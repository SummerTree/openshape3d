#!/usr/bin/env python3
"""Narrated video of a scan-to-CAD run, rendered with Blender.

    python3 make_video.py --run run/ --scan scan.glb --out video/ [--title "…"] [--preview]

1. Narration: one clip per segment (edge-tts neural voice, cached by text;
   macOS `say` when offline), silence trimmed, so each segment lasts as long
   as its line plus a beat.
2. Heatmap: the scan coloured by its distance to the model (trimesh), as
   `run/heatmap.ply`, for the deviation segment.
3. Blender renders the frames (`blender_video.py`, EEVEE, 1920×1080, 30 fps).
4. ffmpeg assembles frames and narration into `out/<name>.mp4` and writes a
   contact sheet (`out/contact.png`) to review before publishing.

`--preview` renders one frame per segment instead of the whole film.
"""
import argparse
import asyncio
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BLENDER = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")
VOICE = os.environ.get("OS3D_VOICE", "en-US-AndrewMultilingualNeural")
RATE = os.environ.get("OS3D_VOICE_RATE", "-3%")


def script(summary, accuracy, title, scan_name):
    tol = accuracy["options"]["toleranceMM"]
    r2m = accuracy["referenceToModel"]
    n_bosses = len(summary.get("bosses", []))
    per_view = ", ".join("%s %.0f percent" % (o["view"], o["iou"] * 100) for o in accuracy["overlays"])
    return [
        {"id": "title", "min": 4.5,
         "say": "A fire hydrant, scanned with an iPhone, turned into a parametric CAD model by an assistant "
                "talking to OpenShape 3D over the Model Context Protocol."},
        {"id": "scan", "min": 8,
         "say": "The scan: {:,} triangles from a TrueDepth camera, with noise, holes, and no idea which way is up."
                .format(accuracy["referenceTriangles"])},
        {"id": "analysis", "min": 7,
         "say": "A script finds the axis of revolution, the radius at every height, and the {} nozzles that stand out from it."
                .format({1: "one", 2: "two", 3: "three", 4: "four"}.get(n_bosses, str(n_bosses)))},
        {"id": "mcp", "min": 9,
         "say": "Then the assistant drives the app through its one MCP tool: a sketch on the scan's own axis, "
                "a revolve, and each nozzle as a circle extruded and unioned into the body. Every call is an "
                "undoable feature in the app's history."},
        {"id": "build", "min": 8,
         "say": "The model takes shape in place, over the scan: the turned body first, then the nozzles and their caps."},
        {"id": "compare", "min": 7,
         "say": "Scan and model share one axis and one base, so they can be compared where they sit, "
                "with no registration step."},
        {"id": "heatmap", "min": 7,
         "say": "The app grades its own work. Each scan point is measured to the model: {:.0f} percent lie within "
                "{:g} millimetres, and ninety-five percent within {:.1f}.".format(
                    r2m["withinTolerance"] * 100, tol, r2m["p95MM"])},
        {"id": "overlays", "min": 8,
         "say": "And it draws the orthographic overlays: the scan's silhouette under the model's outline, "
                "front, top and right. Overlap: {}.".format(per_view)},
        {"id": "numbers", "min": 7,
         "say": "Overall, {:.0f} percent silhouette overlap, from {} MCP calls and {:.0f} seconds in the app."
                .format(accuracy["overallIoU"] * 100, summary.get("calls", 0), summary.get("secondsInApp", 0))},
        {"id": "outro", "min": 4.5,
         "say": "OpenShape 3D is open source, on the iPad, the Mac and the web."},
    ]


def transcript_lines(run, limit=14):
    """The calls that tell the story, from the client log: one line each."""
    path = os.path.join(run, "mcp_client_calls.jsonl")
    if not os.path.exists(path):
        return []
    picked = []
    seen_ops = set()
    for line in open(path):
        entry = json.loads(line)
        args = entry["arguments"]
        op = args.get("op", entry["name"])
        if op in ("screenshot", "command.run", "state", "health", "item.setHidden", "body.setMaterial", "view.visualize"):
            continue
        inner = args.get("args", {})
        short = {}
        for key in ("path", "fileName", "name", "origin", "seedPoint", "distance", "boolean", "radius",
                    "angleDegrees", "format", "reference", "model", "view", "tolerance"):
            if key in inner:
                value = inner[key]
                if isinstance(value, str) and len(value) > 24:
                    value = "…" + value[-20:]
                if isinstance(value, list):
                    value = [round(v, 1) if isinstance(v, float) else v for v in value]
                short[key] = value
        if op == "sketch.addEntities":
            kinds = {}
            for e in inner.get("entities", []):
                kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
            short = {"entities": ", ".join("%d %s" % (n, k) for k, n in kinds.items())}
        text = "os3d  %-22s %s" % (op, json.dumps(short, separators=(", ", ": "), ensure_ascii=False))
        if op in seen_ops and op not in ("feature.extrude", "accuracy.image"):
            continue
        seen_ops.add(op)
        picked.append(text[:120])
        if len(picked) >= limit:
            break
    return picked


def synthesize(segments, cache_dir):
    os.makedirs(cache_dir, exist_ok=True)
    try:
        import edge_tts
    except ImportError:
        edge_tts = None
    for seg in segments:
        key = hashlib.sha1((VOICE + RATE + seg["say"]).encode()).hexdigest()[:10]
        raw = os.path.join(cache_dir, "%s-%s.mp3" % (seg["id"], key))
        trimmed = os.path.join(cache_dir, "%s-%s-trim.m4a" % (seg["id"], key))
        if not os.path.exists(trimmed):
            if not os.path.exists(raw):
                done = False
                if edge_tts:
                    try:
                        asyncio.run(edge_tts.Communicate(seg["say"], VOICE, rate=RATE).save(raw))
                        done = os.path.getsize(raw) > 1000
                    except Exception as error:  # noqa: BLE001 — offline: fall back to the system voice
                        print("edge-tts failed (%s); using the system voice" % error)
                if not done:
                    aiff = raw[:-4] + ".aiff"
                    subprocess.run(["say", "-v", "Samantha", "-o", aiff, seg["say"]], check=True)
                    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", aiff, raw], check=True)
            # Trim leading/trailing silence, normalise, AAC.
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-af",
                            "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.1,"
                            "areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.15,areverse,"
                            "loudnorm=I=-16:TP=-1.5", "-ar", "48000", "-c:a", "aac", "-b:a", "128k", trimmed], check=True)
        seg["clip"] = trimmed
        seg["narration"] = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                                 "-of", "csv=p=0", trimmed], capture_output=True, text=True).stdout.strip())
        seg["seconds"] = max(seg["min"], seg["narration"] + 0.9)
    return segments


def heatmap(run, scan_path, out_path, tolerance):
    import numpy as np
    import trimesh
    scene = trimesh.load(scan_path, force="scene")
    placed = []
    for node in scene.graph.nodes_geometry:
        transform, geometry = scene.graph[node]
        g = scene.geometry[geometry]
        if isinstance(g, trimesh.Trimesh):
            placed.append(g.copy().apply_transform(transform))
    scan = trimesh.util.concatenate(placed) if len(placed) > 1 else placed[0]
    scan.apply_scale(1000)                       # glTF metres → mm, the app's world
    summary = json.load(open(os.path.join(run, "summary.json")))
    model = trimesh.load(summary["exports"]["stl"]["path"], force="mesh")   # mm, Y up as the app exports with up=y
    closest, distance, _ = trimesh.proximity.closest_point(model, scan.vertices)
    # Green within tolerance, through yellow to red at three tolerances.
    t = np.clip(distance / (3 * tolerance), 0, 1)[:, None]
    green = np.array([0.24, 0.66, 0.32])
    yellow = np.array([0.95, 0.80, 0.22])
    red = np.array([0.86, 0.20, 0.16])
    rgb = np.where(t < 0.5, green + (yellow - green) * (t * 2), yellow + (red - yellow) * ((t - 0.5) * 2))
    colors = np.concatenate([rgb, np.ones((len(t), 1))], axis=1)
    scan.visual.vertex_colors = (colors * 255).astype(np.uint8)
    scan.apply_scale(0.001)                      # back to metres for Blender
    scan.export(out_path)
    return {"meanMM": float(distance.mean()), "p95MM": float(np.percentile(distance, 95)), "maxMM": float(distance.max())}


def contact_sheet(video, out, every=2.0, columns=6):
    """A frame every `every` seconds on one sheet — review it before publishing."""
    seconds = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", video],
                                   capture_output=True, text=True).stdout.strip() or 0)
    rows = max(1, -(-int(seconds / every + 1) // columns))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", video, "-vf",
                    "fps=1/%g,scale=320:-1,tile=%dx%d" % (every, columns, rows), "-frames:v", "1", out], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--scan", required=True)
    ap.add_argument("--out", default="video")
    ap.add_argument("--title", default="From an iPhone scan to a CAD model")
    ap.add_argument("--subtitle", default="A fire hydrant, built in OpenShape 3D by an assistant over MCP — and graded by the app")
    ap.add_argument("--name", default="scan-to-cad")
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--only", default=None, help="render one segment id")
    ap.add_argument("--samples", type=int, default=16)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    summary = json.load(open(os.path.join(args.run, "summary.json")))
    accuracy = json.load(open(os.path.join(args.run, "accuracy.json")))

    print("== narration")
    segments = synthesize(script(summary, accuracy, args.title, os.path.basename(args.scan)),
                          os.path.join(args.out, "tts"))
    for seg in segments:
        print("   %-9s %5.1f s  (%4.1f s spoken)" % (seg["id"], seg["seconds"], seg["narration"]))
    timing = {"title": args.title, "subtitle": args.subtitle, "segments": segments,
              "calls": transcript_lines(args.run)}
    timing_path = os.path.join(args.out, "timing.json")
    json.dump(timing, open(timing_path, "w"), indent=1)

    heat = os.path.join(args.run, "heatmap.ply")
    if not os.path.exists(heat):
        print("== heatmap")
        stats = heatmap(args.run, args.scan, heat, accuracy["options"]["toleranceMM"])
        print("   scan→model mean %.2f mm, p95 %.2f mm (trimesh, for the colouring only)" % (stats["meanMM"], stats["p95MM"]))

    print("== blender")
    frames = os.path.join(args.out, "frames")
    cmd = [BLENDER, "-b", "--python", os.path.join(HERE, "blender_video.py"), "--",
           "--run", args.run, "--scan", args.scan, "--timing", timing_path, "--frames", frames,
           "--samples", str(args.samples)]
    if args.preview:
        cmd += ["--preview", "1"]
    if args.only:
        cmd += ["--only", args.only]
    log = open(os.path.join(args.out, "blender.log"), "w")
    result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    log.close()
    if result.returncode != 0:
        sys.exit("blender failed; see " + os.path.join(args.out, "blender.log"))
    if args.preview:
        print("   previews in", frames)
        return

    print("== compose")
    segs = json.load(open(os.path.join(frames, "segments.json")))
    fps = segs["fps"]
    inputs = ["-framerate", str(fps), "-i", os.path.join(frames, "frame_%04d.jpg")]
    filters = []
    mix = []
    for i, seg in enumerate(segs["segments"]):
        inputs += ["-i", seg["clip"]]
        delay = int((seg["start"] - 1) / fps * 1000)
        filters.append("[%d:a]adelay=%d|%d[a%d]" % (i + 1, delay, delay, i))
        mix.append("[a%d]" % i)
    filters.append("%samix=inputs=%d:normalize=0[aout]" % ("".join(mix), len(mix)))
    out = os.path.join(args.out, args.name + ".mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filters),
                    "-map", "0:v", "-map", "[aout]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "19",
                    "-c:a", "aac", "-b:a", "160k", "-shortest", "-movflags", "+faststart", out], check=True)
    contact_sheet(out, os.path.join(args.out, "contact.png"))
    seconds = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out],
                                   capture_output=True, text=True).stdout.strip())
    print("wrote %s (%.1f s, %.1f MB); contact sheet %s" % (out, seconds, os.path.getsize(out) / 1e6,
                                                           os.path.join(args.out, "contact.png")))


if __name__ == "__main__":
    main()
