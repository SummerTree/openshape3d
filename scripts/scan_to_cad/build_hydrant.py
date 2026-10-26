#!/usr/bin/env python3
"""Turn a 3D scan of a turned part into a CAD model in OpenShape 3D, through
the MCP server, and have the app grade the result.

    python3 build_hydrant.py --scan scan.glb --analysis analysis/ --out run/ --port 8947 \
        [--name bollard --label "Bollard" --color 0.75 0.75 0.72 | --color scan]

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
   Then each body of revolution on its own axis (a valve's branches),
   unioned in; the polygonal bands (a hex nut) extruded and unioned; and
   last, every passage — a branch's bore the scan shows running on into
   its parent — revolved on the branch's axis and subtracted, after every
   union that could have filled it.
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
from fit_primitives import cavity_section, hollow_section, sketch_entities  # noqa: E402
# Re-exported: the films, the reel and the tests take the colour rule from
# here; `run_corpus.py` imports it from `spec_color` so it stays numpy-free.
from spec_color import HYDRANT_RED, model_color, color_option, nut_words  # noqa: E402,F401


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


def section_seed(loop):
    """A point inside a closed (r, h) polygon: the midpoint of the longest
    horizontal span between two crossings of a scan line through the
    polygon's middle — never on an edge, never in a dish."""
    pts = np.asarray(loop, dtype=float)
    hs = sorted(set(np.round(pts[:, 1], 3)))
    best = None
    for frac in (0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8):
        y = float(pts[:, 1].min() + frac * (pts[:, 1].max() - pts[:, 1].min()))
        if any(abs(y - v) < 1e-6 for v in hs):
            y += 0.37
        xs = []
        n = len(pts)
        for i in range(n):
            a, b = pts[i], pts[(i + 1) % n]
            if (a[1] > y) != (b[1] > y):
                xs.append(a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]))
        xs.sort()
        for x0, x1 in zip(xs[0::2], xs[1::2]):
            if best is None or x1 - x0 > best[0]:
                best = (x1 - x0, (x0 + x1) / 2, y)
        if best and best[0] > 2.0:
            break
    if best is None:
        return [float(pts[:, 0].mean()), float(pts[:, 1].mean())]
    return [float(best[1]), float(best[2])]


def keep_off_axis(entities, margin=0.05):
    """An arc carried to the axis ends a hair past it once its centre and
    radius are rounded (u = −8e-5 on the bollard's dome), and a profile
    that crosses the axis revolves to nothing (`emptyGeometry`). Pull any
    arc end that lands under `margin` from the axis back onto u = margin,
    by moving that end's angle along its own circle."""
    for e in entities:
        if e["kind"] != "arc":
            continue
        c, r = e["center"], e["radius"]
        for key in ("startAngle", "endAngle"):
            theta = e[key]
            if c[0] + r * math.cos(theta) < margin and r > margin:
                cos_t = (margin - c[0]) / r
                if abs(cos_t) <= 1.0:
                    candidate = math.acos(cos_t)
                    # the branch (upper or lower half) nearest the old angle
                    options = [candidate, -candidate, candidate + 2 * math.pi, -candidate + 2 * math.pi]
                    e[key] = min(options, key=lambda t: abs(t - theta))
    return entities


def open_lines(points):
    """Line entities between consecutive distinct points of an OPEN chain
    (no closing line)."""
    pts = dedupe([[float(p[0]), float(p[1])] for p in points]) if points else []
    return [{"kind": "line", "a": [round(a[0], 4), round(a[1], 4)], "b": [round(b[0], 4), round(b[1], 4)]}
            for a, b in zip(pts, pts[1:])]


def bore_chains(analysis, profile, height):
    """The bores at a body's free ends (`analysis["bores"]`, from
    `analyze_scan.detect_bores`) as the point chains the half-section runs
    through instead of a plain end face. Returns (prefix, suffix, bored):
    `prefix` runs from the loop's closing point to the outer profile's foot
    (exclusive) — up the axis from the bore's floor, out to the bore wall,
    along it to the mouth; `suffix` from the outer profile's top (exclusive)
    back to the closing point; `bored` the bores as drawn, for the note.
    Without a bore an end is the axis point, as every revolve was:
    ([[0, 0]], [[0, height]], []).

    Every bore radius is kept a wall inside the outer profile over the
    bore's own depth (the loop must stay simple: a profile that narrows to
    the bore's radius would cross it), capped at the body's length; a bore
    seen along the whole body — or two that meet — is a through bore, an
    annular loop with no axis segment at all."""
    rs = [max(float(r), 0.0) for r, _ in profile]
    hs = [float(hh) for _, hh in profile]

    def outer_min(h0, h1):
        """The smallest outer radius over h0..h1 (the profile's vertices
        inside the range and its radius at both ends)."""
        lo, hi = sorted((h0, h1))
        inside = [r for r, hh in zip(rs, hs) if lo - 1e-6 <= hh <= hi + 1e-6]
        ends = [float(np.interp(h, hs, rs)) for h in (lo, hi)] if len(hs) >= 2 else rs[:1]
        return min(inside + ends) if (inside or ends) else 0.0

    def steps_of(bore):
        prof = bore.get("profile") or [[bore["rInnerMM"], 0.0], [bore["rInnerMM"], bore["depthMM"]]]
        depth = float(min(bore["depthMM"], height))
        through = bool(bore.get("through")) or depth >= height - 0.5
        if through:
            depth = float(height)
        steps = []
        for (r_a, d_a), (r_b, d_b) in zip(prof, prof[1:]):
            if abs(r_a - r_b) > 1e-6 or d_a >= depth:
                continue                                        # a level step between two runs, or past the floor
            steps.append([float(r_a), float(d_a), float(min(d_b, depth))])
        if steps:
            steps[-1][2] = depth
        return steps, depth, through

    bores = {b["end"]: b for b in (analysis.get("bores") or []) if b.get("end") in ("start", "end")}
    drawn = {}
    for end, bore in bores.items():
        steps, depth, through = steps_of(bore)
        if not steps or depth < 1.0:
            continue
        kept = []
        for r, d_a, d_b in steps:
            h0, h1 = (d_a, d_b) if end == "start" else (height - d_b, height - d_a)
            limit = outer_min(h0, h1)
            r = min(r, limit - max(1.0, 0.1 * limit))
            if r < 1.0:
                kept = []
                break
            kept.append([r, d_a, d_b])
        if kept:
            drawn[end] = (kept, depth, through)
    if "start" in drawn and "end" in drawn:
        s, e = drawn["start"], drawn["end"]
        if s[2] or e[2] or s[1] + e[1] >= height - 1.0:
            # They meet: one through bore, from the end that reached farther.
            keep = "start" if s[1] >= e[1] else "end"
            steps, _, _ = drawn[keep]
            steps[-1][2] = float(height)
            drawn = {keep: (steps, float(height), True)}
    bored = []
    for end, (steps, depth, through) in drawn.items():
        bored.append({"end": end, "rInnerMM": round(steps[0][0], 2), "depthMM": round(depth, 1), "through": through,
                      "steps": [[round(r, 2), round(d_a, 1), round(d_b, 1)] for r, d_a, d_b in steps]})
    prefix, suffix = [[0.0, 0.0]], [[0.0, height]]
    if "start" in drawn:
        steps, depth, through = drawn["start"]
        prefix = [] if through else [[0.0, depth]]
        for r, d_a, d_b in reversed(steps):
            prefix += [[r, d_b], [r, d_a]]
        if through:
            suffix = []                 # the loop closes along the top face, from the profile's top to the bore wall
    if "end" in drawn:
        steps, depth, through = drawn["end"]
        suffix = []
        for r, d_a, d_b in steps:
            suffix += [[r, height - d_a], [r, height - d_b]]
        if through:
            prefix = []                 # … and along the foot
        else:
            suffix.append([0.0, height - depth])
    return prefix, suffix, bored


def bore_words(bored):
    """", bored r 14 mm 60 deep at its start" — for notes and labels."""
    return "".join(", bored r %.0f mm %s at its %s" % (b["rInnerMM"], "right through" if b["through"] else "%.0f deep" % b["depthMM"], b["end"])
                   for b in bored)


def body_section(analysis):
    """The body's half-section to revolve — one answer for the build, the
    film (`demo_video.py take`) and the reel, so a film shows the model the
    inspection graded. Sketch coordinates: u = radius, v = height, the axis
    at u = 0. Returns {"entities", "seed" (a point inside the loop), "note"
    (for the transcript), "hollow" ({wallMM, measuredWallMM, openEnd} for a
    container, else None), "outline" (the straightened profile closed along
    the axis — the Pappus check's polygon), "inner" (for a container: the
    cavity's {entities, seed, note} to revolve and subtract after the
    outer revolve, else None), "bores" (the bores drawn into the loop, as
    `bore_chains` reports them)}.

    A bore at an end (`analysis["bores"]`) is part of the ONE loop: the
    outline runs in along the end face to the bore's radius, along the
    bore to its floor and back to the axis — the solid is the wall round
    the hole, no second op. The film and the reel revolve this same
    section, so they inherit it."""
    profile, height, body_r = analysis["profile"], analysis["heightMM"], analysis["bodyRadiusMM"]
    prefix, suffix, bored = bore_chains(analysis, profile, height)
    cleaned = dedupe(prefix + [[max(r, 0.0), h] for r, h in profile] + suffix)
    segments = analysis.get("profileSegments")
    open_top = analysis.get("openTop")
    seed = section_seed(cleaned) if bored else [body_r * 0.5, height * 0.5]
    hollow = None
    inner = None
    loop = analysis.get("sectionLoop")
    if loop and len(loop) >= 4:
        # A dished part: the traced half-section is the sketch loop itself
        # (a dish, a bore, two tyres on one hub all come with it).
        pts = [[max(float(r), 0.0), float(hh)] for r, hh in loop]
        entities = lines_for(dedupe(pts))
        seed = section_seed(pts)
        note = "{} lines: the traced half-section (a dished part), axis at u = 0".format(len(entities))
        return {"entities": entities, "seed": seed, "note": note, "hollow": None, "outline": pts, "inner": None, "bores": []}
    if open_top and segments:
        # A container: the solid revolve of the outer profile, then the
        # cavity — the outer profile eroded a wall in, from the floor to
        # past the open rim — revolved and SUBTRACTED. (One hollow loop
        # offset round a ribbed profile folded over itself; the kernel's
        # shell refused the barrel at every thickness.)
        end = open_top.get("end", "top")
        min_r = min(min(s["a"][0], s["b"][0]) for s in segments)
        wall = float(max(1.5, min(open_top["wallMM"], 0.45 * min_r)))
        cavity, cavity_seed = cavity_section(segments, height, wall, end, floor_from_rim=open_top.get("depthMM"))
        if cavity:
            inner = {"entities": sketch_entities(cavity), "seed": cavity_seed,
                     "note": "%d entities: the cavity, a %.1f mm wall in, open at the %s — revolved and subtracted" % (
                         len(cavity), wall, end)}
            hollow = {"wallMM": wall, "measuredWallMM": open_top["wallMM"], "openEnd": end}
    if segments and any(s["kind"] == "arc" for s in segments):
        # Lines and arcs from the analysis (a dome is an arc), closed
        # along the axis: (0,0) → the profile's foot … its top → (0, height).
        foot = segments[0]["a"]
        drawn = keep_off_axis(sketch_entities(segments))
        # The profile's top, read off the last entity as drawn (an arc's end
        # moves when it is kept off the axis); it closes to the axis at its
        # own height, then down the axis.
        last = drawn[-1]
        if last["kind"] == "arc":
            top = [last["center"][0] + last["radius"] * math.cos(last["endAngle"]),
                   last["center"][1] + last["radius"] * math.sin(last["endAngle"])]
        else:
            top = last["b"]
        if suffix and not any(b["end"] == "end" for b in bored):
            # The plain axis close, moved to the drawn top's own height (an
            # arc's end moves when it is kept off the axis). A through bore
            # from the foot has emptied the suffix — the loop closes along
            # the top face to the bore's wall — and keeps it empty.
            suffix = [[0.0, float(top[1])]]
        foot_pt = [max(float(foot[0]), 0.0), float(foot[1])]
        top_pt = [max(float(top[0]), 0.0), float(top[1])]
        # From the closing point (the axis, or a through bore's wall) to
        # the foot, the drawn profile, then from its top through the bore
        # (or straight to the axis) and back to the closing point.
        close_to = prefix[0] if prefix else foot_pt
        entities = open_lines(prefix + [foot_pt]) + drawn + open_lines([top_pt] + suffix + [close_to])
        entities = [e for e in entities if e["kind"] != "line" or
                    math.hypot(e["a"][0] - e["b"][0], e["a"][1] - e["b"][1]) > 0.02]
        arcs = sum(e["kind"] == "arc" for e in entities)
        note = "{} entities ({} arcs): half the cross-section, axis at u = 0{}".format(len(entities), arcs, bore_words(bored))
    else:
        entities = lines_for(cleaned)
        note = "{} lines: half the cross-section, axis at u = 0{}".format(len(entities), bore_words(bored))
    return {"entities": entities, "seed": seed, "note": note, "hollow": hollow, "outline": cleaned, "inner": inner,
            "bores": bored}


def window_sections(analysis, shift=None):
    """Each opening of each window of the analysis (`find_windows`: a
    hand-wheel's openings between its spokes) as a sketch plane through
    the axis turned to the opening's first azimuth, the annulus rectangle
    to revolve on it by the opening's span and SUBTRACT:
    [{plane, entities, seed, angleDegrees, note}]. `shift` is added to the
    origin (the film stands the scan on the floor)."""
    out = []
    axis = unit(analysis["axisDirection"])
    u, v = unit(analysis["azimuthZero"]), unit(analysis["azimuthNinety"])
    origin = np.asarray(analysis["axisOrigin"], dtype=float) + (np.zeros(3) if shift is None else np.asarray(shift, dtype=float))
    for w in analysis.get("windows", []) or []:
        r0, r1, h0, h1 = float(w["rInnerMM"]), float(w["rOuterMM"]), float(w["h0"]), float(w["h1"])
        if r1 - r0 < 1.0 or h1 - h0 < 1.0:
            continue
        pts = [[r0, h0 - 0.5], [r1, h0 - 0.5], [r1, h1 + 0.5], [r0, h1 + 0.5]]
        for n, (start_deg, span_deg) in enumerate(w["openings"], 1):
            x = unit(math.cos(math.radians(start_deg)) * u + math.sin(math.radians(start_deg)) * v)
            out.append({"plane": {"origin": [float(c) for c in origin], "xAxis": [float(c) for c in x],
                                  "yAxis": [float(c) for c in axis], "name": "Opening %d" % n},
                        "entities": lines_for(pts), "seed": [(r0 + r1) / 2, (h0 + h1) / 2],
                        "angleDegrees": round(float(span_deg), 2),
                        "note": "an opening between two spokes: the annulus r %.0f–%.0f over h %.0f–%.0f from %.0f° for %.0f°, revolved and subtracted" % (
                            r0, r1, h0, h1, start_deg, span_deg)})
    return out


def cut_window(mcp, win, cad_id, label, note=True):
    """Sketch and revolve one opening by its span about the axis,
    subtracted from `cad_id`. Returns the app's reply."""
    sk = mcp.os3d("sketch.create", dict(win["plane"], name=label + " " + win["plane"]["name"]),
                  note="the opening's sketch, through the axis at its first azimuth" if note else None)["sketchID"]
    mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": win["entities"]}, note=win["note"] if note else None)
    return mcp.os3d("feature.revolve", {"sketchID": sk, "seedPoint": win["seed"], "axisPoint": [0, 0],
                                        "axisDirection": [0, 1], "angleDegrees": win["angleDegrees"],
                                        "boolean": "subtract", "booleanTargets": [cad_id]},
                    note="revolved by the opening's span and subtracted" if note else None)


def secondary_sections(analysis, shift=None):
    """Each body of revolution the analysis traced on its own axis
    (`analysis["bodies"]` — a valve's pipe, its branches, its side port;
    a hydrant's nozzles) as the sketch plane through its axis and the
    half-section to revolve on it, in the build's world frame (`shift`
    added to every origin: the film stands the scan on the floor).
    Returns [{plane, entities, seed, note, label, index, parent,
    junction, radiusMM, lengthMM}], in the analysis's order — a body
    that runs into another is listed after it, so each union meets
    material already there."""
    out = []
    delta = np.zeros(3) if shift is None else np.asarray(shift, dtype=float)
    for body in analysis.get("bodies", []):
        origin = np.asarray(body["axisOrigin"], dtype=float) + delta
        axis = unit(body["axisDirection"])
        u = unit(body["azimuthZero"])
        section = body_section(body)
        plane = {"origin": [float(x) for x in origin], "xAxis": [float(x) for x in u],
                 "yAxis": [float(x) for x in axis], "name": "Body %d profile" % body["index"]}
        out.append({"plane": plane, "entities": section["entities"], "seed": section["seed"],
                    "note": section["note"], "index": body["index"], "parent": body.get("parent"),
                    "junction": body.get("junction"), "radiusMM": body["bodyRadiusMM"], "lengthMM": body["heightMM"],
                    "bores": section["bores"],
                    "label": "body %d: radius ~%.0f mm over %.0f mm on its own axis%s%s%s" % (
                        body["index"], body["bodyRadiusMM"], body["heightMM"],
                        "" if body.get("parent") is None else ", into body %s" % body["parent"],
                        bore_words(section["bores"]), passage_words(body))})
    return out


def revolve_secondary(mcp, sec, cad_id, note=True):
    """Sketch and revolve one secondary body (`secondary_sections`) 360°
    about its own axis, unioned into `cad_id`. Returns the app's reply."""
    sk = mcp.os3d("sketch.create", sec["plane"],
                  note="a sketch through the axis of %s" % sec["label"] if note else None)["sketchID"]
    mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": sec["entities"]},
             note=sec["note"] if note else None)
    return mcp.os3d("feature.revolve", {"sketchID": sk, "seedPoint": sec["seed"], "axisPoint": [0, 0],
                                        "axisDirection": [0, 1], "angleDegrees": 360,
                                        "boolean": "union", "booleanTargets": [cad_id]},
                    note="revolved about its own axis and unioned into the body" if note else None)


def passages_of(body):
    """The passages recorded behind a secondary body's bores
    (`bores[j]["passage"]`, from the analysis): [(bore, passage), …] for
    the bores that have one. A main-body record (no "index") has none."""
    if "index" not in body:
        return []
    return [(bore, bore["passage"]) for bore in body.get("bores") or []
            if bore.get("passage") and bore.get("end") in ("start", "end")]


def passage_run_on(bore, passage):
    """How far the passage runs past the bore the loop cuts, mm."""
    return max(float(passage["depthMM"]) - float(bore["depthMM"]), 0.0)


def passage_words(body):
    """", its bore running on 14 mm into body 0" — for the body's label."""
    return "".join(", its bore running on %.0f mm into body %s" % (passage_run_on(bore, passage), body.get("parent"))
                   for bore, passage in passages_of(body))


def passage_sections(analysis, shift=None):
    """Each passage the analysis read behind a secondary body's bore
    (`bodies[k]["bores"][j]["passage"]`: the bore's last radius carried on
    along the branch's axis past the parent's skin, as deep as the scan
    shows interior surface) as a sketch on the body's own axis plane — the
    plane `secondary_sections` builds: origin = axisOrigin + shift, x =
    azimuthZero, y = axis — with the rectangle to revolve 360° and SUBTRACT
    from the whole model: u from 0 to the passage's radius, v from a
    millimetre OUTSIDE the free end (so the cut opens the mouth cleanly) to
    the passage's far end, `depthMM` in from the free end plane. A bore at
    the body's "end" is cut from heightMM + 1 down to heightMM − depthMM;
    one at its "start" from −1 up to depthMM. Returns [{plane, entities,
    seed, note, label, index, parent, end, rMM, depthMM, runOnMM, floor,
    capped}] in the bodies' order. The build cuts these AFTER every union
    (the branches, the nuts): a union into the parent fills a bore wherever
    the parent is solid, and a nut's prism would refill one too."""
    out = []
    delta = np.zeros(3) if shift is None else np.asarray(shift, dtype=float)
    for body in analysis.get("bodies", []):
        for bore, passage in passages_of(body):
            r, depth, height = float(passage["rMM"]), float(passage["depthMM"]), float(body["heightMM"])
            if r < 1.0 or depth < 1.0:
                continue
            end = bore["end"]
            v0, v1 = (height + 1.0, height - depth) if end == "end" else (-1.0, depth)
            pts = [[0.0, v0], [r, v0], [r, v1], [0.0, v1]]
            origin = np.asarray(body["axisOrigin"], dtype=float) + delta
            plane = {"origin": [float(x) for x in origin], "xAxis": [float(x) for x in unit(body["azimuthZero"])],
                     "yAxis": [float(x) for x in unit(body["axisDirection"])], "name": "Body %d passage" % body["index"]}
            run_on = passage_run_on(bore, passage)
            parent = body.get("parent")
            why = (" to the floor the scan shows" if passage.get("floor")
                   else " and stopped short of body %s's far skin" % parent if passage.get("capped")
                   else " as deep as the scan shows surface inside it (%.0f mm)" % float(passage.get("seenMM", depth)))
            out.append({"plane": plane, "entities": lines_for(pts), "seed": [r / 2.0, (v0 + v1) / 2.0],
                        "index": body["index"], "parent": parent, "end": end, "rMM": round(r, 2), "depthMM": round(depth, 2),
                        "runOnMM": round(run_on, 2), "floor": bool(passage.get("floor")), "capped": bool(passage.get("capped")),
                        "label": "body %d's bore runs on %.0f mm into body %s" % (body["index"], run_on, parent),
                        "note": "the passage: the bore's last radius r %.1f mm carried on along body %d's axis from its %s, "
                                "%.0f mm deep in all (%.0f past the bore the loop cut)%s, revolved 360° and subtracted" % (
                                    r, body["index"], end, depth, run_on, why)})
    return out


def cut_passage(mcp, sec, cad_id, note=True):
    """Sketch and revolve one passage (`passage_sections`) 360° about the
    body's own axis, subtracted from `cad_id`. Returns the app's reply."""
    sk = mcp.os3d("sketch.create", sec["plane"],
                  note="the passage's sketch, on body %d's axis plane" % sec["index"] if note else None)["sketchID"]
    mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": sec["entities"]}, note=sec["note"] if note else None)
    return mcp.os3d("feature.revolve", {"sketchID": sk, "seedPoint": sec["seed"], "axisPoint": [0, 0],
                                        "axisDirection": [0, 1], "angleDegrees": 360,
                                        "boolean": "subtract", "booleanTargets": [cad_id]},
                    note="revolved about the branch's axis and subtracted: the bore runs on into the parent" if note else None)


def passage_caption(sec):
    """The film's caption for a passage: "The bore runs on · body 3's
    passage, 14 mm into body 0, revolved and subtracted"."""
    return "The bore runs on · body %d's passage, %.0f mm into body %s, revolved and subtracted" % (
        sec["index"], sec["runOnMM"], sec["parent"])


def nut_polygon(nut):
    """The n-gon of a nut record (`analyze_scan.find_nuts`) in its sketch
    plane: vertices at the corner radius (half the across-flats over
    cos(π/n)), the first flat's outward normal along +x, so the corners
    sit at ±π/n from it. Returns [[x, y], …] counter-clockwise."""
    n = int(nut["sides"])
    R = nut["acrossFlatsMM"] / 2.0 / math.cos(math.pi / n)
    return [[round(R * math.cos(math.pi / n + 2 * math.pi * k / n), 4), round(R * math.sin(math.pi / n + 2 * math.pi * k / n), 4)]
            for k in range(n)]


def nut_sections(analysis, shift=None):
    """Every polygonal band the analysis found on an axis (`nuts` on the
    main record and on each body under `bodies`: a hex nut, a square
    collar) as a sketch on the plane normal to that axis at the nut's
    foot — origin on the axis at h0, x along the first flat's outward
    normal (azimuthZero turned by phaseDeg), y = axis × x so the extrude
    (along x × y) runs up the axis — with the n-gon as lines, to extrude
    by h1 − h0 and union: [{plane, entities, seed, distance, note, label,
    sides, acrossFlatsMM, body}]. The revolve under it already runs at
    the inscribed radius over that span (the analysis clamps its bands),
    so the prism carries the corners and nothing round pokes out of the
    flats. `shift` is added to every origin (the film stands the scan on
    the floor). Main-body nuts first, then each body's in the analysis's
    order."""
    out = []
    delta = np.zeros(3) if shift is None else np.asarray(shift, dtype=float)
    hosts = [(None, analysis)] + [(body["index"], body) for body in analysis.get("bodies", [])]
    for body_index, host in hosts:
        axis = unit(host["axisDirection"])
        u, v = unit(host["azimuthZero"]), unit(host["azimuthNinety"])
        base = np.asarray(host["axisOrigin"], dtype=float) + delta
        for k, nut in enumerate(host.get("nuts") or [], 1):
            distance = float(nut["h1"]) - float(nut["h0"])
            if distance < 1.0 or nut["acrossFlatsMM"] < 2.0:
                continue
            phi = math.radians(float(nut.get("phaseDeg", 0.0)))
            x = unit(math.cos(phi) * u + math.sin(phi) * v)
            y = unit(np.cross(axis, x))
            origin = base + axis * float(nut["h0"])
            words = nut_words(nut)
            where = "the body's axis" if body_index is None else "body %d's axis" % body_index
            out.append({"plane": {"origin": [float(c) for c in origin], "xAxis": [float(c) for c in x],
                                  "yAxis": [float(c) for c in y],
                                  "name": "%s %d" % ("Nut" if body_index is None else "Body %d nut" % body_index, k)},
                        "entities": lines_for(nut_polygon(nut)), "seed": [0.0, 0.0], "distance": round(distance, 3),
                        "sides": int(nut["sides"]), "acrossFlatsMM": float(nut["acrossFlatsMM"]), "body": body_index,
                        "h0": float(nut["h0"]), "h1": float(nut["h1"]),
                        "label": "%s on %s" % (words, where),
                        "note": "a %d-gon %.0f mm across the flats on a plane normal to %s at h %.0f, extruded %.0f mm up the axis and unioned in" % (
                            nut["sides"], nut["acrossFlatsMM"], where, nut["h0"], distance)})
    return out


def extrude_nut(mcp, nut, cad_id, label, note=True):
    """Sketch and extrude one nut (`nut_sections`) up its axis, unioned
    into `cad_id`. Returns the app's reply."""
    sk = mcp.os3d("sketch.create", dict(nut["plane"], name=label + " " + nut["plane"]["name"]),
                  note="a sketch normal to the axis at the nut's foot" if note else None)["sketchID"]
    mcp.os3d("sketch.addEntities", {"sketchID": sk, "entities": nut["entities"]}, note=nut["note"] if note else None)
    return mcp.os3d("feature.extrude", {"sketchID": sk, "seedPoint": nut["seed"], "distance": nut["distance"],
                                        "boolean": "union", "booleanTargets": [cad_id]},
                    note="extruded up the axis and unioned into the body" if note else None)


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
    args.color = model_color({"color": color_option(args.color)}, analysis)
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
        if section["inner"]:
            sk_in = mcp.os3d("sketch.create", dict(plane, name=args.label + " cavity"),
                             note="the cavity's sketch, on the same axis plane")["sketchID"]
            mcp.os3d("sketch.addEntities", {"sketchID": sk_in, "entities": section["inner"]["entities"]},
                     note=section["inner"]["note"])
            reply_in = mcp.os3d("feature.revolve", {"sketchID": sk_in, "seedPoint": section["inner"]["seed"],
                                                    "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360,
                                                    "boolean": "subtract", "booleanTargets": [cad_id]},
                                note="the cavity revolved 360° and subtracted: the container is hollow")
            if reply_in.get("failed"):
                print("   cavity cut did not build:", reply_in.get("message"))
            else:
                cad = next(b for b in reply_in["bodies"] if b["id"] == cad_id)
                print("   cavity subtracted: volume %.0f → %.0f mm³" % (reply["bodies"][0]["volumeMM3"] if reply.get("bodies") else 0, cad["volumeMM3"]))
        for win in window_sections(analysis):
            reply_w = cut_window(mcp, win, cad_id, args.label)
            if reply_w.get("failed"):
                print("   window cut did not build:", reply_w.get("message"))
                mcp.os3d("command.run", {"id": "edit.undo"}, note="the refused cut undone")
            else:
                cad = next(b for b in reply_w["bodies"] if b["id"] == cad_id)
                print("   %s: volume → %.0f mm³" % (win["note"], cad["volumeMM3"]))
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

        secondaries = secondary_sections(analysis)
        for n, sec in enumerate(secondaries, 1):
            s.step("Body %d of %d on its own axis: radius ~%.0f mm over %.0f mm%s" % (
                n, len(secondaries), sec["radiusMM"], sec["lengthMM"],
                "" if sec["parent"] is None else ", into body %s" % sec["parent"]))
            reply = revolve_secondary(mcp, sec, cad_id)
            if reply.get("failed"):
                print("   not built:", reply.get("message"))
                mcp.os3d("command.run", {"id": "edit.undo"}, note="the refused revolve undone")
                s.summary.setdefault("secondaryBodies", []).append({"index": sec["index"], "ok": False,
                                                                     "message": reply.get("message")})
                continue
            vol = next(b for b in reply["bodies"] if b["id"] == cad_id)["volumeMM3"]
            print("   %d entities; volume → %.0f mm³" % (len(sec["entities"]), vol))
            s.summary.setdefault("secondaryBodies", []).append({"index": sec["index"], "ok": True, "volumeMM3": vol,
                                                                 "radiusMM": sec["radiusMM"], "lengthMM": sec["lengthMM"],
                                                                 "parent": sec["parent"], "junction": sec["junction"]})
            mcp.os3d("item.setHidden", {"allSketches": True})
            s.shot("02-body-%d-iso" % n, "isometric")
            s.stage("stage-1-body-%d" % n, cad_id)

        # The polygonal bands on the axes — a hex nut, a square collar —
        # each a prism extruded up its axis over the revolve, which runs
        # at the inscribed radius there.
        nuts = nut_sections(analysis)
        for n, nut in enumerate(nuts, 1):
            s.step("Nut %d of %d: %s" % (n, len(nuts), nut["label"]))
            reply = extrude_nut(mcp, nut, cad_id, args.label)
            if reply.get("failed"):
                print("   not built:", reply.get("message"))
                mcp.os3d("command.run", {"id": "edit.undo"}, note="the refused extrude undone")
                s.summary.setdefault("nuts", []).append({"label": nut["label"], "ok": False, "message": reply.get("message")})
                continue
            vol = next(b for b in reply["bodies"] if b["id"] == cad_id)["volumeMM3"]
            print("   %d-gon, %.0f mm across the flats, %.0f mm tall; volume → %.0f mm³" % (
                nut["sides"], nut["acrossFlatsMM"], nut["distance"], vol))
            s.summary.setdefault("nuts", []).append({"label": nut["label"], "ok": True, "volumeMM3": vol,
                                                     "sides": nut["sides"], "acrossFlatsMM": nut["acrossFlatsMM"],
                                                     "heightMM": nut["distance"], "body": nut["body"]})
            mcp.os3d("item.setHidden", {"allSketches": True})
            s.shot("02-nut-%d-iso" % n, "isometric")
            s.stage("stage-1-nut-%d" % n, cad_id)

        # The passages — a branch's bore the scan shows running on into its
        # parent — cut LAST among the unions' company: the branch's union
        # filled its bore where the parent is solid, and a nut's prism (or
        # any later union) would fill it again. The bosses come after; they
        # stand on the main body's skin, away from the branches' axes.
        passages = passage_sections(analysis)
        for n, pas in enumerate(passages, 1):
            s.step("Passage %d of %d: %s" % (n, len(passages), pas["label"]))
            reply = cut_passage(mcp, pas, cad_id)
            if reply.get("failed"):
                print("   not cut:", reply.get("message"))
                mcp.os3d("command.run", {"id": "edit.undo"}, note="the refused cut undone")
                s.summary.setdefault("passages", []).append({"label": pas["label"], "ok": False, "message": reply.get("message"),
                                                             "body": pas["index"], "parent": pas["parent"]})
                continue
            vol = next(b for b in reply["bodies"] if b["id"] == cad_id)["volumeMM3"]
            print("   r %.1f mm, %.0f mm deep from the %s (%.0f past the bore); volume → %.0f mm³" % (
                pas["rMM"], pas["depthMM"], pas["end"], pas["runOnMM"], vol))
            s.summary.setdefault("passages", []).append({"label": pas["label"], "ok": True, "volumeMM3": vol,
                                                         "body": pas["index"], "parent": pas["parent"], "end": pas["end"],
                                                         "rMM": pas["rMM"], "depthMM": pas["depthMM"], "runOnMM": pas["runOnMM"],
                                                         "floor": pas["floor"], "capped": pas["capped"]})
            mcp.os3d("item.setHidden", {"allSketches": True})
            s.shot("02-passage-%d-iso" % n, "isometric")
            s.stage("stage-1-passage-%d" % n, cad_id)

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
    ap.add_argument("--color", nargs="+", default=["scan"], metavar="R G B | scan",
                    help="the model's colour: three numbers in 0…1, or 'scan' (default) for the analysis's "
                         "scanColor — the scan's own dominant colour — falling back to hydrant red")
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
