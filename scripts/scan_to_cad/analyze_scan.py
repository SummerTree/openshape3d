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
6. Colour. The scan's dominant colour, read off its own texture (or vertex
   colours), goes into the JSON as `scanColor` so the model can be painted
   like the scan instead of a hand-picked red (`scan_color`).
7. Sections. One radius per band throws away everything the band's 36
   sectors disagree on. Each band's sector medians are fitted as a ring
   off the axis and oval (`fit_section`: the first two harmonics, the
   lumps left out), smoothed along the height between the profile's
   steps (`section_field`) and recorded as `sections`; `roundness` says
   how far the sectors stray from the revolve and whether the build keeps
   it, re-fits a tilted axis, or lofts through the sections
   (`section_gate`).
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


def load_mesh(path, unit_scale=None, keep_scene=False):
    """The scan as one mesh in millimetres, with the scale applied. With
    `keep_scene` the loaded scene comes back as well, textures and all, for
    `scan_color` — a 4096² RGBA texture costs five seconds to decode, and
    once is enough."""
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
    if keep_scene:
        return mesh, unit_scale, scene
    return mesh, unit_scale


def srgb_to_linear(c):
    """sRGB 0…1 to linear light, the IEC 61966-2-1 curve (not a plain gamma)."""
    c = np.asarray(c, dtype=float)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    """Linear light back to sRGB 0…1, clipped."""
    c = np.clip(np.asarray(c, dtype=float), 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def color_samples(source, count=20000, seed=7):
    """Points on the scan's surface with the colour the file paints there:
    an (n, 3) sRGB array in 0…1 and where it came from ("texture" or
    "vertex"), or None when nothing in the file carries colour.

    `source` is the scan's path or an already loaded scene or mesh. The
    corpus scans are glTF binaries whose texture lives per geometry (a
    `force='mesh'` load drops it), so each geometry is sampled on its own,
    in proportion to its area, by area-weighted faces and barycentric UVs
    looked up in the material's base-colour image, times the material's
    base-colour factor when it has one. Vertex (or face) colours are the
    fallback for a scan that has no photo texture."""
    scene = trimesh.load(source) if isinstance(source, str) else source
    geometries = list(scene.geometry.values()) if isinstance(scene, trimesh.Scene) else [scene]
    geometries = [g for g in geometries if isinstance(g, trimesh.Trimesh) and len(g.faces)]
    areas = np.array([g.area for g in geometries], dtype=float)
    if not len(areas) or areas.sum() <= 0:
        return None
    rgb, sources = [], set()
    for g, area in zip(geometries, areas):
        n = int(round(count * area / areas.sum()))
        if n < 1:
            continue
        visual = g.visual
        points, faces = trimesh.sample.sample_surface(g, n, seed=seed)
        weights = trimesh.triangles.points_to_barycentric(g.triangles[faces], points)
        image = None
        material = getattr(visual, "material", None)
        if material is not None:
            image = getattr(material, "baseColorTexture", None) or getattr(material, "image", None)
        uv = getattr(visual, "uv", None)
        if image is not None and uv is not None and len(uv) == len(g.vertices):
            at = (np.asarray(uv, dtype=float)[g.faces[faces]] * weights[:, :, None]).sum(axis=1)
            colors = trimesh.visual.color.uv_to_color(at, image)[:, :3].astype(float) / 255.0
            factor = getattr(material, "baseColorFactor", None)
            if factor is not None:
                # glTF multiplies in linear light while the texture (and the
                # swatch) are sRGB: a factor of 0.5 on white is 0.5 linear,
                # which is 0.74 on screen, not 0.5.
                linear = srgb_to_linear(colors) * (np.asarray(factor, dtype=float)[:3] / 255.0)
                colors = linear_to_srgb(linear)
            rgb.append(colors)
            sources.add("texture")
        elif getattr(visual, "kind", None) == "vertex" and visual.defined:
            per_vertex = np.asarray(visual.vertex_colors, dtype=float)[:, :3] / 255.0
            rgb.append((per_vertex[g.faces[faces]] * weights[:, :, None]).sum(axis=1))
            sources.add("vertex")
        elif getattr(visual, "kind", None) == "face" and visual.defined:
            rgb.append(np.asarray(visual.face_colors, dtype=float)[faces, :3] / 255.0)
            sources.add("vertex")
    if not rgb:
        return None
    return np.clip(np.vstack(rgb), 0.0, 1.0), ("texture" if "texture" in sources else "vertex")


def dominant_color(rgb, k=4, seed=7):
    """The colour that covers the scan, with the share of the samples it
    holds: k-means into a few clusters, then the cluster whose share
    weighted by its saturation is the largest, as the mean of its members.

    The raw largest cluster is not what the eye names a part by: a spray
    can's white lettering, bare-metal ends and highlights make one light
    cluster of 40 % against the label's blue at 31 %, and a person still
    calls the can blue. Weighting each cluster's share by one plus its
    saturation ((max − min) / max of its centre) lets a painted colour win
    over a neutral one of nearly twice its area, while a grey bollard or a
    white mug, with no saturated cluster of any size, stays grey or
    white. `share` is the cluster's raw share, so a low value says the
    swatch is one colour among several."""
    from scipy.cluster.vq import kmeans2
    rgb = np.asarray(rgb, dtype=float)
    # A texture of two flat colours has no four clusters to find.
    k = min(k, len(np.unique(np.round(rgb, 2), axis=0)))
    if k < 2:
        return [float(c) for c in rgb.mean(axis=0)], 1.0
    centres, labels = kmeans2(rgb, k, minit="++", rng=seed)
    shares = np.bincount(labels, minlength=k) / float(len(labels))
    peak = centres.max(axis=1)
    saturation = np.where(peak > 0, (peak - centres.min(axis=1)) / np.maximum(peak, 1e-9), 0.0)
    best = int(np.argmax(shares * (1.0 + saturation)))
    return [float(c) for c in rgb[labels == best].mean(axis=0)], float(shares[best])


def lift_shadow(rgb, floor=0.25):
    """The colour scaled up until its brightest channel is at least `floor`,
    hue kept: a scan's texture has the lighting baked in, and a swatch read
    off a dark side of a red hydrant is a muddy brown nobody would paint a
    model."""
    rgb = np.asarray(rgb, dtype=float)
    peak = float(rgb.max())
    if peak <= 0:
        return [floor] * 3
    if peak < floor:
        rgb = rgb * (floor / peak)
    return [round(float(c), 4) for c in np.clip(rgb, 0.0, 1.0)]


def scan_color_record(source):
    """What the analysis JSON records as `scanColor`: the scan's dominant
    colour as sRGB in 0…1, the share of the surface samples in its cluster
    and whether it was read from the texture or from vertex colours — or
    None when the scan carries no colour at all."""
    found = color_samples(source)
    if found is None:
        return None
    rgb, where = found
    colour, share = dominant_color(rgb)
    return {"rgb": lift_shadow(colour), "share": round(share, 3), "source": where}


def scan_color(source):
    """The scan's dominant albedo as sRGB [r, g, b] in 0…1, or None."""
    record = scan_color_record(source)
    return None if record is None else record["rgb"]


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


def open_end_depth(height):
    """How far past an end plane a ray must fall for `detect_open_top` to
    call that end open. The bore detector keeps to holes shallower than
    this (or much narrower than the end), so one hole is never both a
    container's cavity and a bore."""
    return max(0.15 * height, 25.0)


def detect_bores(h, radius, azimuth, n_radial, height, radii_ends, band_mm, noise_mm=0.5, secondary=False,
                 sectors=24, debug=False, profile=None, n_axial=None, caps=None):
    """A hole bored into a free end of a body of revolution — an open pipe
    end, a coupling's socket, a recessed port — read off the points that
    face IN (normal toward the axis) just inside the end plane: an inner
    wall at r_inner, a real wall in from the end's own radius, seen round
    at least half the circle, running some depth into the body. The depth
    is how far the inner wall is seen, slab by slab (max(band, 2 mm));
    where the wall's radius steps (a coupling's socket r 19 for 12 mm, then
    the pipe's own r 14) the bore keeps a stepped profile; seen most of the
    way along the body it is a through bore (depth = the body's length —
    a branch unioned into its parent is filled where the parent is solid,
    so the pipe stays open to the parent's skin). A scanner sees less of a
    bore the deeper it goes, so the depth is a lower bound: as far as the
    inner wall is seen.

    `radii_ends` is (the profile's radius at h = 0, at h = height);
    `n_radial` the points' normal component along the outward radial, so a
    point on an inner wall reads < 0; `profile` the traced outer profile
    [(r, h), …], which the bore must stay a wall inside — the walk stops
    where the body narrows onto it. A body `secondary=True` (a branch
    traced on its own axis, where `detect_open_top` never runs) takes a
    bore on the inner wall alone, down to a 1 mm wall; the main body only
    where the hole is shallower than `open_end_depth` (what the open-top
    test would have called a container) or narrower than 0.6 of the end
    radius — a bucket's cavity is `detect_open_top`'s and never a bore.
    `n_axial` (the normals' component along the axis) and `caps` (the
    axial-facing samples the trace leaves out, as (h, radius, azimuth,
    n_axial) — an end face, a shelf, a floor) let the floor be seen:
    points inside the hole facing back toward the mouth. A hole with
    a floor is never through, however far along the body its wall runs —
    a bucket whose floor is a tenth of its height is a container with a
    thin floor, not a tube — so the main-body rule above still holds for
    it. Nothing may stand in the hole over its depth either (a nut's
    flanks face OUT inside the bore's radius): that is a recess round the
    nut, left to the residual fit.

    Returns a list, one record per bored end: {"end": "start"|"end",
    "rInnerMM", "depthMM", "wallMM", "share", "through", "profile":
    [[r, depth], …] (the bore's radius by depth from the end plane, as
    steps)}. Two bores that meet in the middle are one through bore."""
    slab = max(float(band_mm), 2.0)
    nb = int(height / slab) + 1
    if nb < 2 or len(h) < 50:
        return []
    inward = n_radial < -0.5
    outer_r = None
    if profile and len(profile) >= 2:
        p_r = np.array([float(p[0]) for p in profile])
        p_h = np.array([float(p[1]) for p in profile])
        order = np.argsort(p_h, kind="stable")

        def outer_r(hh):
            """The outer profile's radius at height hh — the SMALLEST it
            reads there, so a step's two points at one height do not hide
            the narrower side."""
            near = np.abs(p_h - hh) <= 0.5 * slab
            if near.any():
                return float(p_r[near].min())
            return float(np.interp(hh, p_h[order], p_r[order]))

    def tol_r(r):
        return max(1.5, 3.0 * noise_mm, 0.08 * r)

    found = []
    for end, sign, h_end, r_end in (("start", 1.0, 0.0, float(radii_ends[0])), ("end", -1.0, float(height), float(radii_ends[1]))):
        if r_end < 4.0:
            continue
        wall_min = max(1.0, 2.0 * noise_mm) if secondary else max(1.5, 0.06 * r_end)
        depth = sign * (h - h_end)
        cand = inward & (depth >= -slab) & (depth < height) & (radius > 0.2 * r_end) & (radius < r_end - wall_min)
        if cand.sum() < 30:
            continue
        k_of = np.clip(np.floor(np.maximum(depth, 0.0) / slab).astype(int), 0, nb - 1)
        counts = np.bincount(k_of[cand], minlength=nb)
        sector = ((azimuth + 180.0) / (360.0 / sectors)).astype(int) % sectors
        # The mouth: the inner wall over the first three slabs.
        mouth = cand & (k_of <= 2)
        if mouth.sum() < 30 or counts[:2].max() < 8:
            continue
        r0 = float(np.median(radius[mouth]))
        members = mouth & (np.abs(radius - r0) <= tol_r(r0))
        if members.sum() < 20:
            continue
        r0 = float(np.median(radius[members]))
        share = len(np.unique(sector[members])) / float(sectors)
        if share < 0.5:
            if debug:
                print("bore? %s end: an inner wall r %.1f seen in only %.0f%% of the sectors" % (end, r0, 100 * share))
            continue
        wall = r_end - r0
        if wall < wall_min:
            if debug:
                print("bore? %s end: r %.1f inside r %.1f is a %.1f mm wall, under %.1f" % (end, r0, r_end, wall, wall_min))
            continue
        # Nothing standing in the mouth: a stem or a nut inside a collar
        # faces OUT inside the collar's radius (a hydrant's operating nut
        # in the raised ring on its bonnet), and the ring is a recess round
        # it, not a bore.
        standing = (depth >= -slab) & (depth < 3 * slab) & (radius < r0 - wall_min) & (n_radial > 0.5)
        if standing.sum() > 0.25 * members.sum():
            if debug:
                print("bore? %s end: %d points face out inside r %.1f at the mouth — something stands in it" % (
                    end, int(standing.sum()), r0 - wall_min))
            continue
        # Walk inward slab by slab while the inner wall keeps its radius; a
        # step to a new radius (held for two slabs) starts a new run; one
        # sparse slab is stepped over when the next agrees.
        n_min = max(8, int(0.15 * counts[:3].max()))
        med = np.full(nb, np.nan)
        for k in range(nb):
            sel = cand & (k_of == k)
            if sel.sum() >= n_min:
                med[k] = float(np.median(radius[sel]))
        if debug:
            print("bore? %s end (r %.1f, wall ≥ %.1f): inner wall per %.0f mm slab: %s" % (
                end, r_end, wall_min, slab, " ".join("%d:%s" % (counts[k], "-" if np.isnan(med[k]) else "%.1f" % med[k])
                                                        for k in range(min(nb, 40)))))
        def ok(k):
            """Enough inner wall in slab k — and a wall's worth of body
            outside it: the outer profile must be at least `wall_min`
            wider there, or the "bore" would be wider than the part."""
            if not (k < nb and counts[k] >= n_min and not np.isnan(med[k])):
                return False
            if outer_r is None:
                return True
            h_k = (k + 0.5) * slab if end == "start" else height - (k + 0.5) * slab
            return float(outer_r(h_k)) >= med[k] + wall_min

        runs = []                     # [r, first slab, last slab]
        r_cur, start = r0, 0
        last = -1
        k = 0
        while k < nb:
            if ok(k) and abs(med[k] - r_cur) <= tol_r(r_cur):
                last = k
                k += 1
                continue
            # Up to two slabs of transition (a chamfer, a thread's run-out,
            # a sparse slab): the wall again at its radius, or a new
            # radius held for two slabs — a step.
            move = None
            for j in range(k, min(k + 3, nb)):
                if ok(j) and abs(med[j] - r_cur) <= tol_r(r_cur):
                    move = ("same", j)
                    break
                if ok(j) and ok(j + 1) and abs(med[j + 1] - med[j]) <= tol_r(med[j]) and last >= start:
                    move = ("step", j)
                    break
            if move is None:
                break
            if move[0] == "same":
                k = move[1]
                continue
            runs.append([r_cur, start, last])
            r_cur, start, last = float(med[move[1]]), move[1], move[1]
            k = move[1] + 1
        if last >= start:
            runs.append([r_cur, start, last])
        # Neighbouring runs that agree to the tolerance are one run (a slab
        # or two of jitter had split them).
        merged = []
        for run in runs:
            if merged and abs(run[0] - merged[-1][0]) <= tol_r(max(run[0], merged[-1][0])):
                merged[-1][2] = run[2]
                continue
            merged.append(run)
        runs = merged
        if not runs:
            continue
        depth_mm = float(min((runs[-1][2] + 1) * slab, height))
        r_in = min(run[0] for run in runs)
        # Nothing standing in the hole over its depth: a nut or a stem
        # faces OUT inside the bore's radius (a hydrant's operating nut
        # sits 28 mm down in the raised ring on its bonnet), and seen
        # round the circle it is in the hole, not a stray patch — the ring
        # is a recess round it, not a bore.
        standing = (depth >= -slab) & (depth < depth_mm + 2 * slab) & (radius < r_in - wall_min) & (n_radial > 0.5)
        if standing.sum() >= 20 and len(np.unique(sector[standing])) >= 0.5 * sectors:
            if debug:
                print("bore? %s end: %d points face out inside r %.1f within %.0f mm of the mouth — something stands in the hole" % (
                    end, int(standing.sum()), r_in - wall_min, depth_mm + 2 * slab))
            continue
        # The floor, where the scanner saw it: points inside the bore's
        # radius facing back toward the mouth, round a good part of the
        # circle. A hole with a floor is never through.
        floor = None
        if n_axial is not None or caps is not None:
            f_depth, f_radius, f_sector = depth, radius, sector
            f_axial = n_axial if n_axial is not None else np.zeros(len(h))
            if caps is not None and len(caps[0]):
                f_depth = np.concatenate([f_depth, sign * (np.asarray(caps[0], dtype=float) - h_end)])
                f_radius = np.concatenate([f_radius, np.asarray(caps[1], dtype=float)])
                f_sector = np.concatenate([f_sector, ((np.asarray(caps[2], dtype=float) + 180.0) / (360.0 / sectors)).astype(int) % sectors])
                f_axial = np.concatenate([f_axial, np.asarray(caps[3], dtype=float)])
            on_floor = ((-sign * f_axial) > 0.5) & (f_radius < r_in - wall_min) & (f_depth >= 2 * slab) & (f_depth <= height)
            if debug:
                print("bore? %s end: %d points inside r %.1f face the mouth%s" % (
                    end, int(on_floor.sum()), r_in - wall_min,
                    "" if not on_floor.sum() else " — a floor at %.0f mm (median), round %.0f%% of the circle" % (
                        float(np.median(f_depth[on_floor])), 100.0 * len(np.unique(f_sector[on_floor])) / sectors)))
            if on_floor.sum() >= 20 and len(np.unique(f_sector[on_floor])) >= 0.3 * sectors:
                floor = float(np.median(f_depth[on_floor]))
        through = floor is None and depth_mm >= 0.85 * height
        if through:
            depth_mm = float(height)
        elif floor is not None:
            if debug and depth_mm >= 0.85 * height:
                print("bore? %s end: the wall runs %.0f mm but a floor is seen %.0f mm in — not through" % (end, depth_mm, floor))
            depth_mm = float(min(depth_mm, max(floor, 2.0 * slab)))
        if depth_mm < max(2.0 * slab, 3.0):
            continue
        if not secondary and not through and depth_mm > open_end_depth(height) and r0 > 0.6 * r_end:
            if debug:
                print("bore? %s end: %.0f mm deep and r %.1f of %.1f — a container's cavity, left to the open-end test" % (
                    end, depth_mm, r0, r_end))
            continue
        # Each run's radius from all its member points, and the profile as
        # steps: [r, depth] from the end plane inward.
        profile = []
        for i, (r_run, k0, k1) in enumerate(runs):
            sel = cand & (k_of >= k0) & (k_of <= k1) & (np.abs(radius - r_run) <= tol_r(r_run))
            r_run = float(np.median(radius[sel])) if sel.sum() >= 8 else float(r_run)
            d0 = 0.0 if i == 0 else float(k0 * slab)
            d1 = depth_mm if i == len(runs) - 1 else float((k1 + 1) * slab)
            profile.append([round(r_run, 2), round(d0, 1)])
            profile.append([round(r_run, 2), round(d1, 1)])
        found.append({"end": end, "rInnerMM": round(float(profile[0][0]), 2), "depthMM": round(depth_mm, 1),
                      "wallMM": round(r_end - float(profile[0][0]), 2), "share": round(share, 3), "through": bool(through),
                      "profile": profile})
    if len(found) == 2 and (found[0]["through"] or found[1]["through"]
                            or found[0]["depthMM"] + found[1]["depthMM"] >= height - slab):
        # Two bores that meet are one through bore, read from the end that
        # showed more of its wall.
        keep = max(found, key=lambda b: (b["share"], b["depthMM"]))
        keep["through"], keep["depthMM"] = True, round(float(height), 1)
        keep["profile"][-1][1] = round(float(height), 1)
        found = [keep]
    return found


def passage_depth(points, normals, c_mouth, d_in, r_last, tol_mm, slab_mm, max_depth_mm, floor_from_mm,
                  beyond_mm=0.0, debug=False, label=""):
    """How far a branch's bore runs on into the body it joins — the passage
    (`detect_bores` reads the bore on the branch's own faces, and the loop
    that cuts it ends where the branch's own wall ends; the union into the
    parent fills the hole wherever the parent is solid, while the scanner
    saw the passage continue through the parent's chamber). Walks slabs of
    max(`slab_mm`, 2 mm) along the branch's axis (`d_in`, a unit vector
    pointing into the body from the free end's plane through `c_mouth`)
    over the WHOLE scan's sampled points (`points`, `normals` — not the
    body's labelled faces: the chamber's walls are the parent's), inside a
    cylinder of the bore's last radius `r_last` (plus `tol_mm`).

    - "Surface inside the cylinder": a point within r_last + tol of the axis
      that does not face away from the mouth (n·d_in < 0.5 — the parent's
      far skin, where the axis leaves it, faces away, and is no interior).
    - A floor: a slab with at least N points at radius < 0.6 r_last whose
      normal faces back toward the mouth (n·d_in < −0.5), looked for from
      `floor_from_mm` on (the bore's own depth less a slab: the bore's own
      floor, if it had one, is found again there and nothing is deeper).
      N = max(10, 0.15 × W), W the most points a slab of the bore's wall
      (|r − r_last| ≤ tol) holds over the three slabs before `floor_from_mm`
      — a floor fully seen holds about 0.18 r/slab of a wall slab's
      points, so 0.15 W asks for a sixth of a full floor, and ten points
      is the least a patch and not a stray takes. The parent's outer skin,
      where the branch's cylinder passes through it on the near side, is
      outside the cylinder (the branch's wall is wider than its bore) and
      its inner wall round the hole's edge is at the cylinder's radius,
      not under 0.6 of it; the far skin faces away.
    - The depth: the floor's depth (the median of that slab's floor points)
      when one is seen, else the far end of the deepest slab with at least
      max(5, 0.1 W) points of surface inside the cylinder; both capped at
      `max_depth_mm` (the caller's: a wall short of where the axis leaves
      the parent's envelope). The walk looks `beyond_mm` past the cap so a
      surface beyond it (something behind the part) is seen for what it
      is; a floor beyond the cap is not the passage's floor.

    Returns (depth, floor_seen, seen_depth, capped): `seen_depth` the far
    end of the deepest slab with surface inside the cylinder (up to the
    floor's slab when a floor is seen), `capped` when the cap and not the
    scan set the depth. All in mm from the mouth plane."""
    slab = max(float(slab_mm), 2.0)
    d_in = np.asarray(d_in, dtype=float)
    d_in = d_in / max(np.linalg.norm(d_in), 1e-12)
    c_mouth = np.asarray(c_mouth, dtype=float)
    max_depth = max(float(max_depth_mm), 0.0)
    walk_end = max_depth + max(float(beyond_mm), 0.0)
    floor_from = max(float(floor_from_mm), 0.0)
    pts = np.asarray(points, dtype=float)
    nrm = np.asarray(normals, dtype=float)
    rel = pts - c_mouth
    h = rel @ d_in
    near = (h >= 0.0) & (h < walk_end + slab)
    if near.sum() < 10:
        return (min(floor_from, max_depth), False, 0.0, False)
    rel, h, nrm = rel[near], h[near], nrm[near]
    r = np.linalg.norm(rel - np.outer(h, d_in), axis=1)
    along = nrm @ d_in
    inside = r <= r_last + tol_mm
    nb = int(math.ceil((walk_end + slab) / slab)) + 1
    k_of = np.clip(np.floor(h / slab).astype(int), 0, nb - 1)
    wall = inside & (np.abs(r - r_last) <= tol_mm)
    k_from = int(math.floor(floor_from / slab))
    ref_lo = max(0, k_from - 3)
    wall_counts = np.bincount(k_of[wall], minlength=nb)
    W = int(wall_counts[ref_lo:k_from].max()) if k_from > ref_lo else int(wall_counts[:max(k_from, 1)].max())
    n_floor = max(10, int(round(0.15 * W)))
    n_seen = max(5, int(round(0.1 * W)))
    surface = inside & (along < 0.5)
    on_floor = inside & (r < 0.6 * r_last) & (along < -0.5) & (h >= floor_from)
    surf_counts = np.bincount(k_of[surface], minlength=nb)
    floor_counts = np.bincount(k_of[on_floor], minlength=nb)
    k_end = int(math.floor(walk_end / slab))
    floor_k, floor_depth = None, None
    for k in range(k_from, min(k_end, nb - 1) + 1):
        if floor_counts[k] >= n_floor:
            floor_k = k
            floor_depth = float(np.median(h[on_floor & (k_of == k)]))
            break
    last_k = floor_k if floor_k is not None else min(k_end, nb - 1)
    seen = [k for k in range(0, last_k + 1) if surf_counts[k] >= n_seen]
    seen_depth = float(min((seen[-1] + 1) * slab, walk_end)) if seen else 0.0
    if debug:
        print("passage? %s: r %.1f (+%.1f) from %.0f mm, cap %.0f mm, wall ref %d (floor ≥ %d, surface ≥ %d) — surface/floor per %.0f mm slab: %s" % (
            label, r_last, tol_mm, floor_from, max_depth, W, n_floor, n_seen, slab,
            " ".join("%d:%d/%d" % (k * slab, surf_counts[k], floor_counts[k]) for k in range(k_from, min(k_end, nb - 1) + 1))))
    if floor_depth is not None:
        if floor_depth <= max_depth:
            return (float(floor_depth), True, seen_depth, False)
        return (max_depth, False, seen_depth, True)
    if seen_depth > max_depth:
        return (max_depth, False, seen_depth, True)
    return (seen_depth, False, seen_depth, False)


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
        deep_limit = lift + open_end_depth(height)
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


# Sections (`trace_sections`): when a revolve is not enough — see
# `section_gate` for where these come from.
LOFT_MIN_RMS_MM = 1.5          # the sectors must stray more than this (and twice the noise) from the revolve
LOFT_MIN_SHARE = 0.4           # … and the sections must take this share of it away
AXIS_DOMINANT_SHARE = 0.75     # a straight drift of the centre that does this much of it is a tilted axis


def sector_angles(sectors=36):
    """The centre azimuth of each sector of the band loop's grid, radians
    (sector j covers −180° + j·360°/sectors onward, as `sector_of`)."""
    return np.radians(-180.0 + (np.arange(sectors) + 0.5) * 360.0 / sectors)


def section_basis(theta):
    """r(θ) = c0 + c1 cos θ + s1 sin θ + c2 cos 2θ + s2 sin 2θ: the first
    harmonic is the section's centre off the axis (a circle of radius R
    centred at (cx, cy) reads R + cx cos θ + cy sin θ to first order), the
    second an oval (an ellipse a × b at angle φ reads (a + b)/2 +
    (a − b)/2 · cos 2(θ − φ))."""
    theta = np.asarray(theta, dtype=float)
    return np.column_stack([np.ones(len(theta)), np.cos(theta), np.sin(theta), np.cos(2 * theta), np.sin(2 * theta)])


def ellipse_radius(theta, cx, cy, mean, mx, my):
    """How far from the axis, along the ray at azimuth θ, an ellipse lies:
    centred at (cx, cy), semi-axes mean ± m with (mx, my) = m (cos 2φ,
    sin 2φ), the major axis at φ — exactly what a sector median measures,
    where `section_basis` is its first-order expansion. The two part ways
    when a ring is off the axis AND oval: a circle 15 mm off a 300 mm
    axis reads its mean radius 0.19 mm short and an oval it does not have
    of the same size (d²/4R), which the harmonics take for the ring's —
    the barrel's sections strayed up to 0.69 mm from their true ellipses."""
    theta = np.asarray(theta, dtype=float)
    m = math.hypot(mx, my)
    phi = 0.5 * math.atan2(my, mx)
    a2, b2 = (mean + m) ** 2, (mean - m) ** 2
    c, s = math.cos(phi), math.sin(phi)
    # The axis and the ray in the ellipse's own frame.
    ox, oy = -(c * cx + s * cy), s * cx - c * cy
    ux, uy = c * np.cos(theta) + s * np.sin(theta), -s * np.cos(theta) + c * np.sin(theta)
    A = ux * ux / a2 + uy * uy / b2
    B = 2.0 * (ox * ux / a2 + oy * uy / b2)
    C = ox * ox / a2 + oy * oy / b2 - 1.0
    return (-B + np.sqrt(np.maximum(B * B - 4.0 * A * C, 0.0))) / (2.0 * A)


def refine_ring(theta, radii, coef, iterations=6):
    """The two-harmonic fit (`section_basis`: c0, c1, s1, c2, s2) moved onto
    the ellipse itself (`ellipse_radius`: mean, cx, cy, mx, my — the same
    five numbers, read exactly): a few Gauss-Newton steps against the
    sector medians, from the harmonic solution. Returns the coefficients."""
    p = np.array(coef, dtype=float)
    if p[0] <= 0.0:
        return p
    for _ in range(iterations):
        f = ellipse_radius(theta, p[1], p[2], p[0], p[3], p[4])
        J = np.empty((len(theta), 5))
        for k in range(5):
            q = p.copy()
            q[k] += 1e-4
            J[:, k] = (ellipse_radius(theta, q[1], q[2], q[0], q[3], q[4]) - f) / 1e-4
        step, *_ = np.linalg.lstsq(J, np.asarray(radii, dtype=float) - f, rcond=None)
        p = p + step
        if float(np.max(np.abs(step))) < 1e-6:
            break
    return p


def widest_empty_deg(keep):
    """The widest run of sectors NOT in `keep` (wrapping round), degrees."""
    n = len(keep)
    if keep.all():
        return 0.0
    if not keep.any():
        return 360.0
    present = np.where(keep)[0]
    runs = np.diff(np.concatenate([present, [present[0] + n]])) - 1
    return float(runs.max()) * 360.0 / n


def fit_section(medians, body, reach, point_noise, min_sectors=24, max_gap_deg=90.0, iterations=6):
    """One band's section from its sector medians: the band's ring as
    r(θ) = c0 + the first two harmonics (`section_basis`) — where its
    centre sits off the axis, how oval it is. Only the sectors on the
    body count: those the band loop's body cluster reached (`reach`, the
    same ±3·MAD window that made the mean circle), and of those, after
    each fit, only the ones within max(1 mm, 3× the noise, 3× the
    residual's MAD) of the fitted ring — a nozzle's flared root, a
    handle's foot or a cap's chain leaves the sectors it fills, and the
    ring is fitted again on the rest. Returns None when fewer than
    `min_sectors` of the 36 stay, or when they leave an empty arc wider
    than `max_gap_deg` (two harmonics fitted on half a circle are a guess,
    not a measurement); else {coef [c0, c1, s1, c2, s2] — the harmonics'
    sectors chosen, the five numbers then read off the ellipse itself
    (`refine_ring`: mean radius, centre, oval) — keep (bool per sector),
    residualMM (rms of what the ellipse leaves, on the kept sectors)}."""
    medians = np.asarray(medians, dtype=float)
    n = len(medians)
    theta = sector_angles(n)
    A = section_basis(theta)
    ok = ~np.isnan(medians)
    ok[ok] = np.abs(medians[ok] - body) <= max(reach, 3.0, 3.0 * point_noise)
    keep = ok.copy()
    coef = None
    for _ in range(iterations):
        if keep.sum() < min_sectors or widest_empty_deg(keep) > max_gap_deg:
            return None
        coef, *_ = np.linalg.lstsq(A[keep], medians[keep], rcond=None)
        res = np.where(ok, medians - A @ coef, np.inf)
        mad = float(np.median(np.abs(res[keep])))
        tol = max(1.0, 3.0 * point_noise, 3.0 * 1.48 * mad)
        new = ok & (np.abs(res) <= tol)
        if (new == keep).all():
            break
        keep = new
    if keep.sum() < min_sectors or widest_empty_deg(keep) > max_gap_deg:
        return None
    coef, *_ = np.linalg.lstsq(A[keep], medians[keep], rcond=None)
    coef = refine_ring(theta[keep], medians[keep], coef)
    res = medians[keep] - ellipse_radius(theta[keep], coef[1], coef[2], coef[0], coef[3], coef[4])
    residual = float(np.sqrt(np.mean(res ** 2)))
    # A ring the two harmonics describe: what they leave is the scanner's
    # noise (a dented barrel's dents, a cast surface's ripple), and the
    # centre and the oval are a few hundredths of the radius. A band that
    # leaves more is no slightly-out-of-round ring — an extinguisher's
    # valve and handle above its neck fit an "oval" of 22 mm on a 39 mm
    # radius, 10 mm of residual — and votes for nothing. The limit is the
    # noise's, not the radius's: 3 % of the pail's 180 mm let its rim
    # bands through at 4–5.5 mm (the lip's sector medians jump ±8 mm from
    # one sector to the next, on 0.95 mm of noise) and they pulled the
    # top sections 1.4 mm off the wall's own trend; every barrel band
    # (1.1–1.9 mm on 2.2 mm of noise) and every pail wall band (≤ 0.54)
    # still passes.
    if residual > max(1.5, 4.0 * point_noise):
        return None
    if math.hypot(coef[1], coef[2]) > 0.12 * body or math.hypot(coef[3], coef[4]) > 0.12 * body:
        return None
    return {"coef": coef, "keep": keep, "residualMM": residual}


def running(values, runs, width, how):
    """`values` (nan where unknown) smoothed along the bands by a running
    median or mean `width` bands wide, inside each run of bands
    separately (`runs`: a run id per band) — a profile step bounds the
    smoothing, so a lip's own centre is never averaged with the wall's."""
    out = np.array(values, dtype=float)
    half = width // 2
    for run in np.unique(runs):
        idx = np.where(runs == run)[0]
        v = np.asarray(values, dtype=float)[idx]
        for k in range(len(idx)):
            w = v[max(0, k - half): k + half + 1]
            w = w[~np.isnan(w)]
            if len(w):
                out[idx[k]] = float(np.median(w) if how == "median" else np.mean(w))
    return out


def section_field(bands, grid_med, grid_reach, step_heights, point_noise, band_mm, skip=None):
    """The section of every band as a smooth field along the axis: its mean
    radius against the band's one radius (`dr`: the band radius is the
    median of the sector medians, and the median of an oval ring that also
    sits off the axis is not its mean — up to 8 mm on the barrel's rim), its centre
    (c1, s1) in the azimuthZero / azimuthNinety frame and its oval (c2,
    s2: half the difference of the semi-axes is their length, the major
    axis at half their angle). Each band is fitted on its own
    (`fit_section`); the five numbers (linear in the fit, so they average
    without the wrap of an angle) are then run through a median and a
    mean about 15 mm wide, inside the runs between the profile's steps
    (`step_heights`): a band reads its centre to about the scanner's
    noise, the drift of a dented barrel runs over hundreds of
    millimetres, and a flange is a run of its own. A band with no fit (a
    filler, a band on a nut's flats, a band a handle half fills, the
    valve above an extinguisher's neck, every band of a run with fewer
    than three fitted) takes the field from its run's fitted neighbours,
    else from the nearest fitted band. Returns (rows,
    fitted) — rows: per band {h, dr, c1, s1, c2, s2, fitted, residualMM,
    sectors, keep}; `fitted` the number of bands fitted on their own."""
    hs = np.array([b["h"] for b in bands], dtype=float)
    runs = np.searchsorted(np.sort(np.asarray(step_heights, dtype=float)), hs) if len(step_heights) else np.zeros(len(bands), dtype=int)
    raw = np.full((len(bands), 5), np.nan)
    rows = []
    for i, b in enumerate(bands):
        fit = None
        if not b.get("filler") and not (skip is not None and skip[i]) and grid_med[i] is not None:
            fit = fit_section(grid_med[i], b["median"], grid_reach[i], point_noise)
        if fit is not None:
            raw[i] = [fit["coef"][0] - b["median"]] + list(fit["coef"][1:])
        rows.append({"h": float(b["h"]), "fitted": fit is not None,
                     "residualMM": fit["residualMM"] if fit else None,
                     "sectors": int(fit["keep"].sum()) if fit else 0,
                     "keep": fit["keep"] if fit else None})
    # A run of one or two fitted bands (a pail's 3 mm foot ring under its
    # first step) is a guess, not a field: one band there read the pail's
    # base 7 mm off the axis its whole wall shares to half a millimetre.
    # Such a run takes its neighbours' field like an unfitted one.
    for run in np.unique(runs):
        idx = np.where(runs == run)[0]
        if 0 < int((~np.isnan(raw[idx, 0])).sum()) < 3:
            raw[idx] = np.nan
            for i in idx:
                rows[i].update(fitted=False, keep=None, sectors=0, residualMM=None)
    fitted = int((~np.isnan(raw[:, 0])).sum())
    keys = ("dr", "c1", "s1", "c2", "s2")
    if fitted == 0:
        for r in rows:
            r.update({k: 0.0 for k in keys})
        return rows, 0
    width = max(3, int(round(15.0 / band_mm)) | 1)
    smooth = np.empty_like(raw)
    for k in range(raw.shape[1]):
        med = running(raw[:, k], runs, width, "median")
        smooth[:, k] = running(np.where(np.isnan(raw[:, k]), np.nan, med), runs, width, "mean")
    # Gaps: inside a run, linear between its fitted neighbours (and level
    # past its ends); a run with nothing fitted carries the nearest band's.
    have = ~np.isnan(smooth[:, 0])
    for run in np.unique(runs):
        idx = np.where(runs == run)[0]
        got = idx[have[idx]]
        if len(got):
            for k in range(raw.shape[1]):
                smooth[idx, k] = np.interp(hs[idx], hs[got], smooth[got, k])
    have = ~np.isnan(smooth[:, 0])
    for i in np.where(~have)[0]:
        j = np.where(have)[0][np.argmin(np.abs(hs[have] - hs[i]))]
        smooth[i] = smooth[j]
    for r, values in zip(rows, smooth):
        r.update({k: float(x) for k, x in zip(keys, values)})
    return rows, fitted


def profile_steps(profile, epsilon):
    """The heights of the profile's steps — a level edge (a flange's shelf,
    a chime's floor) or one that runs out far more than it rises — which
    bound the section field's smoothing and the build's lofts."""
    out = []
    for (r0, h0), (r1, h1) in zip(profile, profile[1:]):
        dr, dh = abs(r1 - r0), abs(h1 - h0)
        if dr > max(2.0, 2.0 * epsilon) and dh <= 0.34 * dr:
            out.append(round(0.5 * (h0 + h1), 4))
    return out


def roundness_of(bands, grid_med, rows, point_noise):
    """How far the sectors stray from the revolve, and how much of that the
    sections take away — over the fitted bands, weighted by radius (a
    millimetre on a 300 mm drum is more surface than on a 20 mm stem):
    `sector` the kept sector medians against the band's one radius (what
    a revolve leaves), `centre` against the smoothed section's mean radius
    and centre, `oval` with its oval as well (what a loft through the
    smoothed sections leaves), `axis` against the band radius moved by
    only the straight-line drift of the centre along the axis (what a
    re-fitted, tilted axis would leave). Returns (rms {sector, centre,
    oval, axis}, the drift's line {lineX, lineY, shift0, shift1, h0, h1,
    tiltDeg}) or (None, None) with no band fitted."""
    sse = {"sector": 0.0, "centre": 0.0, "oval": 0.0, "axis": 0.0}
    weight = 0.0
    used = [(b, med, row) for b, med, row in zip(bands, grid_med, rows) if row["fitted"]]
    if not used:
        return None, None
    hs = np.array([row["h"] for _, _, row in used])
    cxs = np.array([row["c1"] for _, _, row in used])
    cys = np.array([row["s1"] for _, _, row in used])
    sw = np.sqrt(np.array([float(b["median"]) for b, _, _ in used]))
    # The straight line through the centres (weighted least squares).
    G = np.column_stack([np.ones(len(hs)), hs])
    line_x, *_ = np.linalg.lstsq(G * sw[:, None], cxs * sw, rcond=None)
    line_y, *_ = np.linalg.lstsq(G * sw[:, None], cys * sw, rcond=None)
    for b, med, row in used:
        keep = row["keep"]
        theta = sector_angles(len(med))[keep]
        dev = np.asarray(med, dtype=float)[keep] - b["median"]
        mean = float(b["median"]) + row["dr"]
        centre = ellipse_radius(theta, row["c1"], row["s1"], mean, 0.0, 0.0) - b["median"]
        oval = ellipse_radius(theta, row["c1"], row["s1"], mean, row["c2"], row["s2"]) - b["median"]
        ax = ellipse_radius(theta, line_x[0] + line_x[1] * row["h"], line_y[0] + line_y[1] * row["h"],
                            float(b["median"]), 0.0, 0.0) - b["median"]
        w = float(b["median"])
        sse["sector"] += w * float(np.sum(dev ** 2))
        sse["centre"] += w * float(np.sum((dev - centre) ** 2))
        sse["oval"] += w * float(np.sum((dev - oval) ** 2))
        sse["axis"] += w * float(np.sum((dev - ax) ** 2))
        weight += w * len(dev)
    rms = {k: math.sqrt(v / weight) for k, v in sse.items()}
    h0, h1 = float(hs.min()), float(hs.max())
    shift0 = [float(line_x[0] + line_x[1] * h0), float(line_y[0] + line_y[1] * h0)]
    shift1 = [float(line_x[0] + line_x[1] * h1), float(line_y[0] + line_y[1] * h1)]
    tilt = math.degrees(math.atan(math.hypot(line_x[1], line_y[1])))
    return rms, {"lineX": [float(x) for x in line_x], "lineY": [float(y) for y in line_y],
                 "shift0": shift0, "shift1": shift1, "h0": h0, "h1": h1, "tiltDeg": tilt}


def section_gate(rms, point_noise):
    """Which body the sections ask for: "revolve" (one profile about one
    straight axis carries it), "axis" (the sections are round but their
    centres drift along a straight line — the axis is off: re-fit it and
    keep the revolve) or "loft" (a body through the sections). Returns
    (build, why).

    The thresholds are read off the corpus (2026-10-26; sector medians
    against the band's one radius, rms over the fitted bands): the parts
    that are round sit at 0.10 (the spray can), 0.20 (the clean
    extinguisher), 0.42 (the mug), 0.45 (the valve), 0.51 (the rusty
    extinguisher), 0.60 (the bollard) and 0.89 mm (the hydrant, its
    nozzles' roots and the bonnet's lobes in it); the two that are not
    sit at 3.21 (the pail, an oval growing from 0.7 to 6.9 mm up to its
    rim) and 6.51 mm (the barrel, its centre walking 20 mm and an oval of
    up to 12). 1.5 mm — three quarters of the app's tightest tolerance
    (2 mm), with a margin of 0.6 mm over the least round revolve and 1.7
    mm under the least out-of-round loft — and twice the scanner's noise
    (a noisy scan's sectors stray by the noise alone: the barrel's 2.2 mm
    would ask for 4.3). Then the sections must take away 40 % of it: the
    pail's take 89 %, the barrel's 69 %; a part whose stray is dents,
    ribs or lumps (what two harmonics cannot say) keeps its revolve. And
    the cheaper answer first: when a straight-line drift of the centre
    along the axis takes away three quarters of what the full sections
    do, the axis is what is wrong — a tilted, re-fitted axis keeps the
    revolve, and only what is left after it can ask for a loft (on the
    corpus the line takes 3 % of it on the barrel and 9 % on the pail:
    theirs is an oval and a wandering centre, not a tilt)."""
    s, l, a = rms["sector"], rms["oval"], rms["axis"]
    floor = max(LOFT_MIN_RMS_MM, 2.0 * point_noise)
    if s <= floor:
        return "revolve", "round: the sectors stray %.2f mm rms, within %.2f mm (max of %.1f mm and twice the %.2f mm noise)" % (
            s, floor, LOFT_MIN_RMS_MM, point_noise)
    gain = (s - l) / s if s > 0 else 0.0
    if gain < LOFT_MIN_SHARE:
        return "revolve", "the sectors stray %.2f mm rms but centre and oval take only %.0f%% of it (dents, ribs or lumps, not a section)" % (
            s, 100 * gain)
    if s - a >= AXIS_DOMINANT_SHARE * (s - l):
        return "axis", "the centres drift along a straight line: a re-fitted axis takes %.2f of the %.2f mm the sections would" % (
            s - a, s - l)
    return "loft", "the sectors stray %.2f mm rms; the sections take %.0f%% of it, to %.2f mm" % (s, 100 * gain, l)


def trace_sections(bands, grid_med, grid_reach, profile, epsilon, nuts, point_noise, band_mm, traced=False, secondary=False):
    """Sections: the ring round every band, not only its one radius — where
    its centre sits off the axis and how oval it is (`section_field`), and
    whether a revolve can carry the part or a loft through the sections
    must (`section_gate`). Returns (sections, roundness): sections per band
    {h, cxMM, cyMM, drMM, aMM, bMM, angleDeg, residualMM, sectors, fitted}
    (cx, cy the ring's centre in the azimuthZero / azimuthNinety frame; a
    and b its semi-axes, about the band radius moved by drMM; the major
    axis at angleDeg from azimuthZero toward azimuthNinety; residualMM what
    the two harmonics leave on the band's own fit), roundness
    {sectorRmsMM, afterCentreMM, afterOvalMM, afterAxisMM, tiltDeg,
    axisShiftMM, axisLine, bandsFitted, bands, steps, build, why}."""
    steps = profile_steps(profile, epsilon)
    skip = np.array([any(n["h0"] - band_mm <= b["h"] <= n["h1"] + band_mm for n in nuts or []) for b in bands], dtype=bool)
    rows, fitted = section_field(bands, grid_med, grid_reach, steps, point_noise, band_mm, skip=skip)
    rms, drift = roundness_of(bands, grid_med, rows, point_noise)
    sections = []
    for b, row in zip(bands, rows):
        m = math.hypot(row["c2"], row["s2"])
        r0 = float(b["median"]) + row["dr"]
        sections.append({"h": round(row["h"], 3), "cxMM": round(row["c1"], 3), "cyMM": round(row["s1"], 3),
                         "drMM": round(row["dr"], 3), "aMM": round(r0 + m, 3), "bMM": round(r0 - m, 3),
                         "angleDeg": round(math.degrees(0.5 * math.atan2(row["s2"], row["c2"])), 2),
                         "residualMM": None if row["residualMM"] is None else round(row["residualMM"], 3),
                         "sectors": row["sectors"], "fitted": row["fitted"]})
    roundness = {"bandsFitted": fitted, "bands": len(bands), "steps": steps, "build": "revolve"}
    if rms is None:
        roundness["why"] = "no band has enough of its circle on the body to fit a section"
        print("out of round: no band fitted (%d bands) — revolved" % len(bands))
        return sections, roundness
    build, why = section_gate(rms, point_noise)
    if traced and build != "revolve":
        build, why = "revolve", "a traced half-section (a dished part) is revolved as it is; the sections would ask for a %s (%s)" % (build, why)
    if secondary and build != "revolve":
        build, why = "revolve", "a body on its own axis is revolved (its root is trimmed and lengthened into its parent, which the sections do not follow); the sections would ask for a %s (%s)" % (build, why)
    roundness.update({"sectorRmsMM": round(rms["sector"], 3), "afterCentreMM": round(rms["centre"], 3),
                      "afterOvalMM": round(rms["oval"], 3), "afterAxisMM": round(rms["axis"], 3),
                      "tiltDeg": round(drift["tiltDeg"], 3),
                      "axisShiftMM": [[round(x, 2) for x in drift["shift0"]], [round(x, 2) for x in drift["shift1"]]],
                      "axisLine": {"h0": round(drift["h0"], 3), "h1": round(drift["h1"], 3),
                                   "x": [round(x, 7) for x in drift["lineX"]], "y": [round(y, 7) for y in drift["lineY"]]},
                      "build": build, "why": why})
    print("out of round: the sectors stray %.2f mm rms from the revolve; %.2f after the centre, %.2f after the oval, %.2f after a re-fitted axis (tilt %.2f°), %d of %d bands fitted — %s: %s" % (
        rms["sector"], rms["centre"], rms["oval"], rms["axis"], drift["tiltDeg"], fitted, len(bands), build, why))
    return sections, roundness


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


def polygon_radius(theta, sides, apothem, phase):
    """The distance from the axis to a regular polygon's outline at the
    azimuth `theta` (radians): apothem / cos of the angle from the nearest
    flat's normal. `phase` is the azimuth of one flat's outward normal."""
    period = 2 * math.pi / sides
    t = ((np.asarray(theta, dtype=float) - phase + period / 2) % period) - period / 2
    return apothem / np.cos(t)


def fit_polygon(theta, r, sides, step_deg=1.0):
    """The regular `sides`-gon that best follows the sector radii `r` at
    the azimuths `theta` (radians): the phase (a flat's normal) searched
    in `step_deg` steps over one period, the apothem the median of
    r · cos(angle from that flat's normal) — on a true polygon that
    product is the apothem in every sector. Returns (median residual,
    phase, apothem, residual per sector)."""
    theta, r = np.asarray(theta, dtype=float), np.asarray(r, dtype=float)
    period = 2 * math.pi / sides
    phases = np.arange(0.0, period, math.radians(step_deg))
    t = ((theta[None, :] - phases[:, None] + period / 2) % period) - period / 2
    c = np.cos(t)
    a = np.median(r[None, :] * c, axis=1)
    res = np.abs(r[None, :] - a[:, None] / c)
    score = np.median(res, axis=1)
    k = int(np.argmin(score))
    return float(score[k]), float(phases[k]), float(a[k]), res[k]


def find_nuts(h, radius, azimuth, facing, band_mm, point_noise, sides=(4, 6, 8), sectors=72, min_share=0.8,
              min_height=4.0, debug=False):
    """Polygonal bands on the axis — a hex nut, a square collar, an
    octagonal boss — on the surface the points describe: over windows of
    height, for each radius level the window's outward-facing points
    cluster at, the radius against azimuth (`sectors` sectors; a
    hexagon's flats are 60° wide, so 72 of 5° resolve them) is fitted
    with a regular n-gon (`fit_polygon`) for each n in `sides`. The
    n-gon is taken when at least `min_share` of ALL the sectors lie
    within a tolerance of it (max(3 × the scanner's noise, 0.5 mm,
    2.5 % of the apothem)), its residual is under half the circle's
    (the same sectors against their median radius — a round collar
    fits a circle better than any polygon), and the corner stands
    clear above the flat by max(1 mm, 2.5 tolerances): an octagon of
    apothem 22 mm rises 1.8 mm at its corners and is within a noisy
    scan's reach, a hexagon of the same size 3.4 mm. Windows that agree
    on n, the apothem (within max(1 mm, 4 %)) and the phase (within 4°)
    join into one record; a record is at least two windows and
    `min_height` tall. Returns [{h0, h1, sides, acrossFlatsMM,
    phaseDeg, share, contrastMM, residualMM}], `phaseDeg` the azimuth
    of one flat's outward normal in [0, 360 / n) — the sketch's x axis
    for `build_hydrant.nut_sections`."""
    h, radius, azimuth = np.asarray(h, dtype=float), np.asarray(radius, dtype=float), np.asarray(azimuth, dtype=float)
    keep = np.asarray(facing, dtype=bool) & (radius > 1.0)
    h, radius, azimuth = h[keep], radius[keep], azimuth[keep]
    if len(h) < 100:
        return []
    window = max(2.0 * band_mm, 2.0)
    sector_of = ((azimuth + 180.0) / (360.0 / sectors)).astype(int) % sectors
    theta = np.radians((np.arange(sectors) + 0.5) * (360.0 / sectors) - 180.0)
    rows = []                                    # (h_lo, h_hi, sides, apothem, phase, share, contrast, residual)
    for lo in np.arange(float(h.min()), float(h.max()), window):
        sel = (h >= lo) & (h < lo + window)
        if sel.sum() < 4 * sectors:
            continue
        r_w, s_w = radius[sel], sector_of[sel]
        # The radius levels the window's surface sits at: the modes of a
        # 1 mm histogram, at least 4 mm apart, each holding a tenth of the
        # points (a nut inside a crown: two levels in one window).
        bins = np.arange(0.0, r_w.max() + 2.0, 1.0)
        counts, _ = np.histogram(r_w, bins)
        levels = []
        for k in np.argsort(counts)[::-1]:
            if counts[k] < max(30, 0.1 * len(r_w)):
                break
            centre = bins[k] + 0.5
            if all(abs(centre - lv) >= 4.0 for lv in levels):
                levels.append(centre)
            if len(levels) >= 3:
                break
        best_row = None
        for level in levels:
            near = np.abs(r_w - level) <= 1.5
            if near.sum() < 20:
                continue
            level = float(np.median(r_w[near]))
            for n in sides:
                reach = level / math.cos(math.pi / n)
                tol = max(3.0 * point_noise, 0.5, 0.025 * level)
                band = (r_w >= level - 2.0 * tol - 1.0) & (r_w <= reach + 2.0 * tol + 1.0)
                r_sec = np.full(sectors, np.nan)
                for j in range(sectors):
                    rj = r_w[band & (s_w == j)]
                    if len(rj) >= 3:
                        r_sec[j] = np.median(rj)
                present = ~np.isnan(r_sec)
                if present.sum() < min_share * sectors:
                    continue
                score, phase, apothem, res = fit_polygon(theta[present], r_sec[present], n)
                if apothem <= 1.0:
                    continue
                contrast = apothem / math.cos(math.pi / n) - apothem
                circle = float(np.median(np.abs(r_sec[present] - np.median(r_sec[present]))))
                share = float((res <= tol).sum()) / sectors
                ok = (share >= min_share and score <= 0.5 * circle and score <= tol
                      and contrast >= max(1.0, 2.5 * tol))
                if debug:
                    print("nut? h %.0f level %.1f n %d: apothem %.1f phase %.0f° share %.2f residual %.2f (circle %.2f) contrast %.1f tol %.2f %s" % (
                        lo, level, n, apothem, math.degrees(phase), share, score, circle, contrast, tol, "OK" if ok else ""))
                if ok and (best_row is None or score / contrast < best_row[7] / best_row[6]):
                    best_row = (lo, lo + window, n, apothem, phase, share, contrast, score)
        if best_row is not None:
            rows.append(best_row)
    # Windows that agree join into one nut.
    nuts, group = [], []

    def close(group):
        if len(group) < 2:
            return
        h0, h1 = group[0][0], group[-1][1]
        if h1 - h0 < min_height:
            return
        n = group[0][2]
        apothem = float(np.median([g[3] for g in group]))
        period = 2 * math.pi / n
        phase = math.atan2(np.mean([math.sin(g[4] * n) for g in group]), np.mean([math.cos(g[4] * n) for g in group])) / n
        phase %= period
        nuts.append({"h0": round(float(h0), 2), "h1": round(float(h1), 2), "sides": int(n),
                     "acrossFlatsMM": round(2.0 * apothem, 2), "phaseDeg": round(math.degrees(phase), 2),
                     "share": round(float(np.mean([g[5] for g in group])), 3),
                     "contrastMM": round(float(np.mean([g[6] for g in group])), 2),
                     "residualMM": round(float(np.mean([g[7] for g in group])), 3)})

    for row in rows:
        if group:
            last = group[-1]
            period = 360.0 / row[2]
            d_phase = abs((math.degrees(row[4] - last[4]) + period / 2) % period - period / 2)
            same = (row[2] == last[2] and abs(row[0] - last[1]) < 1e-6
                    and abs(row[3] - last[3]) <= max(1.0, 0.04 * last[3]) and d_phase <= 4.0)
            if not same:
                close(group)
                group = []
        group.append(row)
    close(group)
    return nuts


def nut_samples(mesh, origin, axis, u, v, samples=60000, h_range=None, r_max=None, seed=7):
    """Points over the whole mesh's surface in a body's frame — (h, radius,
    azimuth in degrees, facing out) — for `find_nuts`: a nut's flats are
    faces no normal line through the axis claims, so the faces labelled
    a body's own may lack them, and the detector reads the scan itself
    about the body's axis, within `h_range` and `r_max`."""
    if not len(mesh.faces):
        return None
    pts, face_index = trimesh.sample.sample_surface(mesh, int(samples), seed=seed)
    pts = np.asarray(pts, dtype=float)
    normals = np.asarray(mesh.face_normals, dtype=float)[face_index]
    h = (pts - origin) @ axis
    perp = (pts - origin) - np.outer(h, axis)
    radius = np.linalg.norm(perp, axis=1)
    keep = np.ones(len(h), dtype=bool)
    if h_range is not None:
        keep &= (h >= h_range[0]) & (h <= h_range[1])
    if r_max is not None:
        keep &= radius <= r_max
    with np.errstate(invalid="ignore", divide="ignore"):
        facing = (perp * normals).sum(axis=1) > 0.2 * radius
    azimuth = np.degrees(np.arctan2(perp @ v, perp @ u))
    return h[keep], radius[keep], azimuth[keep], facing[keep]


def clamp_bands_to_nuts(bands, nuts, point_noise):
    """The band radii over a nut's span held to its apothem — the revolve
    then runs inside the flats and the polygon prism carries the
    corners; a round ring at the mean radius pokes out of the flats and
    misses the corners. Only a band that sits on the nut's own level is
    clamped: a hex nut inside a crown (the hydrant's) leaves the crown's
    ring alone. Returns how many bands moved."""
    moved = 0
    for nut in nuts:
        a = nut["acrossFlatsMM"] / 2.0
        reach = a / math.cos(math.pi / nut["sides"])
        slack = max(1.0, 3.0 * point_noise)
        for b in bands:
            if nut["h0"] - 1e-6 <= b["h"] <= nut["h1"] + 1e-6 and a < b["median"] <= reach + slack:
                b["median"] = a
                moved += 1
    return moved


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
            axis_choice="auto", flip=False, samples=200000, multi=True, secondary=False, axis_origin=None,
            up_rule="y", _reflipped=False, source=None, nut_mesh=None, _axis_refit=False):
    """The scan as a body of revolution: its axis, the profile along it,
    the bosses off it. With `multi`, the axis finder (`fit_axes`) looks for
    more bodies of revolution first — a valve's pipe, branches and side
    port on their own axes — and each is traced on its own (this function
    again, `secondary=True`: no ground trim, no bosses, no flip, the given
    axis kept) and listed under `bodies`; the main trace then sees only
    the faces that are the main body's or nobody's. `nut_mesh` is the
    mesh the polygonal-band detector (`find_nuts`) reads instead of this
    one — the whole scan, for a body traced on its own faces."""
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
    if up_rule == "y" and abs(axis[1]) > math.cos(math.radians(30.0)):
        base_at_low = axis[1] > 0
    else:
        base_at_low = not (low_r < high_r)
    if flip:
        base_at_low = not base_at_low
    if secondary or _axis_refit:
        # A secondary body keeps the direction it was given; so does the
        # re-trace on a re-fitted axis (`section_gate`'s "axis"), whose
        # direction is the first trace's, already standing on its base.
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
    # A sidewalk reaches far beyond the part; a drum's floor disc spreads
    # its radii just as widely but stays inside the body's radius, and
    # is the floor (trimmed, the drum read as open at the bottom).
    mid = (h > lo + 0.3 * span) & (h < hi - 0.3 * span) & own_v
    body_guess = float(np.median(radius[mid])) if mid.sum() >= 50 else float(np.median(radius[own_v])) if own_v.any() else 0.0
    reach = []
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1]) & own_v
        spread.append(np.percentile(radius[sel], 80) - np.percentile(radius[sel], 20) if sel.sum() >= 20 else np.nan)
        reach.append(np.percentile(radius[sel], 80) if sel.sum() >= 20 else np.nan)
    spread = np.array(spread)
    reach = np.array(reach)
    base_index = 0
    for i in range(min(12, len(spread))):
        if not np.isnan(spread[i]) and spread[i] > 60 and reach[i] > 1.25 * body_guess:
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
    # The axial-facing samples (an end face, a shelf, a floor) are kept
    # apart for the bore detector: a hole's floor is where they face back
    # toward its mouth, and the trace itself never sees them.
    cap_h, cap_perp, cap_n_axial = np.zeros(0), np.zeros((0, 3)), np.zeros(0)
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
        cap_h, cap_perp, cap_n_axial = s_h[~side], s_perp[~side], s_normals[~side] @ axis
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
    cap_radius = np.linalg.norm(cap_perp, axis=1)
    cap_azimuth = np.degrees(np.arctan2(cap_perp @ v, cap_perp @ u))

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
    grid_reach = []    # per band: how far from the body radius the body cluster reached
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
        grid_reach.append(float(reach) if len(agreed) >= 4 else max(3.0, 3.0 * point_noise))
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
            grid_reach.insert(len(filled) - 1, grid_reach[len(filled) - 2])
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
        grid_reach = grid_reach[: len(bands)]
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
    drop_h = 0.0
    if first:
        bands = bands[first:]
        grid_med, grid_reach = grid_med[first:], grid_reach[first:]
        drop_h = bands[0]["h"] - band_mm / 2
        height -= drop_h
        for b in bands:
            b["h"] -= drop_h
        for b in bosses:
            b["centerHeightMM"] = round(b["centerHeightMM"] - drop_h, 1)
        origin = origin + axis * drop_h
    # Polygonal bands on the axis — a hex nut, a square collar — read off
    # the scan itself about this axis (`nut_samples`: a nut's flats are
    # faces no normal line claims, so a body's own faces may lack them),
    # in the frame the profile is in. The bands over a nut are held to
    # its apothem (`clamp_bands_to_nuts`): the revolve runs inside the
    # flats and the build's polygon prism carries the corners.
    nuts = []
    nut_source = nut_mesh if nut_mesh is not None else (cropped if cropped is not None else mesh)
    if len(bands) >= 2 and nut_source is not None and len(nut_source.faces):
        # Dense enough that a 2 mm window round a 22 mm nut holds a few
        # points in every 5° sector: about three per mm² of the scan.
        nut_count = int(min(3_000_000, max(3 * int(samples or 0), 600_000, 3.0 * float(nut_source.area))))
        sampled_nuts = nut_samples(nut_source, origin, axis, u, v, samples=nut_count,
                                   h_range=(-band_mm, height + band_mm), r_max=3.0 * float(body_r.max()) + 10.0)
        if sampled_nuts is not None:
            nuts = find_nuts(*sampled_nuts, band_mm=band_mm, point_noise=point_noise, debug=debug)
        for nut in nuts:
            print("nut: a %d-sided %s %.0f mm across the flats over h %.0f–%.0f (flat normal at %.0f°, %.0f%% of the sectors within tolerance)" % (
                nut["sides"], "hex nut" if nut["sides"] == 6 else ("square collar" if nut["sides"] == 4 else "octagonal nut"),
                nut["acrossFlatsMM"], nut["h0"], nut["h1"], nut["phaseDeg"], 100 * nut["share"]))
        if nuts:
            clamp_bands_to_nuts(bands, nuts, point_noise)
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
    # But a dished wheel first: a band of a tyre on a hub holds two full
    # rings far apart, and from the hub side the rim's dish reads as an
    # open end 260 mm deep (the truck wheel's rays fell into the dish and
    # through the hub's bore, and the "cavity" cut the rim away, 21 mm
    # mean deviation). The dish test asks for proper rings (six tenths
    # of the circle) 40 mm apart: an open container's floor sits a wall's
    # thickness in from its skin and is no dish, so a bucket and a drum
    # keep their cavity cut.
    cell = max(band_mm, 2.0)
    dish = (not secondary) and is_dished(surface_grid(h, radius, azimuth, cell, min_share=0.6), cell, min_gap_mm=40.0)
    open_top = None if (secondary or dish) else detect_open_top(cropped if cropped is not None else mesh, origin, axis, u, v,
                                                                height, ends, bands, radius, h, facing=facing)
    if dish:
        print("dished: two rings in one band (a tyre on a hub) — the half-section is traced; no open end is looked for")
    if open_top:
        print("open %s: rays from outside fall %.0f mm in (or through) on %.0f%% of that end; wall %.1f mm — the revolve will be shelled" % (
            open_top["end"], open_top["depthMM"], open_top["share"] * 100, open_top["wallMM"]))
    if open_top and open_top["end"] == "bottom" and not secondary and not _reflipped and up_rule == "y":
        # An open container stands on its closed end: a drum whose open
        # rim came out at the bottom under the +Y rule (its file's +Y
        # points at the floor — or it has no floor at all, and rays fall
        # through either way) is traced again by the wider-end rule.
        print("open at the bottom: traced again with the wider end as the base")
        return analyze(mesh, band_mm=band_mm, lump_margin_mm=lump_margin_mm, out_dir=out_dir, name=name,
                       epsilon=epsilon, debug=debug, axis_choice=axis_choice, flip=flip, samples=samples,
                       multi=multi, secondary=secondary, axis_origin=axis_origin, up_rule="wider", _reflipped=True,
                       source=source, nut_mesh=nut_mesh, _axis_refit=_axis_refit)
    # One radius per height cannot describe a dished wheel: a band there
    # holds two full rings far apart (the tyre and the hub) with nothing
    # between. Such a part gets its whole half-section traced instead.
    with np.errstate(invalid="ignore", divide="ignore"):
        n_radial = np.where(radius > 1e-9, (perp * normals).sum(axis=1) / np.maximum(radius, 1e-9), 0.0)
    n_axial = normals @ axis
    surface_mask, cell_normals = surface_grid(h, radius, azimuth, cell, n_radial=n_radial, n_axial=n_axial)
    # The dish test ran above, before the open end was looked for (a
    # valve's stem, branch and side port together fill half the sectors
    # of one band and are no ring; a bucket's floor is no dish).
    dished = dish
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
    # A bore at a free end: an open pipe end, a coupling's socket, a
    # recessed port. Not where the open-end test or the traced section
    # already describe the hollow — a bucket's open top is no bore.
    bores = []
    if not (open_top or dished or section_loop):
        # The scanner's noise as the band says it (3× the noise, 1–4 mm):
        # a small body's own estimate can read 3 mm on a 0.03 mm scan.
        bores = detect_bores(h - drop_h, radius, azimuth, n_radial, height, ends, band_mm,
                             noise_mm=min(point_noise, band_mm / 3.0), secondary=secondary, debug=debug,
                             profile=simplified, n_axial=n_axial,
                             caps=(cap_h - drop_h, cap_radius, cap_azimuth, cap_n_axial))
    for b in bores:
        print("bore at the %s: r %.1f inside r %.1f (a %.1f mm wall), %.0f mm deep%s, seen round %.0f%% of the circle%s" % (
            b["end"], b["rInnerMM"], b["rInnerMM"] + b["wallMM"], b["wallMM"], b["depthMM"],
            " (through)" if b["through"] else "", 100 * b["share"],
            "" if len(b["profile"]) <= 2 else "; steps %s" % " ".join("r %.1f to %.0f" % (r, d) for r, d in b["profile"][1::2])))

    sections, roundness = trace_sections(bands, grid_med, grid_reach, simplified, epsilon, nuts, point_noise, band_mm,
                                         traced=bool(section_loop), secondary=secondary)
    if _axis_refit:
        roundness["axisRefitted"] = True
    if roundness["build"] == "axis":
        if _axis_refit:
            # Once only: a second re-fit asking for a third is a drift the
            # line cannot settle; the revolve stays on this axis.
            roundness.update(build="revolve", why=roundness["why"] + " — already re-fitted once; revolved on this axis")
        else:
            # The centres' straight line is the axis: through the centre at
            # h = 0 (this origin's level), along the axis leaned by the
            # line's slope in u and v. The whole trace runs again on it —
            # ground, bands, profile, bosses, bores, sections.
            line = roundness["axisLine"]
            new_origin = origin + line["x"][0] * u + line["y"][0] * v
            new_axis = axis + line["x"][1] * u + line["y"][1] * v
            new_axis = new_axis / np.linalg.norm(new_axis)
            print("axis re-fitted from the sections: moved %.2f mm at the foot, tilted %.2f°; traced again on it" % (
                math.hypot(line["x"][0], line["y"][0]), roundness["tiltDeg"]))
            return analyze(mesh, band_mm=band_mm, lump_margin_mm=lump_margin_mm, out_dir=out_dir, name=name,
                           epsilon=epsilon, debug=debug, axis_choice="%.9f,%.9f,%.9f!" % tuple(new_axis), flip=False,
                           samples=samples, multi=multi, secondary=secondary, axis_origin=new_origin, up_rule=up_rule,
                           _reflipped=_reflipped, source=source, nut_mesh=nut_mesh, _axis_refit=True)

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
        "nuts": nuts,
        "openTop": open_top,
        "bores": bores,
        "bosses": bosses,
        "sections": sections,
        "roundness": roundness,
        "boundsMM": {"min": [float(x) for x in mesh.bounds[0]], "max": [float(x) for x in mesh.bounds[1]]},
        "bodies": [],
    }
    if selection is not None and len(selection["axes"]) >= 2:
        analysis["axes"] = [{k: ax[k] for k in ("origin", "direction", "share", "lengthMM", "radiusMM", "parent", "junction")}
                            for ax in selection["axes"]]
        analysis["bodies"] = secondary_bodies(mesh, selection, face_labels, name, samples, lump_margin_mm,
                                              band_mm=band_mm, epsilon=epsilon, debug=debug)
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
        if source is not None:
            # The model's colour comes from the scan's own texture, read off
            # the source file: `mesh` may be a cropped or concatenated copy
            # whose texture the exporter could not carry.
            colour = scan_color_record(source)
            if colour is not None:
                analysis["scanColor"] = colour
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
        for nut in a.get("nuts") or []:
            nut["h0"], nut["h1"] = round(nut["h0"] + start_mm, 2), round(nut["h1"] + start_mm, 2)
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
        # A nut keeps its span in the new frame — one at the root is cut
        # off with the root here and runs on into the parent, which is
        # where it sits.
        for nut in a.get("nuts") or []:
            nut["h0"], nut["h1"] = round(nut["h0"] - lo, 2), round(nut["h1"] - lo, 2)
    a["profile"] = [[round(float(r), 2), round(float(hh), 2)] for r, hh in profile]
    a["profileSegments"] = segments
    a["heightMM"] = round(hi - lo, 2)
    a["trimmedMM"] = [round(float(start_mm), 2), round(float(end_mm), 2)]
    return a


def passage_record(a, bore, scan_samples, parent, debug=False, label=""):
    """The `passage` record for a secondary body's bore at its FREE end (see
    `passage_depth`), or None when the hole the scan shows runs no deeper
    than the hole the model has by more than a slab. The model's hole is the
    bore the loop cuts (`depthMM`) only as far as the parent's skin: the
    union into the parent fills it from where the axis enters the parent's
    envelope on (the valve's oblique branch is bored 52 mm by its own faces
    and its parent's skin is 38 mm in, so the built model's hole stopped at
    38 and the scan's floor at 51 sat inside the solid). So the depth the
    record carries is the deeper of the passage walk's and the bore's own
    (never less than `depthMM`), and it is recorded when that exceeds
    min(`depthMM`, the entry depth) by more than a slab.

    `a` is the body in its FINAL frame (after `trim_profile` /
    `extend_profile`), `scan_samples` (points, normals) over the whole
    scan, `parent` the axis finder's record of the body it joins (origin,
    direction, extent, envelope). The cap is where the body's axis,
    followed inward from the mouth, leaves the parent's envelope
    (`fit_axes.inside_body`), less max(2 mm, the bore's wall) — the passage
    never comes out through the parent's far skin."""
    import fit_axes
    points, normals = scan_samples
    origin = np.asarray(a["axisOrigin"], dtype=float)
    axis = np.asarray(a["axisDirection"], dtype=float)
    height = float(a["heightMM"])
    if bore["end"] == "start":
        c_mouth, d_in = origin, axis
    else:
        c_mouth, d_in = origin + axis * height, -axis
    r_last = float(bore["profile"][-1][0]) if bore.get("profile") else float(bore["rInnerMM"])
    wall = max(2.0, float(bore.get("wallMM") or 0.0))
    slab = max(float(a.get("bandMM") or 2.0), 2.0)
    tol = max(1.5, float(a.get("bandMM") or 0.0))
    # Along the axis from the mouth, 1 mm at a time: into the parent's
    # envelope and out of it again.
    reach = height + 4.0 * float(parent.get("radiusMM") or 0.0) + 20.0
    hs = np.arange(0.0, reach, 1.0)
    inside = fit_axes.inside_body(c_mouth + np.outer(hs, d_in), parent, 0.0)
    if not inside.any():
        return None
    k_in = int(np.argmax(inside))
    h_enter = float(hs[k_in])
    after = np.where(~inside[k_in:])[0]
    capped_by = float(hs[k_in + after[0]]) if len(after) else None
    max_depth = (capped_by - wall) if capped_by is not None else float(hs[-1])
    depth_bore = float(bore["depthMM"])
    if max_depth < depth_bore:
        return None                 # the bore itself runs out past the cap: nothing sane to add
    depth, floor_seen, seen, capped = passage_depth(points, normals, c_mouth, d_in, r_last, tol, slab, max_depth,
                                                   max(depth_bore - slab, 0.0), beyond_mm=wall + 2.0 * slab,
                                                   debug=debug, label=label)
    depth = max(float(depth), depth_bore)
    if depth <= min(depth_bore, h_enter) + slab:
        return None
    # `intoParentMM`: how much of the cut lies inside the parent — past the
    # entry — which is what the union filled and what the build's words say
    # (a passage no deeper than the bore still runs that far into it).
    return {"depthMM": round(depth, 2), "rMM": round(r_last, 2), "floor": bool(floor_seen),
            "capped": bool(capped), "seenMM": round(float(seen), 2),
            "intoParentMM": round(max(depth - h_enter, 0.0), 2)}, h_enter


def secondary_bodies(mesh, selection, face_labels, name, samples, lump_margin_mm, band_mm=None, epsilon=None, debug=False):
    """Every body of revolution the axis finder found beyond the main one,
    traced on its own axis — the faces labelled its own, `analyze` again
    with that axis fixed — and lengthened into the body it runs into.
    Returns the list for `analysis["bodies"]` (profile, segments, frame,
    parent, junction), in the finder's order."""
    bodies = []
    keys = ("name", "axisOrigin", "axisDirection", "azimuthZero", "azimuthNinety", "heightMM", "profile",
            "profileSegments", "bodyRadiusMM", "maxRadiusMM", "bandMM", "epsilonMM", "noiseMM", "topNotARingMM",
            "extendedMM", "trimmedMM", "nuts", "bores", "roundness")
    import fit_axes
    jobs = []
    scan_samples = None            # the whole scan sampled with normals, once, for the passages
    for k, ax in enumerate(selection["axes"][1:], 1):
        faces_k = np.where(face_labels == k)[0]
        if len(faces_k) < 50:
            continue
        if ax["junction"] == "through" and ax["parent"] is not None:
            # One axis through the parent (a hydrant's twin side nozzles)
            # is two bodies, one each side of it, each running into it:
            # the stretch inside the parent is no profile (the barrel's
            # skin cut obliquely made arcs of 164 mm the app refused).
            parent = selection["axes"][ax["parent"]]
            c, d = np.asarray(ax["origin"], dtype=float), np.asarray(ax["direction"], dtype=float)
            hs = np.arange(ax["hMin"], ax["hMax"], 1.0)
            inside = fit_axes.inside_body(c + np.outer(hs, d), parent, 0.0)
            if inside.any():
                h_in, h_out = float(hs[inside].min()), float(hs[inside].max())
                centres = (np.asarray(mesh.triangles_center)[faces_k] - c) @ d
                low, high = faces_k[centres < h_in], faces_k[centres > h_out]
                for side, faces_s, junction in (("a", low, "end"), ("b", high, "start")):
                    if len(faces_s) >= 50:
                        jobs.append((k, "%d%s" % (k, side), faces_s, dict(ax, junction=junction,
                                                                        junctionParentRadiusMM=float(parent["radiusMM"]))))
                continue
        jobs.append((k, str(k), faces_k, ax))
    for k, tag, faces_k, ax in jobs:
        sub = mesh.submesh([faces_k], append=True)
        d = np.asarray(ax["direction"], dtype=float)
        choice = "%.6f,%.6f,%.6f!" % tuple(d)
        print("== body %s: %d faces on its own axis" % (tag, len(faces_k)))
        try:
            # The scanner's noise is the scan's, not the body's: the main
            # trace's band and simplifier serve every body. The nut
            # detector reads the whole scan about this axis: a nut at the
            # root is seen before the root is trimmed, and its flats are
            # faces the labelling may not have given this body.
            a = analyze(sub, out_dir=None, name="%s-body%s" % (name, tag), axis_choice=choice,
                        axis_origin=np.asarray(ax["origin"], dtype=float), flip=False,
                        samples=max(40000, int(samples) // 3), multi=False, secondary=True,
                        lump_margin_mm=lump_margin_mm, band_mm=band_mm, epsilon=epsilon, nut_mesh=mesh, debug=debug)
        except Exception as error:  # noqa: BLE001 — a body too thin to trace is left to the residual fit
            print("   body %s not traced: %s" % (tag, error))
            continue
        if len(a["profile"]) < 3 or a["heightMM"] < 5:
            print("   body %s too short to keep (%d profile points over %.1f mm)" % (tag, len(a["profile"]), a["heightMM"]))
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
        # A bore is at a FREE end: whatever the tracer read at the junction
        # end is the parent's skin cut by the branch, and it is trimmed away.
        if ax["junction"] in ("start", "end"):
            kept_bores = []
            for b in a.get("bores", []):
                if b["end"] != ax["junction"]:
                    kept_bores.append(b)
                elif b.get("through"):
                    # A through bore read from the junction end is the same
                    # hole seen from the free end: one radius (the run nearest
                    # the free end), measured from there, so the trim of the
                    # root does not move its steps.
                    free = "end" if ax["junction"] == "start" else "start"
                    r_free = float(b["profile"][-1][0])
                    r_outer = float(a["profile"][-1][0] if free == "end" else a["profile"][0][0])
                    kept_bores.append(dict(b, end=free, rInnerMM=round(r_free, 2), wallMM=round(r_outer - r_free, 2),
                                           profile=[[round(r_free, 2), 0.0], [round(r_free, 2), b["depthMM"]]]))
            a["bores"] = kept_bores
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
        # The passage: the bore at the free end carried on along the axis
        # into the parent, as deep as the whole scan shows interior surface
        # inside it (`passage_depth`), never out through the parent's far
        # skin. Recorded on the bore only when it runs deeper than the
        # bore the loop cuts by more than a slab.
        if ax["junction"] in ("start", "end") and ax["parent"] is not None:
            free = "end" if ax["junction"] == "start" else "start"
            for b in a.get("bores", []):
                if b["end"] != free:
                    continue
                if scan_samples is None:
                    scan_samples = fit_axes.sample_with_normals(
                        mesh, int(min(1_500_000, max(300_000, 2.0 * float(mesh.area)))), seed=7)[:2]
                found = passage_record(a, b, scan_samples, selection["axes"][ax["parent"]], debug=debug,
                                       label="body %s" % tag)
                if found is not None:
                    passage, h_enter = found
                    b["passage"] = passage
                    print("   body %s: the bore (r %.1f, %.0f mm deep) runs on into body %s, %.0f mm past its skin (%.0f mm in), to %s %.0f mm%s" % (
                        tag, passage["rMM"], b["depthMM"], ax["parent"], passage["depthMM"] - h_enter, h_enter,
                        "a floor at" if passage["floor"] else ("a wall short of its far skin at" if passage["capped"]
                                                               else "as far as the scan shows it,"),
                        passage["depthMM"],
                        "" if passage["depthMM"] > b["depthMM"] else " — the bore's own depth; the union must not fill it"))
        body = {key: a[key] for key in keys if key in a}
        body.update({"index": k, "tag": tag, "parent": ax["parent"], "junction": ax["junction"],
                     "shareOfSurface": ax["share"], "finderRadiusMM": ax["radiusMM"], "finderLengthMM": ax["lengthMM"]})
        bodies.append(body)
        print("   body %s: %d profile points over %.0f mm, radius ~%.1f mm%s%s" % (
            tag, len(a["profile"]), a["heightMM"], a["bodyRadiusMM"],
            "" if not (start_mm or end_mm) else ", lengthened %.0f mm into body %s" % (start_mm or end_mm, ax["parent"]),
            "".join(", bored r %.1f %s at its %s" % (b["rInnerMM"], "right through" if b.get("through") else "%.0f mm deep" % b["depthMM"], b["end"])
                    for b in body.get("bores", []))))
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
    mesh, scale, scene = load_mesh(args.scan, args.units, keep_scene=True)
    name = os.path.splitext(os.path.basename(args.scan))[0]
    band = None if args.band == "auto" else float(args.band)
    epsilon = None if args.epsilon == "auto" else float(args.epsilon)
    a = analyze(mesh, band_mm=band, out_dir=args.out, name=name, epsilon=epsilon, debug=args.debug,
                axis_choice=args.axis, flip=args.flip, samples=args.samples, multi=not args.single, source=scene)
    print("scan: %d triangles, %.0f mm tall, body radius %.1f mm (file units x%g)" % (
        a["triangles"], a["heightMM"], a["bodyRadiusMM"], scale))
    if a.get("scanColor"):
        print("colour: rgb %s from the %s, %.0f%% of the surface" % (
            np.round(a["scanColor"]["rgb"], 2), a["scanColor"]["source"], a["scanColor"]["share"] * 100))
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
