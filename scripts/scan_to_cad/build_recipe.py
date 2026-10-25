#!/usr/bin/env python3
"""Build a CAD model in OpenShape 3D from a recipe — a JSON list of sketch
features (extrudes with line-and-arc outlines, revolves with radial
profiles) in the reference mesh's own frame — through the MCP server, then
export every body for `inspect_fit.py`.

    python3 build_recipe.py recipe.json --out run/ --port 8947 [--reference prep/reference.stl]

The recipe:

    {"name": "clamp", "color": [0.72, 0.72, 0.7],
     "parts": [
       {"name": "rib", "kind": "extrude",
        "plane": {"origin": [0,0,-15], "xAxis": [1,0,0], "yAxis": [0,1,0]},
        "segments": [{"kind":"line","a":[..],"b":[..]}, {"kind":"arc","center":[..],"radius":r,"start":rad,"end":rad,"ccw":true}, …],
        "distance": 30},
       {"name": "plate", "kind": "extrude", "plane": {…}, "segments": […], "distance": 10,
        "boolean": "union", "target": "rib"},
       {"name": "bore", "kind": "extrude", "plane": {…}, "circle": {"center":[0,0],"radius":6.9},
        "distance": 31, "boolean": "subtract", "target": "rib"},
       {"name": "screw", "kind": "revolve",
        "axis": {"origin": [x,y,z], "direction": [dx,dy,dz]},
        "profile": [[r, h], …]}                     # open polyline from the axis out and back; closed along the axis
       {"name": "ball", "kind": "revolve", "axis": {…}, "arc": {"radius": 12.5}}   # a sphere
     ]}

`plane` is world mm: the sketch's u along `xAxis`, v along `yAxis`, and an
extrude goes `distance` along xAxis × yAxis. A `boolean` part names its
`target` part and changes that body in place. Every part keeps a world
transform of none — the model is built where the reference is, so the
comparison needs no registration.

Writes into `--out`: `summary.json` (part → body id, bounds, volume),
`<name>-cad.stl` (every model body), `transcript.md`, the MCP logs, and
if `--reference` is given imports it first (hidden, so the model's
pictures are clean) and leaves it in the design for the app's own
Accuracy Report.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import MCPClient, MCPError  # noqa: E402
from fit_primitives import sketch_entities  # noqa: E402


def unit(v):
    v = np.asarray(v, dtype=float)
    return v / np.linalg.norm(v)


def point_in_polygon(pt, loop):
    x, y = pt
    inside = False
    n = len(loop)
    for i in range(n):
        x0, y0 = loop[i]
        x1, y1 = loop[(i + 1) % n]
        if (y0 > y) != (y1 > y):
            xi = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
            if x < xi:
                inside = not inside
    return inside


def loop_points(segments, step=1.0):
    """The outline as a dense polyline (arcs sampled), for seed finding."""
    pts = []
    for s in segments:
        if s["kind"] == "line":
            pts.append(s["a"])
        else:
            c, r = s["center"], s["radius"]
            sa, sb = (s["start"], s["end"]) if s["ccw"] else (s["end"], s["start"])
            while sb <= sa:
                sb += 2 * math.pi
            k = max(4, int(r * (sb - sa) / step))
            angles = np.linspace(sa, sb, k + 1)
            if not s["ccw"]:
                angles = angles[::-1]
            for t in angles[:-1]:
                pts.append([c[0] + r * math.cos(t), c[1] + r * math.sin(t)])
    return pts


def seed_inside(segments):
    """A point inside the outline: walk inward from edge midpoints until one lands inside."""
    loop = loop_points(segments)
    n = len(loop)
    arr = np.array(loop)
    for i in range(n):
        a, b = arr[i], arr[(i + 1) % n]
        mid = (a + b) / 2
        e = b - a
        if np.linalg.norm(e) < 1e-6:
            continue
        nrm = np.array([-e[1], e[0]]) / np.linalg.norm(e)
        for side in (1, -1):
            for d in (0.5, 1.0, 2.0, 4.0):
                p = mid + side * nrm * d
                if point_in_polygon(p, loop):
                    return [float(p[0]), float(p[1])]
    c = arr.mean(axis=0)
    return [float(c[0]), float(c[1])]


def closed_profile(profile):
    """Whether a revolve profile is a closed loop of its own (its first and
    last points coincide): a hoop's annular section, which must not be
    closed along the axis — that would fill a bucket."""
    return len(profile) >= 4 and abs(profile[0][0] - profile[-1][0]) < 1e-6 and abs(profile[0][1] - profile[-1][1]) < 1e-6


def revolve_region(profile):
    """The entities of a revolve profile and a seed point inside them: the
    half-section closed along the axis, seeded near the axis at mid-height
    (as every revolve was), or a closed section as it is, seeded at its
    own centroid (a hoop round a hollow body)."""
    ents, pts = revolve_entities(profile)
    if closed_profile(profile):
        loop = np.array(pts, dtype=float)
        seed = loop.mean(axis=0)
        return ents, [float(seed[0]), float(seed[1])]
    rs = [p[0] for p in pts if p[0] > 0]
    hs = [p[1] for p in pts]
    return ents, [min(rs) * 0.5, (min(hs) + max(hs)) / 2]


def revolve_entities(profile, h_close=None):
    """Lines for a half-section: axis at u = 0, from (0, h0) out along the
    profile and back to the axis at (0, h1); a closed profile (first point
    = last) is drawn as the loop it is."""
    if closed_profile(profile):
        pts = [[max(r, 0.0), h] for r, h in profile[:-1]]
    else:
        pts = [[0.0, profile[0][1]]] + [[max(r, 0.0), h] for r, h in profile] + [[0.0, profile[-1][1]]]
    cleaned = [pts[0]]
    for p in pts[1:]:
        if abs(p[0] - cleaned[-1][0]) > 1e-6 or abs(p[1] - cleaned[-1][1]) > 1e-6:
            cleaned.append(p)
    ents = []
    for a, b in zip(cleaned, cleaned[1:] + cleaned[:1]):
        if abs(a[0] - b[0]) > 1e-6 or abs(a[1] - b[1]) > 1e-6:
            ents.append({"kind": "line", "a": [round(a[0], 4), round(a[1], 4)], "b": [round(b[0], 4), round(b[1], 4)]})
    return ents, cleaned


def radial_frame(direction):
    d = unit(direction)
    ref = np.array([0.0, 0.0, 1.0]) if abs(d[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    u = unit(ref - (ref @ d) * d)
    return u, d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recipe")
    ap.add_argument("--out", default="run")
    ap.add_argument("--port", type=int, default=8947)
    ap.add_argument("--reference", default=None, help="mesh to import first (mm STL/OBJ or a GLB in metres)")
    args = ap.parse_args()
    with open(args.recipe) as f:
        recipe = json.load(f)
    os.makedirs(args.out, exist_ok=True)
    colour = recipe.get("color", [0.72, 0.72, 0.7])
    summary = {"name": recipe.get("name", "part"), "parts": {}, "bodies": {}}

    with MCPClient(port=args.port, log_dir=args.out) as mcp:
        mcp.initialize()
        health = mcp.os3d("health")
        if not health.get("hasDocument"):
            sys.exit("open a design in the app first (launch with OS3D_FRESH=1)")
        if args.reference:
            reply = mcp.os3d("document.import", {"path": os.path.abspath(args.reference),
                                                 "fileName": os.path.basename(args.reference)},
                             note="the reference mesh, where the file places it")
            ref_ids = reply["bodyIDs"]
            summary["reference"] = {"ids": ref_ids, "triangles": reply.get("triangles"),
                                    "bounds": [b["bounds"] for b in reply["bodies"] if b["id"] in ref_ids]}
            mcp.os3d("item.select", {"ids": []})
            mcp.os3d("body.setMaterial", {"bodyIDs": ref_ids, "color": [0.55, 0.62, 0.72, 0.4], "roughness": 0.9})
            print("reference:", len(ref_ids), "bodies,", reply.get("triangles"), "triangles")

        bodies = {}          # part name → body id
        for part in recipe["parts"]:
            name = part["name"]
            kind = part["kind"]
            boolean = part.get("boolean")
            target = bodies.get(part.get("target")) if boolean else None
            if boolean and target is None:
                sys.exit("%s: boolean target %r has no body yet" % (name, part.get("target")))
            if kind == "extrude":
                pl = part["plane"]
                sk = mcp.os3d("sketch.create", {"origin": pl["origin"], "xAxis": pl["xAxis"], "yAxis": pl["yAxis"],
                                                "name": name}, note="sketch for " + name)["sketchID"]
                if "segments" in part:
                    ents = sketch_entities(part["segments"])
                    seed = part.get("seed") or seed_inside(part["segments"])
                elif "circle" in part:
                    c = part["circle"]
                    ents = [{"kind": "circle", "center": c["center"], "radius": c["radius"]}]
                    seed = c["center"]
                else:
                    sys.exit(name + ": an extrude needs segments or a circle")
                mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": ents},
                         note="%d entities (%d arcs)" % (len(ents), sum(e["kind"] == "arc" for e in ents)))
                req = {"sketchID": sk, "seedPoint": seed, "distance": part["distance"]}
                if part.get("symmetric"):
                    req["symmetric"] = True
                if boolean:
                    req["boolean"] = boolean
                    req["booleanTargets"] = [target]
                reply = mcp.os3d("feature.extrude", req, note="%s: extrude %.2f mm%s" % (
                    name, part["distance"], " (%s into %s)" % (boolean, part.get("target")) if boolean else ""))
            elif kind == "revolve":
                ax = part["axis"]
                u, d = radial_frame(ax["direction"])
                origin = [float(x) for x in ax["origin"]]
                sk = mcp.os3d("sketch.create", {"origin": origin, "xAxis": [float(x) for x in u],
                                                "yAxis": [float(x) for x in d], "name": name},
                              note="a sketch through the axis of " + name)["sketchID"]
                if "profile" in part:
                    ents, pts = revolve_entities(part["profile"])
                    rs = [p[0] for p in pts if p[0] > 0]
                    hs = [p[1] for p in pts]
                    seed = part.get("seed") or [min(rs) * 0.5, (min(hs) + max(hs)) / 2]
                elif "arc" in part:
                    r = part["arc"]["radius"]
                    h0 = part["arc"].get("h0", -r)
                    h1 = part["arc"].get("h1", r)
                    # Half-disc: an arc on the +u side from (0, -r) to (0, r), closed by the axis.
                    ents = [{"kind": "arc", "center": [0.0, 0.0], "radius": r, "startAngle": -math.pi / 2, "endAngle": math.pi / 2},
                            {"kind": "line", "a": [0.0, r], "b": [0.0, -r]}]
                    seed = [r * 0.4, 0.0]
                else:
                    sys.exit(name + ": a revolve needs a profile or an arc")
                mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": ents}, note="%d entities" % len(ents))
                req = {"sketchID": sk, "seedPoint": seed, "axisPoint": [0, 0], "axisDirection": [0, 1],
                       "angleDegrees": 360}
                if boolean:
                    req["boolean"] = boolean
                    req["booleanTargets"] = [target]
                reply = mcp.os3d("feature.revolve", req, note="%s: revolve 360°" % name)
            else:
                sys.exit("%s: unknown kind %r" % (name, kind))
            produced = reply.get("producedBodyIDs") or []
            changed = reply.get("changedBodyIDs") or []
            if boolean:
                body = target
            elif produced:
                body = produced[0]
            else:
                sys.exit("%s: no body produced: %s" % (name, json.dumps(reply)[:300]))
            bodies[name] = body
            row = next((b for b in reply.get("bodies", []) if b["id"] == body), {})
            summary["parts"][name] = {"body": body, "bounds": row.get("bounds"), "volumeMM3": row.get("volumeMM3"),
                                      "produced": produced, "changed": changed}
            print("  %-14s %-8s body %s  bounds %s  volume %s" % (
                name, kind, body[:8], np.round(row.get("bounds", []), 1).tolist() if row.get("bounds") else "?",
                ("%.0f" % row["volumeMM3"]) if row.get("volumeMM3") else "?"))
            mcp.os3d("item.setHidden", {"allSketches": True})
        model_ids = sorted(set(bodies.values()), key=lambda i: list(bodies.values()).index(i))
        mcp.os3d("body.setMaterial", {"bodyIDs": model_ids, "color": list(colour), "roughness": 0.45})
        mcp.os3d("item.select", {"ids": []})
        for name, bid in bodies.items():
            summary["bodies"][bid] = name
        # Check every body and export.
        for bid in model_ids:
            check = mcp.os3d("check", {"body": bid})
            health_row = check["bodies"][0]["health"]
            summary["parts"][summary["bodies"][bid]]["valid"] = health_row["valid"]
            if not health_row["valid"]:
                print("  INVALID:", summary["bodies"][bid], health_row.get("findings"))
        path = os.path.join(os.path.abspath(args.out), summary["name"] + "-cad.stl")
        reply = mcp.os3d("document.export", {"format": "stl", "up": "y", "name": summary["name"] + "-cad",
                                             "path": path, "body": model_ids}, note="every model body")
        summary["export"] = reply.get("path", path)
        for name, bid in bodies.items():
            p = os.path.join(os.path.abspath(args.out), "%s-%s.stl" % (summary["name"], name))
            mcp.os3d("document.export", {"format": "stl", "up": "y", "name": name, "path": p, "body": [bid]},
                     note="body of " + name)
            summary["parts"][name]["stl"] = p
        summary["modelBodies"] = model_ids
        summary["calls"] = len(mcp.calls)
        with open(os.path.join(args.out, "transcript.md"), "w") as f:
            f.write(mcp.transcript_markdown("Recipe build — " + summary["name"]))
        with open(os.path.join(args.out, "summary.json"), "w") as f:
            json.dump(summary, f, indent=1, default=str)
        print("done: %d parts, %d bodies, %d MCP calls; %s" % (len(bodies), len(model_ids), len(mcp.calls), path))


if __name__ == "__main__":
    try:
        main()
    except MCPError as error:
        print("MCP call failed:", error, file=sys.stderr)
        sys.exit(1)
