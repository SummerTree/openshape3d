#!/usr/bin/env python3
"""The accuracy report as one self-contained HTML page, from a build run.

    python3 report.py run/ --out run/report.html [--title "Fire hydrant"]

Reads `summary.json`, `accuracy.json`, `transcript.md` and the pictures the
build wrote (`overlays/`, `shots/`, and `analysis/profile.png` beside the
run when present) and inlines everything, so the page travels as one file.
The numbers are the app's own (`/v1/accuracy`); nothing is recomputed here.
"""
import argparse
import base64
import html
import json
import os


def data_uri(path):
    if not path or not os.path.exists(path):
        return None
    ext = os.path.splitext(path)[1].lower()
    mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "svg": "image/svg+xml"}.get(ext[1:], "image/png")
    with open(path, "rb") as f:
        return "data:{};base64,{}".format(mime, base64.b64encode(f.read()).decode("ascii"))


def histogram_svg(stats, tolerance, width=360, height=120):
    bins = stats.get("histogram") or []
    if not bins:
        return ""
    peak = max(bins) or 1
    bin_mm = stats["histogramBinMM"]
    w = width / len(bins)
    bars = []
    for i, count in enumerate(bins):
        h = (height - 28) * count / peak
        within = (i + 1) * bin_mm <= tolerance + 1e-9
        bars.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>' % (
            i * w + 1, height - 20 - h, max(w - 2, 1), h, "#4caf50" if within else "#ff9800"))
    tx = tolerance / (bin_mm * len(bins)) * width
    marker = '<line x1="%.1f" y1="0" x2="%.1f" y2="%d" stroke="#555" stroke-dasharray="3,3"/>' % (tx, tx, height - 20) if tx <= width else ""
    axis = '<text x="2" y="%d" font-size="11" fill="#666">0</text><text x="%d" y="%d" font-size="11" fill="#666" text-anchor="end">%.1f mm</text>' % (
        height - 6, width - 2, height - 6, bin_mm * len(bins))
    return '<svg viewBox="0 0 %d %d" width="%d" height="%d">%s%s%s</svg>' % (width, height, width, height, "".join(bars), marker, axis)


def table(rows):
    out = ["<table>"]
    for label, value in rows:
        out.append("<tr><th>%s</th><td>%s</td></tr>" % (html.escape(str(label)), html.escape(str(value))))
    out.append("</table>")
    return "\n".join(out)


def markdown_table_to_html(md):
    """Only what transcript.md uses: a heading, a paragraph, one pipe table."""
    out = []
    in_table = False
    for line in md.splitlines():
        if line.startswith("# "):
            continue
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if all(set(c) <= set("-: ") for c in cells):
                continue
            if not in_table:
                out.append('<table class="transcript">')
                in_table = True
                out.append("<tr>" + "".join("<th>%s</th>" % html.escape(c) for c in cells) + "</tr>")
            else:
                out.append("<tr>" + "".join("<td>%s</td>" % html.escape(c.replace("`", "")) for c in cells) + "</tr>")
        else:
            if in_table:
                out.append("</table>")
                in_table = False
            if line.strip():
                out.append("<p>%s</p>" % html.escape(line.replace("`", "")))
    if in_table:
        out.append("</table>")
    return "\n".join(out)


def build(run, title):
    with open(os.path.join(run, "summary.json")) as f:
        summary = json.load(f)
    with open(os.path.join(run, "accuracy.json")) as f:
        acc = json.load(f)
    transcript = ""
    if os.path.exists(os.path.join(run, "transcript.md")):
        with open(os.path.join(run, "transcript.md")) as f:
            transcript = f.read()
    analysis_png = data_uri(os.path.join(os.path.dirname(run.rstrip("/")), "analysis", "profile.png"))
    azimuth_png = data_uri(os.path.join(os.path.dirname(run.rstrip("/")), "analysis", "azimuth.png"))
    tol = acc["options"]["toleranceMM"]

    overlays = []
    for o in acc["overlays"]:
        img = data_uri(os.path.join(run, "overlays", o["view"] + ".jpg"))
        overlays.append('''
<figure class="overlay">
  %s
  <figcaption><b>%s view</b> — overlap %.1f%% · outline mean %.2f mm · 95%% within %.2f mm · max %.2f mm<br>
  reference %.0f mm² · model %.0f mm² · missing %.0f mm² · excess %.0f mm²</figcaption>
</figure>''' % ('<img src="%s" alt="%s view overlay">' % (img, o["view"]) if img else "",
                o["view"].capitalize(), o["iou"] * 100, o["boundaryMeanMM"], o["boundaryP95MM"], o["boundaryMaxMM"],
                o["referenceAreaMM2"], o["modelAreaMM2"], o["missingAreaMM2"], o["excessAreaMM2"]))

    def dev(label, s):
        return '''
<div class="dev">
  <h4>%s</h4>
  %s
  %s
</div>''' % (html.escape(label), table([
            ("Samples", "{:,}".format(s["samples"])),
            ("Mean / RMS", "%.2f / %.2f mm" % (s["meanMM"], s["rmsMM"])),
            ("Median / 95% / max", "%.2f / %.2f / %.2f mm" % (s["medianMM"], s["p95MM"], s["maxMM"])),
            ("Within %.1f mm" % tol, "%.1f%%" % (s["withinTolerance"] * 100)),
            ("Bias (signed mean)", "%+.2f mm" % s["meanSignedMM"]),
        ]), histogram_svg(s, tol))

    shots = []
    for key in sorted(summary.get("shots", {})):
        img = data_uri(summary["shots"][key])
        if img:
            shots.append('<figure><img src="%s" alt="%s"><figcaption>%s</figcaption></figure>' % (img, key, key))

    rb, mb = acc["referenceBounds"], acc["modelBounds"]
    exports = summary.get("exports", {})
    bosses = summary.get("bosses", [])
    page = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%(title)s — accuracy report</title>
<style>
  :root { --ink:#1d2330; --muted:#5b6472; --line:#e3e6ec; --ref:#2b74e0; --model:#e8650d; --bg:#fff; }
  body { font: 15px/1.5 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: var(--ink); background: var(--bg); margin: 0; }
  main { max-width: 1100px; margin: 0 auto; padding: 32px 20px 64px; }
  h1 { font-size: 30px; margin: 0 0 6px; } h2 { font-size: 21px; margin: 40px 0 12px; border-bottom: 1px solid var(--line); padding-bottom: 6px; }
  h4 { margin: 0 0 8px; }
  .lede { color: var(--muted); font-size: 16px; }
  .headline { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin: 22px 0; }
  .tile { border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; }
  .tile .n { font-size: 26px; font-weight: 600; } .tile .l { color: var(--muted); font-size: 13px; }
  table { border-collapse: collapse; font-size: 14px; } th, td { text-align: left; padding: 5px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--muted); font-weight: 500; white-space: nowrap; }
  .overlays { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 18px; }
  figure { margin: 0; } figure img { width: 100%%; border: 1px solid var(--line); border-radius: 8px; }
  figcaption { font-size: 13px; color: var(--muted); margin-top: 6px; }
  .devs { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 24px; }
  .legend span { display: inline-block; width: 12px; height: 12px; border-radius: 2px; margin: 0 6px 0 14px; vertical-align: -1px; }
  .shots { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }
  table.transcript { width: 100%%; font-size: 12.5px; } table.transcript td { font-family: Menlo, monospace; word-break: break-word; }
  .summary { background: #f5f7fb; border-radius: 10px; padding: 14px 18px; }
  code { font-family: Menlo, monospace; font-size: 13px; }
  @media (prefers-color-scheme: dark) { :root { --ink:#e8ebf1; --muted:#9aa3b2; --line:#2a303b; --bg:#12151b; } .summary { background:#1a1f28; } figure img { background:#fff; } }
</style></head>
<body><main>
<h1>%(title)s — scan to CAD accuracy report</h1>
<p class="lede">A 3D scan turned into a parametric CAD model in OpenShape 3D over its MCP interface, and graded by the app itself:
orthographic silhouettes of the scan and the model laid over each other, and the distance from every sampled point of one surface to the other.</p>

<div class="headline">
  <div class="tile"><div class="n">%(iou).1f%%</div><div class="l">silhouette overlap (IoU), mean of %(views)d views</div></div>
  <div class="tile"><div class="n">%(within).1f%%</div><div class="l">of scan points within %(tol).1f mm of the model</div></div>
  <div class="tile"><div class="n">%(p95).2f mm</div><div class="l">95th-percentile scan-to-model deviation</div></div>
  <div class="tile"><div class="n">%(calls)d</div><div class="l">MCP calls, %(secs).1f s in the app</div></div>
</div>

<p class="summary">%(summary)s</p>

<h2>Orthographic overlays</h2>
<p class="legend"><span style="background:var(--ref)"></span>reference (scan) silhouette, filled <span style="background:var(--model)"></span>model outline</p>
<div class="overlays">%(overlays)s</div>

<h2>Surface deviation</h2>
<div class="devs">%(dev1)s %(dev2)s</div>

<h2>Size and volume</h2>
%(sizes)s

<h2>The model</h2>
%(model)s
%(bosses)s

<h2>Pictures from the app</h2>
<div class="shots">%(shots)s</div>

%(analysis)s

<h2>The MCP session</h2>
<p>Every call the build made to the <code>os3d</code> tool, through <code>scripts/mcp_openshape3d.py</code>, in order.</p>
%(transcript)s

<h2>Files</h2>
%(files)s
</main></body></html>
''' % {
        "title": html.escape(title),
        "iou": acc["overallIoU"] * 100, "views": len(acc["overlays"]),
        "within": acc["referenceToModel"]["withinTolerance"] * 100, "tol": tol,
        "p95": acc["referenceToModel"]["p95MM"],
        "calls": summary.get("calls", 0), "secs": summary.get("secondsInApp", 0),
        "summary": html.escape(acc["summary"]),
        "overlays": "".join(overlays),
        "dev1": dev("Scan → model (reference to model)", acc["referenceToModel"]),
        "dev2": dev("Model → scan (model to reference)", acc["modelToReference"]),
        "sizes": table([
            ("Scan size (W × H × D)", "%.1f × %.1f × %.1f mm" % tuple(rb["sizeMM"])),
            ("Model size", "%.1f × %.1f × %.1f mm" % tuple(mb["sizeMM"])),
            ("Difference (model − scan)", "%+.1f × %+.1f × %+.1f mm" % tuple(acc["extentDeltaMM"])),
            ("Scan triangles / model triangles", "{:,} / {:,}".format(acc["referenceTriangles"], acc["modelTriangles"])),
            ("Scan closed?", "yes" if acc["referenceWatertight"] else "no (open mesh, volume not compared)"),
            ("Model volume", "%.0f mm³" % acc["modelVolumeMM3"]),
            ("Alignment", acc["options"]["alignment"] + " (built on the scan's own axis)"),
        ]),
        "model": table([
            ("Revolve", "%d-point profile, %.0f mm³ (Pappus from the profile: %.0f mm³)" % (
                summary.get("revolve", {}).get("profilePoints", 0), summary.get("revolve", {}).get("volumeMM3", 0),
                summary.get("revolve", {}).get("pappusMM3", 0))),
            ("Valid solid", "yes" if summary.get("check", {}).get("valid") else "no — " + str(summary.get("check", {}).get("findings"))),
            ("B-rep faces", (summary.get("check", {}).get("counts") or {}).get("faces", "")),
            ("Analytic (B-rep)", "yes" if summary.get("cad", {}).get("brep") else "no"),
        ]),
        "bosses": ("<h4>Bosses from the scan</h4>" + "<table><tr><th>azimuth</th><th>height</th><th>neck Ø</th><th>cap Ø</th><th>reach from axis</th></tr>"
                   + "".join("<tr><td>%.0f°</td><td>%.0f mm</td><td>%.0f mm</td><td>%.0f mm</td><td>%.0f mm</td></tr>" % (
                       b["azimuthDeg"], b["centerHeightMM"], b["neckRadiusMM"] * 2, b["capRadiusMM"] * 2, b["reachMM"]) for b in bosses)
                   + "</table>") if bosses else "",
        "shots": "".join(shots),
        "analysis": ('<h2>Scan analysis</h2><div class="overlays"><figure><img src="%s" alt="radial profile"><figcaption>Radius by height: the median (blue), the maximum (orange) and the revolve polyline (black).</figcaption></figure>'
                     '<figure><img src="%s" alt="azimuth map"><figcaption>Radius above the body radius by height and azimuth: the nozzles show as blobs.</figcaption></figure></div>' % (analysis_png, azimuth_png)) if analysis_png and azimuth_png else "",
        "transcript": markdown_table_to_html(transcript),
        "files": table([(k, "%s (%s bytes%s)" % (os.path.basename(v["path"]), "{:,}".format(v["bytes"]),
                                                  ", " + v["sizeMM"] + " mm" if v.get("sizeMM") else "")) for k, v in exports.items()]
                       + [("accuracy report", "accuracy.json"), ("transcript", "transcript.md")]),
    }
    return page


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--out", default=None)
    ap.add_argument("--title", default="Fire hydrant")
    args = ap.parse_args()
    out = args.out or os.path.join(args.run, "report.html")
    with open(out, "w") as f:
        f.write(build(args.run, args.title))
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
