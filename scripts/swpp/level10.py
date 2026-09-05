"""Level 10 — CSWA Exam Level (19 problems). Frame per kit: FRONT = world XY,
TOP = XZ (sketch v = -z), RIGHT = YZ; the sheet's red origin is world 0."""
import math
from kit import (Sketch, front, back, top, bottom, right, left, plane_at, extrude, revolve,
                 fillet, chamfer, edges_where, union, subtract, mirror, move)

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss", "Extrude Cut")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


# --------------------------------------------------------------- 10.8 ----

def _rail_block(length=165.0, width=132.0, pocket_len=60.0, pocket_z0=38.0):
    """10.8A body. z runs 0 (near end, the plan's bottom edge) to -length.
    Cross-section (front view): base ±width/2 × y -22..8, shoulders ±44 to
    y = 13, dovetail head 47 wide with 1.5 × 45° top chamfers (the (44) top
    flat), 45° flanks (the 90° between them) down to a short vertical wall
    at ±18.75, R1.5 on the eight longitudinal corners the callout counts.
    Then: 22-wide U-slot from the near end to an R11 end about z = -127,
    22 deep (floor at the origin height); two side pockets 26 × 60 with R8
    inner corners; a 13-deep underside recess leaving 16-wide feet at
    z 0..-16 and -117.5..-133.5 (the far 32 is recessed too, per A-A);
    Detail D keyway (5 flat, 45° sides 5 wide) across the recess ceiling
    beside the second foot; Ø10 through the slot floor at z = -24 with a
    2 × 45° mouth; 2× Ø7 / Ø12 × 8 counterbores with 2 × 45° at z = -155;
    Ø8 + 2× Ø3 bores at y = 13 from the far end into the slot."""
    hw = width / 2
    prof = [(-hw, -22), (hw, -22), (hw, 8), (44, 8), (44, 13), (18.75, 13), (18.75, 15.75),
            (23.5, 20.5), (22, 22), (-22, 22), (-23.5, 20.5), (-18.75, 15.75), (-18.75, 13),
            (-44, 13), (-44, 8), (-hw, 8)]
    radii = [0, 0, 0, 1.5, 1.5, 1.5, 0, 1.5, 0, 0, 1.5, 0, 1.5, 1.5, 1.5, 0]
    body = extrude(Sketch(front(-length)).rounded_poly(prof, radii), (0, -10), length)
    # U-slot, open at the near end, R11 end about z = -127
    zc = 127.0
    slot = (Sketch(top(22)).line((-11, -1), (11, -1)).line((11, -1), (11, zc))
            .arc((0, zc), 11, 0, 180).line((-11, zc), (-11, -1)))
    extrude(slot, (0, 60), -22, cut=[body])
    # side pockets 26 deep, R8 inner corners (centres 8 in from both walls)
    z0, z1 = pocket_z0, pocket_z0 + pocket_len
    xi = hw - 26
    pk = Sketch(top(8))
    for s in (-1, 1):
        xo, xw, xc = s * (hw + 1), s * xi, s * (xi + 8)
        pk.line((xo, z0), (xc, z0))
        if s < 0:
            pk.arc((xc, z0 + 8), 8, 270, 360).line((xw, z0 + 8), (xw, z1 - 8)).arc((xc, z1 - 8), 8, 0, 90)
        else:
            pk.arc((xc, z0 + 8), 8, 180, 270).line((xw, z0 + 8), (xw, z1 - 8)).arc((xc, z1 - 8), 8, 90, 180)
        pk.line((xc, z1), (xo, z1)).line((xo, z1), (xo, z0))
    for s in (-1, 1):
        extrude(pk, (s * (xi + 13), (z0 + z1) / 2), -31, cut=[body])
    # underside recess 13 deep between the feet, and beyond the second foot
    f2a, f2b = 117.5, 133.5
    rc = Sketch(top(-22)).rect(-hw - 1, 16, hw + 1, f2a).rect(-hw - 1, f2b, hw + 1, length + 1)
    extrude(rc, (0, 60), 13, cut=[body])
    extrude(rc, (0, (f2b + length) / 2), 13, cut=[body])
    # Detail D keyway across the recess ceiling: flat 5 at 3.54 deep, 45° sides
    d = 5 / math.sqrt(2)
    kc = 111.0
    kw = (Sketch(right(-hw - 1)).poly([(kc - 2.5 - d, -9), (kc - 2.5, -9 + d), (kc + 2.5, -9 + d),
                                        (kc + 2.5 + d, -9), (kc + 2.5 + d, -10), (kc - 2.5 - d, -10)]))
    extrude(kw, (kc, -8), width + 2, cut=[body])
    # Ø10 through the slot floor at z = -24, 2 × 45° at the mouth
    extrude(Sketch(top(0)).circle((0, 24), 5), (0, 24), -10, cut=[body])
    ch = Sketch(plane_at((0, 0, -24), (1, 0, 0), (0, 1, 0))).poly([(4, 1), (8, 1), (4, -3)])
    revolve(ch, (5, -0.5), (0, 0), (0, 1), cut=[body])
    # counterbored holes at x = ±55 (centred on the margins), z = -(length - 10)
    zh = length - 10
    for s in (-1, 1):
        x = s * (hw - 11)
        extrude(Sketch(top(8)).circle((x, zh), 3.5), (x, zh), -18, cut=[body])
        extrude(Sketch(top(8)).circle((x, zh), 6), (x, zh), -8, cut=[body])
        ch = Sketch(plane_at((x, 0, -zh), (1, 0, 0), (0, 1, 0))).poly([(5, 9), (9, 9), (5, 5)])
        revolve(ch, (7, 8.5), (0, 0), (0, 1), cut=[body])
    # Ø8 + 2× Ø3 bores from the far end face into the slot, at y = 13
    extrude(Sketch(front(-length - 1)).circle((0, 13), 4), (0, 13), length - zc - 9 + 2, cut=[body])
    for s in (-1, 1):
        extrude(Sketch(front(-length - 1)).circle((s * 7, 13), 1.5), (s * 7, 13), length - zc - 7 + 2, cut=[body])
    return body


@problem("10.8A", 431376, features=("Extrude Boss", "Extrude Cut", "Fillet (sketch)", "Chamfer (as revolve cut)"))
def p10_8A():
    return _rail_block()


# -------------------------------------------------------------- 10.10 ----
# F3 worker. Plate 144 x 88 x 13 (4x R12 plan corners), origin at the plate
# top / right end / front edge: world x runs 0..144 left->right, z 0..88 is
# the plan depth (front edge z = 0), y is height with the plate top at 0.
# Pixel-read from the three views (1.514 px/mm): the right view is a C —
# the 13 plate plus two 22-wide side rails hanging 13 below it (the '13' is
# the rail depth under the plate, 26 = plate + rail in the front view, 44 is
# the clear web), 2x R3 in the rail/web corners; the 4x O18 bosses stand
# on the long edges (centres ON the edge lines), 5 above the plate top and,
# in both views and in 10.10B's Section B-B, ~2.5 below the rail bottom
# (undimensioned; 2.4-2.6 measured); the O8 holes run from the boss top to
# the rail-bottom level (10.10B's section shows the unhatched bore ending on
# that plane, the cap below hatched) - the callout's 5.00 is the boss height
# above the plate. Notch 30 x 8.67 with R3 corners in both rails 45 from
# the right end; 2x O5 through each rail at 21 / 31 from the left end, 5
# above the rail bottom (Detail A); R5 on the plate's top perimeter (the
# tangent line 5 below the top runs the whole front view).

def _p10_10A(boss_below=2.5):
    body = extrude(Sketch(bottom(0)).rounded_poly([(0, 0), (144, 0), (144, 88), (0, 88)], 12), (72, 44), 13)
    top_loop = edges_where(body, lambda e: abs(e["midpoint"][1]) < 0.3)
    assert len(top_loop) == 8, top_loop
    fillet(body, 5.0, top_loop)
    rail_f = extrude(Sketch(bottom(-13)).rounded_poly([(0, 0), (144, 0), (144, 22), (0, 22)], [12, 12, 0, 0]), (72, 11), 13, union=[body])
    extrude(Sketch(bottom(-13)).rounded_poly([(0, 66), (144, 66), (144, 88), (0, 88)], [0, 0, 12, 12]), (72, 77), 13, union=[body])
    inner = edges_where(body, lambda e: abs(e["midpoint"][1] + 13) < 0.3 and e["lengthMM"] > 100
                        and (abs(e["midpoint"][2] - 22) < 0.3 or abs(e["midpoint"][2] - 66) < 0.3))
    assert len(inner) == 2, inner
    fillet(body, 3.0, inner)
    # notch through both rails, 45..75 from the right end, 8.67 tall, R3 at its ceiling corners
    x0, x1, yt = 144 - 75, 144 - 45, -26 + 8.67
    extrude(Sketch(front(-1)).rounded_poly([(x0, -27), (x1, -27), (x1, yt), (x0, yt)], [0, 0, 3, 3]), ((x0 + x1) / 2, -22), 90, cut=[body])
    # O5 through the rails, 21 and 31 from the left end, 5 above the rail bottom
    for x in (21, 31):
        extrude(Sketch(front(-1)).circle((x, -21), 2.5), (x, -21), 90, cut=[body])
    # bosses: O18 on the long edges, 5 above the plate top down to boss_below under the rails
    h = 5 + 26 + boss_below
    for c in [(48, 0), (120, 0), (48, 88), (120, 88)]:
        extrude(Sketch(bottom(5)).circle(c, 9), c, h, union=[body])
    for c in [(48, 0), (120, 0), (48, 88), (120, 88)]:
        extrude(Sketch(bottom(5)).circle(c, 4), c, 31, cut=[body])
    return body


@problem("10.10A", 244027, features=("Extrude Boss", "Extrude Cut", "Fillet"))
def p10_10A():
    return _p10_10A()
