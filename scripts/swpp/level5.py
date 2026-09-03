"""Level 5 — Reference Geometry (20 problems). Planes at an angle are built
as an explicit basis over the bridge (the UI has no angled-plane tool yet)."""
import math
from kit import Sketch, front, top, right, left, plane_at, extrude, fillet, edges_where, union, bodies

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("5.1", 28862, features=("Extrude Boss", "Plane at an angle", "Sketch: Arcs"))
def p5_1():
    # Bent plate, 4 thick. Flat region: 108 × 64 outline with an 18 × 18
    # corner chamfer at the origin, R12 at (108, 0) and (0, 64), 2 × Ø10 at
    # the round centres, cut off by the bend line from (54, 64) at 35° below
    # horizontal to (108, 26.19). Beyond it the sheet bends up through 68°
    # (112° included) around an outer R12 / inner R8 and runs 14 further.
    # Flat 5510.5 × 4 + bend 47.47 × 65.94 + flange 56 × 65.94 = 28 865.
    yb = 64 - 54 * math.tan(math.radians(35))
    pts = [(0, 18), (18, 0), (108, 0), (108, yb), (54, 64), (0, 64)]
    flat = Sketch(top(0)).rounded_poly(pts, [0, 0, 12, 0, 0, 12]).circle((12, 52), 5).circle((96, 12), 5)
    base = extrude(flat, (40, 30), 4)
    # Section plane perpendicular to the bend line, through its midpoint;
    # u across the bend line (towards the flange), v up.
    d = ((108 - 54), (yb - 64))
    L = math.hypot(*d)
    d = (d[0] / L, d[1] / L)
    n = (-d[1], d[0])                       # plan-space normal towards (108, 64)
    if (108 - 54) * n[0] + (64 - 64) * n[1] < 0:
        n = (-n[0], -n[1])
    mid = ((54 + 108) / 2, (64 + yb) / 2)
    origin = (mid[0], 0, -mid[1])           # plan (X, Y) → world (X, 0, -Y)
    xa = (n[0], 0, -n[1])
    plane = plane_at(origin, xa, (0, 1, 0))
    a = math.radians(-90 + 68)              # arc end angle about the bend centre (0, 12)
    ox, oy = 12 * math.cos(a), 12 + 12 * math.sin(a)
    ix, iy = 8 * math.cos(a), 12 + 8 * math.sin(a)
    tx, ty = -math.sin(a), math.cos(a)      # flange direction (tangent)
    sk = (Sketch(plane).line((0, 0), (0, 4))
          .arc((0, 12), 8, -90, -22).arc((0, 12), 12, -90, -22)
          .line((ox, oy), (ox + 14 * tx, oy + 14 * ty))
          .line((ox + 14 * tx, oy + 14 * ty), (ix + 14 * tx, iy + 14 * ty))
          .line((ix + 14 * tx, iy + 14 * ty), (ix, iy)))
    extrude(sk, (6, 2), L / 2, symmetric=True, union=[base])
    return base


@problem("5.2", 48824, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_2():
    # Plate 132 × 64 × 5, R6 corners, 4 × Ø6 at the corner centres; boss
    # Ø32 to 18 total with a Ø24 bore through everything; four ribs 9 wide
    # at ±30° from the long axis, tops sloping at 18° (162°) from r = 45 on
    # the plate up into the boss wall (started inside it, per the hint).
    plate = Sketch(top(0)).rounded_poly([(-66, -32), (66, -32), (66, 32), (-66, 32)], 6)
    for sx in (-1, 1):
        for sy in (-1, 1):
            plate.circle((sx * 60, sy * 26), 3)
    body = extrude(plate, (0, 0), 5)
    extrude(Sketch(top(5)).circle((0, 0), 16), (0, 0), 13, union=[body])
    for ang in (30, 150, 210, 330):
        r = math.radians(ang)
        plane = plane_at((0, 0, 0), (math.cos(r), 0, -math.sin(r)), (0, 1, 0))
        top_y = 5 + (45 - 15) * math.tan(math.radians(18))
        rib = Sketch(plane).line((15, 5), (45, 5)).line((45, 5), (15, top_y)).line((15, top_y), (15, 5))
        extrude(rib, (20, 6), 4.5, symmetric=True, union=[body])
    extrude(Sketch(top(18)).circle((0, 0), 12), (0, 0), -18, cut=[body])
    return body


@problem("5.9", 152544, features=("Extrude Boss", "Extrude Cut", "Fillet", "Plane at an angle"))
def p5_9():
    # T block: slab 65 × 105 × 16 over a centred rail 31 wide × 16, origin on
    # the top face. A Ø30 boss whose axis lies IN the top face at 35° to the
    # 65 edge (so half of it stands proud), trimmed to the slab's x edges,
    # R5 fillets where it meets the face, a Ø21 bore along the axis, and
    # 2 × Ø14 at (0, ±37.5) through everything. 161 280 + 28 036 − 27 468
    # + 560 − 9 852 = 152 556.
    s, c = math.sin(math.radians(35)), math.cos(math.radians(35))
    body = extrude(Sketch(top(-16)).rect(-32.5, -52.5, 32.5, 52.5), (0, 0), 16)
    extrude(Sketch(top(-32)).rect(-15.5, -52.5, 15.5, 52.5), (0, 0), 16, union=[body])
    perp = plane_at((0, 0, 0), (s, 0, -c), (0, 1, 0))       # normal along the boss axis
    extrude(Sketch(perp).circle((0, 0), 15), (0, 0), 50, symmetric=True, union=[body])
    extrude(Sketch(right(32.5)).rect(-60, -40, 60, 40), (0, 0), 30, cut=[body])
    extrude(Sketch(left(-32.5)).rect(-60, -40, 60, 40), (0, 0), 30, cut=[body])
    # The two straight boss-base edges: on the top face, 65/cos35 = 79.2 long
    # (the bridge flags them convex, so pick by length band, not by concavity).
    base_edges = edges_where(body, lambda e: abs(e["midpoint"][1]) < 1e-3 and 70 < e["lengthMM"] < 90)
    assert len(base_edges) == 2, f"expected the two boss-base edges, found {len(base_edges)}"
    fillet(body, 5, base_edges)
    extrude(Sketch(perp).circle((0, 0), 10.5), (0, 0), 60, symmetric=True, cut=[body])
    for v in (37.5, -37.5):
        extrude(Sketch(top(0)).circle((0, v), 7), (0, v), -32, cut=[body])
    return body


@problem("5.13", 358642, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_13():
    # Tube Ø75 / Ø60 × 200 about the origin; a tab 10 thick on a plane
    # through the tube's axis leaned 8° off vertical, from inside the wall
    # out to 75 from the axis, 120 long with R10 outer corners, and four
    # Ø12 holes 10 in from the outer edge at 10, 40, 70 and 100 from the
    # top (the part is asymmetric). 318 086 + ~40 400 = 358.5k.
    body = extrude(Sketch(top(-100)).circle((0, 0), 37.5).circle((0, 0), 30), (33, 0), 200)
    a = math.radians(8)
    plane = plane_at((0, 0, 0), (1, 0, 0), (0, math.cos(a), math.sin(a)))
    tab = Sketch(plane).rounded_poly([(31, -60), (75, -60), (75, 60), (31, 60)], [0, 10, 10, 0])
    for v in (50, 20, -10, -40):
        tab.circle((65, v), 6)
    extrude(tab, (50, 0), 5, symmetric=True, union=[body])
    return body


@problem("5.14", 3257, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_14():
    # Ø19 cylinder 14 tall with a flat 8 from its axis; Ø6 bosses 2.5 tall
    # coaxial on both ends (19 overall); a Ø6 cross bore from the flat to
    # the round side with a Ø10 counterbore 4 deep at the flat.
    h = math.sqrt(9.5 ** 2 - 64)
    a1 = math.degrees(math.atan2(h, 8))
    d = Sketch(top(0)).line((8, -h), (8, h)).arc((0, 0), 9.5, a1, 360 - a1)
    body = extrude(d, (0, 0), 14)
    extrude(Sketch(top(14)).circle((0, 0), 3), (0, 0), 2.5, union=[body])
    extrude(Sketch(top(0)).circle((0, 0), 3), (0, 0), -2.5, union=[body])
    extrude(Sketch(right(8)).circle((0, 7), 3), (0, 7), -18, cut=[body])
    extrude(Sketch(right(8)).circle((0, 7), 5), (0, 7), -4, cut=[body])
    return body


@problem("5.16", 157918, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_16():
    # Rectangular tube 100 × 60, R10 corners, 5 wall (inner R5), stood on
    # the origin and cut by a plane through the axis 110 up, tilted 32°
    # about the 100 direction. Wall 1435.7 mm² × mean height 110 = 157 929.
    tube = (Sketch(top(0)).rounded_poly([(-50, -30), (50, -30), (50, 30), (-50, 30)], 10)
            .rounded_poly([(-45, -25), (45, -25), (45, 25), (-45, 25)], 5))
    body = extrude(tube, (47.5, 0), 200)
    t = math.radians(32)
    cutter = plane_at((0, 110, 0), (1, 0, 0), (0, math.sin(t), math.cos(t)))
    extrude(Sketch(cutter).rect(-80, -80, 80, 80), (0, 0), -150, cut=[body])
    return body
