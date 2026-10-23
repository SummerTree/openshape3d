#!/usr/bin/env python3
"""Geometry readers for the scan-to-CAD recipes: fit a sphere or an axis
to a mesh, trace a radial profile along an axis, cut a planar section and
turn its loop into the lines and arcs a sketch wants.

Imported by `analyze_assembly.py`; nothing here talks to the app.
Millimetres and radians throughout (sketch arcs take radians).
"""
import math

import numpy as np


# ---- fits ------------------------------------------------------------------

def fit_sphere(points):
    """Least squares sphere: centre, radius, per-point |residual|."""
    pts = np.asarray(points, dtype=float)
    A = np.hstack([2 * pts, np.ones((len(pts), 1))])
    b = (pts ** 2).sum(axis=1)
    x, *_ = np.linalg.lstsq(A, b, rcond=None)
    c = x[:3]
    r = math.sqrt(max(x[3] + c @ c, 0.0))
    return c, r, np.abs(np.linalg.norm(pts - c, axis=1) - r)


def fit_axis(points, iterations=6):
    """Axis of a turned part: start from the principal direction, then
    refine as the line through the centres of thin slices (a chamfer or a
    groove barely moves a slice's centre). Returns (point, unit direction)."""
    pts = np.asarray(points, dtype=float)
    c = pts.mean(axis=0)
    _, _, vt = np.linalg.svd(pts - c, full_matrices=False)
    d = vt[0]
    for _ in range(iterations):
        h = (pts - c) @ d
        edges = np.linspace(h.min(), h.max(), 25)
        centres = []
        for i in range(24):
            sel = (h >= edges[i]) & (h < edges[i + 1])
            if sel.sum() >= 12:
                centres.append(pts[sel].mean(axis=0))
        centres = np.array(centres)
        if len(centres) < 3:
            break
        cc = centres.mean(axis=0)
        _, _, vt = np.linalg.svd(centres - cc, full_matrices=False)
        d_new = vt[0] if vt[0] @ d > 0 else -vt[0]
        c, d = cc, d_new / np.linalg.norm(d_new)
    return c, d


def radial_profile(points, origin, direction, band=0.5, stat="max"):
    """(h, r) pairs along the axis, one per band: `stat` of the radius in
    the band — `max` for a CAD mesh (the facets sit inside the true
    circle, so the max is nearest the true radius), `median` for a scan."""
    pts = np.asarray(points, dtype=float)
    h = (pts - origin) @ direction
    perp = (pts - origin) - np.outer(h, direction)
    r = np.linalg.norm(perp, axis=1)
    edges = np.arange(h.min(), h.max() + band, band)
    out = []
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1])
        if sel.sum() >= 3:
            val = r[sel].max() if stat == "max" else float(np.median(r[sel]))
            out.append((float((edges[i] + edges[i + 1]) / 2), float(val)))
    return out, (float(h.min()), float(h.max()))


# ---- sections and outlines ------------------------------------------------

def section_loops(mesh, origin, normal, x_axis=None):
    """Cut the mesh with a plane and return its closed loops as 2D point
    arrays in the plane's (x, y) frame, largest area first, plus the frame."""
    import trimesh
    normal = np.asarray(normal, dtype=float)
    normal /= np.linalg.norm(normal)
    if x_axis is None:
        ref = np.array([1.0, 0, 0]) if abs(normal[0]) < 0.9 else np.array([0, 1.0, 0])
        x_axis = ref - (ref @ normal) * normal
    x_axis = np.asarray(x_axis, dtype=float)
    x_axis /= np.linalg.norm(x_axis)
    y_axis = np.cross(normal, x_axis)
    sec = mesh.section(plane_origin=origin, plane_normal=normal)
    if sec is None:
        return [], (x_axis, y_axis)
    loops = []
    for path in sec.discrete:
        p = np.asarray(path)
        rel = p - np.asarray(origin)
        xy = np.column_stack([rel @ x_axis, rel @ y_axis])
        if np.allclose(xy[0], xy[-1]):
            xy = xy[:-1]
        if len(xy) >= 3:
            loops.append(xy)
    loops.sort(key=lambda q: -abs(polygon_area(q)))
    return loops, (x_axis, y_axis)


def polygon_area(xy):
    x, y = xy[:, 0], xy[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def face_loops(mesh, normal, level, tol=0.05, x_axis=None):
    """Outline(s) of the planar faces whose normal is `normal` at offset
    `level` along it — a cap, a pocket floor — as 2D loops, largest first."""
    import trimesh
    normal = np.asarray(normal, dtype=float)
    normal /= np.linalg.norm(normal)
    n = mesh.face_normals @ normal
    d = mesh.triangles_center @ normal
    idx = np.where((n > 0.98) & (np.abs(d - level) < tol))[0]
    if len(idx) == 0:
        return [], None
    sub = mesh.submesh([idx], append=True)
    outline = sub.outline()
    origin = normal * level
    if x_axis is None:
        ref = np.array([1.0, 0, 0]) if abs(normal[0]) < 0.9 else np.array([0, 1.0, 0])
        x_axis = ref - (ref @ normal) * normal
    x_axis = np.asarray(x_axis, dtype=float)
    x_axis /= np.linalg.norm(x_axis)
    y_axis = np.cross(normal, x_axis)
    loops = []
    for path in outline.discrete:
        p = np.asarray(path)
        rel = p - origin
        xy = np.column_stack([rel @ x_axis, rel @ y_axis])
        if np.allclose(xy[0], xy[-1]):
            xy = xy[:-1]
        if len(xy) >= 3:
            loops.append(xy)
    loops.sort(key=lambda q: -abs(polygon_area(q)))
    return loops, (x_axis, y_axis)


# ---- lines and arcs -------------------------------------------------------

def circle_through(p, q, r):
    """Centre and radius of the circle through three 2D points (None if collinear)."""
    ax, ay = p
    bx, by = q
    cx, cy = r
    d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < 1e-9:
        return None
    ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
    uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d
    return np.array([ux, uy]), math.hypot(ax - ux, ay - uy)


def fit_circle_2d(xy):
    """Algebraic least-squares circle through 2D points: centre, radius, max |residual|."""
    xy = np.asarray(xy, dtype=float)
    A = np.column_stack([2 * xy, np.ones(len(xy))])
    b = (xy ** 2).sum(axis=1)
    x, *_ = np.linalg.lstsq(A, b, rcond=None)
    c = x[:2]
    r = math.sqrt(max(x[2] + c @ c, 0.0))
    return c, r, float(np.abs(np.linalg.norm(xy - c, axis=1) - r).max())


def segments_from_loop(xy, tol=0.05, min_arc_points=4, max_radius=None):
    """Turn a closed polyline into a list of lines and arcs.

    A tessellated arc is a run of short edges turning the same way by
    similar angles; a true corner is one big turn. Walk the loop: at
    every vertex measure the turn; group consecutive vertices whose
    turns are small (< 40°) and of one sign into candidate arcs, fit a
    circle, and keep the arc if every point of the run sits within `tol`
    of it (and the radius is under `max_radius`); everything else stays
    as lines between the surviving vertices.

    Returns [{"kind": "line", "a": [x,y], "b": [x,y]} |
             {"kind": "arc", "center": [x,y], "radius": r, "start": rad, "end": rad, "ccw": bool, "a": .., "b": ..}]
    in loop order, closed."""
    pts = np.asarray(xy, dtype=float)
    n = len(pts)
    if n < 3:
        return []
    # Merge vertices closer than `merge` to their predecessor: a CAD
    # tessellation often doubles every corner of an arc 0.25 mm apart,
    # and the turn at such a stub is noise that breaks the run.
    merge = max(4 * tol, 0.3)
    keep = [0]
    for i in range(1, n):
        if np.linalg.norm(pts[i] - pts[keep[-1]]) > merge:
            keep.append(i)
    if len(keep) > 1 and np.linalg.norm(pts[keep[-1]] - pts[keep[0]]) <= merge:
        keep.pop()
    pts = pts[keep]

    def turns(p):
        prev = p - np.roll(p, 1, axis=0)
        nxt = np.roll(p, -1, axis=0) - p
        ang_prev = np.arctan2(prev[:, 1], prev[:, 0])
        ang_next = np.arctan2(nxt[:, 1], nxt[:, 0])
        return (ang_next - ang_prev + math.pi) % (2 * math.pi) - math.pi      # signed, −π..π

    # Drop collinear vertices (a chord split in two): they carry no turn and
    # their midpoint sits inside the arc by the sagitta, which would fail
    # the fit.
    t = turns(pts)
    pts = pts[np.abs(t) > math.radians(0.5)]
    n = len(pts)
    if n < 3:
        return []
    turn = turns(pts)
    smooth = np.abs(turn) < math.radians(40)
    # Candidate runs: maximal sequences of consecutive vertices with smooth
    # turns of one sign. A tessellated arc's END vertices (the tangent
    # points) turn by half a step and belong to the run; the arc spans the
    # run exactly, and the fit uses the run's vertices only.
    arcs = []     # (start_index, end_index inclusive, center, radius, ccw, run)
    corners = np.where(~smooth)[0]
    if len(corners):
        start = int(corners[0])
    else:
        # No corner at all (a stadium, a circle): start right after the
        # longest edge, so the walk's seam falls on a line, not inside an arc.
        edges = np.linalg.norm(np.roll(pts, -1, axis=0) - pts, axis=1)
        start = (int(np.argmax(edges)) + 1) % n
    order = [(start + k) % n for k in range(n)]
    i = 0
    while i < n:
        vi = order[i]
        if not smooth[vi]:
            i += 1
            continue
        sign = np.sign(turn[vi])
        j = i
        while j + 1 < n and smooth[order[j + 1]] and np.sign(turn[order[j + 1]]) == sign:
            j += 1
        run = [order[k] for k in range(i, j + 1)]

        # Two arcs turning the same way with a straight line between them
        # read as one run (the line's end vertices are tangent points, each
        # turning by half a step). Fit; if the circle does not hold, split
        # at the run's longest edge and try the halves.
        def fit_run(r_):
            if len(r_) < min_arc_points:
                return
            c, r, resid = fit_circle_2d(pts[r_])
            if resid <= tol and (max_radius is None or r <= max_radius):
                arcs.append((r_[0], r_[-1], c, r, sign > 0, r_))
                return
            lengths = [np.linalg.norm(pts[r_[k + 1]] - pts[r_[k]]) for k in range(len(r_) - 1)]
            k = int(np.argmax(lengths))
            fit_run(r_[:k + 1])
            fit_run(r_[k + 1:])
        fit_run(run)
        i = j + 1
    # Emit in loop order from `start`.
    out = []
    arc_at = {a[0]: a for a in arcs}
    k = 0
    while k < n:
        vi = order[k]
        if vi in arc_at:
            a0, a1, c, r, ccw, run = arc_at[vi]
            pa, pb = pts[a0], pts[a1]
            sa = math.atan2(pa[1] - c[1], pa[0] - c[0])
            sb = math.atan2(pb[1] - c[1], pb[0] - c[0])
            out.append({"kind": "arc", "center": [float(c[0]), float(c[1])], "radius": float(r),
                        "start": float(sa), "end": float(sb), "ccw": bool(ccw),
                        "a": [float(pa[0]), float(pa[1])], "b": [float(pb[0]), float(pb[1])]})
            k += len(run) - 1
            continue
        vj = order[(k + 1) % n]
        pa, pb = pts[vi], pts[vj]
        out.append({"kind": "line", "a": [float(pa[0]), float(pa[1])], "b": [float(pb[0]), float(pb[1])]})
        k += 1
    # Snap every end point onto the arcs' own ends, so the loop closes exactly
    # (an arc's end computed from its centre and radius is off the traced
    # vertex by the fit residual).
    for s in out:
        if s["kind"] == "arc":
            c, r = s["center"], s["radius"]
            s["a"] = [c[0] + r * math.cos(s["start"]), c[1] + r * math.sin(s["start"])]
            s["b"] = [c[0] + r * math.cos(s["end"]), c[1] + r * math.sin(s["end"])]
    for s, nxt_s in zip(out, out[1:] + out[:1]):
        if s["kind"] == "line" and nxt_s["kind"] == "arc":
            s["b"] = list(nxt_s["a"])
        if s["kind"] == "arc" and nxt_s["kind"] == "line":
            nxt_s["a"] = list(s["b"])
    return out


def arcs_in_polyline(simplified, dense, tol, min_arc_points=4, max_radius=None, min_span=0.0, row_heights=None,
                     tol_per_radius=0.0, min_sagitta=0.0):
    """Lines and arcs for an OPEN polyline — a revolve's radial profile.

    `simplified` is the design polyline (after straightening and the
    simplifier: a dome is a run of a few points turning one way);
    `dense` the traced points it came from (one per scan band). Runs of
    same-sign turns on the simplified polyline are fitted with a circle
    through their own vertices; the arc is kept when every dense point
    between the run's ends sits within `tol` of it — the scanner's noise
    is what `tol` is. `min_span` is the shortest chord worth an arc (a
    rolled seam a few millimetres tall is lines); `row_heights`, the
    heights of a mesh's vertex rows, lets a low-poly mesh's chords off:
    its rows lie on the true curve but the facets between them cut the
    corner by chord²/8r, and that much is allowed on top of `tol`.
    Returns segments in order, `line` or `arc`, like `segments_from_loop`."""
    pts = np.asarray(simplified, dtype=float)
    dense = np.asarray(dense, dtype=float)
    n = len(pts)
    if n < 3:
        return [{"kind": "line", "a": [float(a) for a in pts[i]], "b": [float(b) for b in pts[i + 1]]} for i in range(n - 1)]
    prev = pts[1:-1] - pts[:-2]
    nxt = pts[2:] - pts[1:-1]
    ang_prev = np.arctan2(prev[:, 1], prev[:, 0])
    ang_next = np.arctan2(nxt[:, 1], nxt[:, 0])
    turn = np.zeros(n)
    turn[1:-1] = (ang_next - ang_prev + math.pi) % (2 * math.pi) - math.pi
    smooth = (np.abs(turn) < math.radians(60)) & (np.abs(turn) > math.radians(0.5))
    smooth[0] = smooth[-1] = False
    arcs = {}
    i = 1
    while i < n - 1:
        if not smooth[i]:
            i += 1
            continue
        sign = np.sign(turn[i])
        j = i
        while j + 1 < n - 1 and smooth[j + 1] and np.sign(turn[j + 1]) == sign:
            j += 1
        # The run's own vertices turn; whether the vertex before it and the
        # one after it (the polyline's ends have no turn at all) lie on the
        # arc too is tried, widest first, and the first circle that holds
        # on the dense points between its ends wins.
        core = list(range(i, j + 1))
        candidates = [[i - 1] + core + [j + 1], core + [j + 1], [i - 1] + core, core]
        for run in candidates:
            if len(run) < min_arc_points:
                continue
            c, r, _ = fit_circle_2d(pts[run])
            if max_radius is not None and r > max_radius:
                continue
            # Validate on the dense points between the run's ends, by the
            # profile's own parameter (height).
            lo, hi = sorted((pts[run[0]][1], pts[run[-1]][1]))
            chord = float(np.linalg.norm(pts[run[-1]] - pts[run[0]]))
            if chord < min_span:
                continue
            # A barely bent run is a line with a bulge the simplifier would
            # have dropped: an arc has to bow by at least `min_sagitta`.
            if min_sagitta > 0 and chord * chord / (8.0 * r) < min_sagitta:
                continue
            between = dense[(dense[:, 1] >= lo) & (dense[:, 1] <= hi)]
            if len(between) < 3:
                continue
            allowance = 0.0
            if row_heights is not None and len(row_heights):
                rows = np.concatenate([[lo], row_heights[(row_heights > lo) & (row_heights < hi)], [hi]])
                # A facet's chord, never more than the tolerance and a half:
                # a drum's smooth middle is one 230 mm quad, and that gap
                # would excuse any circle at all.
                allowance = min(float(np.diff(rows).max()) ** 2 / (8.0 * r), 1.5 * tol)
            resid = float(np.abs(np.linalg.norm(between - c, axis=1) - r).max())
            if resid <= max(tol, tol_per_radius * r) + allowance:
                arcs[run[0]] = (run, c, r, sign > 0)
                break
        i = j + 1
    out = []
    k = 0
    while k < n - 1:
        if k in arcs:
            run, c, r, ccw = arcs[k]
            pa, pb = pts[run[0]], pts[run[-1]]
            sa = math.atan2(pa[1] - c[1], pa[0] - c[0])
            sb = math.atan2(pb[1] - c[1], pb[0] - c[0])
            out.append({"kind": "arc", "center": [float(c[0]), float(c[1])], "radius": float(r),
                        "start": float(sa), "end": float(sb), "ccw": bool(ccw),
                        "a": [float(pa[0]), float(pa[1])], "b": [float(pb[0]), float(pb[1])]})
            k = run[-1]
            continue
        out.append({"kind": "line", "a": [float(pts[k][0]), float(pts[k][1])], "b": [float(pts[k + 1][0]), float(pts[k + 1][1])]})
        k += 1
    # Snap the ends onto the arcs so the loop closes exactly.
    for s in out:
        if s["kind"] == "arc":
            c, r = s["center"], s["radius"]
            s["a"] = [c[0] + r * math.cos(s["start"]), c[1] + r * math.sin(s["start"])]
            s["b"] = [c[0] + r * math.cos(s["end"]), c[1] + r * math.sin(s["end"])]
    for s, t in zip(out, out[1:]):
        if s["kind"] == "line" and t["kind"] == "arc":
            s["b"] = list(t["a"])
        if s["kind"] == "arc" and t["kind"] == "line":
            t["a"] = list(s["b"])
    return out


def _reverse(segments):
    out = []
    for s in reversed(segments):
        t = dict(s, a=list(s["b"]), b=list(s["a"]))
        if s["kind"] == "arc":
            t["start"], t["end"], t["ccw"] = s["end"], s["start"], not s["ccw"]
        out.append(t)
    return out


def _reflect_h(segments, H):
    """The segments with h → H − h (a bottom-open container handled as a top-open one)."""
    out = []
    for s in segments:
        t = dict(s, a=[s["a"][0], H - s["a"][1]], b=[s["b"][0], H - s["b"][1]])
        if s["kind"] == "arc":
            t["center"] = [s["center"][0], H - s["center"][1]]
            t["start"], t["end"], t["ccw"] = -s["start"], -s["end"], not s["ccw"]
        out.append(t)
    return out


def _polyline_of(segments, arc_steps=16):
    pts = []
    for s in segments:
        if s["kind"] == "line":
            pts.append(s["a"])
        else:
            c, r = s["center"], s["radius"]
            sa, sb = s["start"], s["end"]
            if s["ccw"]:
                while sb <= sa:
                    sb += 2 * math.pi
            else:
                while sb >= sa:
                    sb -= 2 * math.pi
            for k in range(arc_steps):
                t = sa + (sb - sa) * k / arc_steps
                pts.append([c[0] + r * math.cos(t), c[1] + r * math.sin(t)])
    return np.array(pts, dtype=float)


def loop_self_intersects(segments):
    """Does the closed loop cross itself? Checked on a polyline through the
    segments (arcs sampled), every pair of non-adjacent edges."""
    p = _polyline_of(segments)
    n = len(p)
    if n < 4:
        return False
    a, b = p, np.roll(p, -1, axis=0)

    def orient(o, p1, p2):
        return (p1[:, 0] - o[:, 0]) * (p2[:, 1] - o[:, 1]) - (p1[:, 1] - o[:, 1]) * (p2[:, 0] - o[:, 0])
    for i in range(n):
        j = np.arange(i + 2, n if i > 0 else n - 1)
        if len(j) == 0:
            continue
        a1 = np.repeat(a[i][None, :], len(j), axis=0)
        b1 = np.repeat(b[i][None, :], len(j), axis=0)
        a2, b2 = a[j], b[j]
        d1, d2 = orient(a1, b1, a2), orient(a1, b1, b2)
        d3, d4 = orient(a2, b2, a1), orient(a2, b2, b1)
        if np.any((d1 * d2 < -1e-9) & (d3 * d4 < -1e-9)):
            return True
    return False


def hollow_section(segments, height, wall, open_end="top"):
    """A container's half-section as one closed loop (see `_hollow_once`).
    Everything is done with the open end at the top; a bottom-open part is
    reflected in, and its loop reflected back. The inner profile is the
    outer one offset a wall in; when that offset folds over itself (a
    stepped cap, rim steps smaller than the wall) the outer polyline is
    simplified with a growing tolerance until the offset holds, and failing
    that the inner profile is one straight wall at the body radius, with
    the floor where the outer profile first narrows below it."""
    flipped = open_end == "bottom"
    work = _reverse(_reflect_h(segments, height)) if flipped else [dict(s) for s in segments]

    def back(loop):
        return _reverse(_reflect_h(loop, height)) if flipped else loop

    loop = _hollow_once(work, height, wall)
    if not loop_self_intersects(loop):
        return back(loop)
    pts = [tuple(work[0]["a"])] + [tuple(s["b"]) for s in work]
    for factor in (2.0, 4.0, 8.0, 16.0):
        coarse = _douglas_peucker(pts, factor * wall)
        simple = [{"kind": "line", "a": list(a), "b": list(b)} for a, b in zip(coarse, coarse[1:])]
        loop = _hollow_once(work, height, wall, inner_source=simple)
        if not loop_self_intersects(loop):
            return back(loop)
    # Last resort: the inner profile as a function of height — the outer
    # radius eroded by the wall (the least radius within a wall above and
    # below, less the wall), so it can neither cross the outer profile nor
    # itself; outward beads narrower than two walls vanish from the inside.
    # The floor sits where the body first reaches its radius, scanning up
    # from the closed end (a cap or a foot narrower than the body stays
    # solid under it).
    radii = [p[0] for p in pts]
    r_body = float(np.median(radii))
    floor_h = wall
    for q in sorted(pts, key=lambda q: q[1]):
        if q[0] >= r_body - 1.0:
            floor_h = max(wall, q[1] + wall)
            break
    top = work[-1]["b"]
    eroded = _eroded_inner(work, wall, floor_h, top[1])
    return back(_hollow_once(work, height, wall, inner_source=eroded, floor_h=floor_h, offset=False))


def cavity_section(segments, height, wall, open_end="top", overshoot=5.0, floor_from_rim=None):
    """A container's cavity as its own closed loop, to revolve and SUBTRACT
    from the solid revolve of the outer profile: the inner profile is the
    outer one eroded a wall in (`_eroded_inner`, a function of height, so
    it can never fold), from the floor to `overshoot` past the open rim,
    closed along the axis. Two simple loops and one boolean, where one
    hollow loop offset round a ribbed profile folded over itself.
    Returns (segments, seed point) in the profile's own frame."""
    flipped = open_end == "bottom"
    work = _reverse(_reflect_h(segments, height)) if flipped else [dict(s) for s in segments]
    pts = [tuple(work[0]["a"])] + [tuple(s["b"]) for s in work]
    top_h = work[-1]["b"][1]
    # The floor: where the profile, scanning up from the closed end, first
    # reaches nine tenths of the widest it gets in the bottom quarter — a
    # bucket's foot ring is already there (floor one wall up), a drum's
    # chime climbs to it over 50 mm (the floor at the chime's top).
    lower = [q for q in pts if q[1] <= 0.25 * top_h] or pts[:2]
    arrive = 0.9 * max(q[0] for q in lower)
    floor_h = wall
    for q in sorted(pts, key=lambda q: q[1]):
        if q[0] >= arrive:
            floor_h = max(wall, q[1] + wall)
            break
    # The rays `detect_open_top` sent down the open end measured the floor
    # itself: when they stopped short of the far end, that is where the
    # floor is (a drum's is 16 mm up its chime, not at the chime's top).
    if floor_from_rim is not None and floor_from_rim < top_h - 1.0:
        floor_h = max(wall, top_h - floor_from_rim)
    inner = _eroded_inner(work, wall, floor_h, top_h)
    if not inner:
        return [], None
    first, last = inner[0]["a"], inner[-1]["b"]
    lid = top_h + overshoot
    loop = ([{"kind": "line", "a": [0.0, floor_h], "b": list(first)}] + inner
            + [{"kind": "line", "a": list(last), "b": [last[0], lid]},
               {"kind": "line", "a": [last[0], lid], "b": [0.0, lid]},
               {"kind": "line", "a": [0.0, lid], "b": [0.0, floor_h]}])
    for s, t in zip(loop, loop[1:]):
        t["a"] = list(s["b"])
    loop = [s for s in loop if abs(s["a"][0] - s["b"][0]) > 1e-6 or abs(s["a"][1] - s["b"][1]) > 1e-6]
    mid_h = (floor_h + top_h) / 2
    r_mid = float(np.interp(mid_h, [q["a"][1] for q in inner] + [last[1]], [q["a"][0] for q in inner] + [last[0]]))
    seed = [max(0.5 * r_mid, 1.0), mid_h]
    if flipped:
        loop = _reverse(_reflect_h(loop, height))
        seed = [seed[0], height - seed[1]]
    return loop, seed


def _eroded_inner(outer, wall, floor_h, top_h, step=1.0):
    """Lines for an inner profile r(h) = min outer radius within ±wall of h,
    less the wall, from `floor_h` to `top_h`, simplified to 0.3 mm."""
    pts = _polyline_of(outer, arc_steps=24)
    pts = np.vstack([pts, [outer[-1]["b"]]])
    # Dense samples along every edge, then the least radius per height bin.
    dense = []
    for a, b in zip(pts, pts[1:]):
        n = max(2, int(np.linalg.norm(b - a) / step) + 1)
        dense.append(a + (b - a) * np.linspace(0, 1, n)[:, None])
    dense = np.vstack(dense)
    hs = np.arange(floor_h, top_h + step, step)
    bins = np.clip(((dense[:, 1] - floor_h) / step).round().astype(int), 0, len(hs) - 1)
    r_min = np.full(len(hs), np.inf)
    np.minimum.at(r_min, bins, dense[:, 0])
    empty = ~np.isfinite(r_min)
    if empty.any() and (~empty).any():
        r_min[empty] = np.interp(hs[empty], hs[~empty], r_min[~empty])
    from scipy.ndimage import minimum_filter1d
    k = max(1, int(round(wall / step)))
    r_in = minimum_filter1d(r_min, size=2 * k + 1, mode="nearest") - wall
    r_in = np.maximum(r_in, 0.5)
    prof = [(float(r), float(h)) for r, h in zip(r_in, hs)]
    prof = _douglas_peucker(prof, 0.3)
    return [{"kind": "line", "a": list(a), "b": list(b)} for a, b in zip(prof, prof[1:])]


def _douglas_peucker(points, epsilon):
    if len(points) < 3:
        return list(points)
    a, b = np.array(points[0]), np.array(points[-1])
    ab = b - a
    norm = np.linalg.norm(ab)
    rel = np.array(points) - a
    d = np.linalg.norm(rel, axis=1) if norm < 1e-9 else np.abs(ab[0] * rel[:, 1] - ab[1] * rel[:, 0]) / norm
    i = int(np.argmax(d))
    if d[i] > epsilon:
        return _douglas_peucker(points[: i + 1], epsilon)[:-1] + _douglas_peucker(points[i:], epsilon)
    return [points[0], points[-1]]


def _hollow_once(segments, height, wall, inner_source=None, floor_h=None, offset=True):
    """A container's half-section as one closed loop: the outer profile
    (`segments`, foot to top, radius against height) up the outside,
    across the rim at the open end, and back down a wall thickness inside
    to a floor `wall` thick at the closed end. Lines move in by `wall`;
    an arc keeps its centre and loses `wall` of radius when it bulges
    outward (a dome, a belly) or gains it when it is a groove. One revolve
    of this is the bucket — the kernel's own shell offset refused a ribbed
    barrel at every thickness.

    Returns segments in loop order, starting on the axis at the closed end."""
    outer = [dict(s) for s in segments]
    base = [dict(s) for s in (segments if inner_source is None else inner_source)]
    # Inner profile, outer order (foot → top), a wall in: every line moved
    # along its own inward normal (a lip's underside moves UP, a shoulder
    # moves down — moving everything radially left a lip's inner face on
    # its outer face and the wall there zero thick, which the kernel
    # rendered as a detached ring), neighbouring lines mitred back
    # together, arcs concentric.
    inner = []
    for s in base:
        if not offset:
            inner.append(dict(s, a=list(s["a"]), b=list(s["b"])))
        elif s["kind"] == "line":
            d = np.array(s["b"]) - np.array(s["a"])
            n = np.linalg.norm(d)
            if n < 1e-9:
                continue
            inward = np.array([-d[1], d[0]]) / n            # left of the upward walk: toward the axis
            a = (np.array(s["a"]) + inward * wall).tolist()
            b = (np.array(s["b"]) + inward * wall).tolist()
            inner.append({"kind": "line", "a": a, "b": b})
        else:
            mid_r = (s["a"][0] + s["b"][0]) / 2
            convex = s["center"][0] < mid_r          # centre on the axis side: the arc bulges out
            r = s["radius"] - wall if convex else s["radius"] + wall
            if r <= 0.5:
                inner.append({"kind": "line", "a": [s["a"][0] - wall, s["a"][1]], "b": [s["b"][0] - wall, s["b"][1]]})
                continue
            c = s["center"]
            inner.append({"kind": "arc", "center": list(c), "radius": r, "start": s["start"], "end": s["end"], "ccw": s["ccw"],
                          "a": [c[0] + r * math.cos(s["start"]), c[1] + r * math.sin(s["start"])],
                          "b": [c[0] + r * math.cos(s["end"]), c[1] + r * math.sin(s["end"])]})
    # Mitre: where two offset lines meet, both end at their intersection
    # (a bevel — just joined — when the corner is so sharp the mitre would
    # spike past two walls). A line meeting an arc snaps to the arc's end.
    for s, t in zip(inner, inner[1:]):
        if s["kind"] == "line" and t["kind"] == "line":
            p, q = np.array(s["a"]), np.array(s["b"])
            u, v = np.array(t["a"]), np.array(t["b"])
            d1, d2 = q - p, v - u
            den = d1[0] * d2[1] - d1[1] * d2[0]
            if abs(den) > 1e-9:
                k = ((u[0] - p[0]) * d2[1] - (u[1] - p[1]) * d2[0]) / den
                x = p + d1 * k
                if np.linalg.norm(x - q) <= 2 * wall and np.linalg.norm(x - u) <= 2 * wall:
                    s["b"] = x.tolist()
                    t["a"] = x.tolist()
                    continue
            # Parallel, or too sharp: join the ends with a short line later.
        elif s["kind"] == "line":
            s["b"] = list(t["a"])
        elif t["kind"] == "line":
            t["a"] = list(s["b"])
    joined = []
    for s in inner:
        if joined and np.linalg.norm(np.array(joined[-1]["b"]) - np.array(s["a"])) > 1e-6:
            joined.append({"kind": "line", "a": list(joined[-1]["b"]), "b": list(s["a"])})
        joined.append(s)
    inner = joined
    # Clip the inner profile to the floor level and start it there.
    if floor_h is None:
        floor_h = wall
    kept = []
    for s in inner:
        lo, hi = min(s["a"][1], s["b"][1]), max(s["a"][1], s["b"][1])
        if hi <= floor_h + 1e-6:
            continue
        if lo < floor_h and s["kind"] == "line":
            t = (floor_h - s["a"][1]) / (s["b"][1] - s["a"][1]) if abs(s["b"][1] - s["a"][1]) > 1e-9 else 0.0
            r_cut = s["a"][0] + (s["b"][0] - s["a"][0]) * t
            s = {"kind": "line", "a": [r_cut, floor_h], "b": list(s["b"])}
        elif lo < floor_h:
            # An arc through the floor: its part above the floor as a chord.
            top_pt = s["b"] if s["b"][1] > s["a"][1] else s["a"]
            s = {"kind": "line", "a": [top_pt[0] - 0.0, floor_h], "b": list(top_pt)}
        kept.append(s)
    inner = kept
    for s in inner:
        s["a"][0] = max(s["a"][0], 0.5)
        s["b"][0] = max(s["b"][0], 0.5)
    foot, top = outer[0]["a"], outer[-1]["b"]
    inner_top, inner_foot = inner[-1]["b"], inner[0]["a"]
    loop = ([{"kind": "line", "a": [0.0, 0.0], "b": [max(foot[0], 0.0), foot[1]]}]
            + outer
            + [{"kind": "line", "a": [top[0], top[1]], "b": [inner_top[0], top[1]]}]
            + ([{"kind": "line", "a": [inner_top[0], top[1]], "b": list(inner_top)}] if abs(inner_top[1] - top[1]) > 1e-6 else [])
            + _reverse(inner)
            + [{"kind": "line", "a": list(inner_foot), "b": [0.0, floor_h]},
               {"kind": "line", "a": [0.0, floor_h], "b": [0.0, 0.0]}])
    # Make the loop exactly continuous: each segment starts where the last ended.
    for s, t in zip(loop, loop[1:]):
        if t["kind"] == "line":
            t["a"] = list(s["b"])
        elif s["kind"] == "line":
            s["b"] = list(t["a"])
    loop = [s for s in loop if s["kind"] != "line" or abs(s["a"][0] - s["b"][0]) > 1e-6 or abs(s["a"][1] - s["b"][1]) > 1e-6]
    return loop


def sketch_entities(segments, snap=1e-3):
    """The app's entity list for a segment list: `line` {a, b} and `arc`
    {center, radius, startAngle, endAngle} (radians, counter-clockwise
    from start to end — a clockwise arc is written with its ends swapped).
    An arc's ends as the app will compute them (from the rounded centre,
    radius and angles) can sit a hundredth off the segment's own `a`/`b`;
    the lines on either side are moved onto those computed ends, since the
    profile detector bridges no gap at all ("revolve profile unresolved"
    on a 0.007 mm one)."""
    ents = []
    for s in segments:
        if s["kind"] == "line":
            if np.linalg.norm(np.array(s["a"]) - np.array(s["b"])) < snap:
                continue
            ents.append({"kind": "line", "a": [round(v, 4) for v in s["a"]], "b": [round(v, 4) for v in s["b"]]})
        else:
            sa, sb = (s["start"], s["end"]) if s["ccw"] else (s["end"], s["start"])
            while sb <= sa:
                sb += 2 * math.pi
            ents.append({"kind": "arc", "center": [round(v, 4) for v in s["center"]], "radius": round(s["radius"], 4),
                         "startAngle": round(sa, 6), "endAngle": round(sb, 6)})
    # Two arcs in a row meet only to the rounding: a short line between
    # their computed ends closes the loop (the detector bridges nothing).
    def arc_ends(e):
        c, r = e["center"], e["radius"]
        return ([c[0] + r * math.cos(e["startAngle"]), c[1] + r * math.sin(e["startAngle"])],
                [c[0] + r * math.cos(e["endAngle"]), c[1] + r * math.sin(e["endAngle"])])
    arc_end_points = [end for e in ents if e["kind"] == "arc" for end in arc_ends(e)]
    for f in ents:
        if f["kind"] != "line" or not arc_end_points:
            continue
        # Each line end goes to its NEAREST arc end only: a 0.3 mm line
        # between two arcs had both its ends pulled onto one arc and vanished.
        for key in ("a", "b"):
            end = min(arc_end_points, key=lambda q: math.hypot(f[key][0] - q[0], f[key][1] - q[1]))
            if math.hypot(f[key][0] - end[0], f[key][1] - end[1]) <= 0.5:
                f[key] = [round(end[0], 6), round(end[1], 6)]
    joined = []
    for e, f in zip(ents, ents[1:] + ents[:1]):
        joined.append(e)
        if e["kind"] == "arc" and f["kind"] == "arc":
            # A clockwise arc is written with its angles swapped, so the
            # junction may be either end of either arc: the nearest pair.
            pairs = [(p, q) for p in arc_ends(e) for q in arc_ends(f)]
            p, q = min(pairs, key=lambda pq: math.hypot(pq[0][0] - pq[1][0], pq[0][1] - pq[1][1]))
            gap = math.hypot(p[0] - q[0], p[1] - q[1])
            if 1e-5 < gap <= 0.5:
                joined.append({"kind": "line", "a": [round(p[0], 6), round(p[1], 6)],
                               "b": [round(q[0], 6), round(q[1], 6)]})
    return joined


def segments_png(path, loops_segments, points_loops=None, size=1200, margin=40):
    """A quick picture of fitted segments over the raw points, to be looked at."""
    from PIL import Image, ImageDraw
    allpts = np.vstack([np.vstack([s["a"], s["b"]] if s["kind"] == "line" else [s["a"], s["b"]]) for segs in loops_segments for s in segs])
    lo, hi = allpts.min(axis=0), allpts.max(axis=0)
    scale = (size - 2 * margin) / max(hi - lo)
    img = Image.new("RGB", (int((hi[0] - lo[0]) * scale) + 2 * margin, int((hi[1] - lo[1]) * scale) + 2 * margin), (20, 21, 24))
    draw = ImageDraw.Draw(img)

    def P(p):
        return (margin + (p[0] - lo[0]) * scale, img.height - margin - (p[1] - lo[1]) * scale)
    if points_loops:
        for pl in points_loops:
            for p in pl:
                x, y = P(p)
                draw.ellipse([x - 2, y - 2, x + 2, y + 2], fill=(110, 110, 120))
    for segs in loops_segments:
        for s in segs:
            if s["kind"] == "line":
                draw.line([P(s["a"]), P(s["b"])], fill=(90, 200, 120), width=2)
            else:
                c, r = s["center"], s["radius"]
                sa, sb = (s["start"], s["end"]) if s["ccw"] else (s["end"], s["start"])
                while sb <= sa:
                    sb += 2 * math.pi
                steps = max(8, int((sb - sa) / 0.05))
                prev = None
                for k in range(steps + 1):
                    t = sa + (sb - sa) * k / steps
                    q = P((c[0] + r * math.cos(t), c[1] + r * math.sin(t)))
                    if prev:
                        draw.line([prev, q], fill=(255, 150, 60), width=2)
                    prev = q
                x, y = P(c)
                draw.ellipse([x - 3, y - 3, x + 3, y + 3], outline=(255, 150, 60))
    img.save(path)
    return path
