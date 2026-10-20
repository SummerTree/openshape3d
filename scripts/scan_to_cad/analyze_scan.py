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
    inliers, re-run without far residuals. Returns (cu, cv, radius)."""
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
    return cu, cv, r


def fit_axis(points, up_guess, iterations=4, bands=40):
    """Refine the axis as the line through the centroids of slices along it;
    returns (point on axis, unit direction)."""
    axis = up_guess / np.linalg.norm(up_guess)
    origin = points.mean(axis=0)
    for _ in range(iterations):
        h = (points - origin) @ axis
        lo, hi = np.percentile(h, 3), np.percentile(h, 97)
        edges = np.linspace(lo, hi, bands + 1)
        centroids, heights = [], []
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
            cu, cv, _ = fit_circle(pu, pv)
            centroids.append(origin + cu * u + cv * v + axis * ((edges[i] + edges[i + 1]) / 2))
            heights.append((edges[i] + edges[i + 1]) / 2)
        centroids = np.array(centroids)
        if len(centroids) < 3:
            break
        direction, _, _ = principal_axis(centroids)
        if direction @ axis < 0:
            direction = -direction
        axis = direction
        origin = centroids.mean(axis=0)
    return origin, axis


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


def analyze(mesh, band_mm=4.0, lump_margin_mm=6.0, out_dir=None, name="scan"):
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
    # The scanner's ground: a band at the bottom whose radius jumps far
    # beyond the base flange. Trim it.
    bottom = np.percentile(h, 0.5)
    edges = np.arange(bottom, h.max() + band_mm, band_mm)
    med = []
    for i in range(len(edges) - 1):
        sel = (h >= edges[i]) & (h < edges[i + 1])
        med.append(np.median(radius[sel]) if sel.sum() >= 20 else np.nan)
    med = np.array(med)
    valid = np.where(~np.isnan(med))[0]
    base_index = valid[0]
    body_radius = np.nanmedian(med[valid[: max(3, len(valid) // 6)]])
    for i in valid[:6]:
        if med[i] > body_radius * 1.6:
            base_index = i + 1
    base_h = edges[base_index]
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
        # The body radius of the band: what most sectors agree on. A nozzle
        # fills a few sectors; a scanner hole empties a few; the 40th
        # percentile of the sector medians ignores both.
        agreed = smed[~np.isnan(smed)]
        body = float(np.percentile(agreed, 30)) if len(agreed) >= 4 else float(np.median(r))
        k = int(np.argmax(r))
        bands.append({"h": float((edges[i] + edges[i + 1]) / 2), "median": body,
                      "p20": float(np.percentile(r, 20)), "p80": float(np.percentile(r, 80)),
                      "max": float(r[k]), "maxAzimuth": float(azimuth[k]), "count": int(sel.sum())})
        grid_max.append(smax)
        grid_med.append(smed)
    grid_max = np.array(grid_max) if grid_max else np.zeros((0, sectors))
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
    for cells in blobs:
        if len(cells) < 4:
            continue
        # A blob that runs round most of a band is a ring — a flange step or
        # the dome's shoulder straddling two bands — not a boss.
        per_band = {}
        for ci, cj in cells:
            per_band.setdefault(ci, set()).add(cj)
        if max(len(s) for s in per_band.values()) >= sectors * 0.45:
            continue
        excess = np.array([grid_max[ci, cj] - body_r[ci] for ci, cj in cells])
        heights = np.array([bands[ci]["h"] for ci, cj in cells])
        angles = np.radians(np.array([(cj + 0.5) * (360 / sectors) - 180 for ci, cj in cells]))
        w = excess / excess.sum()
        centre_h = float((heights * w).sum())
        az = math.degrees(math.atan2((np.sin(angles) * w).sum(), (np.cos(angles) * w).sum()))
        # Reach along the boss direction and width across it, from the raw
        # points near the blob.
        d = math.cos(math.radians(az)) * u + math.sin(math.radians(az)) * v
        t = np.cross(axis, d)
        near = (np.abs(h - centre_h) < (heights.max() - heights.min()) / 2 + band_mm * 2)
        da = (azimuth[near] - az + 180) % 360 - 180
        near_idx = np.where(near)[0][np.abs(da) < 60]
        along = perp[near_idx] @ d
        across = perp[near_idx] @ t
        body_here = float(np.interp(centre_h, [b["h"] for b in bands], body_r))
        out = along > body_here + lump_margin_mm * 0.5
        if out.sum() < 20:
            continue
        reach = float(np.percentile(along[out], 99))
        width = float(np.percentile(across[out], 97.5) - np.percentile(across[out], 2.5))
        tall = float(np.percentile(h[near_idx][out], 97.5) - np.percentile(h[near_idx][out], 2.5))
        # Where the boss meets the body, it is narrower than at its cap: the
        # width over the inner half of the protrusion.
        inner = out & (along < body_here + (reach - body_here) * 0.5)
        neck = float(np.percentile(across[inner], 97.5) - np.percentile(across[inner], 2.5)) if inner.sum() >= 20 else width
        bosses.append({"azimuthDeg": round(az, 1), "centerHeightMM": round(centre_h, 1),
                       "reachMM": round(reach, 1), "widthMM": round(width, 1), "neckWidthMM": round(neck, 1),
                       "heightSpanMM": round(tall, 1), "bodyRadiusMM": round(body_here, 1), "cells": len(cells)})
    # A boss has height: a ring of proud cells one or two bands tall is a
    # step in the profile caught between two bands, not a nozzle.
    bosses = [b for b in bosses if b["reachMM"] - b["bodyRadiusMM"] >= 12 and b["heightSpanMM"] >= 3 * band_mm]
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

    # Polyline for the revolve: (radius, height) from the median profile.
    profile = [(b["median"], b["h"]) for b in bands]
    if profile:
        profile = [(profile[0][0], 0.0)] + profile + [(profile[-1][0], height)]
    simplified = douglas_peucker(profile, epsilon=1.5)

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
    args = ap.parse_args()
    mesh, scale = load_mesh(args.scan, args.units)
    name = os.path.splitext(os.path.basename(args.scan))[0]
    a = analyze(mesh, band_mm=args.band, out_dir=args.out, name=name)
    print("scan: %d triangles, %.0f mm tall, body radius %.1f mm (file units x%g)" % (
        a["triangles"], a["heightMM"], a["bodyRadiusMM"], scale))
    print("axis origin", np.round(a["axisOrigin"], 1), "direction", np.round(a["axisDirection"], 3))
    print("profile points:", len(a["profile"]))
    for b in a["bosses"]:
        print("boss at %6.1f° height %5.1f reach %5.1f width %5.1f span %5.1f" % (
            b["azimuthDeg"], b["centerHeightMM"], b["reachMM"], b["widthMM"], b["heightSpanMM"]))
    print("wrote", os.path.join(args.out, "profile.json"))


if __name__ == "__main__":
    main()
