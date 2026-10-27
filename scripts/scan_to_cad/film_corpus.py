#!/usr/bin/env python3
"""Film every built part of a scan corpus: a take in the app, then the cut.

    python3 film_corpus.py corpus/ --port 8947 --derived-data ~/Library/Developer/Xcode/DerivedData/openshape3d-xxx \
        [--only bollard,beer-mug] [--music path.m4a] [--python venv/bin/python] [--skip-take] [--skip-compose]

For each part in `order.json` that `results.json` says built, this runs
`demo_video.py take --ui --spec <part>/spec.json` into `<part>/demo/` and
then `demo_video.py compose --spec … --report … --overlays …`, and records
the film's path (or the error) in `films.json`. One music bed for all the
films (`--music`, a file: the hydrant's Lyria bed) keeps the series
consistent and saves ten Lyria calls; the narration is per part.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def run_logged(cmd, log_path, timeout, what):
    """Run `cmd` with its output in `log_path`. On a timeout kill its whole
    process group — demo_video.py's ffmpeg would otherwise live on, orphaned
    — and raise with the log's tail; a non-zero exit raises the same way."""
    with open(log_path, "w") as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            raise RuntimeError("%s timed out after %d s" % (what, timeout))
    if code != 0:
        tail = open(log_path).read().splitlines()[-8:]
        raise RuntimeError("%s exit %d: %s" % (what, code, " | ".join(tail)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--port", type=int, default=8947)
    ap.add_argument("--simulator", default="os3d-hydrant")
    ap.add_argument("--derived-data", required=True)
    ap.add_argument("--only", default=None)
    ap.add_argument("--music", default="lyria")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--skip-take", action="store_true")
    ap.add_argument("--skip-compose", action="store_true")
    ap.add_argument("--hook-background", nargs=3, default=["0.13", "0.14", "0.16"])
    ap.add_argument("--allow-fail", action="store_true",
                    help="film parts whose inspection (results.json → qa.verdict) FAILED; by default they are skipped")
    args = ap.parse_args()
    corpus = os.path.abspath(args.corpus)
    order = json.load(open(os.path.join(corpus, "order.json")))
    results = json.load(open(os.path.join(corpus, "results.json")))
    if args.only:
        order = [s for s in order if s in args.only.split(",")]
    films_path = os.path.join(corpus, "films.json")
    films = json.load(open(films_path)) if os.path.exists(films_path) else {}
    for slug in order:
        if not results.get(slug, {}).get("ok"):
            print("== %s: not built, skipped" % slug, flush=True)
            continue
        # A model the inspection failed is not filmed: the film would show
        # the flaw at full size (a bucket with a lid, a dome cut into steps)
        # with a cheerful number under it. Fix the build, or --allow-fail.
        qa = results[slug].get("qa", {})
        if qa.get("verdict") == "FAIL" and not args.allow_fail:
            print("== %s: inspection FAILED (%s) — not filmed; see %s or pass --allow-fail" % (
                slug, ", ".join(qa.get("failed", [])) or "see checks.json", qa.get("sheet", "qa/review.png")), flush=True)
            for line in qa.get("patches", []):
                print("     %s" % line, flush=True)
            continue
        if qa.get("verdict"):
            print("== %s: inspection %s" % (slug, qa["verdict"]), flush=True)
        part = os.path.join(corpus, slug)
        spec = os.path.join(part, "spec.json")
        analysis = os.path.join(part, "analysis")
        profile = json.load(open(os.path.join(analysis, "profile.json")))
        scan = profile.get("croppedScan") or os.path.join(analysis, "scan_cropped.glb")
        demo = os.path.join(part, "demo")
        row = films.get(slug, {})
        t0 = time.time()
        try:
            if not args.skip_take:
                print("== %s: take" % slug, flush=True)
                cmd = [args.python, "-I", os.path.join(HERE, "demo_video.py"), "take", "--scan", scan, "--analysis", analysis,
                       "--out", demo, "--port", str(args.port), "--simulator", args.simulator, "--ui",
                       "--derived-data", args.derived_data, "--spec", spec,
                       "--tolerance", str(results[slug]["toleranceMM"]), "--hook-background"] + list(args.hook_background)
                run_logged(cmd, os.path.join(part, "take.log"), 3600, "take")   # a lofted body's take replays its hundreds of lofts
                row["take"] = os.path.join(demo, "take.mov")
            if not args.skip_compose:
                print("== %s: compose" % slug, flush=True)
                report = os.path.join(part, slug + "-accuracy-report.html")
                cmd = [args.python, "-I", os.path.join(HERE, "demo_video.py"), "compose", "--out", demo, "--spec", spec,
                       "--tts", "gemini", "--music", args.music, "--overlays", os.path.join(part, "run", "overlays")]
                if os.path.exists(report):
                    cmd += ["--report", report]
                run_logged(cmd, os.path.join(part, "compose.log"), 2400, "compose")
                name = json.load(open(spec)).get("name", slug + "-demo")
                row["film"] = os.path.join(demo, name + ".mp4")
                row["ok"] = os.path.exists(row["film"])
            if row.get("ok"):
                row.pop("error", None)   # an earlier round's failure, now behind us
            print("   done in %.0f s" % (time.time() - t0), flush=True)
        except Exception as error:  # noqa: BLE001 — the row says what stopped it
            row["ok"] = False
            row["error"] = str(error)[:800]
            print("   FAILED:", str(error)[:300], flush=True)
        row["seconds"] = round(time.time() - t0)
        films[slug] = row
        with open(films_path, "w") as f:
            json.dump(films, f, indent=1)
    print("films:", sum(1 for s in order if films.get(s, {}).get("ok")), "of", len(order), "->", films_path)


if __name__ == "__main__":
    main()
