#!/usr/bin/env python3
"""Build the features `fit_features.py` found into the model already in the
app — sweeps, revolves and extrudes unioned into the revolved body — then
check it, photograph it, run the app's own accuracy report again and export
it over the first run's files.

    python3 build_features.py --features features/features.json --run run/ --port 8947 [--tolerance 2]

`run/summary.json` (from `build_hydrant.py`) says which body is the model
and which the scan; the app must still hold that design. Each feature is one
sketch and one feature op with `boolean: union` into the body; one that the
kernel refuses is recorded and left out, never a stray body. The summary
gains a `features` list (what was built, the volume after each) and its
`check`, `accuracy`, `exports` and `calls` are refreshed.
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import MCPClient, MCPError  # noqa: E402
from fit_primitives import sketch_entities  # noqa: E402
from build_hydrant import Session, unit  # noqa: E402
from build_recipe import revolve_region, radial_frame, seed_inside  # noqa: E402


def oval_entities(a, b):
    """An ellipse of semi-axes a ≥ b as the draughtsman's four-centre oval:
    two small arcs (radius b²/a, osculating at the ends of the major axis)
    and two large ones joined tangent to them. The kernel sweeps circle
    arcs along a polyline spine cleanly; a true ellipse section came out
    an unorientable shell ("boolean: the tool solid is invalid")."""
    a, b = float(max(a, b)), float(min(a, b))
    if a - b < 0.05 * a:
        return [{"kind": "circle", "center": [0, 0], "radius": round((a + b) / 2, 3)}]
    r1 = b * b / a
    r2 = ((a - r1) ** 2 + b * b - r1 * r1) / (2 * (b - r1))
    c1 = a - r1                       # small arcs centred on the major axis at ±c1
    c2 = r2 - b                       # large arcs centred on the minor axis at ∓c2 (below for the top arc)
    # The tangent point lies on the line from the large arc's centre through the small arc's centre.
    phi = math.atan2(c2, c1)          # angle of that line above the major axis, from the small centre
    ents = []
    # right small arc, from -phi to +phi about (c1, 0)
    ents.append({"kind": "arc", "center": [c1, 0.0], "radius": r1, "startAngle": -phi, "endAngle": phi})
    # top large arc about (0, -c2): from phi to pi - phi
    ents.append({"kind": "arc", "center": [0.0, -c2], "radius": r2, "startAngle": phi, "endAngle": math.pi - phi})
    # left small arc about (-c1, 0): from pi - phi to pi + phi
    ents.append({"kind": "arc", "center": [-c1, 0.0], "radius": r1, "startAngle": math.pi - phi, "endAngle": math.pi + phi})
    # bottom large arc about (0, c2): from pi + phi to 2 pi - phi
    ents.append({"kind": "arc", "center": [0.0, c2], "radius": r2, "startAngle": math.pi + phi, "endAngle": 2 * math.pi - phi})
    for e in ents:
        e["center"] = [round(v, 4) for v in e["center"]]
        e["radius"] = round(e["radius"], 4)
        e["startAngle"] = round(e["startAngle"], 6)
        e["endAngle"] = round(e["endAngle"], 6)
    return ents


def sweep_sketch(feature):
    """The profile sketch at the spine's start, its normal along the first leg."""
    spine = np.array(feature["spine"], dtype=float)
    t0 = unit(spine[1] - spine[0])
    x = np.array(feature.get("xAxis") or [0, 0, 0], dtype=float)
    x = x - (x @ t0) * t0
    if np.linalg.norm(x) < 1e-6:
        ref = np.array([0, 0, 1.0]) if abs(t0[2]) < 0.9 else np.array([1.0, 0, 0])
        x = ref - (ref @ t0) * t0
    x = unit(x)
    y = np.cross(t0, x)                   # x × y = t0: the plane faces along the spine
    prof = feature["profile"]
    if prof["shape"] == "ellipse":
        entities = oval_entities(prof["rx"], prof["ry"])
    else:
        entities = [{"kind": "circle", "center": [0, 0], "radius": prof["radius"]}]
    plane = {"origin": [float(v) for v in spine[0]], "xAxis": [float(v) for v in x], "yAxis": [float(v) for v in y]}
    return plane, entities, [0.0, 0.0]


def bore_profile(feature, overshoot=5.0):
    """The inner cone to cut out of a hollow horn (`fit_features.cone_mouth`:
    `boreDepthMM`, `wallMM`, `boreMouth`, `boreProfile`): the inner skin the
    scanner saw (`boreProfile`, [[r, h]] along the axis), or failing that
    the feature's own profile a wall in, from `overshoot` past the mouth
    (so the cut opens the end face) to the bore's floor, as [[r, h], …]
    along the feature's axis for `revolve_region` to close along the axis
    and revolve — subtracted after the horn's own union. Every radius is
    kept a millimetre inside the outer profile, so the cut never opens the
    skin. None when the feature has no bore."""
    depth = float(feature.get("boreDepthMM") or 0.0)
    wall = float(feature.get("wallMM") or 0.0)
    if depth <= 0 or wall <= 0:
        return None
    P = sorted(((float(r), float(h)) for r, h in feature["profile"]), key=lambda p: p[1])
    hs = [h for _, h in P]
    rs = [r for r, _ in P]
    at_hi = feature.get("boreMouth", "end") == "end"
    # The mouth as the fit measured it: the profile's end before the fit
    # lengthened it into what it meets (only the far end is lengthened).
    h_m = hs[-1] if at_hi else hs[0]
    floor_h = h_m - depth if at_hi else h_m + depth
    lo, hi = sorted((h_m, floor_h))
    margin = max(1.0, 0.3 * wall)

    def outer(h):
        return float(np.interp(h, hs, rs))

    seen = feature.get("boreProfile") or []
    if len(seen) >= 2:
        s_h = [float(h) for _, h in seen]
        s_r = [float(r) for r, _ in seen]

        def r_at(h):
            return max(min(float(np.interp(h, s_h, s_r)), outer(h) - margin), 0.5)
        heights = [lo, hi] + [h for h in s_h if lo < h < hi] + [h for h in hs if lo < h < hi]
    else:
        def r_at(h):
            return max(outer(h) - wall, 0.5)
        heights = [lo, hi] + [h for h in hs if lo < h < hi]
    beyond = (h_m + overshoot) if at_hi else (h_m - overshoot)
    inner = {round(h, 2): r_at(h) for h in heights}
    inner[round(beyond, 2)] = r_at(h_m)
    return [[round(inner[h], 2), h] for h in sorted(inner)]


def build_feature(mcp, feature, cad_id, label, note=True):
    """One fitted feature into the body: its sketch and its op, unioned.
    Returns the op's reply (`reply["failed"]` when the kernel refused it).
    The film and the reel call this for every feature the build built, so
    they show the same model the inspection graded."""
    kind = feature["kind"]
    say = (lambda text: text) if note else (lambda text: None)
    if kind == "sweep":
        plane, entities, seed = sweep_sketch(feature)
        sk = mcp.os3d("sketch.create", dict(plane, name=label),
                      note=say("the section's sketch at the spine's start, facing along it"))["sketchID"]
        mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": entities},
                 note=say("the section: %s" % json.dumps(feature["profile"])))
        return mcp.os3d("feature.sweep", {"sketchID": sk, "seedPoint": seed, "spine": feature["spine"],
                                          "boolean": "union", "booleanTargets": [cad_id]},
                        note=say("swept along %d spine points, unioned into the body" % len(feature["spine"])))
    if kind == "revolve":
        ax = feature["axis"]
        u, d = radial_frame(ax["direction"])
        sk = mcp.os3d("sketch.create", {"origin": [float(x) for x in ax["origin"]],
                                        "xAxis": [float(x) for x in u], "yAxis": [float(x) for x in d],
                                        "name": label}, note=say("a sketch through the feature's own axis"))["sketchID"]
        entities, seed = revolve_region(feature["profile"])
        mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": entities},
                 note=say("%d lines: %s" % (len(entities), "the ring's own section" if feature.get("hoop")
                                            else "the radial profile, closed along the axis")))
        reply = mcp.os3d("feature.revolve", {"sketchID": sk, "seedPoint": seed, "axisPoint": [0, 0],
                                             "axisDirection": [0, 1], "angleDegrees": 360,
                                             "boolean": "union", "booleanTargets": [cad_id]},
                         note=say("revolved 360° about its axis, unioned into the body"))
        bore = bore_profile(feature)
        if bore and not reply.get("failed"):
            # A hollow horn: the inner cone, a wall in from the mouth to the
            # bore's floor, revolved on the same plane and SUBTRACTED. The
            # horn stays if the cut is refused (the refusal is undone here,
            # so the caller's undo does not take the horn with it).
            sk_in = mcp.os3d("sketch.create", {"origin": [float(x) for x in ax["origin"]],
                                               "xAxis": [float(x) for x in u], "yAxis": [float(x) for x in d],
                                               "name": label + " bore"}, note=say("the bore's sketch, on the same axis plane"))["sketchID"]
            ents_in, seed_in = revolve_region(bore)
            mcp.os3d("sketch.addEntities", {"sketchID": sk_in, "entities": ents_in},
                     note=say("%d lines: the inner cone, a %.1f mm wall in, %.0f mm deep from the mouth" % (
                         len(ents_in), feature["wallMM"], feature["boreDepthMM"])))
            cut = mcp.os3d("feature.revolve", {"sketchID": sk_in, "seedPoint": seed_in, "axisPoint": [0, 0],
                                               "axisDirection": [0, 1], "angleDegrees": 360,
                                               "boolean": "subtract", "booleanTargets": [cad_id]},
                           note=say("revolved and subtracted: the horn is hollow"))
            if cut.get("failed"):
                reply["boreRefused"] = cut.get("message", "the bore did not cut")
                try:
                    mcp.os3d("command.run", {"id": "edit.undo"}, note=say("the refused bore undone; the horn stays solid"))
                except MCPError:
                    pass
            else:
                reply = cut
        return reply
    if kind == "extrude":
        pl = feature["plane"]
        sk = mcp.os3d("sketch.create", {"origin": pl["origin"], "xAxis": pl["xAxis"], "yAxis": pl["yAxis"],
                                        "name": label}, note=say("a sketch in the plate's own plane"))["sketchID"]
        entities = sketch_entities(feature["segments"])
        seed = feature.get("seed") or seed_inside(feature["segments"])
        mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": entities},
                 note=say("%d entities (%d arcs): the outline" % (len(entities), sum(e["kind"] == "arc" for e in entities))))
        req = {"sketchID": sk, "seedPoint": seed, "distance": feature["distance"],
               "boolean": "union", "booleanTargets": [cad_id]}
        if feature.get("symmetric"):
            req["symmetric"] = True
        return mcp.os3d("feature.extrude", req, note=say("extruded %.1f mm%s, unioned into the body" % (
            feature["distance"], " each way" if feature.get("symmetric") else "")))
    raise MCPError("feature", "unknown kind %r" % kind)


def shift_feature(feature, delta):
    """The feature moved by `delta` (mm): the film and the reel stand the
    scan on the floor with its axis origin at the world origin, so a
    feature fitted in the build's frame moves by −axisOrigin to match."""
    delta = np.asarray(delta, dtype=float)
    f = json.loads(json.dumps(feature))
    if f["kind"] == "sweep":
        f["spine"] = [[float(v) for v in (np.asarray(p, dtype=float) + delta)] for p in f["spine"]]
    elif f["kind"] == "revolve":
        f["axis"]["origin"] = [float(v) for v in (np.asarray(f["axis"]["origin"], dtype=float) + delta)]
    elif f["kind"] == "extrude":
        f["plane"]["origin"] = [float(v) for v in (np.asarray(f["plane"]["origin"], dtype=float) + delta)]
    return f


def bore_words(feature):
    """", bored 30 mm, 120 deep" for a hollow horn, else ""."""
    if not feature.get("boreDepthMM"):
        return ""
    return ", bored %.0f mm, %.0f deep" % (2 * float(feature.get("boreRadiusMM") or 0.0), float(feature["boreDepthMM"]))


SHAPE_WORDS = {"stadium": "a bar with rounded ends", "rectangle": "a rectangle", "square": "a square",
               "hexagon": "a hexagon", "octagon": "an octagon", "circle": "a disc", "ellipse": "an oval"}


def part_caption(feature):
    """The caption for a feature `fit_features.py` named as a part — a
    lever, a hex nut, a hoop — or None when it has no name (the old
    caption then stands)."""
    part = feature.get("part")
    if not part:
        return None
    kind = feature["kind"]
    shape = feature.get("shape") or {}
    head = "A hex nut" if part == "nut" and shape.get("sides") == 6 else "%s %s" % ("An" if part[0] in "aeiou" else "A", part)
    if kind == "sweep":
        tail = ("one tube along one spline, swept and unioned in" if part == "hose"
                else "a tube swept along its own centreline, unioned in")
    elif kind == "revolve":
        tail = {"hoop": "a ring on the body's own axis, revolved and unioned in",
                "horn": "a cone on the hose's end, revolved and unioned in"}.get(
            part, "a radial profile on its own axis, revolved and unioned in")
        tail += bore_words(feature)
    else:
        what = SHAPE_WORDS.get(shape.get("kind"), "its outline")
        if shape.get("cornerMM"):
            what += " with rounded corners"
        tail = ("%s extruded along the branch, unioned in" % what if feature.get("bar")
                else "%s, extruded and unioned in" % what)
    return "%s · %s" % (head, tail)


def feature_caption(feature):
    """What a film's caption says for a feature."""
    named = part_caption(feature)
    if named:
        return named
    kind = feature["kind"]
    if kind == "sweep":
        prof = feature["profile"]
        what = "a round section" if prof["shape"] == "circle" else "an oval section"
        return "Swept · %s along its own centreline, unioned in" % what
    if kind == "revolve":
        return ("A cone on its own axis · revolved and unioned in%s" % bore_words(feature) if feature.get("cone")
                else "Its own axis · a radial profile, revolved and unioned in")
    if feature.get("bar"):
        return "A bar · its section extruded along its length, unioned in"
    return "A plate · its outline extruded to the measured thickness, unioned in"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--features", required=True)
    ap.add_argument("--run", required=True, help="the build's run folder (summary.json, exports)")
    ap.add_argument("--port", type=int, default=8947)
    ap.add_argument("--tolerance", type=float, default=2.0)
    ap.add_argument("--max", type=int, default=12)
    args = ap.parse_args()
    with open(args.features) as f:
        found = json.load(f)
    with open(os.path.join(args.run, "summary.json")) as f:
        summary = json.load(f)
    features = found.get("features", [])[: args.max]
    cad_id = summary["revolve"]["id"]
    scan_id = summary["scan"]["id"]
    name = summary["name"]
    if not features:
        print("no features to build")
        return
    with MCPClient(port=args.port, log_dir=args.run) as mcp:
        s = Session(mcp, args.run, name)
        s.summary = summary
        summary.setdefault("steps", [])
        mcp.initialize()
        health = mcp.os3d("health", note="is the design still open")
        if not health.get("hasDocument"):
            sys.exit("the app has no design open")
        state = mcp.os3d("state", note="the bodies as the build left them")
        ids = {b["id"] for b in state["bodies"]}
        if cad_id not in ids:
            sys.exit("the model body %s is not in the design any more" % cad_id[:8])
        built = []
        for n, feature in enumerate(features, 1):
            kind = feature["kind"]
            label = feature.get("name", "%s %d" % (kind, n))
            s.step("Feature %d of %d: %s (%s)" % (n, len(features), label, kind))
            row = {"name": label, "kind": kind, "coverage": feature.get("coverage")}
            try:
                reply = build_feature(mcp, feature, cad_id, label)
                if kind == "sweep":
                    row.update({"profile": feature["profile"], "spinePoints": len(feature["spine"]),
                                "lengthMM": feature.get("lengthMM")})
                elif kind == "revolve":
                    row.update({"profilePoints": len(feature["profile"]), "lengthMM": feature.get("lengthMM")})
                else:
                    row.update({"thicknessMM": feature.get("thicknessMM"), "areaMM2": feature.get("areaMM2")})
                if reply.get("failed"):
                    raise MCPError("feature." + kind, reply.get("message", "did not build"))
                body = next((b for b in reply.get("bodies", []) if b["id"] == cad_id), None)
                row["volumeMM3"] = body["volumeMM3"] if body else None
                row["ok"] = True
                print("   ok: volume %s mm³" % (("%.0f" % body["volumeMM3"]) if body else "?"), flush=True)
            except MCPError as error:
                row.update({"ok": False, "error": str(error)[:400]})
                print("   REFUSED:", str(error)[:200], flush=True)
                # The failed node stays in the history as a feature that did
                # not build; undo it so the next one starts clean.
                try:
                    mcp.os3d("command.run", {"id": "edit.undo"}, note="undo the refused feature")
                except MCPError:
                    pass
            built.append(row)
            mcp.os3d("item.setHidden", {"allSketches": True})
        summary["features"] = built
        s.shot("07-features-iso", "isometric")

        s.step("Check the solid")
        check = mcp.os3d("check", {"body": cad_id}, note="is the model still one valid closed solid")
        health_row = check["bodies"][0]["health"]
        print("   valid", health_row["valid"], "findings", health_row.get("findings"), flush=True)
        summary["check"] = {"valid": health_row["valid"], "findings": health_row.get("findings"),
                            "counts": health_row.get("counts")}
        state = mcp.os3d("state")
        summary["cad"] = next(b for b in state["bodies"] if b["id"] == cad_id)

        s.step("Pictures of both")
        s.shot("08-both-iso", "isometric")
        s.shot("08-both-front", "front")
        mcp.os3d("item.setHidden", {"ids": [scan_id]}, note="scan hidden: the model alone")
        s.shot("09-cad-iso", "isometric")
        s.shot("09-cad-front", "front")
        mcp.os3d("view.visualize", {"preset": "Studio", "background": "color", "backgroundColor": [1, 1, 1],
                                    "groundShadow": True}, note="a render-style picture")
        time.sleep(1.0)
        s.shot("06-cad-visualize", "isometric", 1600, 1200)
        mcp.os3d("view.visualize", {"off": True})
        mcp.os3d("item.setHidden", {"ids": [scan_id], "hidden": False}, note="scan back")
        mcp.os3d("item.select", {"ids": []})

        s.step("Accuracy report from the app")
        report = mcp.os3d("accuracy", {"reference": scan_id, "model": cad_id, "tolerance": args.tolerance,
                                       "views": ["front", "top", "right"]},
                          note="silhouette overlays + surface deviation, both ways, with the features in")
        with open(os.path.join(args.run, "accuracy.json"), "w") as f:
            json.dump(report, f, indent=1)
        print("   " + report["summary"], flush=True)
        overlays = {}
        for view in ("front", "top", "right"):
            data = mcp.os3d("accuracy.image", {"reference": scan_id, "model": cad_id, "view": view,
                                               "tolerance": args.tolerance, "width": 1400},
                            note="overlay picture, %s" % view)
            path = os.path.join(args.run, "overlays", view + ".jpg")
            with open(path, "wb") as f:
                f.write(data)
            overlays[view] = path
        summary["accuracy"] = {"overallIoU": report["overallIoU"], "summary": report["summary"],
                               "referenceToModel": report["referenceToModel"],
                               "modelToReference": report["modelToReference"],
                               "overlays": {o["view"]: {"iou": o["iou"], "boundaryMeanMM": o["boundaryMeanMM"],
                                                        "boundaryP95MM": o["boundaryP95MM"]}
                                            for o in report["overlays"]},
                               "overlayImages": overlays, "json": os.path.join(args.run, "accuracy.json")}

        s.step("Export")
        for fmt in ("stl", "step", "obj"):
            path, reply = s.export(name + "-cad", fmt, body=cad_id)
            summary["exports"][fmt] = {"path": path, "bytes": reply["bytes"], "sizeMM": reply.get("sizeMM")}
            print("   ", fmt, path, reply.get("sizeMM"), flush=True)
        summary["calls"] = summary.get("calls", 0) + len(mcp.calls)
        summary["secondsInApp"] = round(summary.get("secondsInApp", 0) + sum(c["seconds"] for c in mcp.calls), 2)
        with open(os.path.join(args.run, "transcript-features.md"), "w") as f:
            f.write(mcp.transcript_markdown("Features over MCP — " + name))
        with open(os.path.join(args.run, "summary.json"), "w") as f:
            json.dump(summary, f, indent=1, default=str)
        ok = sum(1 for r in built if r.get("ok"))
        print("done: %d of %d features built, %d MCP calls; overlap %.1f%%" % (
            ok, len(built), len(mcp.calls), report["overallIoU"] * 100), flush=True)


if __name__ == "__main__":
    try:
        main()
    except MCPError as error:
        print("MCP call failed:", error, file=sys.stderr)
        sys.exit(1)
