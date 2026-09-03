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
