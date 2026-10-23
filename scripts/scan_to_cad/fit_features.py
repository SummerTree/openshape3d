#!/usr/bin/env python3
"""What the revolve missed, and what to build for it.

    python3 fit_features.py --scan run/scan.stl --model run/part-cad.stl --analysis analysis/profile.json \
        --tolerance 2 --out features/

A turned body explains a can or a bollard outright; a pail has a handle, a
mug a handle and a lid lever, an extinguisher a hose, a horn and a grip. This
reads the scan against the model already built, keeps every scan triangle
that lies farther than a few tolerances from it, splits those into connected
pieces, and tries the three things a CAD feature can be on each piece:

    sweep     a tube — a wire handle, a hose, a strap: the piece's geodesic
              spine is traced, the centreline found by mean-shift inside it,
              the section's radius (or ellipse) read along it
    revolve   a body of revolution about its own axis — a horn, a hand-wheel,
              a knob: an axis fitted, the roundness checked band by band, the
              radial profile traced
    extrude   a plate or a block — a lever, a lug, a valve body: the thin
              direction by PCA, the outline in the plane as lines and arcs
              (an alpha shape of the projected points), extruded to the
              measured thickness

Each candidate is scored by the share of the piece's points it covers within
tolerance; the best one wins, what it leaves uncovered is split again and
tried again (a hose with a horn on its end is a sweep and then a revolve).
Pieces nothing explains are listed as `unexplained`, with where they are.

Writes `features.json` — a list of features in `build_recipe.py`'s terms,
world millimetres, every end that meets the body extended into it so the
union fuses — and `review.png`, the residual pieces in three views with the
spines and outlines drawn over them. `build_features.py` builds the list
into the model over MCP.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

try:
    import trimesh
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import dijkstra
    from scipy.spatial import Delaunay, cKDTree
except ImportError:
    sys.exit("pip install trimesh numpy scipy rtree pillow  (or run with the scan_to_cad venv)")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fit_primitives import fit_axis, fit_circle_2d, segments_from_loop  # noqa: E402


def unit(v):
    v = np.asarray(v, dtype=float)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def sample(mesh, n, seed=1):
    pts, fi = trimesh.sample.sample_surface(mesh, int(n), seed=seed)
    return np.asarray(pts, dtype=float), np.asarray(fi)


def surface_tree(mesh, spacing=0.7, cap=1_500_000):
    """A KD-tree of points spread over the mesh (about `spacing` mm apart)
    plus its vertices: distance-to-surface to within half a spacing."""
    n = int(min(cap, max(100_000, mesh.area / (spacing * spacing))))
    s, _ = sample(mesh, n, seed=3)
    return cKDTree(np.vstack([s, np.asarray(mesh.vertices, dtype=float)]))


def component_points(comp, n=5000, cap=9000):
    """Points on a residual piece: samples plus its vertices, with normals."""
    s, fi = sample(comp, n, seed=2)
    pts = np.vstack([s, np.asarray(comp.vertices, dtype=float)])
    nrm = np.vstack([np.asarray(comp.face_normals, dtype=float)[fi], np.asarray(comp.vertex_normals, dtype=float)])
    if len(pts) > cap:
        keep = np.random.default_rng(5).choice(len(pts), cap, replace=False)
        pts, nrm = pts[keep], nrm[keep]
    return pts, nrm


def douglas_peucker_3d(points, epsilon):
    pts = np.asarray(points, dtype=float)
    if len(pts) < 3:
        return pts.tolist()
    a, b = pts[0], pts[-1]
    ab = b - a
    L = np.linalg.norm(ab)
    if L < 1e-9:
        d = np.linalg.norm(pts - a, axis=1)
    else:
        t = ((pts - a) @ ab) / (L * L)
        proj = a + np.outer(np.clip(t, 0, 1), ab)
        d = np.linalg.norm(pts - proj, axis=1)
    i = int(np.argmax(d))
    if d[i] > epsilon:
        left = douglas_peucker_3d(pts[: i + 1], epsilon)
        right = douglas_peucker_3d(pts[i:], epsilon)
        return left[:-1] + right
    return [pts[0].tolist(), pts[-1].tolist()]


def douglas_peucker_2d(points, epsilon):
    pts = np.asarray(points, dtype=float)
    if len(pts) < 3:
        return pts.tolist()
    a, b = pts[0], pts[-1]
    ab = b - a
    L = np.linalg.norm(ab)
    if L < 1e-9:
        d = np.linalg.norm(pts - a, axis=1)
    else:
        d = np.abs(ab[0] * (pts[:, 1] - a[1]) - ab[1] * (pts[:, 0] - a[0])) / L
    i = int(np.argmax(d))
    if d[i] > epsilon:
        left = douglas_peucker_2d(pts[: i + 1], epsilon)
        right = douglas_peucker_2d(pts[i:], epsilon)
        return left[:-1] + right
    return [pts[0].tolist(), pts[-1].tolist()]


def resample_polyline(P, step):
    P = np.asarray(P, dtype=float)
    seg = np.linalg.norm(np.diff(P, axis=0), axis=1)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    if s[-1] < step:
        return P[[0, -1]]
    targets = np.arange(0.0, s[-1], step)
    targets = np.append(targets, s[-1])
    out = np.column_stack([np.interp(targets, s, P[:, k]) for k in range(3)])
    return out


# ---- the residual -----------------------------------------------------------

def far_components(scan, model_tree, far, min_area):
    """Pieces of the scan farther than `far` from the model: the triangles
    whose three corners are all far, split by adjacency, the small change
    dropped. Returns (pieces largest first, per-vertex distance)."""
    verts = np.asarray(scan.vertices, dtype=float)
    d, _ = model_tree.query(verts, workers=-1)
    far_f = (d > far)[np.asarray(scan.faces)].all(axis=1)
    idx = np.flatnonzero(far_f)
    if len(idx) == 0:
        return [], d
    sub = scan.submesh([idx], append=True)
    comps = trimesh.graph.connected_components(sub.face_adjacency, nodes=np.arange(len(sub.faces)))
    parts = []
    for c in comps:
        c = np.asarray(c)
        if len(c) < 4:
            continue
        m = sub.submesh([c], append=True)
        if m.area >= min_area:
            parts.append(m)
    parts.sort(key=lambda m: -m.area)
    return parts, d


# ---- sweep ------------------------------------------------------------------

DEBUG = bool(os.environ.get("FIT_DEBUG"))


def say(*parts):
    if DEBUG:
        print("      ", *parts, flush=True)


def tube_fit(comp, tol, far, model_tree):
    pts, nrm = component_points(comp)
    n = len(pts)
    if n < 60:
        say("tube: only", n, "points")
        return None
    # Thickness: a ray from each point into the piece meets the far wall a
    # chord away; the median chord is the tube's diameter.
    origins = pts - nrm * 0.2
    try:
        loc, idx_ray, _ = comp.ray.intersects_location(origins, -nrm, multiple_hits=False)
    except Exception:  # noqa: BLE001
        return None
    if len(idx_ray) < 20:
        say("tube: only", len(idx_ray), "inward rays hit")
        return None
    chords = np.linalg.norm(np.asarray(loc) - origins[idx_ray], axis=1)
    chords = chords[(chords > 0.5) & (chords < 400)]
    if len(chords) < 20:
        say("tube: only", len(chords), "chords")
        return None
    r0 = float(np.median(chords)) / 2
    say("tube: %d of %d rays hit, chord median %.1f mm -> r0 %.1f" % (len(chords), n, 2 * r0, r0))
    if r0 < 1.0:
        return None
    # Only the points well clear of the body: a handle's arch, a hose's
    # run. The lugs a wire hooks into and the rim they sit on lie within a
    # few tolerances of the model and would tangle the geodesic; the ends
    # are carried back into the body afterwards.
    d_body, _ = model_tree.query(pts, workers=-1)
    clear = d_body > max(3.0 * far, 2.0 * r0)
    if clear.sum() < 60:
        say("tube: only %d of %d points stand clear of the body" % (int(clear.sum()), n))
        return None
    say("tube: %d of %d points stand clear of the body" % (int(clear.sum()), n))
    pts, nrm = pts[clear], nrm[clear]
    n = len(pts)
    # The spine: the longest geodesic on a nearest-neighbour graph.
    k = 8
    tree = cKDTree(pts)
    dd, jj = tree.query(pts, k=k + 1)
    rows = np.repeat(np.arange(n), k)
    cols = jj[:, 1:].ravel()
    w = dd[:, 1:].ravel() + 1e-6
    G = coo_matrix((w, (rows, cols)), shape=(n, n)).tocsr()
    d0 = dijkstra(G, directed=False, indices=0)
    finite = np.isfinite(d0)
    if finite.sum() < 0.5 * n:
        # The biggest connected part of the graph.
        best = None
        for seed in range(0, n, max(1, n // 20)):
            ds = dijkstra(G, directed=False, indices=seed)
            f = np.isfinite(ds)
            if best is None or f.sum() > best[1].sum():
                best = (ds, f)
        d0, finite = best
    a = int(np.argmax(np.where(finite, d0, -1)))
    da, pred = dijkstra(G, directed=False, indices=a, return_predecessors=True)
    b = int(np.argmax(np.where(np.isfinite(da), da, -1)))
    path = [b]
    while path[-1] != a and pred[path[-1]] >= 0:
        path.append(int(pred[path[-1]]))
    path = path[::-1]
    length = float(da[b])
    say("tube: geodesic %.0f mm over %d path points" % (length, len(path)))
    if len(path) < 4:
        return None
    if length < 3.0 * r0:
        return None
    # The centreline: the piece's points binned by their geodesic distance
    # from one end, a tube's width per bin, so every bin holds a whole
    # cross-section (or a slice of one) and its mean sits on the axis. The
    # order is the distance itself — it cannot double back the way a path
    # traced round the skin does.
    # Bins a tube's width wide, and wide enough that each holds a score of
    # points: a thin wire sampled sparsely cannot afford 3 mm bins.
    step = max(2.0, 2.0 * r0, length / max(10.0, n / 25.0))
    reach = np.where(np.isfinite(da), da, -1.0)
    nb = int(length / step) + 1
    which = np.clip((reach / step).astype(int), 0, nb - 1)
    C, bin_members = [], []
    for k in range(nb):
        members = np.flatnonzero((which == k) & (reach >= 0))
        if len(members) < 5:
            continue
        C.append(pts[members].mean(axis=0))
        bin_members.append(members)
    C = np.asarray(C)
    if len(C) >= 5:
        kernel = np.ones(3) / 3
        sm = np.column_stack([np.convolve(C[:, k], kernel, mode="valid") for k in range(3)])
        C = np.vstack([C[:1], sm, C[-1:]])
    m = len(C)
    if m < 3:
        return None
    # Section along the centreline: radius, and the ellipse of the offsets.
    rows_out = []
    for i in range(m):
        t = unit(C[min(i + 1, m - 1)] - C[max(i - 1, 0)])
        near = bin_members[i] if i < len(bin_members) else tree.query_ball_point(C[i], 1.5 * r0)
        if len(near) < 8:
            rows_out.append(None)
            continue
        o = pts[near] - C[i]
        o_perp = o - np.outer(o @ t, t)
        rho = np.linalg.norm(o_perp, axis=1)
        # A bin that holds more than one branch (the wire and the lug it
        # hooks into) is no section at all: its spread gives it away.
        p75 = float(np.percentile(rho, 75))
        if p75 > 2.5 * max(float(np.median(rho)), 0.8 * r0) + 2 * tol:
            say("tube: bin %d mixed: %d points, rho median %.1f p75 %.1f" % (i, len(near), float(np.median(rho)), p75))
            rows_out.append(None)
            continue
        # A tube scanned from one side is half a skin: its points' median
        # distance from the centre falls short of the radius the chords gave.
        r = max(float(np.median(rho)), 0.8 * r0)
        # basis in the section plane
        e1 = unit(np.cross(t, [0, 0, 1.0]) if abs(t[2]) < 0.9 else np.cross(t, [1.0, 0, 0]))
        e2 = np.cross(t, e1)
        xy = np.column_stack([o_perp @ e1, o_perp @ e2])
        cov = np.cov(xy.T) if len(xy) > 3 else np.eye(2)
        vals, vecs = np.linalg.eigh(cov)
        major = vecs[:, int(np.argmax(vals))]
        minor = np.array([-major[1], major[0]])
        a_half = float(np.percentile(np.abs(xy @ major), 90)) / 0.95
        b_half = float(np.percentile(np.abs(xy @ minor), 90)) / 0.95
        major3 = unit(e1 * major[0] + e2 * major[1])
        rows_out.append({"c": C[i], "t": t, "r": r, "a": max(a_half, b_half), "b": max(min(a_half, b_half), 0.5),
                         "major": major3, "members": near, "rho": rho, "i": i})
    say("tube: %d centreline samples, radii %s" % (sum(x is not None for x in rows_out),
                                                       " ".join("%.1f" % x["r"] if x else "-" for x in rows_out)))
    if sum(x is not None for x in rows_out) < 3:
        return None
    # Runs of one radius: a hose keeps its radius, a horn on its end does
    # not; a mixed bin breaks the run.
    runs, run = [], []
    for x in rows_out:
        if x is None:
            if run:
                runs.append(run)
            run = []
            continue
        if run:
            med = float(np.median([y["r"] for y in run]))
            if abs(x["r"] - med) > max(0.35 * med, tol):
                runs.append(run)
                run = []
        run.append(x)
    if run:
        runs.append(run)
    # Runs that follow one another along the tube and differ in radius by
    # less than six tenths (a handle thick at the top, thinner below) are
    # ONE sweep at the median section — a continuous handle, not two
    # pieces with a step between; runs farther apart in radius meet end
    # to end so the union has no gap.
    merged = []
    for run in runs:
        if merged and run and merged[-1]:
            prev = merged[-1]
            r_prev = float(np.median([x["r"] for x in prev]))
            r_run = float(np.median([x["r"] for x in run]))
            near = abs(run[0]["i"] - prev[-1]["i"]) <= 6
            # Only runs of a steady radius merge: a hose must not be swept
            # into the horn that grows out of it.
            steady = all((max(x["r"] for x in rr) - min(x["r"] for x in rr)) < 0.5 * float(np.median([x["r"] for x in rr]))
                         for rr in (prev, run))
            if near and steady and max(r_prev, r_run) / max(min(r_prev, r_run), 1e-6) < 1.6:
                merged[-1] = prev + run
                continue
            if near:
                bridge = dict(run[0])
                bridge["r"] = prev[-1]["r"]
                bridge["a"], bridge["b"] = prev[-1]["a"], prev[-1]["b"]
                merged[-1] = prev + [bridge]
        merged.append(run)
    runs = merged
    features = []
    for run in runs:
        if len(run) < 3:
            continue
        r = float(np.median([x["r"] for x in run]))
        a = float(np.median([x["a"] for x in run]))
        b = float(np.median([x["b"] for x in run]))
        spine = np.array([x["c"] for x in run])
        span = float(np.sum(np.linalg.norm(np.diff(spine, axis=0), axis=1)))
        if r < 1.0 or span < max(4.0 * r, 15.0):
            say("tube: run of %d dropped (r %.1f, span %.0f)" % (len(run), r, span))
            continue
        # The run's own points against its own tube: a lever or a valve body
        # the geodesic walked through is no tube, whatever its bins' medians.
        rr = np.array([x["r"] for x in run])
        own = np.concatenate([np.abs(x["rho"] - x["r"]) <= max(tol, 0.3 * x["r"]) for x in run])
        # Half its points on the tube: a corrugated hose's bins carry the
        # valve's and the horn's neighbours and read 53–57 %.
        if float(own.mean()) < 0.5:
            say("tube: run of %d dropped (r %.1f): only %.0f%% of its own points on the tube" % (len(run), r, own.mean() * 100))
            continue
        # A radius that grows steadily along the run is a cone — a horn, a
        # nozzle: a revolve about the run's own line, not a tube.
        idx = np.arange(len(rr))
        trend = float(np.corrcoef(idx, rr)[0, 1]) if len(rr) >= 4 and rr.std() > 1e-9 else 0.0
        if abs(trend) > 0.85 and (rr.max() - rr.min()) > 0.5 * r:
            c0 = spine.mean(axis=0)
            _, _, vt = np.linalg.svd(spine - c0, full_matrices=False)
            d = unit(vt[0])
            if d @ (spine[-1] - spine[0]) < 0:
                d = -d
            hs = (spine - c0) @ d
            prof = [[float(x["r"]), float(hh)] for x, hh in zip(run, hs)]
            prof = douglas_peucker_2d(prof, max(tol * 0.5, 0.5))
            d_lo, _ = model_tree.query(c0 + d * hs.min())
            d_hi, _ = model_tree.query(c0 + d * hs.max())
            if d_lo < far + r:
                prof = [[prof[0][0], prof[0][1] - (far + 4.0)]] + prof
            if d_hi < far + r:
                prof = prof + [[prof[-1][0], prof[-1][1] + (far + 4.0)]]
            features.append({"kind": "revolve", "axis": {"origin": [round(float(v), 2) for v in c0],
                                                         "direction": [round(float(v), 5) for v in d]},
                             "profile": [[round(float(q), 2), round(float(hh), 2)] for q, hh in prof],
                             "lengthMM": round(span, 1), "radiusMM": round(r, 2), "cone": True})
            say("tube: run of %d is a cone (r %.1f → %.1f over %.0f mm): a revolve" % (len(run), rr[0], rr[-1], span))
            continue
        # Ends that meet the body run on into it; a free end gets back the
        # half bin the mean took off it.
        t0 = unit(spine[1] - spine[0])
        t1 = unit(spine[-1] - spine[-2])
        start = reach_body(spine[0], -t0, r, far, model_tree, step)
        end = reach_body(spine[-1], t1, r, far, model_tree, step)
        spine = np.vstack([start, spine, end])
        simplified = douglas_peucker_3d(spine, max(tol * 0.5, 0.5))
        ellipse = a / max(b, 1e-6) > 1.25
        major = run[0]["major"]
        major = unit(major - (major @ t0) * t0)
        features.append({
            "kind": "sweep", "profile": ({"shape": "ellipse", "rx": round(a, 2), "ry": round(b, 2)} if ellipse
                                         else {"shape": "circle", "radius": round(r, 2)}),
            "xAxis": [round(float(v), 5) for v in major], "spine": [[round(float(v), 2) for v in p] for p in simplified],
            "lengthMM": round(span, 1), "radiusMM": round(r, 2),
        })
    if not features:
        say("tube: no run survived")
        return None
    # Coverage: distance of the piece's points to the tube surfaces.
    covered = np.zeros(len(comp.vertices), dtype=bool)
    verts = np.asarray(comp.vertices, dtype=float)
    for f in features:
        if f["kind"] == "revolve":
            covered |= revolve_covered(f, verts, tol)
            continue
        dense = resample_polyline(np.array(f["spine"]), 1.0)
        dtree = cKDTree(dense)
        dc, _ = dtree.query(verts)
        if f["profile"]["shape"] == "circle":
            r, slack = f["profile"]["radius"], 0.0
        else:
            r = (f["profile"]["rx"] + f["profile"]["ry"]) / 2
            slack = (f["profile"]["rx"] - f["profile"]["ry"]) / 2
        covered |= np.abs(dc - r) <= max(tol, 0.3 * r) + slack
    return {"kind": "sweep", "features": features, "covered": covered, "coverage": float(covered.mean())}


def reach_body(point, direction, r, far, model_tree, step):
    """The end of a tube carried on along its tangent until it is a radius
    inside the body (so the union fuses), up to 60 mm; a free end gets
    half a bin back for what the binning took off it."""
    d0, _ = model_tree.query(point)
    if d0 > 60.0 + r:
        return point + direction * (0.5 * step)
    p = np.array(point, dtype=float)
    travelled, last = 0.0, d0
    while travelled < 60.0:
        p = p + direction * 1.0
        travelled += 1.0
        d, _ = model_tree.query(p)
        if d < 1.0 or (d > last and last < 2.0):      # at the skin, or just through it
            return p + direction * (r + far)
        last = d
    return point + direction * (0.5 * step)


# ---- revolve ----------------------------------------------------------------

def revolve_covered(feature, verts, tol):
    c = np.array(feature["axis"]["origin"], dtype=float)
    d = unit(feature["axis"]["direction"])
    prof = np.array(feature["profile"], dtype=float)
    hv = (verts - c) @ d
    rv = np.linalg.norm((verts - c) - np.outer(hv, d), axis=1)
    r_at = np.interp(hv, prof[:, 1], prof[:, 0])
    return (np.abs(rv - r_at) <= np.maximum(tol, 0.1 * r_at)) & (hv >= prof[0, 1] - tol) & (hv <= prof[-1, 1] + tol)


def revolve_fit(comp, tol, far, model_tree):
    pts, _ = component_points(comp)
    if len(pts) < 80:
        return None
    c, d = fit_axis(pts)
    h = (pts - c) @ d
    perp = (pts - c) - np.outer(h, d)
    r = np.linalg.norm(perp, axis=1)
    extent = float(h.max() - h.min())
    if extent < 4.0:
        return None
    e1 = unit(np.cross(d, [0, 0, 1.0]) if abs(d[2]) < 0.9 else np.cross(d, [1.0, 0, 0]))
    e2 = np.cross(d, e1)
    band = max(2.0, extent / 30)
    edges = np.arange(h.min(), h.max() + band, band)
    round_bands, total, profile = 0, 0, []
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1])
        if sel.sum() < 12:
            continue
        total += 1
        xy = np.column_stack([perp[sel] @ e1, perp[sel] @ e2])
        cc, R, resid = fit_circle_2d(xy)
        # A thin shell (a horn) shows two radii; the outer one is the shape.
        outer = float(np.percentile(r[sel], 75))
        if np.linalg.norm(cc) <= max(2 * tol, 0.1 * outer) and resid <= max(2 * tol, 0.12 * outer):
            round_bands += 1
        profile.append([outer, float((edges[i] + edges[i + 1]) / 2)])
    if total < 3 or round_bands / float(total) < 0.6:
        return None
    # Which end meets the body: extend that end into it.
    lo_pt, hi_pt = c + d * h.min(), c + d * h.max()
    d_lo, _ = model_tree.query(lo_pt)
    d_hi, _ = model_tree.query(hi_pt)
    simplified = douglas_peucker_2d(profile, max(tol * 0.5, 0.5))
    if d_lo < far + 0.5 * profile[0][0]:
        simplified = [[simplified[0][0], simplified[0][1] - (far + 4.0)]] + simplified
    if d_hi < far + 0.5 * profile[-1][0]:
        simplified = simplified + [[simplified[-1][0], simplified[-1][1] + (far + 4.0)]]
    feature = {"kind": "revolve", "axis": {"origin": [round(float(v), 2) for v in c],
                                           "direction": [round(float(v), 5) for v in d]},
               "profile": [[round(float(rr), 2), round(float(hh), 2)] for rr, hh in simplified],
               "lengthMM": round(extent, 1), "radiusMM": round(float(np.median([p[0] for p in profile])), 2)}
    verts = np.asarray(comp.vertices, dtype=float)
    covered = revolve_covered(feature, verts, tol)
    return {"kind": "revolve", "features": [feature], "covered": covered, "coverage": float(covered.mean())}


# ---- extrude ----------------------------------------------------------------

def alpha_outline(xy, alpha):
    """The outer boundary of a point cloud in the plane: the edges that one
    Delaunay triangle of circumradius ≤ alpha owns and no other does, chained
    into loops; the longest loop is the outline."""
    xy = np.asarray(xy, dtype=float)
    if len(xy) < 4:
        return None
    try:
        tri = Delaunay(xy)
    except Exception:  # noqa: BLE001
        return None
    simplices = tri.simplices
    A, B, Cc = xy[simplices[:, 0]], xy[simplices[:, 1]], xy[simplices[:, 2]]
    a = np.linalg.norm(B - Cc, axis=1)
    b = np.linalg.norm(A - Cc, axis=1)
    c = np.linalg.norm(A - B, axis=1)
    s = (a + b + c) / 2
    area = np.sqrt(np.clip(s * (s - a) * (s - b) * (s - c), 0, None))
    with np.errstate(divide="ignore", invalid="ignore"):
        circ = np.where(area > 1e-9, a * b * c / (4 * area), np.inf)
    keep = simplices[circ <= alpha]
    if len(keep) == 0:
        return None
    edges = {}
    for t in keep:
        for i, j in ((0, 1), (1, 2), (2, 0)):
            e = (min(t[i], t[j]), max(t[i], t[j]))
            edges[e] = edges.get(e, 0) + 1
    boundary = [e for e, n in edges.items() if n == 1]
    if len(boundary) < 3:
        return None
    adj = {}
    for i, j in boundary:
        adj.setdefault(i, []).append(j)
        adj.setdefault(j, []).append(i)
    seen = set()
    loops = []
    for start in adj:
        if start in seen:
            continue
        loop = [start]
        seen.add(start)
        prev, cur = None, start
        while True:
            nxt = [k for k in adj[cur] if k != prev and k not in seen]
            if not nxt:
                break
            prev, cur = cur, nxt[0]
            loop.append(cur)
            seen.add(cur)
        loops.append(loop)
    best = max(loops, key=lambda L: sum(np.linalg.norm(xy[L[(k + 1) % len(L)]] - xy[L[k]]) for k in range(len(L))))
    if len(best) < 3:
        return None
    return xy[best]


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


def extrude_fit(comp, tol, far, model_tree):
    pts, _ = component_points(comp)
    if len(pts) < 60:
        return None
    centre = pts.mean(axis=0)
    _, _, vt = np.linalg.svd(pts - centre, full_matrices=False)
    e1, e2, e3 = vt
    if np.dot(np.cross(e1, e2), e3) < 0:
        e2 = -e2
    p = np.column_stack([(pts - centre) @ e1, (pts - centre) @ e2, (pts - centre) @ e3])
    z_lo, z_hi = np.percentile(p[:, 2], 3), np.percentile(p[:, 2], 97)
    t = float(z_hi - z_lo)
    if t < 1.0:
        t = 1.0
    z_mid = float((z_lo + z_hi) / 2)
    xy = p[:, :2]
    nn, _ = cKDTree(xy).query(xy, k=2)
    spacing = float(np.median(nn[:, 1]))
    alpha = max(3.0 * spacing, 1.5, 0.6 * t)
    loop = alpha_outline(xy, alpha)
    if loop is None or len(loop) < 3:
        return None
    loop = np.array(douglas_peucker_2d(np.vstack([loop, loop[:1]]), max(tol * 0.5, 0.4))[:-1])
    if len(loop) < 3:
        return None
    area = 0.5 * abs(float(np.dot(loop[:, 0], np.roll(loop[:, 1], -1)) - np.dot(loop[:, 1], np.roll(loop[:, 0], -1))))
    if area < 4.0:
        return None
    segments = segments_from_loop(loop, tol=max(tol * 0.5, 0.3), max_radius=float(np.ptp(xy, axis=0).max()))
    if len(segments) < 3:
        segments = [{"kind": "line", "a": loop[i].tolist(), "b": loop[(i + 1) % len(loop)].tolist()} for i in range(len(loop))]
    origin = centre + e3 * z_mid
    # A plate that meets the body on one face runs on into it.
    face_lo = origin - e3 * (t / 2)
    face_hi = origin + e3 * (t / 2)
    d_lo, _ = model_tree.query(face_lo)
    d_hi, _ = model_tree.query(face_hi)
    grow_lo = (far + 3.0) if d_lo < far + 2.0 else 0.0
    grow_hi = (far + 3.0) if d_hi < far + 2.0 else 0.0
    origin = origin + e3 * ((grow_hi - grow_lo) / 2)
    thickness = t + grow_lo + grow_hi
    feature = {"kind": "extrude",
               "plane": {"origin": [round(float(v), 2) for v in origin], "xAxis": [round(float(v), 5) for v in e1],
                         "yAxis": [round(float(v), 5) for v in e2]},
               "segments": segments, "distance": round(thickness / 2, 2), "symmetric": True,
               "thicknessMM": round(t, 2), "areaMM2": round(area, 1)}
    verts = np.asarray(comp.vertices, dtype=float)
    pv = np.column_stack([(verts - centre) @ e1, (verts - centre) @ e2, (verts - centre) @ e3])
    # Covered means within tolerance of the SLAB'S SURFACE — a face or the
    # outline's edge — not merely inside it: a wire arch sits inside an
    # 8 mm slab shaped like itself without touching its faces.
    dz = np.abs(pv[:, 2] - z_mid)
    in_slab = dz <= t / 2 + tol
    near_face = np.abs(dz - t / 2) <= tol
    loop_tree = cKDTree(np.vstack([loop, resample_closed(loop, 1.0)]))
    d_edge, _ = loop_tree.query(pv[:, :2])
    inside = np.array([point_in_polygon(q, loop) for q in pv[:, :2]])
    covered = in_slab & ((inside & near_face) | (d_edge <= tol))
    return {"kind": "extrude", "features": [feature], "covered": covered, "coverage": float(covered.mean())}


def resample_closed(loop, step):
    loop = np.asarray(loop, dtype=float)
    closed = np.vstack([loop, loop[:1]])
    seg = np.linalg.norm(np.diff(closed, axis=0), axis=1)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    if s[-1] < step:
        return loop
    targets = np.arange(0.0, s[-1], step)
    return np.column_stack([np.interp(targets, s, closed[:, k]) for k in range(2)])


# ---- choosing ---------------------------------------------------------------

def explain(comp, tol, far, model_tree, depth, out_features, unexplained, budget, label):
    """Try the three fits on a piece, keep the best, recurse on the rest."""
    if budget[0] <= 0:
        unexplained.append(describe(comp, "feature budget spent"))
        return
    candidates = []
    for name, fn in (("sweep", tube_fit), ("revolve", revolve_fit), ("extrude", extrude_fit)):
        try:
            res = fn(comp, tol, far, model_tree)
        except Exception as error:  # noqa: BLE001 — one fit's failure is not the piece's
            print("   %s: %s fit failed: %s" % (label, name, str(error)[:120]), flush=True)
            res = None
        if res:
            candidates.append(res)
            print("   %s: %s covers %.0f%% (%d feature%s)" % (label, name, res["coverage"] * 100, len(res["features"]),
                                                             "" if len(res["features"]) == 1 else "s"), flush=True)
    if not candidates:
        unexplained.append(describe(comp, "no fit"))
        return
    # A sweep that covers as much as a block is the better story (a handle
    # is a tube, not a slab); a revolve likewise over a block.
    def score(c):
        bonus = {"sweep": 0.08, "revolve": 0.05, "extrude": 0.0}[c["kind"]]
        return c["coverage"] + bonus
    best = max(candidates, key=score)
    # A sweep's runs were each proved on their own points, so a hose and
    # its horn count even when the valve beside them is left over; a
    # revolve or a block is one fit for the whole piece and has to cover it.
    needed = 0.25 if best["kind"] == "sweep" else 0.5
    if best["coverage"] < needed:
        unexplained.append(describe(comp, "best fit (%s) covers only %.0f%%" % (best["kind"], best["coverage"] * 100)))
        return
    for f in best["features"]:
        f["name"] = "%s-%s" % (label, f["kind"])
        f["coverage"] = round(best["coverage"], 3)
        f["areaMM2"] = round(float(comp.area), 1)
        out_features.append(f)
        budget[0] -= 1
    # What the fit left: faces whose corners are all uncovered.
    uncovered = ~best["covered"]
    faces = np.asarray(comp.faces)
    left = np.flatnonzero(uncovered[faces].all(axis=1))
    if len(left) < 4 or depth >= 3:
        return
    sub = comp.submesh([left], append=True)
    comps = trimesh.graph.connected_components(sub.face_adjacency, nodes=np.arange(len(sub.faces)))
    rest = []
    for c in comps:
        c = np.asarray(c)
        if len(c) >= 4:
            m = sub.submesh([c], append=True)
            if m.area >= 0.08 * comp.area and m.area >= 150.0:
                rest.append(m)
    rest.sort(key=lambda m: -m.area)
    for k, m in enumerate(rest[:3]):
        explain(m, tol, far, model_tree, depth + 1, out_features, unexplained, budget, "%s.%d" % (label, k + 1))


def describe(comp, why):
    lo, hi = comp.bounds
    return {"why": why, "areaMM2": round(float(comp.area), 1), "centroid": [round(float(v), 1) for v in comp.centroid],
            "extentMM": [round(float(v), 1) for v in (hi - lo)]}


# ---- the sheet --------------------------------------------------------------

def review_sheet(path, pieces, features, bounds):
    from PIL import Image, ImageDraw
    lo, hi = bounds
    size = 700
    views = (("front", 0, 1), ("right", 2, 1), ("top", 0, 2))
    im = Image.new("RGB", (size * 3 + 40, size + 60), (28, 30, 34))
    d = ImageDraw.Draw(im)
    span = float((hi - lo).max())
    palette = [(255, 140, 60), (90, 180, 255), (120, 220, 120), (240, 220, 80), (220, 120, 220), (120, 220, 220),
               (255, 90, 90), (200, 200, 200)]

    def to_px(p, ax, ay, ox):
        x = ox + 20 + (p[ax] - lo[ax]) / span * (size - 40)
        y = 40 + (size - 40) - (p[ay] - lo[ay]) / span * (size - 40)
        return x, y

    for v, (name, ax, ay) in enumerate(views):
        ox = v * size + 20
        d.text((ox + 20, 10), name, fill=(220, 220, 220))
        for k, m in enumerate(pieces):
            col = palette[k % len(palette)]
            s, _ = sample(m, min(4000, max(400, int(m.area / 4))), seed=4)
            for p in s:
                x, y = to_px(p, ax, ay, ox)
                d.point((x, y), fill=col)
        for f in features:
            if f["kind"] == "sweep":
                pts = [to_px(np.array(p), ax, ay, ox) for p in f["spine"]]
                d.line(pts, fill=(255, 255, 255), width=3)
            elif f["kind"] == "revolve":
                o, dd = np.array(f["axis"]["origin"]), np.array(f["axis"]["direction"])
                prof = f["profile"]
                a, b = o + dd * prof[0][1], o + dd * prof[-1][1]
                d.line([to_px(a, ax, ay, ox), to_px(b, ax, ay, ox)], fill=(255, 255, 255), width=3)
            elif f["kind"] == "extrude":
                pl = f["plane"]
                o, xa, ya = np.array(pl["origin"]), np.array(pl["xAxis"]), np.array(pl["yAxis"])
                pts = []
                for seg in f["segments"]:
                    q = seg["a"]
                    pts.append(to_px(o + xa * q[0] + ya * q[1], ax, ay, ox))
                if len(pts) >= 2:
                    d.line(pts + pts[:1], fill=(255, 255, 255), width=2)
    d.text((20, size + 40), "residual pieces (one colour each) with the fitted spines, axes and outlines in white",
           fill=(200, 200, 200))
    im.save(path)


# ---- main -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--analysis", default=None, help="profile.json (for the body's axis; optional)")
    ap.add_argument("--tolerance", type=float, default=2.0)
    ap.add_argument("--far", type=float, default=None, help="mm; a scan triangle farther than this is unexplained (default 2.5× the tolerance, ≥ 4)")
    ap.add_argument("--min-area", type=float, default=None, help="mm²; smaller pieces are ignored (default 0.4%% of the scan)")
    ap.add_argument("--max-features", type=int, default=8)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    scan = trimesh.load(args.scan, force="mesh")
    model = trimesh.load(args.model, force="mesh")
    tol = args.tolerance
    far = args.far or max(4.0, 2.5 * tol)
    min_area = args.min_area or max(150.0, 0.004 * float(scan.area))
    print("scan %d faces, model %d faces; far = %.1f mm, pieces ≥ %.0f mm²" % (len(scan.faces), len(model.faces), far, min_area), flush=True)
    model_tree = surface_tree(model)
    pieces, d = far_components(scan, model_tree, far, min_area)
    far_share = float((d > far).mean())
    print("%.1f%% of the scan's vertices are farther than %.1f mm from the model: %d piece%s" % (
        far_share * 100, far, len(pieces), "" if len(pieces) == 1 else "s"), flush=True)
    features, unexplained = [], []
    budget = [args.max_features]
    for k, comp in enumerate(pieces):
        label = "piece%d" % (k + 1)
        lo, hi = comp.bounds
        print("== %s: area %.0f mm², extent %s" % (label, comp.area, np.round(hi - lo, 0).tolist()), flush=True)
        # A sheet lying just beyond `far` all over (a wall thickness a few mm
        # off) is not a feature: the piece has to stand well proud somewhere.
        dv, _ = model_tree.query(np.asarray(comp.vertices, dtype=float))
        proud = float(np.percentile(dv, 95))
        if proud < max(2.0 * far, 12.0) or comp.area > 25.0 * proud * proud:
            unexplained.append(describe(comp, "a sheet %.0f–%.0f mm off the model over %.0f mm², not a feature" % (
                np.percentile(dv, 5), proud, comp.area)))
            print("   a sheet %.0f–%.0f mm off the model over %.0f mm² — the body's own surface, not a feature" % (
                np.percentile(dv, 5), proud, comp.area), flush=True)
            continue
        explain(comp, tol, far, model_tree, 0, features, unexplained, budget, label)
    result = {"scan": os.path.abspath(args.scan), "model": os.path.abspath(args.model), "toleranceMM": tol, "farMM": far,
              "farShare": round(far_share, 4), "pieces": len(pieces), "features": features, "unexplained": unexplained}
    with open(os.path.join(args.out, "features.json"), "w") as f:
        json.dump(result, f, indent=1)
    try:
        review_sheet(os.path.join(args.out, "review.png"), pieces, features, scan.bounds)
    except Exception as error:  # noqa: BLE001
        print("review sheet failed:", error, flush=True)
    print("features: %d (%s); unexplained: %d" % (
        len(features), ", ".join("%s %s" % (f["name"], f["kind"]) for f in features), len(unexplained)), flush=True)


if __name__ == "__main__":
    main()
