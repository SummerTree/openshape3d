#!/usr/bin/env python3
"""An offline preview of the CAD model the scan-to-CAD build would make —
the same half-section, cavity, bosses and fitted features that
`build_hydrant.py` and `build_features.py` draw in the app, built here as
trimesh meshes (manifold booleans) and measured the way the app's
`accuracy` op measures, so a profile or a feature can be judged in seconds
without the simulator.

    preview_model.py <part dir> [--out dir] [--tolerance T] [--no-features] [--sheet]
                     [--analysis profile.json] [--features features.json] [--sections 96]

Reads `<part>/analysis/profile.json` (the body, its cavity when it is an
open container, the other bodies of revolution traced on their own axes
under `bodies` — a valve's pipe and branches, a hydrant's nozzles — and
its bosses) and `<part>/features/features.json` (the residual features),
keeping only the features `<part>/run/summary.json` says the app built,
when that file exists. Measures the model against `<part>/run/scan.stl`
(the app's export of the scan it compared against) or, failing that,
`analysis/scan_cropped.glb`; `--scan` names another (an STL, or a glTF in
metres), for an analysis made from a different crop. Writes into `--out`
(default `<part>/preview/`):

    preview.stl    the model
    preview.json   the numbers: app-style silhouette overlap per view and
                   overall, vertex-sampled deviations both ways, what fell
                   back to a plain concatenation, for each secondary body
                   how far its surface sits from the scan (a body revolved
                   in the wrong frame sits in air), and — when the app's
                   `run/summary.json` and `run/<part>-cad.stl` exist — the
                   app's numbers beside them and the mesh-to-mesh distance
    qa/            with `--sheet`: `inspect_fit.py`'s review sheet

The app's measure, mirrored (`Kernel/AccuracyKit.swift`): each view's
silhouette is every triangle rasterised on a grid 512 pixels across the
longer extent of both meshes together (front looks along −Z, right along
−X, top down −Y: the viewport's standard views), IoU = overlap / union, the
headline is the mean over the three; the deviations sample each mesh's
VERTICES (thinned to 20 000) and take the distance to the other surface.
So the overlap numbers agree with the app's to the pixel-fill rule; the
deviation numbers depend on where the vertices are, and the app tessellates
its B-rep differently from the facet counts here — compare `preview.stl`
with the app's export directly (`meshToApp` in preview.json) when a
sub-millimetre answer matters.

What a boolean refuses falls back to concatenating the meshes: the
silhouettes are still right, the model-to-scan deviation then counts the
buried surfaces. `preview.json` says which ones.
"""
import argparse
import json
import math
import os
import subprocess
import sys

import numpy as np
import trimesh

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build_hydrant import body_section, boss_section, secondary_sections, world, unit  # noqa: E402
from build_features import sweep_sketch  # noqa: E402
from build_recipe import revolve_region, radial_frame, seed_inside  # noqa: E402
from fit_primitives import sketch_entities  # noqa: E402

VIEWS = {
    # right, up (toward the viewer = right × up), as DrawingViewDirection.basis
    "front": (np.array([1.0, 0, 0]), np.array([0, 1.0, 0])),
    "top": (np.array([1.0, 0, 0]), np.array([0, 0, -1.0])),
    "right": (np.array([0, 0, -1.0]), np.array([0, 1.0, 0])),
}
APP_RESOLUTION = 512
APP_SAMPLES = 20_000


# ---- sketch entities → loops ------------------------------------------------

def entity_polyline(e, arc_deg=2.0):
    """The points of one sketch entity, in order (an arc counter-clockwise
    from its start angle to its end angle, as the app reads it)."""
    if e["kind"] == "line":
        return np.array([e["a"], e["b"]], dtype=float)
    c, r = np.asarray(e["center"], dtype=float), float(e["radius"])
    if e["kind"] == "circle":
        n = max(24, int(math.ceil(360.0 / arc_deg)))
        t = np.linspace(0, 2 * math.pi, n, endpoint=False)
        return np.column_stack([c[0] + r * np.cos(t), c[1] + r * np.sin(t)])
    a0, a1 = float(e["startAngle"]), float(e["endAngle"])
    while a1 <= a0:
        a1 += 2 * math.pi
    n = max(3, int(math.ceil(math.degrees(a1 - a0) / arc_deg)) + 1)
    t = np.linspace(a0, a1, n)
    return np.column_stack([c[0] + r * np.cos(t), c[1] + r * np.sin(t)])


def loops_of_entities(entities, tol=0.6, arc_deg=2.0):
    """Closed loops (each an (n, 2) array, the first point not repeated)
    chained from the entities by matching ends, each entity used once; a
    circle is a loop of its own. `tol` is the gap the chain still bridges
    — `sketch_entities` moves line ends onto arc ends to within 0.5 mm."""
    pieces = [entity_polyline(e, arc_deg) for e in entities]
    loops = []
    used = [False] * len(pieces)
    for i, e in enumerate(entities):
        if e["kind"] == "circle":
            loops.append(pieces[i])
            used[i] = True
    while not all(used):
        start = used.index(False)
        used[start] = True
        chain = [pieces[start]]
        end = pieces[start][-1]
        while True:
            best = None
            for j, p in enumerate(pieces):
                if used[j]:
                    continue
                d0 = float(np.linalg.norm(p[0] - end))
                d1 = float(np.linalg.norm(p[-1] - end))
                if d0 <= tol and (best is None or d0 < best[0]):
                    best = (d0, j, False)
                if d1 <= tol and (best is None or d1 < best[0]):
                    best = (d1, j, True)
            if best is None:
                break
            _, j, reverse = best
            used[j] = True
            p = pieces[j][::-1] if reverse else pieces[j]
            chain.append(p)
            end = p[-1]
            if np.linalg.norm(end - chain[0][0]) <= tol:
                break
        pts = np.vstack([c[:-1] for c in chain] + [chain[-1][-1:]])
        if np.linalg.norm(pts[0] - pts[-1]) <= tol:
            pts = pts[:-1]
        keep = np.ones(len(pts), dtype=bool)
        keep[1:] = np.linalg.norm(np.diff(pts, axis=0), axis=1) > 1e-6
        pts = pts[keep]
        if len(pts) >= 3:
            loops.append(pts)
    return loops


def entity_ends(e):
    """An entity's two end points in the sketch plane."""
    if e["kind"] == "arc":
        c, r = e["center"], e["radius"]
        return (np.array([c[0] + r * math.cos(e["startAngle"]), c[1] + r * math.sin(e["startAngle"])]),
                np.array([c[0] + r * math.cos(e["endAngle"]), c[1] + r * math.sin(e["endAngle"])]))
    if e["kind"] == "circle":
        return None, None
    return np.asarray(e["a"], dtype=float), np.asarray(e["b"], dtype=float)


def chain_gap(entities):
    """The widest gap between consecutive entities drawn in order (each
    end against the next start, either way round), and where it is: a
    sketch the app's revolve would call unresolved has one over its
    snapping tolerance."""
    worst, where = 0.0, None
    ends = [entity_ends(e) for e in entities]
    for i in range(len(ends)):
        a0, b0 = ends[i]
        a1, b1 = ends[(i + 1) % len(ends)]
        if a0 is None or a1 is None:
            continue
        gap = min(np.linalg.norm(b0 - a1), np.linalg.norm(b0 - b1), np.linalg.norm(a0 - a1), np.linalg.norm(a0 - b1))
        if gap > worst:
            worst, where = float(gap), (i, [round(float(v), 2) for v in b0])
    return worst, where


def unresolved(entities, label):
    """A note when the entities do not chain into one closed loop (the
    app refuses such a revolve), else None."""
    gap, where = chain_gap(entities)
    loops = loops_of_entities(entities)
    if gap > 0.5 or len(loops) != 1:
        return "%s: its %d entities do not close into one loop (%d loops; widest gap %.2f mm at entity %s near %s) — the app would refuse this revolve" % (
            label, len(entities), len(loops), gap, where[0] if where else "?", where[1] if where else "?")
    return None


def signed_area(loop):
    x, y = loop[:, 0], loop[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def point_in_loop(pt, loop):
    x, y = float(pt[0]), float(pt[1])
    inside = False
    n = len(loop)
    for i in range(n):
        ax, ay = loop[i]
        bx, by = loop[(i + 1) % n]
        if (ay > y) != (by > y):
            xi = ax + (y - ay) * (bx - ax) / (by - ay)
            if xi > x:
                inside = not inside
    return inside


def pick_loop(loops, seed=None):
    """The loop the seed point lies in (the region the app's op would pick),
    else the largest."""
    if seed is not None:
        for loop in loops:
            if point_in_loop(seed, loop):
                return loop
    return max(loops, key=lambda l: abs(signed_area(l)))


def ccw(loop):
    return loop if signed_area(loop) > 0 else loop[::-1]


def triangulate(loop):
    """Ear clipping of a simple counter-clockwise polygon: (m, 3) indices."""
    n = len(loop)
    idx = list(range(n))
    tris = []

    def convex(i, j, k):
        a, b, c = loop[i], loop[j], loop[k]
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 1e-12

    def inside(p, i, j, k):
        a, b, c = loop[i], loop[j], loop[k]
        s = [(b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]),
             (c[0] - b[0]) * (p[1] - b[1]) - (c[1] - b[1]) * (p[0] - b[0]),
             (a[0] - c[0]) * (p[1] - c[1]) - (a[1] - c[1]) * (p[0] - c[0])]
        return all(v >= -1e-12 for v in s)

    guard = 0
    while len(idx) > 3 and guard < 4 * n * n:
        guard += 1
        clipped = False
        for m in range(len(idx)):
            i, j, k = idx[m - 1], idx[m], idx[(m + 1) % len(idx)]
            if not convex(i, j, k):
                continue
            if any(inside(loop[o], i, j, k) for o in idx if o not in (i, j, k)):
                continue
            tris.append((i, j, k))
            del idx[m]
            clipped = True
            break
        if not clipped:
            break
    if len(idx) == 3:
        tris.append(tuple(idx))
    elif len(idx) > 3:                      # not simple after all: a fan is the best left
        tris += [(idx[0], idx[m], idx[m + 1]) for m in range(1, len(idx) - 1)]
    return np.array(tris, dtype=int)


# ---- solids ------------------------------------------------------------------

def finish(mesh):
    mesh.remove_unreferenced_vertices()
    mesh.merge_vertices()
    mesh.update_faces(mesh.nondegenerate_faces())
    mesh.remove_unreferenced_vertices()
    mesh.fix_normals()
    if mesh.is_watertight and mesh.volume < 0:
        mesh.invert()
    return mesh


def frame_transform(origin, x_axis, y_axis):
    """4×4 taking sketch (x, y, n) to the world: x → x_axis, y → y_axis,
    n → x_axis × y_axis (the plane's normal, the way the app extrudes)."""
    x = unit(x_axis)
    y = unit(np.asarray(y_axis, dtype=float) - (np.asarray(y_axis, dtype=float) @ x) * x)
    n = np.cross(x, y)
    T = np.eye(4)
    T[:3, 0], T[:3, 1], T[:3, 2] = x, y, n
    T[:3, 3] = np.asarray(origin, dtype=float)
    return T


def revolve_loop(loop, origin, x_axis, y_axis, sections=96):
    """The loop (u = radius ≥ 0, v = along the axis) revolved 360° about the
    sketch's y axis, placed in the world."""
    loop = ccw(np.asarray(loop, dtype=float))
    loop = loop.copy()
    loop[:, 0] = np.maximum(loop[:, 0], 0.0)
    closed = np.vstack([loop, loop[:1]])
    mesh = trimesh.creation.revolve(closed, sections=sections)
    # trimesh revolves the 2D y axis onto 3D Z: map Z to the sketch's y.
    x = unit(x_axis)
    d = unit(y_axis)
    e2 = np.cross(d, x)
    T = np.eye(4)
    T[:3, 0], T[:3, 1], T[:3, 2] = x, e2, d
    T[:3, 3] = np.asarray(origin, dtype=float)
    mesh.apply_transform(T)
    return finish(mesh)


def extrude_loop(loop, origin, x_axis, y_axis, distance, symmetric=False):
    """The loop extruded along the plane's normal: 0 → distance, or
    −distance → +distance when symmetric (the app's `symmetric`)."""
    loop = ccw(np.asarray(loop, dtype=float))
    n = len(loop)
    lo, hi = (-distance, distance) if symmetric else (0.0, distance)
    bottom = np.column_stack([loop, np.full(n, lo)])
    top = np.column_stack([loop, np.full(n, hi)])
    verts = np.vstack([bottom, top])
    cap = triangulate(loop)
    faces = [cap[:, ::-1]]                        # bottom faces −n
    faces.append(cap + n)                         # top faces +n
    side = []
    for i in range(n):
        j = (i + 1) % n
        side.append([i, j, n + j])
        side.append([i, n + j, n + i])
    faces.append(np.array(side, dtype=int))
    mesh = trimesh.Trimesh(vertices=verts, faces=np.vstack(faces), process=False)
    mesh.apply_transform(frame_transform(origin, x_axis, y_axis))
    return finish(mesh)


def rotation_between(a, b):
    """The 3×3 rotation taking unit vector a onto unit vector b (identity
    when they agree)."""
    v = np.cross(a, b)
    s = np.linalg.norm(v)
    c = float(a @ b)
    if s < 1e-12:
        if c > 0:
            return np.eye(3)
        # 180°: any axis perpendicular to a
        axis = unit(np.cross(a, [1.0, 0, 0]) if abs(a[0]) < 0.9 else np.cross(a, [0, 1.0, 0]))
        K = np.array([[0, -axis[2], axis[1]], [axis[2], 0, -axis[0]], [-axis[1], axis[0], 0]])
        return np.eye(3) + 2 * K @ K
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K * ((1 - c) / (s * s))


def sweep_section(section, spine, x_axis, y_axis):
    """A closed section (in the plane at spine[0] whose normal is the first
    leg) swept along the polyline spine: the section rides a rotation-
    minimising frame, and at each corner the ring is the previous leg's
    prism cut by the corner's bisector plane (a mitre), so neighbouring
    legs meet without a gap. A sweep whose ring folds back — a vertex of
    the section advancing backwards along a leg, because a bend is
    tighter than the section's reach toward its centre or a leg shorter
    than its mitre — is refused (ValueError): its mesh would still close
    with a plausible volume, so watertightness alone would pass a sweep
    the kernel cannot make (`fit_features.sweep_folds` is the same test)."""
    section = ccw(np.asarray(section, dtype=float))
    P = np.asarray(spine, dtype=float)
    keep = np.ones(len(P), dtype=bool)
    keep[1:] = np.linalg.norm(np.diff(P, axis=0), axis=1) > 1e-6
    P = P[keep]
    m = len(P)
    if m < 2:
        raise ValueError("a sweep needs two spine points")
    T = [unit(P[i + 1] - P[i]) for i in range(m - 1)]
    X = unit(np.asarray(x_axis, dtype=float) - (np.asarray(x_axis, dtype=float) @ T[0]) * T[0])
    Y = np.cross(T[0], X)
    k = len(section)
    rings = []
    rings.append(P[0] + np.outer(section[:, 0], X) + np.outer(section[:, 1], Y))
    for i in range(1, m):
        t_prev = T[i - 1]
        if i < m - 1:
            t_next = T[i]
            n_bis = t_prev + t_next
            if np.linalg.norm(n_bis) < 1e-9 or (t_prev @ unit(n_bis)) < 0.3:
                n_bis = t_prev            # a hairpin: a square cut instead of a mitre
            n_bis = unit(n_bis)
        else:
            n_bis = t_prev
        base = P[i] + np.outer(section[:, 0], X) + np.outer(section[:, 1], Y)
        # the previous leg's lines through the base points, cut by the plane
        t = -((base - P[i]) @ n_bis) / (t_prev @ n_bis)
        rings.append(base + np.outer(t, t_prev))
        if i < m - 1:
            R = rotation_between(t_prev, T[i])
            X, Y = R @ X, R @ Y
    for i in range(m - 1):
        advance = (rings[i + 1] - rings[i]) @ T[i]
        if (advance < -1e-6).any():
            raise ValueError("the sweep folds back on itself on leg %d of %d (a section vertex advances %.1f mm backwards): "
                             "the bend is tighter than the section's reach toward its centre" % (i + 1, m - 1, -float(advance.min())))
    verts = np.vstack(rings)
    faces = []
    cap = triangulate(section)
    faces.append(cap[:, ::-1])                          # start cap faces back along the spine
    faces.append(cap + (m - 1) * k)
    for i in range(m - 1):
        a, b = i * k, (i + 1) * k
        for j in range(k):
            jn = (j + 1) % k
            faces.append(np.array([[a + j, a + jn, b + jn], [a + j, b + jn, b + j]]))
    mesh = trimesh.Trimesh(vertices=verts, faces=np.vstack(faces), process=False)
    return finish(mesh)


# ---- the model, piece by piece -------------------------------------------------

def body_mesh(analysis, sections=96):
    """The body revolve (and the cavity to subtract, or None), placed as
    `build_hydrant.build` places its sketch."""
    origin = np.asarray(analysis["axisOrigin"], dtype=float)
    axis = unit(analysis["axisDirection"])
    u = unit(analysis["azimuthZero"])
    section = body_section(analysis)
    loop = pick_loop(loops_of_entities(section["entities"]), section["seed"])
    body = revolve_loop(loop, origin, u, axis, sections)
    cavity = None
    if section.get("inner"):
        inner = section["inner"]
        loop_in = pick_loop(loops_of_entities(inner["entities"]), inner["seed"])
        cavity = revolve_loop(loop_in, origin, u, axis, sections)
    return body, cavity, section


def boss_mesh(analysis, boss, sections=96):
    origin0 = np.asarray(analysis["axisOrigin"], dtype=float)
    axis = unit(analysis["axisDirection"])
    u = unit(analysis["azimuthZero"])
    v = unit(analysis["azimuthNinety"])
    az = boss["azimuthDeg"]
    d = unit(math.cos(math.radians(az)) * u + math.sin(math.radians(az)) * v)
    t = unit(np.cross(axis, d))
    inner = boss.get("innerStartMM", boss["bodyRadiusMM"] - 12.0)
    entities, seed = boss_section(boss)
    origin = world(origin0, axis, u, v, inner, boss["centerHeightMM"], az)
    loop = pick_loop(loops_of_entities(entities), seed)
    return revolve_loop(loop, origin, t, d, sections)


def secondary_mesh(sec, sections=96):
    """One body of revolution on its own axis (`build_hydrant.secondary_sections`),
    revolved about its sketch's y axis and placed as the app's
    `revolve_secondary` places it."""
    plane = sec["plane"]
    loop = pick_loop(loops_of_entities(sec["entities"]), sec["seed"])
    return revolve_loop(loop, plane["origin"], plane["xAxis"], plane["yAxis"], sections)


def feature_mesh(feature, sections=96):
    kind = feature["kind"]
    if kind == "sweep":
        plane, entities, seed = sweep_sketch(feature)
        loop = pick_loop(loops_of_entities(entities), seed)
        return sweep_section(loop, feature["spine"], plane["xAxis"], plane["yAxis"])
    if kind == "revolve":
        ax = feature["axis"]
        u, d = radial_frame(ax["direction"])
        entities, seed = revolve_region(feature["profile"])
        loop = pick_loop(loops_of_entities(entities), seed)
        return revolve_loop(loop, ax["origin"], u, d, sections)
    if kind == "extrude":
        pl = feature["plane"]
        entities = sketch_entities(feature["segments"])
        seed = feature.get("seed") or seed_inside(feature["segments"])
        loop = pick_loop(loops_of_entities(entities), seed)
        return extrude_loop(loop, pl["origin"], pl["xAxis"], pl["yAxis"], float(feature["distance"]),
                            bool(feature.get("symmetric")))
    raise ValueError("unknown feature kind %r" % kind)


def combine(acc, tool, op, label, notes):
    """`acc` ∪ `tool` (or minus it) with manifold; on refusal the plain
    concatenation, noted."""
    if acc is None:
        return tool
    try:
        if not (acc.is_watertight and tool.is_watertight):
            raise ValueError("not watertight: %s" % ("the model so far" if not acc.is_watertight else label))
        if op == "subtract":
            out = trimesh.boolean.difference([acc, tool], engine="manifold")
        else:
            out = trimesh.boolean.union([acc, tool], engine="manifold")
        if out is None or len(out.faces) == 0 or not out.is_watertight:
            raise ValueError("the result is not a closed solid")
        return out
    except Exception as error:  # noqa: BLE001 — any refusal falls back
        notes.append("%s %s fell back to a concatenation: %s" % (op, label, str(error)[:120]))
        if op == "subtract":
            return acc
        return trimesh.util.concatenate([acc, tool])


def build_preview(analysis, features=(), sections=96, bosses=True, secondaries=True):
    """The whole model as the app would hold it after the build and the
    features: (mesh, notes, parts) — `parts` says what went in, in the
    build's order: the revolve, its cavity, the bodies on their own axes,
    the bosses, the features. A secondary body's row carries its own mesh
    under `_mesh` (for a placement check; not for the JSON)."""
    notes, parts = [], []
    body, cavity, section = body_mesh(analysis, sections)
    bad = unresolved(section["entities"], "the body's profile")
    if bad:
        notes.append(bad)
    model = body
    parts.append({"what": "revolve", "note": section["note"], "volumeMM3": float(body.volume) if body.is_watertight else None})
    if cavity is not None:
        model = combine(model, cavity, "subtract", "the cavity", notes)
        parts.append({"what": "cavity", "note": section["inner"]["note"]})
    if secondaries:
        by_index = {b.get("index"): b for b in analysis.get("bodies", [])}
        for sec in secondary_sections(analysis):
            label = "body %d" % sec["index"]
            bad = unresolved(sec["entities"], label)
            if bad:
                notes.append(bad)
            try:
                tool = secondary_mesh(sec, sections)
            except Exception as error:  # noqa: BLE001
                notes.append("%s could not be drawn: %s" % (label, str(error)[:120]))
                continue
            before = model
            model = combine(model, tool, "union", label, notes)
            body = by_index.get(sec["index"], {})
            parts.append({"what": "body", "index": sec["index"], "radiusMM": sec["radiusMM"], "lengthMM": sec["lengthMM"],
                          "parent": sec["parent"], "junction": sec["junction"],
                          "extendedMM": body.get("extendedMM") or [0.0, 0.0],
                          "volumeMM3": float(tool.volume) if tool.is_watertight else None,
                          "_mesh": tool, "_plane": sec["plane"], "_before": before})
    if bosses:
        for n, boss in enumerate([b for b in analysis.get("bosses", []) if b["reachMM"] - b["bodyRadiusMM"] > 15], 1):
            if not boss.get("profile"):
                notes.append("boss %d has no profile (the circle-extrude fallback is not previewed)" % n)
                continue
            model = combine(model, boss_mesh(analysis, boss, sections), "union", "boss %d" % n, notes)
            parts.append({"what": "boss", "azimuthDeg": boss["azimuthDeg"], "reachMM": boss["reachMM"]})
    for n, feature in enumerate(features, 1):
        label = feature.get("name", "%s %d" % (feature["kind"], n))
        try:
            tool = feature_mesh(feature, sections)
        except Exception as error:  # noqa: BLE001
            notes.append("feature %s could not be drawn: %s" % (label, str(error)[:120]))
            continue
        model = combine(model, tool, "union", label, notes)
        parts.append({"what": "feature", "name": label, "kind": feature["kind"]})
    return model, notes, parts


# ---- the app's measure -----------------------------------------------------------

def rasterize(mesh, right, up, origin, pixel_mm, width, height):
    """Every triangle filled on the grid, as AccuracyKit.rasterize does."""
    from PIL import Image, ImageDraw
    img = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(img)
    pts = np.column_stack([mesh.vertices @ right, mesh.vertices @ up])
    px = (pts - origin) / pixel_mm
    tri = px[mesh.faces]                                   # (m, 3, 2)
    area = ((tri[:, 1, 0] - tri[:, 0, 0]) * (tri[:, 2, 1] - tri[:, 0, 1])
            - (tri[:, 1, 1] - tri[:, 0, 1]) * (tri[:, 2, 0] - tri[:, 0, 0]))
    for t in tri[np.abs(area) > 1e-12]:
        draw.polygon([(float(t[0, 0]), float(t[0, 1])), (float(t[1, 0]), float(t[1, 1])), (float(t[2, 0]), float(t[2, 1]))], fill=1)
    return np.array(img, dtype=bool)


def silhouette_iou(ref, mod, view, resolution=APP_RESOLUTION):
    right, up = VIEWS[view]
    pr = np.column_stack([ref.vertices @ right, ref.vertices @ up])
    pm = np.column_stack([mod.vertices @ right, mod.vertices @ up])
    lo = np.minimum(pr.min(axis=0), pm.min(axis=0))
    hi = np.maximum(pr.max(axis=0), pm.max(axis=0))
    extent = hi - lo
    longest = max(float(extent.max()), 1e-9)
    pixel_mm = longest / max(resolution - 2, 1)
    width = int(math.ceil(extent[0] / pixel_mm)) + 2
    height = int(math.ceil(extent[1] / pixel_mm)) + 2
    origin = lo - pixel_mm
    a = rasterize(ref, right, up, origin, pixel_mm, width, height)
    b = rasterize(mod, right, up, origin, pixel_mm, width, height)
    union = int((a | b).sum())
    return (int((a & b).sum()) / union) if union else 0.0


def app_samples(mesh, limit=APP_SAMPLES):
    """The app's deviation samples: the mesh's used vertices, thinned to the
    budget by a stride (plus triangle centroids when they are too few)."""
    pts = np.asarray(mesh.vertices, dtype=float)
    if len(pts) < limit / 2:
        pts = np.vstack([pts, mesh.triangles_center])
    if len(pts) > limit:
        stride = len(pts) / float(limit)
        pts = pts[(np.arange(limit) * stride).astype(int)]
    return pts


def deviation(src, dst, tolerance, limit=APP_SAMPLES):
    pts = app_samples(src, limit)
    _, dist, _ = trimesh.proximity.closest_point(dst, pts)
    dist = np.asarray(dist, dtype=float)
    return {"samples": int(len(dist)), "meanMM": round(float(dist.mean()), 4),
            "medianMM": round(float(np.median(dist)), 4), "p95MM": round(float(np.percentile(dist, 95)), 4),
            "maxMM": round(float(dist.max()), 4), "withinTolerance": round(float((dist <= tolerance).mean()), 4)}


def area_deviation(src, dst, tolerance, n=APP_SAMPLES, seed=3):
    """The same distances from points sampled evenly over the surface — what
    a model's tessellation cannot sway."""
    pts, _ = trimesh.sample.sample_surface(src, n, seed=seed)
    _, dist, _ = trimesh.proximity.closest_point(dst, pts)
    dist = np.asarray(dist, dtype=float)
    return {"samples": int(len(dist)), "meanMM": round(float(dist.mean()), 4),
            "p95MM": round(float(np.percentile(dist, 95)), 4), "maxMM": round(float(dist.max()), 4),
            "withinTolerance": round(float((dist <= tolerance).mean()), 4)}


def app_metrics(ref, mod, tolerance, resolution=APP_RESOLUTION):
    overlays = {view: round(silhouette_iou(ref, mod, view, resolution), 5) for view in ("front", "top", "right")}
    return {"overallIoU": round(float(np.mean(list(overlays.values()))), 5), "overlays": overlays,
            "referenceToModel": deviation(ref, mod, tolerance), "modelToReference": deviation(mod, ref, tolerance),
            "areaWeighted": {"referenceToModel": area_deviation(ref, mod, tolerance),
                             "modelToReference": area_deviation(mod, ref, tolerance)}}


def mesh_to_mesh(a, b, n=20_000, seed=5):
    """Area-weighted surface samples of each mesh to the other: how far two
    tessellations of the same geometry sit apart."""
    pa, _ = trimesh.sample.sample_surface(a, n, seed=seed)
    pb, _ = trimesh.sample.sample_surface(b, n, seed=seed)
    _, dab, _ = trimesh.proximity.closest_point(b, pa)
    _, dba, _ = trimesh.proximity.closest_point(a, pb)
    out = {}
    for key, d in (("aToB", np.asarray(dab)), ("bToA", np.asarray(dba))):
        out[key] = {"meanMM": round(float(d.mean()), 4), "p95MM": round(float(np.percentile(d, 95)), 4),
                    "maxMM": round(float(d.max()), 4)}
    return out


# ---- the part --------------------------------------------------------------------

def load_scan(part, path=None):
    p = path or os.path.join(part, "run", "scan.stl")
    if os.path.exists(p) and p.lower().endswith(".stl"):
        return trimesh.load(p, force="mesh"), p
    p = path or os.path.join(part, "analysis", "scan_cropped.glb")
    mesh = trimesh.load(p, force="mesh")
    if isinstance(mesh, trimesh.Scene):
        mesh = trimesh.util.concatenate(list(mesh.dump()))
    mesh.apply_scale(1000.0)                  # glTF is metres
    return mesh, p


def surface_to_scan(mesh, scan, n=3000, seed=9, inside_of=None):
    """How far a piece's surface sits from the scan: mean, p95 and max of
    the distance from `n` points sampled on it to the scan's surface, and
    the share within 3 mm. A pipe revolved in the right frame reads a
    millimetre or two; one revolved in the wrong frame tens. With
    `inside_of` (the model built before this piece) the points inside it
    are left out — a branch's root lengthened into its parent, the middle
    of a nozzle pair's axis through the barrel: inside by design, far from
    any scan surface."""
    pts, _ = trimesh.sample.sample_surface(mesh, n, seed=seed)
    pts = np.asarray(pts, dtype=float)
    if inside_of is not None and inside_of.is_watertight:
        try:
            outside = ~np.asarray(inside_of.contains(pts), dtype=bool)
            if outside.sum() >= 50:
                pts = pts[outside]
        except Exception:  # noqa: BLE001 — a containment test that fails leaves every point in
            pass
    _, dist, _ = trimesh.proximity.closest_point(scan, pts)
    dist = np.asarray(dist)
    return {"meanMM": float(dist.mean()), "p95MM": float(np.percentile(dist, 95)), "maxMM": float(dist.max()),
            "within3MM": float((dist <= 3.0).mean()), "points": int(len(pts))}


def built_features(part, features_path=None, summary=None):
    path = features_path or os.path.join(part, "features", "features.json")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        found = json.load(f).get("features", [])
    rows = (summary or {}).get("features")
    if rows is None:
        return found[:12]
    if len(rows) == len(found[: len(rows)]) and all(r.get("name") == f.get("name") for r, f in zip(rows, found)):
        return [f for r, f in zip(rows, found) if r.get("ok")]
    ok_names = [r["name"] for r in rows if r.get("ok")]
    return [f for f in found if f.get("name") in ok_names]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("part", help="the part's corpus folder (analysis/, features/, run/)")
    ap.add_argument("--out", default=None, help="default <part>/preview/")
    ap.add_argument("--tolerance", type=float, default=None, help="mm; default the build's (2 under 300 mm tall, else 3)")
    ap.add_argument("--analysis", default=None, help="a profile.json to use instead of <part>/analysis/profile.json")
    ap.add_argument("--features", default=None, help="a features.json to use instead of <part>/features/features.json")
    ap.add_argument("--no-features", action="store_true")
    ap.add_argument("--no-bosses", action="store_true")
    ap.add_argument("--no-bodies", action="store_true", help="leave out the bodies traced on their own axes (analysis bodies)")
    ap.add_argument("--scan", default=None, help="the scan to measure against (an STL, or a glTF in metres) instead of the part's")
    ap.add_argument("--all-features", action="store_true", help="every feature in the file, not only those the app built")
    ap.add_argument("--sections", type=int, default=96, help="facets round a revolve")
    ap.add_argument("--sheet", action="store_true", help="also run inspect_fit.py into <out>/qa/")
    args = ap.parse_args()
    part = os.path.abspath(args.part)
    out = os.path.abspath(args.out or os.path.join(part, "preview"))
    os.makedirs(out, exist_ok=True)
    with open(args.analysis or os.path.join(part, "analysis", "profile.json")) as f:
        analysis = json.load(f)
    summary = None
    summary_path = os.path.join(part, "run", "summary.json")
    if os.path.exists(summary_path):
        with open(summary_path) as f:
            summary = json.load(f)
    tolerance = args.tolerance or (2.0 if analysis["heightMM"] < 300 else 3.0)
    features = [] if args.no_features else built_features(part, args.features, None if args.all_features else summary)

    model, notes, parts = build_preview(analysis, features, args.sections, bosses=not args.no_bosses,
                                        secondaries=not args.no_bodies)
    stl = os.path.join(out, "preview.stl")
    model.export(stl)
    scan, scan_path = load_scan(part, args.scan)
    # Each body on its own axis: is its surface on the scan?
    for row in parts:
        tool = row.pop("_mesh", None)
        row.pop("_plane", None)
        before = row.pop("_before", None)
        if tool is not None:
            row["surfaceToScan"] = surface_to_scan(tool, scan, inside_of=before)
            fit = row["surfaceToScan"]
            print("   body %d (radius ~%.0f mm over %.0f mm%s): surface to scan mean %.2f mm, p95 %.2f, max %.1f; %.0f%% within 3 mm" % (
                row["index"], row["radiusMM"], row["lengthMM"],
                "" if row["parent"] is None else ", into body %s" % row["parent"],
                fit["meanMM"], fit["p95MM"], fit["maxMM"], 100 * fit["within3MM"]), flush=True)
    metrics = app_metrics(scan, model, tolerance)
    result = {"part": part, "scan": scan_path, "preview": stl, "toleranceMM": tolerance,
              "watertight": bool(model.is_watertight), "volumeMM3": float(model.volume) if model.is_watertight else None,
              "faces": int(len(model.faces)), "parts": parts, "notes": notes, "accuracy": metrics}
    line = "preview: IoU %.1f%% (front %.1f, top %.1f, right %.1f) · model→scan %.2f mm · scan→model %.2f mm · %s%s" % (
        metrics["overallIoU"] * 100, metrics["overlays"]["front"] * 100, metrics["overlays"]["top"] * 100,
        metrics["overlays"]["right"] * 100, metrics["modelToReference"]["meanMM"], metrics["referenceToModel"]["meanMM"],
        "closed solid" if model.is_watertight else "NOT closed", (" · %d note(s)" % len(notes)) if notes else "")
    print(line, flush=True)
    aw = metrics["areaWeighted"]
    print("         area-weighted: model→scan %.2f mm (95%% within %.2f) · scan→model %.2f mm (95%% within %.2f)" % (
        aw["modelToReference"]["meanMM"], aw["modelToReference"]["p95MM"],
        aw["referenceToModel"]["meanMM"], aw["referenceToModel"]["p95MM"]))
    for n in notes:
        print("   note:", n)
    if summary and summary.get("accuracy"):
        app = summary["accuracy"]
        result["app"] = {"overallIoU": app["overallIoU"], "overlays": {k: v["iou"] for k, v in app["overlays"].items()},
                         "modelToReference": app["modelToReference"]["meanMM"], "referenceToModel": app["referenceToModel"]["meanMM"]}
        print("app:     IoU %.1f%% (front %.1f, top %.1f, right %.1f) · model→scan %.2f mm · scan→model %.2f mm" % (
            app["overallIoU"] * 100, app["overlays"]["front"]["iou"] * 100, app["overlays"]["top"]["iou"] * 100,
            app["overlays"]["right"]["iou"] * 100, app["modelToReference"]["meanMM"], app["referenceToModel"]["meanMM"]))
    cad = os.path.join(part, "run", os.path.basename(part) + "-cad.stl")
    if os.path.exists(cad):
        app_mesh = trimesh.load(cad, force="mesh")
        d = mesh_to_mesh(model, app_mesh)
        result["meshToApp"] = d
        print("preview vs the app's export: preview→app mean %.2f mm (p95 %.2f, max %.1f) · app→preview mean %.2f mm (p95 %.2f, max %.1f)" % (
            d["aToB"]["meanMM"], d["aToB"]["p95MM"], d["aToB"]["maxMM"], d["bToA"]["meanMM"], d["bToA"]["p95MM"], d["bToA"]["maxMM"]))
    with open(os.path.join(out, "preview.json"), "w") as f:
        json.dump(result, f, indent=1)
    if args.sheet:
        qa = os.path.join(out, "qa")
        cmd = [sys.executable, "-I", os.path.join(HERE, "inspect_fit.py"), "--reference", scan_path if scan_path.endswith(".stl") else stl,
               "--model", stl, "--out", qa, "--tolerance", str(tolerance)]
        if not scan_path.endswith(".stl"):
            scan_stl = os.path.join(out, "scan.stl")
            scan.export(scan_stl)
            cmd[4] = scan_stl
        subprocess.run(cmd, check=False)
    print("wrote", stl, "and", os.path.join(out, "preview.json"))


if __name__ == "__main__":
    main()
