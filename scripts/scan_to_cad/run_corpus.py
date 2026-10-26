#!/usr/bin/env python3
"""Build every part of a scan corpus through the app, one after another.

    python3 run_corpus.py corpus/ --port 8947 --simulator os3d-hydrant [--only bollard,beer-mug] [--python venv/bin/python]

`corpus/` holds one folder per part (`order.json` lists them) with
`analysis/` from `analyze_scan.py` and a `spec.json` (label, colour — a
list, or "scan" for the scan's own colour — the same file `demo_video.py
--spec` reads). For each part this relaunches the
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
sys.path.insert(0, HERE)
from spec_color import model_color, nut_words  # noqa: E402 — stdlib only; this script runs under any python3

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


def nut_lines(profile):
    """One line per polygonal band the analysis found, on the main axis
    and on each body: "a 26 mm hex nut, 10 mm tall on body 1"."""
    lines = [nut_words(n) + " on the main axis" for n in profile.get("nuts") or []]
    for body in profile.get("bodies") or []:
        lines += [nut_words(n) + " on body %s" % body.get("index") for n in body.get("nuts") or []]
    return lines


def bore_lines(profile):
    """One line per bore the analysis found at a free end, on the main
    body and on each body: "body 2: r 19 mm 50 deep", with " +10 on into
    body 1" when the scan shows the bore running on into the body's
    parent (the bore's `passage` record)."""
    lines = []
    for b in [profile] + (profile.get("bodies") or []):
        for bore in b.get("bores") or []:
            line = "%s: r %.0f mm %s" % ("body %d" % b["index"] if "index" in b else "body",
                                         bore["rInnerMM"], "through" if bore.get("through") else "%.0f deep" % bore["depthMM"])
            passage = bore.get("passage")
            if passage and "index" in b:
                into = passage.get("intoParentMM")
                if into is None:
                    into = max(float(passage["depthMM"]) - float(bore["depthMM"]), 0.0)
                line += " +%.0f on into body %s" % (float(into), b.get("parent"))
            lines.append(line)
    return lines


def patch_lines(patches, top=3):
    """One line per largest patch of each kind: kind, area, where."""
    lines = []
    for kind in ("missing", "excess"):
        for p in patches.get(kind, [])[:top]:
            lines.append("%s %s mm² %s" % (kind, "{:,.0f}".format(p["areaMM2"]).replace(",", " "), p["location"]))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--port", type=int, default=8947)
    ap.add_argument("--simulator", default="os3d-hydrant")
    ap.add_argument("--only", default=None, help="comma-separated part folders")
    ap.add_argument("--python", default=sys.executable, help="the interpreter with trimesh (the venv's)")
    ap.add_argument("--no-features", action="store_true",
                    help="stop after the revolve: skip fit_features.py / build_features.py")
    ap.add_argument("--analyze", action="store_true",
                    help="re-run analyze_scan.py first (auto band/epsilon plus the part's flags in corpus/analysis-flags.json)")
    args = ap.parse_args()
    corpus = os.path.abspath(args.corpus)
    with open(os.path.join(corpus, "order.json")) as f:
        order = json.load(f)
    if args.only:
        order = [s for s in order if s in args.only.split(",")]
    udid = udid_for(args.simulator)
    results_path = os.path.join(corpus, "results.json")
    results = json.load(open(results_path)) if os.path.exists(results_path) else {}
    flags_path = os.path.join(corpus, "analysis-flags.json")
    flags = json.load(open(flags_path)) if os.path.exists(flags_path) else {}
    for slug in order:
        part = os.path.join(corpus, slug)
        spec = json.load(open(os.path.join(part, "spec.json")))
        analysis = os.path.join(part, "analysis")
        if args.analyze:
            source = os.path.join(part, "prep", "scan.glb")
            if not os.path.exists(source):
                source = os.path.join(part, "download", "scan.glb")
            cmd = [args.python, "-I", os.path.join(HERE, "analyze_scan.py"), source, "--out", analysis] + list(flags.get(slug, []))
            with open(os.path.join(part, "analysis.log"), "w") as log:
                done = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
            if done.returncode != 0:
                tail = open(os.path.join(part, "analysis.log")).read().splitlines()[-4:]
                print("=== %s: analyze_scan.py exit %d: %s" % (slug, done.returncode, " | ".join(tail)), flush=True)
                results[slug] = {"label": spec["label"], "ok": False, "error": "analyze_scan.py exit %d" % done.returncode}
                continue
        profile = json.load(open(os.path.join(analysis, "profile.json")))
        scan = profile.get("croppedScan") or os.path.join(analysis, "scan_cropped.glb")
        tolerance = 2.0 if profile["heightMM"] < 300 else 3.0
        # The spec's colour, or with "scan" the scan's own (`scanColor` in
        # the analysis); the build and the inspection sheet paint it alike.
        color = [str(c) for c in model_color(spec, profile)]
        run_dir = os.path.join(part, "run")
        nuts = nut_lines(profile)
        # The bores the analysis found at free ends (the main body's and
        # each secondary body's), so the row says "bored r 14, 50 deep",
        # and "+10 on into body 1" where a bore's passage runs on.
        bores = bore_lines(profile)
        print("=== %s: %s, %.0f mm tall, %d bosses, tolerance %.0f mm%s%s" % (
            slug, spec["label"], profile["heightMM"], len(profile["bosses"]), tolerance,
            ("; " + "; ".join(nuts)) if nuts else "",
            ("; bored — " + ", ".join(bores)) if bores else ""), flush=True)
        t0 = time.time()
        row = {"label": spec["label"], "heightMM": profile["heightMM"], "bosses": len(profile["bosses"]),
               "profilePoints": len(profile["profile"]), "toleranceMM": tolerance, "nuts": nuts, "bores": bores}
        try:
            relaunch(udid, args.port)
            cmd = [args.python, "-I", os.path.join(HERE, "build_hydrant.py"), "--scan", scan, "--analysis", analysis,
                   "--out", run_dir, "--port", str(args.port), "--name", slug, "--label", spec["label"],
                   "--tolerance", str(tolerance), "--color"] + color
            with open(os.path.join(part, "build.log"), "w") as log:
                build = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=1500)
            if build.returncode != 0:
                tail = open(os.path.join(part, "build.log")).read().splitlines()[-6:]
                raise RuntimeError("build_hydrant.py exit %d: %s" % (build.returncode, " | ".join(tail)))
            # What the revolve missed — a handle, a hose, a lever — fitted
            # on the exported pair and built into the body in the same
            # session (`fit_features.py`, `build_features.py`).
            if not args.no_features:
                feat_dir = os.path.join(part, "features")
                fit = subprocess.run([args.python, "-I", os.path.join(HERE, "fit_features.py"),
                                      "--scan", os.path.join(run_dir, "scan.stl"),
                                      "--model", os.path.join(run_dir, slug + "-cad.stl"),
                                      "--analysis", os.path.join(analysis, "profile.json"),
                                      "--tolerance", str(tolerance), "--out", feat_dir],
                                     capture_output=True, text=True, timeout=1200,
                                     env=dict(os.environ, FIT_DEBUG="1"))
                with open(os.path.join(part, "features.log"), "w") as log:
                    log.write(fit.stdout + fit.stderr)
                if fit.returncode != 0:
                    print("    fit_features.py exit %d: %s" % (fit.returncode, fit.stderr[-300:]), flush=True)
                    row["features"] = {"error": "fit_features.py exit %d" % fit.returncode}
                else:
                    found = json.load(open(os.path.join(feat_dir, "features.json")))
                    row["features"] = {"found": len(found["features"]), "unexplained": len(found["unexplained"]),
                                       "farShare": found["farShare"],
                                       "kinds": [f["kind"] for f in found["features"]]}
                    print("    features: %d found (%s), %d pieces unexplained, %.0f%% of the scan was far" % (
                        len(found["features"]), ", ".join(f["kind"] for f in found["features"]) or "none",
                        len(found["unexplained"]), found["farShare"] * 100), flush=True)
                    if found["features"]:
                        with open(os.path.join(part, "features.log"), "a") as log:
                            done = subprocess.run([args.python, "-I", os.path.join(HERE, "build_features.py"),
                                                   "--features", os.path.join(feat_dir, "features.json"),
                                                   "--run", run_dir, "--port", str(args.port),
                                                   "--tolerance", str(tolerance)],
                                                  stdout=log, stderr=subprocess.STDOUT, timeout=1500)
                        if done.returncode != 0:
                            tail = open(os.path.join(part, "features.log")).read().splitlines()[-4:]
                            print("    build_features.py exit %d: %s" % (done.returncode, " | ".join(tail)), flush=True)
                            row["features"]["error"] = "build_features.py exit %d" % done.returncode
                        else:
                            built = json.load(open(os.path.join(run_dir, "summary.json"))).get("features", [])
                            row["features"]["built"] = sum(1 for b in built if b.get("ok"))
                            row["features"]["refused"] = [b["name"] for b in built if not b.get("ok")]
                            print("    features built: %d of %d%s" % (
                                row["features"]["built"], len(built),
                                (" (refused: " + ", ".join(row["features"]["refused"]) + ")") if row["features"]["refused"] else ""),
                                flush=True)
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
            # The second opinion: both-way distances, depth maps and a sheet
            # to look at (`inspect_fit.py`). The app's overlap number alone
            # passed a bucket modelled as a solid drum.
            qa_dir = os.path.join(part, "qa")
            qa = subprocess.run([args.python, "-I", os.path.join(HERE, "inspect_fit.py"),
                                 "--reference", os.path.join(run_dir, "scan.stl"),
                                 "--model", os.path.join(run_dir, slug + "-cad.stl"),
                                 "--out", qa_dir, "--title", spec["label"], "--tolerance", str(tolerance),
                                 "--model-color"] + color,
                                capture_output=True, text=True, timeout=900)
            if qa.returncode == 0:
                checks = json.load(open(os.path.join(qa_dir, "checks.json")))
                row["qa"] = {"verdict": checks["overall"], "sheet": os.path.join(qa_dir, "review.png"),
                             "failed": [c["check"] for c in checks["checks"] if c["verdict"] == "FAIL"],
                             "warned": [c["check"] for c in checks["checks"] if c["verdict"] == "WARN"],
                             # The biggest things wrong, one line each, so the
                             # row says "missing 5 218 mm² in the middle third"
                             # and not just which check failed.
                             "patches": patch_lines(checks.get("patches", {}))}
                print("    qa: %s%s — look at %s" % (checks["overall"],
                                                     (" (" + ", ".join(row["qa"]["failed"]) + ")") if row["qa"]["failed"] else "",
                                                     row["qa"]["sheet"]), flush=True)
            else:
                row["qa"] = {"verdict": "ERROR", "error": "exit %d: %s" % (qa.returncode, qa.stderr[-300:])}
                print("    qa: inspect_fit.py exit %d (a negative code is a signal — memory?): %s" % (
                    qa.returncode, qa.stderr[-200:]), flush=True)
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
