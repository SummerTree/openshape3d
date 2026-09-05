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


@problem("5.3", 40316, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot", "Plane at an angle"))
def p5_3():
    # Plate 88 × 62 × 7 (origin at its centre, on the bottom face), 4 × 6 × 45°
    # corner chamfers, two 6-wide slots 41 between centres at x = ±33 (8 from
    # the edge to the slot side; the right one mirrors it, section A-A running
    # through both slot centres and the origin). On A-A a 14-wide gusset+tab:
    # tab 4 thick leaning 36° to the plate toward +s, hole Ø8 8 above the
    # root line, R7 tip concentric; gusset = the tab's left face extended to
    # the plate (foot 20 along A-A from the left slot centre) plus a face
    # perpendicular to the plate, 20 tall, under the tab's right face.
    # Plate 33 848 + gusset 5 917 + tab 556 = 40 321.
    from kit import subtract
    plate = (Sketch(top(0)).poly([(-38, -31), (38, -31), (44, -25), (44, 25), (38, 31), (-38, 31), (-44, 25), (-44, -25)])
             .slot((-33, -20.5), (-33, 20.5), 3).slot((33, -20.5), (33, 20.5), 3))
    body = extrude(plate, (0, 0), 7)
    sx, sz = 33 / math.hypot(33, 20.5), -20.5 / math.hypot(33, 20.5)      # A-A direction in world (plan up = -z)
    s_hat = (sx, 0, sz)
    m_hat = (-sz, 0, sx)                                                    # section normal (s × y)
    sec = plane_at((0, 0, 0), s_hat, (0, 1, 0))
    c36, s36 = math.cos(math.radians(36)), math.sin(math.radians(36))
    d, n = (c36, s36), (-s36, c36)
    sL = 20 - math.hypot(33, 20.5)
    L = (sL, 7.0)
    # right face = left face offset 4 along -n; it reaches 27 at:
    sR = sL + 4 * s36 + (27 - (7 - 4 * c36)) / math.tan(math.radians(36))
    F = (sR, 27.0)
    Tr = (F[0] + 15 * d[0], F[1] + 15 * d[1])
    Tl = (Tr[0] + 4 * n[0], Tr[1] + 4 * n[1])
    lug = Sketch(sec).poly([L, (sR, 7.0), F, Tr, Tl])
    extrude(lug, (sR - 1, 15), 7, symmetric=True, union=[body])
    # tab-face plane through the hole centre: u along the tab, v across it
    C = (F[0] + 2 * n[0] + 8 * d[0], F[1] + 2 * n[1] + 8 * d[1])
    Cw = (C[0] * s_hat[0], C[1], C[0] * s_hat[2])
    dw = (c36 * s_hat[0], s36, c36 * s_hat[2])
    tab = plane_at(Cw, dw, m_hat)
    extrude(Sketch(tab).circle((0, 0), 4), (0, 0), 5, symmetric=True, cut=[body])
    corner1 = Sketch(tab).line((0, 7), (7, 7)).line((7, 7), (7, 0)).arc((0, 0), 7, 0, 90)
    extrude(corner1, (6.5, 6.5), 5, symmetric=True, cut=[body])
    corner2 = Sketch(tab).line((0, -7), (7, -7)).line((7, -7), (7, 0)).arc((0, 0), 7, 270, 360)
    extrude(corner2, (6.5, -6.5), 5, symmetric=True, cut=[body])
    return body


@problem("5.6", 2344, features=("Extrude Boss", "Extrude Cut", "Fillet", "Plane at an angle"))
def p5_6():
    # Ring Ø23 / Ø20 × 12 about z at the origin; a Ø12 (REF = the ring's
    # width) stem down the −y axis to −25, merged into the ring and trimmed
    # by its bore; Ø8 bore 10 deep from the bottom; at y = −19 a Ø9 boss
    # standing 2 proud of the stem on +z with a Ø6 × 2 counterbore and a Ø3
    # hole into the bore. The section draws all four corners of the ring's
    # 12 × 1.5 section rounded (undimensioned, they scale to ≈ 0.5): R0.5.
    # 2357.0 − 14.5 (rounds) = 2342.5.
    from kit import back, bottom
    body = extrude(Sketch(front(-6)).circle((0, 0), 11.5), (11, 0), 12)
    # A Ø12 stem is tangent to the ring's two flat faces and the union fails
    # validity checking in every order tried (kernel limitation, logged);
    # Ø11.99 clears it and costs 3 mm³ (0.1 %).
    extrude(Sketch(top(-25)).circle((0, 0), 5.995), (0, 0), 25, union=[body])
    extrude(Sketch(back(8)).circle((0, -19), 4.5), (0, -19), 8, union=[body])
    extrude(Sketch(front(-7)).circle((0, 0), 10), (0, 0), 14, cut=[body])
    extrude(Sketch(back(8)).circle((0, -19), 3), (0, -19), 2, cut=[body])
    extrude(Sketch(back(8)).circle((0, -19), 1.5), (0, -19), 8, cut=[body])
    extrude(Sketch(top(-25)).circle((0, 0), 4), (0, 0), 10, cut=[body])
    rim = edges_where(body, lambda e: abs(abs(e["midpoint"][2]) - 6) < 0.05 and e["lengthMM"] > 5
                      and (abs(math.hypot(e["midpoint"][0], e["midpoint"][1]) - 11.5) < 0.05
                           or abs(math.hypot(e["midpoint"][0], e["midpoint"][1]) - 10) < 0.05))
    assert len(rim) >= 4, f"expected the four ring edges, found {len(rim)}"
    fillet(body, 0.5, rim)
    return body


@problem("5.7", 3494, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_7():
    # Cross-pin along +x from the tip at the origin: a Ø8 cylinder for the
    # first 13 with a flat 3 wide (chord, 11 long from the tip) on the +z
    # side and a Ø3 × 4 DEEP flat-bottomed hole 5 from the tip drilled into
    # the flat; then a plus-section (arms 3 TYP, tips trimmed by the Ø8
    # circle — the front view shows the thin arc-tip bands) to 80, and a
    # Ø12 × 3 head. 653.5 − 6.4 − 28.3 + 37.84 × 67 + 339.3 = 3493.4.
    from kit import back
    body = extrude(Sketch(right(0)).circle((0, 0), 4), (0, 0), 13)
    h = math.sqrt(16 - 2.25)
    a = math.degrees(math.atan2(1.5, h))
    cross = (Sketch(right(13)).arc((0, 0), 4, -a, a).line((h, 1.5), (1.5, 1.5)).line((1.5, 1.5), (1.5, h))
             .arc((0, 0), 4, 90 - a, 90 + a).line((-1.5, h), (-1.5, 1.5)).line((-1.5, 1.5), (-h, 1.5))
             .arc((0, 0), 4, 180 - a, 180 + a).line((-h, -1.5), (-1.5, -1.5)).line((-1.5, -1.5), (-1.5, -h))
             .arc((0, 0), 4, 270 - a, 270 + a).line((1.5, -h), (1.5, -1.5)).line((1.5, -1.5), (h, -1.5)))
    extrude(cross, (0, 0), 67, union=[body])
    extrude(Sketch(right(80)).circle((0, 0), 6), (0, 0), 3, union=[body])
    extrude(Sketch(front(h)).rect(-1, -5, 11, 5), (5, 0), 2, cut=[body])
    extrude(Sketch(back(h)).circle((-5, 0), 1.5), (-5, 0), 4, cut=[body])
    return body


@problem("5.8", 132174, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_8():
    # Bent bar 60 wide × 13: flat 77 from the origin (top-left corner, on the
    # top face), then 30° down (150°) with a sharp mitre, the leg 50 to a
    # Ø25 hole and an R30 end. Lug 55 × 10, hole Ø25 32 above the plate,
    # R27.5 crown, on a plane through a plan line at 60° from the front edge
    # at x = 25, leaning 15° (75° to the plate) toward −x; extruded 10
    # toward the lean so a 12.5 mm² × 55 wedge sits inside the plate.
    # 119 742 − 5 022 − 6 381 + 24 570 − 737 = 132 171.
    d = (math.cos(math.radians(30)), -math.sin(math.radians(30)))
    n = (-d[1], d[0]) if False else (-0.5, -math.cos(math.radians(30)))
    P = (77.0, 0.0)
    E = (P[0] + 80 * d[0], P[1] + 80 * d[1])
    Eb = (E[0] + 13 * n[0], E[1] + 13 * n[1])
    s_in = (13 - 13 * (-n[1])) / (-d[1])            # bottom lines meet at y = -13
    I = (P[0] + s_in * d[0] + 13 * n[0], -13.0)
    bar = Sketch(front(0)).poly([(0, 0), P, E, Eb, I, (0, -13)])
    body = extrude(bar, (30, -6), 30, symmetric=True)          # symmetric = ±distance
    leg = plane_at((77, 0, 0), (d[0], d[1], 0), (0, 0, 1))          # extrudes along n (into the leg)
    extrude(Sketch(leg).circle((50, 0), 12.5), (50, 0), 20, cut=[body])
    c1 = Sketch(leg).line((50, 30), (80, 30)).line((80, 30), (80, 0)).arc((50, 0), 30, 0, 90)
    extrude(c1, (78, 28), 20, cut=[body])
    c2 = Sketch(leg).line((50, -30), (80, -30)).line((80, -30), (80, 0)).arc((50, 0), 30, 270, 360)
    extrude(c2, (78, -28), 20, cut=[body])
    b = (0.5, 0, -math.cos(math.radians(60)) * 0 - math.sin(math.radians(60)))   # base line, 60° in plan
    lean = (-math.sin(math.radians(60)), 0, -0.5)                                  # plan-perpendicular, toward -x
    s15, c15 = math.sin(math.radians(15)), math.cos(math.radians(15))
    u = (s15 * lean[0], c15, s15 * lean[2])
    lug = plane_at((25, 0, 30), b, u)
    prof = (Sketch(lug).line((0, 0), (55, 0)).line((55, 0), (55, 32)).arc((27.5, 32), 27.5, 0, 180)
            .line((0, 32), (0, 0)).circle((27.5, 32), 12.5))
    extrude(prof, (10, 10), -10, union=[body])       # b × u points away from the lean: go the other way
    return body


@problem("5.10", 105501, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_10():
    # Triangular plate 10 thick: hull of R15 rounds about the Ø8 hole centres
    # at the origin (apex) and (±37.5, 60 back), origin on the bottom face.
    # A Ø32/Ø21 pipe 85 long on the centreline, tangent to the plate top
    # (axis 26 up), from 20 behind the apex to 30 past the base edge; a
    # 32-wide saddle block from the base edge to the pipe's near end fills
    # up to the axis height. 60 537 + 28 160 + 38 920 − 22 117 = 105 500.
    L = math.hypot(37.5, 60)
    nx, ny = 60 / L, 37.5 / L                      # outward normal of the right side
    a1 = math.degrees(math.atan2(ny, nx))
    pl = (Sketch(top(0)).line((-37.5, -75), (37.5, -75)).arc((37.5, -60), 15, 270, 360 + a1)
          .line((37.5 + 15 * nx, -60 + 15 * ny), (15 * nx, 15 * ny)).arc((0, 0), 15, a1, 180 - a1)
          .line((-15 * nx, 15 * ny), (-37.5 - 15 * nx, -60 + 15 * ny)).arc((-37.5, -60), 15, 180 - a1, 270)
          .circle((0, 0), 4).circle((37.5, -60), 4).circle((-37.5, -60), 4))
    body = extrude(pl, (0, -40), 10)
    extrude(Sketch(top(10)).rect(-16, -75, 16, -20), (0, -50), 16, union=[body])
    extrude(Sketch(front(20)).circle((0, 26), 16), (0, 26), 85, union=[body])
    extrude(Sketch(front(19)).circle((0, 26), 10.5), (0, 26), 87, cut=[body])
    return body


def _corner(p_prev, p, p_next, r):
    """Sketch-fillet data for corner p: (tangent_in, tangent_out, centre, a_in, a_out) in degrees."""
    a = (p_prev[0] - p[0], p_prev[1] - p[1]); la = math.hypot(*a); a = (a[0] / la, a[1] / la)
    b = (p_next[0] - p[0], p_next[1] - p[1]); lb = math.hypot(*b); b = (b[0] / lb, b[1] / lb)
    theta = math.acos(max(-1.0, min(1.0, a[0] * b[0] + a[1] * b[1])))
    d = r / math.tan(theta / 2)
    ta = (p[0] + a[0] * d, p[1] + a[1] * d); tb = (p[0] + b[0] * d, p[1] + b[1] * d)
    bis = (a[0] + b[0], a[1] + b[1]); lbis = math.hypot(*bis)
    c = (p[0] + bis[0] / lbis * r / math.sin(theta / 2), p[1] + bis[1] / lbis * r / math.sin(theta / 2))
    return ta, tb, c, math.degrees(math.atan2(ta[1] - c[1], ta[0] - c[0])), math.degrees(math.atan2(tb[1] - c[1], tb[0] - c[0]))


def _arc_short(sk, c, r, a0, a1):
    sweep = (a1 - a0) % 360
    if sweep > 180:
        sk.arc(c, r, a1, a0 + 360 if a0 < a1 else a0)
    else:
        sk.arc(c, r, a0, a0 + sweep)


@problem("5.11", 208819, features=("Extrude Boss", "Extrude Cut", "Fillet", "Plane at an angle"))
def p5_11():
    # Block 88 wide × 110 deep, origin at the top front edge's midpoint. Slab
    # 24 thick, the back 35 stepped up 6 (R3 in the corner), R5 on the two
    # top long edges; 4 × Ø10 at ±27.5, 15 and 50 from the back. Front leg
    # 12 deep: sides 24 down then tangents to an R25 bottom about the Ø19
    # hole centre 40 below the top (R5 at the junction corners). Scoop: an
    # R23 cylinder whose axis passes through the origin rising 25° toward
    # the back (the section's straight cut line). 213 840 + 170 − 6 597
    # − 1 180 + 23 763 − 21 177 = 208 819.
    from kit import back
    slab = Sketch(back(0)).rounded_poly([(-44, -24), (44, -24), (44, 0), (-44, 0)], [0, 0, 5, 5])
    body = extrude(slab, (0, -12), 110)
    extrude(Sketch(top(-24)).rect(-45, 75, 45, 111), (0, 90), 6, cut=[body])
    step = edges_where(body, lambda e: abs(e["midpoint"][1] + 18) < 0.1 and abs(e["midpoint"][2] + 75) < 0.1 and e["lengthMM"] > 80)
    assert len(step) == 1, f"step edge: {len(step)}"
    fillet(body, 3, step)
    # leg profile (u = -x on back(0) — symmetric, so plain x is fine)
    C = (0, -40); R = 25
    P = (44, -24); dcp = math.hypot(P[0] - C[0], P[1] - C[1])
    phi = math.acos(R / dcp); base = math.atan2(P[1] - C[1], P[0] - C[0])
    at = base - phi                                   # right tangent point angle
    Tr = (C[0] + R * math.cos(at), C[1] + R * math.sin(at)); Tl = (-Tr[0], Tr[1])
    sk = Sketch(back(0))
    tA = _corner((-44, -24), (-44, 0), (44, 0), 5); tB = _corner((-44, 0), (44, 0), (44, -24), 5)
    tC = _corner((44, 0), (44, -24), Tr, 5); tD = _corner(Tl, (-44, -24), (-44, 0), 5)
    for t in (tA, tB, tC, tD):
        _arc_short(sk, t[2], 5, t[3], t[4])
    sk.line(tA[1], tB[0]).line(tB[1], tC[0]).line(tC[1], Tr)
    # bottom arc CCW from Tl (−142.3°) through −90° to Tr (−37.7°)
    sk.arc(C, R, math.degrees(math.atan2(Tl[1] - C[1], Tl[0] - C[0])), math.degrees(at) + 360)
    sk.line(Tl, tD[0]).line(tD[1], tA[0])
    extrude(sk, (0, -30), 12, union=[body])
    extrude(Sketch(back(1)).circle((0, -40), 9.5), (0, -40), 14, cut=[body])
    for u in (-27.5, 27.5):
        for v in (60, 95):
            extrude(Sketch(top(1)).circle((u, v), 5), (u, v), -26, cut=[body])
    s, c = math.sin(math.radians(25)), math.cos(math.radians(25))
    scoop = plane_at((0, 0, 0), (1, 0, 0), (0, -c, -s))
    extrude(Sketch(scoop).circle((0, 0), 23), (0, 0), 70, symmetric=True, cut=[body])
    return body


@problem("5.12", 110020, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_12():
    # Read as: block 13 (x) × 75 (z) × 50 with R25 bottom / R6 top corners
    # in its yz profile (origin at the back-bottom-front corner, z from 0 to
    # −75); a curved wall 35 tall on the block's back edge, 50 wide, 3 thick
    # at the ends with an R45 convex face (apex 10.6 from the back); a root
    # plate 8 thick (y 42..50) 50 wide at the block narrowing to an R45
    # concave front at x ≈ 23–26; arm 5 × 8 to a Ø38 × 30 boss (y 30..60,
    # Ø13 through) at x = 85, with a 3-thick web 12 tall under the arm (the
    # front view's 30..42 band). Views give no wider member under the arm,
    # so this reading is ≈ 12 % light — see notes.
    from kit import right, back
    prof = Sketch(right(0)).rounded_poly([(0, 0), (75, 0), (75, 50), (0, 50)], [25, 25, 6, 6])
    body = extrude(prof, (37.5, 25), 13)                       # right(0): u = -z → z 0..−75
    seg = 45 - math.sqrt(45 ** 2 - 25 ** 2)
    cx = 3 + seg - 45
    a = math.degrees(math.asin(25 / 45))
    wall = (Sketch(top(50)).line((0, 12.5), (0, 62.5)).line((0, 62.5), (3, 62.5))
            .arc((cx, 37.5), 45, -a, a).line((3, 12.5), (0, 12.5)))
    extrude(wall, (2, 37.5), 35, union=[body])
    root_c = (22.7 + 45, 37.5)
    dz = math.sqrt(45 ** 2 - (root_c[0] - 26) ** 2)          # arc ends exactly on x = 26
    b = math.degrees(math.atan2(dz, root_c[0] - 26))
    root = (Sketch(top(42)).line((13, 12.5), (13, 62.5)).line((13, 62.5), (26, 62.5))
            .line((26, 62.5), (26, 37.5 + dz)).arc(root_c, 45, 180 - b, 180 + b)
            .line((26, 37.5 - dz), (26, 12.5)).line((26, 12.5), (13, 12.5)))
    extrude(root, (18, 37.5), 8, union=[body])
    extrude(Sketch(top(42)).rect(13, 35, 70, 40), (40, 37.5), 8, union=[body])
    extrude(Sketch(top(30)).rect(13, 36, 70, 39), (40, 37.5), 12, union=[body])
    extrude(Sketch(top(30)).circle((85, 37.5), 19).circle((85, 37.5), 6.5), (85, 22), 30, union=[body])
    return body


@problem("5.15", 374749, features=("Extrude Boss", "Extrude Cut", "Plane at an angle"))
def p5_15():
    # Base 160 × 100 × 15, R15 corners, 4 × Ø12 on 130 × 70; origin at the
    # left end, mid-width, bottom face. A 15-thick flange whose top surface
    # runs from the base's far top edge (160, 15) up at 30°: tongue 35 wide
    # (plan) to a Ø75 disc centred 100 up the slope, R15 blends, a 30-wide
    # lug with an R15 end and Ø13 hole 50 sideways from the disc centre, Ø30
    # bore. A Ø50 boss coaxial with the bore from the flange's underside to
    # the base, a 15-wide rib under the tongue; the bore runs through the
    # base as well (the plan draws the hole dark). Lands at −0.09 %.
    base = Sketch(top(0)).rounded_poly([(0, -50), (160, -50), (160, 50), (0, 50)], 15)
    for u in (15, 145):
        for v in (-35, 35):
            base.circle((u, v), 6)
    body = extrude(base, (80, 0), 15)
    c30, s30 = math.cos(math.radians(30)), math.sin(math.radians(30))
    d = (-c30, s30, 0); n = (s30, c30, 0)
    flange = plane_at((160, 15, 0), d, (0, 0, 1))                 # d × z = n (up); extrude −15 = down
    R, hw, rf = 37.5, 17.5, 15.0
    C = (100.0, 0.0)
    F1 = (C[0] - math.sqrt((R + rf) ** 2 - (hw + rf) ** 2), hw + rf)
    T1 = (F1[0], hw)
    T2 = (F1[0] + rf * (C[0] - F1[0]) / (R + rf), F1[1] + rf * (C[1] - F1[1]) / (R + rf))
    aT2 = math.degrees(math.atan2(T2[1] - C[1], T2[0] - C[0]))
    aF = math.degrees(math.atan2(T2[1] - F1[1], T2[0] - F1[0]))
    vf = -math.sqrt(R ** 2 - 15 ** 2)
    aR = math.degrees(math.atan2(vf, 15)); aL = math.degrees(math.atan2(vf, -15)) % 360
    sk = (Sketch(flange).line((0, -hw), (0, hw)).line((0, hw), T1).arc(F1, rf, -90, aF)
          .arc(C, R, aR, aT2)
          .line((115, vf), (115, -50)).arc((100, -50), 15, 180, 360).line((85, -50), (85, vf))
          .arc(C, R, 360 - aT2, aL)
          .arc((F1[0], -F1[1]), rf, -aF, 90).line((T1[0], -hw), (0, -hw))
          .circle(C, 15).circle((100, -50), 6.5))
    extrude(sk, (30, 0), -15, union=[body])
    under = plane_at((160 - 15 * n[0], 15 - 15 * n[1], 0), d, (0, 0, 1))
    extrude(Sketch(under).circle(C, 25), (100, 20), -60, union=[body])
    extrude(Sketch(top(0)).rect(-10, -60, 170, 60), (80, 0), -40, cut=[body])   # trim the boss under the base
    yr = 15 + 70 * math.tan(math.radians(30))
    extrude(Sketch(front(-7.5)).poly([(130, 15), (60, yr), (60, 15)]), (100, 20), 15, union=[body])
    extrude(Sketch(flange).circle(C, 15), (100, 0), -130, cut=[body])
    return body
