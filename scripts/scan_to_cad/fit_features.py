#!/usr/bin/env python3
"""What the revolve missed, and what to build for it.

    python3 fit_features.py --scan run/scan.stl --model run/part-cad.stl --analysis analysis/profile.json \
        --tolerance 2 --out features/

A turned body explains a can or a bollard outright; a pail has a handle, a
mug a handle and a lid lever, an extinguisher a hose, a horn and a grip. This
reads the scan against the model already built, keeps every scan triangle
that lies farther than a few tolerances from it, splits those into connected
pieces, and tries the four things a CAD feature can be on each piece:

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
    bar       a straight bar, or a frame of them — a post, a beam, an angle
              or channel, a stand welded from two: the directions along
              which the piece is long, each bar's section read as the cells
              of the plane across it that its points run the length of,
              extruded that length (`bar_fit`; built as an extrude)

    hoop      a ring round the MAIN body's axis (`--analysis` gives it) — a
              barrel's hoop, a rolled rim, a bead: a height band in which
              the piece runs round the axis at one radius, revolved on
              that axis with its own annular section (`hoop_fit`; built
              as a revolve)

    bent bar  a flat bar that leaves the body, bends and runs on — a
              squeeze lever, a strap, a bracket: its centreline traced as
              a tube's, a spine of two or three straight legs fitted to
              it (`corner_spine`), one designed section from the parts
              library read across its longest leg, the bends rounded to
              the radius the points ask for, built as ONE sweep of that
              section along the polyline (`bent_bar_fit`; `tube_fit`
              reads a flat run of a chain the same way)

Each candidate is scored by the share of the piece's points it covers within
tolerance; the best one wins, what it leaves uncovered is split again and
tried again (a hose with a horn on its end is a sweep and then a revolve).
Pieces nothing explains are listed as `unexplained`, with where they are.

The parts library: a plate's or a bar's outline is matched against the
shapes real parts are designed with — a circle, a stadium (a lever), a
rectangle with rounded corners (a flange), a hexagon or an octagon (a
nut), an oval — and the designed shape is taken whenever it explains the
piece as well as the free-form outline does (`regularise_outline`); a
tube is ONE sweep along ONE spine at one radius, with its horn a cone on
the end; a bent bar is one section swept along its legs. Each feature
carries a `shape` (what it is, with its sizes) — a bent bar a `section`
— and a `part` (lever, handle, hose, horn, grip, nut, flange, hoop,
knob, bar, plate, lug) for the captions.

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

# A bar has to explain this much scan (mm²) to be worth a feature: `main`
# sets it from the scan's area (a quarter of a percent, 400 mm² at least).
# A chain's links and a rod's mounting bracket each read as a handful of
# little prisms, every one "100 % on it" — and spent the hydrant's budget
# ahead of its lugs.
BAR_MIN_AREA = 400.0

# The smallest residual piece worth a feature (mm²); `main` sets it from
# the scan's area (0.4 %, 150 at least).
MIN_PIECE_AREA = 150.0


def say(*parts):
    if DEBUG:
        print("      ", *parts, flush=True)


def chord_radius(comp, pts, nrm, label="tube"):
    """Half the piece's thickness: a ray from each point into the piece
    meets the far wall a chord away; the median chord is a tube's diameter
    (a flat bar's thickness, mostly — its wide faces outnumber its edges).
    None when too few rays hit."""
    origins = pts - nrm * 0.2
    try:
        loc, idx_ray, _ = comp.ray.intersects_location(origins, -nrm, multiple_hits=False)
    except Exception:  # noqa: BLE001
        return None
    if len(idx_ray) < 20:
        say("%s: only %d inward rays hit" % (label, len(idx_ray)))
        return None
    chords = np.linalg.norm(np.asarray(loc) - origins[idx_ray], axis=1)
    chords = chords[(chords > 0.5) & (chords < 400)]
    if len(chords) < 20:
        say("%s: only %d chords" % (label, len(chords)))
        return None
    r0 = float(np.median(chords)) / 2
    say("%s: %d of %d rays hit, chord median %.1f mm -> r0 %.1f" % (label, len(chords), len(pts), 2 * r0, r0))
    return r0


def clear_of_body(pts, nrm, r0, far, model_tree, label="tube"):
    """Only the points well clear of the body: a handle's arch, a hose's
    run. The lugs a wire hooks into and the rim they sit on lie within a
    few tolerances of the model and would tangle the geodesic; the ends
    are carried back into the body afterwards. (pts, nrm) or None."""
    d_body, _ = model_tree.query(pts, workers=-1)
    clear = d_body > max(3.0 * far, 2.0 * r0)
    if clear.sum() < 60:
        say("%s: only %d of %d points stand clear of the body" % (label, int(clear.sum()), len(pts)))
        return None
    say("%s: %d of %d points stand clear of the body" % (label, int(clear.sum()), len(pts)))
    return pts[clear], nrm[clear]


def tube_fit(comp, tol, far, model_tree):
    pts, nrm = component_points(comp)
    n = len(pts)
    if n < 60:
        say("tube: only", n, "points")
        return None
    r0 = chord_radius(comp, pts, nrm)
    if r0 is None or r0 < 1.0:
        return None
    kept = clear_of_body(pts, nrm, r0, far, model_tree)
    if kept is None:
        return None
    pts, nrm = kept
    traced = trace_centreline(pts, r0)
    if traced is None:
        return None
    if traced["length"] < 3.0 * r0:
        return None
    C, bin_members, step, tree = traced["C"], traced["members"], traced["step"], traced["tree"]
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
    return tube_runs(comp, pts, rows_out, r0, tol, far, model_tree, step)


def trace_centreline(pts, r0, label="tube"):
    """The centreline of a piece's points: the longest geodesic on a
    nearest-neighbour graph gives the ends, the points binned by geodesic
    distance from one end, a tube's width per bin, give a sample per bin
    — every bin holds a whole cross-section (or a slice of one) and its
    mean sits on the axis, and the order is the distance itself, which
    cannot double back the way a path traced round the skin does. Returns
    {C (n, 3), members (the point indices per sample), step, length, tree}
    or None."""
    n = len(pts)
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
    say("%s: geodesic %.0f mm over %d path points" % (label, length, len(path)))
    if len(path) < 4:
        return None
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
    if len(C) < 3:
        return None
    return {"C": C, "members": bin_members, "step": step, "length": length, "tree": tree, "reach": reach}


def tube_runs(comp, pts, rows_out, r0, tol, far, model_tree, step):
    """`tube_fit`'s second half: the centreline samples split into runs,
    each judged a tube, a cone, a flat bar or nothing, the chain picked
    and its features written."""
    say("tube: %d centreline samples, radii %s" % (sum(x is not None for x in rows_out),
                                                       " ".join("%.1f" % x["r"] if x else "-" for x in rows_out)))
    if sum(x is not None for x in rows_out) < 3:
        return None
    # One spine per piece. The samples split into runs where the radius
    # steps by more than two tolerances (a hose into its horn; the valve
    # body the geodesic walked through); neighbouring runs whose radii
    # agree to that are one run at one radius (a stein's handle, thick
    # above and thinner below, is one tube, not two with a step between).
    # A run whose radius grows steadily is a cone — a horn — and becomes
    # a revolve on the line that continues the spine; the longest tube and
    # the runs that follow it along the spine are the piece's story: ONE
    # sweep with one radius, or a short chain meeting end to end where
    # the radius really steps, with the horn on its end. Whatever else the
    # spine crossed — a lever, a valve — is left for the next pass to
    # explain as what it is. (Three overlapping sweeps once stood in for a
    # CO₂ extinguisher's grip, hose and horn.)
    def step_r(r):
        return max(2.0 * tol, 0.35 * r)

    def radius_of(run):
        return float(np.median([x["r"] for x in run]))

    def cone_run(run, r, tol):
        """The run (or the run less up to three end samples) when its radius
        grows steadily — trend over 0.85 and a spread of more than half its
        median radius — else None. The shortest trim that passes wins, and
        the trimmed run keeps at least four samples and 70 % of the run."""
        n = len(run)
        for cut in range(0, 4):
            for head in range(0, cut + 1):
                tail = cut - head
                sub = run[head:n - tail]
                if len(sub) < max(4, int(math.ceil(0.7 * n))):
                    continue
                rr = np.array([x["r"] for x in sub])
                if rr.std() <= 1e-9:
                    continue
                trend = float(np.corrcoef(np.arange(len(rr)), rr)[0, 1])
                spread = float(rr.max() - rr.min())
                if cut == 0:
                    say("tube: run of %d: r %.1f, radii %.1f → %.1f (spread %.1f), trend %.2f" % (n, r, rr[0], rr[-1], spread, trend))
                if abs(trend) > 0.85 and spread > 0.5 * float(np.median(rr)):
                    if cut:
                        say("tube: run of %d less %d at the start and %d at the end is a cone (trend %.2f)" % (n, head, tail, trend))
                    return sub
        return None
    runs, run = [], []
    for x in rows_out:
        if x is None:
            if run:
                runs.append(run)
            run = []
            continue
        if run and abs(x["r"] - radius_of(run)) > step_r(radius_of(run)):
            runs.append(run)
            run = []
        run.append(x)
    if run:
        runs.append(run)
    merged = []
    for run in runs:
        if merged and run[0]["i"] - merged[-1][-1]["i"] <= 6 and abs(radius_of(run) - radius_of(merged[-1])) <= step_r(max(radius_of(run), radius_of(merged[-1]))):
            merged[-1] = merged[-1] + run
            continue
        merged.append(run)
    runs = merged
    # Each run judged on its own: a cone, a tube, or neither.
    judged = []
    for run in runs:
        r = radius_of(run)
        rr = np.array([x["r"] for x in run])
        spine = np.array([x["c"] for x in run])
        span = float(np.sum(np.linalg.norm(np.diff(spine, axis=0), axis=1))) if len(run) > 1 else 0.0
        verdict = {"run": run, "r": r, "spine": spine, "span": span, "kind": None}
        judged.append(verdict)
        if len(run) < 3 or r < 1.0 or span < max(4.0 * r, 15.0):
            say("tube: run of %d dropped (r %.1f, span %.0f)" % (len(run), r, span))
            continue
        # A section nearly twice as wide as it is thick is a flat bar, not
        # a tube — a squeeze lever, a strap: a bar of a designed section
        # (a rounded rectangle, a stadium) along a spine of one, two or
        # three straight legs (`bar_along`), proved on the run's own
        # points. A strap along a curve (a hanging chain) has no such
        # spine and stays the oval tube it was; a skin thinner than one
        # and a half tolerances is no bar at all.
        a_run = float(np.median([x["a"] for x in run]))
        b_run = float(np.median([x["b"] for x in run]))
        if a_run >= FLAT_RATIO * b_run and 2.0 * b_run < max(1.5 * tol, 3.0):
            # An oval thinner than one and a half tolerances is a torn
            # skin, not a tube (the app refused a 17.8 × 4.2 mm one on the
            # CO₂ extinguisher's horn; a 15 × 1 mm one followed it).
            say("tube: run of %d dropped: a %.0f × %.1f mm oval is a skin, not a tube" % (len(run), 2 * a_run, 2 * b_run))
            continue
        if a_run >= FLAT_RATIO * b_run and 2.0 * r0 >= max(1.5 * tol, 3.0):
            members = np.unique(np.concatenate([x["members"] for x in run]))
            bar = bar_along(pts[members], spine, tol, 2.0 * a_run, step)
            # The section read at the leg's middle has to be the flat one
            # the run measured: a disc there means the run's spread came
            # from a skin's edge, not a bar (the horn's torn sliver).
            if bar is not None and bar["widthMM"] < 1.4 * bar["thicknessMM"]:
                say("tube: run of %d measured flat (%.0f × %.0f) but its section reads %s — not a bar" % (
                    len(run), 2 * a_run, 2 * b_run, bar_words(bar)))
                bar = None
            if bar is not None and bar["coverage"] >= 0.5:
                say("tube: run of %d is a flat bar (%.0f × %.0f): %s, covers %.0f%% of its own points" % (
                    len(run), 2 * a_run, 2 * b_run, bar_words(bar), bar["coverage"] * 100))
                verdict["kind"], verdict["bar"] = "flat", bar
                continue
            if bar is not None:
                say("tube: run of %d: a flat section (%.0f × %.0f) but the bar covers only %.0f%% of its points" % (
                    len(run), 2 * a_run, 2 * b_run, bar["coverage"] * 100))
        # The run's own points against its own tube: a lever or a valve body
        # the geodesic walked through is no tube, whatever its bins' medians.
        own = np.concatenate([np.abs(x["rho"] - x["r"]) <= max(tol, 0.3 * x["r"]) for x in run])
        # Half its points on the tube: a corrugated hose's bins carry the
        # valve's and the horn's neighbours and read 53–57 %.
        if float(own.mean()) < 0.5:
            say("tube: run of %d dropped (r %.1f): only %.0f%% of its own points on the tube" % (len(run), r, own.mean() * 100))
            continue
        # A radius that grows steadily along the run is a cone — a horn, a
        # nozzle: a revolve about the run's own line, not a tube. The
        # geodesic can overshoot the horn's mouth and walk a sample or
        # two down its rim (15.5 → 32.7 → 17.7 on the CO₂ extinguisher's
        # horn against the app's model, trend 0.63; the same horn against
        # the offline model stopped at 33 and read 0.98), so the trend is
        # judged on the run with up to three end samples trimmed, and a
        # cone is the trimmed run.
        cone = cone_run(run, r, tol)
        if cone is not None:
            verdict["run"], verdict["kind"] = cone, "cone"
            verdict["r"] = radius_of(cone)
            verdict["spine"] = np.array([x["c"] for x in cone])
            verdict["span"] = float(np.sum(np.linalg.norm(np.diff(verdict["spine"], axis=0), axis=1)))
            continue
        # A steady run three times fatter than the chords measured is not
        # the tube they measured: a stand's post and beam, walked through
        # by the geodesic, gave a 42 mm "tube" on a piece whose chords
        # said 7 (the app refused the sweep; the bars are the story). Only
        # when the chords measured something — a thin shell's chords are
        # a millimetre whatever the tube.
        if r0 >= 2.0 * tol and r > 3.0 * r0:
            say("tube: run of %d dropped (r %.1f): three times the chord radius %.1f" % (len(run), r, r0))
            continue
        verdict["kind"] = "tube"
    tubes = [k for k, v in enumerate(judged) if v["kind"] in ("tube", "flat")]
    if not tubes:
        say("tube: no run survived")
        return None
    # The chain: the longest tube, and the tubes and cones that follow it
    # along the spine within six bins (a short run of junk between two
    # tubes — a lug the handle passes — is stepped over).
    main_k = max(tubes, key=lambda k: judged[k]["span"])
    chain = [main_k]
    for direction in (-1, 1):
        k = main_k
        while True:
            nxt = k + direction
            while 0 <= nxt < len(judged) and judged[nxt]["kind"] is None and len(judged[nxt]["run"]) <= 3:
                nxt += direction
            if not (0 <= nxt < len(judged)) or judged[nxt]["kind"] is None:
                break
            a, b = (judged[k], judged[nxt]) if direction > 0 else (judged[nxt], judged[k])
            if b["run"][0]["i"] - a["run"][-1]["i"] > 6:
                break
            chain.append(nxt)
            if judged[nxt]["kind"] == "cone":
                break
            k = nxt
    chain.sort()
    features = []
    for pos, k in enumerate(chain):
        v = judged[k]
        run, r, spine, span = v["run"], v["r"], v["spine"], v["span"]
        rr = np.array([x["r"] for x in run])
        if v["kind"] == "cone":
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
            # The end that meets the hose (or the body) runs on into it.
            if d_lo < far + r or pos > 0:
                prof = [[prof[0][0], prof[0][1] - (far + 4.0)]] + prof
            if d_hi < far + r or pos < len(chain) - 1:
                prof = prof + [[prof[-1][0], prof[-1][1] + (far + 4.0)]]
            features.append({"kind": "revolve", "axis": {"origin": [round(float(q), 2) for q in c0],
                                                         "direction": [round(float(q), 5) for q in d]},
                             "profile": [[round(float(q), 2), round(float(hh), 2)] for q, hh in prof],
                             "lengthMM": round(span, 1), "radiusMM": round(r, 2), "cone": True})
            say("tube: run of %d is a cone (r %.1f → %.1f over %.0f mm): a revolve" % (len(run), rr[0], rr[-1], span))
            continue
        a = float(np.median([x["a"] for x in run]))
        b = float(np.median([x["b"] for x in run]))
        # A flat bar: its spine is the bar's own legs, its reach into the
        # body or the next run half its thickness.
        if v["kind"] == "flat":
            spine = np.asarray(v["bar"]["points"], dtype=float)
            r = 0.5 * v["bar"]["thicknessMM"]
        # Ends: a free end meets the body (`reach_body`) or gets back the
        # half bin the mean took off it; an end that meets the next run of
        # the chain reaches into it by a radius so the union fuses.
        t0 = unit(spine[1] - spine[0])
        t1 = unit(spine[-1] - spine[-2])
        attached = [False, False]
        free_end = bar_end if v["kind"] == "flat" else (lambda p, d, rr, fa, mt, st, _tol: reach_body(p, d, rr, fa, mt, st))
        if pos > 0:
            prev = judged[chain[pos - 1]]["spine"]
            start = spine[0] + unit(prev[-1] - spine[0]) * min(r, float(np.linalg.norm(prev[-1] - spine[0])))
        else:
            start, attached[0] = free_end(spine[0], -t0, r, far, model_tree, step, tol)
        if pos < len(chain) - 1:
            nxt = judged[chain[pos + 1]]["spine"]
            end = spine[-1] + unit(nxt[0] - spine[-1]) * min(r, float(np.linalg.norm(nxt[0] - spine[-1])))
        else:
            end, attached[1] = free_end(spine[-1], t1, r, far, model_tree, step, tol)
        if v["kind"] == "flat":
            f = bar_feature(v["bar"], start, end, attached,
                            joins=[pos > 0, pos < len(chain) - 1],
                            into_horn=pos < len(chain) - 1 and judged[chain[pos + 1]]["kind"] == "cone")
            features.append(f)
            say("tube: run of %d is %s" % (len(run), bar_words(v["bar"])))
            continue
        spine = np.vstack([start, spine, end])
        simplified = douglas_peucker_3d(spine, max(tol * 0.5, 0.5))
        ellipse = a / max(b, 1e-6) > 1.25
        major = run[0]["major"]
        major = unit(major - (major @ t0) * t0)
        features.append({
            "kind": "sweep", "profile": ({"shape": "ellipse", "rx": round(a, 2), "ry": round(b, 2)} if ellipse
                                         else {"shape": "circle", "radius": round(r, 2)}),
            "xAxis": [round(float(q), 5) for q in major], "spine": [[round(float(q), 2) for q in p] for p in simplified],
            "lengthMM": round(span, 1), "radiusMM": round(r, 2), "attached": attached,
            # Which ends run on into another run of the chain, and whether
            # the one after is a horn (a hose ends in one).
            "joins": [pos > 0, pos < len(chain) - 1],
            "intoHorn": pos < len(chain) - 1 and judged[chain[pos + 1]]["kind"] == "cone",
        })
    say("tube: the chain is %s (of %d runs)" % (" + ".join("%s r %.1f over %.0f mm" % (judged[k]["kind"], judged[k]["r"], judged[k]["span"]) for k in chain), len(judged)))
    if not any(f["kind"] == "sweep" for f in features):
        say("tube: no run survived")
        return None
    # Coverage: distance of the piece's points to the tube surfaces.
    covered = np.zeros(len(comp.vertices), dtype=bool)
    verts = np.asarray(comp.vertices, dtype=float)
    for f in features:
        if f["kind"] == "revolve":
            covered |= revolve_covered(f, verts, tol)
            continue
        # A flat bar's leftovers are judged at two tolerances: what a
        # constant section leaves of a tapered lever is the lever's own
        # skin, not a part to pile on it (a tube's rule — 30 % of its
        # radius — says the same for a hose). The bar's own fit was
        # proved at one.
        covered |= sweep_covered(f, verts, 2.0 * tol if f.get("section") else tol)
    return {"kind": "sweep", "features": features, "covered": covered, "coverage": float(covered.mean())}


def sweep_covered(f, verts, tol):
    """The vertices within tolerance of a sweep: of the tube's skin
    (within max(tol, 30 %) of the radius from the spine, an oval's
    difference of semi-axes as slack), or of a flat bar's prism, leg by
    leg (`bar_sweep_covered`)."""
    if f.get("section"):
        return bar_sweep_covered(f, verts, tol)
    dense = resample_polyline(np.array(f["spine"]), 1.0)
    dtree = cKDTree(dense)
    dc, _ = dtree.query(verts)
    if f["profile"]["shape"] == "circle":
        r, slack = f["profile"]["radius"], 0.0
    else:
        r = (f["profile"]["rx"] + f["profile"]["ry"]) / 2
        slack = (f["profile"]["rx"] - f["profile"]["ry"]) / 2
    return np.abs(dc - r) <= max(tol, 0.3 * r) + slack


# ---- bent bars and levers ---------------------------------------------------
#
# A squeeze lever, a strap, an angle bracket: a flat bar that leaves the
# body, bends, and runs on. Its spine is one, two or three straight legs
# (`corner_spine`), its section one designed outline from the parts
# library measured across its longest leg (`bar_along`), and it is built
# as ONE sweep of that section along the polyline — the app's
# `feature.sweep` takes any closed sketch region and a world polyline.
# `preview_model.sweep_section` mitres the corners the same way.

# A section this many times wider than thick is a bar, not a tube (a
# stein's handle at 1.6 is still an oval tube; a lever reads 2.3).
FLAT_RATIO = 1.8
# A bend under this is a slight curve, not a corner.
MIN_BEND_DEG = 15.0


def _line_fit(S):
    """(centre, unit direction oriented from the first sample to the last,
    sum of squared orthogonal distances)."""
    S = np.asarray(S, dtype=float)
    c = S.mean(axis=0)
    if len(S) < 2:
        return c, np.array([1.0, 0, 0]), 0.0
    _, s, vt = np.linalg.svd(S - c, full_matrices=False)
    d = unit(vt[0])
    if d @ (S[-1] - S[0]) < 0:
        d = -d
    sse = float(np.sum(s[1:] ** 2))
    return c, d, sse


def _closest_point_of_lines(c1, d1, c2, d2):
    """The midpoint of the closest approach of two lines (their
    intersection when they meet)."""
    w = c1 - c2
    a, b, c = float(d1 @ d1), float(d1 @ d2), float(d2 @ d2)
    d, e = float(d1 @ w), float(d2 @ w)
    den = a * c - b * b
    if abs(den) < 1e-9:
        return (c1 + c2) / 2
    s = (b * e - c * d) / den
    t = (a * e - b * d) / den
    return ((c1 + d1 * s) + (c2 + d2 * t)) / 2


def _dist_to_polyline(S, points):
    """Each sample's distance to the nearest segment of a polyline."""
    S = np.asarray(S, dtype=float)
    best = np.full(len(S), np.inf)
    for a, b in zip(points[:-1], points[1:]):
        ab = b - a
        L2 = float(ab @ ab)
        t = np.clip(((S - a) @ ab) / L2, 0.0, 1.0) if L2 > 1e-12 else np.zeros(len(S))
        best = np.minimum(best, np.linalg.norm(S - (a + np.outer(t, ab)), axis=1))
    return best


def corner_spine(C, tol, width):
    """A polyline of one, two or three straight legs through the ordered
    centreline samples `C`: the samples are split into runs along the
    spine, a line fitted to each, the split (or the two splits) chosen to
    minimise the orthogonal residual, and each leg then refitted on its
    samples clear of the corner (half a section's width: the bins round a
    corner mix both legs and pull the lines toward each other). The
    simplest spine that fits — the samples' RMS distance to it within
    max(tol, 15 % of the section's width) — wins; a corner counts only
    when it bends the spine by `MIN_BEND_DEG` or more, both of its legs
    are at least a section wide, and the residual is well under (three
    quarters of) that of one leg fewer, which did not fit. Returns
    {points (the ends and the corners),
    bendsDeg, residualMM, legs} or None when no such spine fits (a strap
    along a curve)."""
    C = np.asarray(C, dtype=float)
    n = len(C)
    if n < 3:
        return None
    allow = max(tol, 0.15 * width)
    min_leg = max(width, 2.0 * tol)

    def bend(d1, d2):
        return math.degrees(math.acos(max(-1.0, min(1.0, float(d1 @ d2)))))

    def spine_of(runs, refine):
        """The polyline through the runs' lines, or None when a corner is
        too slight or a leg too short."""
        lines = [_line_fit(run) for run in runs]
        corners = [_closest_point_of_lines(lines[i][0], lines[i][1], lines[i + 1][0], lines[i + 1][1]) for i in range(len(runs) - 1)]
        if refine and corners:
            for _ in range(2):
                refit = []
                for i, run in enumerate(runs):
                    keep = np.ones(len(run), dtype=bool)
                    if i > 0:
                        keep &= np.linalg.norm(run - corners[i - 1], axis=1) > 0.5 * width
                    if i < len(runs) - 1:
                        keep &= np.linalg.norm(run - corners[i], axis=1) > 0.5 * width
                    refit.append(_line_fit(run[keep]) if keep.sum() >= 2 else lines[i])
                lines = refit
                corners = [_closest_point_of_lines(lines[i][0], lines[i][1], lines[i + 1][0], lines[i + 1][1]) for i in range(len(runs) - 1)]
        c0, d0, _ = lines[0]
        start = c0 + d0 * float(((runs[0] - c0) @ d0).min())
        cz, dz, _ = lines[-1]
        end = cz + dz * float(((runs[-1] - cz) @ dz).max())
        points = [start] + corners + [end]
        bends = [bend(lines[i][1], lines[i + 1][1]) for i in range(len(lines) - 1)]
        if bends and min(bends) < MIN_BEND_DEG:
            return None
        for i in range(len(points) - 1):
            leg = points[i + 1] - points[i]
            if np.linalg.norm(leg) < min_leg or leg @ lines[i][1] <= 0:
                return None
        return {"points": points, "bendsDeg": bends, "legs": len(runs),
                "residualMM": float(np.sqrt(np.mean(_dist_to_polyline(C, points) ** 2)))}

    one = spine_of([C], refine=False)
    if one is None:
        return None
    r1 = one["residualMM"]
    if r1 <= allow:
        return one
    # Two legs: the split with the least raw residual, then refined.
    best = None
    for k in range(2, n - 1):
        raw = _line_fit(C[:k])[2] + _line_fit(C[k:])[2]
        if best is None or raw < best[0]:
            if spine_of([C[:k], C[k:]], refine=False) is not None:
                best = (raw, k)
    two = spine_of([C[:best[1]], C[best[1]:]], refine=True) if best else None
    if two is not None and two["residualMM"] <= allow and two["residualMM"] <= 0.75 * r1:
        return two
    # Three legs: only when two do not fit (a Z, a U).
    best = None
    for k1 in range(2, n - 3):
        sse_a = _line_fit(C[:k1])[2]
        for k2 in range(k1 + 2, n - 1):
            raw = sse_a + _line_fit(C[k1:k2])[2] + _line_fit(C[k2:])[2]
            if best is None or raw < best[0]:
                if spine_of([C[:k1], C[k1:k2], C[k2:]], refine=False) is not None:
                    best = (raw, k1, k2)
    three = spine_of([C[:best[1]], C[best[1]:best[2]], C[best[2]:]], refine=True) if best else None
    r_prev = two["residualMM"] if two is not None else r1
    if three is not None and three["residualMM"] <= allow and three["residualMM"] <= 0.75 * r_prev:
        return three
    say("bar: no spine fits %d samples within %.1f mm: one leg %.1f, two %s, three %s" % (
        n, allow, r1, "%.1f (bend %.0f°)" % (two["residualMM"], two["bendsDeg"][0]) if two else "none",
        "%.1f" % three["residualMM"] if three else "none"))
    return None


def nearest_leg(P, points):
    """For each point, the index of the nearest leg of the polyline."""
    P = np.asarray(P, dtype=float)
    return np.argmin(np.column_stack([_dist_to_polyline(P, [a, b]) for a, b in zip(points[:-1], points[1:])]), axis=1)


def _leg_line(Q, a, d_old, width):
    """The line of a leg through the centres of slices of its points along
    `d_old`, a quarter of a section thick: each slice's centre is the
    middle of its points' lateral extent (the 2nd to 98th percentile
    across the leg), not their mean — a scan is denser on the face it
    saw best, and the mean of a bin leans to that face by a third of the
    section. A slice with fewer than eight points, or whose lateral
    spread is under 70 % of (or over 1.5 times) the slices' median — a
    partial ring where the geodesic's bins cut the end at a slant, a
    corner's wedge, a lump the bar hangs from — is left out. (centre,
    direction) or None when fewer than three slices are whole."""
    Q = np.asarray(Q, dtype=float)
    e1, e2 = plane_frame(d_old)
    rel = Q - a
    h = rel @ d_old
    lat = np.column_stack([rel @ e1, rel @ e2])
    bw = max(0.25 * width, 1.0)
    idx = np.floor((h - h.min()) / bw).astype(int)
    centres, spreads = [], []
    for k in range(int(idx.max()) + 1):
        m = idx == k
        if m.sum() < 8:
            continue
        lo, hi = np.percentile(lat[m], 2, axis=0), np.percentile(lat[m], 98, axis=0)
        mid = (lo + hi) / 2
        centres.append(a + d_old * float(h[m].mean()) + e1 * mid[0] + e2 * mid[1])
        spreads.append(float((hi - lo).max()))
    if len(centres) < 3:
        return None
    spreads = np.asarray(spreads)
    med = float(np.median(spreads))
    full = (spreads >= 0.7 * med) & (spreads <= 1.5 * med)
    if full.sum() < 3:
        return None
    c, d, _ = _line_fit(np.asarray(centres)[full])
    return c, d if d @ d_old > 0 else -d


def refine_legs(P, points, width):
    """The legs' lines refitted on the bar's own surface points — each
    point's nearest leg, clear of the corners by half a section (the
    centreline samples round a corner are the means of bins that hold
    both legs, and they lean a short leg by ten degrees) — as the line
    through the centres of slices across the leg (`_leg_line`), the
    corners where the refitted lines meet, the ends at the points'
    extremes along them. A leg with too few whole slices, or whose
    refitted line swings more than 20° from the sampled leg (a stub wider
    than it is long), keeps the sampled line; a refit that loses a corner
    or a leg is dropped for the polyline it started from."""
    P = np.asarray(P, dtype=float)
    points = [np.asarray(p, dtype=float) for p in points]
    for _ in range(2):
        legs = list(zip(points[:-1], points[1:]))
        nearest = nearest_leg(P, points)
        lines, ends = [], []
        for i, (a, b) in enumerate(legs):
            d_old = unit(b - a)
            L = float(np.linalg.norm(b - a))
            own = nearest == i
            h = (P - a) @ d_old
            sel = own.copy()
            if i > 0:
                sel &= h > 0.5 * width
            if i < len(legs) - 1:
                sel &= h < L - 0.5 * width
            c, d = a, d_old
            if sel.sum() >= 40:
                fit = _leg_line(P[sel], a, d_old, width)
                if fit is not None and fit[1] @ d_old >= math.cos(math.radians(20)):
                    c, d = fit
            lines.append((c, d))
            hh = (P[own] - c) @ d if own.any() else np.array([0.0, L])
            ends.append((c + d * float(hh.min()), c + d * float(hh.max())))
        corners = [_closest_point_of_lines(lines[i][0], lines[i][1], lines[i + 1][0], lines[i + 1][1]) for i in range(len(legs) - 1)]
        new = [ends[0][0]] + corners + [ends[-1][1]]
        ok = True
        for i in range(len(new) - 1):
            leg = new[i + 1] - new[i]
            if np.linalg.norm(leg) < width or leg @ lines[i][1] <= 0:
                ok = False
        for i in range(len(lines) - 1):
            if math.degrees(math.acos(max(-1.0, min(1.0, float(lines[i][1] @ lines[i + 1][1]))))) < MIN_BEND_DEG:
                ok = False
        if not ok:
            break
        points = new
    return points


def bar_end(point, direction, r, far, model_tree, step, tol):
    """A bar's end: into the body when `reach_body` finds it, else a
    tolerance past the last of its points (the ends come from the
    points' extremes, not from bin means, so there is no half bin to
    give back)."""
    p, attached = reach_body(point, direction, r, far, model_tree, step)
    if attached:
        return p, True
    return np.asarray(point, dtype=float) + unit(direction) * tol, False


def sweep_frames(spine, x_axis):
    """The section's frame on each leg of a polyline spine, carried round
    the corners by the same minimal rotation `preview_model.sweep_section`
    uses (and the app's sweep, to the rotation-minimising frame): a list
    of (start, end, direction, e1, e2) per leg, e1 × e2 = direction."""
    P = np.asarray(spine, dtype=float)
    keep = np.ones(len(P), dtype=bool)
    keep[1:] = np.linalg.norm(np.diff(P, axis=0), axis=1) > 1e-6
    P = P[keep]
    T = [unit(P[i + 1] - P[i]) for i in range(len(P) - 1)]
    X = np.asarray(x_axis, dtype=float)
    X = unit(X - (X @ T[0]) * T[0])
    frames = []
    for i, t in enumerate(T):
        if i > 0:
            X = unit(rotation_between(T[i - 1], t) @ X)
            X = unit(X - (X @ t) * t)
        frames.append((P[i], P[i + 1], t, X, np.cross(t, X)))
    return frames


def rotation_between(a, b):
    """The 3×3 rotation taking unit vector a onto unit vector b (the same
    as `preview_model.rotation_between`, kept here so the fitter has no
    preview dependency)."""
    a, b = unit(a), unit(b)
    v = np.cross(a, b)
    s = np.linalg.norm(v)
    c = float(a @ b)
    if s < 1e-12:
        if c > 0:
            return np.eye(3)
        axis = unit(np.cross(a, [1.0, 0, 0]) if abs(a[0]) < 0.9 else np.cross(a, [0, 1.0, 0]))
        K = np.array([[0, -axis[2], axis[1]], [axis[2], 0, -axis[0]], [-axis[1], axis[0], 0]])
        return np.eye(3) + 2 * K @ K
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K * ((1 - c) / (s * s))


def _legs_covered(P, frames, loop, tol):
    """Points within `tol` of the prism of `loop` along any leg."""
    covered = np.zeros(len(P), dtype=bool)
    for a, b, d, e1, e2 in frames:
        half = 0.5 * float(np.linalg.norm(b - a))
        covered |= prism_covered(P, (a + b) / 2, e1, e2, d, loop, half, tol)
    return covered


def bar_along(P, C, tol, width, step):
    """A flat bar through the points `P` whose centreline samples are `C`:
    the spine as legs (`corner_spine`, refitted on the points by
    `refine_legs`), the section as the designed outline
    (`regularise_outline` — a stadium, a rounded rectangle, a circle, an
    oval) that covers the most of the bar's points when swept along every
    leg, measured on the longest leg's TYPICAL slices (the slices of the
    leg's middle whose extent across it is within 15 % of the median — a
    lever tapers, and the hull of a whole leg is its fattest end) in the
    plane across it; then the bends' radius, the one of a few whose arcs
    cover the most of the bend's points (`fillet_spine`). Returns {points
    (the spine with the arcs drawn in), corners, bendRadiusMM, bendsDeg,
    legsMM, lengthMM, section {shape, segments, seed, widthMM,
    thicknessMM, cornerMM}, xAxis (the section's u axis at the spine's
    start), coverage, covered} or None."""
    P = np.asarray(P, dtype=float)
    spine = corner_spine(C, tol, width)
    if spine is None:
        say("bar: no spine of one, two or three legs fits the centreline")
        return None
    pts3 = refine_legs(P, spine["points"], width)
    legs = [(pts3[i], pts3[i + 1]) for i in range(len(pts3) - 1)]
    lengths = [float(np.linalg.norm(b - a)) for a, b in legs]
    bends = [math.degrees(math.acos(max(-1.0, min(1.0, float(unit(legs[i][1] - legs[i][0]) @ unit(legs[i + 1][1] - legs[i + 1][0]))))))
             for i in range(len(legs) - 1)]
    main = int(np.argmax(lengths))
    a0, b0 = legs[main]
    d = unit(b0 - a0)
    e1, e2 = plane_frame(d)
    # The leg's own points: nearest this leg and in its middle 70 %; the
    # section is read from the window a quarter section either side of
    # the leg's middle (a lever tapers — the CO₂ extinguisher's from 49 to
    # 42 mm over its long leg — and the hull of a whole leg is its
    # fattest end, tilted: a constant section read at the middle is the
    # same amount too wide at one end as too narrow at the other).
    nearest = nearest_leg(P, pts3)
    h = (P - a0) @ d
    mid = (nearest == main) & (h >= 0.15 * lengths[main]) & (h <= 0.85 * lengths[main])
    if mid.sum() < 40:
        say("bar: the longest leg's middle holds only %d points" % int(mid.sum()))
        return None
    window = mid & (np.abs(h - 0.5 * lengths[main]) <= max(0.25 * width, 2.0 * tol))
    rel = (P[window] if window.sum() >= 40 else P[mid]) - a0

    def frames_for(poly, main_index):
        """The frames along `poly` whose frame at segment `main_index` is
        (e1, e2): e1 carried back to the first segment, then forward
        again round every corner as the sweep carries it."""
        X = e1
        T = [unit(poly[i + 1] - poly[i]) for i in range(len(poly) - 1)]
        for j in range(main_index - 1, -1, -1):
            X = unit(rotation_between(T[j + 1], T[j]) @ X)
            X = unit(X - (X @ T[j]) * T[j])
        return sweep_frames(poly, X), X

    frames, X = frames_for(pts3, main)
    # The section plane of the main leg as `sweep_frames` carries it there
    # (a hair off `plane_frame`'s after the round trip): measure in that.
    _, _, _, E1, E2 = frames[main]
    xy = np.column_stack([rel @ E1, rel @ E2])
    best = regularise_outline(xy, 0.0, 0.0, tol, lambda lp: _legs_covered(P, frames, lp, tol))
    if best is None:
        say("bar: no designed section runs along the leg's points")
        return None
    loop = best["loop"]
    covered, coverage = best["covered"], best["coverage"]
    # The bends' radius: the arcs that cover the most of the bend's points.
    rounded, bend_radius, straight = pts3, 0.0, list(range(len(legs)))
    if bends:
        near_bend = np.zeros(len(P), dtype=bool)
        for c in pts3[1:-1]:
            near_bend |= np.linalg.norm(P - c, axis=1) <= 1.5 * width
        best_R = (0.0, float(covered[near_bend].mean()) if near_bend.any() else 0.0)
        for R in (0.5 * width, width, 1.5 * width, 2.0 * width, 3.0 * width, 4.0 * width):
            built = fillet_spine(pts3, R)
            if built is None:
                break
            poly, straight_R = built
            frames_R, X_R = frames_for(poly, straight_R[main])
            cov_R = _legs_covered(P, frames_R, loop, tol)
            share = float(cov_R[near_bend].mean()) if near_bend.any() else 0.0
            if share > best_R[1] + 0.01:
                best_R = (R, share)
                rounded, bend_radius, straight, frames, X, covered = poly, R, straight_R, frames_R, X_R, cov_R
        if bend_radius > 0:
            say("bar: the bends are arcs of %.0f mm radius (%.0f%% of the bend's points on it, %.0f%% with a sharp corner)" % (
                bend_radius, best_R[1] * 100, float(_legs_covered(P, frames_for(pts3, main)[0], loop, tol)[near_bend].mean()) * 100))
        coverage = float(covered.mean())
    shape = best["shape"]
    if shape["kind"] == "circle":
        w = t = shape["diameterMM"]
    elif shape["kind"] in ("hexagon", "octagon"):
        w = t = shape["acrossFlatsMM"]
    else:
        w, t = shape["lengthMM"], shape["widthMM"]
    return {"points": rounded, "corners": pts3[1:-1], "bendRadiusMM": round(bend_radius, 1),
            "bendsDeg": [round(b, 1) for b in bends], "legsMM": [round(L, 1) for L in lengths],
            "lengthMM": round(sum(lengths), 1), "residualMM": round(spine["residualMM"], 2),
            "section": {"shape": shape["kind"], "segments": best["segments"], "seed": best["seed"],
                        "widthMM": round(w, 1), "thicknessMM": round(t, 1), "cornerMM": shape.get("cornerMM", 0.0)},
            "widthMM": float(w), "thicknessMM": float(t), "xAxis": X,
            "coverage": coverage, "covered": covered}


def fillet_spine(points, R):
    """The polyline's corners rounded to arcs of radius `R` — a real bar is
    bent round a former (the CO₂ extinguisher's lever turns on a radius
    of about a section, and a sharp mitre stands 8 mm proud of it at the
    outside of the bend and short of it inside). Each arc is drawn as
    points every 7.5° or less (the app's sweep and
    `preview_model.sweep_section` mitre each small corner alike); an arc
    may take no more than 45 % of either leg, else None. Returns (points,
    straight), `straight[i]` the index of the segment that is leg i's
    straight run."""
    pts = [np.asarray(p, dtype=float) for p in points]
    out, straight = [pts[0]], [0]
    for i in range(1, len(pts) - 1):
        Pc = pts[i]
        d1, d2 = unit(Pc - pts[i - 1]), unit(pts[i + 1] - Pc)
        theta = math.acos(max(-1.0, min(1.0, float(d1 @ d2))))
        t = R * math.tan(theta / 2) if R > 0 else 0.0
        if R > 0 and (t > 0.45 * np.linalg.norm(Pc - pts[i - 1]) or t > 0.45 * np.linalg.norm(pts[i + 1] - Pc)):
            return None
        if R <= 0 or theta < 1e-6:
            out.append(Pc)
            straight.append(len(out) - 1)
            continue
        A, B = Pc - d1 * t, Pc + d2 * t
        centre = Pc + unit(d2 - d1) * (R / math.cos(theta / 2))
        va, vb = A - centre, B - centre
        k = max(2, int(math.ceil(theta / math.radians(7.5))))
        out.append(A)
        for s in range(1, k):
            f = s / k
            out.append(centre + (math.sin((1 - f) * theta) * va + math.sin(f * theta) * vb) / math.sin(theta))
        out.append(B)
        straight.append(len(out) - 1)
    out.append(pts[-1])
    return out, straight


def bar_words(bar):
    s = bar["section"]
    bends = bar["bendsDeg"]
    radius = (" on a %.0f mm radius" % bar["bendRadiusMM"]) if bends and bar.get("bendRadiusMM") else ""
    return "a %.0f × %.0f mm %s bar%s, %.0f mm long" % (
        s["widthMM"], s["thicknessMM"], s["shape"],
        (" bent " + " and ".join("%.0f°" % b for b in bends) + radius) if bends else " (straight)", bar["lengthMM"])


def bar_feature(bar, start, end, attached, joins=(False, False), into_horn=False):
    """The sweep feature of a bar from `bar_along`, its spine's ends moved
    to `start` and `end` (into the body, or into the next run). The spine
    is the bar's legs with the bends' arcs drawn in; `corners` are the
    sharp corners the legs meet at, `bendRadiusMM` the arcs' radius (0
    for a sharp bend)."""
    pts3 = [np.asarray(start, dtype=float)] + [np.asarray(p, dtype=float) for p in bar["points"][1:-1]] + [np.asarray(end, dtype=float)]
    s = bar["section"]
    return {"kind": "sweep", "profile": {"shape": "section", "widthMM": s["widthMM"], "thicknessMM": s["thicknessMM"]},
            "section": {"shape": s["shape"], "widthMM": s["widthMM"], "thicknessMM": s["thicknessMM"],
                        "cornerMM": round(float(s.get("cornerMM") or 0.0), 1),
                        "segments": s["segments"], "seed": s["seed"]},
            "xAxis": [round(float(q), 5) for q in bar["xAxis"]],
            "spine": [[round(float(q), 2) for q in p] for p in pts3],
            "corners": [[round(float(q), 2) for q in p] for p in bar.get("corners", [])],
            "bendRadiusMM": bar.get("bendRadiusMM", 0.0),
            "bent": bool(bar["bendsDeg"]), "bendsDeg": bar["bendsDeg"], "legsMM": bar["legsMM"],
            "lengthMM": bar["lengthMM"], "radiusMM": round(0.5 * s["thicknessMM"], 2),
            "attached": list(attached), "joins": list(joins), "intoHorn": bool(into_horn)}


def bar_sweep_covered(f, verts, tol):
    """The vertices within `tol` of a flat-bar sweep's prism along any of
    its legs (the same section, carried round the corners as the sweep
    carries it)."""
    loop = segments_polyline(f["section"]["segments"], step=max(0.5, 0.25 * tol))
    frames = sweep_frames(f["spine"], f["xAxis"])
    return _legs_covered(np.asarray(verts, dtype=float), frames, loop, tol)


def bent_bar_fit(comp, tol, far, model_tree):
    """A piece that is one bent flat bar — a lever, a bracket — on its own
    (`tube_fit` finds the flat runs of a chain; this is for the piece the
    tube test refuses outright, a 20 × 5 strap having no tube in it): the
    centreline traced as for a tube, the legs and the section by
    `bar_along`, the ends carried into the body. A straight bar is left to
    `bar_fit`; a curve to the sweep."""
    pts, nrm = component_points(comp)
    if len(pts) < 80:
        return None
    r0 = chord_radius(comp, pts, nrm, label="bent bar")
    if r0 is None or r0 < 1.0:
        return None
    kept = clear_of_body(pts, nrm, r0, far, model_tree, label="bent bar")
    if kept is None:
        return None
    pts, nrm = kept
    traced = trace_centreline(pts, r0, label="bent bar")
    if traced is None:
        return None
    C, step = traced["C"], traced["step"]
    members = np.unique(np.concatenate(traced["members"]))
    P = pts[members]
    # The section's width, roughly: twice the 90th percentile of the
    # points' distance from the centreline (the spine fit's tolerance and
    # the shortest leg scale with it).
    dc, _ = cKDTree(resample_polyline(C, 1.0)).query(P)
    width = 2.0 * float(np.percentile(dc, 90))
    if 2.0 * r0 < max(1.5 * tol, 3.0):
        say("bent bar: %.1f mm thick — a skin, not a bar" % (2 * r0))
        return None
    bar = bar_along(P, C, tol, width, step)
    if bar is None:
        return None
    if not bar["bendsDeg"]:
        say("bent bar: the spine is straight — bar_fit's")
        return None
    if bar["widthMM"] < 1.4 * bar["thicknessMM"]:
        # A bent ROUND bar is a tube's job: the sweep follows its true
        # curve, a quarter circle reads here as three gentle legs.
        say("bent bar: %s has a round section — the tube's" % bar_words(bar))
        return None
    if bar["coverage"] < 0.5:
        say("bent bar: %s covers only %.0f%% of its points" % (bar_words(bar), bar["coverage"] * 100))
        return None
    pts3 = bar["points"]
    r = 0.5 * bar["thicknessMM"]
    start, a0 = bar_end(pts3[0], -unit(pts3[1] - pts3[0]), r, far, model_tree, step, tol)
    end, a1 = bar_end(pts3[-1], unit(pts3[-1] - pts3[-2]), r, far, model_tree, step, tol)
    f = bar_feature(bar, start, end, [a0, a1])
    verts = np.asarray(comp.vertices, dtype=float)
    covered = bar_sweep_covered(f, verts, tol)
    say("bent bar: %s, covers %.0f%%" % (bar_words(bar), covered.mean() * 100))
    return {"kind": "bentbar", "features": [f], "covered": covered, "coverage": float(covered.mean())}


def reach_body(point, direction, r, far, model_tree, step):
    """The end of a tube carried on along its tangent until it is a radius
    inside the body (so the union fuses), up to 60 mm; when the tangent
    misses the skin but the body is within three radii (a stein's handle
    meets the belly at an angle), straight to the nearest point of the
    skin and a radius in. A free end gets half a bin back for what the
    binning took off it. Returns (the end, whether it met the body)."""
    d0, nearest = model_tree.query(point)
    if d0 > 60.0 + r:
        return point + direction * (0.5 * step), False
    p = np.array(point, dtype=float)
    travelled, last = 0.0, d0
    while travelled < 60.0:
        p = p + direction * 1.0
        travelled += 1.0
        d, _ = model_tree.query(p)
        if d < 1.0 or (d > last and last < 2.0):      # at the skin, or just through it
            return p + direction * (r + far), True
        last = d
    if d0 <= max(3.0 * r, 2.0 * far):
        skin = np.asarray(model_tree.data[nearest], dtype=float)
        inward = unit(skin - np.asarray(point, dtype=float))
        return skin + inward * (r + far), True
    return point + direction * (0.5 * step), False


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
    verts = np.asarray(comp.vertices, dtype=float)
    pv = np.column_stack([(verts - centre) @ e1, (verts - centre) @ e2, (verts - centre) @ e3])
    covered = slab_covered(pv, loop, z_mid, t, tol)
    feature = {"kind": "extrude",
               "plane": {"origin": [round(float(v), 2) for v in origin], "xAxis": [round(float(v), 5) for v in e1],
                         "yAxis": [round(float(v), 5) for v in e2]},
               "segments": segments, "distance": round(thickness / 2, 2), "symmetric": True,
               "thicknessMM": round(t, 2), "areaMM2": round(area, 1), "attached": [grow_lo > 0, grow_hi > 0]}
    # The designed outline — a stadium, a hexagon, a rounded rectangle —
    # when it explains the plate as well as the alpha shape does.
    designed = regularise_outline(xy, area, float(covered.mean()), tol,
                                  lambda lp: slab_covered(pv, lp, z_mid, t, tol))
    if designed:
        feature.update({"segments": designed["segments"], "seed": designed["seed"], "shape": designed["shape"],
                        "outlineAreaMM2": round(designed["area"], 1)})
        covered = designed["covered"]
    return {"kind": "extrude", "features": [feature], "covered": covered, "coverage": float(covered.mean())}


def slab_covered(pv, loop, z_mid, t, tol):
    """Points (in the plate's frame) within tolerance of the SLAB'S SURFACE
    — a face or the outline's edge — not merely inside it: a wire arch
    sits inside an 8 mm slab shaped like itself without touching its
    faces."""
    dz = np.abs(pv[:, 2] - z_mid)
    in_slab = dz <= t / 2 + tol
    near_face = np.abs(dz - t / 2) <= tol
    loop_tree = cKDTree(np.vstack([loop, resample_closed(loop, 1.0)]))
    d_edge, _ = loop_tree.query(pv[:, :2])
    inside = points_in_polygon(pv[:, :2], loop)
    return in_slab & ((inside & near_face) | (d_edge <= tol))


def resample_closed(loop, step):
    loop = np.asarray(loop, dtype=float)
    closed = np.vstack([loop, loop[:1]])
    seg = np.linalg.norm(np.diff(closed, axis=0), axis=1)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    if s[-1] < step:
        return loop
    targets = np.arange(0.0, s[-1], step)
    return np.column_stack([np.interp(targets, s, closed[:, k]) for k in range(2)])


# ---- bars -------------------------------------------------------------------

def farthest_seeds(pts, k, rng):
    """`k` points spread over the cloud: farthest-point sampling from a
    random start."""
    idx = [int(rng.integers(len(pts)))]
    d = np.linalg.norm(pts - pts[idx[0]], axis=1)
    for _ in range(k - 1):
        j = int(np.argmax(d))
        idx.append(j)
        d = np.minimum(d, np.linalg.norm(pts - pts[j], axis=1))
    return idx


def plane_frame(d):
    """Two unit vectors across `d` with e1 × e2 = d (a sketch plane whose
    normal is the bar's direction, so a positive extrude runs along it)."""
    e1 = unit(np.cross(d, [0, 0, 1.0]) if abs(d[2]) < 0.9 else np.cross(d, [1.0, 0, 0]))
    e2 = np.cross(d, e1)
    return e1, e2


class PrismGrid:
    """The piece's points projected along a direction d onto a grid of
    `cell` mm. A bar along d stacks every point of its length into the
    cells of its section, so those cells hold points spread the whole
    length; a plate crossing the view, or another bar, puts its points
    into a cell at one height only."""

    def __init__(self, pts, d, cell):
        self.d = d
        self._pts = pts
        self.e1, self.e2 = plane_frame(d)
        self.xy = np.column_stack([pts @ self.e1, pts @ self.e2])
        self.h = pts @ d
        self.cell = cell
        ij = np.floor(self.xy / cell).astype(int)
        self.cells = {}
        for k, key in enumerate(map(tuple, ij)):
            self.cells.setdefault(key, []).append(k)
        self.spread = {}
        for key, m in self.cells.items():
            self.spread[key] = (float(np.percentile(self.h[m], 90) - np.percentile(self.h[m], 10))
                                if len(m) >= 3 else 0.0)

    def best_seed(self, used=None, min_spread=0.0):
        """The cell whose points not yet used run farthest along d: the
        wall of the longest bar still unexplained. (A cell under a bar
        already taken, with its used points at one height and a stray at
        another, read as the longest column of all.)"""
        best, best_s = None, min_spread
        for key, m in self.cells.items():
            if used is not None:
                m = [k for k in m if not used[k]]
            if len(m) < 6:
                continue
            hh = self.h[m]
            lo, hi = float(np.percentile(hh, 10)), float(np.percentile(hh, 90))
            s = hi - lo
            if s <= best_s:
                continue
            # A wall's column holds points all along it; a cap's few
            # points at one end and a stray at the other do not.
            bins = np.floor((hh - lo) / max(s / 16.0, 1e-9)).astype(int)
            if len(np.unique(bins[(bins >= 0) & (bins < 16)])) < 8:
                continue
            best, best_s = key, s
        return best, best_s

    def footprint(self, seed_key, used=None, bins=16, min_occupancy=0.2):
        """The section's points, flood-filled from the seed cell over
        8-neighbours that hold at least two unused points, have a fair
        share of them (15 %) in the middle 40 % of the length — clear of
        the joints at either end: a foot bracket, the bar this one meets —
        and occupy at least `min_occupancy` of `bins` height bins.
        Returns (point indices, length) or (None, spread)."""
        s0 = self.spread.get(seed_key, 0.0)
        if s0 < 3 * self.cell:
            return None, s0
        block = [k for di in (-1, 0, 1) for dj in (-1, 0, 1)
                 for k in self.cells.get((seed_key[0] + di, seed_key[1] + dj), [])]
        hb = self.h[block]
        h_lo, h_hi = float(np.percentile(hb, 5)), float(np.percentile(hb, 95))
        if h_hi - h_lo < 3 * self.cell:
            return None, s0
        width = (h_hi - h_lo) / bins
        mid_lo, mid_hi = h_lo + 0.3 * (h_hi - h_lo), h_hi - 0.3 * (h_hi - h_lo)

        def occupancy(members):
            if len(members) < 2:
                return 0.0
            b = np.floor((self.h[members] - h_lo) / width).astype(int)
            b = b[(b >= 0) & (b < bins)]
            return len(np.unique(b)) / float(bins)

        def in_middle(members):
            hh = self.h[members]
            return int(((hh >= mid_lo) & (hh <= mid_hi)).sum())
        seen = {seed_key}
        stack = [seed_key]
        members = []
        while stack:
            c = stack.pop()
            members.extend(self.cells.get(c, []))
            for di in (-1, 0, 1):
                for dj in (-1, 0, 1):
                    nb = (c[0] + di, c[1] + dj)
                    if nb in seen:
                        continue
                    mm = self.cells.get(nb, [])
                    if used is not None:
                        mm = [k for k in mm if not used[k]]
                    if len(mm) >= 2 and in_middle(mm) >= max(2, 0.15 * len(mm)) and occupancy(mm) >= min_occupancy:
                        seen.add(nb)
                        stack.append(nb)
        members = np.array(sorted(set(members)), dtype=int)
        if used is not None:
            members = members[~used[members]]
        # Only the points within the bar's own length (a joint's strays in
        # a shared cell sit beyond it).
        margin = 2 * self.cell
        members = members[(self.h[members] >= h_lo - margin) & (self.h[members] <= h_hi + margin)]
        return members, h_hi - h_lo


def sharpen_direction(P, d, cell, steps=(4.0, 2.0, 1.0, 0.5), budget=120):
    """The direction along which a bar's points project sharpest: a hill
    climb from `d`, tilting by `steps` degrees across it, on the number
    of grid cells (of `cell` mm) the projection fills with three or more
    points — a bar seen along its own axis stacks every point onto its
    section's walls; a few degrees off, the walls smear to twice the
    cells. (The PCA of the points tilted toward a bracket at one end.)"""
    P = np.asarray(P, dtype=float)

    def cost(dd):
        e1, e2 = plane_frame(dd)
        ij = np.floor(np.column_stack([P @ e1, P @ e2]) / cell).astype(int)
        _, counts = np.unique(ij, axis=0, return_counts=True)
        return int((counts >= 3).sum())
    best, best_cost = unit(d), cost(d)
    evaluations = 1
    for step in steps:
        tilt = math.tan(math.radians(step))
        improved = True
        while improved and evaluations < budget:
            improved = False
            e1, e2 = plane_frame(best)
            for du, dv in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                cand = unit(best + tilt * (du * e1 + dv * e2))
                c = cost(cand)
                evaluations += 1
                if c < best_cost:
                    best, best_cost = cand, c
                    improved = True
                    break
    return best


def raster_outline(xy, cell, min_count=None):
    """The outline of a section from its projected points, by occupancy
    rather than by an alpha shape (a thick, noisy, double-walled channel
    gave the alpha shape loops through its own walls): cells of `cell` mm
    that hold enough points — a wall stacks the whole length's points, a
    joint's stragglers do not — one-cell gaps closed, the largest blob
    kept, its cell-edge boundary chained into a loop. Returns (loop (n,2),
    area mm², seed (a point well inside the material)) or None."""
    from scipy import ndimage
    xy = np.asarray(xy, dtype=float)
    if len(xy) < 4:
        return None
    lo = xy.min(axis=0) - 2 * cell
    ij = np.floor((xy - lo) / cell).astype(int)
    shape = (int(ij[:, 0].max()) + 3, int(ij[:, 1].max()) + 3)
    counts = np.zeros(shape, dtype=int)
    np.add.at(counts, (ij[:, 0], ij[:, 1]), 1)
    occupied = counts[counts > 0]
    if min_count is None:
        min_count = max(2.0, 0.15 * float(np.percentile(occupied, 75)))
    mask = counts >= min_count
    if mask.sum() < 4:
        return None
    mask = ndimage.binary_closing(mask, structure=np.ones((3, 3), dtype=bool))
    labels, n = ndimage.label(mask)
    if n == 0:
        return None
    sizes = ndimage.sum(mask, labels, index=np.arange(1, n + 1))
    blob = labels == (int(np.argmax(sizes)) + 1)
    edges = {}

    def add(a, b):
        edges.setdefault(a, []).append(b)
        edges.setdefault(b, []).append(a)
    padded = np.zeros((blob.shape[0] + 2, blob.shape[1] + 2), dtype=bool)
    padded[1:-1, 1:-1] = blob
    for i in range(1, padded.shape[0] - 1):
        for j in range(1, padded.shape[1] - 1):
            if not padded[i, j]:
                continue
            if not padded[i - 1, j]:
                add((i, j), (i, j + 1))
            if not padded[i + 1, j]:
                add((i + 1, j), (i + 1, j + 1))
            if not padded[i, j - 1]:
                add((i, j), (i + 1, j))
            if not padded[i, j + 1]:
                add((i, j + 1), (i + 1, j + 1))
    best = []
    seen_edges = set()
    for start in list(edges):
        for first in edges[start]:
            if (start, first) in seen_edges:
                continue
            loop = [start]
            prev, cur = start, first
            seen_edges.add((start, first))
            seen_edges.add((first, start))
            while cur != start:
                loop.append(cur)
                options = [q for q in edges[cur] if q != prev and (cur, q) not in seen_edges]
                if not options:
                    break
                nxt = options[0]
                seen_edges.add((cur, nxt))
                seen_edges.add((nxt, cur))
                prev, cur = cur, nxt
            if len(loop) > len(best):
                best = loop
    if len(best) < 4:
        return None
    pts = np.array([[(i - 1) * cell + lo[0], (j - 1) * cell + lo[1]] for i, j in best], dtype=float)
    # The cell corners stand up to a cell outside the points: each corner
    # is pulled onto the outermost point within a cell of it (outermost
    # along the corner's own outward normal, so a square's corner stays
    # a corner), and the outline hugs the cloud — a staircase a cell too
    # big all round read as a section 6 mm wider than the channel.
    signed = float(np.dot(pts[:, 0], np.roll(pts[:, 1], -1)) - np.dot(pts[:, 1], np.roll(pts[:, 0], -1)))
    prev_e = pts - np.roll(pts, 1, axis=0)
    next_e = np.roll(pts, -1, axis=0) - pts
    turn = 1.0 if signed > 0 else -1.0          # counter-clockwise: outward is the right-hand side
    normals = np.column_stack([prev_e[:, 1] + next_e[:, 1], -(prev_e[:, 0] + next_e[:, 0])]) * turn
    lengths = np.linalg.norm(normals, axis=1)
    normals = normals / np.where(lengths > 1e-9, lengths, 1.0)[:, None]
    tree = cKDTree(xy)
    snapped = pts.copy()
    for k, (v, nv) in enumerate(zip(pts, normals)):
        near = tree.query_ball_point(v, cell)
        if not near:
            continue
        cand = xy[near]
        snapped[k] = cand[int(np.argmax((cand - v) @ nv))]
    if not _loop_crosses_itself(snapped):
        pts = snapped
    area = float(blob.sum()) * cell * cell
    dist = ndimage.distance_transform_edt(blob)
    si, sj = np.unravel_index(int(np.argmax(dist)), dist.shape)
    seed = [float((si + 0.5) * cell + lo[0]), float((sj + 0.5) * cell + lo[1])]
    return pts, area, seed


def segments_polyline(segments, step=1.0):
    """The closed polyline of a list of lines and arcs (an arc sampled
    every `step` mm along it, the way it is drawn)."""
    out = []
    for s in segments:
        a = np.asarray(s["a"], dtype=float)
        if s["kind"] == "line":
            out.append(a)
            continue
        c, r = np.asarray(s["center"], dtype=float), float(s["radius"])
        b = np.asarray(s["b"], dtype=float)
        a0, a1 = math.atan2(a[1] - c[1], a[0] - c[0]), math.atan2(b[1] - c[1], b[0] - c[0])
        if s.get("ccw", True):
            while a1 <= a0:
                a1 += 2 * math.pi
        else:
            while a1 >= a0:
                a1 -= 2 * math.pi
        n = max(2, int(abs(a1 - a0) * r / step))
        for t in np.linspace(a0, a1, n, endpoint=False):
            out.append(np.array([c[0] + r * math.cos(t), c[1] + r * math.sin(t)]))
    return np.array(out, dtype=float)


def interior_seed(loop, step):
    """A point well inside a polygon: of a grid of `step` mm over its box,
    the inside point farthest from the edge (the sketch's region pick
    needs one; a thin section's blob centre can fall outside the outline
    once its corners are pulled onto the points)."""
    loop = np.asarray(loop, dtype=float)
    lo, hi = loop.min(axis=0), loop.max(axis=0)
    xs = np.arange(lo[0] + step / 2, hi[0], step)
    ys = np.arange(lo[1] + step / 2, hi[1], step)
    if len(xs) == 0 or len(ys) == 0:
        return [float(v) for v in loop.mean(axis=0)]
    grid = np.array([[x, y] for x in xs for y in ys])
    inside = np.array([point_in_polygon(q, loop) for q in grid])
    if not inside.any():
        return [float(v) for v in loop.mean(axis=0)]
    tree = cKDTree(np.vstack([loop, resample_closed(loop, max(step / 2, 0.25))]))
    d_edge, _ = tree.query(grid[inside])
    best = grid[inside][int(np.argmax(d_edge))]
    return [float(best[0]), float(best[1])]


def _loop_crosses_itself(loop):
    """Whether any two non-adjacent edges of a closed polyline cross."""
    P = np.asarray(loop, dtype=float)
    n = len(P)
    if n < 4:
        return False
    A, B = P, np.roll(P, -1, axis=0)

    def orient(p, q, r):
        return (q[:, 0] - p[:, 0]) * (r[:, 1] - p[:, 1]) - (q[:, 1] - p[:, 1]) * (r[:, 0] - p[:, 0])
    for i in range(n):
        j = np.arange(n)
        ok = (j != i) & (j != (i - 1) % n) & (j != (i + 1) % n)
        if not ok.any():
            continue
        a, b = np.repeat(A[i][None], n, axis=0), np.repeat(B[i][None], n, axis=0)
        c, d = A, B
        o1, o2 = orient(a, b, c), orient(a, b, d)
        o3, o4 = orient(c, d, a), orient(c, d, b)
        cross = (o1 * o2 < 0) & (o3 * o4 < 0) & ok
        if cross.any():
            return True
    return False


def prism_covered(P, origin, e1, e2, d, loop, half, tol):
    """Points within `tol` of a prism: inside its length, and inside the
    section's outline or within `tol` of its edge (the outline hugs the
    section's own points, so the prism is the material, not a hull)."""
    rel = P - origin
    h = rel @ d
    xy = np.column_stack([rel @ e1, rel @ e2])
    loop_tree = cKDTree(np.vstack([loop, resample_closed(loop, 1.0)]))
    d_edge, _ = loop_tree.query(xy)
    within = np.abs(h) <= half + tol
    near = within & (d_edge <= 2.5 * tol)
    inside = np.zeros(len(P), dtype=bool)
    if near.any():
        inside[near] = points_in_polygon(xy[near], loop)
    return within & (inside | (d_edge <= tol))


def bar_fit(comp, tol, far, model_tree):
    """A piece as straight bars. Directions: the long axis of elongated
    patches round seeds spread over the piece (a 45 mm channel reads as a
    line at a 70 mm scale), grouped within 12°. For each direction, from
    the cell whose points run farthest along it, the section is flood-
    filled on the grid across it (`PrismGrid.footprint`), its outline
    rasterised (`raster_outline`), and the bar kept when, bin by bin
    along its length, the median share of its points on the prism is at
    least a half (a joint's junk fills one end bin; a bent handle read as
    straight drifts off in most). Bars are taken greedily by the new
    vertices each covers, up to four; each is an extrude of its section,
    symmetric about the bar's middle, run on into the body or into the
    bar it meets."""
    pts, _ = component_points(comp)
    n = len(pts)
    if n < 80:
        return None
    tree = cKDTree(pts)
    nn, _ = tree.query(pts, k=2)
    spacing = float(np.median(nn[:, 1]))
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    diag = float(np.linalg.norm(hi - lo))
    R = max(8.0 * tol, 6.0 * spacing, 0.08 * diag)
    rng = np.random.default_rng(11)
    seeds = farthest_seeds(pts, max(4, min(24, n // 10)), rng)
    cands = []
    for s in seeds:
        # Three scales: a patch a section wide reads round, one a few
        # sections long reads as a line; at a joint the smallest scale
        # keeps to one bar. The most elongated wins.
        best = None
        for scale in (1.0, 2.0, 3.0):
            near = tree.query_ball_point(pts[s], scale * R)
            if len(near) < 12:
                continue
            P = pts[near]
            c = P.mean(axis=0)
            _, S, _vt = np.linalg.svd(P - c, full_matrices=False)
            if S[1] < 1e-9:
                continue
            if best is None or S[0] / S[1] > best[0]:
                best = (S[0] / S[1], unit(_vt[0]), s, near)
        if best is not None and best[0] >= 1.5:
            # The patch's own sharpest projection: its PCA axis leans a
            # few degrees toward whatever else the ball caught.
            elong, d0, s, near = best
            cands.append((elong, sharpen_direction(pts[near], d0, max(tol, 1.5 * spacing, 1.0)), s))
    cands.sort(key=lambda c: -c[0])
    groups = []
    for elong, d, s in cands:
        for g in groups:
            if abs(g["d"] @ d) > math.cos(math.radians(12)):
                g["seeds"].append(s)
                g["dirs"].append(d if d @ g["d"] > 0 else -d)
                g["d"] = unit(np.mean(g["dirs"], axis=0))
                break
        else:
            groups.append({"d": d, "seeds": [s], "dirs": [d], "elong": elong})
    groups.sort(key=lambda g: (-len(g["seeds"]), -g["elong"]))
    say("bar: %d seeds, %d elongated patches, %d directions (R %.0f mm, spacing %.1f)" % (
        len(seeds), len(cands), len(groups), R, spacing))
    if not groups:
        return None
    cell = max(tol, 1.5 * spacing, 1.0)
    bars = []
    used = np.zeros(n, dtype=bool)
    for g in groups[:6]:
        grid = PrismGrid(pts, g["d"], cell)
        first = None
        for _ in range(3):
            seed_key, _s = grid.best_seed(used=used, min_spread=(0.5 * first if first else 3 * cell))
            if seed_key is None:
                say("bar: along %s: no cell runs far enough" % np.round(g["d"], 2).tolist())
                break
            members, length = grid.footprint(seed_key, used=used)
            if members is None or len(members) < 40:
                say("bar: along %s: the section from cell %s (spread %.0f) holds %d points" % (
                    np.round(g["d"], 2).tolist(), seed_key, _s, 0 if members is None else len(members)))
                break
            if first is None:
                first = length
            d = g["d"]
            # The direction, sharpened on the section's own points (the
            # PCA of all of them tilted 4° toward a bracket at the foot,
            # and the section smeared to twice its width); the section is
            # then read again along it.
            d_ref = sharpen_direction(pts[members], d, cell)
            if abs(d_ref @ d) > math.cos(math.radians(15)):
                d = d_ref if d_ref @ d > 0 else -d_ref
                grid2 = PrismGrid(pts, d, cell)
                seed_pt = pts[grid.cells[seed_key][0]]
                key2 = tuple(np.floor(np.array([seed_pt @ grid2.e1, seed_pt @ grid2.e2]) / cell).astype(int))
                members2, length2 = grid2.footprint(key2, used=used)
                if members2 is not None and len(members2) >= 40:
                    members, length = members2, length2
            P = pts[members]
            c = P.mean(axis=0)
            e1, e2 = plane_frame(d)
            rel = P - c
            h = rel @ d
            xy = np.column_stack([rel @ e1, rel @ e2])
            # The length: nearly the full spread of the points (a free end's
            # last points are the end), each free end then run on a
            # tolerance so the cap reaches them.
            h_lo, h_hi = float(np.percentile(h, 0.5)), float(np.percentile(h, 99.5))
            L = h_hi - h_lo
            mid = (h > h_lo + 0.1 * L) & (h < h_hi - 0.1 * L)
            sxy = xy[mid] if mid.sum() >= 40 else xy
            used[members] = True
            raster = raster_outline(sxy, cell)
            if raster is None:
                say("bar: along %s: no outline" % np.round(d, 2).tolist())
                continue
            loop, _area, seed2d = raster
            loop = np.array(douglas_peucker_2d(np.vstack([loop, loop[:1]]), max(0.7 * cell, 0.4))[:-1])
            if len(loop) < 3:
                continue
            if not point_in_polygon(seed2d, loop):
                seed2d = interior_seed(loop, max(0.5 * cell, 0.5))
            ext = np.ptp(loop, axis=0)
            section = float(ext.max())
            if L < 1.5 * section:
                say("bar: along %s: length %.0f under 1.5 × its section %.0f" % (np.round(d, 2).tolist(), L, section))
                continue
            area = polygon_area(loop)
            half = L / 2
            origin = c + d * ((h_lo + h_hi) / 2)
            own = prism_covered(P, origin, e1, e2, d, loop, half, tol)
            # The section as designed — round, hexagonal, a rounded
            # rectangle — when it explains the bar as well as the raster.
            segs, shape = None, None
            designed = regularise_outline(sxy, area, float(own.mean()), tol,
                                          lambda lp: prism_covered(P, origin, e1, e2, d, lp, half, tol))
            if designed:
                loop, segs, shape, own, area = designed["loop"], designed["segments"], designed["shape"], designed["covered"], designed["area"]
                seed2d = designed["seed"]
            hb = np.clip(((h - h_lo) / max(L, 1e-9) * 8).astype(int), 0, 7)
            per_bin = [own[hb == k].mean() for k in range(8) if (hb == k).sum() >= 10]
            own_median = float(np.median(per_bin)) if per_bin else float(own.mean())
            say("bar: along %s length %.0f section %.0f × %.0f area %.0f (%d outline points), %d points, on it %.0f%% (median bin %.0f%%)" % (
                np.round(d, 2).tolist(), L, ext[0], ext[1], area, len(loop), len(P), own.mean() * 100, own_median * 100))
            if own_median < 0.5:
                continue
            bars.append({"d": d, "e1": e1, "e2": e2, "origin": origin, "loop": loop, "half": half, "L": L,
                         "section": section, "own": own_median, "area": area, "seed": seed2d,
                         "segments": segs, "shape": shape})
    if not bars:
        say("bar: no bar survived")
        return None
    # Greedy, on the sampled points (a low-poly piece has too few vertices
    # to count on): each bar must add a twentieth of the piece, and
    # explain `BAR_MIN_AREA` of scan on its own.
    taken = np.zeros(n, dtype=bool)
    chosen = []
    remaining = list(bars)
    area = float(comp.area)
    while remaining and len(chosen) < 4:
        scored = []
        for i, b in enumerate(remaining):
            cv = prism_covered(pts, b["origin"], b["e1"], b["e2"], b["d"], b["loop"], b["half"], tol)
            scored.append((int((cv & ~taken).sum()), i, cv))
        scored.sort(key=lambda t: -t[0])
        new, i, cv = scored[0]
        if new < max(30, 0.05 * n):
            break
        explained = new / float(n) * area
        if explained < BAR_MIN_AREA:
            b = remaining.pop(i)
            say("bar: along %s dropped: explains %.0f mm², under %.0f" % (np.round(b["d"], 2).tolist(), explained, BAR_MIN_AREA))
            continue
        taken |= cv
        chosen.append(remaining.pop(i))
    if not chosen:
        say("bar: no bar covers enough of the piece")
        return None
    verts = np.asarray(comp.vertices, dtype=float)
    covered = np.zeros(len(verts), dtype=bool)
    for b in chosen:
        covered |= prism_covered(verts, b["origin"], b["e1"], b["e2"], b["d"], b["loop"], b["half"], tol)
    features = []
    for b in chosen:
        d, e1, e2, origin, loop, half = b["d"], b["e1"], b["e2"], b["origin"], b["loop"], b["half"]
        grow, touches = [0.0, 0.0], [False, False]
        rel_all = pts - origin
        h_all = rel_all @ d
        lat = np.column_stack([rel_all @ e1, rel_all @ e2])
        lateral = np.linalg.norm(lat - loop.mean(axis=0), axis=1)
        for k, sign in enumerate((-1.0, 1.0)):
            end = origin + d * sign * half
            dm, _ = model_tree.query(end)
            if dm < far + 2.0:
                grow[k] = far + 3.0          # into the body, so the union fuses
                touches[k] = True
                continue
            # The piece goes on past this end within the section's reach:
            # the bar it is welded to — run on into it. A free end runs
            # on a tolerance, to the last of its points.
            past = (sign * h_all > half + tol) & (sign * h_all < half + 0.6 * b["section"]) & (lateral < 0.8 * b["section"])
            grow[k] = 0.5 * b["section"] if past.sum() >= 20 else tol
        origin = origin + d * ((grow[1] - grow[0]) / 2)
        half2 = half + (grow[0] + grow[1]) / 2
        segs = b["segments"]
        if segs is None:
            segs = segments_from_loop(loop, tol=max(tol * 0.5, 0.3), max_radius=float(np.ptp(loop, axis=0).max()))
            if len(segs) < 3:
                segs = [{"kind": "line", "a": loop[i].tolist(), "b": loop[(i + 1) % len(loop)].tolist()} for i in range(len(loop))]
        # The seed must lie inside the outline AS DRAWN (the line-and-arc
        # fit merges close vertices and can move a thin section's edge
        # past the blob's centre).
        drawn = segments_polyline(segs)
        seed = b["seed"]
        if len(drawn) >= 3 and not point_in_polygon(seed, drawn):
            seed = interior_seed(drawn, max(0.5 * cell, 0.5))
        feature = {"kind": "extrude", "bar": True,
                   "plane": {"origin": [round(float(v), 2) for v in origin],
                             "xAxis": [round(float(v), 5) for v in e1], "yAxis": [round(float(v), 5) for v in e2]},
                   "segments": segs, "seed": [round(float(v), 3) for v in seed],
                   "distance": round(half2, 2), "symmetric": True,
                   "thicknessMM": round(b["L"], 2), "lengthMM": round(b["L"], 1), "sectionMM": round(b["section"], 1),
                   "areaMM2": round(b["area"], 1), "ownCoverage": round(b["own"], 3), "attached": touches}
        if b["shape"]:
            feature["shape"] = b["shape"]
        features.append(feature)
    return {"kind": "bar", "features": features, "covered": covered, "coverage": float(covered.mean())}


# ---- the parts library: parametric outlines ---------------------------------
#
# A lever is a bar with rounded ends, a nut a regular hexagon, a flange a
# rectangle with rounded corners, a knob a disc: the free-form outline of
# a plate or a bar's section is matched against these, and the designed
# shape is taken whenever it explains the piece as well as the wiggly one
# (`regularise_outline`). Every shape is written as the same lines and
# arcs `segments_from_loop` produces, so nothing downstream changes.

PARAMETRIC_ORDER = ("circle", "stadium", "square", "rectangle", "hexagon", "octagon", "ellipse")


def arc_segment(center, radius, start, end):
    """An arc in `segments_from_loop`'s terms, counter-clockwise from
    `start` to `end` (radians), its ends computed."""
    c = np.asarray(center, dtype=float)
    a = c + radius * np.array([math.cos(start), math.sin(start)])
    b = c + radius * np.array([math.cos(end), math.sin(end)])
    return {"kind": "arc", "center": [float(c[0]), float(c[1])], "radius": float(radius), "start": float(start),
            "end": float(end), "ccw": True, "a": [float(a[0]), float(a[1])], "b": [float(b[0]), float(b[1])]}


def line_segment(a, b):
    return {"kind": "line", "a": [float(a[0]), float(a[1])], "b": [float(b[0]), float(b[1])]}


def circle_segments(r):
    """A circle as two semicircles: the sketch takes arcs, and a full turn
    is not one."""
    return [arc_segment((0.0, 0.0), r, 0.0, math.pi), arc_segment((0.0, 0.0), r, math.pi, 2 * math.pi)]


def stadium_segments(length, width):
    """Two semicircles joined by two lines, the long axis along u."""
    r = width / 2
    s = length / 2 - r
    if s < 1e-6:
        return circle_segments(r)
    return [arc_segment((s, 0.0), r, -math.pi / 2, math.pi / 2), line_segment((s, r), (-s, r)),
            arc_segment((-s, 0.0), r, math.pi / 2, 1.5 * math.pi), line_segment((-s, -r), (s, -r))]


def rounded_rectangle_segments(length, width, corner):
    """A rectangle `length` along u by `width` along v, its corners rounded
    to `corner` (none when 0), counter-clockwise from the right edge."""
    a, b = length / 2, width / 2
    r = min(corner, 0.45 * min(a, b))
    if r < 1e-6:
        return [line_segment((a, -b), (a, b)), line_segment((a, b), (-a, b)),
                line_segment((-a, b), (-a, -b)), line_segment((-a, -b), (a, -b))]
    return [line_segment((a, r - b), (a, b - r)), arc_segment((a - r, b - r), r, 0.0, math.pi / 2),
            line_segment((a - r, b), (r - a, b)), arc_segment((r - a, b - r), r, math.pi / 2, math.pi),
            line_segment((-a, b - r), (-a, r - b)), arc_segment((r - a, r - b), r, math.pi, 1.5 * math.pi),
            line_segment((r - a, -b), (a - r, -b)), arc_segment((a - r, r - b), r, 1.5 * math.pi, 2 * math.pi)]


def polygon_segments(n, apothem, phi):
    """A regular n-gon of the given apothem (half its across-flats), one
    face normal at angle `phi`, counter-clockwise."""
    R = apothem / math.cos(math.pi / n)
    verts = [(R * math.cos(phi + math.pi / n + 2 * math.pi * k / n), R * math.sin(phi + math.pi / n + 2 * math.pi * k / n))
             for k in range(n)]
    return [line_segment(verts[k], verts[(k + 1) % n]) for k in range(n)]


def oval_segments(a, b):
    """The draughtsman's four-centre oval of semi-axes a ≥ b — the arcs
    `build_features.oval_entities` sweeps — as segments."""
    a, b = float(max(a, b)), float(min(a, b))
    if a - b < 0.05 * a:
        return circle_segments((a + b) / 2)
    r1 = b * b / a
    r2 = ((a - r1) ** 2 + b * b - r1 * r1) / (2 * (b - r1))
    c1, c2 = a - r1, r2 - b
    phi = math.atan2(c2, c1)
    return [arc_segment((c1, 0.0), r1, -phi, phi), arc_segment((0.0, -c2), r2, phi, math.pi - phi),
            arc_segment((-c1, 0.0), r1, math.pi - phi, math.pi + phi),
            arc_segment((0.0, c2), r2, math.pi + phi, 2 * math.pi - phi)]


def place_segments(segs, centre, theta):
    """The segments moved from the shape's own frame into the sketch plane:
    rotated by `theta`, then shifted to `centre`."""
    c, s = math.cos(theta), math.sin(theta)
    R = np.array([[c, -s], [s, c]])
    cen = np.asarray(centre, dtype=float)

    def move(p):
        q = R @ np.asarray(p, dtype=float) + cen
        return [round(float(q[0]), 4), round(float(q[1]), 4)]
    out = []
    for seg in segs:
        t = {"kind": seg["kind"], "a": move(seg["a"]), "b": move(seg["b"])}
        if seg["kind"] == "arc":
            start = (seg["start"] + theta) % (2 * math.pi)
            t.update({"center": move(seg["center"]), "radius": round(seg["radius"], 4), "start": round(start, 6),
                      "end": round(start + (seg["end"] - seg["start"]), 6), "ccw": True})
        out.append(t)
    return out


def polygon_area(loop):
    loop = np.asarray(loop, dtype=float)
    return 0.5 * abs(float(np.dot(loop[:, 0], np.roll(loop[:, 1], -1)) - np.dot(loop[:, 1], np.roll(loop[:, 0], -1))))


def points_in_polygon(P, loop):
    """`point_in_polygon` for many points at once (the same ray cast)."""
    P = np.asarray(P, dtype=float)
    L = np.asarray(loop, dtype=float)
    x, y = P[:, 0], P[:, 1]
    inside = np.zeros(len(P), dtype=bool)
    n = len(L)
    for i in range(n):
        x0, y0 = L[i]
        x1, y1 = L[(i + 1) % n]
        crosses = (y0 > y) != (y1 > y)
        if not crosses.any():
            continue
        xi = x0 + (y[crosses] - y0) * (x1 - x0) / (y1 - y0)
        hit = np.zeros(len(P), dtype=bool)
        hit[crosses] = x[crosses] < xi
        inside ^= hit
    return inside


def solid_points(xy, cell):
    """The projected points with their thin tails taken off: cells of
    `cell` mm that hold points, opened (eroded then dilated by one cell —
    a tail one cell wide vanishes, a body keeps its shape), and the
    points in the cells that survive. A knob's cloud trailed a wisp of
    the neck it sits on, and every shape fitted to the hull was hung on
    it. All the points when fewer than half would survive."""
    from scipy import ndimage
    xy = np.asarray(xy, dtype=float)
    lo = xy.min(axis=0) - 2 * cell
    ij = np.floor((xy - lo) / cell).astype(int)
    shape = (int(ij[:, 0].max()) + 3, int(ij[:, 1].max()) + 3)
    counts = np.zeros(shape, dtype=int)
    np.add.at(counts, (ij[:, 0], ij[:, 1]), 1)
    mask = ndimage.binary_opening(counts > 0, structure=np.ones((3, 3), dtype=bool))
    keep = mask[ij[:, 0], ij[:, 1]]
    return xy[keep] if keep.sum() >= 0.5 * len(xy) else xy


def hull_loop(xy, cell=1.0):
    """The convex hull of the projected points, counter-clockwise, their
    thin tails (`solid_points`) and the half percent farthest from their
    centre left out (one stray point hangs a corner on the hull)."""
    from scipy.spatial import ConvexHull
    xy = np.asarray(xy, dtype=float)
    if len(xy) < 8:
        return None
    xy = solid_points(xy, cell)
    d = np.linalg.norm(xy - np.median(xy, axis=0), axis=1)
    pts = xy[d <= np.percentile(d, 99.5)]
    try:
        hull = ConvexHull(pts)
    except Exception:  # noqa: BLE001 — collinear points have no hull
        return None
    loop = pts[hull.vertices]
    return loop if polygon_area(loop) > 1e-6 else None


def tightest_box(hull):
    """The smallest rectangle round a convex loop (one side lies along a
    hull edge): (angle of its long side, length, width, centre)."""
    best = None
    n = len(hull)
    for i in range(n):
        e = hull[(i + 1) % n] - hull[i]
        if np.linalg.norm(e) < 1e-9:
            continue
        theta = math.atan2(e[1], e[0])
        c, s = math.cos(theta), math.sin(theta)
        u = hull @ np.array([c, s])
        v = hull @ np.array([-s, c])
        L, W = float(np.ptp(u)), float(np.ptp(v))
        if best is None or L * W < best[0]:
            cu, cv = (u.min() + u.max()) / 2, (v.min() + v.max()) / 2
            centre = cu * np.array([c, s]) + cv * np.array([-s, c])
            if L < W:
                theta, L, W = theta + math.pi / 2, W, L
            best = (L * W, theta % math.pi, L, W, centre)
    return best[1:] if best else None


def regular_candidates(xy, tol):
    """The parametric outlines that could be the piece's section, each as
    (name, segments in the plane, seed, shape): a circle, a stadium, a
    rectangle (its corner radius from the area the hull lacks), an oval,
    and a hexagon and an octagon (the tightest about the hull's centroid)."""
    hull = hull_loop(xy, cell=max(tol, 1.0))
    if hull is None or len(hull) < 3:
        return []
    dense = resample_closed(hull, 0.5)
    box = tightest_box(hull)
    if box is None:
        return []
    theta, L, W, centre = box
    area_hull = polygon_area(hull)
    out = []
    cc, R, _ = fit_circle_2d(dense)
    if R > 0.5:
        out.append(("circle", place_segments(circle_segments(R), cc, 0.0), cc,
                    {"kind": "circle", "diameterMM": round(2 * R, 1)}))
    if W > 1.0:
        if L > 1.02 * W:
            out.append(("stadium", place_segments(stadium_segments(L, W), centre, theta), centre,
                        {"kind": "stadium", "lengthMM": round(L, 1), "widthMM": round(W, 1)}))
        corner = math.sqrt(max(L * W - area_hull, 0.0) / (4 - math.pi))
        corner = 0.0 if corner < max(tol, 0.05 * W) else min(corner, 0.45 * W)
        name = "square" if L < 1.08 * W else "rectangle"
        out.append((name, place_segments(rounded_rectangle_segments(L, W, corner), centre, theta), centre,
                    {"kind": name, "lengthMM": round(L, 1), "widthMM": round(W, 1), "cornerMM": round(corner, 1)}))
        if L > 1.1 * W:
            out.append(("ellipse", place_segments(oval_segments(L / 2, W / 2), centre, theta), centre,
                        {"kind": "ellipse", "lengthMM": round(L, 1), "widthMM": round(W, 1)}))
    # The polygons sit about the hull's area centroid; of the rotations,
    # the one whose n-gon needs the smallest apothem to hold every hull
    # vertex is the one whose flats lie along the hull's.
    closed = np.vstack([hull, hull[:1]])
    cross = closed[:-1, 0] * closed[1:, 1] - closed[1:, 0] * closed[:-1, 1]
    cen = (closed[:-1] + closed[1:]).T @ cross / (6 * polygon_area(hull)) * (1.0 if cross.sum() > 0 else -1.0)
    rel = hull - cen
    for n, name in ((6, "hexagon"), (8, "octagon")):
        best = None
        for phi in np.linspace(0.0, 2 * math.pi / n, 48, endpoint=False):
            normals = np.array([[math.cos(phi + 2 * math.pi * k / n), math.sin(phi + 2 * math.pi * k / n)] for k in range(n)])
            apothem = float((rel @ normals.T).max())
            if best is None or apothem < best[0]:
                best = (apothem, phi)
        apothem, phi = best
        if apothem > 0.5:
            out.append((name, place_segments(polygon_segments(n, apothem, phi), cen, 0.0), cen,
                        {"kind": name, "sides": n, "acrossFlatsMM": round(2 * apothem, 1)}))
    return out


def regularise_outline(xy, free_area, free_coverage, tol, covered_of):
    """The designed outline for a section whose free-form outline covers
    `free_coverage` of the piece: the parametric candidate (`regular_candidates`
    of the projected points `xy`) whose outline runs along the points —
    nine tenths of it within two tolerances of one; a box drawn round an
    L-shaped plate crosses the notch in air — and that covers at least
    as much as the free-form outline less 0.03: design intent beats a
    wiggly outline that fits two percent better. Among those, the best
    coverage, and to the hundredth the simpler shape. `covered_of(loop)`
    is the fit's own coverage test on the piece's points. Returns a dict
    (segments, loop, seed, shape, coverage, area) or None."""
    best = None
    points = cKDTree(np.asarray(xy, dtype=float))
    for name, segs, seed, shape in regular_candidates(xy, tol):
        loop = segments_polyline(segs, step=max(0.5, 0.25 * tol))
        if len(loop) < 3 or _loop_crosses_itself(loop):
            continue
        area = polygon_area(loop)
        d_pts, _ = points.query(resample_closed(loop, 1.0))
        along = float((d_pts <= max(2.0 * tol, 2.0)).mean())
        if along < 0.9:
            say("outline: %s: only %.0f%% of its outline runs along the points" % (name, along * 100))
            continue
        covered = covered_of(loop)
        coverage = float(covered.mean())
        if coverage < free_coverage - 0.03:
            say("outline: %s covers %.0f%% (free-form %.0f%%)" % (name, coverage * 100, free_coverage * 100))
            continue
        key = (round(coverage, 2), -PARAMETRIC_ORDER.index(name))
        if best is None or key > best["key"]:
            best = {"key": key, "segments": segs, "loop": loop, "seed": [round(float(v), 3) for v in seed],
                    "shape": shape, "coverage": coverage, "covered": covered, "area": area}
    if best:
        say("outline: %s covers %.0f%% (free-form %.0f%%): the designed shape" % (
            best["shape"]["kind"], best["coverage"] * 100, free_coverage * 100))
    return best


# ---- hoops ------------------------------------------------------------------

# The main body's axis and radius-along, set by `main` from the analysis
# (`--analysis profile.json`): a ring round it is a hoop, revolved on the
# body's own axis rather than fitted as a lump.
BODY = None


def body_frame(analysis, far):
    """What `hoop_fit` needs of the analysis: the axis, the body's radius at
    each height (interpolated along its profile) and how far a hoop's
    section may reach into the skin so the union fuses — half the wall of
    a hollow body (a bucket's wall is 5 mm; the cavity must stay), far + 4
    of a solid one."""
    if not analysis or "axisOrigin" not in analysis:
        return None
    prof = np.asarray(analysis.get("profile") or [], dtype=float)
    if len(prof) < 2:
        return None
    order = np.argsort(prof[:, 1])
    hs, rs = prof[order, 1], prof[order, 0]
    wall = (analysis.get("openTop") or {}).get("wallMM")
    inset = min(0.5 * wall, far + 4.0) if wall else far + 4.0
    return {"origin": np.asarray(analysis["axisOrigin"], dtype=float), "direction": unit(analysis["axisDirection"]),
            "radius_at": lambda h: np.interp(h, hs, rs), "inset": float(inset), "heightMM": float(analysis.get("heightMM", hs[-1]))}


def hoop_fit(comp, tol, far, model_tree, body=None):
    """A ring round the main body's axis — a barrel's hoop, a rolled rim, a
    bead: a height band on that axis in which the piece's points run at
    least half way round (12 of 24 azimuth sectors), at one radius (the
    sectors' outer radii — each sector's 75th percentile, the two or so
    oddest sectors at either end left out (the 10th to 90th percentile of
    them) for the dent or stray patch a scan always has — within
    max(2 tol, 4 %) of each other, so a squashed bucket's bulge, which is
    one-sided, is not a hoop), and no taller than 0.35 of its diameter —
    a ring is a ring, not a wall; a body skin merely out of round by a
    few mm over its whole height runs all the sectors at one radius and
    would otherwise pass. The section is the outer radius per height bin
    out, and the body's own skin a little inside back: a closed annular
    profile revolved on the body's axis (kind `revolve`, the profile
    closed so a hollow body's cavity is kept)."""
    body = body or BODY
    if body is None:
        return None
    pts, nrm = component_points(comp)
    if len(pts) < 80:
        return None
    o, d = body["origin"], body["direction"]
    h = (pts - o) @ d
    perp = (pts - o) - np.outer(h, d)
    r = np.linalg.norm(perp, axis=1)
    e1, e2 = plane_frame(d)
    sectors = 24
    sec = ((np.arctan2(perp @ e2, perp @ e1) + math.pi) / (2 * math.pi) * sectors).astype(int) % sectors
    band = max(2.0, tol)
    h0 = float(h.min())
    nb = int((h.max() - h0) / band) + 1
    which = np.clip(((h - h0) / band).astype(int), 0, nb - 1)
    occupied = np.zeros(nb)
    for k in range(nb):
        m = which == k
        if m.sum() >= 12:
            occupied[k] = len(np.unique(sec[m])) / float(sectors)
    full = occupied >= 0.5
    if not full.any():
        say("hoop: no height band runs half way round the axis (best %.0f%%)" % (occupied.max() * 100))
        return None
    # The longest run of bands the ring runs round.
    best, run = None, None
    for k in range(nb):
        if full[k]:
            run = [k, k] if run is None else [run[0], k]
            if best is None or run[1] - run[0] > best[1] - best[0]:
                best = list(run)
        else:
            run = None
    k0, k1 = best
    sel = (which >= k0) & (which <= k1)
    # The band ends where its points stop, not at the bin edge beyond them
    # (a 10 mm ring in 2 mm bins would otherwise be 12 tall).
    h_lo = max(h0 + k0 * band, float(h[sel].min()))
    h_hi = min(h0 + (k1 + 1) * band, float(h[sel].max()))
    if h_hi - h_lo < 0.5 * band:
        return None
    # Each sector's outer skin (the 75th percentile: a hoop's top and bottom
    # faces, and its inner face where the scan saw it, lie inside it).
    meds = [float(np.percentile(r[sel & (sec == s)], 75)) for s in range(sectors) if (sel & (sec == s)).sum() >= 5]
    if len(meds) < sectors // 2:
        say("hoop: band %.0f–%.0f mm: only %d sectors hold five points" % (h0 + k0 * band, h0 + (k1 + 1) * band, len(meds)))
        return None
    spread = float(np.percentile(meds, 90) - np.percentile(meds, 10))
    r_med = float(np.median(meds))
    if spread > max(2.0 * tol, 0.04 * r_med):
        say("hoop: band %.0f–%.0f mm: %d sectors, radii spread %.1f mm — not one ring" % (
            h0 + k0 * band, h0 + (k1 + 1) * band, len(meds), spread))
        return None
    # A ring is short against its diameter. A body wall a few mm out of
    # round (within the 4 %) runs all the sectors at one radius over its
    # whole height, and on a sparse sheet the band's extent is set by
    # where the samples fell, not by the geometry: neither is a hoop.
    if h_hi - h_lo > 0.35 * 2.0 * r_med:
        say("hoop: band %.0f–%.0f mm is %.0f mm tall on a %.0f mm diameter — a wall, not a ring" % (
            h_lo, h_hi, h_hi - h_lo, 2.0 * r_med))
        return None
    # The ring's outer face per height bin: the 75th percentile radius of
    # the points that face sideways (normal across the axis, not along
    # it). A hoop's top and bottom faces would otherwise pull its end
    # bins' radius in towards the skin, and its own outer vertices would
    # then miss the profile by more than `tol`.
    radial = perp / np.maximum(r, 1e-9)[:, None]
    side = (np.abs(nrm @ d) < 0.6) & (np.abs(np.einsum("ij,ij->i", nrm, radial)) > 0.5)
    outer = []
    for k in range(k0, k1 + 1):
        hc = h0 + (k + 0.5) * band
        m = sel & side & (which == k)
        if m.sum() >= 6 and h_lo < hc < h_hi:
            outer.append([float(np.percentile(r[m], 75)), hc])
    if len(outer) < 1:
        say("hoop: band %.0f–%.0f mm has no side-facing points to take an outer radius from" % (h_lo, h_hi))
        return None
    outer = [[outer[0][0], h_lo]] + outer + [[outer[-1][0], h_hi]]
    outer = douglas_peucker_2d(outer, max(0.5 * tol, 0.5))
    # The inner side follows the body's skin, a little inside it.
    inner = []
    for rr, hh in outer[::-1]:
        r_in = float(body["radius_at"](hh)) - body["inset"]
        inner.append([min(r_in, rr - max(2.0 * tol, 3.0)), hh])
    profile = [[round(float(rr), 2), round(float(hh), 2)] for rr, hh in outer + inner] + [[round(float(outer[0][0]), 2), round(float(outer[0][1]), 2)]]
    section = float(np.mean([rr for rr, _ in outer]) - np.mean([rr for rr, _ in inner]))
    # Covered: within tolerance of the ring's outer face, or of its top or
    # bottom face between the skin and the outer radius — the same `tol`
    # every other fit is held to, so the score explain() ranks is honest.
    verts = np.asarray(comp.vertices, dtype=float)
    hv = (verts - o) @ d
    rv = np.linalg.norm((verts - o) - np.outer(hv, d), axis=1)
    prof = np.asarray(outer, dtype=float)
    r_at = np.interp(hv, prof[:, 1], prof[:, 0])
    in_band = (hv >= h_lo - tol) & (hv <= h_hi + tol)
    on_face = np.abs(rv - r_at) <= tol
    on_end = (rv <= r_at + tol) & ((np.abs(hv - h_lo) <= tol) | (np.abs(hv - h_hi) <= tol))
    covered = in_band & (on_face | on_end)
    rounded = (max(rr for rr, _ in outer) - min(outer[0][0], outer[-1][0])) > tol and len(outer) >= 4
    feature = {"kind": "revolve", "hoop": True,
               "axis": {"origin": [round(float(v), 2) for v in o], "direction": [round(float(v), 5) for v in d]},
               "profile": profile, "lengthMM": round(h_hi - h_lo, 1), "radiusMM": round(r_med, 2),
               "shape": {"kind": "bead" if rounded else "band", "heightMM": round(h_hi - h_lo, 1),
                         "standsProudMM": round(section, 1), "diameterMM": round(2 * r_med, 1)}}
    say("hoop: band %.0f–%.0f mm on the body's axis, radius %.0f (%d sectors, spread %.1f), covers %.0f%%" % (
        h_lo, h_hi, r_med, len(meds), spread, covered.mean() * 100))
    return {"kind": "hoop", "features": [feature], "covered": covered, "coverage": float(covered.mean())}


# ---- naming -----------------------------------------------------------------

def name_part(f):
    """What the feature is, by simple rules on its shape, its ratios and
    where it attaches — lever, handle, hose, horn, grip, nut, flange, hoop,
    knob, bar, plate, lug — or None when the rules do not know."""
    kind = f["kind"]
    shape = (f.get("shape") or {}).get("kind")
    if kind == "sweep" and f.get("section"):
        # A bar swept along its legs: a lever when it is flat and hangs
        # from the body (or the run it joins) at one end, a handle when
        # it comes back to the body at both, else a bar.
        ends = [a or j for a, j in zip(f.get("attached") or [False, False], f.get("joins") or [False, False])]
        flat = f["section"]["widthMM"] >= 1.5 * f["section"]["thicknessMM"]
        if all(ends):
            return "handle"
        if flat and any(ends):
            return "lever"
        return "bar"
    if kind == "sweep":
        ends = f.get("attached") or [False, False]
        if all(ends):
            return "handle"                         # an arch from the body back to the body
        r = f.get("radiusMM", 1e9)
        long = f.get("lengthMM", 0) >= 10.0 * r
        if long and (f.get("intoHorn") or (r <= 8.0 and any(ends))):
            return "hose"                           # a long tube into a horn, or a thin one out of the body
        if not long and any(ends):
            return "grip"                           # a short, fat one out of the body
        return None                                 # a chain, a stein's handle to a hinge the model lacks: the rules do not know
    if kind == "revolve":
        if f.get("hoop"):
            return "hoop"
        if f.get("cone"):
            return "horn"
        return "knob" if f.get("lengthMM", 0) <= 2.2 * f.get("radiusMM", 0) else None
    if f.get("bar"):
        return "bar"
    if not shape:
        return None
    t = f.get("thicknessMM", 0.0)
    s = f["shape"]
    if shape in ("hexagon", "octagon"):
        return "nut"
    if shape == "stadium":
        return "lever" if s["lengthMM"] >= 2.0 * s["widthMM"] else "lug"
    faced = any(f.get("attached") or [])
    if shape in ("rectangle", "square"):
        if t <= 0.35 * s["widthMM"]:
            return "flange" if faced else "plate"
        return "lug"
    if shape == "circle":
        if t >= 0.5 * s["diameterMM"]:
            return "knob"
        return "flange" if faced else "plate"
    if shape == "ellipse":
        return "lug" if t > 0.35 * s["widthMM"] else "plate"
    return None


# ---- choosing ---------------------------------------------------------------

def explain(comp, tol, far, model_tree, depth, out_features, unexplained, budget, label, fits=None):
    """Try the fits on a piece (`fits` names a subset), keep the best,
    recurse on the rest."""
    if budget[0] <= 0:
        unexplained.append(describe(comp, "feature budget spent"))
        return
    candidates = []
    for name, fn in (("hoop", hoop_fit), ("sweep", tube_fit), ("bentbar", bent_bar_fit), ("revolve", revolve_fit),
                     ("extrude", extrude_fit), ("bar", bar_fit)):
        if fits is not None and name not in fits:
            continue
        if name == "hoop" and BODY is None:
            continue
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
    # is a tube, not a slab); a revolve likewise over a block. Bars come
    # last: a chain or a lever read as a straight prism covers more of
    # its points than the tube or the plate it is, so a bar only wins
    # over a tube that covers 0.38 less, a plate 0.3 less — a stand's
    # post and beam, where the tube fit has nothing and the slab a fifth.
    # A hoop on the body's own axis is the strongest story of all; a plate
    # or a bar whose outline is a designed shape (a stadium, a hexagon)
    # earns a little over a free-form one — its coverage is still honest.
    # A bent bar (one designed section swept along two or three legs) is
    # proved point by point against its prism, the strictest test here,
    # so it earns as much as a revolve.
    def score(c):
        bonus = {"hoop": 0.08, "sweep": 0.08, "bentbar": 0.05, "revolve": 0.05, "extrude": 0.0, "bar": -0.3}[c["kind"]]
        if c["kind"] in ("extrude", "bar") and all(f.get("shape") for f in c["features"]):
            bonus += 0.03
        return c["coverage"] + bonus
    # A sweep's runs were each proved on their own points, so a hose and
    # its horn count even when the valve beside them is left over; a hoop
    # likewise on its band's roundness. A revolve, a block or a frame of
    # bars is one fit for the whole piece and has to cover half of it. The
    # best story that covers enough wins — a slab that covers too little
    # does not stop the bars behind it.
    needed = {"sweep": 0.25, "hoop": 0.3}
    ranked = sorted(candidates, key=score, reverse=True)
    best = next((c for c in ranked if c["coverage"] >= needed.get(c["kind"], 0.5)), None)
    if best is None:
        top = ranked[0]
        unexplained.append(describe(comp, "best fit (%s) covers only %.0f%%" % (top["kind"], top["coverage"] * 100)))
        return
    for f in best["features"]:
        f["name"] = "%s-%s" % (label, "bar" if f.get("bar") else ("hoop" if f.get("hoop") else f["kind"]))
        part = name_part(f)
        if part:
            f["part"] = part
        f["coverage"] = round(best["coverage"], 3)
        f["areaMM2"] = round(float(comp.area), 1)
        # The scan area this feature explains, the fit's share of the
        # piece split evenly among its features (the budget ranks by it).
        f["explainedMM2"] = round(float(comp.area) * best["coverage"] / len(best["features"]), 1)
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
    rest, small = [], []
    for c in comps:
        c = np.asarray(c)
        if len(c) >= 4:
            m = sub.submesh([c], append=True)
            # Worth another look: a twelfth of the piece, or a piece's
            # worth of scan by `main`'s own bar (a mug's lid lever is 7 %
            # of its handle piece).
            if m.area >= 150.0 and (m.area >= 0.08 * comp.area or m.area >= 1.5 * MIN_PIECE_AREA):
                rest.append(m)
            else:
                small.append(m.area)
    rest.sort(key=lambda m: -m.area)
    say("%s leaves %s%s" % (label, ", ".join("%.0f mm²" % m.area for m in rest) or "nothing worth a feature",
                            (" (and %d smaller: %s)" % (len(small), " ".join("%.0f" % a for a in sorted(small, reverse=True)[:6]))) if small else ""))
    for k, m in enumerate(rest[:3]):
        explain(m, tol, far, model_tree, depth + 1, out_features, unexplained, budget, "%s.%d" % (label, k + 1), fits)


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
                hs = [p[1] for p in f["profile"]]
                a, b = o + dd * min(hs), o + dd * max(hs)
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
    ap.add_argument("--analysis", default=None, help="profile.json, or the analysis folder holding it (for the body's axis; optional)")
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
    global BAR_MIN_AREA, BODY, MIN_PIECE_AREA
    BAR_MIN_AREA = max(400.0, 0.0025 * float(scan.area))
    MIN_PIECE_AREA = min_area
    if args.analysis:
        # `run_corpus.py` hands over the analysis FOLDER (the same path
        # build_hydrant.py takes); a file is the profile itself.
        path = os.path.join(args.analysis, "profile.json") if os.path.isdir(args.analysis) else args.analysis
        with open(path) as f:
            BODY = body_frame(json.load(f), far)
        if BODY is None:
            print("the analysis has no axis: hoops will not be looked for", flush=True)
    print("scan %d faces, model %d faces; far = %.1f mm, pieces ≥ %.0f mm², a bar explains ≥ %.0f mm²" % (
        len(scan.faces), len(model.faces), far, min_area, BAR_MIN_AREA), flush=True)
    model_tree = surface_tree(model)
    pieces, d = far_components(scan, model_tree, far, min_area)
    far_share = float((d > far).mean())
    print("%.1f%% of the scan's vertices are farther than %.1f mm from the model: %d piece%s" % (
        far_share * 100, far, len(pieces), "" if len(pieces) == 1 else "s"), flush=True)
    features, unexplained = [], []
    # Every piece is explained first; the feature budget is then spent on
    # the features that explain the most scan (coverage × the piece's
    # area), not on whichever pieces came first — three small bars on a
    # chain's links once spent the hydrant's last slots before its cap's
    # nut and its lugs were reached.
    budget = [10 ** 6]
    for k, comp in enumerate(pieces):
        label = "piece%d" % (k + 1)
        lo, hi = comp.bounds
        print("== %s: area %.0f mm², extent %s" % (label, comp.area, np.round(hi - lo, 0).tolist()), flush=True)
        # A sheet lying just beyond `far` all over (a wall thickness a few mm
        # off) is not a feature: the piece has to stand well proud somewhere.
        dv, _ = model_tree.query(np.asarray(comp.vertices, dtype=float))
        proud = float(np.percentile(dv, 95))
        if proud < max(2.0 * far, 12.0) or comp.area > 25.0 * proud * proud:
            # …unless it is a ring round the body's axis: a barrel's hoop
            # stands a centimetre proud all the way round and reads as a
            # sheet by area. Only the hoop fit is tried on such a piece —
            # a slab fitted to a squashed wall would be a lump.
            try:
                hoop = hoop_fit(comp, tol, far, model_tree) if BODY else None
            except Exception as error:  # noqa: BLE001 — one fit's failure is not the part's
                print("   %s: hoop fit failed: %s" % (label, str(error)[:120]), flush=True)
                hoop = None
            if hoop and hoop["coverage"] >= 0.3:
                explain(comp, tol, far, model_tree, 0, features, unexplained, budget, label, fits=("hoop",))
                continue
            unexplained.append(describe(comp, "a sheet %.0f–%.0f mm off the model over %.0f mm², not a feature" % (
                np.percentile(dv, 5), proud, comp.area)))
            print("   a sheet %.0f–%.0f mm off the model over %.0f mm² — the body's own surface, not a feature" % (
                np.percentile(dv, 5), proud, comp.area), flush=True)
            continue
        explain(comp, tol, far, model_tree, 0, features, unexplained, budget, label)
    if len(features) > args.max_features:
        ranked = sorted(range(len(features)), key=lambda i: -features[i]["explainedMM2"])
        keep = set(ranked[: args.max_features])
        for i in sorted(set(range(len(features))) - keep):
            f = features[i]
            unexplained.append({"why": "over the feature budget of %d: %s explains %.0f mm² of a %.0f mm² piece" % (
                args.max_features, f["name"], f["explainedMM2"], f["areaMM2"]),
                "areaMM2": f["areaMM2"], "name": f["name"]})
        print("feature budget: %d of %d kept, by the scan area each explains (dropped %s)" % (
            args.max_features, len(features), ", ".join(features[i]["name"] for i in sorted(set(range(len(features))) - keep))), flush=True)
        features = [f for i, f in enumerate(features) if i in keep]
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
