#!/usr/bin/env python3
"""Does the CAD model actually look like the scan? Numbers decide, pictures
show where — measured both ways, against a stated tolerance, and laid out on
one sheet a person (or an assistant with eyes) reads at full size.

    python3 inspect_fit.py --reference run/scan.stl --model run/part-cad.stl --out qa/ \
        [--tolerance 3] [--up y] [--title "Bucket"]

Writes into `--out`:

    checks.json   every check with its value, its limit, PASS / WARN / FAIL
                  and the sentence that says why
    review.png    one sheet: for front, right, top and an isometric view, the
                  reference and the model shaded the same way, their
                  silhouettes laid over each other (blue where the model
                  lacks material, orange where it has too much), and the
                  depth difference seen from that side on the same colours;
                  the three largest missing (blue, M1–M3) and excess
                  (orange, E1–E3) patches ringed and numbered on the
                  reference and depth tiles, one legend line each
    views/*.png   the same tiles one by one, full size, and patches.png —
                  the shaded reference from the four sides with only the
                  patch marks on it

Why both ways and why depth: a silhouette overlap says nothing about a
bucket modelled as a solid drum (the outline matches), and a reference-to-
model distance says nothing either (every scan point is near SOME model
surface). The model-to-reference distance finds the drum's lid, and the
depth map seen from above shows it as a sheet of orange where the eye saw
a hollow. A dome cut into terraces hides in a mean deviation of 2 mm and
shows as alternating blue and orange bands along the height — the terrace
check counts the sign changes.

The checks (limits scale with `--tolerance`, which defaults to 1 % of the
longest extent, at least 0.5 mm):

    size          each extent of the bounding box, model minus reference
    volume        model / reference, when both meshes are closed
    ref_to_model  mean, 95th percentile and max distance from the reference
                  surface to the model; the share within tolerance
    model_to_ref  the same from the model's surface; the share of the
                  MODEL'S AREA farther than 3 tolerances — excess material
    silhouette    overlap (IoU) per view at ~1000 px, and the worst of 20
                  horizontal strips, so a bad top does not hide in a good
                  body
    depth         per view, the share of the shared silhouette where the
                  surfaces seen from that side differ by more than 3
                  tolerances, split into missing and excess
    terraces      sign changes of the mean signed error along the up axis
                  (more than two = ridges or steps where the reference is
                  smooth)
    largest_missing_patch / largest_excess_patch
                  the area of the biggest connected region of reference
                  surface farther than 1.5 tolerances from the model (the
                  scan has material the model lacks) and of model surface
                  farther than that from the reference (the model has
                  material the scan lacks). WARN above max(300 mm², 0.25 %
                  of the reference area), FAIL above max(1000 mm², 1 %)

Why patches: a mean deviation and a silhouette overlap are owned by the big
turned body. A valve at 94 % overlap has its whole lever missing, and a mean
of 0.7 mm hides a 60 mm part because it is small. A person judges by the
biggest thing that is wrong, so the inspection finds it: the far samples
of each direction are joined into connected regions (a radius graph on the
samples, radius 2.5 × the mean sample spacing) and the largest region is a
check of its own, located in words relative to the part's bounds and up
axis ("in the upper third, on the left, towards the front") so the
sentence names the missing lever. Samples are dense enough that a 10 mm
feature is a patch of twenty-odd samples (one sample per 15 mm² of
surface, at least 40 000 and at most 120 000 per mesh — the cap only binds
on the barrel and the truck wheel, at 30–37 mm² a sample). The threshold
is 1.5 tolerances, not one: at one tolerance a scan's noise and a
hydrant's cast detail cover more than a quarter of the surface and the far
samples percolate into a single patch the size of the part.

Everything is millimetres. Pure numpy + trimesh (+ pillow for the sheet);
no app needed, so it runs on any exported pair.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

try:
    import trimesh
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("pip install trimesh numpy scipy rtree pillow  (or run with the scan_to_cad venv)")

VIEWS = ("front", "right", "top", "iso")
PX = 1000             # pixels across the longest extent for silhouettes (fewer when the surface is large)
MAX_SAMPLES = 5_000_000   # per mesh per view; ~1 GB of working memory — beside a running simulator, 8 M was killed
DIST_SAMPLES = 40_000          # per mesh for the two-way distances, at least; more on a large surface (see distance_samples)
MAX_DIST_SAMPLES = 120_000     # the exact closest-point query costs ~35 µs a sample; 120k keeps the truck wheel near 20 s
MM2_PER_SAMPLE = 15.0          # one sample per 15 mm² of surface: a 10 mm feature is a patch of twenty-odd samples
PATCH_FAR = 1.5                # a sample is "far" beyond this many tolerances (see the docstring on why not 1)
PATCH_RADIUS = 2.5             # neighbours within this many mean sample spacings are one patch
PATCH_KEEP = 5                 # patches of each kind kept in checks.json
PATCH_MARK = 3                 # patches of each kind ringed on the sheet


# ---- loading -------------------------------------------------------------

def load(paths):
    meshes = []
    for p in paths:
        m = trimesh.load(p, force="mesh")
        if isinstance(m, trimesh.Scene):
            m = trimesh.util.concatenate(list(m.dump()))
        meshes.append(m)
    mesh = meshes[0] if len(meshes) == 1 else trimesh.util.concatenate(meshes)
    mesh.remove_unreferenced_vertices()
    return mesh


# ---- view frames ---------------------------------------------------------

def frame(view, up):
    """Rows: screen right, screen up, toward the viewer (world vectors)."""
    up_i = {"x": 0, "y": 1, "z": 2}[up]
    U = np.eye(3)[up_i]
    # Two horizontal axes, in world order after the up axis.
    others = [np.eye(3)[i] for i in range(3) if i != up_i]
    A, B = others[0], others[1]          # for up=y: A = x, B = z
    if view == "front":
        return np.array([A, U, B])       # looking along -B
    if view == "back":
        return np.array([-A, U, -B])
    if view == "right":
        return np.array([-B, U, A])      # looking along -A, from +A
    if view == "left":
        return np.array([B, U, -A])
    if view == "top":
        return np.array([A, -B, U])      # looking down the up axis
    if view == "bottom":
        return np.array([A, B, -U])
    if view == "iso":
        yaw, pitch = math.radians(-35.0), math.radians(28.0)
        r = math.cos(yaw) * A + math.sin(yaw) * B               # screen right
        f = -math.sin(yaw) * A + math.cos(yaw) * B              # horizontal toward viewer
        toward = math.cos(pitch) * f + math.sin(pitch) * U
        up_s = np.cross(toward, r)
        return np.array([r, up_s, toward])
    raise ValueError(view)


class Grid:
    """One orthographic pixel grid shared by both meshes for a view."""

    def __init__(self, bounds_lo, bounds_hi, F, px):
        corners = np.array([[x, y, z] for x in (bounds_lo[0], bounds_hi[0])
                            for y in (bounds_lo[1], bounds_hi[1]) for z in (bounds_lo[2], bounds_hi[2])])
        s = corners @ F.T
        self.F = F
        pad = 0.04 * (s.max(axis=0) - s.min(axis=0)).max()
        self.lo = s.min(axis=0) - pad
        self.hi = s.max(axis=0) + pad
        self.scale = px / (self.hi - self.lo)[:2].max()
        self.w = int(math.ceil((self.hi[0] - self.lo[0]) * self.scale)) + 1
        self.h = int(math.ceil((self.hi[1] - self.lo[1]) * self.scale)) + 1
        self.mm_per_px = 1.0 / self.scale

    def splat(self, mesh, samples=None):
        """Nearest-surface depth per pixel (toward the viewer is +), nan where empty.

        A point splat, not a rasteriser: enough samples that every pixel of
        every wall holds several, then the nearest depth over the pixel's
        3×3 neighbourhood. The neighbourhood matters — with two samples per
        pixel per wall, a tenth of the pixels hold only a BACK-wall sample
        and the depth there reads the part's whole thickness out. The
        density follows the pixel size: four samples per pixel-area of
        surface, between 1.2 and 8 million."""
        if samples is None:
            samples = int(np.clip(4.0 * mesh.area / self.mm_per_px ** 2, 1_200_000, MAX_SAMPLES))
        pts, _ = trimesh.sample.sample_surface(mesh, samples)
        pts = np.vstack([pts, mesh.vertices])
        s = pts @ self.F.T
        ix = ((s[:, 0] - self.lo[0]) * self.scale).astype(int)
        iy = ((self.hi[1] - s[:, 1]) * self.scale).astype(int)
        ok = (ix >= 0) & (ix < self.w) & (iy >= 0) & (iy < self.h)
        ix, iy, z = ix[ok], iy[ok], s[ok, 2]
        near = np.full(self.h * self.w, -np.inf)
        np.maximum.at(near, iy * self.w + ix, z)          # largest z = nearest to viewer
        near = near.reshape(self.h, self.w)
        from scipy.ndimage import maximum_filter
        depth = maximum_filter(near, size=3)
        depth[~np.isfinite(depth)] = np.nan
        return depth

    @staticmethod
    def fit_pixels(bounds_lo, bounds_hi, F, px, area):
        """Pixels across the longest extent such that 8 million samples
        still give four per pixel-area over `area` mm² of surface."""
        corners = np.array([[x, y, z] for x in (bounds_lo[0], bounds_hi[0])
                            for y in (bounds_lo[1], bounds_hi[1]) for z in (bounds_lo[2], bounds_hi[2])])
        s = corners @ F.T
        extent = (s.max(axis=0) - s.min(axis=0))[:2].max() * 1.08
        mm_per_px = max(extent / px, math.sqrt(4.0 * area / MAX_SAMPLES))
        return int(extent / mm_per_px)


# ---- pictures ------------------------------------------------------------

def shade(depth, rgb, mm_per_px, background=(28, 30, 34)):
    """Lambert shading from the depth map's own gradient."""
    h, w = depth.shape
    img = np.zeros((h, w, 3), dtype=np.float32)
    img[:] = background
    mask = np.isfinite(depth)
    if not mask.any():
        return Image.fromarray(img.astype(np.uint8))
    from scipy.ndimage import gaussian_filter
    floor = np.nanmin(depth)
    d = gaussian_filter(np.where(mask, depth, floor), sigma=1.2)     # the splat's grain, smoothed for the normals only
    gy, gx = np.gradient(d, mm_per_px)
    n = np.dstack([-gx, gy, np.ones_like(gx)])
    n /= np.linalg.norm(n, axis=2, keepdims=True) + 1e-9
    light = np.array([-0.4, 0.5, 0.75])
    light /= np.linalg.norm(light)
    lam = np.clip(n @ light, 0, 1)
    base = np.array(rgb, dtype=np.float32)
    col = base * (0.35 + 0.65 * lam[..., None])
    # Rim: the silhouette edge a touch darker, so outlines read.
    from scipy.ndimage import binary_erosion
    edge = mask & ~binary_erosion(mask, iterations=2)
    col[edge] *= 0.55
    img[mask] = col[mask]
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


HOLE_COLOUR = (72, 84, 100)      # seen through a hole in the scan: not judged


def silhouette_overlay(ref_mask, mod_mask, through_hole=None, background=(28, 30, 34)):
    h, w = ref_mask.shape
    img = np.zeros((h, w, 3), dtype=np.uint8)
    img[:] = background
    both = ref_mask & mod_mask
    missing = ref_mask & ~mod_mask
    excess = mod_mask & ~ref_mask
    img[both] = (150, 150, 150)
    img[missing] = (70, 130, 255)
    img[excess] = (255, 140, 40)
    if through_hole is not None:
        img[through_hole] = HOLE_COLOUR
    return Image.fromarray(img)


def depth_diff_image(ref_depth, mod_depth, tol, through_hole=None, background=(28, 30, 34)):
    """Grey within tolerance; blue where the model's surface is deeper (it
    lacks material), orange where it is nearer (it has too much); the
    silhouette-only parts in the same colours, dimmer; slate where the
    model shows through a hole in the scan."""
    h, w = ref_depth.shape
    img = np.zeros((h, w, 3), dtype=np.float32)
    img[:] = background
    if through_hole is not None:
        img[through_hole] = HOLE_COLOUR
    rm, mm = np.isfinite(ref_depth), np.isfinite(mod_depth)
    both = rm & mm
    d = np.zeros_like(ref_depth)
    d[both] = ref_depth[both] - mod_depth[both]      # + : ref nearer → model lacks material
    full = 5.0 * tol
    t = np.clip(np.abs(d) / full, 0, 1)
    grey = np.array([150, 150, 150], dtype=np.float32)
    blue = np.array([70, 130, 255], dtype=np.float32)
    orange = np.array([255, 140, 40], dtype=np.float32)
    col = np.where((d > tol)[..., None], grey + (blue - grey) * t[..., None],
                   np.where((d < -tol)[..., None], grey + (orange - grey) * t[..., None], grey))
    img[both] = col[both]
    img[rm & ~mm] = (40, 70, 140)
    img[mm & ~rm] = (140, 80, 25)
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


def font(size):
    for name in ("/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc",
                 "/Library/Fonts/Arial.ttf"):
        if os.path.exists(name):
            try:
                return ImageFont.truetype(name, size)
            except OSError:
                continue
    return ImageFont.load_default()


# ---- checks --------------------------------------------------------------

def verdict(value, warn, fail, higher_is_worse=True):
    if higher_is_worse:
        return "FAIL" if value > fail else "WARN" if value > warn else "PASS"
    return "FAIL" if value < fail else "WARN" if value < warn else "PASS"


def surface_distances(src, dst, n, seed=3):
    """Points sampled on `src`, their distance to `dst`, and for each the
    closest point on `dst` and its triangle."""
    pts, _ = trimesh.sample.sample_surface(src, n, seed=seed)
    closest, dist, tri = trimesh.proximity.closest_point(dst, pts)
    return pts, dist, (closest, tri)


def boundary_points(mesh, step=2.0):
    """Points every `step` mm along the mesh's open edges (none for a closed
    mesh). Straight from the edge table — an edge used by one face only —
    not from `outline()`, whose path tracing crawls through a scan's
    thousands of pinholes."""
    edges = mesh.edges_sorted
    once = trimesh.grouping.group_rows(edges, require_count=1)
    if len(once) == 0:
        return np.zeros((0, 3))
    a = mesh.vertices[edges[once, 0]]
    b = mesh.vertices[edges[once, 1]]
    length = np.linalg.norm(b - a, axis=1)
    pts = [a, b]
    # Fill the long edges with intermediate points.
    long = np.where(length > step)[0]
    for i in long:
        n = int(length[i] / step)
        t = np.linspace(0, 1, n + 1, endpoint=False)[1:, None]
        pts.append(a[i] + (b[i] - a[i]) * t)
    return np.vstack(pts)


def signed(dist, pts, container, closest):
    """+ outside the container (the container lacks material there), − inside
    — read off the container's face normal at the closest point. (A ray
    test, `contains`, was killed for memory on an 18k-face shell.)"""
    closest_pts, tri = closest
    outward = ((pts - closest_pts) * container.face_normals[tri]).sum(axis=1)
    s = dist.copy()
    s[outward < 0] *= -1
    return s


# ---- patches -------------------------------------------------------------

def distance_samples(area):
    """How many points to sample on a surface of `area` mm² for the two-way
    distances: one per 15 mm² so a 10 mm feature holds twenty-odd, within
    the floor the checks always had and a ceiling the query's cost sets."""
    return int(np.clip(area / MM2_PER_SAMPLE, DIST_SAMPLES, MAX_DIST_SAMPLES))


def horizontal_axes(up):
    """The two horizontal world axes in the order frame() uses them: A is
    screen right in the front view, B points toward the front viewer."""
    up_i = {"x": 0, "y": 1, "z": 2}[up]
    a, b = [i for i in range(3) if i != up_i]
    return up_i, a, b


def describe_location(centre, extent, lo, hi, up):
    """Where a patch sits, in words a person reads against the front view:
    thirds along the up axis, left / centre / right across the width, and
    towards the front or the back ("in the upper third, on the left,
    towards the front"). An axis the patch spans most of is said so
    instead of placed."""
    up_i, a, b = horizontal_axes(up)
    size = np.maximum(hi - lo, 1e-9)
    t = (np.asarray(centre) - lo) / size
    span = np.asarray(extent) / size

    def third(i, names, whole):
        if span[i] > 0.6:
            return whole
        return names[0] if t[i] < 1 / 3 else names[2] if t[i] > 2 / 3 else names[1]

    words = [third(up_i, ("in the lower third", "in the middle third", "in the upper third"), "over most of the height"),
             third(a, ("on the left", "in the centre", "on the right"), "across the width")]
    depth = third(b, ("towards the back", None, "towards the front"), "front to back")
    if depth:
        words.append(depth)
    return ", ".join(words)


def find_patches(pts, dist, far, area_per_sample, spacing, kind, lo, hi, up):
    """The far samples joined into connected regions: a radius graph on the
    samples (cKDTree pairs within PATCH_RADIUS mean spacings) and its
    connected components, largest area first. Each patch says what it is,
    how big, how far out and where, so the check's sentence can name it."""
    idx = np.where(far)[0]
    if len(idx) == 0:
        return []
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    from scipy.spatial import cKDTree
    p = pts[idx]
    pairs = cKDTree(p).query_pairs(PATCH_RADIUS * spacing, output_type="ndarray")
    n = len(idx)
    if len(pairs):
        graph = coo_matrix((np.ones(len(pairs)), (pairs[:, 0], pairs[:, 1])), shape=(n, n))
    else:
        graph = coo_matrix((n, n))
    count, label = connected_components(graph, directed=False)
    patches = []
    for k in range(count):
        members = idx[label == k]
        q = pts[members]
        d = dist[members]
        p_lo, p_hi = q.min(axis=0), q.max(axis=0)
        centre = 0.5 * (p_lo + p_hi)
        extent = p_hi - p_lo
        patches.append({
            "kind": kind,
            "areaMM2": round(float(len(members) * area_per_sample), 1),
            "samples": int(len(members)),
            "meanMM": round(float(d.mean()), 3),
            "maxMM": round(float(d.max()), 3),
            "centreMM": np.round(centre, 1).tolist(),
            "extentMM": np.round(extent, 1).tolist(),
            "location": describe_location(centre, extent, lo, hi, up),
        })
    patches.sort(key=lambda r: -r["areaMM2"])
    return patches


def patch_limits(reference_area):
    """WARN and FAIL areas for the largest patch: a fixed floor so a small
    part's lost knob still counts, scaled up on a big one so cast detail
    on a metre-tall hydrant does not."""
    return max(300.0, 0.0025 * reference_area), max(1000.0, 0.01 * reference_area)


def grouped(value):
    """2140 → '2 140', the way the sheet and the sentences print areas."""
    return "{:,.0f}".format(value).replace(",", " ")


def patch_sentence(kind, patch, reference_area, other):
    sides = sorted(patch["extentMM"], reverse=True)
    return "the largest %s patch is %s mm² (%.0f × %.0f mm, %.2f%% of the reference area) %s, %.1f mm from the %s on average, %.1f mm at most" % (
        kind, grouped(patch["areaMM2"]), sides[0], sides[1], 100.0 * patch["areaMM2"] / reference_area,
        patch["location"], patch["meanMM"], other, patch["maxMM"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference", action="append", required=True, help="scan mesh(es); several are merged")
    ap.add_argument("--model", action="append", required=True, help="CAD mesh(es); several are merged")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tolerance", type=float, default=None, help="mm; default 1%% of the longest extent, ≥ 0.5")
    ap.add_argument("--up", default="y", choices=("x", "y", "z"))
    ap.add_argument("--title", default=None)
    ap.add_argument("--model-color", type=float, nargs=3, default=[0.86, 0.17, 0.12])
    ap.add_argument("--patch-far", type=float, default=PATCH_FAR,
                    help="a sample this many tolerances out belongs to a patch (default %.1f; a calibration knob)" % PATCH_FAR)
    args = ap.parse_args()
    os.makedirs(os.path.join(args.out, "views"), exist_ok=True)

    ref = load(args.reference)
    mod = load(args.model)
    lo = np.minimum(ref.bounds[0], mod.bounds[0])
    hi = np.maximum(ref.bounds[1], mod.bounds[1])
    longest = float((ref.bounds[1] - ref.bounds[0]).max())
    tol = args.tolerance or max(0.5, 0.01 * longest)
    title = args.title or os.path.basename(os.path.dirname(os.path.abspath(args.out))) or "part"
    checks = []
    notes = []

    def add(name, value, limit_warn, limit_fail, text, higher_is_worse=True, unit="", extra=None):
        v = verdict(value, limit_warn, limit_fail, higher_is_worse)
        row = {"check": name, "value": round(float(value), 3), "unit": unit, "warn": limit_warn, "fail": limit_fail,
               "verdict": v, "why": text}
        if extra:
            row.update(extra)
        checks.append(row)
        return v

    # Size.
    dref, dmod = ref.bounds[1] - ref.bounds[0], mod.bounds[1] - mod.bounds[0]
    worst = float(np.abs(dmod - dref).max())
    add("size", worst, 3 * tol, 8 * tol,
        "bounding box, model − reference: %s mm (x, y, z); the reference is %s mm" % (
            np.round(dmod - dref, 1).tolist(), np.round(dref, 1).tolist()), unit="mm",
        extra={"modelMinusReferenceMM": np.round(dmod - dref, 2).tolist(), "referenceMM": np.round(dref, 2).tolist()})

    # Volume.
    if ref.is_watertight and mod.is_watertight and ref.volume > 0:
        ratio = mod.volume / ref.volume
        add("volume", abs(ratio - 1.0), 0.15, 0.4,
            "model volume is %.0f%% of the reference (%.0f vs %.0f cm³)" % (ratio * 100, mod.volume / 1e3, ref.volume / 1e3),
            extra={"ratio": round(ratio, 4)})
    else:
        notes.append("volume not compared: %s" % ("the reference mesh is open" if not ref.is_watertight else "the model mesh is open"))

    # Reference → model.
    n_r = distance_samples(ref.area)
    pts_r, d_rm, closest_r = surface_distances(ref, mod, n_r)
    s_rm = signed(d_rm, pts_r, mod, closest_r)
    within = float((d_rm <= tol).mean())
    add("ref_to_model_mean", float(d_rm.mean()), 1.5 * tol, 3 * tol,
        "reference surface to model: mean %.2f mm, 95%% within %.2f mm, max %.2f mm; %.0f%% within %.1f mm" % (
            d_rm.mean(), np.percentile(d_rm, 95), d_rm.max(), within * 100, tol), unit="mm",
        extra={"p95MM": round(float(np.percentile(d_rm, 95)), 3), "maxMM": round(float(d_rm.max()), 3),
               "withinTolerance": round(within, 4)})
    far_r = float((d_rm > 3 * tol).mean())
    add("ref_far_share", far_r, 0.08, 0.2,
        "%.1f%% of the reference surface is more than %.1f mm from any model surface (missing features)" % (
            far_r * 100, 3 * tol))

    # Model → reference, by area — except where the model faces a HOLE in
    # the scan. A pail scanned on a table has no floor; the model's floor
    # is then far from every scan surface, but what it is nearest to is the
    # scan's open edge (the wall's cut-off bottom). A sample whose nearest
    # scan point lies on an open edge is facing a hole: not excess, not
    # evidence either. A drum's lid is nearest the rim's SURFACE, and
    # counts.
    n_m = distance_samples(mod.area)
    pts_m, d_mr, _ = surface_distances(mod, ref, n_m)
    hole_facing = np.zeros(len(pts_m), dtype=bool)
    boundary = boundary_points(ref)
    if len(boundary):
        from scipy.spatial import cKDTree
        d_edge, _ = cKDTree(boundary).query(pts_m)
        hole_facing = d_edge <= d_mr * 1.15 + tol
    judged = ~hole_facing
    hole_share = float(hole_facing.mean())
    d_j = d_mr[judged] if judged.any() else d_mr
    far_m = float((d_j > 3 * tol).mean())     # sample_surface is area-weighted
    add("model_to_ref_mean", float(d_j.mean()), 1.5 * tol, 3 * tol,
        "model surface to reference: mean %.2f mm, 95%% within %.2f mm, max %.2f mm%s" % (
            d_j.mean(), np.percentile(d_j, 95), d_j.max(),
            " (%.0f%% of the model faces a hole in the scan and is not judged)" % (hole_share * 100) if hole_share > 0.005 else ""),
        unit="mm", extra={"p95MM": round(float(np.percentile(d_j, 95)), 3), "maxMM": round(float(d_j.max()), 3),
                          "holeFacingShare": round(hole_share, 4)})
    add("model_excess_area", far_m, 0.05, 0.15,
        "%.1f%% of the model's judged surface area is more than %.1f mm from the reference — material the reference does not have" % (
            far_m * 100, 3 * tol))
    if hole_share > 0.005:
        notes.append("%.0f%% of the model's surface faces holes in the scan (open edges) and is not judged" % (hole_share * 100))

    # The largest patch. The far samples of each direction, joined into
    # connected regions; the biggest region of each kind is a check, located
    # in words. The patch bounds are the reference's, so "upper third" means
    # the same thing for a missing lever and for an excess lid.
    far_mm = args.patch_far * tol
    missing = find_patches(pts_r, d_rm, d_rm > far_mm, ref.area / n_r, math.sqrt(ref.area / n_r), "missing",
                           ref.bounds[0], ref.bounds[1], args.up)
    excess = find_patches(pts_m, d_mr, judged & (d_mr > far_mm), mod.area / n_m, math.sqrt(mod.area / n_m), "excess",
                          ref.bounds[0], ref.bounds[1], args.up)
    warn_area, fail_area = patch_limits(ref.area)
    for kind, found, other in (("missing", missing, "model"), ("excess", excess, "reference")):
        if found:
            text = patch_sentence(kind, found[0], ref.area, other)
            if len(found) > 1:
                text += "; %d patches of this kind in all, %s mm² together" % (
                    len(found), grouped(sum(p["areaMM2"] for p in found)))
            area = found[0]["areaMM2"]
        else:
            text = "no %s patch: no connected region of surface is more than %.1f mm from the %s" % (kind, far_mm, other)
            area = 0.0
        add("largest_%s_patch" % kind, area, warn_area, fail_area, text, unit="mm²",
            extra={"patches": len(found), "totalMM2": round(sum(p["areaMM2"] for p in found), 1)})
    patch_report = {
        "thresholdMM": far_mm, "radiusMM": round(PATCH_RADIUS * math.sqrt(ref.area / n_r), 2),
        "missing": missing[:PATCH_KEEP], "excess": excess[:PATCH_KEEP],
        "missingTotalMM2": round(sum(p["areaMM2"] for p in missing), 1),
        "missingShare": round(sum(p["areaMM2"] for p in missing) / ref.area, 4),
        "excessTotalMM2": round(sum(p["areaMM2"] for p in excess), 1),
        "excessShare": round(sum(p["areaMM2"] for p in excess) / max(mod.area * (1 - hole_share), 1e-9), 4),
    }

    # Terraces: mean signed error (ref → model) per band along the up axis.
    up_i = {"x": 0, "y": 1, "z": 2}[args.up]
    hts = pts_r[:, up_i]
    edges = np.linspace(hts.min(), hts.max(), 41)
    band_mean = []
    for i in range(40):
        sel = (hts >= edges[i]) & (hts < edges[i + 1])
        band_mean.append(float(s_rm[sel].mean()) if sel.sum() >= 30 else 0.0)
    band_mean = np.array(band_mean)
    strong = np.where(np.abs(band_mean) > tol, np.sign(band_mean), 0)
    nz = strong[strong != 0]
    flips = int((np.diff(nz) != 0).sum()) if len(nz) > 1 else 0
    add("terraces", flips, 2, 4,
        "the signed error along the %s axis changes sign %d times between bands more than %.1f mm out (ridges or steps where the reference is smooth)" % (
            args.up, flips, tol), extra={"bandMeanMM": np.round(band_mean, 2).tolist()})

    # Views: silhouettes and depth.
    colour = tuple(int(c * 255) for c in args.model_color)
    tiles = {}
    grids = {}
    for view in VIEWS:
        F = frame(view, args.up)
        g = Grid(lo, hi, F, Grid.fit_pixels(lo, hi, F, PX, max(ref.area, mod.area)))
        grids[view] = g
        zr = g.splat(ref)
        zm = g.splat(mod)
        rm, mm = np.isfinite(zr), np.isfinite(zm)
        # Model-only pixels far DEEPER than the reference around them are
        # seen through a hole in the scan (a floor under a missing floor):
        # left out of the silhouette and the excess. A lid at the rim's own
        # depth is not.
        through_hole = np.zeros_like(mm)
        if (mm & ~rm).any() and rm.any():
            from scipy.ndimage import distance_transform_edt
            _, (iy, ix) = distance_transform_edt(~rm, return_indices=True)
            near_ref = zr[iy, ix]
            through_hole = mm & ~rm & ((near_ref - zm) > 10 * tol)
            mm = mm & ~through_hole
        inter, union = (rm & mm).sum(), (rm | mm).sum()
        iou = inter / union if union else 0.0
        # Worst of 20 horizontal strips.
        strips = []
        for i in range(20):
            a, b = i * g.h // 20, (i + 1) * g.h // 20
            u = (rm[a:b] | mm[a:b]).sum()
            if u < 0.002 * union:
                continue
            strips.append(((rm[a:b] & mm[a:b]).sum() / u, i))
        worst_iou, worst_i = min(strips) if strips else (iou, -1)
        add("silhouette_%s" % view, iou, 0.93, 0.85,
            "%s silhouette overlap %.1f%%; worst horizontal strip (%d of 20 from the top) %.1f%%" % (
                view, iou * 100, worst_i + 1, worst_iou * 100), higher_is_worse=False,
            extra={"worstStripIoU": round(float(worst_iou), 4), "worstStrip": worst_i + 1})
        both = rm & mm
        if both.any():
            dfull = np.where(both, zr - zm, 0.0)
            d = dfull[both]
            miss = float((d > 3 * tol).mean())
            exc = float((d < -3 * tol).mean())
            # The worst of 20 horizontal strips, so a wrong top (a terraced
            # dome, a cone where a cap should be) is not averaged away by a
            # long body that fits: a strip holding at least 2 % of the
            # silhouette with over half its pixels out of tolerance fails.
            out = both & (np.abs(dfull) > 3 * tol)
            worst_share, worst_strip = 0.0, -1
            for i in range(20):
                a, b = i * g.h // 20, (i + 1) * g.h // 20
                n_both = both[a:b].sum()
                if n_both < 0.02 * both.sum():
                    continue
                share = out[a:b].sum() / n_both
                if share > worst_share:
                    worst_share, worst_strip = float(share), i
            score = max(miss + exc, worst_share * 0.3)       # a 50 % strip scores 0.15 = FAIL
            add("depth_%s" % view, score, 0.06, 0.15,
                "seen from the %s, %.1f%% of the shared silhouette is deeper in the model than the reference by > %.1f mm (missing) and %.1f%% nearer (excess); max %.1f mm; worst strip (%d of 20 from the top) %.0f%% out" % (
                    view, miss * 100, 3 * tol, exc * 100, float(np.abs(d).max()), worst_strip + 1, worst_share * 100),
                extra={"missingShare": round(miss, 4), "excessShare": round(exc, 4), "maxMM": round(float(np.abs(d).max()), 2),
                       "worstStripShare": round(worst_share, 4), "worstStrip": worst_strip + 1})
        tiles[view] = {
            "reference": shade(zr, (178, 184, 196), g.mm_per_px),
            "model": shade(zm, colour, g.mm_per_px),
            "silhouettes": silhouette_overlay(rm, mm, through_hole),
            "depth": depth_diff_image(zr, np.where(through_hole, np.nan, zm), tol, through_hole),
        }
        for k, im in tiles[view].items():
            im.save(os.path.join(args.out, "views", "%s-%s.png" % (view, k)))
        del zr, zm, rm, mm, both, dfull
        import gc
        gc.collect()

    # The sheet.
    overall = "PASS"
    for c in checks:
        if c["verdict"] == "FAIL":
            overall = "FAIL"
        elif c["verdict"] == "WARN" and overall == "PASS":
            overall = "WARN"
    tile = 640
    cols = ("reference", "model", "silhouettes", "depth")
    header, left, rowgap = 150, 150, 10
    marks = [("M%d" % (i + 1), (70, 130, 255), p) for i, p in enumerate(missing[:PATCH_MARK])] + \
            [("E%d" % (i + 1), (255, 140, 40), p) for i, p in enumerate(excess[:PATCH_MARK])]
    W = left + len(cols) * (tile + rowgap)
    H = header + len(VIEWS) * (tile + rowgap) + 120 + 30 * len(marks)
    sheet = Image.new("RGB", (W, H), (18, 19, 22))
    draw = ImageDraw.Draw(sheet)
    big, small, tiny = font(44), font(26), font(22)
    colour_v = {"PASS": (90, 200, 120), "WARN": (240, 190, 60), "FAIL": (255, 90, 80)}

    def ring(view, patch):
        """Centre and radius of a patch in the view's full-size tile pixels:
        the centre through the tile's own frame, the radius half the
        projected extent of the patch's box, never smaller than a dot."""
        g = grids[view]
        c = np.asarray(patch["centreMM"])
        e = 0.5 * np.asarray(patch["extentMM"])
        corners = np.array([c + e * np.array([sx, sy, sz]) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
        s = corners @ g.F.T
        sc = c @ g.F.T
        px = (sc[0] - g.lo[0]) * g.scale
        py = (g.hi[1] - sc[1]) * g.scale
        r = 0.5 * (s.max(axis=0) - s.min(axis=0))[:2].max() * g.scale
        return px, py, max(r, 12.0)

    def draw_marks(canvas, view, x0, y0, k, scale_r=1.0):
        """Rings and labels for the marked patches on a tile pasted at
        (x0, y0) with thumbnail factor k (full-size pixels × k)."""
        d = ImageDraw.Draw(canvas)
        label_font = font(int(26 * max(scale_r, 0.85)))
        for label, col, patch in marks:
            px, py, r = ring(view, patch)
            px, py, r = x0 + px * k, y0 + py * k, min(max(r * k, 10.0), 0.45 * tile * scale_r)
            d.ellipse([px - r, py - r, px + r, py + r], outline=col, width=max(2, int(3 * scale_r)))
            d.text((px + r + 4, py - 14 * scale_r), label, fill=col, font=label_font)
    draw.text((left, 24), "%s — %s" % (title, overall), fill=colour_v[overall], font=big)
    draw.text((left, 84), "tolerance %.1f mm · blue = the model lacks material · orange = it has too much · slate = seen through a hole in the scan · reference %s mm" % (
        tol, " × ".join("%.0f" % v for v in dref)), fill=(170, 174, 182), font=small)
    for j, c in enumerate(cols):
        draw.text((left + j * (tile + rowgap) + 8, header - 36), c, fill=(200, 204, 210), font=small)
    for i, view in enumerate(VIEWS):
        y0 = header + i * (tile + rowgap)
        draw.text((16, y0 + 8), view, fill=(200, 204, 210), font=small)
        for j, c in enumerate(cols):
            im = tiles[view][c]
            im = im.copy()
            im.thumbnail((tile, tile))
            x0 = left + j * (tile + rowgap)
            px0, py0 = x0 + (tile - im.width) // 2, y0 + (tile - im.height) // 2
            sheet.paste(im, (px0, py0))
            if c in ("reference", "depth"):
                draw_marks(sheet, view, px0, py0, im.width / grids[view].w)
        # The view's own numbers under its label.
        rows = [c for c in checks if c["check"] in ("silhouette_%s" % view, "depth_%s" % view)]
        yy = y0 + 48
        for c in rows:
            draw.text((16, yy), "%s %s" % (c["check"].split("_")[0], c["verdict"]), fill=colour_v[c["verdict"]], font=tiny)
            yy += 28
            draw.text((16, yy), "%.3f" % c["value"] if c["value"] < 10 else "%.0f" % c["value"], fill=(170, 174, 182), font=tiny)
            yy += 36
    # Global checks along the bottom.
    yy = header + len(VIEWS) * (tile + rowgap) + 10
    x = left
    for c in checks:
        if c["check"].startswith(("silhouette_", "depth_")):
            continue
        s = "%s %s" % (c["check"], c["verdict"])
        draw.text((x, yy), s, fill=colour_v[c["verdict"]], font=tiny)
        x += draw.textlength(s, font=tiny) + 36
        if x > W - 400:
            x = left
            yy += 30
    # One legend line per ringed patch.
    yy += 44
    legend = []
    for label, col, patch in marks:
        sides = sorted(patch["extentMM"], reverse=True)
        line = "%s  %s %s mm² — %s · %.1f mm from the %s on average · %.0f × %.0f mm" % (
            label, patch["kind"], grouped(patch["areaMM2"]), patch["location"], patch["meanMM"],
            "model" if patch["kind"] == "missing" else "reference", sides[0], sides[1])
        legend.append((line, col))
        draw.text((left, yy), line, fill=col, font=tiny)
        yy += 30
    sheet.save(os.path.join(args.out, "review.png"))

    # Just the marks on the shaded reference, the four views in a row.
    refs = [tiles[v]["reference"] for v in VIEWS]
    ph = max(im.height for im in refs)
    gap = 20
    pw = sum(im.width for im in refs) + gap * (len(refs) + 1)
    patches_img = Image.new("RGB", (pw, ph + 80 + 34 * (len(legend) + 1)), (18, 19, 22))
    pd = ImageDraw.Draw(patches_img)
    pd.text((gap, 14), "%s — the largest patches: blue rings = the model lacks material, orange = it has too much" % title,
            fill=(200, 204, 210), font=small)
    x = gap
    for v, im in zip(VIEWS, refs):
        patches_img.paste(im, (x, 60))
        draw_marks(patches_img, v, x, 60, 1.0, scale_r=1.4)
        pd.text((x + 8, 60 + 8), v, fill=(200, 204, 210), font=small)
        x += im.width + gap
    yy = 60 + ph + 20
    for line, col in legend:
        pd.text((gap, yy), line, fill=col, font=small)
        yy += 34
    patches_img.save(os.path.join(args.out, "views", "patches.png"))

    result = {"title": title, "overall": overall, "toleranceMM": tol, "upAxis": args.up,
              "reference": args.reference, "model": args.model, "notes": notes, "checks": checks,
              "patches": patch_report}
    with open(os.path.join(args.out, "checks.json"), "w") as f:
        json.dump(result, f, indent=1)
    print("%s: %s (tolerance %.1f mm)" % (title, overall, tol))
    for c in checks:
        if c["verdict"] != "PASS":
            print("  %-22s %s  %s" % (c["check"], c["verdict"], c["why"]))
    for n in notes:
        print("  note:", n)
    print("  sheet:", os.path.join(args.out, "review.png"))


if __name__ == "__main__":
    main()
