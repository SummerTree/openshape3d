#!/usr/bin/env python3
"""Read a 3D scan of a turned part (a fire hydrant, a vase, a bollard) and
work out the recipe a CAD model needs: where its axis is, its radial profile
height by height, and where the lumps that are not part of the revolution
(nozzles, caps, a nut) sit.

    python3 analyze_scan.py scan.glb --out analysis/

Writes `profile.json` (everything `build_hydrant.py` reads), `profile.png`
(the radius-by-height chart with the chosen polyline over it) and
`azimuth.png` (the radius around the axis at each height band, where the
nozzles show as bright blobs). Millimetres throughout; the scan's own units
are read from the file (glTF is metres).

Method, in the order it runs:

1. Orientation. A scan's world frame is the phone's, not the part's. The
   part's axis is found as the direction with the least spread of the
   vertices' positions — PCA's smallest principal component is wrong for a
   tall part, so the LARGEST component is taken for a part taller than it
   is wide, then refined: the axis is re-fitted through the centroids of
   thin slices along it, which a nozzle on one side barely moves.
2. Up or down. The wider end of a hydrant (the base flange) is the bottom;
   the scan's ground, if the scanner caught any of it, is a thin, wide
   disc of vertices at one end and is trimmed off first.
3. Profile. Vertices are binned by height; for each band the radius is the
   MEDIAN distance from the axis, which ignores the nozzles — a nozzle
   occupies a sixth of the circumference at most. The band's maximum and
   the azimuth where it occurs are kept too.
4. Lumps. Bands whose maximum radius exceeds the median by more than a
   margin are grouped into azimuth clusters; each cluster is a boss with a
   centre height, an azimuth, a reach (its maximum radius) and a width
   estimated from the angular span of the excess.
5. Polyline. The median profile is simplified (Douglas–Peucker in the
   (radius, height) plane) to the corners a revolve sketch wants.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

try:
    import trimesh
except ImportError:
    sys.exit("pip install trimesh numpy pillow  (or run with the scan_to_cad venv)")


def load_mesh(path, unit_scale=None):
    scene = trimesh.load(path, force="scene")
    meshes = [g for g in scene.geometry.values() if isinstance(g, trimesh.Trimesh)]
    if not meshes:
        sys.exit("no triangle mesh in " + path)
    # Apply node transforms so the vertices are in the file's world frame.
    placed = []
    for node in scene.graph.nodes_geometry:
        transform, geometry = scene.graph[node]
        part = scene.geometry[geometry]
        if isinstance(part, trimesh.Trimesh):
            placed.append(part.copy().apply_transform(transform))
    mesh = trimesh.util.concatenate(placed) if len(placed) > 1 else placed[0]
    ext = os.path.splitext(path)[1].lower()
    if unit_scale is None:
        # glTF/GLB are metres; USDZ centimetres; OBJ/STL guessed from size.
        if ext in (".glb", ".gltf"):
            unit_scale = 1000.0
        elif ext in (".usdz", ".usd", ".usda", ".usdc"):
            unit_scale = 10.0
        else:
            size = float(np.max(mesh.extents))
            unit_scale = 1000.0 if size < 5 else (10.0 if size < 50 else 1.0)
    mesh.apply_scale(unit_scale)
    return mesh, unit_scale


def principal_axis(points):
    centred = points - points.mean(axis=0)
    cov = centred.T @ centred / len(points)
    values, vectors = np.linalg.eigh(cov)
    return vectors[:, np.argmax(values)], vectors, values


def fit_circle(pu, pv, iterations=4, ransac=120, inlier_mm=2.5, seed=7):
    """Centre of a ring of points in the plane, ignoring the lumps on it:
    RANSAC picks the circle through three points that most points sit on
    (a nozzle's points never do), then an algebraic (Kåsa) fit on the
    inliers, re-run without far residuals. Returns (cu, cv, radius, the
    share of the points on the final circle)."""
    n = len(pu)
    rng = np.random.default_rng(seed)
    keep = np.ones(n, dtype=bool)
    if n >= 30:
        best = -1
        for _ in range(ransac):
            i, j, k = rng.choice(n, 3, replace=False)
            ax, ay, bx, by, cx, cy = pu[i], pv[i], pu[j], pv[j], pu[k], pv[k]
            d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
            if abs(d) < 1e-9:
                continue
            ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
            uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d
            rr = math.hypot(ax - ux, ay - uy)
            inliers = np.abs(np.hypot(pu - ux, pv - uy) - rr) < inlier_mm
            count = int(inliers.sum())
            if count > best:
                best, keep = count, inliers
        if best < 8:
            keep = np.ones(n, dtype=bool)
    cu = cv = r = 0.0
    for _ in range(iterations):
        u, v = pu[keep], pv[keep]
        if len(u) < 8:
            break
        A = np.column_stack([u, v, np.ones(len(u))])
        b = u * u + v * v
        sol, *_ = np.linalg.lstsq(A, b, rcond=None)
        cu, cv = sol[0] / 2, sol[1] / 2
        r = math.sqrt(max(sol[2] + cu * cu + cv * cv, 0))
        residual = np.hypot(pu - cu, pv - cv) - r
        mad = np.median(np.abs(residual[keep] - np.median(residual[keep]))) + 1e-6
        keep = np.abs(residual) < max(3 * 1.4826 * mad, 1.5)
    return cu, cv, r, float(keep.sum()) / max(n, 1)


def fit_axis(points, up_guess, iterations=4, bands=40):
    """Refine the axis as the line through the centres of slices along it;
    returns (point on axis, unit direction). Only the slices that are a
    clean ring vote — a barrel band, with most of its points on one circle
    of about the typical radius. A flange, the nozzle band and the dome
    give centres that are off by a nozzle or a bolt ring, and a line fit
    through all of them sat 12 mm beside the hydrant's barrel: every
    sector then read a different radius and no profile could be clean."""
    axis = up_guess / np.linalg.norm(up_guess)
    origin = points.mean(axis=0)
    for _ in range(iterations):
        h = (points - origin) @ axis
        lo, hi = np.percentile(h, 3), np.percentile(h, 97)
        edges = np.linspace(lo, hi, bands + 1)
        centroids, radii, shares = [], [], []
        for i in range(bands):
            sel = (h >= edges[i]) & (h < edges[i + 1])
            if sel.sum() < 30:
                continue
            ring = points[sel]
            # The centroid of a ring of vertices is biased toward the side
            # the scanner saw best, and toward a nozzle; a robust circle fit
            # through the ring is not.
            local = ring - origin
            perp = local - np.outer(local @ axis, axis)
            u = np.cross(axis, [1, 0, 0] if abs(axis[0]) < 0.9 else [0, 1, 0]); u /= np.linalg.norm(u)
            v = np.cross(axis, u)
            pu, pv = perp @ u, perp @ v
            cu, cv, rr, share = fit_circle(pu, pv)
            centroids.append(origin + cu * u + cv * v + axis * ((edges[i] + edges[i + 1]) / 2))
            radii.append(rr)
            shares.append(share)
        centroids, radii, shares = np.array(centroids), np.array(radii), np.array(shares)
        if len(centroids) < 3:
            break
        clean = shares > 0.5
        typical = float(np.median(radii[clean])) if clean.sum() >= 3 else float(np.median(radii))
        good = clean & (np.abs(radii - typical) < 0.15 * typical)
        if good.sum() < 3:
            good = np.ones(len(centroids), dtype=bool)
        voters = centroids[good]
        direction, _, _ = principal_axis(voters)
        if direction @ axis < 0:
            direction = -direction
        centre = voters.mean(axis=0)
        # Once more without the centres that still sit off the line.
        off = voters - centre
        dist = np.linalg.norm(off - np.outer(off @ direction, direction), axis=1)
        near = dist < max(3.0, 3 * np.median(dist) + 1e-6)
        if near.sum() >= 3:
            voters = voters[near]
            direction, _, _ = principal_axis(voters)
            if direction @ axis < 0:
                direction = -direction
            centre = voters.mean(axis=0)
        axis = direction
        origin = centre
    return origin, axis


def agreed_radius(values, window=3.0, previous=None, min_share=0.06, continuity_mm=6.0):
    """The centre of the densest cluster of `values`: the value most others
    sit within `window` of, then the median of that cluster. Ties go to the
    smaller value — a body, not a lump on it. With `previous` (the band
    below), a cluster that continues it wins over a denser one when it still
    holds a quarter of the sectors: at the nozzle band three caps and their
    flares fill most sectors at one radius, but the barrel is still there
    in the rest, and a barrel does not jump 100 mm between two bands. A
    flange does step — its cluster is not within `continuity_mm` of the
    band below, so the densest wins there as it should."""
    values = np.sort(np.asarray(values, dtype=float))

    def cluster_of(v):
        return values[(values >= v - window) & (values <= v + window)]

    best, best_count = values[0], -1
    for v in values:
        count = len(cluster_of(v))
        if count > best_count:
            best, best_count = v, count
    if previous is not None:
        near = values[np.argmin(np.abs(values - previous))]
        members = cluster_of(near)
        if abs(near - previous) <= continuity_mm and len(members) >= max(2, min_share * len(values)):
            return float(np.median(members))
    return float(np.median(cluster_of(best)))


def straighten(points, tol=3.0, min_run=4, step_ratio=3.0):
    """Design intent from a traced profile of (radius, height) points, one
    per band: a run of bands whose radii agree within ±`tol` is ONE
    vertical segment at their median (a cylinder), a jump in radius over
    little height is a horizontal step (a flange face), and what is left —
    a cone, a dome — keeps its points for the simplifier. A scan's noise
    is a millimetre or two; a revolve that follows it band by band comes
    out ridged where the part is smooth."""
    if len(points) < 3:
        return points
    radii = np.array([r for r, _ in points], dtype=float)
    heights = np.array([h for _, h in points], dtype=float)
    out = []
    i = 0
    n = len(points)
    while i < n:
        # Grow a run while every radius stays within tol of the run's median.
        j = i + 1
        while j < n:
            run = radii[i:j + 1]
            if np.abs(run - np.median(run)).max() <= tol:
                j += 1
            else:
                break
        # A run is a cylinder only when its radius has no trend: a dome or
        # a cone drifts a millimetre or two a band and stays within tol for
        # a few bands, and collapsing those runs cut the dome into terraces.
        third = max(1, (j - i) // 3)
        trend = abs(float(np.median(radii[j - third:j]) - np.median(radii[i:i + third]))) if j - i >= min_run else 0.0
        if j - i >= min_run and trend <= tol * 0.5:
            r = float(np.median(radii[i:j]))
            out.append((r, float(heights[i])))
            out.append((r, float(heights[j - 1])))
            i = j
        else:
            out.append((float(radii[i]), float(heights[i])))
            i += 1
    # Steps: a radius change several times the height it happens over is a
    # flange face — make it level, at the step's mid-height.
    snapped = [out[0]]
    for (r0, h0), (r1, h1) in zip(out, out[1:]):
        dr, dh = abs(r1 - r0), abs(h1 - h0)
        if dr > 8.0 and dr > step_ratio * dh and dh > 0:
            hm = (h0 + h1) / 2
            snapped.append((r0, hm))
            snapped.append((r1, hm))
        snapped.append((r1, h1))
    # Drop repeats.
    cleaned = [snapped[0]]
    for pt in snapped[1:]:
        if abs(pt[0] - cleaned[-1][0]) > 1e-6 or abs(pt[1] - cleaned[-1][1]) > 1e-6:
            cleaned.append(pt)
    return cleaned


def douglas_peucker(points, epsilon):
    if len(points) < 3:
        return points
    a, b = np.array(points[0]), np.array(points[-1])
    ab = b - a
    norm = np.linalg.norm(ab)
    if norm < 1e-9:
        d = np.linalg.norm(np.array(points) - a, axis=1)
    else:
        rel = np.array(points) - a
        d = np.abs(ab[0] * rel[:, 1] - ab[1] * rel[:, 0]) / norm
    i = int(np.argmax(d))
    if d[i] > epsilon:
        left = douglas_peucker(points[: i + 1], epsilon)
        right = douglas_peucker(points[i:], epsilon)
        return left[:-1] + right
    return [points[0], points[-1]]


def analyze(mesh, band_mm=4.0, lump_margin_mm=6.0, out_dir=None, name="scan", epsilon=1.5, debug=False):
    points = np.asarray(mesh.vertices, dtype=float)
    direction, _, values = principal_axis(points)
    origin, axis = fit_axis(points, direction)

    h = (points - origin) @ axis
    perp = (points - origin) - np.outer(h, axis)
    radius = np.linalg.norm(perp, axis=1)

    # Which way is up: the end with the larger radius is the base.
    lo, hi = np.percentile(h, 1), np.percentile(h, 99)
    span = hi - lo
    low_r = np.median(radius[h < lo + span * 0.08])
    high_r = np.median(radius[h > hi - span * 0.08])
    if low_r < high_r:
        axis = -axis
        h = -h
        perp = (points - origin) - np.outer(h, axis)
    # The scanner's ground: the bottom bands of a standing scan hold a flat
    # ring of sidewalk whose radii spread over a wide range, where a band of
    # the part itself is a thin ring. Trim every band up to the last wide one
    # among the first dozen.
    bottom = np.percentile(h, 0.5)
    edges = np.arange(bottom, h.max() + band_mm, band_mm)
    spread = []
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1])
        spread.append(np.percentile(radius[sel], 80) - np.percentile(radius[sel], 20) if sel.sum() >= 20 else np.nan)
    spread = np.array(spread)
    base_index = 0
    for i in range(min(12, len(spread))):
        if not np.isnan(spread[i]) and spread[i] > 60:
            base_index = i + 1
    base_h = edges[base_index]
    # The scan without its ground: every triangle whose corners all sit
    # above the trim. The comparison and the film use this copy, so the
    # sidewalk the scanner caught never counts against the model.
    cropped = None
    if base_index > 0:
        keep_v = h >= base_h
        faces = np.asarray(mesh.faces)
        cropped = mesh.copy()
        cropped.update_faces(keep_v[faces].all(axis=1))
        cropped.remove_unreferenced_vertices()
    keep = h >= base_h
    points, h, perp, radius = points[keep], h[keep] - base_h, perp[keep], radius[keep]
    origin = origin + axis * base_h

    # In-plane frame: u = azimuth 0 (toward the scan's +Z projected into the
    # plane), v = axis × u; azimuth measured from u toward v.
    ref = np.array([0.0, 0.0, 1.0])
    u = ref - (ref @ axis) * axis
    if np.linalg.norm(u) < 0.1:
        ref = np.array([1.0, 0.0, 0.0])
        u = ref - (ref @ axis) * axis
    u /= np.linalg.norm(u)
    v = np.cross(axis, u)
    azimuth = np.degrees(np.arctan2(perp @ v, perp @ u))

    height = float(h.max())
    edges = np.arange(0, height + band_mm, band_mm)
    sectors = 36
    sector_of = ((azimuth + 180) / (360 / sectors)).astype(int) % sectors
    bands = []
    grid_max = []      # per band: max radius per 10° sector (nan when empty)
    grid_med = []
    previous_body = None
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1])
        if sel.sum() < 12:
            continue
        r = radius[sel]
        sec = sector_of[sel]
        smax = np.full(sectors, np.nan)
        smed = np.full(sectors, np.nan)
        for j in range(sectors):
            rj = r[sec == j]
            if len(rj) >= 2:
                smax[j] = rj.max()
                smed[j] = np.median(rj)
        # The body radius of the band: what most sectors agree on — the
        # densest cluster of the sector medians (within ±3 mm), not a
        # percentile of them. At the nozzle band three nozzles, their flared
        # roots and the chains hanging from their caps fill well over half
        # the sectors, so even a low percentile climbed onto them and the
        # revolve grew rings the hydrant does not have; the clean sectors
        # still agree with each other to a millimetre, and the cluster
        # finds them however many sectors the lumps take.
        agreed = smed[~np.isnan(smed)]
        body = agreed_radius(agreed, previous=previous_body) if len(agreed) >= 4 else float(np.median(r))
        previous_body = body
        k = int(np.argmax(r))
        bands.append({"h": float((edges[i] + edges[i + 1]) / 2), "median": body,
                      "p20": float(np.percentile(r, 20)), "p80": float(np.percentile(r, 80)),
                      "max": float(r[k]), "maxAzimuth": float(azimuth[k]), "count": int(sel.sum())})
        grid_max.append(smax)
        grid_med.append(smed)
    grid_max = np.array(grid_max) if grid_max else np.zeros((0, sectors))
    # A spike of one or two bands between bands that agree is a cap's face
    # filling the sectors for 8 mm, not an 8 mm flange; the part continues.
    for width in (1, 2):
        for i in range(1, len(bands) - width):
            below, above = bands[i - 1]["median"], bands[i + width]["median"]
            here = [bands[k]["median"] for k in range(i, i + width)]
            if abs(below - above) <= 4 and all(abs(x - below) > 8 and abs(x - above) > 8 for x in here):
                for k in range(i, i + width):
                    bands[k]["median"] = (below + above) / 2
    body_r = np.array([b["median"] for b in bands])

    # Lumps: cells of the (band × sector) grid whose maximum stands proud of
    # the band's body radius, grouped into connected blobs (wrapping round in
    # azimuth). Each blob is a boss.
    proud = np.zeros_like(grid_max, dtype=bool)
    for i in range(len(bands)):
        proud[i] = (grid_max[i] - body_r[i]) > lump_margin_mm
    proud &= ~np.isnan(grid_max)
    # Watershed rather than plain connected components: two nozzles whose
    # flanks touch on the grid must stay two bosses. Cells are claimed in
    # order of excess, each joining a neighbouring region if one exists and
    # founding its own otherwise, so regions grow from their peaks outward
    # and never merge.
    excess_grid = np.where(proud, grid_max - body_r[:, None], 0.0)
    order = sorted(((excess_grid[i, j], i, j) for i in range(proud.shape[0]) for j in range(sectors) if proud[i, j]),
                   reverse=True)
    labels = -np.ones(proud.shape, dtype=int)
    blobs, peaks = [], []
    for cell_excess, i, j in order:
        touching = []
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ni, nj = i + di, (j + dj) % sectors
            if 0 <= ni < proud.shape[0] and labels[ni, nj] >= 0 and labels[ni, nj] not in touching:
                touching.append(labels[ni, nj])
        if not touching:
            labels[i, j] = len(blobs)
            blobs.append([(i, j)])
            peaks.append(cell_excess)
            continue
        joined = max(touching, key=lambda k: len(blobs[k]))
        # This cell is the highest point joining the regions it touches —
        # their saddle. A saddle nearly as high as the lower peak means one
        # lump with a noisy top; a low saddle means two neighbours.
        for other in touching:
            if other != joined and cell_excess >= 0.6 * min(peaks[joined], peaks[other]):
                for ci, cj in blobs[other]:
                    labels[ci, cj] = joined
                blobs[joined] += blobs[other]
                blobs[other] = []
                peaks[joined] = max(peaks[joined], peaks[other])
        labels[i, j] = joined
        blobs[joined].append((i, j))
    blobs = [b for b in blobs if b]
    bosses = []
    dropped = []
    for cells in blobs:
        if len(cells) < 4:
            continue
        peak_i, peak_j = max(cells, key=lambda c: excess_grid[c[0], c[1]])
        peak = excess_grid[peak_i, peak_j]
        tag = "blob %3d cells, peak +%.0f mm at h %.0f az %.0f" % (
            len(cells), peak, bands[peak_i]["h"], (peak_j + 0.5) * (360 / sectors) - 180)
        # The boss proper is the blob's core — cells at least half as proud
        # as its peak. A cap's chain hangs down the barrel as a thin trail
        # of faint cells and can tie the cap to a flange ring below; judged
        # on the core, the cap stays a boss and the ring stays a ring.
        cells = [c for c in cells if excess_grid[c[0], c[1]] >= 0.5 * peak]
        # A chain hangs from a cap's rim as far from the axis as the cap
        # itself, so it is in the core too — but it is one or two sectors
        # wide where the cap is many. Keep only the bands with a wide
        # presence; the centre height is then the cap's, not the chain's.
        per_band_core = {}
        for ci, cj in cells:
            per_band_core.setdefault(ci, set()).add(cj)
        wide = {ci for ci, s in per_band_core.items() if len(s) >= 3}
        cells = [c for c in cells if c[0] in wide]
        if len(cells) < 8:
            dropped.append(tag + " — a core of only %d cells" % len(cells))
            continue
        # A blob that runs round much of the circumference is a ring — a
        # flange step or the dome's shoulder straddling two bands, with
        # scanner holes breaking it into pieces — not a boss.
        per_band = {}
        for ci, cj in cells:
            per_band.setdefault(ci, set()).add(cj)
        if max(len(s) for s in per_band.values()) >= sectors * 0.45:
            dropped.append(tag + " — a ring in one band")
            continue
        if len(set(cj for ci, cj in cells)) >= sectors * 0.42:
            dropped.append(tag + " — spans %d sectors" % len(set(cj for ci, cj in cells)))
            continue
        excess = np.array([grid_max[ci, cj] - body_r[ci] for ci, cj in cells])
        angles = np.radians(np.array([(cj + 0.5) * (360 / sectors) - 180 for ci, cj in cells]))
        w = excess / excess.sum()
        # The boss is centred on its widest band — a cap fills many sectors,
        # the chain hanging from it one or two, and it reaches as far as the
        # cap does, so neither the farthest cell nor the blob's weighted
        # centre is safe from it.
        band_width = {ci: len(s) for ci, s in per_band_core.items() if ci in wide}
        widest = max(band_width, key=lambda ci: (band_width[ci], excess_grid[ci].max()))
        centre_h = float(bands[widest]["h"])
        az = math.degrees(math.atan2((np.sin(angles) * w).sum(), (np.cos(angles) * w).sum()))
        # Reach along the boss direction and width across it, from the raw
        # points within a cap's height of the centre.
        near = np.abs(h - centre_h) < 100.0
        da = (azimuth[near] - az + 180) % 360 - 180
        # As wide in azimuth as the lump itself plus a sector each side:
        # a fixed 60° reached the next nozzle's cap on a hydrant whose
        # nozzles sit 90° apart, and its points widened this one.
        half_span = len(set(cj for ci, cj in cells)) * (360 / sectors) / 2 + 360 / sectors
        near_idx = np.where(near)[0][np.abs(da) < max(15.0, half_span)]
        if len(near_idx) < 20:
            dropped.append(tag + " — too few points near it")
            continue
        # The boss points where its cap's face is: the farthest points from
        # the axis. A scanner sees a cap from the front, so the grid's
        # excess-weighted azimuth leans toward the side it captured; the
        # face's own mean direction does not.
        r_near = radius[near_idx]
        far = r_near >= np.percentile(r_near, 94)
        az_far = np.radians(azimuth[near_idx][far])
        az = math.degrees(math.atan2(np.sin(az_far).mean(), np.cos(az_far).mean()))
        d = math.cos(math.radians(az)) * u + math.sin(math.radians(az)) * v
        t = np.cross(axis, d)
        along = perp[near_idx] @ d
        across = perp[near_idx] @ t
        body_here = float(np.interp(centre_h, [b["h"] for b in bands], body_r))
        out = along > body_here + lump_margin_mm * 0.5
        if out.sum() < 20:
            dropped.append(tag + " — too few points proud of the body")
            continue
        reach = float(np.percentile(along[out], 95))
        protrusion = reach - body_here
        # The boss as a body of revolution about its own axis: its radius
        # slice by slice along that axis — a nozzle's flared casting, the
        # threads, the cap, the nut on the cap's face all come out as steps.
        # The radius is read across (horizontally): chains hang down from a
        # cap's rim, so a horizontal extent is clean where a vertical one is
        # not; and the scanner sees a cap from one side, so |across| is
        # taken, not the span between the two sides.
        inner = body_here - 12.0
        step = 8.0
        slices = []
        hh = h[near_idx]
        for lo in np.arange(inner, reach + step, step):
            m = (along >= lo) & (along < lo + step) & (np.abs(hh - centre_h) < 100)
            if m.sum() < 8:
                continue
            slices.append((float(lo + step / 2 - inner), float(np.percentile(np.abs(across[m]), 95))))
        if len(slices) < 3:
            dropped.append(tag + " — too few slices along it")
            continue
        if debug:
            print("slices az %.0f h %.0f (±%.0f°): %s" % (az, centre_h, max(15.0, half_span),
                                                          " ".join("%.0f@%.0f" % (rr, ss) for ss, rr in slices)))
        # The cap's rim and the barrel's own surface near the root cannot be
        # wider than the barrel; the nut on the face is the last slices.
        radii_along = np.array([r for _, r in slices])
        radii_along[0] = min(radii_along[0], radii_along[1])
        # Solidity: a cast boss fills its box on the (band × sector) grid; a
        # chain, or the eyelet it hangs from, is a thin line through it.
        rows = len(set(ci for ci, cj in cells))
        cols = len(set(cj for ci, cj in cells))
        solidity = len(cells) / float(max(rows * cols, 1))
        if debug:
            print("solidity az %.0f h %.0f: %d cells in %d×%d → %.2f" % (az, centre_h, len(cells), rows, cols, solidity))
        slices = [(s, float(r)) for (s, _), r in zip(slices, radii_along)]
        boss_profile = douglas_peucker([(r, s) for s, r in slices], epsilon=2.0)   # (radius, along)
        # Centre height: the boss's top edge minus its radius, since nothing
        # hangs above a nozzle but a chain hangs below it.
        neck_sel = out & (along > body_here + protrusion * 0.3) & (along < body_here + protrusion * 0.7)
        neck_r = float(np.interp(body_here + protrusion * 0.5 - inner, [s for s, _ in slices], [r for _, r in slices]))
        # The cap's face is a disc: the median height of its points is the
        # nozzle's centre. (The top edge minus the neck radius put the
        # pumper 20 mm low — its flared root is wider than its cap, and the
        # deviation preview showed the model missing the cap's top half.)
        # Only the bands where the lump is wide count, so the chain hanging
        # from the rim does not vote.
        wide_h = [bands[ci]["h"] for ci in wide]
        face_sel = out & (along > reach - 40.0) & (hh >= min(wide_h) - band_mm) & (hh <= max(wide_h) + band_mm)
        if face_sel.sum() >= 20:
            centre_h = float(np.median(hh[face_sel]))
        elif neck_sel.sum() >= 20:
            centre_h = float(np.percentile(hh[neck_sel], 97) - neck_r)
        width = 2 * float(max(r for _, r in slices[len(slices) // 2:]))
        neck = 2 * neck_r
        tall = 2 * neck_r
        bosses.append({"azimuthDeg": round(az, 1), "centerHeightMM": round(centre_h, 1),
                       "reachMM": round(reach, 1), "widthMM": round(width, 1), "neckWidthMM": round(neck, 1),
                       "heightSpanMM": round(tall, 1), "bodyRadiusMM": round(body_here, 1), "cells": len(cells),
                       "innerStartMM": round(inner, 1), "solidity": round(solidity, 2),
                       "profile": [[round(r, 2), round(s, 2)] for r, s in boss_profile]})
    # A boss has height: a ring of proud cells one or two bands tall is a
    # step in the profile caught between two bands, not a nozzle; and it is
    # about as tall as it is wide — a sliver of flange is wide and flat.
    kept = []
    band_h = np.array([b["h"] for b in bands])

    def shadow_radius(b):
        """The widest the body gets from the lump's foot to 40 mm above its
        top: a flange there casts the lump in its shadow."""
        lo, hi = b["centerHeightMM"] - b["heightSpanMM"] / 2, b["centerHeightMM"] + b["heightSpanMM"] / 2 + 40.0
        sel = (band_h >= lo) & (band_h <= hi)
        return float(body_r[sel].max()) if sel.any() else b["bodyRadiusMM"]

    for b in bosses:
        why = None
        if b["reachMM"] - b["bodyRadiusMM"] < 20:
            why = "protrudes %.0f mm" % (b["reachMM"] - b["bodyRadiusMM"])
        elif b["heightSpanMM"] < 3 * band_mm:
            why = "only %.0f mm tall" % b["heightSpanMM"]
        elif b["widthMM"] < 20:
            why = "only %.0f mm wide" % b["widthMM"]
        elif not (10 <= b["centerHeightMM"] <= height - 10):
            why = "centred at %.0f mm, off the part" % b["centerHeightMM"]
        elif b["profile"] and b["profile"][0][0] > b["bodyRadiusMM"] * 1.15:
            why = "starts %.0f mm wide at a %.0f mm body — a flange, not a boss" % (b["profile"][0][0] * 2, b["bodyRadiusMM"] * 2)
        elif b["reachMM"] < shadow_radius(b) + 30.0:
            # Bolts, eyelets and the chains hung from them sit just under a
            # flange and reach a little past its rim; a nozzle reaches far
            # beyond anything around it.
            why = "reaches %.0f mm under a %.0f mm flange — the flange's hardware, not a boss" % (b["reachMM"], shadow_radius(b))
        elif b["profile"] and b["neckWidthMM"] > 0 and b["profile"][0][0] > b["neckWidthMM"]:
            # A boss is roughly a cylinder: its root is about as wide as its
            # neck. A root twice the neck is a thin thing on a wide base —
            # a chain link, or a flange's underside caught in the band
            # below it — not a nozzle or a lug.
            why = "%.0f mm wide at the root but %.0f mm at the neck — a spike on a flange, not a boss" % (
                b["profile"][0][0] * 2, b["neckWidthMM"])
        if why:
            dropped.append("boss az %.0f h %.0f reach %.0f — %s" % (b["azimuthDeg"], b["centerHeightMM"], b["reachMM"], why))
        else:
            kept.append(b)
    bosses = kept
    if debug:
        for line in dropped:
            print("dropped:", line)
    bosses.sort(key=lambda b: -(b["reachMM"] - b["bodyRadiusMM"]))
    # A sliver the watershed split off a cap's rim (same azimuth, touching
    # heights) belongs to the boss beside it.
    merged = []
    for b in bosses:
        for m in merged:
            da = abs((b["azimuthDeg"] - m["azimuthDeg"] + 180) % 360 - 180)
            dh = abs(b["centerHeightMM"] - m["centerHeightMM"])
            if da < 45 and dh < (b["heightSpanMM"] + m["heightSpanMM"]) / 2 + 2 * band_mm:
                break
        else:
            merged.append(b)
    bosses = merged

    # The revolve starts where the scan has solid coverage: the bottom of a
    # standing scan thins out into the ground, and a few sparse bands there
    # would put the model's base where the scanner saw almost nothing.
    counts = np.array([b["count"] for b in bands])
    typical = float(np.median(counts[: max(8, len(counts) // 4)]))
    first = 0
    for i, b in enumerate(bands):
        if b["h"] > 150:
            break
        if counts[i] < 0.3 * typical:
            first = i + 1
    if first:
        bands = bands[first:]
        drop_h = bands[0]["h"] - band_mm / 2
        height -= drop_h
        for b in bands:
            b["h"] -= drop_h
        for b in bosses:
            b["centerHeightMM"] = round(b["centerHeightMM"] - drop_h, 1)
        origin = origin + axis * drop_h
    # Polyline for the revolve: (radius, height) from the body radii, with a
    # three-band running median against scanner noise, except where the
    # profile steps (a flange edge must stay sharp).
    radii = np.array([b["median"] for b in bands])
    smoothed = radii.copy()
    for i in range(1, len(radii) - 1):
        trio = radii[i - 1:i + 2]
        if trio.max() - trio.min() < 8:
            smoothed[i] = np.median(trio)
    profile = [(float(r), b["h"]) for r, b in zip(smoothed, bands)]
    # Cylinders as single segments, flanges as level steps, the rest to the
    # simplifier: the revolve is the part's design, not the scanner's noise.
    profile = straighten(profile, tol=max(2.5, epsilon * 1.5))
    if profile:
        profile = [(profile[0][0], 0.0)] + profile + [(profile[-1][0], height)]
    simplified = douglas_peucker(profile, epsilon=epsilon)

    analysis = {
        "name": name,
        "triangles": int(len(mesh.faces)), "vertices": int(len(mesh.vertices)),
        "axisOrigin": [float(x) for x in origin], "axisDirection": [float(x) for x in axis],
        "azimuthZero": [float(x) for x in u], "azimuthNinety": [float(x) for x in v],
        "heightMM": round(height, 2),
        "maxRadiusMM": round(float(radius.max()), 2),
        "bodyRadiusMM": round(float(np.median([b["median"] for b in bands])), 2),
        "bands": bands,
        "profile": [[round(r, 2), round(hh, 2)] for r, hh in simplified],
        "bosses": bosses,
        "boundsMM": {"min": [float(x) for x in mesh.bounds[0]], "max": [float(x) for x in mesh.bounds[1]]},
    }
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        if cropped is not None:
            # glTF is metres by definition, so every consumer (the app, Blender,
            # trimesh) reads it the same way; the photo texture travels inside.
            scaled = cropped.copy()
            scaled.apply_scale(0.001)
            path = os.path.join(out_dir, "scan_cropped.glb")
            try:
                scaled.export(path)
                analysis["croppedScan"] = path
                analysis["groundTrimmedMM"] = round(float(base_h - bottom), 1)
            except Exception as error:  # noqa: BLE001 — a texture the exporter cannot carry
                scaled.visual = trimesh.visual.ColorVisuals()
                scaled.export(path)
                analysis["croppedScan"] = path
                analysis["groundTrimmedMM"] = round(float(base_h - bottom), 1)
                print("cropped scan written without its texture:", error)
        with open(os.path.join(out_dir, "profile.json"), "w") as f:
            json.dump(analysis, f, indent=1)
        try:
            chart(analysis, bands, h, radius, azimuth, out_dir)
        except ImportError:
            pass
    return analysis


def chart(analysis, bands, h, radius, azimuth, out_dir):
    from PIL import Image, ImageDraw

    W, H = 900, 1100
    im = Image.new("RGB", (W, H), (250, 250, 252))
    d = ImageDraw.Draw(im)
    height = analysis["heightMM"]
    rmax = analysis["maxRadiusMM"] * 1.1
    sx = (W - 120) / rmax
    sy = (H - 120) / height

    def pt(r, hh):
        return 60 + r * sx, H - 60 - hh * sy

    for b in bands:
        d.line([pt(b["p20"], b["h"]), pt(b["p80"], b["h"])], fill=(180, 200, 240), width=3)
        d.ellipse([pt(b["max"], b["h"])[0] - 2, pt(b["max"], b["h"])[1] - 2,
                   pt(b["max"], b["h"])[0] + 2, pt(b["max"], b["h"])[1] + 2], fill=(240, 150, 60))
    d.line([pt(b["median"], b["h"]) for b in bands], fill=(60, 110, 220), width=2)
    d.line([pt(r, hh) for r, hh in analysis["profile"]], fill=(20, 20, 20), width=3)
    for r, hh in analysis["profile"]:
        x, y = pt(r, hh)
        d.ellipse([x - 4, y - 4, x + 4, y + 4], outline=(20, 20, 20), fill=(255, 255, 255), width=2)
    d.text((60, 20), "radius by height: blue = median (p20–p80 bar), orange = max, black = revolve polyline",
           fill=(40, 40, 40))
    d.text((60, 40), "height %.0f mm, body radius %.1f mm, %d bosses" % (height, analysis["bodyRadiusMM"], len(analysis["bosses"])),
           fill=(40, 40, 40))
    im.save(os.path.join(out_dir, "profile.png"))

    # Azimuth map: height × azimuth, brightness = radius above the band median.
    AW, AH = 720, 600
    am = Image.new("RGB", (AW, AH), (255, 255, 255))
    px = am.load()
    nb = max(len(bands), 1)
    grid = np.zeros((nb, 72))
    for i, b in enumerate(bands):
        sel = np.abs(h - b["h"]) < 2.5
        az = ((azimuth[sel] + 180) / 5).astype(int) % 72
        np.maximum.at(grid[i], az, radius[sel] - b["median"])
    top = max(float(grid.max()), 1.0)
    for y in range(AH):
        i = min(int((AH - 1 - y) / AH * nb), nb - 1)
        for x in range(AW):
            j = int(x / AW * 72)
            v = max(0.0, grid[i, j]) / top
            px[x, y] = (int(255 - 200 * v), int(255 - 120 * v), int(255 - 30 * v))
    dd = ImageDraw.Draw(am)
    for boss in analysis["bosses"]:
        x = (boss["azimuthDeg"] + 180) / 360 * AW
        y = AH - boss["centerHeightMM"] / height * AH
        dd.ellipse([x - 8, y - 8, x + 8, y + 8], outline=(200, 30, 30), width=2)
        dd.text((x + 10, y - 6), "%.0f° h%.0f r%.0f" % (boss["azimuthDeg"], boss["centerHeightMM"], boss["reachMM"]), fill=(120, 0, 0))
    dd.text((8, 8), "azimuth −180…180° across, height up; colour = radius above the band median", fill=(40, 40, 40))
    am.save(os.path.join(out_dir, "azimuth.png"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scan")
    ap.add_argument("--out", default="analysis")
    ap.add_argument("--units", type=float, default=None, help="mm per file unit (default: by format)")
    ap.add_argument("--band", type=float, default=4.0, help="height band, mm")
    ap.add_argument("--epsilon", type=float, default=1.5, help="polyline simplification, mm (2–3 for a noisy scan)")
    ap.add_argument("--debug", action="store_true", help="say why each candidate lump was dropped")
    args = ap.parse_args()
    mesh, scale = load_mesh(args.scan, args.units)
    name = os.path.splitext(os.path.basename(args.scan))[0]
    a = analyze(mesh, band_mm=args.band, out_dir=args.out, name=name, epsilon=args.epsilon, debug=args.debug)
    print("scan: %d triangles, %.0f mm tall, body radius %.1f mm (file units x%g)" % (
        a["triangles"], a["heightMM"], a["bodyRadiusMM"], scale))
    print("axis origin", np.round(a["axisOrigin"], 1), "direction", np.round(a["axisDirection"], 3))
    print("profile points:", len(a["profile"]))
    for b in a["bosses"]:
        print("boss at %6.1f° height %5.1f reach %5.1f width %5.1f neck %5.1f profile %s" % (
            b["azimuthDeg"], b["centerHeightMM"], b["reachMM"], b["widthMM"], b["neckWidthMM"],
            " ".join("%.0f@%.0f" % (r, s) for r, s in b.get("profile", []))))
    print("wrote", os.path.join(args.out, "profile.json"))


if __name__ == "__main__":
    main()
