#!/usr/bin/env python3
"""A demo film of the scan-to-CAD run, shot in the app itself.

    python3 demo_video.py take    --scan analysis/scan_cropped.glb --analysis analysis/ --out demo/ --port 8947 [--spec part.json]
    python3 demo_video.py compose --out demo/ [--spec part.json] [--tts gemini|edge] [--music lyria|generated|path.m4a]

`--spec` is a JSON file that says what the part is, so one script films any
turned part: {"label": "Fire extinguisher", "color": [r, g, b], "title":
"…|…", "subtitle", "titleSay", "name", "credit": "Scan: CC-BY grafi on
Sketchfab", "captions": {"import", "revolve", "boss" (with {n}), "lug",
"check"}, "say": {beat: line, with {iou} {calls} {mean} {label}}}. Every
key is optional; without the file the words are the fire hydrant's.

`take` records the iPad simulator (`simctl io recordVideo`) while the model
is built over MCP — the scan appearing, the revolve, each nozzle, a slow
turn in Visualize, then Views ▸ Accuracy Report… opening and computing on
screen — and writes `take.mov` plus `timeline.json` (when each beat
happened). The build itself is `build_hydrant.py`'s recipe, paced for the
camera; exports and the JSON report are not filmed. With `--ui` the app is
launched by `TutorialTakeUITests` (the remote-controlled touch test the
YouTube series uses) and the report is opened the way a person opens it:
the Views menu, Accuracy Report…, Compare, a scroll through the results,
Done — real taps on the recording, not an agent op.

`compose` cuts the take to its beats, lays a caption pill over each, puts a
title and a numbers card around it, narrates it (Gemini TTS through Vertex
AI when the gcloud login is valid, otherwise the edge-tts neural voice) and
adds a music bed (Lyria through Vertex AI, or a generated one), then writes
`<name>.mp4` and a contact sheet.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import math
import os
import signal
import subprocess
import sys
import time
import urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mcp_client import MCPClient  # noqa: E402

BUNDLE = "com.laan.labs.openshape3d"
W, H, FPS = 1920, 1080, 30


# ----------------------------------------------------------------------------- take

def simctl(*args, check=True, capture=True):
    return subprocess.run(["xcrun", "simctl", *args], check=check, capture_output=capture, text=True)


def udid_for(name):
    out = simctl("list", "devices", "available").stdout
    for line in out.splitlines():
        if name + " (" in line:
            import re
            m = re.search(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", line)
            if m:
                return m.group(0)
    sys.exit("no simulator named " + name)


class Recorder:
    def __init__(self, udid, path):
        if os.path.exists(path):
            os.remove(path)
        self.proc = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", path],
                                     stderr=subprocess.PIPE, text=True)
        while True:
            line = self.proc.stderr.readline()
            if "Recording started" in line:
                self.t0 = time.time()
                return
            if self.proc.poll() is not None:
                sys.exit("recordVideo did not start")

    def now(self):
        return time.time() - self.t0

    def stop(self):
        self.proc.send_signal(signal.SIGINT)
        self.proc.wait(timeout=180)


def scan_on_floor(path, base_mm, out):
    """`path` (a GLB in metres) translated so `base_mm` lands at the origin."""
    import trimesh
    scene = trimesh.load(path, force="scene")
    shift = -np.asarray(base_mm, dtype=float) / 1000.0
    for node in scene.graph.nodes_geometry:
        matrix, geom = scene.graph[node]
        matrix = np.array(matrix, dtype=float)
        matrix[:3, 3] += shift
        scene.graph.update(frame_to=node, matrix=matrix)
    scene.export(out)
    return out


def modelling_calls(calls):
    """The calls that made the model: sketches, features, checks and the
    report — not the camera moves, colours and hides that stage the film."""
    staging = {"health", "state", "screenshot", "item.setHidden", "item.select", "body.setMaterial", "view.visualize",
               "view.accuracyReport", "view.deviationPreview", "command.run"}
    return sum(1 for c in calls if (c.get("arguments") or {}).get("op") not in staging)


def take(args):
    with open(os.path.join(args.analysis, "profile.json")) as f:
        analysis = json.load(f)
    from build_hydrant import body_section, boss_section, unit, world, secondary_sections, revolve_secondary, window_sections, cut_window
    from build_features import build_feature, feature_caption, shift_feature
    from mcp_client import MCPError
    spec = args.spec or {}
    label = spec.get("label", "Hydrant")
    color = list(spec.get("color", [0.86, 0.17, 0.12]))
    captions = {"import": "Import the iPhone scan", "revolve": "One sketch on the scan's own axis, one revolve",
                "boss": "Nozzle {n} · its own profile, revolved and unioned in", "lug": "A lug on the bonnet · the same way",
                "body": "A second axis · its own profile, revolved and unioned in",
                "check": "A valid solid, every step in the history"}
    captions.update(spec.get("captions", {}))
    axis_origin = np.array(analysis["axisOrigin"])
    axis = unit(analysis["axisDirection"])
    # The film's copy of the scan stands with its fitted base at the origin,
    # so the studio floor (y = 0) is under it and the ground shadow lands
    # where a shadow should; the build shifts with it.
    os.makedirs(args.out, exist_ok=True)
    args.scan = scan_on_floor(args.scan, axis_origin, os.path.join(args.out, "scan-on-floor.glb"))
    axis_origin = np.zeros(3)
    u = unit(analysis["azimuthZero"])
    v = unit(analysis["azimuthNinety"])
    height = analysis["heightMM"]
    body_r = analysis["bodyRadiusMM"]
    bosses = [b for b in analysis["bosses"] if b["reachMM"] - b["bodyRadiusMM"] > 15 and b.get("profile")]
    nozzles = set(id(b) for b in sorted(bosses, key=lambda b: -(b["reachMM"] - b["bodyRadiusMM"]))[:3])

    os.makedirs(args.out, exist_ok=True)
    udid = udid_for(args.simulator)
    beats = []

    touch, test, control = None, None, None
    if args.ui:
        # The touch half: the YouTube series' remote-controlled UI test
        # launches the app (with the agent bridge on our port) and performs
        # the taps we post to its control server.
        sys.path.insert(0, os.path.join(HERE, "..", "youtube_series"))
        import common as yt
        yt.BRIDGE_PORT = str(args.port)
        yt.CONTROL_PORT = args.control_port
        yt.DD = args.derived_data or yt.DD
        simctl("terminate", udid, BUNDLE, check=False)
        control = yt.Control(port=args.control_port)
        test = yt.start_test(udid, os.path.join(args.out, "xcodebuild.log"))
        control.wait_event("ready", 900)
        control.act("new_design")
        time.sleep(2.0)
        touch = control.act

    with MCPClient(port=args.port, log_dir=args.out) as mcp:
        mcp.initialize()
        health = mcp.os3d("health")
        if not health.get("hasDocument"):
            sys.exit("open an empty design first (launch with OS3D_FRESH=1)")
        if mcp.os3d("state")["bodies"]:
            sys.exit("the design is not empty; relaunch with OS3D_FRESH=1")
        mcp.os3d("command.run", {"id": "view.isometric"})
        rec = Recorder(udid, os.path.join(args.out, "take.mov"))
        time.sleep(1.0)

        def beat(bid, caption):
            beats.append({"id": bid, "caption": caption, "start": rec.now()})
            print("== %5.1fs %s" % (rec.now(), caption), flush=True)

        def hold(seconds):
            time.sleep(seconds)

        def turn(seconds, step=0.5):
            """Keep the camera moving: a 15° step every half second."""
            until = rec.now() + seconds
            while rec.now() < until:
                mcp.os3d("command.run", {"id": "view.rotateLeft15"})
                time.sleep(step)

        try:
            beat("import", captions["import"])
            reply = mcp.os3d("document.import", {"path": os.path.abspath(args.scan), "fileName": os.path.basename(args.scan)})
            scan_id = reply["bodyIDs"][0]
            # An import lands selected, and a selected body is drawn with the
            # accent tint mixed into its texture (45% blue); clear it so the
            # scan shows its own photo texture.
            mcp.os3d("item.select", {"ids": []})
            mcp.os3d("command.run", {"id": "view.fit"})
            hold(0.8)
            mcp.os3d("command.run", {"id": "view.isometric"})
            hold(0.6)
            beats[-1]["ready"] = rec.now()
            turn(3.5)
            mcp.os3d("body.setMaterial", {"bodyIDs": [scan_id], "color": [0.55, 0.62, 0.72, 0.42], "roughness": 0.9})
            turn(0.8)

            beat("revolve", captions["revolve"])
            plane = {"origin": world(axis_origin, axis, u, v, 0, 0), "xAxis": [float(x) for x in u],
                     "yAxis": [float(x) for x in axis], "name": label + " profile"}
            sketch = mcp.os3d("sketch.create", plane)["sketchID"]
            # The half-section the build revolved — arcs for a dome, a hollow
            # section for a container — so the film shows the model the
            # inspection graded, not a solid traced from the straight profile.
            section = body_section(analysis)
            mcp.os3d("sketch.addEntities", {"sketchID": sketch, "entities": section["entities"]})
            turn(1.2)
            reply = mcp.os3d("feature.revolve", {"sketchID": sketch, "seedPoint": section["seed"],
                                                 "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360})
            cad_id = reply["producedBodyIDs"][0]
            if section.get("inner"):
                # A container: the cavity revolved and subtracted, as the build did.
                sk_in = mcp.os3d("sketch.create", dict(plane, name=label + " cavity"))["sketchID"]
                mcp.os3d("sketch.addEntities", {"sketchID": sk_in, "entities": section["inner"]["entities"]})
                mcp.os3d("feature.revolve", {"sketchID": sk_in, "seedPoint": section["inner"]["seed"],
                                             "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360,
                                             "boolean": "subtract", "booleanTargets": [cad_id]})
            for win in window_sections(analysis, shift=-np.array(analysis["axisOrigin"], dtype=float)):
                try:
                    if cut_window(mcp, win, cad_id, label, note=False).get("failed"):
                        mcp.os3d("command.run", {"id": "edit.undo"})
                except MCPError:
                    pass
            mcp.os3d("body.setMaterial", {"bodyIDs": [cad_id], "color": color, "roughness": 0.45})
            mcp.os3d("item.setHidden", {"allSketches": True})
            turn(3.6)

            # The other bodies of revolution the analysis traced on their
            # own axes (a valve's pipe and branches, a hydrant's nozzles),
            # each revolved and unioned in under its own caption. The scan
            # stands on the floor: every origin shifts with it.
            for n, sec in enumerate(secondary_sections(analysis, shift=-np.array(analysis["axisOrigin"], dtype=float)), 1):
                beat("body%d" % n, captions["body"].format(n=n))
                try:
                    reply = revolve_secondary(mcp, sec, cad_id, note=False)
                    if reply.get("failed"):
                        mcp.os3d("command.run", {"id": "edit.undo"})
                except MCPError:
                    pass
                mcp.os3d("item.setHidden", {"allSketches": True})
                turn(1.6)

            nozzle_no = 0
            for n, boss in enumerate(bosses, 1):
                if id(boss) in nozzles:
                    nozzle_no += 1
                    beat("boss%d" % n, captions["boss"].format(n=nozzle_no))
                else:
                    beat("boss%d" % n, captions["lug"])
                az = boss["azimuthDeg"]
                d = unit(math.cos(math.radians(az)) * u + math.sin(math.radians(az)) * v)
                t = unit(np.cross(axis, d))
                inner = boss.get("innerStartMM", boss["bodyRadiusMM"] - 12.0)
                entities, seed = boss_section(boss)
                origin = world(axis_origin, axis, u, v, inner, boss["centerHeightMM"], az)
                sk = mcp.os3d("sketch.create", {"origin": origin, "xAxis": [float(x) for x in t],
                                                "yAxis": [float(x) for x in d], "name": "Boss %d" % n})["sketchID"]
                mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": entities})
                turn(0.6)
                mcp.os3d("feature.revolve", {"sketchID": sk, "seedPoint": seed,
                                             "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360,
                                             "boolean": "union", "booleanTargets": [cad_id]})
                mcp.os3d("item.setHidden", {"allSketches": True})
                turn(1.6)

            # What the revolve missed — a handle, a hose, a lever — fitted
            # by fit_features.py and built by build_features.py: the film
            # builds the same, feature by feature, under its own caption.
            features_path = args.features or os.path.join(os.path.dirname(os.path.abspath(args.analysis)),
                                                          "features", "features.json")
            built = []
            if os.path.exists(features_path):
                with open(features_path) as f:
                    found = json.load(f).get("features", [])
                summary_path = os.path.join(os.path.dirname(features_path), "..", "run", "summary.json")
                if os.path.exists(summary_path):
                    with open(summary_path) as f:
                        ok_names = {b["name"] for b in json.load(f).get("features", []) if b.get("ok")}
                    found = [ft for ft in found if ft.get("name") in ok_names]
                # The scan stands on the floor with its axis origin at the
                # world origin; the features were fitted in the build's frame.
                built = [shift_feature(ft, -np.array(analysis["axisOrigin"], dtype=float)) for ft in found]
            for n, feature in enumerate(built, 1):
                beat("feature%d" % n, captions.get("feature") or feature_caption(feature))
                try:
                    reply = build_feature(mcp, feature, cad_id, feature.get("name", "feature %d" % n), note=False)
                    if reply.get("failed"):
                        mcp.os3d("command.run", {"id": "edit.undo"})
                except MCPError:
                    pass
                mcp.os3d("item.setHidden", {"allSketches": True})
                turn(1.6)

            beat("check", captions["check"])
            check = mcp.os3d("check", {"body": cad_id})
            valid = check["bodies"][0]["health"]["valid"]
            mcp.os3d("item.setHidden", {"ids": [scan_id]})
            mcp.os3d("view.visualize", {"preset": "Studio", "background": "color", "backgroundColor": [1, 1, 1],
                                        "groundShadow": True, "panel": False})
            hold(0.8)
            turn(6.0, step=0.45)
            mcp.os3d("view.visualize", {"off": True})
            mcp.os3d("item.setHidden", {"ids": [scan_id], "hidden": False})
            mcp.os3d("command.run", {"id": "view.isometric"})
            hold(1.0)
            # The numbers for the ending, before the report beat so the wait
            # is not filmed (the cut keeps the check beat's start). Later —
            # once the hook has moved the model aside — the same call ran
            # past the MCP timeout.
            report = mcp.os3d("accuracy", {"reference": scan_id, "model": cad_id, "tolerance": args.tolerance})
            if touch:
                # The report as a person opens it: the Views menu, Accuracy
                # Report…, the sheet (its pickers default to the mesh as the
                # reference and the solid as the model), Compare, the
                # results, a scroll through them, Done. The cut skips the
                # computing wait between `computeStart` and `computeEnd`.
                # Taps go through SpringBoard (`raw_*`): an open menu and a
                # computing sheet keep the app from reporting idle, and an
                # app-side tap would wait up to 60 s for it. The menu is
                # taller than a landscape iPad shows, so it scrolls first.
                beat("accuracy-open", "Views › Accuracy Report…")
                touch("raw_tap:ViewsMenu")
                hold(1.0)
                touch("raw_drag:0.90,0.45;0.90,0.22;0.08")
                hold(0.7)
                touch("raw_tap:AccuracyReportButton")
                hold(2.2)
                beat("accuracy", "")
                beats[-1]["computeStart"] = rec.now()
                touch("raw_tap:AccuracyCompareButton")
                # The results are in when the button reads "Compare Again"
                # (the summary row sits below the fold of the list, where a
                # cell does not exist yet to be found).
                until = time.time() + 180
                while time.time() < until and touch("exists:Compare Again") != "done:yes":
                    pass
                beats[-1]["computeEnd"] = rec.now()
                hold(2.4)
                touch("raw_drag:0.5,0.80;0.5,0.34;0.1")
                hold(2.0)
                touch("raw_drag:0.5,0.34;0.5,0.80;0.1")
                hold(1.0)
                # The report on the part: the sheet's "Show Deviation in
                # Viewport" row closes the sheet and colours the scan — blue
                # where the model is missing material, orange where it has
                # too much; the legend's Done ends it. The cut starts when
                # the legend reports the colours are in (`ready`).
                beat("deviation", "Deviation preview · blue = missing · orange = excess")
                touch("raw_tap:AccuracyShowDeviationButton")
                # The colours are in when the app's state says so (an
                # XCUITest poll for the legend's button never matched it,
                # and each poll's snapshot slowed the measurement).
                until = time.time() + 150
                while time.time() < until:
                    dp = mcp.os3d("state").get("deviationPreview") or {}
                    if dp.get("active") and not dp.get("computing"):
                        break
                    time.sleep(1.0)
                hold(0.8)
                beats[-1]["ready"] = rec.now()
                turn(7.5)
                if touch("raw_tap:DeviationDone") != "done":
                    mcp.os3d("view.deviationPreview", {"off": True})
                hold(0.6)
            else:
                beat("accuracy", "")
                mcp.os3d("view.accuracyReport", {"reference": scan_id, "model": cad_id, "tolerance": args.tolerance})
                # The sheet computes for about as long as the `accuracy` call took
                # (the same kernel), then shows its overlays; film both, and let
                # the cut skip the wait.
                beats[-1]["computeSeconds"] = round(mcp.calls[-2]["seconds"], 1)
                hold(mcp.calls[-2]["seconds"] + 12.0)
                mcp.os3d("view.accuracyReport", {"off": True})
                hold(0.5)
                beat("deviation", "Deviation preview · blue = missing · orange = excess")
                mcp.os3d("view.deviationPreview", {"reference": scan_id, "model": cad_id, "tolerance": args.tolerance})
                hold(0.6)
                beats[-1]["ready"] = rec.now()
                turn(7.5)
                mcp.os3d("view.deviationPreview", {"off": True})
                hold(0.5)

            # The hook for the opening: the scan, photo texture and all,
            # beside the finished model, both turning in the studio view.
            beat("hook", "")
            mcp.os3d("item.setHidden", {"ids": [scan_id]})
            # The model steps aside (a feature body moves; an imported mesh
            # cannot), and a fresh, untinted copy of the scan takes its place.
            # Aside by a little under half the part's size (400 mm for the
            # 940 mm hydrant), so a 60 mm can and a metre of bollard both
            # share the frame with their scan.
            aside = round(max(height, 2 * analysis.get("maxRadiusMM", body_r)) * 0.43)
            mcp.os3d("feature.transform", {"bodyID": cad_id, "translation": [aside, 0, -aside]})
            reply = mcp.os3d("document.import", {"path": os.path.abspath(args.scan), "fileName": os.path.basename(args.scan)})
            scan2 = reply["bodyIDs"][0]
            mcp.os3d("item.select", {"ids": []})
            mcp.os3d("view.visualize", {"preset": "Studio", "background": "color", "backgroundColor": list(args.hook_background),
                                        "groundShadow": True, "panel": False})
            mcp.os3d("command.run", {"id": "view.isometric"})
            mcp.os3d("command.run", {"id": "view.fit"})
            hold(1.6)
            beats[-1]["ready"] = rec.now()
            turn(20.0)
            mcp.os3d("view.visualize", {"off": True})

            beat("end", "")
            end = rec.now()
        finally:
            rec.stop()
            if control:
                control.finish()
                try:
                    test.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    test.kill()
                control.server.shutdown()

    timeline = {"beats": beats, "end": end, "valid": bool(valid),
                "accuracy": {"overallIoU": report["overallIoU"],
                             "views": {o["view"]: o["iou"] for o in report["overlays"]},
                             "referenceToModel": report["referenceToModel"], "modelToReference": report["modelToReference"],
                             "summary": report["summary"], "calls": modelling_calls(mcp.calls)}}
    with open(os.path.join(args.out, "timeline.json"), "w") as f:
        json.dump(timeline, f, indent=1)
    print("take %.1f s, %d MCP calls -> %s" % (end, len(mcp.calls), os.path.join(args.out, "take.mov")))


# ----------------------------------------------------------------------------- narration

def script_for(timeline, title_say, scan_name, spec=None):
    a = timeline["accuracy"]
    r2m = a["referenceToModel"]
    views = a["views"]
    spec = spec or {}
    numbers = {"iou": a["overallIoU"] * 100, "calls": a["calls"], "mean": a["modelToReference"]["meanMM"],
               "label": spec.get("label", "hydrant").lower()}
    lines = {
        "title": title_say,
        "import": "The scan comes straight into OpenShape 3D as a mesh, texture and all.",
        "revolve": "One sketch on the scan's own axis, one revolve — the barrel, the flanges, the bonnet.",
        "boss1": "Each nozzle is read off the scan as a profile of its own, revolved, and unioned into the body.",
        "body1": "Every other body of revolution is found on its own axis from the scan's normals — read off the scan "
                 "on that axis, revolved, and unioned in.",
        "body2": "",
        "body3": "",
        "body4": "",
        "boss2": "",
        "boss3": "",
        "boss4": "",
        "check": "It's a valid solid, every step in the history, ready to export as STEP or STL.",
        "accuracy": "Then the app grades its own work: Views, Accuracy Report. The scan is the reference, the solid is the model — "
                    "compare, and it lays the silhouettes over each other and measures every point. {:.0f} percent overlap.".format(
            a["overallIoU"] * 100),
        "deviation": "And it shows you where, on the scan itself: blue where the model is missing material, orange where it "
                     "has too much, grey within tolerance.",
        "report": "Every run also writes a report: the three orthographic silhouettes — the scan filled in blue under the "
                  "model's outline — and the distance from every sampled point, both ways.",
        "numbers": "A phone scan to a parametric model in {} calls, within {:.0f} millimetres on average.".format(
            a["calls"], a["modelToReference"]["meanMM"]),
        "outro": "OpenShape 3D is open source.",
    }
    for key, line in spec.get("say", {}).items():
        lines[key] = line.format(**numbers) if line else ""
    return lines


def gcloud_token():
    try:
        out = subprocess.run(["gcloud", "auth", "print-access-token"], capture_output=True, text=True, timeout=30)
        token = out.stdout.strip()
        return token if out.returncode == 0 and token else None
    except Exception:  # noqa: BLE001
        return None


def google_post(url, body, headers, timeout=180):
    """POST JSON to a Google API through curl: this Mac's Python cannot verify
    Google's certificate chain (urllib: CERTIFICATE_VERIFY_FAILED), curl can.
    The headers (a bearer token or an API key) travel in a file, not on the
    command line, so they never show in a process list."""
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(body, f)
        payload = f.name
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(headers + ["Content-Type: application/json"]) + "\n")
        header_file = f.name
    try:
        out = subprocess.run(["curl", "-s", "-m", str(timeout), "-X", "POST", "-H", "@" + header_file,
                              "--data-binary", "@" + payload, url], capture_output=True, text=True, check=True)
    finally:
        os.remove(payload)
        os.remove(header_file)
    reply = json.loads(out.stdout)
    if "error" in reply:
        raise RuntimeError(reply["error"].get("message", str(reply["error"]))[:200])
    return reply


def vertex_post(url, body, token, timeout=180):
    return google_post(url, body, ["Authorization: Bearer " + token], timeout)


GEMINI_KEY_FILE = os.path.expanduser("~/.config/openshape3d/gemini-api.key")


def gemini_api_key():
    """The Gemini Developer API key: `GEMINI_API_KEY`, else the key file
    (mode 600, outside every repo). None means Vertex AI with gcloud."""
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if key:
        return key
    try:
        with open(GEMINI_KEY_FILE) as f:
            return f.read().strip() or None
    except OSError:
        return None


def gemini_tts(text, path, voice, project, region, model="gemini-3.8-flash-tts"):
    """Gemini TTS; raw 24 kHz PCM → the given path (m4a). With a Developer
    API key (AI Studio) the model comes from generativelanguage — its
    catalog (2026-10-21) has gemini-3.8-flash-tts, gemini-3.8-flash-lite-tts,
    gemini-3.1-flash-tts-preview, gemini-2.5-pro-preview-tts; otherwise
    Vertex AI with the gcloud login, whose catalog stops at
    gemini-3.1-flash-tts-preview (us-central1) and gemini-2.5-pro-tts."""
    body = {"contents": [{"role": "user", "parts": [{"text": text}]}],
            "generationConfig": {"responseModalities": ["AUDIO"],
                                 "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}}}}
    key = gemini_api_key()
    if key:
        url = "https://generativelanguage.googleapis.com/v1beta/models/{m}:generateContent".format(m=model)
        reply = google_post(url, body, ["x-goog-api-key: " + key], timeout=120)
    else:
        token = gcloud_token()
        if not token:
            raise RuntimeError("no Gemini API key and no gcloud access token (run `gcloud auth login`)")
        url = ("https://{r}-aiplatform.googleapis.com/v1/projects/{p}/locations/{r}/publishers/google/models/"
               "{m}:generateContent").format(r=region, p=project, m=model)
        reply = vertex_post(url, body, token, timeout=120)
    part = reply["candidates"][0]["content"]["parts"][0]["inlineData"]
    mime = part.get("mimeType", "audio/L16;codec=pcm;rate=24000")
    data = base64.b64decode(part["data"])
    if mime.lower().startswith("audio/wav"):
        # The 3.8 models answer with a WAV container; ffmpeg reads it as is.
        raw = path + ".wav"
        with open(raw, "wb") as f:
            f.write(data)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-c:a", "aac", "-b:a", "128k", path], check=True)
    else:
        # Raw 16-bit PCM at the rate the mime type names (the 2.5 and 3.1 models).
        rate = 24000
        for piece in mime.split(";"):
            if piece.strip().startswith("rate="):
                rate = int(piece.strip()[5:])
        raw = path + ".pcm"
        with open(raw, "wb") as f:
            f.write(data)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(rate), "-ac", "1", "-i", raw,
                        "-c:a", "aac", "-b:a", "128k", path], check=True)
    os.remove(raw)


def edge_tts(text, path, voice="en-US-AndrewMultilingualNeural", rate="-2%"):
    import edge_tts as et
    mp3 = path + ".mp3"
    for attempt in range(3):
        try:
            asyncio.run(et.Communicate(text, voice, rate=rate).save(mp3))
            break
        except Exception as problem:  # noqa: BLE001 — the service drops a line now and then ("No audio was received")
            if attempt == 2:
                raise
            print("edge-tts failed (%s); trying again" % str(problem)[:80], flush=True)
            time.sleep(3.0)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", mp3, "-c:a", "aac", "-b:a", "128k", path], check=True)
    os.remove(mp3)


def narrate(lines, cache_dir, backend, gemini_voice, project, region, gemini_model="gemini-3.8-flash-tts"):
    os.makedirs(cache_dir, exist_ok=True)
    clips = {}
    used = backend
    for key, text in lines.items():
        if not text:
            continue
        stamp = hashlib.sha1((used + gemini_model + gemini_voice + text).encode()).hexdigest()[:10]
        out = os.path.join(cache_dir, "%s-%s.m4a" % (key, stamp))
        trimmed = out[:-4] + "-trim.m4a"
        if not os.path.exists(trimmed):
            if not os.path.exists(out):
                if used == "gemini":
                    # A rate limit is not an outage: wait and try again (the
                    # Developer API's free tier allows a few requests a
                    # minute, and a film has a dozen lines). Only when the
                    # model itself is out of reach does the fallback voice
                    # take over — and then for every line, so the film never
                    # mixes two voices.
                    attempts, error = 0, None
                    while attempts < 6:
                        try:
                            gemini_tts(text, out, gemini_voice, project, region, gemini_model)
                            error = None
                            # Pace the next line: a burst of a dozen requests
                            # trips the Developer API's per-minute limit.
                            time.sleep(8)
                            break
                        except Exception as problem:  # noqa: BLE001
                            error = problem
                            message = str(problem)
                            if "quota" not in message.lower() and "429" not in message and "rate" not in message.lower():
                                break
                            attempts += 1
                            wait = 20 * attempts
                            print("Gemini TTS rate-limited on %s (%s); waiting %d s" % (key, message[:80], wait))
                            time.sleep(wait)
                    if error is not None:
                        if clips:
                            raise RuntimeError("Gemini TTS failed on %s after earlier lines succeeded (%s); "
                                               "try again later rather than mix voices" % (key, str(error)[:160]))
                        print("Gemini TTS unavailable (%s); using the edge-tts voice" % str(error)[:120])
                        used = "edge"
                        stamp = hashlib.sha1((used + gemini_voice + text).encode()).hexdigest()[:10]
                        out = os.path.join(cache_dir, "%s-%s.m4a" % (key, stamp))
                        trimmed = out[:-4] + "-trim.m4a"
                        if not os.path.exists(out):
                            edge_tts(text, out)
                else:
                    edge_tts(text, out)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", out, "-af",
                            "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.08,"
                            "areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.12,areverse,"
                            "loudnorm=I=-16:TP=-1.5", "-ar", "48000", "-c:a", "aac", "-b:a", "128k", trimmed], check=True)
        seconds = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", trimmed],
                                       capture_output=True, text=True).stdout.strip())
        clips[key] = {"path": trimmed, "seconds": seconds}
    return clips, used


# ----------------------------------------------------------------------------- music

def lyria_music(path, project, region, prompt):
    token = gcloud_token()
    if not token:
        raise RuntimeError("no gcloud access token")
    url = ("https://{r}-aiplatform.googleapis.com/v1/projects/{p}/locations/{r}/publishers/google/models/"
           "lyria-002:predict").format(r=region, p=project)
    body = {"instances": [{"prompt": prompt, "negative_prompt": "vocals, lyrics, distortion"}], "parameters": {"sample_count": 1}}
    reply = vertex_post(url, body, token, timeout=180)
    pred = reply["predictions"][0]
    data = base64.b64decode(pred.get("bytesBase64Encoded") or pred.get("audioContent"))
    wav = path + ".wav"
    with open(wav, "wb") as f:
        f.write(data)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "aac", "-b:a", "160k", path], check=True)
    os.remove(wav)


def generated_music(path, seconds, bpm=104, seed=3):
    """A light, upbeat bed: a four-chord loop (I–V–vi–IV) on a soft synth
    pad with a plucked arpeggio and a gentle kick — enough to carry a demo
    when no licensed track is at hand."""
    sr = 44100
    rng = np.random.default_rng(seed)
    beat = 60.0 / bpm
    n = int(seconds * sr)
    tt = np.arange(n) / sr
    out = np.zeros(n)
    root = 220.0  # A3
    chords = [[0, 4, 7], [7, 11, 14], [9, 12, 16], [5, 9, 12]]   # A, E, F#m, D
    bar = 4 * beat

    def note(freq, start, length, amp, kind):
        i0 = int(start * sr)
        i1 = min(int((start + length) * sr), n)
        if i1 <= i0:
            return
        t = np.arange(i1 - i0) / sr
        env = np.minimum(1, t / 0.02) * np.exp(-t / (length * (0.9 if kind == "pad" else 0.3)))
        if kind == "pad":
            wave = 0.5 * np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(2 * np.pi * freq * 2 * t) * np.exp(-t * 2)
        else:
            wave = np.sign(np.sin(2 * np.pi * freq * t)) * 0.3 + 0.7 * np.sin(2 * np.pi * freq * t)
            wave *= np.exp(-t * 6)
        out[i0:i1] += amp * env * wave

    k = 0
    total_bars = int(seconds / bar) + 1
    for b in range(total_bars):
        chord = chords[b % 4]
        start = b * bar
        for semi in chord:
            note(root * 2 ** (semi / 12) / 2, start, bar, 0.09, "pad")
            note(root * 2 ** (semi / 12), start, bar, 0.05, "pad")
        # Arpeggio: eighth notes over the chord, with a little variation.
        for e in range(8):
            semi = chord[(e + (b % 2)) % 3] + (12 if e % 3 == 2 else 0)
            if rng.random() < 0.85:
                note(root * 2 ** (semi / 12) * 2, start + e * beat / 2, beat * 0.45, 0.07, "pluck")
        # Kick on 1 and 3, soft.
        for q in (0, 2):
            i0 = int((start + q * beat) * sr)
            t = np.arange(min(int(0.18 * sr), n - i0)) / sr
            if len(t):
                out[i0:i0 + len(t)] += 0.25 * np.sin(2 * np.pi * (55 + 60 * np.exp(-t * 30)) * t) * np.exp(-t * 18)
        k += 1
    # Fade in / out, soft limit.
    fade = int(1.5 * sr)
    out[:fade] *= np.linspace(0, 1, fade)
    out[-fade:] *= np.linspace(1, 0, fade)
    out = np.tanh(out * 1.6) * 0.8
    wav = path + ".wav"
    import wave
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((out * 32767).astype(np.int16).tobytes())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "aac", "-b:a", "160k", path], check=True)
    os.remove(wav)


# ----------------------------------------------------------------------------- compose

def card(path, title, lines, foot="", accent=(230, 72, 48)):
    from PIL import Image, ImageDraw, ImageFont

    def font(size, bold=False):
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=1 if bold else 0)

    im = Image.new("RGB", (W, H), (248, 247, 244))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 18, H], fill=accent)
    y = 150
    for i, word in enumerate(title):
        d.text((110, y), word, font=font(84, True), fill=(28, 32, 40))
        y += 104
    y += 30
    for label, value in lines:
        if label:
            d.text((110, y), label.upper(), font=font(24), fill=(120, 128, 140))
            y += 34
        d.text((110, y), value, font=font(46, True), fill=(28, 32, 40))
        y += 86
    if foot:
        d.text((110, H - 110), foot, font=font(28), fill=(120, 128, 140))
    im.save(path)


def title_overlay(path, title_lines, subtitle, size=78):
    """A band over footage: large lines and a subtitle under them — the
    title at the start, the numbers and the credits at the end."""
    from PIL import Image, ImageDraw, ImageFont
    big = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=1)
    small = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 34, index=0)
    pad = 36
    line_h = int(size * 1.13)
    h = pad * 2 + line_h * len(title_lines) + 54
    probe = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    w = int(min(W - 112, max([probe.textlength(t, font=big) for t in title_lines]
                             + [probe.textlength(subtitle, font=small)]) + 2 * pad))
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=26, fill=(20, 24, 32, 205), outline=(255, 255, 255, 48), width=2)
    y = pad - 8
    for line in title_lines:
        d.text((pad, y), line, font=big, fill=(255, 255, 255, 255))
        y += line_h
    d.text((pad, y + 6), subtitle, font=small, fill=(200, 208, 220, 255))
    im.save(path)


def caption(path, text, sub=""):
    from PIL import Image, ImageDraw, ImageFont
    font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 44, index=1)
    small = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 28, index=0)
    pad = 28
    probe = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    tw = probe.textlength(text, font=font)
    sw = probe.textlength(sub, font=small) if sub else 0
    w = int(max(tw, sw) + 2 * pad)
    h = 44 + 2 * pad + (40 if sub else 0)
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=22, fill=(20, 24, 32, 215), outline=(255, 255, 255, 48), width=2)
    d.text((pad, pad - 6), text, font=font, fill=(255, 255, 255, 255))
    if sub:
        d.text((pad, pad + 48), sub, font=small, fill=(190, 198, 210, 255))
    im.save(path)


CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAPER = (250, 248, 243)


def still_clip(png, path, seconds, vf):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-framerate", str(FPS), "-i", png, "-t", "%.2f" % seconds,
                    "-vf", vf, "-r", str(FPS), "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", path],
                   check=True)
    return path


def report_page_clip(html, work, seconds):
    """The report page itself, rendered by headless Chrome at a 1280-px
    window with a 1.5× device scale (crisp text at 1920), scrolling from its
    title down to the three overlays."""
    if not os.path.exists(CHROME):
        print("no Chrome at %s; the report page is not filmed" % CHROME)
        return None
    png = os.path.join(work, "report-page.png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1.5",
                    "--window-size=1280,2200", "--screenshot=" + png, "file://" + os.path.abspath(html)],
                   capture_output=True, check=True)
    from PIL import Image
    ih = Image.open(png).size[1]
    # Down to the overlays grid (the heading sits about 820 px down at
    # this scale) and no further; an ease-in-out scroll that settles there
    # for the last third.
    travel = max(0, min(ih - H, 820))
    y = "(%d)*(0.5-0.5*cos(PI*min(1,t/%.2f)))" % (travel, seconds * 0.68)
    return still_clip(png, os.path.join(work, "report-0.mp4"), seconds, "crop=%d:%d:0:'%s'" % (W, H, y))


def overlay_triptych(overlays, views, path):
    """The three orthographic overlays on one sheet, each captioned with its
    overlap — front, top, right — and the legend the report uses."""
    from PIL import Image, ImageDraw, ImageFont

    def font(size, bold=False):
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size, index=1 if bold else 0)

    im = Image.new("RGB", (W, H), PAPER)
    d = ImageDraw.Draw(im)
    d.text((72, 48), "Orthographic overlays", font=font(58, True), fill=(28, 32, 40))
    lx = 72
    for swatch, label in (((86, 140, 214), "scan silhouette"), ((232, 132, 50), "model outline"), ((190, 192, 196), "where they agree")):
        d.rounded_rectangle([lx, 134, lx + 26, 160], radius=6, fill=swatch)
        d.text((lx + 38, 128), label, font=font(30), fill=(90, 96, 108))
        lx += 38 + int(d.textlength(label, font=font(30))) + 48
    top, bottom = 196, H - 120
    boxes = []
    for view in ("front", "top", "right"):
        src = os.path.join(overlays, view + ".jpg")
        if not os.path.exists(src):
            continue
        pic = Image.open(src).convert("RGB")
        # The overlay carries its own small header and legend; crop them.
        pic = pic.crop((0, int(pic.height * 0.035), pic.width, pic.height))
        scale = (bottom - top) / pic.height
        boxes.append((view, pic, int(pic.width * scale), bottom - top))
    gap = 64
    total = sum(w for _, _, w, _ in boxes) + gap * (len(boxes) - 1)
    scale_all = min(1.0, (W - 144) / max(total, 1))
    x = (W - int(total * scale_all)) // 2
    for view, pic, w, h in boxes:
        w2, h2 = int(w * scale_all), int(h * scale_all)
        y = top + (bottom - top - h2) // 2
        im.paste(pic.resize((w2, h2), Image.LANCZOS), (x, y))
        d.rectangle([x - 1, y - 1, x + w2, y + h2], outline=(214, 210, 200))
        label = "%s · %.0f%% overlap" % (view.capitalize(), views.get(view, 0) * 100)
        d.text((x + (w2 - d.textlength(label, font=font(34, True))) // 2, bottom + 26), label, font=font(34, True), fill=(28, 32, 40))
        x += w2 + int(gap * scale_all)
    im.save(path)
    return path


def overlay_pan_clip(overlays, view, work, seconds):
    """One overlay filling the frame's width, panned top to bottom, so the
    blue (scan only) and orange (model only) margins read at full size."""
    src = os.path.join(overlays, view + ".jpg")
    if not os.path.exists(src):
        return None
    from PIL import Image
    pic = Image.open(src).convert("RGB")
    pic = pic.crop((0, int(pic.height * 0.035), pic.width, pic.height))
    # Fit to the frame's width with paper margins, on the report's paper.
    inner = int(W * 0.72)
    pic = pic.resize((inner, int(pic.height * inner / pic.width)), Image.LANCZOS)
    page = Image.new("RGB", (W, pic.height + 160), PAPER)
    page.paste(pic, ((W - inner) // 2, 80))
    png = os.path.join(work, "report-%s.png" % view)
    page.save(png)
    travel = max(0, page.height - H)
    y = "(%d)*(0.5-0.5*cos(PI*min(1,t/%.2f)))" % (travel, seconds)
    return still_clip(png, os.path.join(work, "report-%s.mp4" % view), seconds, "crop=%d:%d:0:'%s'" % (W, H, y))


def ffmpeg_watched(cmd, timeout, tries=2):
    """Run an ffmpeg command under a watchdog, and once more if it stalls.

    ffmpeg 9's threaded pipeline can deadlock on the final mux — a graph of
    a dozen looping picture inputs (the caption cards) over the take: every
    thread then waits in sch_wait / tq_receive at 0 % CPU and the mp4 never
    gets its index. One film in eight hit it; the second try has not.
    """
    for attempt in range(1, tries + 1):
        try:
            subprocess.run(cmd, check=True, timeout=timeout)
            return
        except subprocess.TimeoutExpired:
            print("ffmpeg stalled for %.0f s writing %s (attempt %d of %d)%s" % (
                timeout, os.path.basename(cmd[-1]), attempt, tries, "; trying again" if attempt < tries else ""), flush=True)
    raise RuntimeError("ffmpeg stalled %d times writing %s" % (tries, os.path.basename(cmd[-1])))


def compose(args):
    with open(os.path.join(args.out, "timeline.json")) as f:
        tl = json.load(f)
    beats = tl["beats"]
    acc = tl["accuracy"]
    work = os.path.join(args.out, "work")
    os.makedirs(work, exist_ok=True)
    # The simulator records a frame only when the screen changes, so a still
    # moment has no frames at all and a cut through it comes out empty.
    # Resample to a constant 30 fps once, then cut from that. A retake leaves
    # the old copy behind, so rebuild it whenever the take is the newer file
    # (the truck wheel was once cut from a copy of the take before its retake).
    take = os.path.join(work, "take-cfr.mp4")
    source = os.path.join(args.out, "take.mov")
    if not os.path.exists(take) or os.path.getmtime(take) < os.path.getmtime(source):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", source,
                        "-vf", "fps=%d" % FPS, "-fps_mode", "cfr", "-an", "-c:v", "libx264", "-preset", "veryfast",
                        "-crf", "16", "-pix_fmt", "yuv420p", take], check=True)

    # 1. Narration first: it sets how long each beat may hold.
    lines = script_for(tl, args.title_say, "", args.spec)
    credit = (args.spec or {}).get("credit", "Scan: CC-BY laanlabs on Sketchfab")
    clips, backend = narrate(lines, os.path.join(args.out, "tts"), args.tts, args.gemini_voice, args.project, args.region,
                             args.gemini_model)
    print("narration:", backend, args.gemini_model if backend == "gemini" else "")

    # 2. Cut list: every beat of the take, trimmed to its narration (plus a
    #    beat of air), with a title card before and cards after.
    segs = []
    hook = None
    for i, b in enumerate(beats[:-1]):
        start, end = b["start"], beats[i + 1]["start"]
        if b["id"] == "hook":
            # Opens and closes the film: scan beside model, turning. The
            # opener runs as long as the title line; the ending carries the
            # numbers and the credits.
            say = clips.get("title")
            first = b.get("ready", start + 2.0)
            open_len = (say["seconds"] + 1.2) if say else 6.0
            close_len = (clips["numbers"]["seconds"] if "numbers" in clips else 4.0) + \
                        (clips["outro"]["seconds"] if "outro" in clips else 3.0) + 2.4
            hook = {"id": "hook", "caption": "", "pieces": [(first, min(end, first + open_len))], "say": say}
            ender = {"id": "ender", "caption": "", "pieces": [(max(first, end - close_len), end)], "say": None}
            continue
        say = clips.get(b["id"])
        want = (say["seconds"] + 0.8) if say else (end - start)
        # A beat may name the moment its picture is ready (the scan framed
        # after the import); the cut starts there.
        start = max(start, b.get("ready", start))
        # Keep the whole beat if it is short; otherwise show its first part
        # and its last part, so the result is always seen.
        length = end - start
        if b["id"] == "accuracy" and "computeStart" in b and "computeEnd" in b:
            # Opened by touch: Compare is tapped at `computeStart`, the
            # results appear at `computeEnd`; the wait between is cut.
            pieces = [(start, b["computeStart"] + 1.0), (max(start, b["computeEnd"] - 0.2), end)]
        elif b["id"] == "accuracy":
            # The sheet opens (2.5 s), then the result — the computing wait
            # in between is cut out.
            wait = b.get("computeSeconds", 16.0) + 3.0
            pieces = [(start, start + 2.5), (min(start + wait, end - 1), end)] if end - start > wait + 2 else [(start, end)]
        elif b["id"] == "accuracy-open":
            pieces = [(start, end)]
        elif b["id"] == "check":
            pieces = [(start, min(end, start + want))]
        elif length <= want + 0.5:
            pieces = [(start, min(end, start + want))]
        else:
            pieces = [(start, start + want * 0.55), (end - want * 0.45, end)]
        seg = {"id": b["id"], "caption": b["caption"], "pieces": pieces, "say": say}
        # A beat whose footage is shorter than its line is slowed to fit
        # (up to 1.6×; the camera is turning, nothing else moves), so the
        # next beat's line never starts over this one. The report beat's
        # line starts on the menu beat before it and is not measured here.
        have = sum(q - p for p, q in pieces)
        if say and b["id"] != "accuracy" and have > 0 and have < want:
            seg["stretch"] = min(want / have, 1.6)
        segs.append(seg)

    # Source clips at 1920×1080: the take is the iPad's screen; crop to 16:9
    # from the top (the toolbar) down, then scale.
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                            "-of", "csv=p=0", take], capture_output=True, text=True).stdout.strip().split(",")
    sw, sh = int(probe[0]), int(probe[1])
    # `simctl io recordVideo` writes the native (portrait) framebuffer with
    # a landscape device's picture turned inside it, status bar down the
    # right edge; a quarter turn counter-clockwise stands it up.
    pre = ""
    if sw < sh and args.landscape:
        pre = "transpose=2,"
        sw, sh = sh, sw
    def crop_for(seg_id):
        if sw < sh or seg_id == "accuracy":
            # A portrait screen, or the tall report sheet: the whole screen
            # on a blurred copy of itself.
            return None
        if seg_id in ("hook", "ender"):
            # The opening and the ending: closer on the pair of hydrants,
            # which a fit of two bodies leaves small (still a downscale),
            # and the pair right of centre so the title band at the lower
            # left sits beside them, not on them.
            w = int(sw * 0.74) & ~1
            h = int(w * 9 / 16) & ~1
            x = max(0, (sw - w) // 2 - int(sw * 0.09))
            y = max(0, min(sh - h, int(sh * 0.50) - h // 2))
            return pre + "crop=%d:%d:%d:%d" % (w, h, x, y)
        crop_h = int(sw * 9 / 16)
        spare = max(0, sh - crop_h)
        # 16:9 from near the top, so the app's toolbar stays in frame.
        return pre + "crop=%d:%d:0:%d" % (sw, min(crop_h, sh), min(spare, 60))

    clip_paths = []
    if hook:
        segs.insert(0, hook)
    report_clips = []
    if args.overlays and os.path.isdir(args.overlays):
        # The report beat: as long as its narration, split across the page
        # scroll, the three overlays and the front view close up.
        say = clips.get("report")
        span = (say["seconds"] + 2.0) if say else 12.0
        page = report_page_clip(args.report, work, span * 0.36) if args.report else None
        if page:
            report_clips.append(("report", "The accuracy report · one HTML file", page))
        sheet = overlay_triptych(args.overlays, acc["views"], os.path.join(work, "report-sheet.png"))
        # A slow push in on the sheet (zoompan wants an oversampled source to stay smooth).
        tri = still_clip(sheet, os.path.join(work, "report-1.mp4"), span * (0.34 if page else 0.5),
                         "scale=%d:%d,zoompan=z='1+0.0006*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=%dx%d:fps=%d" % (
                             W * 2, H * 2, W, H, FPS))
        report_clips.append(("report-sheet", "", tri))
        pan = overlay_pan_clip(args.overlays, "front", work, span * (0.30 if page else 0.5))
        if pan:
            report_clips.append(("report-front", "Front view · the scan in blue, the model's outline in orange", pan))
    if hook:
        segs.append(ender)
    for seg in segs:
        if seg["id"] == "ender" and report_clips:
            for sid, cap, path in report_clips:
                length = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                                              capture_output=True, text=True).stdout.strip())
                clip_paths.append(({"id": sid, "caption": cap, "pieces": [(0, length)], "say": clips.get("report") if sid == "report" else None},
                                   path, length))
        for j, (a, b) in enumerate(seg["pieces"]):
            path = os.path.join(work, "%s-%d.mp4" % (seg["id"], j))
            crop = crop_for(seg["id"])
            vf = (crop + ",scale=%d:%d" % (W, H)) if crop else \
                pre + "split[bg][fg];[bg]scale=%d:%d,boxblur=30:5,eq=brightness=-0.15[bgs];[fg]scale=-2:%d[fgs];[bgs][fgs]overlay=(W-w)/2:0" % (W, H, H)
            # `-ss` and `-t` before the input seek and bound the SOURCE; a
            # stretched beat slows those frames with setpts and the output
            # `-t` is the longer length (an input `-to` is not honoured by
            # this ffmpeg and the clips ran long).
            k = seg.get("stretch", 1.0)
            if k > 1.0:
                vf += ",setpts=PTS*%.3f" % k
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", "%.3f" % a, "-t", "%.3f" % (b - a), "-i", take,
                            "-t", "%.3f" % ((b - a) * k), "-an", "-vf", vf, "-r", str(FPS), "-c:v", "libx264",
                            "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", path], check=True)
            probe_len = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                                       capture_output=True, text=True).stdout.strip()
            try:
                real = float(probe_len)
            except ValueError:
                sys.exit("an empty clip for beat %s (%.1f–%.1f s): the take is shorter than its timeline?" % (seg["id"], a, b))
            clip_paths.append((seg, path, real))

    # 3. Cards.
    r2m, m2r = acc["referenceToModel"], acc["modelToReference"]
    per_view = "   ".join("%s %.0f%%" % (k, v * 100) for k, v in acc["views"].items())
    card(os.path.join(work, "title.png"), args.title.split("|"), [("", args.subtitle)], "OpenShape 3D  ·  Model Context Protocol")
    card(os.path.join(work, "numbers.png"), ["By the numbers"], [
        ("Silhouette overlap, mean of three views", "%.1f%%   (%s)" % (acc["overallIoU"] * 100, per_view)),
        ("Model surface to scan", "mean %.1f mm · 95%% within %.1f mm" % (m2r["meanMM"], m2r["p95MM"])),
        ("Scan surface to model", "mean %.1f mm · 95%% within %.1f mm" % (r2m["meanMM"], r2m["p95MM"])),
        ("Built by an assistant over MCP", "%d calls, one parametric model" % acc["calls"]),
    ], credit)
    card(os.path.join(work, "outro.png"), ["OpenShape 3D", "is open source"], [
        ("", "app.openshape3d.com"), ("", "github.com/laanlabs/openshape3d")], "Built with Claude over MCP")

    def still(name, seconds):
        path = os.path.join(work, name + ".mp4")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-i", os.path.join(work, name + ".png"),
                        "-t", "%.2f" % seconds, "-r", str(FPS), "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                        "-pix_fmt", "yuv420p", path], check=True)
        return path

    def hold_for(key, floor):
        return max(floor, clips[key]["seconds"] + 0.9) if key in clips else floor

    sequence = [] if hook else [("title", still("title", hold_for("title", 4.0)), hold_for("title", 4.0))]
    for seg, path, length in clip_paths:
        sequence.append((seg["id"], path, length))
    if not hook:
        sequence.append(("numbers", still("numbers", hold_for("numbers", 5.0)), hold_for("numbers", 5.0)))
        sequence.append(("outro", still("outro", hold_for("outro", 3.5)), hold_for("outro", 3.5)))

    # 4. Concatenate the picture, then captions, narration and music in one pass.
    concat = os.path.join(work, "concat.txt")
    with open(concat, "w") as f:
        for _, path, _ in sequence:
            f.write("file '%s'\n" % path)
    silent = os.path.join(work, "picture.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", concat, "-c", "copy", silent], check=True)

    # Where each segment starts in the film.
    t = 0.0
    starts = {}
    for sid, _, length in sequence:
        starts.setdefault(sid, t)
        t += length
    total = t
    if hook:
        # The title line is spoken over the opening footage.
        starts["title"] = starts["hook"]

    # Captions: one pill per beat, shown over its clips.
    caption_inputs, overlays = [], []
    seen = set()
    if hook:
        png = os.path.join(work, "cap-hook.png")
        title_overlay(png, args.title.split("|"), args.subtitle)
        caption_inputs.append(png)
        overlays.append(("hook", starts["hook"], starts["hook"] + sum(l for sg, _, l in clip_paths if sg["id"] == "hook")))
        # The ending: the numbers while their line is read, then the credits.
        ender_start = starts["ender"]
        ender_len = sum(l for sg, _, l in clip_paths if sg["id"] == "ender")
        numbers_len = (clips["numbers"]["seconds"] + 1.0) if "numbers" in clips else 4.0
        png_n = os.path.join(work, "cap-numbers.png")
        title_overlay(png_n, ["%.0f%% silhouette overlap · %.0f mm mean deviation" % (acc["overallIoU"] * 100, m2r["meanMM"]),
                              "%d MCP calls · one parametric model" % acc["calls"]],
                      "front %.0f%% · top %.0f%% · right %.0f%%" % tuple(acc["views"].get(k, 0) * 100 for k in ("front", "top", "right")),
                      size=56)
        caption_inputs.append(png_n)
        overlays.append(("ender", ender_start, ender_start + numbers_len))
        png_o = os.path.join(work, "cap-outro.png")
        title_overlay(png_o, ["OpenShape 3D is open source"], "app.openshape3d.com  ·  github.com/laanlabs/openshape3d  ·  " + credit[0].lower() + credit[1:], size=64)
        caption_inputs.append(png_o)
        overlays.append(("outro-overlay", ender_start + numbers_len, ender_start + ender_len))
        # Narration for the ending rides on the ender segment.
        starts["numbers"] = ender_start
        starts["outro"] = ender_start + numbers_len
    for seg, path, length in clip_paths:
        if seg["id"] in seen or not seg["caption"]:
            continue
        seen.add(seg["id"])
        png = os.path.join(work, "cap-%s.png" % seg["id"])
        caption(png, seg["caption"])
        caption_inputs.append(png)
        # Visible from the first clip of the beat to the end of its last clip.
        first = starts[seg["id"]]
        last = first + sum(l2 for sg2, _, l2 in clip_paths if sg2["id"] == seg["id"])
        overlays.append((seg["id"], first, last))

    print("captions:", [(sid, round(a, 1), round(b, 1)) for sid, a, b in overlays])
    inputs = ["-i", silent]
    filters = []
    vin = "[0:v]"
    for i, png in enumerate(caption_inputs):
        # Each looped picture is bounded to the film's length: an endless
        # input left ffmpeg running after the last frame was written.
        # One frame, not a looped stream: `overlay` holds a picture's last
        # frame for the rest of the film (its default eof_action), and a
        # dozen endlessly looping picture inputs are what deadlocked
        # ffmpeg 9's scheduler — twice in ten films, -nostdin or not.
        inputs += ["-i", png]
        sid, a, b = overlays[i]
        # Top-left over the viewport; bottom-left while the report sheet is
        # up, so the pill never sits on the sheet's title.
        y = "H-h-48" if sid in ("accuracy", "hook", "ender", "outro-overlay") or sid.startswith("report") else "40"
        filters.append("%s[%d:v]overlay=56:%s:enable='between(t,%.2f,%.2f)'[v%d]" % (vin, i + 1, y, a + 0.15, b - 0.15, i))
        vin = "[v%d]" % i
    video_out = vin

    # Narration at each segment's start; the report's line starts with the
    # menu that opens it, when the take has that beat. A line that would
    # still be running when the next one is due holds the next back by the
    # overlap and a breath: a long spec line costs a slightly later cue,
    # never two voices at once.
    if "accuracy-open" in starts:
        starts["accuracy"] = starts["accuracy-open"]
    cue, last_end, previous = {}, 0.0, None
    for sid in sorted((s for s in clips if s in starts), key=lambda s: starts[s]):
        due = starts[sid] + 0.25
        cue[sid] = max(due, last_end + 0.3) if previous else due
        if cue[sid] > due:
            print("the %s line waits %.1f s for the %s line to end" % (sid, cue[sid] - due, previous))
        last_end, previous = cue[sid] + clips[sid]["seconds"], sid
    spoken = sorted((cue[sid], cue[sid] + clips[sid]["seconds"], sid) for sid in cue)
    print("narration:", [(sid, round(a, 1), round(b, 1)) for a, b, sid in spoken])
    if spoken and spoken[-1][1] > total:
        print("WARNING: the %s line runs %.1f s past the end of the film" % (spoken[-1][2], spoken[-1][1] - total))
    n_caps = len(caption_inputs)
    aud_idx = n_caps + 1
    mix = []
    for sid, clip in clips.items():
        if sid not in starts:
            continue
        inputs += ["-i", clip["path"]]
        delay = int(cue[sid] * 1000)
        filters.append("[%d:a]adelay=%d|%d[n%d]" % (aud_idx, delay, delay, aud_idx))
        mix.append("[n%d]" % aud_idx)
        aud_idx += 1

    # Music: a bed under everything, ducked by a third.
    music = None
    if args.music == "lyria":
        try:
            music = os.path.join(work, "music.m4a")
            if not os.path.exists(music):
                lyria_music(music, args.project, args.region, args.music_prompt)
        except Exception as error:  # noqa: BLE001
            print("Lyria unavailable (%s); generating a bed" % str(error)[:120])
            music = None
    if args.music == "generated" or (args.music == "lyria" and music is None):
        music = os.path.join(work, "music-generated.m4a")
        if not os.path.exists(music):
            generated_music(music, total + 2)
    elif args.music not in ("lyria", "generated", "none"):
        music = args.music
    if music and args.music != "none":
        # Loop the bed to the film's length first: an endless `-stream_loop`
        # input into amix never signals its end, and the mux hangs.
        looped = os.path.join(work, "music-looped.m4a")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-stream_loop", "-1", "-i", music,
                        "-t", "%.2f" % (total + 1.0), "-c", "copy", looped], check=True)
        inputs += ["-i", looped]
        filters.append("[%d:a]volume=%.2f,atrim=0:%.2f,afade=t=out:st=%.2f:d=2.5[mus]" % (aud_idx, args.music_gain, total, total - 2.5))
        mix.append("[mus]")
    filters.append("".join(mix) + "amix=inputs=%d:normalize=0,alimiter=limit=0.95[aout]" % len(mix))

    out = os.path.join(args.out, args.name + ".mp4")
    ffmpeg_watched(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filters),
                    "-map", video_out, "-map", "[aout]", "-c:v", "libx264", "-preset", "medium", "-crf", "19",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-t", "%.2f" % total,
                    "-movflags", "+faststart", out], timeout=max(600.0, total * 8))
    sheet = os.path.join(args.out, "contact.png")
    rows = max(1, -(-int(total / 2 + 1) // 6))
    ffmpeg_watched(["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-i", out, "-vf", "fps=1/2,scale=320:-1,tile=6x%d" % rows,
                    "-frames:v", "1", sheet], timeout=300.0)
    print("wrote %s (%.1f s); narration %s; music %s; contact sheet %s" % (
        out, total, backend, "none" if not music else os.path.basename(music), sheet))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("take")
    t.add_argument("--scan", required=True)
    t.add_argument("--analysis", required=True)
    t.add_argument("--out", default="demo")
    t.add_argument("--port", type=int, default=8787)
    t.add_argument("--simulator", default="os3d-hydrant")
    t.add_argument("--tolerance", type=float, default=3.0)
    t.add_argument("--hook-background", type=float, nargs=3, default=[1, 1, 1], metavar=("R", "G", "B"),
                   help="the studio background behind the opening pair (0…1)")
    t.add_argument("--ui", action="store_true",
                   help="launch the app through TutorialTakeUITests and open the Accuracy Report by touch")
    t.add_argument("--control-port", type=int, default=8930, help="the UI test's control server (with --ui)")
    t.add_argument("--derived-data", default=None, help="xcodebuild -derivedDataPath for the UI test (with --ui)")
    t.add_argument("--spec", default=None, help="JSON: what the part is (label, colour, captions); see the top of this file")
    t.add_argument("--features", default=None, help="features.json (default: <part>/features/features.json beside the analysis)")
    c = sub.add_parser("compose")
    c.add_argument("--out", default="demo")
    c.add_argument("--spec", default=None, help="JSON: title, narration lines and credit for this part")
    c.add_argument("--name", default=None, help="the film's file name (default hydrant-demo, or the spec's)")
    c.add_argument("--title", default=None, help="title card lines, | between them")
    c.add_argument("--subtitle", default=None)
    c.add_argument("--title-say", default=None)
    c.add_argument("--tts", choices=["gemini", "edge"], default="gemini")
    c.add_argument("--gemini-voice", default="Charon")
    c.add_argument("--gemini-model", default="gemini-3.8-flash-tts",
                   help="a Gemini TTS model; with a Developer API key (GEMINI_API_KEY or ~/.config/openshape3d/gemini-api.key): "
                        "gemini-3.8-flash-tts, gemini-3.8-flash-lite-tts, gemini-3.1-flash-tts-preview; on Vertex AI: "
                        "gemini-3.1-flash-tts-preview, gemini-2.5-pro-tts, gemini-2.5-flash-tts")
    c.add_argument("--project", default="openshape3d")
    c.add_argument("--region", default="us-central1")
    c.add_argument("--music", default="lyria", help="lyria | generated | none | a file")
    c.add_argument("--music-prompt", default="bright instrumental synth groove, light drums, warm pads, optimistic, steady tempo, background music")
    c.add_argument("--music-gain", type=float, default=0.22)
    c.add_argument("--report", default=None, help="the run's HTML accuracy report, filmed scrolling (needs Chrome)")
    c.add_argument("--overlays", default=None, help="the run's overlays/ folder (front/top/right.jpg) for the report beat")
    c.add_argument("--landscape", action=argparse.BooleanOptionalAction, default=True,
                   help="the take was filmed on a landscape device (the recording needs a quarter turn)")
    args = ap.parse_args()
    if args.spec:
        with open(args.spec) as f:
            args.spec = json.load(f)
    if args.cmd == "take":
        take(args)
    else:
        spec = args.spec or {}
        args.name = args.name or spec.get("name", "hydrant-demo")
        args.title = args.title or spec.get("title", "From an iPhone scan|to a CAD model")
        args.subtitle = args.subtitle or spec.get("subtitle", "Built in OpenShape 3D by an assistant, over MCP")
        args.title_say = args.title_say or spec.get("titleSay",
            "A fire hydrant, scanned with an iPhone — turned into a CAD model inside OpenShape 3D by an assistant, over MCP.")
        compose(args)


if __name__ == "__main__":
    main()
