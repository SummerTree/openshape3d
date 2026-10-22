#!/usr/bin/env python3
"""Build every part of a scan corpus through the app, one after another.

    python3 run_corpus.py corpus/ --port 8947 --simulator os3d-hydrant [--only bollard,beer-mug] [--python venv/bin/python]

`corpus/` holds one folder per part (`order.json` lists them) with
`analysis/` from `analyze_scan.py` and a `spec.json` (label, colour — the
same file `demo_video.py --spec` reads). For each part this relaunches the
app in an empty design (`OS3D_FRESH=1`, the agent bridge on `--port`),
waits for the bridge, runs `build_hydrant.py` into `<part>/run/`, then
`report.py`, and writes `corpus/results.json` — one row per part with the
app's own numbers (overlap, mean deviation, valid solid, calls), or the
error that stopped it. A part that fails does not stop the rest.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = "com.laan.labs.openshape3d"


def udid_for(name):
    out = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True, check=True).stdout
    for devices in json.loads(out)["devices"].values():
        for d in devices:
            if d["name"] == name:
                return d["udid"]
    sys.exit("no simulator named " + name)


def relaunch(udid, port):
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
    time.sleep(1.0)
    env = dict(os.environ, SIMCTL_CHILD_OS3D_AGENT="1", SIMCTL_CHILD_OS3D_FRESH="1", SIMCTL_CHILD_OS3D_AGENT_PORT=str(port))
    subprocess.run(["xcrun", "simctl", "launch", udid, BUNDLE], env=env, check=True, capture_output=True)
    for _ in range(60):
        time.sleep(1.0)
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/v1/state" % port, timeout=2) as r:
                state = json.load(r)
            if state.get("ok") and not state.get("bodies"):
                return state
        except Exception:  # noqa: BLE001 — not up yet
            pass
    sys.exit("the app's bridge never answered on port %d" % port)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--port", type=int, default=8947)
    ap.add_argument("--simulator", default="os3d-hydrant")
    ap.add_argument("--only", default=None, help="comma-separated part folders")
    ap.add_argument("--python", default=sys.executable, help="the interpreter with trimesh (the venv's)")
    args = ap.parse_args()
    corpus = os.path.abspath(args.corpus)
    with open(os.path.join(corpus, "order.json")) as f:
        order = json.load(f)
    if args.only:
        order = [s for s in order if s in args.only.split(",")]
    udid = udid_for(args.simulator)
    results_path = os.path.join(corpus, "results.json")
    results = json.load(open(results_path)) if os.path.exists(results_path) else {}
    for slug in order:
        part = os.path.join(corpus, slug)
        spec = json.load(open(os.path.join(part, "spec.json")))
        analysis = os.path.join(part, "analysis")
        profile = json.load(open(os.path.join(analysis, "profile.json")))
        scan = profile.get("croppedScan") or os.path.join(analysis, "scan_cropped.glb")
        tolerance = 2.0 if profile["heightMM"] < 300 else 3.0
        run_dir = os.path.join(part, "run")
        print("=== %s: %s, %.0f mm tall, %d bosses, tolerance %.0f mm" % (
            slug, spec["label"], profile["heightMM"], len(profile["bosses"]), tolerance), flush=True)
        t0 = time.time()
        row = {"label": spec["label"], "heightMM": profile["heightMM"], "bosses": len(profile["bosses"]),
               "profilePoints": len(profile["profile"]), "toleranceMM": tolerance}
        try:
            relaunch(udid, args.port)
            cmd = [args.python, "-I", os.path.join(HERE, "build_hydrant.py"), "--scan", scan, "--analysis", analysis,
                   "--out", run_dir, "--port", str(args.port), "--name", slug, "--label", spec["label"],
                   "--tolerance", str(tolerance), "--color"] + [str(c) for c in spec["color"]]
            with open(os.path.join(part, "build.log"), "w") as log:
                build = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=1500)
            if build.returncode != 0:
                tail = open(os.path.join(part, "build.log")).read().splitlines()[-6:]
                raise RuntimeError("build_hydrant.py exit %d: %s" % (build.returncode, " | ".join(tail)))
            summary = json.load(open(os.path.join(run_dir, "summary.json")))
            acc = summary["accuracy"]
            row.update({"ok": True, "valid": summary["check"]["valid"], "calls": summary["calls"],
                        "overallIoU": acc["overallIoU"], "modelToScanMeanMM": acc["modelToReference"]["meanMM"],
                        "scanToModelMeanMM": acc["referenceToModel"]["meanMM"], "summary": acc["summary"],
                        "run": run_dir})
            report = subprocess.run([args.python, "-I", os.path.join(HERE, "report.py"), run_dir, "--title", spec["label"],
                                     "--out", os.path.join(part, slug + "-accuracy-report.html")],
                                    capture_output=True, text=True)
            row["report"] = os.path.join(part, slug + "-accuracy-report.html") if report.returncode == 0 else report.stderr[-300:]
            print("    ok: overlap %.1f%%, model→scan mean %.1f mm, valid %s, %d calls" % (
                acc["overallIoU"] * 100, acc["modelToReference"]["meanMM"], row["valid"], row["calls"]), flush=True)
        except Exception as error:  # noqa: BLE001 — the row says what stopped it
            row.update({"ok": False, "error": str(error)[:600]})
            print("    FAILED:", str(error)[:300], flush=True)
        row["seconds"] = round(time.time() - t0, 1)
        results[slug] = row
        with open(results_path, "w") as f:
            json.dump(results, f, indent=1)
    done = [s for s in order if results.get(s, {}).get("ok")]
    print("%d of %d built; results in %s" % (len(done), len(order), results_path))


if __name__ == "__main__":
    main()
