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

1. Orientation. A scan's world frame is the phone's, not the part's. Each
   of the three principal directions of the vertices is tried as the axis
   and refined (re-fitted through the centres of thin slices along it,
   which a nozzle on one side barely moves); the one whose slices are the
   roundest wins — the tall direction for a hydrant or a bottle, the thin
   one for a wheel, and for a bucket the direction its handle's arch
   pulled PCA away from. `--axis largest|middle|smallest|X,Y,Z` forces it.
2. Up or down. The wider end of a hydrant (the base flange) is the bottom;
   `--flip` says otherwise (an extinguisher's hose makes its top the wide
   end). The scan's ground, if the scanner caught any of it, is a thin,
   wide disc of vertices at one end and is trimmed off first.
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fit_primitives import arcs_in_polyline  # noqa: E402


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


def widest_gap_deg(angles_deg, sector=10.0):
    """The widest empty arc around a slice, in degrees: 0 for a ring seen
    all round, ~160 for the two short arcs a handle leaves in a slice."""
    n = int(round(360.0 / sector))
    occupied = np.zeros(n, dtype=bool)
    occupied[(np.floor((np.asarray(angles_deg) + 180.0) / sector).astype(int)) % n] = True
    if occupied.all():
        return 0.0
    if not occupied.any():
        return 360.0
    # Rotate so the run starts on an occupied sector, then the longest run of empties.
    first = int(np.argmax(occupied))
    rolled = np.roll(occupied, -first)
    longest = run = 0
    for o in rolled:
        run = 0 if o else run + 1
        longest = max(longest, run)
    return longest * sector


def fit_axis(points, up_guess, iterations=10, bands=40):
    """Refine the axis as the line through the centres of slices along it;
    returns (point on axis, unit direction). Only the slices that are a
    clean ring vote — a barrel band, with most of its points on one circle
    of about the typical radius, seen most of the way round. A flange, the
    nozzle band and the dome give centres that are off by a nozzle or a
    bolt ring, and a line fit through all of them sat 12 mm beside the
    hydrant's barrel: every sector then read a different radius and no
    profile could be clean. A slice through a pail's handle is two short
    arcs, and a circle through both passes the share test with a perfect
    score — its centre is nowhere near the axis, and those slices had the
    fit bouncing between 4° and 17° off; a ring must have no empty arc
    wider than 120° to vote (the same rule the body's top uses)."""
    axis = up_guess / np.linalg.norm(up_guess)
    origin = points.mean(axis=0)
    for _ in range(iterations):
        h = (points - origin) @ axis
        lo, hi = np.percentile(h, 3), np.percentile(h, 97)
        edges = np.linspace(lo, hi, bands + 1)
        centroids, radii, shares, gaps = [], [], [], []
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
            gaps.append(widest_gap_deg(np.degrees(np.arctan2(pv - cv, pu - cu))))
        centroids, radii, shares, gaps = np.array(centroids), np.array(radii), np.array(shares), np.array(gaps)
        if len(centroids) < 3:
            break
        clean = (shares > 0.5) & (gaps <= 120.0)
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


def axis_quality(points, origin, axis, bands=40):
    """How much of the part is round about this axis: the share of all the
    vertices that sit on their slice's fitted circle, over the slices that
    hold enough of them. A hydrant about its own axis scores ~0.8; the
    same hydrant sliced across scores ~0.2."""
    h = (points - origin) @ axis
    lo, hi = np.percentile(h, 3), np.percentile(h, 97)
    edges = np.linspace(lo, hi, bands + 1)
    u = np.cross(axis, [1, 0, 0] if abs(axis[0]) < 0.9 else [0, 1, 0]); u /= np.linalg.norm(u)
    v = np.cross(axis, u)
    on_circle, counted = 0.0, 0
    for i in range(bands):
        sel = (h >= edges[i]) & (h < edges[i + 1])
        if sel.sum() < 30:
            continue
        local = points[sel] - origin
        perp = local - np.outer(local @ axis, axis)
        _, _, _, share = fit_circle(perp @ u, perp @ v)
        on_circle += share * sel.sum()
        counted += int(sel.sum())
    return on_circle / counted if counted else 0.0


def choose_axis(points, choice="auto", extra=None, axis_origin=None):
    """The part's axis: every principal direction refined by `fit_axis`,
    the roundest kept (see `axis_quality`); or the one `choice` names.
    `extra` are more candidates, as (point, direction) pairs already
    refined (the axis finder's), tried as they are when no principal
    direction is clean (quality under 0.75 — a valve, whose principal
    direction is the diagonal between its body and its pipe). With
    `axis_origin` and a fixed direction ("x,y,z!") nothing is fitted.
    Returns (origin, axis, {candidate: quality})."""
    if axis_origin is not None and choice not in ("auto", "largest", "middle", "smallest") and choice.endswith("!"):
        axis = np.array([float(x) for x in choice.rstrip("!").split(",")])
        axis /= np.linalg.norm(axis)
        origin = np.asarray(axis_origin, dtype=float)
        return origin, axis, {choice: axis_quality(points, origin, axis)}
    _, vectors, values = principal_axis(points)
    order = np.argsort(values)[::-1]
    candidates = {"largest": vectors[:, order[0]], "middle": vectors[:, order[1]], "smallest": vectors[:, order[2]]}
    if choice not in ("auto", "largest", "middle", "smallest"):
        # "x,y,z" is refined from that start; "x,y,z!" is kept as given (a
        # valve body whose branch and stem drag every refinement onto the
        # diagonal between them), only the origin fitted: the centre of
        # the clean ring slices along it.
        fixed = choice.endswith("!")
        guess = np.array([float(x) for x in choice.rstrip("!").split(",")])
        guess /= np.linalg.norm(guess)
        if not fixed:
            origin, axis = fit_axis(points, guess)
            return origin, axis, {choice: axis_quality(points, origin, axis)}
        axis = guess
        origin, _ = fit_axis(points, guess, iterations=1)
        # The refinement's first pass moved the origin onto the ring centres;
        # keep that origin, discard its direction.
        origin = origin - ((origin - points.mean(axis=0)) @ axis) * axis + ((origin - points.mean(axis=0)) @ axis) * axis
        return origin, axis, {choice: axis_quality(points, origin, axis)}
    tried = {}
    for name, guess in candidates.items():
        if choice != "auto" and name != choice:
            continue
        origin, axis = fit_axis(points, guess)
        tried[name] = (axis_quality(points, origin, axis), origin, axis)
    best = max(tried, key=lambda k: tried[k][0])
    if choice == "auto" and extra and tried[best][0] < 0.75:
        for i, (c, d) in enumerate(extra):
            c, d = np.asarray(c, dtype=float), np.asarray(d, dtype=float)
            tried["axes%d" % i] = (axis_quality(points, c, d), c, d / np.linalg.norm(d))
        better = max(tried, key=lambda k: tried[k][0])
        if tried[better][0] > tried[best][0] + 0.03:
            best = better
    return tried[best][1], tried[best][2], {k: round(q, 3) for k, (q, _, _) in tried.items()}


def agreed_radius(values, window=3.0, previous=None, min_share=0.06, continuity_mm=6.0, sector_medians=None):
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
    if previous is not None and sector_medians is not None:
        # A cluster that runs round most of the circle in one piece is a
        # ring — a hand-wheel's rim above a thin stem — and the band's
        # radius, continuity or not. Three nozzle caps fill as many
        # sectors, but in three pieces with the barrel between them.
        sm = np.asarray(sector_medians, dtype=float)
        on = np.abs(sm - best) <= window
        on[np.isnan(sm)] = False
        if on.any() and not on.all():
            runs, run = [], 0
            doubled = np.concatenate([on, on])
            for flag in doubled:
                run = run + 1 if flag else 0
                runs.append(run)
            longest = min(max(runs), int(on.sum()))
        else:
            longest = int(on.sum())
        if longest >= 0.5 * len(sm):
            return float(np.median(cluster_of(best)))
    if previous is not None:
        near = values[np.argmin(np.abs(values - previous))]
        members = cluster_of(near)
        # A lobed flange (bolt lugs round a bonnet) splits its sectors
        # between the lobes and the hollows, 8–14 mm apart on a 110 mm
        # ring: the band keeps the radius the band below settled on rather
        # than flipping between the two every millimetre.
        reach = max(continuity_mm, 0.08 * previous)
        if abs(near - previous) <= reach and len(members) >= max(2, min_share * len(values)):
            return float(np.median(members))
    return float(np.median(cluster_of(best)))


def straighten(points, tol=3.0, min_run=4, step_ratio=3.0, step_min=8.0):
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
        if dr > step_min and dr > step_ratio * dh and dh > 0:
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


def detect_open_top(mesh, origin, axis, u, v, height, radii_ends, bands, radius, h, grid=12, facing=None):
    """Is the part a container open at one end? Rays along the axis from
    just outside each end, over a disc of 0.7 × that end's radius.

    What a ray meets says what the end is. On a closed end it hits the
    skin at once, FRONT face toward it. Into a bucket it falls to the
    floor's inside — a front face, deep in — or out through the floor
    when the scanner never saw one (a pail scanned on a table has no
    floor at all), so a lost ray counts as open too. But a scan trimmed
    at the ground has a hole there as well, and rays from that side cross
    the hole and hit the inside of the part's own top: a BACK face, deep
    in — that is a solid with a hole, not a container, and the end is
    not open. An end is open when 60 % of its rays are deep-front or
    lost and few hit shallow; with both ends open the wider one is the
    rim and the other gets the floor. `radii_ends` is (radius at h = 0,
    radius at the top). Returns None, or
    {end: "top"|"bottom", depthMM, share, wallMM, innerRadiusMM}."""
    if height < 30:
        return None
    lift = 20.0
    offsets = np.linspace(-0.7, 0.7, grid)
    found = []
    for end, r_end in (("top", radii_ends[1]), ("bottom", radii_ends[0])):
        if r_end < 10:
            continue
        start_h = height + lift if end == "top" else -lift
        direction = -axis if end == "top" else axis
        origins, dirs = [], []
        for x in offsets:
            for y in offsets:
                if x * x + y * y <= 0.49:
                    origins.append(origin + axis * start_h + (u * x + v * y) * r_end)
                    dirs.append(direction)
        origins, dirs = np.array(origins), np.array(dirs)
        try:
            locations, index_ray, index_tri = mesh.ray.intersects_location(origins, dirs, multiple_hits=False)
        except Exception:  # noqa: BLE001 — no ray support for this mesh
            return None
        deep_limit = lift + max(0.15 * height, 25.0)
        lost = len(origins) - len(index_ray)
        if len(index_ray):
            locations = np.asarray(locations, dtype=float).reshape(-1, 3)
            travelled = (locations - origins[index_ray]) @ direction
            front = (mesh.face_normals[index_tri] @ direction) < 0
            deep_front = int(((travelled > deep_limit) & front).sum())
            shallow_front = int(((travelled <= deep_limit) & front).sum())
        else:
            travelled = np.zeros(0)
            deep_front = shallow_front = 0
        share = (lost + deep_front) / float(len(origins))
        if share >= 0.6 and shallow_front < 0.2 * len(origins):
            deep_vals = travelled[travelled > deep_limit]
            # The floor is where the deepest tenth of the rays stop: a
            # drum's bottom is a recessed disc inside a raised chime ring.
            depth = float(np.percentile(deep_vals, 90) - lift) if len(deep_vals) else height
            found.append((end, r_end, share, depth))
    if not found:
        return None
    end, r_end, share, depth = max(found, key=lambda f: f[1])      # the wider open end is the rim
    # Wall thickness: a little in from the rim (the rim itself may carry a
    # lip or the handle's lugs), the inner surface is the second population
    # of radii in a band — a wall thickness inside the body radius. No
    # inner population (the scanner never saw inside) means a guess.
    band_mm = bands[-1]["h"] - bands[-2]["h"] if len(bands) > 1 else 4.0
    rim_h = bands[-1]["h"] if end == "top" else bands[0]["h"]
    inward = -1 if end == "top" else 1
    # Well clear of the rim: a drum's rolled lip is 14 mm thick where its
    # wall is 5, so the window starts 30 mm in and runs to 80 mm.
    span_in = min(0.25 * height, 200.0)
    lo, hi = sorted((rim_h + inward * max(2 * band_mm, 0.4 * span_in), rim_h + inward * max(7 * band_mm, span_in)))
    window = [b["median"] for b in bands if lo <= b["h"] <= hi]
    body = float(np.median(window)) if window else r_end
    sel = (h > lo) & (h < hi)
    wall = None
    if facing is not None:
        # The wall is the gap between the points facing out and the points
        # facing in: a point's normal says which side of the skin it is on.
        outer_pts = radius[sel & (facing > 0.3)]
        inner_pts = radius[sel & (facing < -0.3)]
        if len(outer_pts) >= 30 and len(inner_pts) >= 30:
            wall = float(np.median(outer_pts) - np.median(inner_pts))
    if wall is None:
        inner = radius[sel & (radius < body - 1.0) & (radius > 0.5 * body)]
        if sel.sum() >= 30 and len(inner) >= 0.1 * sel.sum():
            wall = body - float(np.median(inner))
        else:
            wall = 3.0
    wall = float(min(max(wall, 1.5), 15.0))
    return {"end": end, "depthMM": round(depth, 1), "share": round(share, 3),
            "wallMM": round(wall, 2), "innerRadiusMM": round(r_end - wall, 2)}


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


def estimate_noise(h, radius, azimuth, band=2.0, sectors=36):
    """The scanner's noise, in mm: on the bands that are a cylinder (the
    agreed radius does not move between neighbours) the radii inside one
    band × sector cell spread by nothing but noise — half their 16–84 %
    range, the median over those cells and bands. A low-poly scan reads
    0.0 and its profile is traced to the half-millimetre; a photogrammetry
    hydrant reads a millimetre or two and its profile is smoothed and
    straightened as before. With no cylinder bands at all (a pure dome)
    the spread of the sector medians stands in."""
    edges = np.arange(0, h.max() + band, band)
    sec = ((azimuth + 180) / (360 / sectors)).astype(int) % sectors
    rows = []
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1])
        if sel.sum() < 36:
            continue
        r, s = radius[sel], sec[sel]
        meds, spreads = [], []
        for j in range(sectors):
            rj = r[s == j]
            if len(rj) >= 4:
                meds.append(float(np.median(rj)))
                spreads.append(float(np.percentile(rj, 84) - np.percentile(rj, 16)) / 2)
        if len(meds) < 12:
            continue
        rows.append((agreed_radius(meds), np.array(meds), np.array(spreads)))
    cells, fallback = [], []
    for k in range(1, len(rows) - 1):
        body, meds, spreads = rows[k]
        close = np.abs(meds - body) < 3.0
        if close.sum() < 12:
            continue
        fallback.append(float(np.median(np.abs(meds[close] - body))) * 1.48)
        if abs(body - rows[k - 1][0]) < 0.5 and abs(body - rows[k + 1][0]) < 0.5:
            cells.append(float(np.median(spreads[close])))
    if len(cells) >= 3:
        return float(np.median(cells))
    if fallback:
        return float(np.median(fallback))
    return 1.0


def surface_grid(h, radius, azimuth, cell, sectors=24, min_share=0.35, n_radial=None, n_axial=None):
    """Every point collapsed to (r, h): a cell of that grid is SURFACE of
    the body of revolution when points reach it from at least `min_share`
    of the azimuth sectors (a bracket or a handle fills a few sectors and
    is left out). Rows are h, columns r. With the points' normals split
    into radial and axial parts, returns (surface, normals (H, R, 2)): the
    mean outward normal of each surface cell in the (r, h) plane."""
    r_cells = int(radius.max() / cell) + 2
    h_cells = int(h.max() / cell) + 2
    ri = np.clip((radius / cell).astype(int), 0, r_cells - 1)
    hi = np.clip((h / cell).astype(int), 0, h_cells - 1)
    si = ((azimuth + 180) / (360.0 / sectors)).astype(int) % sectors
    seen = np.zeros((h_cells, r_cells, sectors), dtype=bool)
    seen[hi, ri, si] = True
    surface = seen.sum(axis=2) >= min_share * sectors
    if n_radial is None:
        return surface
    flat = hi * r_cells + ri
    sum_r = np.bincount(flat, weights=n_radial, minlength=h_cells * r_cells).reshape(h_cells, r_cells)
    sum_h = np.bincount(flat, weights=n_axial, minlength=h_cells * r_cells).reshape(h_cells, r_cells)
    normals = np.stack([sum_r, sum_h], axis=-1)
    length = np.linalg.norm(normals, axis=-1, keepdims=True)
    normals = np.where(length > 1e-9, normals / np.maximum(length, 1e-9), 0.0)
    return surface, normals


def is_dished(surface, cell, min_gap_mm=20.0):
    """One radius per height cannot describe this part: some row of the
    surface grid holds two separate runs of ring cells with a gap wider
    than `min_gap_mm` (and five cells) between them — a tyre and a hub,
    a cup standing in a cup. A wall's two skins are a cell or two apart
    and do not count."""
    gap_cells = max(5, int(min_gap_mm / cell))
    hits = 0
    for row in surface:
        idx = np.flatnonzero(row)
        if len(idx) < 2:
            continue
        gaps = np.diff(idx)
        if (gaps > gap_cells).any():
            hits += 1
            if hits >= 3:
                return True
    return False


def find_windows(h, radius, azimuth, cell, n_radial, n_axial, min_share=0.65, sectors=24, min_gap_mm=6.0, max_gap_mm=60.0, min_rows=3,
                 spoke_sectors=48):
    """Where one radius per height is a disc but the part is a wheel: rows
    of the (r, h) grid that hold a run of ring cells near the axis (the
    hub) and, past a gap of 6–60 mm that fewer than 65 % of the sectors
    reach (only the spokes), another run (the rim). Consecutive such rows
    with the same gap are a window — the annulus between hub and rim over
    those heights — and the spokes are where the points in that annulus
    are: the runs of sectors holding at least 30 % of the busiest sector's
    points. What lies between the spokes are the openings, for the build
    to cut out of the revolve (each a partial revolve of the annulus,
    half a sector short of the spokes on each side). The hub must face
    OUT: a bore's wall faces in, and the solid between a bore and the
    outer skin is no window. A solid flange has no hub run beside it and
    keeps its disc; a thin wall's two skins are a cell or two apart and
    do not count; a disc with no spokes to speak of (fewer than two) is
    left alone. Returns [{h0, h1, rInnerMM, rOuterMM, rows, spokes,
    openings: [[from°, span°], …]}]."""
    # The spokes are read on a finer wheel of sectors than the surface
    # grid's: five spokes leave openings under 60° each.
    si = ((azimuth + 180) / (360.0 / spoke_sectors)).astype(int) % spoke_sectors
    surface, normals = surface_grid(h, radius, azimuth, cell, sectors=sectors, min_share=min_share,
                                    n_radial=n_radial, n_axial=n_axial)
    rows = []
    for i, row in enumerate(surface):
        idx = np.flatnonzero(row)
        if len(idx) < 2:
            continue
        runs, start = [], idx[0]
        for a, b in zip(idx[:-1], idx[1:]):
            if b != a + 1:
                runs.append((start, a))
                start = b
        runs.append((start, idx[-1]))
        if len(runs) < 2:
            continue
        (a0, a1), (b0, b1) = runs[0], runs[1]
        gap = (b0 - a1 - 1) * cell
        if gap < min_gap_mm or gap > max_gap_mm:
            continue
        if normals[i, a1, 0] < 0.3:
            continue                                       # the inner run faces in: a bore, not a hub
        rows.append((i, (a1 + 1) * cell, b0 * cell))
    windows, group = [], []

    def close(group):
        if len(group) < min_rows:
            return
        h0, h1 = group[0][0] * cell, (group[-1][0] + 1) * cell
        r_in, r_out = float(np.median([g[1] for g in group])), float(np.median([g[2] for g in group]))
        # The spokes: where the middle half of the annulus has points,
        # sector by sector (its edges hold the hub's and the rim's skins,
        # all the way round).
        quarter = 0.25 * (r_out - r_in)
        inside = (h >= h0) & (h < h1) & (radius >= r_in + quarter) & (radius < r_out - quarter)
        counts = np.bincount(si[inside], minlength=spoke_sectors)
        if counts.max() < 10:
            return
        spoke = counts >= 0.3 * counts.max()
        if spoke.all() or not spoke.any():
            return
        # Runs of spoke sectors, wrapping round.
        start = int(np.argmin(spoke))                  # a sector with no spoke, to start between runs
        order = [(start + k) % spoke_sectors for k in range(spoke_sectors)]
        runs, run = [], []
        for k in order:
            if spoke[k]:
                run.append(k)
            elif run:
                runs.append(run)
                run = []
        if run:
            runs.append(run)
        if len(runs) < 2:
            return
        width = 360.0 / spoke_sectors
        edges = []
        for run in runs:
            a = (run[0] * width - 180.0) - width / 2          # the run's first sector's start, half a sector of margin
            b = (run[-1] * width - 180.0 + width) + width / 2   # its last sector's end, plus the margin
            edges.append((a, b))
        openings = []
        for (a, b), (c, d) in zip(edges, edges[1:] + edges[:1]):
            span = (c - b) % 360.0
            if span >= 2 * width:
                openings.append([round(((b + 180.0) % 360.0) - 180.0, 1), round(span, 1)])   # [from°, span°]
        if not openings:
            return
        windows.append({"h0": round(h0, 2), "h1": round(h1, 2), "rInnerMM": round(r_in, 2), "rOuterMM": round(r_out, 2),
                        "rows": len(group), "spokes": len(runs), "openings": openings})
    for row in rows:
        if group and (row[0] - group[-1][0] > 2 or abs(row[1] - group[-1][1]) > 1.5 * cell or abs(row[2] - group[-1][2]) > 1.5 * cell):
            close(group)
            group = []
        group.append(row)
    close(group)
    return windows


def trace_section(h, radius, azimuth, cell, sectors=24, min_share=0.35, dilate=1, surface=None, normals=None):
    """The body of revolution's full half-section, for a part one radius per
    height cannot describe — a dished wheel, a cup inside a cup. The
    outside is flooded in from the far edges of the surface grid through
    the empty cells, and what the flood cannot reach — solid or sealed —
    is the section. Its outline is traced cell edge by cell edge into
    loops, the longest loop kept. Returns (loop points [(r, h)…], the
    solid mask, the surface mask), or (None, …) when there is no surface."""
    if surface is None:
        surface = surface_grid(h, radius, azimuth, cell, sectors, min_share)
    if normals is None:
        return None, None, None
    if not surface.any():
        return None, None, None
    from scipy.ndimage import binary_fill_holes, binary_opening, label
    from scipy.spatial import cKDTree
    H, R = surface.shape
    # Inside or outside by the surface's own orientation: a cell lies
    # inside when the nearest surface cells face away from it — their
    # outward normals point from them past it, not toward it. Holes in
    # the scan do not matter: whatever surface is nearest decides, and the
    # vote is weighted by closeness. (A flood from the outside leaked
    # through every hole; ray parity was fooled wherever the outline ran
    # along the ray.)
    sy, sx = np.nonzero(surface)
    s_pts = np.column_stack([sx, sy]).astype(float)
    s_nrm = normals[sy, sx] if normals is not None else None
    if s_nrm is None or np.abs(s_nrm).sum() < 1e-9:
        return None, None, None
    tree = cKDTree(s_pts)
    gy, gx = np.mgrid[0:H, 0:R]
    cells = np.column_stack([gx.ravel(), gy.ravel()]).astype(float)
    k = min(8, len(s_pts))
    dist, idx = tree.query(cells, k=k)
    dist = dist.reshape(len(cells), k)
    idx = idx.reshape(len(cells), k)
    rel = cells[:, None, :] - s_pts[idx]                     # from the surface cell to this cell
    side = (rel * s_nrm[idx]).sum(axis=-1)                   # > 0: in front of (outside) that surface
    weight = 1.0 / (dist + 0.5)
    score = (np.sign(side) * weight).sum(axis=1)
    solid = (score < 0).reshape(H, R)
    solid |= surface
    solid = binary_fill_holes(solid)
    solid = binary_opening(solid, iterations=1) | surface
    labels, n = label(solid)
    if n > 1:
        sizes = np.bincount(labels.ravel())
        sizes[0] = 0
        solid = labels == int(np.argmax(sizes))
    # Outline: the edges of solid cells facing non-solid cells, chained.
    edges = {}
    H, R = solid.shape
    def add(a, b):
        edges.setdefault(a, []).append(b)
        edges.setdefault(b, []).append(a)
    for i in range(H):
        for j in range(R):
            if not solid[i, j]:
                continue
            if j == 0 or not solid[i, j - 1]:
                add((j, i), (j, i + 1))
            if j == R - 1 or not solid[i, j + 1]:
                add((j + 1, i), (j + 1, i + 1))
            if i == 0 or not solid[i - 1, j]:
                add((j, i), (j + 1, i))
            if i == H - 1 or not solid[i + 1, j]:
                add((j, i + 1), (j + 1, i + 1))
    loops, seen_v = [], set()
    for start in edges:
        if start in seen_v:
            continue
        loop, prev, cur = [start], None, start
        seen_v.add(start)
        while True:
            nxt = [q for q in edges[cur] if q != prev and q not in seen_v]
            if not nxt:
                break
            prev, cur = cur, nxt[0]
            loop.append(cur)
            seen_v.add(cur)
        if len(loop) >= 4:
            loops.append(loop)
    if not loops:
        return None, solid, surface
    best = max(loops, key=len)
    pts = [(x * cell, y * cell) for x, y in best]
    return pts, solid, surface


def refine_section(points, h, radius, cell):
    """Vertices of a simplified cell outline moved onto the points they
    stand for: a vertical run (one radius) takes the median radius of the
    surface points beside it, a horizontal run (one height) the median
    height — the cell grid's half-cell error goes away on the faces that
    matter, the ones along and across the axis."""
    pts = [list(p) for p in points]
    n = len(pts)
    for k in range(n):
        a, b = pts[k], pts[(k + 1) % n]
        if abs(a[0] - b[0]) < 1e-9 and abs(a[1] - b[1]) >= cell:          # vertical: constant r
            lo, hi = sorted((a[1], b[1]))
            sel = (h >= lo) & (h <= hi) & (np.abs(radius - a[0]) <= 1.5 * cell)
            if sel.sum() >= 12:
                r_new = float(np.median(radius[sel]))
                a[0] = b[0] = r_new
        elif abs(a[1] - b[1]) < 1e-9 and abs(a[0] - b[0]) >= cell:        # horizontal: constant h
            lo, hi = sorted((a[0], b[0]))
            sel = (radius >= lo) & (radius <= hi) & (np.abs(h - a[1]) <= 1.5 * cell)
            if sel.sum() >= 12:
                h_new = float(np.median(h[sel]))
                a[1] = b[1] = h_new
    return pts


def analyze(mesh, band_mm=None, lump_margin_mm=6.0, out_dir=None, name="scan", epsilon=None, debug=False,
            axis_choice="auto", flip=False, samples=200000, multi=True, secondary=False, axis_origin=None):
    """The scan as a body of revolution: its axis, the profile along it,
    the bosses off it. With `multi`, the axis finder (`fit_axes`) looks for
    more bodies of revolution first — a valve's pipe, branches and side
    port on their own axes — and each is traced on its own (this function
    again, `secondary=True`: no ground trim, no bosses, no flip, the given
    axis kept) and listed under `bodies`; the main trace then sees only
    the faces that are the main body's or nobody's."""
    points = np.asarray(mesh.vertices, dtype=float)
    selection, pool, face_labels, trace_faces = None, None, None, None
    extra = None
    if multi and not secondary:
        import fit_axes
        pool = fit_axes.propose_axes(mesh)
        extra = [(c, d) for (c, d, _sel, _dist, _close) in pool["candidates"][:4]]
    origin, axis, qualities = choose_axis(points, axis_choice, extra=extra, axis_origin=axis_origin)
    print("axis candidates (share of vertices on their slice's circle):",
          ", ".join("%s %.2f" % kv for kv in sorted(qualities.items(), key=lambda kv: -kv[1])))
    if pool is not None:
        # The main axis: the tracer's own choice when a principal direction
        # is clean (quality 0.75: a mug, a can), else the finder's strongest
        # body of revolution, if it holds a good share of the surface — the
        # roundness score cannot tell a valve's body from the diagonal
        # between its body and its pipe (0.64 against 0.65), the finder's
        # rings can (31 % of the surface against 4 %).
        free = fit_axes.select_axes(pool)
        best_q = max(qualities.values()) if qualities else 0.0
        if axis_choice == "auto" and best_q < 0.75 and free["axes"] and free["axes"][0]["share"] >= 0.15:
            strongest = free["axes"][0]
            d0 = np.asarray(strongest["direction"])
            if abs(d0 @ axis) < math.cos(math.radians(5.0)):
                print("main axis: the finder's strongest body (%.0f%% of the surface, direction %s) over the principal direction (quality %.2f)" % (
                    100 * strongest["share"], np.round(d0, 3), best_q))
            origin = np.asarray(strongest["origin"], dtype=float)
            axis = d0 if d0 @ axis >= 0 else -d0
            selection = free
        else:
            selection = fit_axes.select_axes(pool, main=(origin, axis))
        found = selection["axes"]
        if found:
            # The finder's own origin for the main axis (its normal lines'
            # least squares; the ring-centre mean sits beside a valve's body).
            main = found[0]
            d_main = np.asarray(main["direction"])
            origin = np.asarray(main["origin"], dtype=float)
            axis = d_main if d_main @ axis >= 0 else -d_main
        if len(found) >= 2:
            face_labels = fit_axes.label_faces(mesh, selection)
            trace_faces = np.where(face_labels <= 0)[0]
            for k, ax in enumerate(found):
                print("body %d: %4.1f%% of the surface, direction %s, %.0f mm long, radius ~%.1f mm%s" % (
                    k, 100 * ax["share"], np.round(ax["direction"], 3), ax["lengthMM"], ax["radiusMM"],
                    "" if ax["parent"] is None else ", into body %d (%s)" % (ax["parent"], ax["junction"])))

    h = (points - origin) @ axis
    perp = (points - origin) - np.outer(h, axis)
    radius = np.linalg.norm(perp, axis=1)

    # Which way is up: the scan's own +Y when the axis is near it (glTF
    # and the app agree on Y up; a valve's hand-wheel is wider than its
    # base), else the end with the larger radius is the base. `flip`
    # inverts either. A secondary body keeps the direction it was given.
    lo, hi = np.percentile(h, 1), np.percentile(h, 99)
    span = hi - lo
    low_r = np.median(radius[h < lo + span * 0.08])
    high_r = np.median(radius[h > hi - span * 0.08])
    if abs(axis[1]) > math.cos(math.radians(30.0)):
        base_at_low = axis[1] > 0
    else:
        base_at_low = not (low_r < high_r)
    if flip:
        base_at_low = not base_at_low
    if secondary:
        base_at_low = True
    if not base_at_low:
        axis = -axis
        h = -h
        perp = (points - origin) - np.outer(h, axis)
    # The scanner's ground: the bottom bands of a standing scan hold a flat
    # ring of sidewalk whose radii spread over a wide range, where a band of
    # the part itself is a thin ring. Trim every band up to the last wide one
    # among the first dozen.
    trim_band = 4.0
    bottom = np.percentile(h, 0.5)
    edges = np.arange(bottom, h.max() + trim_band, trim_band)
    spread = []
    # Judged on the main body's own points when the finder labelled the
    # faces: a pipe's hex nut 100 mm out from a valve's axis read as a
    # sidewalk and took the base block with it.
    if face_labels is not None:
        own_v = np.zeros(len(points), dtype=bool)
        own_v[np.unique(np.asarray(mesh.faces)[face_labels == 0])] = True
    else:
        own_v = np.ones(len(points), dtype=bool)
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1]) & own_v
        spread.append(np.percentile(radius[sel], 80) - np.percentile(radius[sel], 20) if sel.sum() >= 20 else np.nan)
    spread = np.array(spread)
    base_index = 0
    for i in range(min(12, len(spread))):
        if not np.isnan(spread[i]) and spread[i] > 60:
            base_index = i + 1
    if secondary:
        base_index = 0
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
    # The trace's own mesh: with other bodies of revolution found, only
    # the faces that are the main body's or nobody's (a pipe's rings in
    # the body's bands made a drum of the body).
    trace = mesh if trace_faces is None else mesh.submesh([np.asarray(trace_faces)], append=True)
    if trace_faces is not None:
        points = np.asarray(trace.vertices, dtype=float)
        h = (points - origin) @ axis
        perp = (points - origin) - np.outer(h, axis)
        radius = np.linalg.norm(perp, axis=1)
    keep = h >= base_h
    normals = np.asarray(trace.vertex_normals, dtype=float)[keep]
    points, h, perp, radius = points[keep], h[keep] - base_h, perp[keep], radius[keep]
    origin = origin + axis * base_h
    trace_cropped = trace
    if base_index > 0 and trace_faces is not None:
        tv = (np.asarray(trace.vertices, dtype=float) - (origin - axis * base_h)) @ axis >= base_h
        trace_cropped = trace.copy()
        trace_cropped.update_faces(tv[np.asarray(trace.faces)].all(axis=1))
        trace_cropped.remove_unreferenced_vertices()
    elif base_index > 0:
        trace_cropped = cropped
    # The mesh's vertex rows (heights where a low-poly mesh actually has
    # vertices): the arc finder allows the facets between them their chord.
    row_heights = np.unique(np.round(h, 0))
    # The profile is traced on the SURFACE, not on the vertices: a low-poly
    # scan has a vertex row every 10 mm and nothing between, and a fine
    # mesh has them wherever the scanner's triangles happened to fall.
    # Points are sampled over the faces (area-weighted) and added to the
    # vertices; points on faces that look along the axis — a can's top, a
    # flange's shelf, the floor of a mug — are left out, since a band
    # through a flat end would read the disc's spread of radii as the
    # wall's, and the shelves come out as the radius steps anyway.
    source = trace_cropped
    apex_h = float(h.max())        # the scan's true top, before any face is left out
    if samples and len(source.faces):
        sampled, face_index = trimesh.sample.sample_surface(source, int(samples), seed=7)
        sampled = np.asarray(sampled, dtype=float)
        s_normals = np.asarray(source.face_normals, dtype=float)[face_index]
        s_h = (sampled - origin) @ axis
        s_perp = (sampled - origin) - np.outer(s_h, axis)
        side = np.abs(s_normals @ axis) < 0.985
        v_side = np.abs(normals @ axis) < 0.985
        points = np.vstack([points[v_side], sampled[side]])
        h = np.concatenate([h[v_side], s_h[side]])
        perp = np.vstack([perp[v_side], s_perp[side]])
        radius = np.linalg.norm(perp, axis=1)
        normals = np.vstack([normals[v_side], s_normals[side]])
    # The OUTER surface is the profile. A thin-walled bucket or drum is
    # scanned inside as well as out, and a band's sector medians then fall
    # on whichever wall has more points there — the inner one as often as
    # not, 3–7 mm in. A point facing away from the axis is on the outside.
    with np.errstate(invalid="ignore", divide="ignore"):
        facing = (perp * normals).sum(axis=1) > 0.2 * radius

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

    # How fine to trace: a clean mesh to the millimetre, a noisy scan in
    # bands wide enough that each band's radius is a median of many points.
    point_noise = estimate_noise(h, radius, azimuth)
    if band_mm is None:
        band_mm = float(min(4.0, max(1.0, round(3.0 * point_noise, 1))))
    print("scanner noise %.2f mm: bands of %.1f mm" % (point_noise, band_mm))

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
        outward = sel & facing
        if outward.sum() >= max(12, 0.3 * sel.sum()):
            sel = outward
        r = radius[sel]
        sec = sector_of[sel]
        # How much of the circle the band's points leave empty: a ring,
        # however coarse, has points all the way round; a handle's arch
        # or a lever across the top has them in one or two clusters with
        # a long empty arc between.
        present = np.unique(sec)
        if len(present) >= sectors:
            gap_deg = 0.0
        else:
            runs = np.diff(np.concatenate([present, [present[0] + sectors]])) - 1
            gap_deg = float(runs.max()) * 360.0 / sectors
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
        body = agreed_radius(agreed, previous=previous_body, sector_medians=smed) if len(agreed) >= 4 else float(np.median(r))
        # An out-of-round body (a dented barrel, a squashed pail) spreads
        # its sectors over more than the cluster's ±3 mm, and the densest
        # cluster of a sinusoid sits at an extreme; widen to the scan's own
        # spread and take the median of what is in reach — the mean circle.
        if len(agreed) >= 4:
            for _ in range(3):
                mad = float(np.median(np.abs(agreed - body)))
                reach = max(3.0, 3.0 * point_noise, 3.0 * 1.48 * mad)
                members = agreed[np.abs(agreed - body) <= reach]
                if len(members):
                    body = float(np.median(members))
        previous_body = body
        k = int(np.argmax(r))
        bands.append({"h": float((edges[i] + edges[i + 1]) / 2), "median": body,
                      "p20": float(np.percentile(r, 20)), "p80": float(np.percentile(r, 80)),
                      "max": float(r[k]), "maxAzimuth": float(azimuth[k]), "count": int(sel.sum()),
                      "sectors": int(len(agreed)), "gapDeg": round(gap_deg, 1)})
        grid_max.append(smax)
        grid_med.append(smed)
    # A gap in the bands (the stem under a hand-wheel, hidden from the
    # scanner; a bore no ray reached) is not a cone from the band below to
    # the band above: the lower band's radius is carried up to the gap's
    # end, where the profile steps.
    filled = []
    for i, b in enumerate(bands):
        if filled and b["h"] - filled[-1]["h"] > 3.0 * band_mm:
            below = filled[-1]
            filled.append(dict(below, h=float(b["h"] - band_mm), count=0, gapDeg=0.0, filler=True))
            grid_max.insert(len(filled) - 1, grid_max[len(filled) - 2])
            grid_med.insert(len(filled) - 1, grid_med[len(filled) - 2])
        filled.append(b)
    bands = filled
    # The part ends where the rings do: a bucket's handle arches on above
    # the rim, a few sectors wide, and its "radius" shrinking toward the
    # apex read as a dome over the bucket. Bands with points in fewer than
    # a quarter of the sectors, from the top down, are not the body; the
    # revolve stops under them (the comparison still sees the whole scan,
    # so the handle shows as missing, which it is).
    # A band is "not a ring" when a third of the circle around it is empty
    # (a coarse mesh's dome has a dozen points in its top bands, spread all
    # the way round; a handful of points is given the benefit of the doubt).
    full = [i for i, b in enumerate(bands) if b["count"] < 8 or b["gapDeg"] <= 120.0]
    trimmed_top = 0.0
    if full and full[-1] < len(bands) - 2:
        trimmed_top = height - (bands[full[-1]]["h"] + band_mm / 2)
        bands = bands[: full[-1] + 1]
        grid_max, grid_med = grid_max[: len(bands)], grid_med[: len(bands)]
        height = bands[-1]["h"] + band_mm / 2
        print("top %.0f mm is not a ring (a handle?): the body ends at %.0f mm" % (trimmed_top, height))
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
        elif b["heightSpanMM"] < max(3 * band_mm, 10.0):
            why = "only %.0f mm tall" % b["heightSpanMM"]
        elif b["widthMM"] < 20:
            why = "only %.0f mm wide" % b["widthMM"]
        elif not (10 <= b["centerHeightMM"] <= height - 10):
            why = "centred at %.0f mm, off the part" % b["centerHeightMM"]
        elif trimmed_top and b["centerHeightMM"] + b["heightSpanMM"] / 2 >= height - 2 * band_mm:
            # The lump runs on into the part above the last ring — it is
            # the root of the handle the body stops under, not a boss.
            why = "runs into the non-ring top — the handle's root, not a boss"
        elif b["profile"] and b["profile"][0][0] > b["bodyRadiusMM"] * 1.15:
            why = "starts %.0f mm wide at a %.0f mm body — a flange, not a boss" % (b["profile"][0][0] * 2, b["bodyRadiusMM"] * 2)
        elif b["centerHeightMM"] > 0.85 * height and b["bodyRadiusMM"] < 0.5 * float(body_r.max()):
            # A lump beside a narrow neck at the very top is the valve, the
            # hand-wheel or the knob that sits ON the top, seen from the
            # side — not a nozzle sticking out radially. The residual fit
            # gets it, as the plate or the revolve it is.
            why = "beside a narrow neck at the top — what sits on the top, not a radial boss"
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
    if secondary:
        bosses = []
    if selection is not None and len(selection["axes"]) >= 2 and bosses:
        # A lump that is a traced body (the pipe off a valve) is no boss.
        kept = []
        for b in bosses:
            d_b = math.cos(math.radians(b["azimuthDeg"])) * u + math.sin(math.radians(b["azimuthDeg"])) * v
            explained = False
            for k, ax in enumerate(selection["axes"][1:], 1):
                d_k = np.asarray(ax["direction"])
                if abs(d_k @ d_b) < math.cos(math.radians(35.0)):
                    continue
                c_k = np.asarray(ax["origin"]) + d_k * (ax["junctionH"] if ax.get("junctionH") is not None else 0.0)
                h_k = float((c_k - origin) @ axis)
                if abs(h_k - b["centerHeightMM"]) <= max(30.0, 1.5 * ax["radiusMM"]):
                    explained = True
                    print("boss az %.0f h %.0f is body %d, traced on its own axis" % (b["azimuthDeg"], b["centerHeightMM"], k))
                    break
            if not explained:
                kept.append(b)
        bosses = kept

    # The revolve starts where the scan has solid coverage: the bottom of a
    # standing scan thins out into the ground, and a few sparse bands there
    # would put the model's base where the scanner saw almost nothing.
    counts = np.array([b["count"] for b in bands])
    typical = float(np.median(counts[: max(8, len(counts) // 4)]))
    # Only a run of sparse bands from the very bottom: a low-poly scan's
    # bands are sparse at random all the way up, and one at 140 mm must
    # not take everything under it with it.
    first = 0
    for i, b in enumerate(bands):
        if secondary or b["h"] > 150 or counts[i] >= 0.3 * typical:
            break
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
    # The profile's own noise: how far the band medians stray from the
    # profile smoothed over about 12 mm (a running median — a step or a
    # rib is one big value and the median ignores it). Photogrammetry
    # noise is bumps a centimetre across, not white: a second difference
    # between neighbouring 1 mm bands read the hydrant as 0.4 mm clean
    # and traced every bump as a step.
    if len(radii) >= 5:
        from scipy.ndimage import median_filter
        win = max(5, int(round(12.0 / band_mm)) | 1)
        smooth_ref = median_filter(radii, size=min(win, len(radii) | 1), mode="nearest")
        # The 80th percentile, not the median: the jitter sits where the
        # lumps are (a hydrant's nozzle band flips between clusters), and
        # the median of a mostly clean profile would not see it.
        noise = float(np.percentile(np.abs(radii - smooth_ref), 80))
    else:
        noise = point_noise
    if epsilon is None:
        # A noisy profile is never traced finer than a thousandth of the
        # height (0.4 mm on a 940 mm hydrant traced 190 points); a clean
        # one keeps its detail (a bollard's collar is a few 1 mm steps).
        floor = 0.001 * height if noise > 0.15 else 0.0
        epsilon = float(min(2.5, max(0.4, floor, round(2.5 * noise, 2))))
    print("profile noise %.2f mm (band to band): simplifier %.2f mm" % (noise, epsilon))
    smoothed = radii.copy()
    if noise > 0.15:
        # A running median about 6 mm wide, except across a step (a
        # flange edge must stay sharp): a lobed bonnet flange flips the
        # band's radius between its lobes and its hollows band by band.
        half = max(1, int(round(3.0 / band_mm)))
        for i in range(len(radii)):
            lo, hi = max(0, i - half), min(len(radii), i + half + 1)
            window = radii[lo:hi]
            # Flips up to about a seventh of the radius are the lobes of a
            # flange, not a step: a real flange rises by a third or more.
            if window.max() - window.min() < max(8.0, 0.15 * float(np.median(window))):
                smoothed[i] = np.median(window)
    profile = [(float(r), b["h"]) for r, b in zip(smoothed, bands)]
    # Cylinders as single segments, flanges as level steps, the rest to the
    # simplifier: the revolve is the part's design, not the scanner's noise.
    dense = [(float(r), float(b["h"])) for r, b in zip(smoothed, bands)]
    straight_tol = max(0.6, epsilon * 1.5)
    profile = straighten(profile, tol=straight_tol, step_min=max(2.0, 3.0 * straight_tol))
    if profile:
        profile = [(profile[0][0], 0.0)] + profile + [(profile[-1][0], height)]
    simplified = douglas_peucker(profile, epsilon=epsilon)
    # A dome, a barrel's belly, a can's shoulder: an arc in the revolve
    # sketch, not a staircase of chords. The arcs are looked for on the
    # simplifier's own polyline through the raw bands (`straighten` has
    # already cut a belly into a cylinder and two cones by then — the
    # terraces the deviation preview painted on the beer mug): runs that
    # turn one way are tried as circles and kept when every band between
    # their ends lies within the scanner's noise of the circle. Each arc
    # then replaces the straightened points inside its height range.
    raw = [(dense[0][0], 0.0)] + dense + [(dense[-1][0], height)] if dense else []
    raw_simplified = douglas_peucker(raw, epsilon=epsilon) if raw else []
    if debug:
        print("raw polyline (%d points): %s" % (len(raw_simplified), " ".join("%.1f@%.1f" % p for p in raw_simplified)))
        print("straightened (%d points): %s" % (len(simplified), " ".join("%.1f@%.1f" % p for p in simplified)))
    # An arc wider than the part is tall is a slight taper, not a curve.
    # On a finely traced profile three vertices are enough to try a circle:
    # the bands between them are what prove it, to a few times the noise
    # (a noisy scan gets the simplifier's slack); a chord under 10 mm is a
    # seam or a step, not a curve.
    arc_tol = max(epsilon, 1.5) * 1.6 if noise > 0.25 else max(4 * noise, 0.2)
    arcs = [s for s in arcs_in_polyline(raw_simplified, dense, tol=arc_tol, max_radius=height,
                                        min_arc_points=3 if band_mm <= 1.5 else 4, min_span=10.0,
                                        row_heights=row_heights, tol_per_radius=0.0 if noise > 0.25 else 0.006,
                                        min_sagitta=max(2 * epsilon, 1.0))
            if s["kind"] == "arc"]
    # A curve is taller than it is wide, or near enough: an "arc" from a
    # 6 mm stem out to a 34 mm rim that rises 2 mm is a step with a band
    # caught between, and one from a rim's top edge in to its hub over
    # 5 mm is the flat top with the hub's foot — three points on a step
    # fit a circle as well as a quarter-round does. A dome rises about
    # its own radius; a shoulder rises more than a third of what it
    # narrows by.
    def tall_enough(arc):
        dr = abs(arc["a"][0] - arc["b"][0])
        dh = abs(arc["a"][1] - arc["b"][1])
        return dh >= max(3.0 * band_mm, 0.4 * dr)
    for arc in arcs:
        if not tall_enough(arc):
            print("profile: an arc r %.0f over h %.0f–%.0f is a step (rises %.1f mm over %.1f mm of radius), kept as lines" % (
                arc["radius"], min(arc["a"][1], arc["b"][1]), max(arc["a"][1], arc["b"][1]),
                abs(arc["a"][1] - arc["b"][1]), abs(arc["a"][0] - arc["b"][0])))
    arcs = [arc for arc in arcs if tall_enough(arc)]
    arcs.sort(key=lambda s: min(s["a"][1], s["b"][1]))
    spliced = []
    rest = list(simplified)
    for arc in arcs:
        h0, h1 = sorted((arc["a"][1], arc["b"][1]))
        spliced += [p for p in rest if p[1] < h0 - 1e-6]
        spliced.append(("arc", arc))
        rest = [p for p in rest if p[1] > h1 + 1e-6]
    spliced += rest
    segments = []
    prev = None
    for item in spliced:
        if isinstance(item, tuple) and item[0] == "arc":
            arc = item[1]
            lo, hi = (arc["a"], arc["b"]) if arc["a"][1] <= arc["b"][1] else (arc["b"], arc["a"])
            if prev is not None and (abs(prev[0] - lo[0]) > 1e-6 or abs(prev[1] - lo[1]) > 1e-6):
                if math.hypot(prev[0] - lo[0], prev[1] - lo[1]) < 0.3 and segments and segments[-1]["kind"] == "line":
                    segments[-1]["b"] = [float(lo[0]), float(lo[1])]        # snap the line onto the arc
                else:
                    segments.append({"kind": "line", "a": [float(prev[0]), float(prev[1])], "b": [float(lo[0]), float(lo[1])]})
            if arc["a"][1] > arc["b"][1]:      # keep the arc running upward like the rest of the profile
                arc = dict(arc, a=arc["b"], b=arc["a"], start=arc["end"], end=arc["start"], ccw=not arc["ccw"])
            segments.append(arc)
            prev = hi
        else:
            if prev is not None:
                segments.append({"kind": "line", "a": [float(prev[0]), float(prev[1])], "b": [float(item[0]), float(item[1])]})
            prev = item
    if arcs:
        simplified = [p for p in spliced if not (isinstance(p, tuple) and p and p[0] == "arc")]
    # A dome's apex: an arc that ends near the top and whose circle meets
    # the axis within a few bands of it is carried to the axis. The top
    # band's median radius is read a couple of millimetres under the apex,
    # so a closed-off arc left a flat button there (the bollard's).
    last_arc = max((i for i, s in enumerate(segments) if s["kind"] == "arc"), default=None)
    if last_arc is not None:
        last = segments[last_arc]
        tail = segments[last_arc + 1:]
        tail_span = (tail[-1]["b"][1] - last["b"][1]) if tail else 0.0
        cr, ch, R = last["center"][0], last["center"][1], last["radius"]
        if abs(cr) < R and last["b"][0] < 0.5 * R and tail_span <= max(4 * band_mm, 12.0, 0.2 * R):
            apex_h = ch + math.sqrt(R * R - cr * cr)
            if abs(apex_h - height) < max(3 * band_mm, 10.0):
                del segments[last_arc + 1:]
                last["b"] = [0.0, apex_h]
                last["end"] = math.atan2(apex_h - ch, -cr)
                if simplified:
                    simplified = [p for p in simplified if p[1] <= last["a"][1] + 1e-6] + [(0.0, apex_h)]
                height = apex_h
                print("profile: the top arc is carried to the axis at h %.1f (its apex)" % apex_h)
    if segments and segments[-1]["kind"] == "line" and apex_h - height > 0.5 and not secondary:
        top_r = segments[-1]["b"][0]
        gap = apex_h - height
        # Only a cap's worth: the last band under a dome's crown is a few
        # millimetres under the apex. A valve's lever 76 mm above the last
        # ring, an extinguisher's handle 97 mm above it, came out as spikes
        # to the apex; they are the residual fit's.
        if 0 < top_r < 0.5 * float(body_r.max()) and gap <= max(2.0 * band_mm, 0.6 * top_r):
            segments.append({"kind": "line", "a": [float(top_r), float(height)], "b": [0.0, float(apex_h)]})
            simplified = list(simplified) + [(0.0, float(apex_h))]
            print("profile: the top is carried from r %.0f at h %.1f to the apex at h %.1f" % (top_r, height, apex_h))
            height = float(apex_h)
        elif 0 < top_r < 0.5 * float(body_r.max()):
            print("profile: the top %.0f mm above the last ring (r %.0f) is not a cap; left to the feature fit" % (gap, top_r))
    if arcs:
        print("profile: %d arcs (%s)" % (len(arcs), ", ".join("r %.0f over h %.0f–%.0f" % (
            s["radius"], min(s["a"][1], s["b"][1]), max(s["a"][1], s["b"][1])) for s in arcs)))
    # Open top? A bucket, a barrel without its lid, a mug: rays down the
    # axis from above hit the inside bottom, not a top. Then the revolve is
    # shelled, at the rim's wall thickness.
    ends = (float(simplified[0][0]), float(simplified[-1][0])) if simplified else (float(body_r[0]), float(body_r[-1]))
    open_top = None if secondary else detect_open_top(cropped if cropped is not None else mesh, origin, axis, u, v,
                                                      height, ends, bands, radius, h, facing=facing)
    if open_top:
        print("open %s: rays from outside fall %.0f mm in (or through) on %.0f%% of that end; wall %.1f mm — the revolve will be shelled" % (
            open_top["end"], open_top["depthMM"], open_top["share"] * 100, open_top["wallMM"]))
    # One radius per height cannot describe a dished wheel: a band there
    # holds two full rings far apart (the tyre and the hub) with nothing
    # between. Such a part gets its whole half-section traced instead.
    cell = max(band_mm, 2.0)
    with np.errstate(invalid="ignore", divide="ignore"):
        n_radial = np.where(radius > 1e-9, (perp * normals).sum(axis=1) / np.maximum(radius, 1e-9), 0.0)
    n_axial = normals @ axis
    surface_mask, cell_normals = surface_grid(h, radius, azimuth, cell, n_radial=n_radial, n_axial=n_axial)
    # The test for a dish asks for proper rings (six tenths of the circle):
    # a valve's stem, branch and side port together fill half the sectors
    # of one band and are no ring.
    # An open container's floor sits a wall's thickness in from its skin
    # and is no dish: the test wants a gap of 40 mm, on a part with no
    # open end (a bucket and a drum keep their band trace and cavity cut).
    dished = (not open_top) and (not secondary) and is_dished(surface_grid(h, radius, azimuth, cell, min_share=0.6), cell, min_gap_mm=40.0)
    section_loop = None
    # A ring on a hub (a hand-wheel) within a part that is otherwise one
    # radius per height: the annulus between them is a window to cut.
    windows = [] if (open_top or secondary or dished) else find_windows(h, radius, azimuth, cell, n_radial, n_axial)
    for w in windows:
        print("window: a wheel over h %.0f–%.0f — %d spokes between hub r %.0f and rim r %.0f, %d openings cut out" % (
            w["h0"], w["h1"], w["spokes"], w["rInnerMM"], w["rOuterMM"], len(w["openings"])))
    if dished:
        pts_loop, solid_mask, surface_mask = trace_section(h, radius, azimuth, cell, surface=surface_mask,
                                                           normals=cell_normals)
        if pts_loop:
            simplified_loop = douglas_peucker(pts_loop + [pts_loop[0]], epsilon=max(cell * 0.9, 1.0))[:-1]
            simplified_loop = refine_section(simplified_loop, h, radius, cell)
            section_loop = [[round(float(r), 2), round(float(hh), 2)] for r, hh in simplified_loop]
            print("dished: the half-section traced as a region of %d cells of %.1f mm, outline of %d points" % (
                int(solid_mask.sum()), cell, len(section_loop)))
            # The section already holds every ring; what stands off it (a
            # wheel's stand, a bracket) is no radial boss — the residual
            # fit takes it. A boss revolved from the stand's lump made a
            # 500 mm disc.
            if bosses:
                print("dished: %d boss candidate(s) left to the residual fit" % len(bosses))
                bosses = []

    analysis = {
        "name": name,
        "triangles": int(len(mesh.faces)), "vertices": int(len(mesh.vertices)),
        "axisOrigin": [float(x) for x in origin], "axisDirection": [float(x) for x in axis],
        "azimuthZero": [float(x) for x in u], "azimuthNinety": [float(x) for x in v],
        "heightMM": round(height, 2),
        "noiseMM": round(noise, 3), "pointNoiseMM": round(point_noise, 3), "bandMM": band_mm, "epsilonMM": epsilon,
        "axisQuality": qualities, "flipped": bool(flip), "topNotARingMM": round(trimmed_top, 1),
        "maxRadiusMM": round(float(radius.max()), 2),
        "bodyRadiusMM": round(float(np.median([b["median"] for b in bands])), 2),
        "bands": bands,
        "profile": [[round(r, 2), round(hh, 2)] for r, hh in simplified],
        "profileSegments": segments,
        "sectionLoop": section_loop,
        "windows": windows,
        "openTop": open_top,
        "bosses": bosses,
        "boundsMM": {"min": [float(x) for x in mesh.bounds[0]], "max": [float(x) for x in mesh.bounds[1]]},
        "bodies": [],
    }
    if selection is not None and len(selection["axes"]) >= 2:
        analysis["axes"] = [{k: ax[k] for k in ("origin", "direction", "share", "lengthMM", "radiusMM", "parent", "junction")}
                            for ax in selection["axes"]]
        analysis["bodies"] = secondary_bodies(mesh, selection, face_labels, name, samples, lump_margin_mm,
                                              band_mm=band_mm, epsilon=epsilon)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        if cropped is None:
            # Nothing to trim, but the copy is still the one the app imports:
            # a scan whose file units were overridden (`--units`) is only
            # the right size here.
            cropped = mesh
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


def extend_profile(a, start_mm=0.0, end_mm=0.0):
    """Lengthen a traced body along its axis — `start_mm` below its foot,
    `end_mm` past its top — at the end's own radius, so the revolve runs
    into the body it joins (a union wants overlap). The origin moves down
    with the foot; heights, profile and segments shift with it."""
    axis = np.asarray(a["axisDirection"], dtype=float)
    if start_mm > 0:
        a["axisOrigin"] = [float(x) for x in np.asarray(a["axisOrigin"], dtype=float) - axis * start_mm]
        a["profile"] = [[r, hh + start_mm] for r, hh in a["profile"]]
        for seg in a["profileSegments"]:
            seg["a"] = [seg["a"][0], seg["a"][1] + start_mm]
            seg["b"] = [seg["b"][0], seg["b"][1] + start_mm]
            if "center" in seg:
                seg["center"] = [seg["center"][0], seg["center"][1] + start_mm]
        # The new line meets the first segment exactly where it starts (the
        # profile's rounded radius sat 0.02 mm off it: "revolve profile
        # unresolved").
        first = a["profileSegments"][0]["a"] if a["profileSegments"] else a["profile"][0]
        r0, h0 = float(first[0]), float(first[1])
        a["profile"] = [[r0, 0.0]] + a["profile"]
        a["profileSegments"] = [{"kind": "line", "a": [r0, 0.0], "b": [r0, h0]}] + a["profileSegments"]
        a["heightMM"] = round(float(a["heightMM"]) + start_mm, 2)
    if end_mm > 0:
        top = float(a["heightMM"])
        last = a["profileSegments"][-1]
        if last["kind"] == "arc":
            end_pt = [last["center"][0] + last["radius"] * math.cos(last["end"]),
                      last["center"][1] + last["radius"] * math.sin(last["end"])]
        else:
            end_pt = last["b"]
        r1, h1 = float(end_pt[0]), float(end_pt[1])
        a["profile"] = a["profile"] + [[r1, top + end_mm]]
        a["profileSegments"] = a["profileSegments"] + [{"kind": "line", "a": [r1, h1], "b": [r1, top + float(end_mm)]}]
        a["heightMM"] = round(top + end_mm, 2)
    a["extendedMM"] = [round(float(start_mm), 2), round(float(end_mm), 2)]
    return a


def trim_profile(a, start_mm=0.0, end_mm=0.0):
    """Cut `start_mm` off the foot of a traced body and `end_mm` off its
    top: the profile and its segments are clipped at the new ends (an arc
    that straddles the cut becomes a line from the cut to its far end),
    heights re-based so the foot is at 0, the origin moved up with it."""
    axis = np.asarray(a["axisDirection"], dtype=float)
    top = float(a["heightMM"])
    lo, hi = float(start_mm), top - float(end_mm)
    if hi - lo < 3.0:
        return a

    def clip_point(pt):
        return [float(pt[0]), float(min(max(pt[1], lo), hi))]

    profile = [[r, hh] for r, hh in a["profile"] if lo <= hh <= hi]
    first = np.interp(lo, [hh for _, hh in a["profile"]], [r for r, _ in a["profile"]])
    last = np.interp(hi, [hh for _, hh in a["profile"]], [r for r, _ in a["profile"]])
    profile = [[float(first), lo]] + [p for p in profile if lo < p[1] < hi] + [[float(last), hi]]
    segments = []
    for seg in a["profileSegments"]:
        a0, b0 = seg["a"], seg["b"]
        s_lo, s_hi = min(a0[1], b0[1]), max(a0[1], b0[1])
        if s_hi <= lo or s_lo >= hi:
            continue
        if seg["kind"] == "arc" and s_lo >= lo and s_hi <= hi:
            segments.append(seg)
        elif seg["kind"] == "arc":
            segments.append({"kind": "line", "a": clip_point(a0), "b": clip_point(b0)})
        else:
            segments.append({"kind": "line", "a": clip_point(a0), "b": clip_point(b0)})
    segments = [sg for sg in segments if sg["kind"] == "arc" or abs(sg["a"][1] - sg["b"][1]) > 1e-6 or abs(sg["a"][0] - sg["b"][0]) > 1e-6]
    if lo > 0:
        a["axisOrigin"] = [float(x) for x in np.asarray(a["axisOrigin"], dtype=float) + axis * lo]
        profile = [[r, hh - lo] for r, hh in profile]
        for seg in segments:
            seg["a"] = [seg["a"][0], seg["a"][1] - lo]
            seg["b"] = [seg["b"][0], seg["b"][1] - lo]
            if "center" in seg:
                seg["center"] = [seg["center"][0], seg["center"][1] - lo]
    a["profile"] = [[round(float(r), 2), round(float(hh), 2)] for r, hh in profile]
    a["profileSegments"] = segments
    a["heightMM"] = round(hi - lo, 2)
    a["trimmedMM"] = [round(float(start_mm), 2), round(float(end_mm), 2)]
    return a


def secondary_bodies(mesh, selection, face_labels, name, samples, lump_margin_mm, band_mm=None, epsilon=None):
    """Every body of revolution the axis finder found beyond the main one,
    traced on its own axis — the faces labelled its own, `analyze` again
    with that axis fixed — and lengthened into the body it runs into.
    Returns the list for `analysis["bodies"]` (profile, segments, frame,
    parent, junction), in the finder's order."""
    bodies = []
    keys = ("name", "axisOrigin", "axisDirection", "azimuthZero", "azimuthNinety", "heightMM", "profile",
            "profileSegments", "bodyRadiusMM", "maxRadiusMM", "bandMM", "epsilonMM", "noiseMM", "topNotARingMM",
            "extendedMM", "trimmedMM")
    for k, ax in enumerate(selection["axes"][1:], 1):
        faces_k = np.where(face_labels == k)[0]
        if len(faces_k) < 50:
            continue
        sub = mesh.submesh([faces_k], append=True)
        d = np.asarray(ax["direction"], dtype=float)
        choice = "%.6f,%.6f,%.6f!" % tuple(d)
        print("== body %d: %d faces on its own axis" % (k, len(faces_k)))
        try:
            # The scanner's noise is the scan's, not the body's: the main
            # trace's band and simplifier serve every body.
            a = analyze(sub, out_dir=None, name="%s-body%d" % (name, k), axis_choice=choice,
                        axis_origin=np.asarray(ax["origin"], dtype=float), flip=False,
                        samples=max(40000, int(samples) // 3), multi=False, secondary=True,
                        lump_margin_mm=lump_margin_mm, band_mm=band_mm, epsilon=epsilon)
        except Exception as error:  # noqa: BLE001 — a body too thin to trace is left to the residual fit
            print("   body %d not traced: %s" % (k, error))
            continue
        if len(a["profile"]) < 3 or a["heightMM"] < 5:
            print("   body %d too short to keep (%d profile points over %.1f mm)" % (k, len(a["profile"]), a["heightMM"]))
            continue
        # Into its parent: the finder's junction end is the foot ("start",
        # the low end of its direction) or the top ("end"); a body that
        # passes through its parent needs no lengthening. The root — where
        # the body's rings are cut by the parent's skin, over 2 r_parent /
        # tan θ along a branch leaving at θ — is no part of the profile:
        # it is cut off and the body runs straight into its parent at the
        # first clean radius.
        r_parent = float(ax.get("junctionParentRadiusMM") or 0.0)
        start_mm = end_mm = 0.0
        if ax["junction"] in ("start", "end") and ax["parent"] is not None:
            d_parent = np.asarray(selection["axes"][ax["parent"]]["direction"], dtype=float)
            cos_t = abs(float(d @ d_parent))
            tan_t = math.sqrt(max(1.0 - cos_t * cos_t, 1e-6)) / max(cos_t, 1e-6)
            root = 2.0 * r_parent / max(tan_t, 0.5) + 0.2 * float(a["bodyRadiusMM"])
            root = float(min(root, 0.4 * a["heightMM"]))
            trim_profile(a, root if ax["junction"] == "start" else 0.0, root if ax["junction"] == "end" else 0.0)
            r_end = float(a["profile"][0][0] if ax["junction"] == "start" else a["profile"][-1][0])
            delta = max(4.0, min(r_parent if r_parent > 0 else 1e9, 0.6 * r_end + 2.0 * float(ax["tolMM"])))
            if ax["junction"] == "start":
                start_mm = delta + root
            else:
                end_mm = delta + root
            extend_profile(a, start_mm, end_mm)
        body = {key: a[key] for key in keys if key in a}
        body.update({"index": k, "parent": ax["parent"], "junction": ax["junction"], "shareOfSurface": ax["share"],
                     "finderRadiusMM": ax["radiusMM"], "finderLengthMM": ax["lengthMM"]})
        bodies.append(body)
        print("   body %d: %d profile points over %.0f mm, radius ~%.1f mm%s" % (
            k, len(a["profile"]), a["heightMM"], a["bodyRadiusMM"],
            "" if not (start_mm or end_mm) else ", lengthened %.0f mm into body %s" % (start_mm or end_mm, ax["parent"])))
    return bodies


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
    # The revolve's own loop: lines and arcs (the arcs sampled).
    for seg in analysis.get("profileSegments") or []:
        if seg["kind"] == "arc":
            c, r0 = seg["center"], seg["radius"]
            a0, a1 = seg["start"], seg["end"]
            if seg.get("ccw", True):
                while a1 < a0:
                    a1 += 2 * math.pi
            else:
                while a1 > a0:
                    a1 -= 2 * math.pi
            steps = max(6, int(abs(a1 - a0) * r0 / 2.0))
            d.line([pt(c[0] + r0 * math.cos(a0 + (a1 - a0) * k / steps), c[1] + r0 * math.sin(a0 + (a1 - a0) * k / steps))
                    for k in range(steps + 1)], fill=(20, 20, 20), width=3)
        else:
            d.line([pt(*seg["a"]), pt(*seg["b"])], fill=(20, 20, 20), width=3)
    if not analysis.get("profileSegments"):
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
    ap.add_argument("--band", default="auto", help="height band, mm (auto: 3× the scanner's noise, 1–4 mm)")
    ap.add_argument("--epsilon", default="auto",
                    help="polyline simplification, mm (auto: 2.5× the scanner's noise, 0.4–2.5 mm)")
    ap.add_argument("--samples", type=int, default=200000, help="surface points sampled for the trace (0: vertices only)")
    ap.add_argument("--debug", action="store_true", help="say why each candidate lump was dropped")
    ap.add_argument("--axis", default="auto",
                    help="auto (the roundest of the three principal directions), largest, middle, smallest, or X,Y,Z")
    ap.add_argument("--flip", action="store_true", help="invert which end is the base (the scan's +Y end when the axis is near vertical, else the wider end)")
    ap.add_argument("--single", action="store_true", help="one axis only: skip the axis finder's search for more bodies of revolution")
    args = ap.parse_args()
    mesh, scale = load_mesh(args.scan, args.units)
    name = os.path.splitext(os.path.basename(args.scan))[0]
    band = None if args.band == "auto" else float(args.band)
    epsilon = None if args.epsilon == "auto" else float(args.epsilon)
    a = analyze(mesh, band_mm=band, out_dir=args.out, name=name, epsilon=epsilon, debug=args.debug,
                axis_choice=args.axis, flip=args.flip, samples=args.samples, multi=not args.single)
    print("scan: %d triangles, %.0f mm tall, body radius %.1f mm (file units x%g)" % (
        a["triangles"], a["heightMM"], a["bodyRadiusMM"], scale))
    print("axis origin", np.round(a["axisOrigin"], 1), "direction", np.round(a["axisDirection"], 3))
    print("profile points:", len(a["profile"]))
    for b in a.get("bodies", []):
        print("body %d: %d profile points over %.0f mm, radius ~%.1f mm, into body %s (%s)" % (
            b["index"], len(b["profile"]), b["heightMM"], b["bodyRadiusMM"], b["parent"], b["junction"]))
    for b in a["bosses"]:
        print("boss at %6.1f° height %5.1f reach %5.1f width %5.1f neck %5.1f profile %s" % (
            b["azimuthDeg"], b["centerHeightMM"], b["reachMM"], b["widthMM"], b["neckWidthMM"],
            " ".join("%.0f@%.0f" % (r, s) for r, s in b.get("profile", []))))
    print("wrote", os.path.join(args.out, "profile.json"))


if __name__ == "__main__":
    main()
