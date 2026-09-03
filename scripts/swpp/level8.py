"""Level 8 — Sweep Boss/Cut (14 problems)."""
import math
from kit import Sketch, front, top, right, extrude, sweep, arc_points, revolve

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Sweep",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("8.6", 24448)
def p8_6():
    # Ø10 tube swept round a closed pear: centreline arcs R15 (top, about
    # the origin) and R32 (bottom, 80 below) joined by their outer tangents.
    r1, r2, d = 15.0, 32.0, 80.0
    alpha = math.asin((r2 - r1) / d)
    # tangent normals (right side): angle from +x of the normal = -alpha
    def pt(cx, cy, r, ang):
        return (cx + r * math.cos(ang), cy + r * math.sin(ang), 0.0)
    nr = -alpha                       # right tangent normal angle
    nl = math.pi + alpha              # left tangent normal angle
    top_c, bot_c = (0.0, 0.0), (0.0, -d)
    spine = []
    # small arc over the top: from the right tangent point round to the left one (CCW)
    spine += arc_points((0, 0, 0), r1, math.degrees(nr), math.degrees(nl), n=32)
    # down the left tangent to the big circle
    spine.append(pt(bot_c[0], bot_c[1], r2, nl))
    # big arc round the bottom from the left tangent point to the right one (CCW)
    spine += arc_points((0, -d, 0), r2, math.degrees(nl), math.degrees(nr) + 360, n=48)[1:]
    # back up the right tangent to the start
    spine.append(spine[0])
    # profile: a circle on a plane perpendicular to the spine at its start
    # (the start heads along +y at the right tangent point? no — the arc
    # starts moving CCW, i.e. tangent direction is +90° from the normal)
    tdir = (math.cos(nr + math.pi / 2), math.sin(nr + math.pi / 2), 0)
    s0 = spine[0]
    from kit import plane_at
    # plane spanned by z and the in-plane normal to tdir
    nvec = (-tdir[1], tdir[0], 0)
    prof = Sketch(plane_at(s0, (0, 0, 1), nvec)).circle((0, 0), 5)
    return sweep(prof, (0, 0), spine)


@problem("8.1", 1306, features=("Sweep", "Sketch: Polygon"))
def p8_1():
    # Hex key: 4 across-flats hexagon swept up 75 and across 25 (outside
    # dimensions), the bend's OUTER radius 6 → centreline R4. Path from the
    # origin: up to (0, 69), quarter arc to (4, 73), across to (23, 73).
    prof = Sketch(top(0)).polygon_flats((0, 0), 4, 6)
    spine = [(0, 0, 0), (0, 69, 0)] + arc_points((4, 69, 0), 4, 180, 90, n=24)[1:] + [(23, 73, 0)]
    return sweep(prof, (0, 0), spine)


def _fillet_path(points, R, n=8):
    """Polyline through `points` with every interior corner replaced by an
    R arc sampled into n chords (a sweep spine takes lines only)."""
    import math
    out = [points[0]]
    for i in range(1, len(points) - 1):
        p0, p, p1 = points[i - 1], points[i], points[i + 1]
        d1 = (p[0] - p0[0], p[1] - p0[1]); l1 = math.hypot(*d1); d1 = (d1[0] / l1, d1[1] / l1)
        d2 = (p1[0] - p[0], p1[1] - p[1]); l2 = math.hypot(*d2); d2 = (d2[0] / l2, d2[1] / l2)
        cosang = max(-1.0, min(1.0, d1[0] * d2[0] + d1[1] * d2[1]))
        theta = math.acos(cosang)                       # turning angle
        t = R * math.tan(theta / 2)
        a = (p[0] - t * d1[0], p[1] - t * d1[1])        # tangent point in
        b = (p[0] + t * d2[0], p[1] + t * d2[1])        # tangent point out
        cross = d1[0] * d2[1] - d1[1] * d2[0]
        nrm = (-d1[1], d1[0]) if cross > 0 else (d1[1], -d1[0])   # towards the centre
        c = (a[0] + R * nrm[0], a[1] + R * nrm[1])
        a0 = math.atan2(a[1] - c[1], a[0] - c[0])
        a1 = math.atan2(b[1] - c[1], b[0] - c[0])
        sweep = a1 - a0
        if cross > 0 and sweep < 0:
            sweep += 2 * math.pi
        if cross < 0 and sweep > 0:
            sweep -= 2 * math.pi
        for k in range(n + 1):
            ang = a0 + sweep * k / n
            out.append((c[0] + R * math.cos(ang), c[1] + R * math.sin(ang)))
    out.append(points[-1])
    return out


@problem("8.10", 46575, features=("Sweep",))
def p8_10():
    # 25 × 6 strip swept along a bent path (all bends R12): left leg 48 up,
    # 70 along the bottom, a 55° rise to a shelf at 38 reaching the right
    # leg at 145, the leg up to a corner and an arm 62 long rising 25° to
    # the left so the tip sits at 115 overall. Path 325.6 − 13.9 (bends)
    # = 311.7 → 46 755.
    import math
    rise = 38 / math.tan(math.radians(55))
    tip_up = 62 * math.sin(math.radians(25))
    pts = [(0, 48), (0, 0), (70, 0), (70 + rise, 38), (145, 38), (145, 115 - tip_up),
           (145 - 62 * math.cos(math.radians(25)), 115)]
    path = _fillet_path(pts, 12)
    spine = [(x, y, 0) for (x, y) in path]
    prof = Sketch(top(48)).rect(-3, -12.5, 3, 12.5)
    return sweep(prof, (0, 0), spine)
