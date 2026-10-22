#!/usr/bin/env python3
"""Turn a 3D scan of a turned part into a CAD model in OpenShape 3D, through
the MCP server, and have the app grade the result.

    python3 build_hydrant.py --scan scan.glb --analysis analysis/ --out run/ --port 8947 \
        [--name bollard --label "Bollard" --color 0.75 0.75 0.72]

Every step is an `os3d` tool call to `scripts/mcp_openshape3d.py` — the
same server Claude Desktop and Claude Code use — so this is a full test of
the MCP surface: import (a development-build op), sketches, a revolve,
extrude-with-union bosses, materials, views, screenshots, check, the new
`accuracy` / `accuracy.image` ops, and export. The app has to be running a
DEBUG build with the agent bridge on (`docs/AGENT_CONTROL.md`).

What it writes into `--out`:

    transcript.md          every MCP call, in order, with what came back
    mcp_client_calls.jsonl the same, machine-readable (plus the server's own log)
    shots/*.jpg            the viewport after each step (iso, front, top, right)
    overlays/*.jpg         the app's accuracy overlays, one per view
    accuracy.json          the app's full accuracy report
    stages/*.stl           the model after each feature, for the video
    hydrant-cad.{stl,step,obj}   the finished model; scan.stl the reference
    summary.json           ids, numbers and paths the report and video use

The recipe (`analysis/profile.json` from `analyze_scan.py`):

1. Import the scan where it is — the model is built on the scan's own axis,
   so the accuracy report compares them in place, no registration.
2. A vertical sketch on the fitted axis: the radial profile as a closed
   polyline, revolved 360°. That is the barrel, flanges, bonnet and nut.
3. Each detected boss (a hose nozzle, the pumper): a circle on a sketch
   perpendicular to its direction, extruded from inside the body out to
   its reach and unioned; the cap as a second, wider extrude.
4. Materials for the pictures, check the solid, compare against the scan,
   export.
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
from fit_primitives import hollow_section, sketch_entities  # noqa: E402


def unit(v):
    v = np.asarray(v, dtype=float)
    return v / np.linalg.norm(v)


def world(axis_origin, axis, u, v, radius, height, azimuth_deg=None):
    """A point at `height` up the axis and `radius` out along `azimuth`."""
    p = np.asarray(axis_origin) + axis * height
    if azimuth_deg is not None and radius:
        a = math.radians(azimuth_deg)
        p = p + (math.cos(a) * u + math.sin(a) * v) * radius
    return [float(x) for x in p]


def lines_for(points):
    """Closed loop of line entities through `points` (sketch (u, v) mm)."""
    out = []
    for i in range(len(points)):
        a, b = points[i], points[(i + 1) % len(points)]
        if abs(a[0] - b[0]) < 1e-9 and abs(a[1] - b[1]) < 1e-9:
            continue
        out.append({"kind": "line", "a": [round(a[0], 3), round(a[1], 3)], "b": [round(b[0], 3), round(b[1], 3)]})
    return out


def dedupe(points):
    """`points` without consecutive repeats (each would be a zero-length line)."""
    out = [points[0]]
    for p in points[1:]:
        if abs(p[0] - out[-1][0]) > 1e-6 or abs(p[1] - out[-1][1]) > 1e-6:
            out.append(p)
    return out


def body_section(analysis):
    """The body's half-section to revolve — one answer for the build, the
    film (`demo_video.py take`) and the reel, so a film shows the model the
    inspection graded. Sketch coordinates: u = radius, v = height, the axis
    at u = 0. Returns {"entities", "seed" (a point inside the loop), "note"
    (for the transcript), "hollow" ({wallMM, measuredWallMM, openEnd} for a
    container, else None), "outline" (the straightened profile closed along
    the axis — the Pappus check's polygon)}."""
    profile, height, body_r = analysis["profile"], analysis["heightMM"], analysis["bodyRadiusMM"]
    cleaned = dedupe([[0.0, 0.0]] + [[max(r, 0.0), h] for r, h in profile] + [[0.0, height]])
    segments = analysis.get("profileSegments")
    open_top = analysis.get("openTop")
    seed = [body_r * 0.5, height * 0.5]
    hollow = None
    if open_top and segments:
        # A container: one revolve of a hollow half-section — the outer
        # profile, the rim at the open end, the inner profile a wall in,
        # and a floor at the closed end. (The kernel's shell offset
        # refused the ribbed barrel at every thickness.)
        end = open_top.get("end", "top")
        min_r = min(min(s["a"][0], s["b"][0]) for s in segments)
        # A wall thicker than the profile's smallest feature folds the
        # inner offset over itself (the barrel's 13.7 mm "wall" — read
        # off its rolled rim — against 4–8 mm steps and r 25 ribs): cap
        # it at six tenths of the smallest step or arc, and under half
        # the smallest radius.
        sizes = [s["radius"] for s in segments if s["kind"] == "arc"]
        sizes += [abs(s["b"][1] - s["a"][1]) for s in segments[1:-1]
                  if s["kind"] == "line" and abs(s["b"][1] - s["a"][1]) >= 2.0]      # the runs between steps
        wall = min(open_top["wallMM"], 0.45 * min_r)
        if sizes:
            wall = min(wall, 0.6 * min(sizes))
        wall = float(max(1.5, wall))
        entities = sketch_entities(hollow_section(segments, height, wall, end))
        foot_r = segments[0]["a"][0] if end == "top" else segments[-1]["b"][0]
        seed = [max(foot_r * 0.5, 1.0), wall * 0.5 if end == "top" else height - wall * 0.5]     # in the floor
        arcs = sum(e["kind"] == "arc" for e in entities)
        note = "{} entities ({} arcs): a hollow half-section, {} mm wall, open at the {}".format(
            len(entities), arcs, round(wall, 1), end)
        hollow = {"wallMM": wall, "measuredWallMM": open_top["wallMM"], "openEnd": end}
    elif segments and any(s["kind"] == "arc" for s in segments):
        # Lines and arcs from the analysis (a dome is an arc), closed
        # along the axis: (0,0) → the profile's foot … its top → (0, height).
        foot, top = segments[0]["a"], segments[-1]["b"]
        entities = ([{"kind": "line", "a": [0.0, 0.0], "b": [round(max(foot[0], 0.0), 4), round(foot[1], 4)]}]
                    + sketch_entities(segments)
                    + [{"kind": "line", "a": [round(max(top[0], 0.0), 4), round(top[1], 4)], "b": [0.0, round(float(height), 4)]},
                       {"kind": "line", "a": [0.0, round(float(height), 4)], "b": [0.0, 0.0]}])
        entities = [e for e in entities if e["kind"] != "line" or
                    abs(e["a"][0] - e["b"][0]) > 1e-6 or abs(e["a"][1] - e["b"][1]) > 1e-6]
        arcs = sum(e["kind"] == "arc" for e in entities)
        note = "{} entities ({} arcs): half the cross-section, axis at u = 0".format(len(entities), arcs)
    else:
        entities = lines_for(cleaned)
        note = "{} lines: half the cross-section, axis at u = 0".format(len(entities))
    return {"entities": entities, "seed": seed, "note": note, "hollow": hollow, "outline": cleaned}


def boss_section(boss):
    """A boss's measured radius-along profile closed back along its own axis
    (sketch u across the boss, v along it), and a seed inside the loop:
    (entities, seed)."""
    prof = [[max(r, 1.0), s] for r, s in boss["profile"]]
    loop = dedupe([[0.0, 0.0], [prof[0][0], 0.0]] + prof + [[0.0, prof[-1][1]]])
    return lines_for(loop), [max(prof[0][0] * 0.4, 2.0), prof[-1][1] * 0.3]


class Session:
    def __init__(self, mcp, out, name):
        self.mcp = mcp
        self.out = out
        self.name = name
        self.summary = {"name": name, "steps": [], "shots": {}, "stages": [], "exports": {}}
        for d in ("shots", "overlays", "stages"):
            os.makedirs(os.path.join(out, d), exist_ok=True)

    def step(self, title):
        print("==", title, flush=True)
        self.summary["steps"].append({"title": title, "t": time.time()})

    def shot(self, key, view=None, width=1400, height=1000):
        if view:
            self.mcp.os3d("command.run", {"id": "view." + view})
            self.mcp.os3d("command.run", {"id": "view.fit"})
            time.sleep(1.2)                         # standard views animate
        data = self.mcp.os3d("screenshot", {"width": width, "height": height}, note="viewport " + key)
        path = os.path.join(self.out, "shots", key + ".jpg")
        with open(path, "wb") as f:
            f.write(data)
        self.summary["shots"][key] = path
        return path

    def export(self, name, fmt, body=None, up="y", folder=None):
        args = {"format": fmt, "up": up, "name": name,
                "path": os.path.join(folder or self.out, "{}.{}".format(name, fmt))}
        if body:
            args["body"] = [body] if isinstance(body, str) else list(body)
        reply = self.mcp.os3d("document.export", args, note="export " + name)
        return reply["path"], reply

    def stage(self, label, body):
        path, _ = self.export(label, "stl", body=body, folder=os.path.join(self.out, "stages"))
        self.summary["stages"].append({"label": label, "path": path})
        return path


def build(args):
    with open(os.path.join(args.analysis, "profile.json")) as f:
        analysis = json.load(f)
    axis_origin = np.array(analysis["axisOrigin"])
    axis = unit(analysis["axisDirection"])
    u = unit(analysis["azimuthZero"])
    v = unit(analysis["azimuthNinety"])
    profile = analysis["profile"]
    height = analysis["heightMM"]
    body_r = analysis["bodyRadiusMM"]

    with MCPClient(port=args.port, log_dir=args.out) as mcp:
        s = Session(mcp, args.out, args.name)

        s.step("MCP handshake")
        mcp.initialize()
        s.summary["server"] = mcp.server_info
        s.summary["tools"] = mcp.tool_names()
        print("   server", mcp.server_info, "tools", mcp.tool_names())
        health = mcp.os3d("health", note="is the app there, is a design open")
        if not health.get("hasDocument"):
            sys.exit("open a design in the app first (launch with OS3D_FRESH=1)")
        state = mcp.os3d("state", note="what is in the design before we start")
        if state["bodies"]:
            print("   note: the design already holds", len(state["bodies"]), "bodies")

        s.step("Import the scan")
        reply = mcp.os3d("document.import", {"path": os.path.abspath(args.scan),
                                             "fileName": os.path.basename(args.scan)},
                         note="the scan becomes a mesh body, placed as the file places it")
        scan_id = reply["bodyIDs"][0]
        scan = next(b for b in reply["bodies"] if b["id"] == scan_id)
        s.summary["scan"] = {"id": scan_id, "triangles": reply["triangles"], "bounds": scan["bounds"],
                             "name": scan["name"]}
        print("   scan", scan["name"], reply["triangles"], "triangles, bounds", np.round(scan["bounds"], 1).tolist())
        mcp.os3d("body.setMaterial", {"bodyIDs": [scan_id], "color": [0.55, 0.62, 0.72, 0.4], "roughness": 0.9},
                 note="a see-through grey-blue for the scan, so the model shows inside it")
        s.shot("01-scan-iso", "isometric")
        s.shot("01-scan-front", "front")

        s.step("Revolve the profile")
        plane = {"origin": world(axis_origin, axis, u, v, 0, 0), "xAxis": [float(x) for x in u],
                 "yAxis": [float(x) for x in axis], "name": args.label + " profile"}
        sketch = mcp.os3d("sketch.create", plane, note="a vertical sketch on the scan's own axis")["sketchID"]
        # The half-section (`body_section`): lines, arcs for a dome or a
        # belly, a hollow section for a container — the film and the reel
        # revolve the same one.
        section = body_section(analysis)
        cleaned, entities, seed, note = section["outline"], section["entities"], section["seed"], section["note"]
        if section["hollow"]:
            s.summary["hollow"] = section["hollow"]
            print("   open at the %s (rays fall %.0f mm in): hollow section, wall %.1f mm" % (
                section["hollow"]["openEnd"], analysis["openTop"]["depthMM"], section["hollow"]["wallMM"]))
        mcp.os3d("sketch.addEntities", {"sketchID": sketch, "entities": entities}, note=note)
        reply = mcp.os3d("feature.revolve", {"sketchID": sketch, "seedPoint": seed, "axisPoint": [0, 0],
                                             "axisDirection": [0, 1], "angleDegrees": 360},
                         note="360° about the axis")
        cad_id = reply["producedBodyIDs"][0]
        cad = next(b for b in reply["bodies"] if b["id"] == cad_id)
        # Pappus check: the revolve's volume from the profile's own area.
        area = 0.0
        cx = 0.0
        pts = cleaned
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            cross = a[0] * b[1] - b[0] * a[1]
            area += cross
            cx += (a[0] + b[0]) * cross
        area = abs(area) / 2
        centroid_u = abs(cx) / (6 * area) if area else 0
        pappus = 2 * math.pi * centroid_u * area
        print("   revolve volume %.0f mm³, Pappus from the profile %.0f mm³ (%.2f%%)" % (
            cad["volumeMM3"], pappus, (cad["volumeMM3"] / pappus - 1) * 100 if pappus else 0))
        s.summary["revolve"] = {"id": cad_id, "volumeMM3": cad["volumeMM3"], "pappusMM3": pappus,
                                "profilePoints": len(cleaned)}
        mcp.os3d("body.setMaterial", {"bodyIDs": [cad_id], "color": list(args.color), "roughness": 0.45},
                 note="the model's colour")
        mcp.os3d("item.setHidden", {"allSketches": True}, note="hide the construction sketch")
        s.shot("02-revolve-iso", "isometric")
        s.stage("stage-1-revolve", cad_id)

        bosses = [b for b in analysis["bosses"] if b["reachMM"] - b["bodyRadiusMM"] > 15]
        for n, boss in enumerate(bosses, 1):
            s.step("Boss %d of %d: azimuth %.0f°, height %.0f mm, reach %.0f mm" % (
                n, len(bosses), boss["azimuthDeg"], boss["centerHeightMM"], boss["reachMM"]))
            az = boss["azimuthDeg"]
            d = unit(math.cos(math.radians(az)) * u + math.sin(math.radians(az)) * v)
            t = unit(np.cross(axis, d))
            reach = boss["reachMM"]
            if boss.get("profile"):
                # A body of revolution about the boss's own axis: the sketch's
                # u is across (t), v is along the boss (d); the measured
                # radius-along profile, closed back along the axis.
                inner = boss.get("innerStartMM", boss["bodyRadiusMM"] - 12.0)
                prof = [[max(r, 1.0), s] for r, s in boss["profile"]]
                entities, seed = boss_section(boss)
                origin = world(axis_origin, axis, u, v, inner, boss["centerHeightMM"], az)
                sk = mcp.os3d("sketch.create", {"origin": origin, "xAxis": [float(x) for x in t],
                                                "yAxis": [float(x) for x in d], "name": "Boss %d" % n},
                              note="a sketch through the boss's own axis")["sketchID"]
                mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": entities},
                         note="%d lines: the boss's half-profile, its axis at u = 0" % len(entities))
                reply = mcp.os3d("feature.revolve", {"sketchID": sk, "seedPoint": seed, "axisPoint": [0, 0],
                                                     "axisDirection": [0, 1], "angleDegrees": 360,
                                                     "boolean": "union", "booleanTargets": [cad_id]},
                                 note="revolved about its axis and unioned into the body")
                vol = next(b for b in reply["bodies"] if b["id"] == cad_id)["volumeMM3"]
                print("   %d-point profile, radius %.0f → %.0f mm over %.0f mm; volume → %.0f mm³" % (
                    len(prof), prof[0][0], prof[-1][0], prof[-1][1], vol))
                s.summary.setdefault("bosses", []).append({
                    "azimuthDeg": az, "centerHeightMM": boss["centerHeightMM"], "reachMM": reach,
                    "neckRadiusMM": boss.get("neckWidthMM", 0) / 2, "capRadiusMM": boss.get("widthMM", 0) / 2,
                    "profilePoints": len(prof), "volumeMM3": vol})
            else:
                inner = boss["bodyRadiusMM"] - 12.0                 # start inside the body: unions want overlap
                protrusion = reach - boss["bodyRadiusMM"]
                cap_len = max(min(protrusion * 0.3, 30.0), 8.0)
                # The neck never reads wider than the cap: a chain or a flared
                # casting beside the neck inflates its measured width.
                neck_r = max(min(boss.get("neckWidthMM", boss["widthMM"] * 0.85), boss["widthMM"] * 0.88) / 2, 8.0)
                cap_r = max(boss["widthMM"] / 2, neck_r + 2.0)
                origin = world(axis_origin, axis, u, v, inner, boss["centerHeightMM"], az)
                sk = mcp.os3d("sketch.create", {"origin": origin, "xAxis": [float(x) for x in t],
                                                "yAxis": [float(x) for x in axis], "name": "Boss %d" % n},
                              note="a sketch facing along the boss")["sketchID"]
                mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": [
                    {"kind": "circle", "center": [0, 0], "radius": round(neck_r, 2)}]})
                length = reach - cap_len - inner
                reply = mcp.os3d("feature.extrude", {"sketchID": sk, "seedPoint": [0, 0], "distance": round(length, 2),
                                                     "boolean": "union", "booleanTargets": [cad_id]},
                                 note="the nozzle, unioned into the body")
                vol_after_neck = next(b for b in reply["bodies"] if b["id"] == cad_id)["volumeMM3"]
                cap_origin = world(axis_origin, axis, u, v, reach - cap_len - 2.0, boss["centerHeightMM"], az)
                sk2 = mcp.os3d("sketch.create", {"origin": cap_origin, "xAxis": [float(x) for x in t],
                                                 "yAxis": [float(x) for x in axis], "name": "Cap %d" % n})["sketchID"]
                mcp.os3d("sketch.addEntities", {"sketchID": sk2, "entities": [
                    {"kind": "circle", "center": [0, 0], "radius": round(cap_r, 2)}]})
                reply = mcp.os3d("feature.extrude", {"sketchID": sk2, "seedPoint": [0, 0], "distance": round(cap_len + 2.0, 2),
                                                     "boolean": "union", "booleanTargets": [cad_id]},
                                 note="the cap")
                vol = next(b for b in reply["bodies"] if b["id"] == cad_id)["volumeMM3"]
                print("   neck r %.1f length %.1f, cap r %.1f length %.1f; volume %.0f → %.0f mm³" % (
                    neck_r, length, cap_r, cap_len, vol_after_neck, vol))
                s.summary.setdefault("bosses", []).append({
                    "azimuthDeg": az, "centerHeightMM": boss["centerHeightMM"], "neckRadiusMM": neck_r,
                    "capRadiusMM": cap_r, "reachMM": reach, "volumeMM3": vol})
            mcp.os3d("item.setHidden", {"allSketches": True})
            s.shot("03-boss-%d-iso" % n, "isometric")
            s.stage("stage-%d-boss-%d" % (n + 1, n), cad_id)

        s.step("Check the solid")
        check = mcp.os3d("check", {"body": cad_id}, note="is the model a valid closed solid")
        health_row = check["bodies"][0]["health"]
        print("   valid", health_row["valid"], "findings", health_row.get("findings"),
              "faces", health_row.get("counts", {}).get("faces"))
        s.summary["check"] = {"valid": health_row["valid"], "findings": health_row.get("findings"),
                              "counts": health_row.get("counts")}
        state = mcp.os3d("state")
        s.summary["cad"] = next(b for b in state["bodies"] if b["id"] == cad_id)
        s.summary["cad"]["brep"] = s.summary["cad"].get("brep")

        s.step("Pictures of both")
        s.shot("04-both-iso", "isometric")
        s.shot("04-both-front", "front")
        s.shot("04-both-top", "top")
        s.shot("04-both-right", "right")
        mcp.os3d("item.setHidden", {"ids": [scan_id]}, note="scan hidden: the model alone")
        s.shot("05-cad-iso", "isometric")
        s.shot("05-cad-front", "front")
        mcp.os3d("view.visualize", {"preset": "Studio", "background": "color", "backgroundColor": [1, 1, 1],
                                    "groundShadow": True}, note="a render-style picture")
        time.sleep(1.0)
        s.shot("06-cad-visualize", "isometric", 1600, 1200)
        mcp.os3d("view.visualize", {"off": True})
        mcp.os3d("item.setHidden", {"ids": [scan_id], "hidden": False}, note="scan back")

        s.step("Accuracy report from the app")
        report = mcp.os3d("accuracy", {"reference": scan_id, "model": cad_id, "tolerance": args.tolerance,
                                       "views": ["front", "top", "right"]},
                          note="silhouette overlays + surface deviation, both ways")
        with open(os.path.join(args.out, "accuracy.json"), "w") as f:
            json.dump(report, f, indent=1)
        print("   " + report["summary"])
        overlays = {}
        for view in ("front", "top", "right"):
            data = mcp.os3d("accuracy.image", {"reference": scan_id, "model": cad_id, "view": view,
                                               "tolerance": args.tolerance, "width": 1400},
                            note="overlay picture, %s" % view)
            path = os.path.join(args.out, "overlays", view + ".jpg")
            with open(path, "wb") as f:
                f.write(data)
            overlays[view] = path
        s.summary["accuracy"] = {"overallIoU": report["overallIoU"], "summary": report["summary"],
                                 "referenceToModel": report["referenceToModel"],
                                 "modelToReference": report["modelToReference"],
                                 "overlays": {o["view"]: {"iou": o["iou"], "boundaryMeanMM": o["boundaryMeanMM"],
                                                          "boundaryP95MM": o["boundaryP95MM"]}
                                              for o in report["overlays"]},
                                 "overlayImages": overlays, "json": os.path.join(args.out, "accuracy.json")}

        s.step("Export")
        for fmt in ("stl", "step", "obj"):
            path, reply = s.export(args.name + "-cad", fmt, body=cad_id)
            s.summary["exports"][fmt] = {"path": path, "bytes": reply["bytes"], "sizeMM": reply.get("sizeMM")}
            print("   ", fmt, path, reply.get("sizeMM"))
        path, reply = s.export("scan", "stl", body=scan_id)
        s.summary["exports"]["scan"] = {"path": path, "bytes": reply["bytes"]}
        archive = os.path.join(args.out, args.name + ".os3d")
        s.summary["design"] = archive

        s.summary["calls"] = len(mcp.calls)
        s.summary["secondsInApp"] = round(sum(c["seconds"] for c in mcp.calls), 2)
        with open(os.path.join(args.out, "transcript.md"), "w") as f:
            f.write(mcp.transcript_markdown("Scan to CAD over MCP — " + args.name))
        with open(os.path.join(args.out, "summary.json"), "w") as f:
            json.dump(s.summary, f, indent=1, default=str)
        print("done: %d MCP calls, %.1f s in the app; overlap %.1f%%" % (
            len(mcp.calls), s.summary["secondsInApp"], report["overallIoU"] * 100))
        return s.summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan", required=True)
    ap.add_argument("--analysis", required=True, help="folder with profile.json from analyze_scan.py")
    ap.add_argument("--out", default="run")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--name", default="hydrant", help="file names: <name>-cad.step and friends")
    ap.add_argument("--label", default="Hydrant", help="what the part is, for the sketch names")
    ap.add_argument("--color", type=float, nargs=3, default=[0.86, 0.17, 0.12], metavar=("R", "G", "B"),
                    help="the model's colour (default hydrant red)")
    ap.add_argument("--tolerance", type=float, default=2.0, help="mm; what counts as within tolerance")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    try:
        build(args)
    except MCPError as error:
        print("MCP call failed:", error, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
