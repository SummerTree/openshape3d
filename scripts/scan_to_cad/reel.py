#!/usr/bin/env python3
"""The corpus reel: every scan beside its CAD model, then its deviation
preview, part after part — cut both ways, 16:9 and 9:16, with narration,
music, captions, and the text files that go with a post.

    python3 reel.py corpus/ --port 8947 --simulator os3d-hydrant \\
        --derived-data ~/Library/Developer/Xcode/DerivedData/openshape3d-xxx \\
        [--orientation both|landscape|portrait] [--only a,b] [--skip-take] [--skip-compose] \\
        [--tts gemini|edge] [--music path.m4a|none] [--out corpus/reel]

take — per orientation the app runs inside the film's take UI test
(`TutorialTakeUITests`, which holds the device in that orientation for as
long as it runs; an app launched on its own after a rotation test falls
back to the simulator's own orientation and the portrait pass came out on
its side), then for each built part a new design is opened, the scan
imported with its base on the floor, the model rebuilt from the part's
analysis (the film's sketch-and-revolve recipe), the Deviation Preview
filmed turning over a dark studio backdrop, then the pair — the untinted
scan beside the model — filmed turning. Two short clips per part, over the
bridge; the test only turns the device and opens the designs.

compose — a title over the first pair, one segment per part (the pair,
then the preview) sized to the part's narration line, an outro over the
last pair. The 16:9 cut crops the iPad's screen in on the parts and lays
caption pills over it; the 9:16 cut keeps the whole portrait screen and
writes the captions in the bands above and below it. Narration through
`demo_video.narrate` (Gemini 3.8, each line cached by its text), the music
bed ducked under it. Writes `reel-16x9.mp4`, `reel-9x16.mp4`, `script.txt`,
`captions-16x9.srt`, `captions-9x16.srt`, `credits.txt`, `post.txt`.

Narration lines: `title` and `outro` below, and per part the spec's
`reelSay` (or the default sentence), with `{label}`, `{iou}` and `{mean}`
filled in from `results.json` — the numbers the app measured.
"""
import argparse
import json
import math
import os
import socket
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from build_hydrant import body_section, boss_section, unit, world, secondary_sections, revolve_secondary, window_sections, cut_window, model_color  # noqa: E402
from build_features import build_feature, shift_feature  # noqa: E402
from demo_video import Recorder, caption, ffmpeg_watched, narrate, scan_on_floor, title_overlay  # noqa: E402
from mcp_client import MCPClient, MCPError  # noqa: E402
from run_corpus import BUNDLE, udid_for  # noqa: E402

BACKDROP = (0.13, 0.14, 0.16)
FRAMES = {"landscape": (1920, 1080), "portrait": (1080, 1920)}
HOOK_SECONDS, PREVIEW_SECONDS = 10.0, 6.0      # recorded
PREVIEW_CUT = 3.2                               # used, per part
PAIR_SKIP = 3.0                                 # the import's notice fades over the pair's first seconds
TITLE_SAY = ("Ten 3D scans from Sketchfab, each rebuilt as a parametric CAD model by an assistant "
             "over MCP in OpenShape 3D — and graded by the app against the scan.")
OUTRO_SAY = "OpenShape 3D is open source. Every scan is CC-BY, credited on screen."
DEFAULT_SAY = "{label}: {iou} percent silhouette overlap, within {mean} millimetres on average."


# ----------------------------------------------------------------------------- take

def recorder(udid, path):
    """demo_video's Recorder exits the process when simctl will not record
    (an orphaned recording on the device, say); here that is one part's
    failure, and the session starts again."""
    try:
        return Recorder(udid, path)
    except SystemExit as stop:
        raise RuntimeError("recordVideo did not start (%s)" % stop)


def wait_empty_design(port, seconds=40):
    """The bridge answering on a design with no bodies in it."""
    import urllib.request
    until = time.time() + seconds
    while time.time() < until:
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/v1/state" % port, timeout=2) as r:
                state = json.load(r)
            if state.get("ok") and not state.get("bodies"):
                return
        except Exception:  # noqa: BLE001 — not up yet
            pass
        time.sleep(0.5)
    raise RuntimeError("no empty design on the bridge after %d s" % seconds)


def build_model(mcp, analysis, label, color, features=None):
    """The film's recipe, on a scan whose base sits at the origin: one
    profile revolved about the fitted axis, each boss revolved about its
    own and unioned in. Returns the body id."""
    origin = np.zeros(3)
    axis, u, v = unit(analysis["axisDirection"]), unit(analysis["azimuthZero"]), unit(analysis["azimuthNinety"])
    plane = {"origin": world(origin, axis, u, v, 0, 0), "xAxis": [float(x) for x in u],
             "yAxis": [float(x) for x in axis], "name": label + " profile"}
    sketch = mcp.os3d("sketch.create", plane)["sketchID"]
    # The half-section the build revolved (arcs, a hollow section for a
    # container): the reel shows the model the inspection graded.
    section = body_section(analysis)
    mcp.os3d("sketch.addEntities", {"sketchID": sketch, "entities": section["entities"]})
    cad = mcp.os3d("feature.revolve", {"sketchID": sketch, "seedPoint": section["seed"],
                                       "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360})["producedBodyIDs"][0]
    if section.get("inner"):
        # A container: the cavity revolved and subtracted, as the build did.
        sk_in = mcp.os3d("sketch.create", dict(plane, name=label + " cavity"))["sketchID"]
        mcp.os3d("sketch.addEntities", {"sketchID": sk_in, "entities": section["inner"]["entities"]})
        mcp.os3d("feature.revolve", {"sketchID": sk_in, "seedPoint": section["inner"]["seed"],
                                     "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360,
                                     "boolean": "subtract", "booleanTargets": [cad]})
    for win in window_sections(analysis, shift=-np.array(analysis["axisOrigin"], dtype=float)):
        try:
            if cut_window(mcp, win, cad, label, note=False).get("failed"):
                mcp.os3d("command.run", {"id": "edit.undo"})
        except MCPError:
            pass
    # The other bodies of revolution on their own axes (a valve's pipe
    # and branches, a hydrant's nozzles), as the build revolved them.
    delta = -np.array(analysis["axisOrigin"], dtype=float)         # the scan stands on the floor, axis origin at 0
    for sec in secondary_sections(analysis, shift=delta):
        try:
            reply = revolve_secondary(mcp, sec, cad, note=False)
            if reply.get("failed"):
                mcp.os3d("command.run", {"id": "edit.undo"})
        except MCPError:
            pass
    bosses = [b for b in analysis.get("bosses", []) if b["reachMM"] - b["bodyRadiusMM"] > 15 and b.get("profile")]
    for n, boss in enumerate(bosses, 1):
        az = boss["azimuthDeg"]
        d = unit(math.cos(math.radians(az)) * u + math.sin(math.radians(az)) * v)
        t = unit(np.cross(axis, d))
        inner = boss.get("innerStartMM", boss["bodyRadiusMM"] - 12.0)
        entities, seed = boss_section(boss)
        sk = mcp.os3d("sketch.create", {"origin": world(origin, axis, u, v, inner, boss["centerHeightMM"], az),
                                        "xAxis": [float(x) for x in t], "yAxis": [float(x) for x in d],
                                        "name": "Boss %d" % n})["sketchID"]
        mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": entities})
        mcp.os3d("feature.revolve", {"sketchID": sk, "seedPoint": seed,
                                     "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360,
                                     "boolean": "union", "booleanTargets": [cad]})
    # The fitted features the build built (features.json, the ones its
    # summary says were ok), so the reel shows the model the inspection graded.
    for n, feature in enumerate(features or [], 1):
        feature = shift_feature(feature, delta)
        try:
            reply = build_feature(mcp, feature, cad, feature.get("name", "feature %d" % n), note=False)
            if reply.get("failed"):
                mcp.os3d("command.run", {"id": "edit.undo"})
        except MCPError:
            pass
    mcp.os3d("body.setMaterial", {"bodyIDs": [cad], "color": list(color), "roughness": 0.45})
    mcp.os3d("item.setHidden", {"allSketches": True})
    return cad


def built_features(part):
    """The features build_features.py built for a part, or []."""
    path = os.path.join(part, "features", "features.json")
    summary = os.path.join(part, "run", "summary.json")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        found = json.load(f).get("features", [])
    if os.path.exists(summary):
        with open(summary) as f:
            ok = {b["name"] for b in json.load(f).get("features", []) if b.get("ok")}
        found = [ft for ft in found if ft.get("name") in ok]
    return found


def take_part(slug, part, spec, analysis, tolerance, udid, port, out):
    """Two clips of one part: the Deviation Preview turning, then the pair."""
    os.makedirs(out, exist_ok=True)
    cropped = analysis.get("croppedScan") or os.path.join(part, "analysis", "scan_cropped.glb")
    floor = os.path.join(part, "demo", "scan-on-floor.glb")
    if not os.path.exists(floor):
        floor = scan_on_floor(cropped, analysis["axisOrigin"], os.path.join(out, "scan-on-floor.glb"))
    clips = {}
    with MCPClient(port=port, log_dir=out) as mcp:
        mcp.initialize()

        def turn(seconds, step=0.5):
            until = time.time() + seconds
            while time.time() < until:
                mcp.os3d("command.run", {"id": "view.rotateLeft15"})
                time.sleep(step)

        def studio():
            mcp.os3d("view.visualize", {"preset": "Studio", "background": "color", "backgroundColor": list(BACKDROP),
                                        "groundShadow": True, "panel": False})

        scan_id = mcp.os3d("document.import", {"path": os.path.abspath(floor), "fileName": os.path.basename(floor)})["bodyIDs"][0]
        mcp.os3d("item.select", {"ids": []})
        cad = build_model(mcp, analysis, spec.get("label", slug), model_color(spec, analysis),
                          features=built_features(part))

        # The preview: the scan wears the colours, the model is ghosted.
        studio()
        mcp.os3d("command.run", {"id": "view.isometric"})
        mcp.os3d("command.run", {"id": "view.fit"})
        time.sleep(1.0)
        try:
            mcp.os3d("view.deviationPreview", {"reference": scan_id, "model": cad, "tolerance": tolerance, "panel": False})
        except Exception as problem:  # noqa: BLE001
            # The call waits for the measurement; on a dense scan with the
            # Mac busy it can outlast the server's timeout while the app
            # carries on measuring — the poll below sees it finish.
            if "timed out" not in str(problem).lower():
                raise
            print("   (the preview call timed out; waiting for the app)", flush=True)
        until = time.time() + 300
        while time.time() < until:
            dp = mcp.os3d("state").get("deviationPreview") or {}
            if dp.get("active") and not dp.get("computing"):
                break
            time.sleep(1.0)
        time.sleep(0.8)
        rec = recorder(udid, os.path.join(out, "preview.mov"))
        turn(PREVIEW_SECONDS)
        rec.stop()
        clips["preview"] = os.path.join(out, "preview.mov")
        mcp.os3d("view.deviationPreview", {"off": True})

        # The pair: the model steps aside, a fresh untinted scan takes its place.
        mcp.os3d("item.setHidden", {"ids": [scan_id]})
        aside = round(max(analysis["heightMM"], 2 * analysis.get("maxRadiusMM", analysis["bodyRadiusMM"])) * 0.43)
        mcp.os3d("feature.transform", {"bodyID": cad, "translation": [aside, 0, -aside]})
        mcp.os3d("document.import", {"path": os.path.abspath(floor), "fileName": os.path.basename(floor)})
        mcp.os3d("item.select", {"ids": []})
        studio()
        mcp.os3d("command.run", {"id": "view.isometric"})
        mcp.os3d("command.run", {"id": "view.fit"})
        time.sleep(1.4)
        rec = recorder(udid, os.path.join(out, "pair.mov"))
        turn(HOOK_SECONDS)
        rec.stop()
        clips["pair"] = os.path.join(out, "pair.mov")
        mcp.os3d("view.visualize", {"off": True})
    return clips


def free_port(start, tries=50):
    """The first port from `start` that nothing on this Mac is listening on."""
    for port in range(start, start + tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError("no free control port in %d..%d" % (start, start + tries))


def rotate_device(udid, derived_data, orientation, log_path):
    """Put the simulator in `orientation` before a pass.

    An iPad simulator boots in portrait, and `XCUIDevice.shared.orientation`
    turns it to landscape from there — but it will not turn it back: with the
    device in landscape, the take test and the one-shot `RotateDeviceUITests`
    both log "Setting device orientation to Portrait" and the home screen,
    the app and every recording stay landscape (a portrait pass once filmed
    ten clips on their side, twice). So portrait is a shutdown and a boot;
    landscape is the rotate test (the orientation outlives it)."""
    print("== turning the device to %s" % orientation, flush=True)
    if orientation == "portrait":
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True, check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], capture_output=True, timeout=300)
        time.sleep(5.0)
        with open(log_path, "w") as log:
            log.write("portrait: the simulator was shut down and booted (it boots in portrait)\n")
        return
    env = dict(os.environ, TEST_RUNNER_OS3D_ORIENTATION=orientation)
    cmd = ["xcodebuild", "test", "-project", os.path.join(ROOT, "openshape3d.xcodeproj"), "-scheme", "openshape3d",
           "-destination", "platform=iOS Simulator,id=" + udid, "-derivedDataPath", derived_data,
           "-parallel-testing-enabled", "NO", "-only-testing:openshape3dUITests/RotateDeviceUITests"]
    with open(log_path, "w") as log:
        done = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=env, timeout=900)
    if done.returncode != 0:
        raise RuntimeError("RotateDeviceUITests exit %d — see %s" % (done.returncode, log_path))


def take(args, corpus, order, results, specs, out):
    udid = udid_for(args.simulator)
    # The YouTube series' remote-controlled UI test launches the app with
    # the bridge on our port, turns the device, and opens a new design on
    # request; it keeps the orientation for as long as it runs.
    sys.path.insert(0, os.path.join(HERE, "..", "youtube_series"))
    import common as yt
    yt.BRIDGE_PORT = str(args.port)
    yt.DD = args.derived_data
    for orientation in args.orientations:
        odir = os.path.join(out, orientation)
        os.makedirs(odir, exist_ok=True)
        rotate_device(udid, args.derived_data, orientation, os.path.join(odir, "rotate.log"))
        takes_path = os.path.join(odir, "takes.json")
        takes = json.load(open(takes_path)) if os.path.exists(takes_path) else {}
        yt.ORIENTATION = orientation
        pending, attempts, session = list(order), {}, 0
        while pending:
            # One app session per part: the app starts fresh, the test opens
            # a new design, the part is filmed, the session ends. Clearing
            # the design over the bridge between parts left the previous
            # part's model standing beside the next part's scan, and a part
            # that fails leaves the app in an unknown state anyway (a
            # measurement that outlasted the server's timeout once took the
            # bridge down with it); a failed part is tried once more.
            session += 1
            # A free port for the session's control server. The last
            # session's listening socket is closed below (`server_close`;
            # `shutdown` alone leaves it bound until the cycle collector
            # finds it — the portrait pass once died on "Address already
            # in use" at its sixth part), and a probe guards the rest.
            yt.CONTROL_PORT = free_port(args.control_port)
            print("== %s: launching the app in the take test (session %d)" % (orientation, session), flush=True)
            subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
            control = yt.Control(port=yt.CONTROL_PORT)
            test = yt.start_test(udid, os.path.join(odir, "xcodebuild-%d.log" % session))
            try:
                control.wait_event("ready", 900)
                while pending:
                    slug = pending[0]
                    part = os.path.join(corpus, slug)
                    with open(os.path.join(part, "analysis", "profile.json")) as f:
                        analysis = json.load(f)
                    t0 = time.time()
                    print("== %s / %s" % (orientation, slug), flush=True)
                    try:
                        control.act("new_design")
                        wait_empty_design(args.port)
                        clips = take_part(slug, part, specs[slug], analysis, results[slug]["toleranceMM"], udid, args.port,
                                          os.path.join(odir, slug))
                        takes[slug] = {"ok": True, "clips": clips, "seconds": round(time.time() - t0)}
                        pending.pop(0)
                        with open(takes_path, "w") as f:
                            json.dump(takes, f, indent=1)
                        break
                    except Exception as error:  # noqa: BLE001 — the row says what stopped it
                        attempts[slug] = attempts.get(slug, 0) + 1
                        takes[slug] = {"ok": False, "error": str(error)[:600], "seconds": round(time.time() - t0)}
                        print("   FAILED:", str(error)[:300], flush=True)
                        if attempts[slug] >= 2:
                            pending.pop(0)
                        with open(takes_path, "w") as f:
                            json.dump(takes, f, indent=1)
                        break
                    with open(takes_path, "w") as f:
                        json.dump(takes, f, indent=1)
            finally:
                control.finish()
                try:
                    test.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    test.kill()
                control.server.shutdown()
                control.server.server_close()
        print("%s: %d of %d parts filmed" % (orientation, sum(1 for s in order if takes.get(s, {}).get("ok")), len(order)), flush=True)
    if args.orientations[-1] != "landscape":
        # Leave the simulator the way the part films expect it.
        rotate_device(udid, args.derived_data, "landscape", os.path.join(out, "rotate-back.log"))


# ----------------------------------------------------------------------------- compose

def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                          "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip().split(",")
    return int(out[0]), int(out[1])


def content_box(clip, pre, at=2.0):
    """Where the parts are on the screen: the rows and columns of a frame
    that differ from the studio backdrop, the app's chrome masked out (the
    top bar, the left tool column, the view cube at the top right).
    Returns (x0, y0, x1, y1) in the standing-up frame."""
    from PIL import Image
    png = clip[:-4] + "-probe.png"
    subprocess.run(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-ss", "%.2f" % at, "-i", clip,
                    "-vf", pre + "scale=iw/4:ih/4", "-frames:v", "1", png], check=True)
    im = np.asarray(Image.open(png).convert("RGB"), dtype=float)
    h, w = im.shape[:2]
    bg = np.array([c * 255 for c in BACKDROP])
    diff = np.abs(im - bg).sum(axis=2) > 36
    diff[: int(h * 0.11), :] = False       # the top bar
    diff[:, : int(w * 0.07)] = False       # the tool column
    diff[: int(h * 0.26), int(w * 0.86):] = False   # the view cube
    ys, xs = np.where(diff)
    if len(ys) < 50:
        return 0, 0, w * 4, h * 4
    return int(xs.min()) * 4, int(ys.min()) * 4, int(xs.max() + 1) * 4, int(ys.max() + 1) * 4


def frame_filter(clip, orientation):
    """The chain that turns a simulator recording into the cut's frame."""
    W, H = FRAMES[orientation]
    sw, sh = probe(clip)
    pre = ""
    if orientation == "landscape":
        if sw < sh:
            # `recordVideo` writes the portrait framebuffer with the
            # landscape picture turned inside it; stand it up.
            pre, sw, sh = "transpose=2,", sh, sw
        # In on the parts: a 16:9 window around where they are, with a
        # tenth of headroom — as close as that allows, never closer than
        # 70 % of the width (a fit of two tall parts fills the height of
        # the screen, a small part sits in the middle of it).
        x0, y0, x1, y1 = content_box(clip, pre)
        need_h = (y1 - y0) * 1.2
        h = int(min(sh, max(need_h, sw * 0.70 * 9 / 16))) & ~1
        w = int(min(sw, h * 16 / 9)) & ~1
        h = int(w * 9 / 16) & ~1
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        x = int(max(0, min(sw - w, cx - w / 2)))
        y = int(max(0, min(sh - h, cy - h / 2)))
        return "%sfps=30,crop=%d:%d:%d:%d,scale=%d:%d" % (pre, w, h, x, y, W, H)
    if sw > sh:
        pre, sw, sh = "transpose=1,", sh, sw
    # The whole portrait screen at the cut's width, the bands above and
    # below it in the backdrop's colour — the captions go there.
    ph = (int(sh * W / sw) & ~1)
    bg = "0x%02x%02x%02x" % tuple(int(c * 255) for c in BACKDROP)
    return "%sfps=30,scale=%d:%d,pad=%d:%d:0:%d:color=%s" % (pre, W, ph, W, H, (H - ph) // 2, bg)


def band_overlay(path, orientation, top, bottom):
    """The 9:16 cut's text: lines in the band above the picture and lines
    in the band below. A transparent full-frame PNG."""
    from PIL import Image, ImageDraw, ImageFont
    W, H = FRAMES[orientation]
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def font(size, bold=True):
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=1 if bold else 0)

    max_w = W - 2 * 48   # the frame less a gutter; 1080 px holds about 40 characters at 44 px

    def wrap(text, f):
        """`text` as lines that fit the width in font `f`, broken at ' · '
        (the title's subtitle and the outro's links ran off both edges)."""
        lines, cur = [], ""
        for piece in text.split(" · "):
            cand = piece if not cur else cur + " · " + piece
            if not cur or d.textlength(cand, font=f) <= max_w:
                cur = cand
            else:
                lines.append(cur)
                cur = piece
        return lines + [cur]

    def block(lines, y_center, sizes, colours):
        rows = []
        for text, size, colour in zip(lines, sizes, colours):
            bold = size >= 44
            for line in wrap(text, font(size, bold)):
                s, f = size, font(size, bold)
                while d.textlength(line, font=f) > max_w and s > 24:   # a piece with no ' · ' to break at
                    s -= 2
                    f = font(s, bold)
                rows.append((line, f, s, colour))
        heights = [int(s * 1.25) for _, _, s, _ in rows]
        y = y_center - sum(heights) // 2
        for (text, f, s, colour), lh in zip(rows, heights):
            tw = d.textlength(text, font=f)
            d.text(((W - tw) / 2, y), text, font=f, fill=colour)
            y += lh

    white, grey = (255, 255, 255, 255), (190, 198, 210, 255)
    if top:
        block(top, 150, [58, 34][:len(top)], [white, grey][:len(top)])
    if bottom:
        block(bottom, H - 150, [44, 32][:len(bottom)], [white, grey][:len(bottom)])
    im.save(path)
    return path


def segment_clip(src, seconds, orientation, overlays, path, seek=0.0):
    """One segment: the clip framed for the cut, the overlays on it."""
    W, H = FRAMES[orientation]
    inputs = ["-ss", "%.2f" % seek, "-i", src]
    # tpad holds the last frame when the source runs out before `seconds`
    # (the title starts past the import notice, which leaves its pair short).
    chain = ["[0:v]%s,tpad=stop_mode=clone:stop_duration=%.2f[v0]" % (frame_filter(src, orientation), seconds)]
    last = "v0"
    for i, (png, x, y) in enumerate(overlays, 1):
        inputs += ["-i", png]   # one frame; overlay holds it (a looped input can deadlock ffmpeg 9)
        chain.append("[%s][%d:v]overlay=%s:%s:format=auto[v%d]" % (last, i, x, y, i))
        last = "v%d" % i
    ffmpeg_watched(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", *inputs, "-filter_complex", ";".join(chain),
                    "-map", "[%s]" % last, "-t", "%.2f" % seconds, "-r", "30", "-c:v", "libx264", "-preset", "medium",
                    "-crf", "19", "-pix_fmt", "yuv420p", "-an", path], timeout=600)
    return path


def painted(painter, path, *args, **kwargs):
    """demo_video's pill painters write the PNG and return nothing."""
    painter(path, *args, **kwargs)
    return path


def srt_time(t):
    ms = int(round(t * 1000))
    return "%02d:%02d:%02d,%03d" % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000)


def compose(args, corpus, order, results, specs, manifest, out):
    music = args.music
    if music == "default":
        music = os.path.join(corpus, "..", "hydrant", "demo", "music-lyria.m4a")
        if not os.path.exists(music):
            music = "none"
    # The lines, with the app's numbers in them.
    lines = {"title": TITLE_SAY}
    numbers = {}
    for slug in order:
        r = results[slug]
        numbers[slug] = {"iou": "%.0f" % (r["overallIoU"] * 100), "mean": "%.0f" % r["modelToScanMeanMM"]
                         if r["modelToScanMeanMM"] >= 1.5 else "%.1f" % r["modelToScanMeanMM"],
                         "label": specs[slug].get("label", slug)}
        lines[slug] = specs[slug].get("reelSay", DEFAULT_SAY).format(**numbers[slug])
    lines["outro"] = OUTRO_SAY
    clips, backend = narrate(lines, os.path.join(out, "tts"), args.tts, args.gemini_voice, args.project, args.region)
    with open(os.path.join(out, "script.txt"), "w") as f:
        f.write("Corpus reel — narration (%s)\n\n" % backend)

    for orientation in args.orientations:
        odir = os.path.join(out, orientation)
        takes = json.load(open(os.path.join(odir, "takes.json")))
        parts = [s for s in order if takes.get(s, {}).get("ok")]
        if not parts:
            print("%s: nothing filmed" % orientation)
            continue
        W, H = FRAMES[orientation]
        work = os.path.join(odir, "work")
        os.makedirs(work, exist_ok=True)
        segs, cue, t = [], {}, 0.0

        def pills(slug, name, credit, nums):
            if orientation == "portrait":
                return [(band_overlay(os.path.join(work, slug + "-bands.png"), orientation, [name, credit], [nums]), 0, 0)]
            top = painted(title_overlay, os.path.join(work, slug + "-name.png"), [name], credit, size=52)
            low = painted(caption, os.path.join(work, slug + "-nums.png"), nums)
            return [(top, 56, 48), (low, 56, "H-h-48")]

        # Title over the first pair, held for the title line.
        first = parts[0]
        title_s = max(4.5, clips["title"]["seconds"] + 0.7)
        if orientation == "portrait":
            ov = [(band_overlay(os.path.join(work, "title-bands.png"), orientation,
                                ["From 3D scans", "to CAD models"], ["Ten Sketchfab scans · built over MCP in OpenShape 3D"]), 0, 0)]
        else:
            ov = [(painted(title_overlay, os.path.join(work, "title.png"), ["From 3D scans", "to CAD models"],
                           "Ten Sketchfab scans · built by an assistant over MCP in OpenShape 3D"), 56, "H-h-48")]
        # Past the import notice, like the parts; the clip's last frame holds if the title outlasts it.
        segs.append(segment_clip(takes[first]["clips"]["pair"], title_s, orientation, ov, os.path.join(work, "seg-title.mp4"),
                                 seek=max(PAIR_SKIP, HOOK_SECONDS - title_s - 0.2)))
        cue["title"] = t + 0.25
        t += title_s

        for slug in parts:
            name = specs[slug].get("label", slug)
            scan = specs[slug].get("scan", {})
            credit = "Scan: CC-BY %s on Sketchfab" % (scan.get("author") or manifest.get(slug, {}).get("author", ""))
            r = results[slug]
            nums = "%s %% silhouette overlap · %s mm mean deviation" % (numbers[slug]["iou"], numbers[slug]["mean"])
            say = clips[slug]["seconds"]
            # The pair holds for the line; a long line also stretches the
            # preview (both clips have slack beyond their usual cut).
            pair_s = min(HOOK_SECONDS - PAIR_SKIP - 0.2, max(4.5, say + 0.6 - PREVIEW_CUT))
            preview_s = min(PREVIEW_SECONDS - 0.2, max(PREVIEW_CUT, say + 0.6 - pair_s))
            ov = pills(slug, name, credit, nums)
            segs.append(segment_clip(takes[slug]["clips"]["pair"], pair_s, orientation, ov, os.path.join(work, slug + "-pair.mp4"),
                                     seek=PAIR_SKIP))
            preview_note = "Deviation preview · blue = missing · orange = excess"
            if orientation == "portrait":
                ov2 = [(band_overlay(os.path.join(work, slug + "-bands2.png"), orientation, [name, credit], [preview_note]), 0, 0)]
            else:
                ov2 = [ov[0], (painted(caption, os.path.join(work, slug + "-preview.png"), preview_note), 56, "H-h-48")]
            segs.append(segment_clip(takes[slug]["clips"]["preview"], preview_s, orientation, ov2,
                                     os.path.join(work, slug + "-preview.mp4")))
            cue[slug] = t + 0.25
            t += pair_s + preview_s
            if say + 0.25 > pair_s + preview_s:
                print("WARNING: the %s line (%.1f s) runs past its segment (%.1f s)" % (slug, say, pair_s + preview_s))

        # Outro over the last pair's remaining seconds.
        outro_s = max(4.0, clips["outro"]["seconds"] + 1.2)
        last = parts[-1]
        if orientation == "portrait":
            ov = [(band_overlay(os.path.join(work, "outro-bands.png"), orientation, ["OpenShape 3D", "is open source"],
                                ["app.openshape3d.com · github.com/laanlabs/openshape3d"]), 0, 0)]
        else:
            ov = [(painted(title_overlay, os.path.join(work, "outro.png"), ["OpenShape 3D is open source"],
                           "app.openshape3d.com · github.com/laanlabs/openshape3d · scans CC-BY on Sketchfab", size=56), 56, "H-h-48")]
        segs.append(segment_clip(takes[last]["clips"]["pair"], outro_s, orientation, ov, os.path.join(work, "seg-outro.mp4"),
                                 seek=max(0.0, HOOK_SECONDS - outro_s - 0.2)))
        cue["outro"] = t + 0.25
        t += outro_s
        total = t

        # Hold a line back rather than let it overlap the one before.
        last_end, previous = 0.0, None
        for sid in sorted(cue, key=cue.get):
            if previous and cue[sid] < last_end + 0.3:
                print("the %s line waits %.1f s for the %s line" % (sid, last_end + 0.3 - cue[sid], previous))
                cue[sid] = last_end + 0.3
            last_end, previous = cue[sid] + clips[sid]["seconds"], sid

        concat = os.path.join(work, "concat.txt")
        with open(concat, "w") as f:
            for s in segs:
                f.write("file '%s'\n" % s)
        video = os.path.join(work, "video.mp4")
        ffmpeg_watched(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", concat,
                        "-c", "copy", video], timeout=300)

        inputs, filters, mix, idx = ["-i", video], [], [], 1
        for sid in sorted(cue, key=cue.get):
            inputs += ["-i", clips[sid]["path"]]
            delay = int(cue[sid] * 1000)
            filters.append("[%d:a]adelay=%d|%d[n%d]" % (idx, delay, delay, idx))
            mix.append("[n%d]" % idx)
            idx += 1
        if music != "none":
            looped = os.path.join(work, "music-looped.m4a")
            subprocess.run(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-stream_loop", "-1", "-i", music,
                            "-t", "%.2f" % (total + 1.0), "-c", "copy", looped], check=True)
            inputs += ["-i", looped]
            filters.append("[%d:a]volume=%.2f,atrim=0:%.2f,afade=t=out:st=%.2f:d=2.5[mus]" % (idx, args.music_gain, total, total - 2.5))
            mix.append("[mus]")
        filters.append("".join(mix) + "amix=inputs=%d:normalize=0,alimiter=limit=0.95[aout]" % len(mix))
        name = "reel-16x9.mp4" if orientation == "landscape" else "reel-9x16.mp4"
        final = os.path.join(out, name)
        ffmpeg_watched(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filters),
                        "-map", "0:v", "-map", "[aout]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-t", "%.2f" % total,
                        "-movflags", "+faststart", final], timeout=600)
        sheet = os.path.join(out, "contact-%s.png" % orientation)
        cols = 6 if orientation == "landscape" else 10
        rows = max(1, -(-int(total / 2 + 1) // cols))
        ffmpeg_watched(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-i", final, "-vf",
                        "fps=1/2,scale=%d:-1,tile=%dx%d" % (320 if orientation == "landscape" else 180, cols, rows),
                        "-frames:v", "1", sheet], timeout=300)

        # The text files: the subtitles, and the script with its cues.
        srt = os.path.join(out, "captions-%s.srt" % ("16x9" if orientation == "landscape" else "9x16"))
        with open(srt, "w") as f:
            for n, sid in enumerate(sorted(cue, key=cue.get), 1):
                f.write("%d\n%s --> %s\n%s\n\n" % (n, srt_time(cue[sid]), srt_time(cue[sid] + clips[sid]["seconds"]), lines[sid]))
        with open(os.path.join(out, "script.txt"), "a") as f:
            f.write("== %s cut: %s (%.1f s)\n" % (orientation, name, total))
            for sid in sorted(cue, key=cue.get):
                f.write("%6.1f s  %-20s %s\n" % (cue[sid], sid, lines[sid]))
            f.write("\n")
        print("wrote %s (%.1f s); narration %s; music %s; contact sheet %s" % (
            final, total, backend, "none" if music == "none" else os.path.basename(music), sheet))

    with open(os.path.join(out, "credits.txt"), "w") as f:
        f.write("Scans (all CC Attribution, via Sketchfab):\n")
        for slug in order:
            m = manifest.get(slug, {})
            f.write("- %s — %s (%s), %s — %s\n" % (m.get("name", slug), m.get("author", ""), m.get("username", ""),
                                                  m.get("license", "CC-BY"), m.get("url", "")))
    with open(os.path.join(out, "post.txt"), "w") as f:
        f.write("Ten 3D scans from Sketchfab, each rebuilt as a parametric CAD model by an assistant over MCP in "
                "OpenShape 3D — and graded by the app against the scan. Silhouette overlap: "
                + ", ".join("%s %s %%" % (specs[s].get("label", s).lower(), numbers[s]["iou"]) for s in order)
                + ". The handles, hoses and the valve's second axis are what it misses, and the Deviation Preview "
                "paints them blue.\n\nOpenShape 3D is open source: app.openshape3d.com · github.com/laanlabs/openshape3d\n\n")
        f.write(open(os.path.join(out, "credits.txt")).read())


# ----------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--out", default=None, help="default corpus/reel")
    ap.add_argument("--port", type=int, default=8947)
    ap.add_argument("--simulator", default="os3d-hydrant")
    ap.add_argument("--derived-data", default=None, help="DerivedData with the UI test products (the take test runs from it)")
    ap.add_argument("--control-port", type=int, default=8930)
    ap.add_argument("--orientation", choices=["both", "landscape", "portrait"], default="both")
    ap.add_argument("--only", default=None, help="comma-separated part folders")
    ap.add_argument("--skip-take", action="store_true")
    ap.add_argument("--skip-compose", action="store_true")
    ap.add_argument("--tts", choices=["gemini", "edge"], default="gemini")
    ap.add_argument("--gemini-voice", default="Charon")
    ap.add_argument("--project", default="openshape3d")
    ap.add_argument("--region", default="us-central1")
    ap.add_argument("--music", default="default", help="a file, none, or default (the hydrant's bed)")
    ap.add_argument("--music-gain", type=float, default=0.22)
    ap.add_argument("--allow-fail", action="store_true",
                    help="include parts whose inspection (results.json → qa.verdict) FAILED; by default they are left out")
    args = ap.parse_args()
    args.orientations = ["landscape", "portrait"] if args.orientation == "both" else [args.orientation]
    corpus = os.path.abspath(args.corpus)
    out = os.path.abspath(args.out or os.path.join(corpus, "reel"))
    os.makedirs(out, exist_ok=True)
    order = json.load(open(os.path.join(corpus, "order.json")))
    results = json.load(open(os.path.join(corpus, "results.json")))
    manifest = json.load(open(os.path.join(corpus, "manifest.json")))
    order = [s for s in order if results.get(s, {}).get("ok")]
    # The reel shows only what the inspection passed or merely warned on;
    # a FAIL is a flaw at full size with a number under it.
    failed = [s for s in order if results[s].get("qa", {}).get("verdict") == "FAIL"]
    if failed and not args.allow_fail:
        print("left out, inspection FAILED: %s (pass --allow-fail to keep them)" % ", ".join(failed), flush=True)
        order = [s for s in order if s not in failed]
    for s in order:
        v = results[s].get("qa", {}).get("verdict")
        if v:
            print("%s: inspection %s" % (s, v), flush=True)
    if args.only:
        order = [s for s in order if s in args.only.split(",")]
    specs = {s: json.load(open(os.path.join(corpus, s, "spec.json"))) for s in order}
    if not args.skip_take:
        if not args.derived_data:
            sys.exit("--derived-data is needed to run the take test")
        take(args, corpus, order, results, specs, out)
    if not args.skip_compose:
        compose(args, corpus, order, results, specs, manifest, out)


if __name__ == "__main__":
    main()
