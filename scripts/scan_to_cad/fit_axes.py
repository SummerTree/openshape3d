#!/usr/bin/env python3
"""The revolve axes of a scan — all of them.

A valve is a vertical body with a horizontal pipe through it, a branch off
the pipe and a side port: four bodies of revolution on four axes. One axis
and one profile cannot describe it (the pipe revolved about the body's axis
is a drum; the body revolved about the pipe's is a cone), so the tracer
needs to know every axis and which part of the scan belongs to each.

The axes come from the surface normals. On a cylinder every normal is
perpendicular to the axis, so the cross product of two normals on the same
cylinder points along it: nearby point pairs vote for a direction on the
sphere, and each surface of revolution with a cylindrical stretch makes a
peak (`direction_peaks`). For a direction, every normal line crosses the
axis, so projected along the direction the normal lines meet at the axis's
point: a second vote, in the plane, finds it (`position_peaks`). Each
candidate is then refined on its inliers — the points whose normal line
passes within a tolerance of the axis, which also admits the cones and
domes coaxial with the cylinder (`refine`) — and the axes are kept in
order of how much of the scan they explain (`find_axes`).

    python3 fit_axes.py scan.glb [--units 1000] [--out dir]

prints the axes and draws the scan's points coloured by axis.
"""
import argparse
import math
import os
import sys

import numpy as np
import trimesh
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from analyze_scan import axis_quality, fit_axis as ring_fit_axis, load_mesh  # noqa: E402


def unit(v):
    v = np.asarray(v, dtype=float)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def sample_with_normals(mesh, n, seed=11):
    """Surface samples (area-weighted) with their faces' normals, plus the
    vertices with theirs: the Hough wants an even coverage of the surface,
    not the scanner's triangle density."""
    pts, face = trimesh.sample.sample_surface(mesh, int(n), seed=seed)
    normals = np.asarray(mesh.face_normals, dtype=float)[face]
    return np.asarray(pts, dtype=float), normals, np.asarray(face)


def line_line_distance(p, n, c, d):
    """Distance between each normal line (p, n) and the axis line (c, d);
    inf where the normal is parallel to the axis (an end face says nothing
    about where the axis is)."""
    w = np.cross(d, n)
    wn = np.linalg.norm(w, axis=1)
    with np.errstate(invalid="ignore", divide="ignore"):
        dist = np.abs(((p - c) * w).sum(axis=1)) / wn
    dist[wn < 1e-6] = np.inf
    return dist, wn


# ---- the direction vote ------------------------------------------------------

def direction_peaks(points, normals, pair_radius, cell_deg=2.0, pairs_per_point=4, top=12, seed=5):
    """Directions many normal pairs are perpendicular to: the axes of the
    scan's cylinders. Returns [(direction, votes)] strongest first, with a
    non-maximum suppression of 3 cells."""
    rng = np.random.default_rng(seed)
    tree = cKDTree(points)
    n = len(points)
    # Pairs: each point with a few random neighbours within pair_radius.
    idx = tree.query_ball_point(points, pair_radius)
    a_list, b_list = [], []
    for i, nb in enumerate(idx):
        if len(nb) < 2:
            continue
        nb = np.asarray(nb)
        pick = rng.choice(nb, size=min(pairs_per_point, len(nb)), replace=False)
        pick = pick[pick != i]
        a_list.append(np.full(len(pick), i))
        b_list.append(pick)
    if not a_list:
        return []
    a = np.concatenate(a_list)
    b = np.concatenate(b_list)
    cross = np.cross(normals[a], normals[b])
    mag = np.linalg.norm(cross, axis=1)
    # Nearly parallel normals (a flat face, or two points along one
    # generator of a cylinder) say nothing about the direction.
    keep = mag > math.sin(math.radians(4.0))
    cross = cross[keep] / mag[keep][:, None]
    # One hemisphere: flip to z ≥ 0 (then y ≥ 0 on the equator, x ≥ 0 on y = 0).
    flip = (cross[:, 2] < 0) | ((cross[:, 2] == 0) & (cross[:, 1] < 0)) | (
        (cross[:, 2] == 0) & (cross[:, 1] == 0) & (cross[:, 0] < 0))
    cross[flip] *= -1
    # Equal-area-ish bins: rings of theta, each split into round(360 sin θ / cell) cells.
    theta = np.degrees(np.arccos(np.clip(cross[:, 2], -1, 1)))      # 0 at the pole (z), 90 at the equator
    phi = np.degrees(np.arctan2(cross[:, 1], cross[:, 0])) % 360.0
    n_rings = int(math.ceil(90.0 / cell_deg))
    ring = np.minimum((theta / cell_deg).astype(int), n_rings - 1)
    ring_cells = np.array([max(1, int(round(360.0 * math.sin(math.radians((k + 0.5) * cell_deg)) / cell_deg)))
                           for k in range(n_rings)])
    ring_offset = np.concatenate([[0], np.cumsum(ring_cells)[:-1]])
    cell = ring_offset[ring] + np.minimum((phi / 360.0 * ring_cells[ring]).astype(int), ring_cells[ring] - 1)
    counts = np.bincount(cell, minlength=int(ring_cells.sum()))
    # Cell centres, for the suppression and the output.
    centres = np.zeros((len(counts), 3))
    for k in range(n_rings):
        th = math.radians((k + 0.5) * cell_deg)
        for j in range(ring_cells[k]):
            ph = math.radians((j + 0.5) * 360.0 / ring_cells[k])
            centres[ring_offset[k] + j] = [math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th)]
    total = float(counts.sum())
    # Smooth over the neighbouring cells (1.5 cells): a peak on a cell
    # boundary — the equator, or φ = 0 — splits four ways otherwise.
    near_cos = math.cos(math.radians(1.5 * cell_deg))
    smoothed = ((np.abs(centres @ centres.T) > near_cos) * counts[None, :]).sum(axis=1)
    order = np.argsort(smoothed)[::-1]
    if os.environ.get("AXES_DEBUG"):
        print("direction vote: %d pairs in %d cells; top cells (smoothed):" % (int(total), len(counts)))
        for c in order[:12]:
            print("   %6d  %s" % (smoothed[c], np.round(centres[c], 3)))
    peaks = []
    # Distinct directions only: a noisy scan's main axis peaks again 7–10°
    # off and would fill the list with itself, leaving no room for a short
    # branch's own direction.
    suppress_cos = math.cos(math.radians(6 * cell_deg))
    for c in order:
        if smoothed[c] <= 0 or len(peaks) >= top:
            break
        if smoothed[c] < 0.0025 * total:
            break
        if any(abs(centres[c] @ p) > suppress_cos for p, _ in peaks):
            continue
        near = np.where(np.abs(centres @ centres[c]) > near_cos)[0]
        signs = np.sign(centres[near] @ centres[c])
        mean = (centres[near] * (counts[near] * signs)[:, None]).sum(axis=0)
        peaks.append((unit(mean) if np.linalg.norm(mean) > 1e-9 else centres[c], int(smoothed[c])))
    return peaks


# ---- the position vote -------------------------------------------------------

def plane_basis(d):
    e1 = unit(np.cross(d, [0, 0, 1.0]) if abs(d[2]) < 0.9 else np.cross(d, [1.0, 0, 0]))
    e2 = np.cross(d, e1)
    return e1, e2


def position_peaks(points, normals, d, cell_mm, reach, top=3, side_cos=0.35):
    """Where, in the plane across `d`, the normal lines of the points that
    face across `d` meet: a vote along each projected normal line (both
    ways — a scan's normals are not all outward). Returns [(point on the
    axis, votes)] strongest first; peaks closer than 6 cells merge."""
    e1, e2 = plane_basis(d)
    side = np.abs(normals @ d) < side_cos
    if side.sum() < 50:
        return []
    p = points[side]
    m = np.column_stack([normals[side] @ e1, normals[side] @ e2])
    mn = np.linalg.norm(m, axis=1)
    ok = mn > 1e-6
    p, m = p[ok], m[ok] / mn[ok][:, None]
    q = np.column_stack([p @ e1, p @ e2])
    lo = q.min(axis=0) - reach
    hi = q.max(axis=0) + reach
    shape = np.maximum(((hi - lo) / cell_mm).astype(int) + 1, 1)
    acc = np.zeros(shape, dtype=np.int32)
    steps = np.arange(-reach, reach + cell_mm, cell_mm)
    for t in steps:
        pos = q + t * m
        ij = ((pos - lo) / cell_mm).astype(int)
        inside = (ij[:, 0] >= 0) & (ij[:, 0] < shape[0]) & (ij[:, 1] >= 0) & (ij[:, 1] < shape[1])
        np.add.at(acc, (ij[inside, 0], ij[inside, 1]), 1)
    # Smooth a little (a 3×3 box) so a peak straddling cells still wins.
    from scipy.ndimage import uniform_filter, maximum_filter
    sm = uniform_filter(acc.astype(float), size=3, mode="constant")
    maxima = (sm == maximum_filter(sm, size=int(6), mode="constant")) & (sm > 0)
    cand = np.argwhere(maxima)
    vals = sm[maxima]
    order = np.argsort(vals)[::-1]
    peaks = []
    for k in order[: top * 3]:
        i, j = cand[k]
        centre = lo + (np.array([i, j]) + 0.5) * cell_mm
        if any(np.linalg.norm(centre - c2) < 6 * cell_mm for c2, _ in peaks):
            continue
        peaks.append((centre, float(vals[k])))
        if len(peaks) >= top:
            break
    # Back to 3D: a point on the axis (at the points' mean height along d).
    h0 = float((points @ d).mean())
    return [(e1 * c[0] + e2 * c[1] + d * h0, v) for c, v in peaks]


# ---- refinement --------------------------------------------------------------

def inliers_of(points, normals, c, d, tol):
    """Points whose normal line passes within `tol` of the axis — the
    surfaces of revolution about it — leaving out the faces that look
    along the axis (their normal line is parallel to it, or nearly: an end
    face, a shelf) since they would pass the test anywhere."""
    dist, wn = line_line_distance(points, normals, c, d)
    return (dist < tol) & (wn > math.sin(math.radians(8.0)))


def refine(points, normals, c, d, tol, rounds=3):
    """Alternate a least-squares axis point for the inliers' normal lines
    with the ring-centre direction fit (`analyze_scan.fit_axis`): the
    normal lines give the position to a fraction of a millimetre, the ring
    centres hold the direction when the normals are noisy."""
    c = np.asarray(c, dtype=float)
    d = unit(d)
    sel = inliers_of(points, normals, c, d, tol)
    for _ in range(rounds):
        if sel.sum() < 30:
            break
        p, n = points[sel], normals[sel]
        # Minimise Σ ((p − c)·w)² over c ⊥ d, with w = d × n̂ (the normal
        # to the plane through the axis and the normal line).
        w = np.cross(d, n)
        wn = np.linalg.norm(w, axis=1)
        w = w / wn[:, None]
        e1, e2 = plane_basis(d)
        A = np.column_stack([w @ e1, w @ e2])
        b = (p * w).sum(axis=1)
        sol, *_ = np.linalg.lstsq(A, b, rcond=None)
        c = e1 * sol[0] + e2 * sol[1] + d * float((p @ d).mean())
        # Direction from the ring centres of the inliers.
        try:
            c2, d2 = ring_fit_axis(p, d, iterations=3, bands=30)
            if d2 @ d < 0:
                d2 = -d2
            if math.degrees(math.acos(min(1.0, abs(d2 @ d)))) < 6.0:
                d = unit(d2)
                c = c + d * 0.0
        except Exception:  # noqa: BLE001 — too few rings; keep the direction
            pass
        new = inliers_of(points, normals, c, d, tol)
        if new.sum() < 30:
            break
        sel = new
    dist, _ = line_line_distance(points, normals, c, d)
    return c, d, sel, dist


def ring_bins(points, c, d, bin_mm, tol, sectors=24):
    """The inliers sliced along the axis. Per bin: its centre height, the
    ring radius (what most sectors agree on), the ring's outer radius, a
    ring flag and the mask of the bin's points that sit on the ring.

    A normal line through the axis is a loose test: a flat face whose
    plane holds the axis direction (a nut's side, a block's wall) and the
    skin of another body that the axis happens to cross both pass it in
    stripes. A ring is tighter — most sectors round the axis see the same
    radius: the medians of at least ten of 24 sectors within a few
    tolerances (or 12 %) of their common value — and only the points at
    that radius are the body's."""
    p = np.asarray(points, dtype=float)
    h = (p - c) @ d
    perp = (p - c) - np.outer(h, d)
    r = np.linalg.norm(perp, axis=1)
    e1, e2 = plane_basis(d)
    az = np.arctan2(perp @ e2, perp @ e1)
    sector = ((az + math.pi) / (2 * math.pi) * sectors).astype(int) % sectors
    lo, hi = float(h.min()), float(h.max())
    edges = np.arange(lo, hi + bin_mm, bin_mm)
    rows = []
    for i in range(len(edges) - 1):
        m = (h >= edges[i]) & (h < edges[i + 1])
        centre = (edges[i] + edges[i + 1]) / 2
        if m.sum() < 15:
            rows.append((centre, np.nan, np.nan, False, np.zeros(len(p), dtype=bool)))
            continue
        idx = np.where(m)[0]
        meds = []
        for k in range(sectors):
            sk = idx[sector[idx] == k]
            if len(sk) >= 3:
                meds.append(float(np.median(r[sk])))
        if len(meds) < 10:
            rows.append((centre, float(np.median(r[idx])), float(np.percentile(r[idx], 90)), False,
                         np.zeros(len(p), dtype=bool)))
            continue
        meds = np.array(meds)
        ring_r = float(np.median(meds))
        # How far the sectors may disagree and still be one ring: the
        # tolerance, but never more than 30 % of the radius — the
        # tolerance is the scan's, set by a hydrant-sized diagonal, and
        # would let a flat lever 8 mm thick pass for a 14 mm bar.
        reach = max(0.12 * ring_r, min(2.0 * tol, 0.3 * ring_r))
        agree = np.abs(meds - ring_r) <= reach
        if agree.sum() >= 2:
            ring_r = float(np.median(meds[agree]))
        agree = np.abs(meds - ring_r) <= reach
        on_ring = np.zeros(len(p), dtype=bool)
        members = idx[np.abs(r[idx] - ring_r) <= reach]
        on_ring[members] = True
        outer = float(np.percentile(r[members], 95)) if len(members) else ring_r
        rows.append((centre, ring_r, outer, bool(agree.sum() >= 10), on_ring))
    return rows, h


def longest_run(flags, max_gap=1):
    """[start, end) of the longest run of True with at most `max_gap`
    consecutive False inside it."""
    best, start, gap, run_start = (0, 0), None, 0, None
    for i, f in enumerate(list(flags) + [False]):
        if f:
            if run_start is None:
                run_start = i
            gap = 0
            if i + 1 - run_start > best[1] - best[0]:
                best = (run_start, i + 1)
        elif run_start is not None:
            gap += 1
            if gap > max_gap:
                run_start, gap = None, 0
    return best


def axis_summary(points, c, d, tol, bin_mm=None):
    """Where along the axis the inliers are rings: from the first ring bin
    to the last (a body keeps its rings across the band where a pipe
    joins it), plus up to two bins of inliers beyond each end for a
    wheel's rim or a flange at the very end. Returns the extent, the
    envelope (per bin: height, outer radius, ring radius), the mask of the
    points on rings (`onRing`), the mask within the extent (`inRun`) and
    the roundness — the share of the extent's points that sit on a ring.
    None when there are not two ring bins."""
    p = np.asarray(points, dtype=float)
    if bin_mm is None:
        h_all = (p - c) @ d
        bin_mm = max(2.0, min(10.0, (h_all.max() - h_all.min()) / 30.0))
    rows, h = ring_bins(p, c, d, bin_mm, tol)
    flags = [row[3] for row in rows]
    rings = [i for i, f in enumerate(flags) if f]
    if len(rings) < 2:
        return None
    populated = [i for i, row in enumerate(rows) if not np.isnan(row[1])]
    a = max(rings[0] - 2, populated[0]) if populated else rings[0]
    b = min(rings[-1] + 2, populated[-1]) + 1 if populated else rings[-1] + 1
    lo, hi = rows[a][0] - bin_mm / 2, rows[b - 1][0] + bin_mm / 2
    in_run = (h >= lo) & (h <= hi)
    on_ring = np.zeros(len(p), dtype=bool)
    for row in rows[a:b]:
        if row[3]:
            on_ring |= row[4]
    envelope = []
    for i in range(a, b):
        row = rows[i]
        if row[3]:
            envelope.append([float(row[0]), float(row[2]), float(row[1])])
        else:
            # Not a ring (a rim with its hub, a bin the pipe interrupts):
            # the nearest ring's radii stand in.
            j = min(rings, key=lambda k: abs(k - i))
            envelope.append([float(row[0]), float(rows[j][2]), float(rows[j][1])])
    radii = [row[1] for row in rows[a:b] if row[3]]
    return {"hMin": float(lo), "hMax": float(hi), "lengthMM": float(hi - lo),
            "radiusMM": float(np.median(radii)) if radii else float("nan"),
            "envelope": envelope, "inRun": in_run, "onRing": on_ring,
            "roundness": float(on_ring.sum() / max(in_run.sum(), 1)), "binMM": bin_mm}


def inside_body(points, axis, tol):
    """Points of an accepted body or within it: no farther from its axis
    than the envelope's outer radius plus a tolerance, within its extent.
    The skin counts: a branch's axis runs on through the pipe it leaves,
    where the pipe's skin, cut obliquely, would pass for rings."""
    c, d = np.asarray(axis["origin"]), np.asarray(axis["direction"])
    h = (points - c) @ d
    r = np.linalg.norm((points - c) - np.outer(h, d), axis=1)
    env = np.asarray(axis["envelope"])
    r_env = np.interp(h, env[:, 0], env[:, 1])
    return (h >= axis["hMin"] - tol) & (h <= axis["hMax"] + tol) & (r < r_env + tol)


def passes_through(c, d, h_lo, h_hi, bodies, tol):
    """The first body the axis is inside somewhere between h_lo and h_hi
    (two side nozzles share one axis through the barrel), as (body index,
    h where it enters), else None."""
    for k, body in enumerate(bodies):
        bc, bd = np.asarray(body["origin"]), np.asarray(body["direction"])
        env = np.asarray(body["envelope"])
        for h in np.arange(h_lo, h_hi, max(1.0, tol)):
            p = c + d * h
            hb = float((p - bc) @ bd)
            if hb < body["hMin"] or hb > body["hMax"]:
                continue
            rb = float(np.linalg.norm((p - bc) - hb * bd))
            if rb <= float(np.interp(hb, env[:, 0], env[:, 1])):
                return (k, float(h), 0.0)
    return None


def continues_beyond(points, c, d, h_end, outward, r, tol, need=30):
    """Is there scan surface straight on past this end — within 1.2 radius
    of the axis, from a tolerance to half a radius beyond it? A pipe's
    free end has air beyond it; a mug handle's straight arm runs on into
    its bend, and is no body of revolution."""
    h = (points - c) @ d
    along = (h - h_end) * outward
    near = (along > tol) & (along < 0.5 * r + 2 * tol)
    if near.sum() < need:
        return False
    perp = np.linalg.norm((points[near] - c) - np.outer(h[near], d), axis=1)
    return int((perp <= 1.2 * r + tol).sum()) >= need


def junction(c, d, h_end, outward, r_sec, bodies, tol):
    """Does the axis, followed from the end at `h_end` in the direction
    `outward` × d for up to 0.8 radius, enter one of `bodies`? Returns
    (body index, h where it enters) or None. A pipe runs into the body it
    feeds; a hose alongside a tank never enters it."""
    best = None
    for k, body in enumerate(bodies):
        bc, bd = np.asarray(body["origin"]), np.asarray(body["direction"])
        env = np.asarray(body["envelope"])
        for step in np.arange(0.0, 0.8 * r_sec + 2 * tol, max(0.5, tol / 2)):
            p = c + d * (h_end + outward * step)
            hb = float((p - bc) @ bd)
            if hb < body["hMin"] or hb > body["hMax"]:
                continue
            rb = float(np.linalg.norm((p - bc) - hb * bd))
            if rb <= float(np.interp(hb, env[:, 0], env[:, 1])):
                if best is None or step < best[2]:
                    best = (k, h_end + outward * step, step, float(np.interp(hb, env[:, 0], env[:, 2])))
                break
    return best


def propose_axes(mesh, samples=60000, tol_mm=None, verbose=False):
    """Every axis the scan might have: the direction votes (plus the
    principal directions), the position votes for each, each candidate
    refined on its inliers. Returns the pool: the samples, the tolerance
    and the candidates as (point, direction, inlier mask, normal-line
    distances, close count)."""
    points, normals, faces = sample_with_normals(mesh, samples)
    diag = float(np.linalg.norm(mesh.bounds[1] - mesh.bounds[0]))
    if tol_mm is None:
        # The tolerance for a normal line to count as crossing the axis: a
        # few millimetres on a hand-sized part, more on a hydrant (scanner
        # noise tilts normals by a few degrees over a radius of 100 mm).
        tol_mm = float(min(12.0, max(1.5, 0.012 * diag)))
    pair_radius = max(4.0, 0.08 * diag)
    dirs = direction_peaks(points, normals, pair_radius)
    if verbose:
        for d, v in dirs:
            print("direction %s: %d votes" % (np.round(d, 3), v))
    # The principal directions join the candidates: a barrel-shaped mug or
    # a dished wheel has no cylinder for the normal pairs to vote with, but
    # its normal lines still meet on its axis.
    centred = points - points.mean(axis=0)
    _, _, vt = np.linalg.svd(centred[:: max(1, len(centred) // 20000)], full_matrices=False)
    for pd in vt:
        if not any(abs(pd @ d) > math.cos(math.radians(6.0)) for d, _ in dirs):
            dirs.append((unit(pd), 0))
    candidates = []
    for d, votes in dirs:
        for c, v in position_peaks(points, normals, d, cell_mm=max(1.0, 0.006 * diag), reach=0.5 * diag):
            if verbose:
                print("  candidate: direction %s through %s, %.0f votes" % (np.round(d, 3), np.round(c, 1), v))
            c2, d2, sel, dist = refine(points, normals, c, d, tol_mm)
            # How many points the axis explains closely (half the
            # tolerance): a vertical line through a point on a tilted
            # branch's axis passes the loose test on a slice of the
            # branch, the branch's own axis on all of it.
            close = int((sel & (dist < 0.5 * tol_mm)).sum())
            if verbose:
                print("  refined: direction %s through %s, %d inliers, %d close" % (
                    np.round(d2, 3), np.round(c2, 1), int(sel.sum()), close))
            if sel.sum() < 100:
                continue
            candidates.append((c2, d2, sel, dist, close))
    candidates.sort(key=lambda t: -t[4])
    return {"points": points, "normals": normals, "faces": faces, "tolMM": tol_mm, "candidates": candidates,
            "diagMM": diag}


def _axis_record(c, d, summary, fresh, n_points, tol_mm, parent, parent_end):
    mid_h = 0.5 * (summary["hMin"] + summary["hMax"])
    mid = c + d * mid_h
    return {"origin": [float(x) for x in mid], "direction": [float(x) for x in d],
            "count": int(fresh.sum()), "share": float(fresh.sum() / n_points),
            "tolMM": tol_mm, "hMin": summary["hMin"] - mid_h, "hMax": summary["hMax"] - mid_h,
            "lengthMM": summary["lengthMM"], "radiusMM": summary["radiusMM"],
            "roundness": summary["roundness"],
            "envelope": [[e[0] - mid_h, e[1], e[2]] for e in summary["envelope"]],
            "parent": None if parent is None else int(parent[0]),
            "junction": None if parent is None else parent_end,
            "junctionH": None if parent is None else float(parent[1] - mid_h),
            "junctionParentRadiusMM": None if (parent is None or len(parent) < 4) else float(parent[3])}


def select_axes(pool, main=None, min_share=0.008, min_points=300, max_axes=8, verbose=False):
    """The bodies among the pool's candidates, strongest first. With
    `main` = (point, direction) that axis is the first body whatever the
    candidates say (the tracer's own choice of main axis); otherwise the
    candidate explaining most points is. Every later body is judged on
    the points OUTSIDE the bodies already accepted — a branch's axis runs
    on into the pipe it leaves, where the pipe's skin, cut obliquely,
    would pass for rings; the twin side nozzles of a hydrant share one
    axis through the barrel, whose crossing band is no ring at all — and
    has to show rings of its own there, mostly unclaimed, and an end that
    runs into an accepted body. Best-first: at each step every remaining
    candidate is judged afresh and the one with most fresh ring points is
    taken (a line parallel to the barrel through a cap's chain explains
    more normals than the nozzle's own axis, but fewer rings)."""
    points, normals, tol_mm = pool["points"], pool["normals"], pool["tolMM"]
    n = len(points)
    axes = []
    claimed = np.zeros(n, dtype=bool)
    inside_any = np.zeros(n, dtype=bool)
    remaining = list(pool["candidates"])
    if main is not None:
        c, d = np.asarray(main[0], dtype=float), unit(main[1])
        sel = inliers_of(points, normals, c, d, tol_mm)
        summary = axis_summary(points[sel], c, d, tol_mm) if sel.sum() >= 30 else None
        if summary is not None:
            on_ring = np.zeros(n, dtype=bool)
            on_ring[np.where(sel)[0]] = summary["onRing"]
            axes.append(_axis_record(c, d, summary, on_ring, n, tol_mm, None, None))
            claimed |= on_ring
            inside_any |= inside_body(points, axes[-1], tol_mm)
            # The candidates that are this axis found again drop out.
            remaining = [t for t in remaining if not (abs(t[1] @ d) > math.cos(math.radians(3.0)) and
                                                     np.linalg.norm(np.cross(t[0] - c, d)) < 2 * tol_mm)]
    while remaining and len(axes) < max_axes:
        best = None
        for t in remaining:
            c, d, sel, dist, close = t
            own = sel & ~inside_any
            if own.sum() < min_points:
                continue
            summary = axis_summary(points[own], c, d, tol_mm)
            if summary is None:
                continue
            in_run = np.zeros(n, dtype=bool)
            in_run[np.where(own)[0]] = summary["inRun"]
            on_ring = np.zeros(n, dtype=bool)
            on_ring[np.where(own)[0]] = summary["onRing"]
            fresh = on_ring & ~claimed
            parent, parent_end = None, None
            if axes:
                r_sec = summary["radiusMM"]
                at_start = junction(c, d, summary["hMin"], -1.0, r_sec, axes, tol_mm)
                at_end = junction(c, d, summary["hMax"], +1.0, r_sec, axes, tol_mm)
                through = passes_through(c, d, summary["hMin"], summary["hMax"], axes, tol_mm)
                if at_start is None and at_end is None and through is None:
                    if verbose:
                        print("  axis %s through %s: %d own points, %.0f mm long, radius %.1f — runs into nothing, not a body" % (
                            np.round(d, 3), np.round(c, 1), int(fresh.sum()), summary["lengthMM"], r_sec))
                    continue
                if at_start is not None or at_end is not None:
                    parent = at_start if (at_end is None or (at_start is not None and at_start[2] <= at_end[2])) else at_end
                    parent_end = "start" if parent is at_start else "end"
                else:
                    # Through a body: rings on both sides of it (a hydrant's
                    # twin side nozzles), not a bar laid across its top.
                    h_own = (points[on_ring] - c) @ d
                    before, after = int((h_own < through[1]).sum()), int((h_own > through[1]).sum())
                    if min(before, after) < 0.2 * max(len(h_own), 1):
                        if verbose:
                            print("  axis %s through %s: %d own points, %.0f mm long, radius %.1f — crosses A%d with rings on one side only, not a body" % (
                                np.round(d, 3), np.round(c, 1), int(fresh.sum()), summary["lengthMM"], r_sec, through[0]))
                        continue
                    parent, parent_end = through, "through"
                # A free end must be free: surface straight on past it means
                # a bend (a handle's arm), not a body of revolution.
                free_bad = False
                for h_end, outward, taken in ((summary["hMin"], -1.0, at_start), (summary["hMax"], +1.0, at_end)):
                    if taken is None and continues_beyond(points, c, d, h_end, outward, r_sec, tol_mm):
                        free_bad = True
                if free_bad:
                    if verbose:
                        print("  axis %s through %s: %d own points, %.0f mm long, radius %.1f — the scan runs on past its free end, not a body" % (
                            np.round(d, 3), np.round(c, 1), int(fresh.sum()), summary["lengthMM"], r_sec))
                    continue
            if verbose:
                print("  axis %s through %s: %d fresh of %d own points in the run, %.0f mm long, radius %.1f, roundness %.2f%s" % (
                    np.round(d, 3), np.round(c, 1), int(fresh.sum()), int(in_run.sum()), summary["lengthMM"],
                    summary["radiusMM"], summary["roundness"],
                    "" if parent is None else ", runs into A%d at its %s" % (parent[0], parent_end)))
            if fresh.sum() < max(min_points, min_share * n):
                continue
            if fresh.sum() < 0.6 * in_run.sum():
                continue
            if summary["lengthMM"] < max(12.0, 0.6 * summary["radiusMM"]):
                continue
            if summary["roundness"] < 0.7:
                continue
            if best is None or fresh.sum() > best[0]:
                best = (int(fresh.sum()), t, summary, on_ring, parent, parent_end)
        if best is None:
            break
        _, t, summary, on_ring, parent, parent_end = best
        c, d = t[0], t[1]
        axes.append(_axis_record(c, d, summary, on_ring & ~claimed, n, tol_mm, parent, parent_end))
        claimed |= on_ring
        inside_any |= inside_body(points, axes[-1], tol_mm)
        remaining = [r for r in remaining if r is not t]
        if verbose:
            print("  -> A%d" % (len(axes) - 1))
    labels = assign(points, normals, axes, tol_mm)
    return {"axes": axes, "labels": labels, "points": points, "normals": normals, "faces": pool["faces"],
            "tolMM": tol_mm}


def find_axes(mesh, samples=60000, tol_mm=None, main=None, verbose=False, **kw):
    """`propose_axes` then `select_axes` (see both)."""
    pool = propose_axes(mesh, samples=samples, tol_mm=tol_mm, verbose=verbose)
    return select_axes(pool, main=main, verbose=verbose, **kw)


def assign(points, normals, axes, tol_mm):
    """Each point's axis: the one its normal line crosses with the smallest
    residual among the axes whose radius envelope reaches it there; a point
    no normal line claims (a hex nut's flat, a chain) goes to the axis
    whose envelope it sits closest under. −1 when none admits it."""
    n = len(points)
    if not axes:
        return -np.ones(n, dtype=int)
    best = np.full(n, np.inf)
    labels = -np.ones(n, dtype=int)
    fallback = np.full(n, np.inf)
    fallback_label = -np.ones(n, dtype=int)
    for k, ax in enumerate(axes):
        c, d = np.asarray(ax["origin"]), np.asarray(ax["direction"])
        h = (points - c) @ d
        r = np.linalg.norm((points - c) - np.outer(h, d), axis=1)
        env = np.asarray(ax["envelope"])
        if len(env) == 0:
            continue
        r_env = np.interp(h, env[:, 0], env[:, 1])
        within = (h >= ax["hMin"] - 2 * tol_mm) & (h <= ax["hMax"] + 2 * tol_mm) & (r <= 1.25 * r_env + tol_mm)
        dist, wn = line_line_distance(points, normals, c, d)
        score = dist / tol_mm
        # A later (weaker) body takes a point from an earlier one only
        # when it explains the normal clearly better: on the barrel's own
        # skin the side nozzles' axis passes as close as the barrel's
        # along two stripes, and the skin is the barrel's.
        ok = within & (score < 1.0) & (wn > math.sin(math.radians(8.0))) & (score < best - 0.25)
        best[ok] = score[ok]
        labels[ok] = k
        # Fallback: at most a little outside the ring's own radius (a hex
        # nut's flats round a pipe), by how far under it the point sits.
        r_ring = np.interp(h, env[:, 0], env[:, 2])
        ratio = np.where(within & (r <= 1.15 * r_ring + tol_mm), r / np.maximum(r_ring, 1e-6), np.inf)
        fb = (ratio < fallback)
        fallback[fb] = ratio[fb]
        fallback_label[fb] = k
    none = labels < 0
    labels[none] = fallback_label[none]
    return labels


def label_faces(mesh, result):
    """Each face's axis (−1 = none), by its centroid and normal, with the
    same rule the samples got."""
    centroids = np.asarray(mesh.triangles_center, dtype=float)
    normals = np.asarray(mesh.face_normals, dtype=float)
    return assign(centroids, normals, result["axes"], result["tolMM"])


def debug_image(result, path, size=900):
    """Three projections of the samples coloured by axis."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return
    pts, labels = result["points"], result["labels"]
    palette = [(230, 80, 60), (60, 140, 230), (70, 190, 110), (240, 170, 40), (170, 90, 220), (40, 200, 200)]
    img = Image.new("RGB", (size * 3, size), (24, 26, 30))
    draw = ImageDraw.Draw(img)
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    span = float((hi - lo).max())
    for v, (a, b) in enumerate(((0, 1), (2, 1), (0, 2))):
        for i in range(0, len(pts), max(1, len(pts) // 40000)):
            x = (pts[i, a] - lo[a]) / span * (size - 60) + 30 + v * size
            y = size - 30 - (pts[i, b] - lo[b]) / span * (size - 60)
            col = palette[labels[i] % len(palette)] if labels[i] >= 0 else (110, 110, 110)
            draw.point((x, y), fill=col)
        for k, ax in enumerate(result["axes"]):
            c, d = np.asarray(ax["origin"]), np.asarray(ax["direction"])
            p0, p1 = c + d * ax["hMin"], c + d * ax["hMax"]
            xy = [((p[a] - lo[a]) / span * (size - 60) + 30 + v * size, size - 30 - (p[b] - lo[b]) / span * (size - 60))
                  for p in (p0, p1)]
            draw.line(xy, fill=(255, 255, 255), width=2)
            draw.text((xy[0][0] + 4, xy[0][1] + 4), "A%d" % k, fill=(255, 255, 255))
    img.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scan")
    ap.add_argument("--units", type=float, default=None, help="mm per file unit (default: by format)")
    ap.add_argument("--samples", type=int, default=60000)
    ap.add_argument("--out", default=None)
    ap.add_argument("--axis", default=None, help="seed the main axis as analyze_scan.choose_axis would (auto, largest, x,y,z or x,y,z!)")
    args = ap.parse_args()
    mesh, _ = load_mesh(args.scan, args.units)
    main = None
    if args.axis:
        from analyze_scan import choose_axis
        origin, direction, q = choose_axis(np.asarray(mesh.vertices, dtype=float), args.axis)
        print("main axis from choose_axis(%s): %s through %s, quality %s" % (args.axis, np.round(direction, 3), np.round(origin, 1), q))
        main = (origin, direction)
    result = find_axes(mesh, samples=args.samples, main=main, verbose=True)
    print("tolerance %.2f mm" % result["tolMM"])
    for k, ax in enumerate(result["axes"]):
        print("A%d: %5.1f%% of the surface, direction %s through %s, %.0f mm long, radius ~%.1f mm%s" % (
            k, 100 * ax["share"], np.round(ax["direction"], 3), np.round(ax["origin"], 1), ax["lengthMM"], ax["radiusMM"],
            "" if ax["parent"] is None else ", into A%d at its %s" % (ax["parent"], ax["junction"])))
    unassigned = float((result["labels"] < 0).mean())
    print("unassigned: %.1f%%" % (100 * unassigned))
    if args.out:
        os.makedirs(args.out, exist_ok=True)
        debug_image(result, os.path.join(args.out, "axes.png"))
        import json
        with open(os.path.join(args.out, "axes.json"), "w") as f:
            json.dump({"tolMM": result["tolMM"], "axes": result["axes"]}, f, indent=1)


if __name__ == "__main__":
    main()
