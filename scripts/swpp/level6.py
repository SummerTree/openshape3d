"""Level 6 — Revolve Boss/Cut (20 problems)."""
import math
from kit import Sketch, front, top, right, extrude, revolve, fillet, edges_where, bounds

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Revolve",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("6.6", 21076)
def p6_6():
    # Stepped shaft along x: Ø20 (0..7), Ø16 neck (7..10), Ø26 (10..28),
    # Ø20 (28..42), Ø16 (42..55), Ø12 (55..72), Ø8 (72..82); a Ø5 bore 36
    # deep with a 118° drill point to 38, all in one revolved profile.
    outer = [(0, 10), (7, 10), (7, 8), (10, 8), (10, 13), (28, 13), (28, 10), (42, 10),
             (42, 8), (55, 8), (55, 6), (72, 6), (72, 4), (82, 4), (82, 0)]
    pts = [(0, 2.5)] + outer + [(38, 0), (36, 2.5)]
    sk = Sketch(front(0)).poly(pts)
    return revolve(sk, (20, 5), (0, 0), (1, 0))


@problem("6.19", 11704)
def p6_19():
    # Post: Ø17 base tapering 4° from vertical; head = a 90° double cone
    # 24 across, the upper cone 9 high to the apex at 71, the lower cone's
    # side perpendicular to the upper one down to the shaft. (Built as
    # drawn; the sheet's number is ~5 % more — see notes.)
    t = math.tan(math.radians(4))
    apex, rim_y, rim_r = 71.0, 62.0, 12.0
    # lower cone side direction ⟂ (rim→apex) = (-12, 9): (-9, -12)
    # r_lower(y) = rim_r - (rim_y - y) * 9/12
    lo, hi = 20.0, 61.0
    for _ in range(60):
        mid = (lo + hi) / 2
        f = (8.5 - t * mid) - (rim_r - (rim_y - mid) * 0.75)
        lo, hi = (mid, hi) if f > 0 else (lo, mid)
    yj = (lo + hi) / 2
    rj = 8.5 - t * yj
    sk = Sketch(front(0)).poly([(0, 0), (8.5, 0), (rj, yj), (rim_r, rim_y), (0, apex)])
    return revolve(sk, (3, 20), (0, 0), (0, 1))


@problem("6.16", 4080)
def p6_16():
    # Peg: Ø13 base tapering 6° (from vertical) up into a Ø16 ball centred
    # 32 up, the ball cut flat at 37. The taper meets the ball at y = 25.
    t = math.tan(math.radians(6))
    R, cy, top_y = 8.0, 32.0, 37.0
    # cone r(y) = 6.5 - t*y  meets  sqrt(R² - (y-cy)²)
    lo, hi = 20.0, 31.0
    for _ in range(60):
        mid = (lo + hi) / 2
        f = (6.5 - t * mid) - math.sqrt(max(R * R - (mid - cy) ** 2, 0))
        lo, hi = (mid, hi) if f > 0 else (lo, mid)
    ym = (lo + hi) / 2
    rm = 6.5 - t * ym
    rt = math.sqrt(R * R - (top_y - cy) ** 2)
    a0 = math.degrees(math.atan2(ym - cy, rm))
    a1 = math.degrees(math.atan2(top_y - cy, rt))
    sk = (Sketch(front(0)).line((0, 0), (6.5, 0)).line((6.5, 0), (rm, ym))
          .arc((0, cy), R, a0, a1).line((rt, top_y), (0, top_y)).line((0, top_y), (0, 0)))
    return revolve(sk, (3, 10), (0, 0), (0, 1))


@problem("6.15", 137296)
def p6_15():
    # Bowl, 5-thick sheet of revolution: flat bottom Ø75 (to the sharp
    # corner), 45° sides (135° inside angle) to a Ø165 rim, R25 outer bend
    # with a concentric R20 inner bend; the rim cut horizontally.
    c = (37.5 - 25 * math.tan(math.radians(22.5)), 25.0)      # bend centre
    def on(r, ang):
        return (c[0] + r * math.cos(math.radians(ang)), c[1] + r * math.sin(math.radians(ang)))
    o_end, i_end = on(25, -45), on(20, -45)
    # outer 45° line from o_end to the rim at y = 45 → x = o_end.x + (45 - o_end.y)
    top_y = 45.0
    o_rim = (o_end[0] + (top_y - o_end[1]), top_y)
    i_rim = (i_end[0] + (top_y - i_end[1]), top_y)
    sk = (Sketch(front(0)).line((0, 0), on(25, -90)).arc(c, 25, -90, -45)
          .line(o_end, o_rim).line(o_rim, i_rim).line(i_rim, i_end)
          .arc(c, 20, -90, -45).line(on(20, -90), (0, 5)).line((0, 5), (0, 0)))
    return revolve(sk, (10, 2.5), (0, 0), (0, 1))


@problem("6.18", 10337)
def p6_18():
    # Post: Ø17 base tapering 4° to a Ø10 waist at 50, flaring to a Ø18 rim
    # at 68 with a 2-high conical point; the flare meets the cap at 90°.
    t4 = math.tan(math.radians(4))
    cap_ang = math.atan2(2, 9)                    # cap surface vs horizontal
    # flare direction is perpendicular to the cap surface: rises 9 per 2 out
    # r_flare(y) = 9 - (68 - y) * tan(cap_ang)
    tf = math.tan(cap_ang)
    yw = (9 - 68 * tf - 8.5) / (-t4 - tf) if False else None
    # solve 8.5 - t4*y = 9 - (68 - y)*tf  →  y (tf - t4) = 0.5 + 68 tf - 9 + ... do it numerically
    lo, hi = 10.0, 67.0
    for _ in range(60):
        mid = (lo + hi) / 2
        f = (8.5 - t4 * mid) - (9 - (68 - mid) * tf)
        lo, hi = (mid, hi) if f > 0 else (lo, mid)
    yw = (lo + hi) / 2
    rw = 8.5 - t4 * yw
    sk = (Sketch(front(0)).poly([(0, 0), (8.5, 0), (rw, yw), (9, 68), (0, 70)]))
    return revolve(sk, (3, 20), (0, 0), (0, 1))


@problem("6.1", 5996, features=("Revolve",))
def p6_1():
    # Pawn, 38 tall, one axis. Base Ø18 × 3 with an R1.5 bottom rim;
    # body from a Ø13 foot on the base: an R6 bulb through the foot and
    # tangent to the R15 concave neck that meets the collar at Ø8; collar
    # Ø13 × 3 (R1.5 top rim) with its top 12.5 below the crown of the R7.5
    # sphere. The bulb centre (c, h) solves |C-(6.5,3)| = 6 and
    # |C-(19,22.5)| = 21 (tangent to the neck arc centred 15 out from Ø8).
    d = math.hypot(12.5, 19.5)
    a = (36 - 441 + d * d) / (2 * d)
    hh = math.sqrt(36 - a * a)
    px, py = 6.5 + a * 12.5 / d, 3 + a * 19.5 / d
    c, h = px - hh * 19.5 / d, py + hh * 12.5 / d          # the bulb-side root
    tx, ty = c + 6 * (19 - c) / 21, h + 6 * (22.5 - h) / 21  # tangency point
    a0 = math.degrees(math.atan2(3 - h, 6.5 - c))
    a1 = math.degrees(math.atan2(ty - h, tx - c))
    n1 = math.degrees(math.atan2(ty - 22.5, tx - 19)) % 360
    axis = ((0, 0), (0, 1))
    # Each R1.5 callout names ONE edge: the base's bottom rim and the
    # collar's top rim; the other edge of each stays sharp (a full round on
    # both rings reads 0.8 % light).
    base = revolve(Sketch(front(0)).line((0, 0), (7.5, 0)).arc((7.5, 1.5), 1.5, -90, 0)
                   .line((9, 1.5), (9, 3)).line((9, 3), (0, 3)).line((0, 3), (0, 0)), (3, 1.5), *axis)
    body = (Sketch(front(0)).line((0, 3), (6.5, 3)).arc((c, h), 6, a0, a1)
            .arc((19, 22.5), 15, 180, n1).line((4, 22.5), (0, 22.5)).line((0, 22.5), (0, 3)))
    revolve(body, (2, 10), *axis, union=[base])
    collar = (Sketch(front(0)).line((0, 22.5), (6.5, 22.5)).line((6.5, 22.5), (6.5, 24))
              .arc((5, 24), 1.5, 0, 90).line((5, 25.5), (0, 25.5)).line((0, 25.5), (0, 22.5)))
    revolve(collar, (2.5, 24), *axis, union=[base])
    sphere = Sketch(front(0)).arc((0, 30.5), 7.5, -90, 90).line((0, 38), (0, 23))
    revolve(sphere, (3, 30.5), *axis, union=[base])
    return base


@problem("6.17", 7587, features=("Revolve", "Extrude Cut", "Plane at an angle"))
def p6_17():
    # Peg: cone Ø17 at the base tapering 6° per side up to a Ø16 ball whose
    # centre sits 54 up (read to the centre: to the ball's top the part is
    # 4.7 % light); a slot 3 wide, 6 deep at 45° across the ball. Cone
    # 5893 + ball 2145 − overlap 226 − slot 204 = 7608.
    from kit import plane_at
    t = math.tan(math.radians(6))
    axis = ((0, 0), (0, 1))
    cone = (Sketch(front(0)).line((0, 0), (8.5, 0)).line((8.5, 0), (8.5 - 54 * t, 54))
            .line((8.5 - 54 * t, 54), (0, 54)).line((0, 54), (0, 0)))
    body = revolve(cone, (3, 20), *axis)
    ball = Sketch(front(0)).arc((0, 54), 8, -90, 90).line((0, 62), (0, 46))
    revolve(ball, (3, 54), *axis, union=[body])
    d = (math.cos(math.radians(45)), math.sin(math.radians(45)), 0)
    plane = plane_at((0, 54, 0), d, (0, 0, 1))          # u along the slot's depth, v across the ball
    extrude(Sketch(plane).rect(2, -12, 20, 12), (10, 0), 1.5, symmetric=True, cut=[body])
    return body


@problem("6.2", 9603, features=("Revolve", "Extrude Boss", "Extrude Cut", "Chamfer"))
def p6_2():
    # Pressed dome plate: 65 × 50 × 3 with R6 corners and 4 × Ø5 holes at the
    # corner centres (1.5 × 45° chamfer on the top face, Section B-B). Dome =
    # a 3-thick sheet of revolution: rim bend R6 in / R9 out about (22.5, 9),
    # 100° cone (flanks 40° to the plate), top bend R9 out / R6 in, Ø14 hole.
    # The height isn't called out: the top bend starts at the hole's edge
    # (r = 7, as drawn), which puts the top at 11.42. Plate 9337 − chamfers
    # 85 + dome 5036 − disc removed 4771 = 9601.
    from kit import chamfer, edges_where
    pl = Sketch(top(0)).rounded_poly([(-32.5, -25), (32.5, -25), (32.5, 25), (-32.5, 25)], 6)
    for u in (-26.5, 26.5):
        for v in (-19, 19):
            pl.circle((u, v), 2.5)
    body = extrude(pl, (0, 0), 3)
    rims = edges_where(body, lambda e: abs(e["midpoint"][1] - 3) < 0.01 and abs(e["lengthMM"] - 2 * math.pi * 2.5) < 0.4)   # rims report a tessellated length (15.51)
    assert len(rims) == 4, f"hole rims: {len(rims)}"
    chamfer(body, 1.5, rims)
    extrude(Sketch(top(-1)).circle((0, 0), 22.5), (0, 0), 5, cut=[body])
    s40, c40 = math.sin(math.radians(40)), math.cos(math.radians(40))
    Ttop = (22.5 - 6 * s40, 9 - 6 * c40)
    Tbot = (22.5 - 9 * s40, 9 - 9 * c40)
    rc = 7.0
    H = 9 + Ttop[1] + (-9 - (rc - Ttop[0]) * s40) / c40
    Ct = (rc, H - 9)
    sk = (Sketch(front(0)).line((22.5, 0), (22.5, 3)).arc((22.5, 9), 6, 230, 270)
          .line(Ttop, (Ct[0] + 9 * s40, Ct[1] + 9 * c40)).arc(Ct, 9, 50, 90)
          .line((7, H), (7, H - 3)).arc(Ct, 6, 50, 90)                 # rc = 7: no flat, the arc ends on the hole
          .line((Ct[0] + 6 * s40, Ct[1] + 6 * c40), Tbot).arc((22.5, 9), 9, 230, 270))
    revolve(sk, (21, 1.5), (0, 0), (0, 1), union=[body])
    return body


@problem("6.3", 427, features=("Revolve", "Extrude Boss", "Sketch: Polygon", "Chamfer"))
def p6_3():
    # Hex bit: 6 A/F shank 0..13, 4 A/F tip 13..17, revolved 1 × 45° chamfer
    # at the base and 0.5 × 45° at the tip (corner setbacks), and an R4.5
    # revolved groove whose centre sits at the tip's base level; its radial
    # position is taken so the groove bottoms out on the tip's corner circle
    # (c = 4.5 + 2/cos 30° = 6.81; the drawn + marks scale to ≈ 6.7). The R1
    # at the junction has no corner to sit in under this reading. ≈ 429.
    body = extrude(Sketch(top(0)).polygon_flats((0, 0), 6, 6), (0, 0), 13)
    extrude(Sketch(top(13)).polygon_flats((0, 0), 4, 6), (0, 0), 4, union=[body])
    axis = ((0, 0), (0, 1))
    rc6 = 3 / math.cos(math.radians(30))
    revolve(Sketch(front(0)).poly([(rc6 - 1, 0), (5, 0), (5, 1 + (5 - rc6))]), (4.5, 0.3), *axis, cut=[body])
    rc4 = 2 / math.cos(math.radians(30))
    revolve(Sketch(front(0)).poly([(rc4 - 0.5, 17), (4, 17), (4, 17 - (4 - rc4 + 0.5))]), (3.5, 16.8), *axis, cut=[body])
    c = 4.5 + rc4
    revolve(Sketch(front(0)).circle((c, 13), 4.5), (c, 13), *axis, cut=[body])
    return body


@problem("6.4", 370322, features=("Revolve", "Extrude Boss", "Extrude Cut", "Fillet", "Circular Pattern"))
def p6_4():
    # Elbow: bore Ø56, wall 11 (OD 78), bent 38° about a centre 117 from the
    # axis at the base flange's top face (R78 = the inside of the bend), no
    # straight legs (the drawn bend centre sits exactly on the flange's top).
    # Flanges 11 thick, ring width 33 from the bore (OD 122), 12 × Ø7.33
    # each on R50 (11 in from the rim). 8 × R2: the four rim edges, the two
    # tube/flange fillets and the two bore edges at the end faces.
    # 2 × 95 924 + 2315.3 × 77.6 − 1 198 = 370 312.
    from kit import plane_at
    def flange_sketch(sk, cx=0.0, cy=0.0):
        sk.circle((cx, cy), 61).circle((cx, cy), 28)
        for k in range(12):
            a = math.radians(30 * k)
            sk.circle((cx + 50 * math.cos(a), cy + 50 * math.sin(a)), 7.33 / 2)
        return sk
    body = extrude(flange_sketch(Sketch(top(0))), (44, 0), 11)
    ring = Sketch(top(11)).circle((0, 0), 39).circle((0, 0), 28)
    revolve(ring, (33, 0), (-117, 0), (0, -1), angle=38, union=[body])   # +38° about sketch +v swept the tube down
    c38, s38 = math.cos(math.radians(38)), math.sin(math.radians(38))
    P = (-117 + 117 * c38, 11 + 117 * s38, 0)
    t = (-s38, c38, 0)
    end = plane_at(P, (0, 0, 1), (c38, s38, 0))              # z × radial = t (outward)
    extrude(flange_sketch(Sketch(end)), (0, 44), 11, union=[body])
    bmin, bmax = bounds(body)
    assert bmax[1] > 60, f"bend went the wrong way: {bmax}"
    Ptop = (P[0] + 11 * t[0], P[1] + 11 * t[1], 0)
    def on_top_end(m):
        return abs((m[0] - Ptop[0]) * t[0] + (m[1] - Ptop[1]) * t[1]) < 0.3
    rims = edges_where(body, lambda e: abs(e["lengthMM"] - 2 * math.pi * 61) < 12)
    necks = edges_where(body, lambda e: abs(e["lengthMM"] - 2 * math.pi * 39) < 8)
    bores = edges_where(body, lambda e: abs(e["lengthMM"] - 2 * math.pi * 28) < 6
                        and (abs(e["midpoint"][1]) < 0.3 or on_top_end(e["midpoint"])))
    assert (len(rims), len(necks), len(bores)) == (4, 2, 2), f"fillet edges: {len(rims)}, {len(necks)}, {len(bores)}"
    fillet(body, 2, rims + necks + bores)
    return body


@problem("6.7", 6049, features=("Revolve", "Extrude Boss", "Sketch: Slot", "Fillet"))
def p6_7():
    # Eye bolt: stadium ring 22 × 14 outside, wall 3 (16 × 8 slot), 15 wide
    # along the axis, origin at its centre; Ø11 shank down to 45 below it,
    # then a Ø5 × 7 tip (52 overall); R2 fillet where the shank meets the
    # eye. The eye is taken as a straight extrusion (its side profile is
    # undimensioned). 2275 + 3611 + 137 + 30 = 6053.
    from kit import edges_where
    eye = Sketch(front(-7.5)).slot((-4, 0), (4, 0), 7).slot((-4, 0), (4, 0), 4)
    body = extrude(eye, (0, 5.5), 15)
    extrude(Sketch(top(-45)).circle((0, 0), 5.5), (0, 0), 41, union=[body])
    extrude(Sketch(top(-52)).circle((0, 0), 2.5), (0, 0), 7, union=[body])
    junction = edges_where(body, lambda e: -7.2 < e["midpoint"][1] < -6.3 and math.hypot(e["midpoint"][0], e["midpoint"][2]) < 6.5)
    if junction:
        try:
            fillet(body, 2, junction)
        except Exception as exc:  # noqa: BLE001 - recorded in the notes
            print("6.7: shank/eye fillet skipped:", str(exc)[:120])
    return body


@problem("6.8", 9738, features=("Revolve", "Extrude Boss", "Extrude Cut"))
def p6_8():
    # Spool: Ø40 × 2 flanges either side of a Ø35 × 3 hub (origin at the hub
    # centre); under the lower flange a 5-tall open "U" boss: outer 30, inner
    # 18 (walls 6), 25 long from the outer base face to the tips, R6 on the
    # outer base corners. Its placement follows the hint: the inner base face
    # is tangent to the Ø5 through hole (centre 10 left of the axis), the
    # hole sits on the U's centreline (9 from each inner face) and the right
    # arm's inner face passes through the origin — which fixes the tilt at
    # acos(9/10): arms 64.2° from the horizontal. 7913 + 392.5 × 5 − 137 =
    # 9738.
    body = extrude(Sketch(top(1.5)).circle((0, 0), 20), (0, 0), 2)
    extrude(Sketch(top(-1.5)).circle((0, 0), 17.5), (0, 0), 3, union=[body])
    extrude(Sketch(top(-3.5)).circle((0, 0), 20), (0, 0), 2, union=[body])
    phi = math.acos(0.9)                                   # perpendicular offset 9 over a horizontal 10
    d = (math.sin(phi), math.cos(phi)); n = (math.cos(phi), -math.sin(phi))
    H = (-10.0, 0.0)
    def P(t, s):
        return (H[0] + t * d[0] + s * n[0], H[1] + t * d[1] + s * n[1])
    pts = [P(-8.5, -15), P(16.5, -15), P(16.5, -9), P(-2.5, -9), P(-2.5, 9), P(16.5, 9), P(16.5, 15), P(-8.5, 15)]
    u = Sketch(top(-8.5)).rounded_poly(pts, [6, 0, 0, 0, 0, 0, 0, 6])
    extrude(u, P(-5.5, 0), 5, union=[body])
    extrude(Sketch(top(4)).circle(H, 2.5), H, -13, cut=[body])
    return body


@problem("6.11", 12788, features=("Revolve", "Extrude Boss", "Extrude Cut", "Fillet", "Chamfer"))
def p6_11():
    # Rod end: eye Ø20 × 25 (axis z) with a Ø12 hole at the origin; arm 18
    # wide (z) whose front profile is the tangent hull from the eye to a
    # 15-tall end face at x = 25; neck Ø9 from 25 to 30 with 1 × 45°
    # chamfers at both ends (a conical fillet on the arm side, an edge
    # chamfer on the shank side); shank Ø12 to 52 with a Ø4 cross hole
    # along z at 38 and R1 on its end edge. 7854 − 2827 + 5067 + 2488 +
    # 318 − 151 − 8 − 3 = 12 738.
    from kit import chamfer
    body = extrude(Sketch(front(-12.5)).circle((0, 0), 10), (5, 0), 25)
    dP = math.hypot(25, 7.5)
    aP = math.atan2(7.5, 25); aT = aP + math.acos(10 / dP)
    T1 = (10 * math.cos(aT), 10 * math.sin(aT)); T2 = (T1[0], -T1[1])
    arm = (Sketch(front(-9)).line(T1, (25, 7.5)).line((25, 7.5), (25, -7.5)).line((25, -7.5), T2)
           .arc((0, 0), 10, math.degrees(aT), 360 - math.degrees(aT)))
    extrude(arm, (15, 0), 18, union=[body])
    extrude(Sketch(front(-13)).circle((0, 0), 6), (0, 0), 26, cut=[body])
    extrude(Sketch(right(25)).circle((0, 0), 4.5), (0, 0), 5, union=[body])
    extrude(Sketch(right(30)).circle((0, 0), 6), (0, 0), 22, union=[body])
    axis = ((0, 0), (1, 0))
    revolve(Sketch(front(0)).poly([(25, 4.5), (26, 4.5), (25, 5.5)]), (25.3, 4.7), *axis, union=[body])
    revolve(Sketch(front(0)).poly([(30, 6), (31, 6), (30, 5)]), (30.3, 5.8), *axis, cut=[body])
    extrude(Sketch(front(-7)).circle((38, 0), 2), (38, 0), 14, cut=[body])
    end = edges_where(body, lambda e: abs(e["midpoint"][0] - 52) < 0.05 and abs(e["lengthMM"] - 2 * math.pi * 6) < 1.0)
    assert len(end) == 1, f"shank end edge: {len(end)}"
    fillet(body, 1, end)
    return body


@problem("6.20", 499298, features=("Revolve", "Extrude Cut", "Sketch: Slot"))
def p6_20():
    # Ø110 sphere at the origin, cut flat at y = −30; a stadium pocket 50
    # between centres × Ø25 from the top down to the plane y = +15; the two
    # Ø25 holes at its ends continue from +15 through to the flat bottom
    # (the section hatches the 25-wide web between them).
    sph = Sketch(front(0)).arc((0, 0), 55, -90, 90).line((0, 55), (0, -55))
    body = revolve(sph, (20, 0), (0, 0), (0, 1))
    extrude(Sketch(top(-30)).rect(-60, -60, 60, 60), (0, 0), -30, cut=[body])
    extrude(Sketch(top(15)).slot((-25, 0), (25, 0), 12.5), (0, 0), 45, cut=[body])
    for u in (-25, 25):
        extrude(Sketch(top(-31)).circle((u, 0), 12.5), (u, 0), 46, cut=[body])
    return body


@problem("6.12", 4630, features=("Revolve", "Extrude Cut"))
def p6_12():
    # Ball knob, one revolve: Ø14 base; concave R4 waist whose narrowest
    # point is at y = 6 (r = 6, centre (10, 6)), an R2 convex crest at y = 10
    # tangent to it (crest r = 7.53), a second R4 concave waist tangent to
    # the R2 and to the ball, ball Ø20 centred 24 up (its diameter is not
    # called out; the section scales to 19.7); Ø7 × 10 bore from the bottom;
    # two Ø8 blind holes into the ball, from −x and from +z, each ending 4
    # past the centre (Sections A-A / B-B).
    from kit import back
    C1 = (10.0, 6.0)
    yb = 6 - math.sqrt(16 - 9)                                # R4 meets the Ø14 base
    C2 = (10 - math.sqrt(20), 10.0)                           # |C1C2| = 6 → crest r = C2.x + 2 = 7.53
    B = (0.0, 24.0)
    # C3: |C3 − C2| = 6 and |C3 − B| = 14, the root with x > 0
    dx, dy = B[0] - C2[0], B[1] - C2[1]; d = math.hypot(dx, dy)
    a = (36 - 196 + d * d) / (2 * d); h = math.sqrt(36 - a * a)
    px, py = C2[0] + a * dx / d, C2[1] + a * dy / d
    C3 = (px + h * dy / d, py - h * dx / d)
    def towards(p, q, r):
        L = math.hypot(q[0] - p[0], q[1] - p[1])
        return (p[0] + r * (q[0] - p[0]) / L, p[1] + r * (q[1] - p[1]) / L)
    def ang(c, p):
        return math.degrees(math.atan2(p[1] - c[1], p[0] - c[0])) % 360
    def arc_ccw(sk, c, r, a0, a1):
        if a1 <= a0:
            a1 += 360
        return sk.arc(c, r, a0, a1)
    T12 = towards(C1, C2, 4); T23 = towards(C2, C3, 2); T3b = towards(C3, B, 4)
    sk = (Sketch(front(0)).line((0, 10), (3.5, 10)).line((3.5, 10), (3.5, 0)).line((3.5, 0), (7, 0)).line((7, 0), (7, yb)))
    arc_ccw(sk, C1, 4, ang(C1, T12), ang(C1, (7, yb)))        # concave, through the lower waist
    arc_ccw(sk, C2, 2, ang(C2, T12), ang(C2, T23))            # convex crest
    arc_ccw(sk, C3, 4, ang(C3, T3b), ang(C3, T23))            # concave, through the upper waist
    arc_ccw(sk, B, 10, ang(B, T3b), 90)                       # the ball up to its top
    sk.line((0, 34), (0, 10))
    body = revolve(sk, (6, 2), (0, 0), (0, 1))
    extrude(Sketch(right(-12)).circle((0, 24), 4), (0, 24), 16, cut=[body])     # from −x to x = +4
    extrude(Sketch(back(12)).circle((0, 24), 4), (0, 24), 16, cut=[body])       # from +z to z = −4
    return body


@problem("6.13", 1152651, features=("Revolve", "Extrude Boss", "Extrude Cut", "Axis"))
def p6_13():
    # Half shell (blind revolve 180°): Ø135 / Ø60, 225 along +x from the
    # origin, flat face on the xy plane, body on −z; Ø89 counterbore 72 deep
    # from the left end; a 20 × 20 pocket 35 from the right end cut from the
    # top through to the bore; a Ø14 half-round groove in the flat face 95
    # from the right end (open at that end) 56 below the axis; a 10 × 14 tab
    # 17 long off the left end face near the bottom. The end view's 43°/32°
    # radial lines are not reproduced (their meaning is not fixed by the
    # other views). 1 170 040 − 14 000 − 7 300 + 2 400 ≈ 1 151 100.
    from kit import back
    shell = Sketch(front(0)).poly([(0, 44.5), (72, 44.5), (72, 30), (225, 30), (225, 67.5), (0, 67.5)])
    body = revolve(shell, (100, 50), (0, 0), (1, 0), angle=180)
    bmin, bmax = bounds(body)
    side = -1 if bmin[2] < -1 else 1                        # the half the revolve landed on (z sign)
    v0, v1 = (0, 20) if side < 0 else (-20, 0)              # top(): v = -z
    extrude(Sketch(top(70)).rect(170, v0, 190, v1), (180, (v0 + v1) / 2), -45, cut=[body])
    extrude(Sketch(front(0)).slot((130, -56), (240, -56), 7), (180, -56), 7 * side, cut=[body])
    u0, u1 = (0, 10) if side < 0 else (-10, 0)              # right(): u = -z
    extrude(Sketch(right(0)).rect(u0, -55, u1, -41), ((u0 + u1) / 2, -48), -17, union=[body])
    return body


@problem("6.14", 39945, features=("Revolve", "Extrude Cut", "Sketch: Polygon"))
def p6_14():
    # Ø50 ball at the origin with flats at +17 and −23; the through bore is
    # the −23 flat's chord (Ø19.60 REF); a recess = the top flat offset 2
    # (Ø32.66) 5 deep, a hex socket inscribed in it 15 deep (to −3), and a
    # 2-wide × 1-deep meridian groove down the front (Detail A).
    # 60 654 − 4 189 − 10 389 − 6 032 − 96 = 39 948.
    rt = math.sqrt(25 ** 2 - 17 ** 2); rb = math.sqrt(25 ** 2 - 23 ** 2)
    a0 = math.degrees(math.atan2(-23, rb)); a1 = math.degrees(math.atan2(17, rt))
    sk = (Sketch(front(0)).line((0, -23), (rb, -23)).arc((0, 0), 25, a0, a1).line((rt, 17), (0, 17)).line((0, 17), (0, -23)))
    body = revolve(sk, (10, 0), (0, 0), (0, 1))
    rr = rt - 2
    extrude(Sketch(top(17)).circle((0, 0), rr), (0, 0), -5, cut=[body])
    extrude(Sketch(top(12)).polygon((0, 0), rr, 6, 90), (0, 0), -15, cut=[body])
    extrude(Sketch(top(-3)).circle((0, 0), rb), (0, 0), -21, cut=[body])
    revolve(Sketch(front(0)).rect(-1, 24, 1, 26), (0, 25), (0, 0), (1, 0), angle=180, cut=[body])
    return body


@problem("6.5", 292994, features=("Extrude Boss", "Revolve Cut", "Extrude Cut"))
def p6_5():
    # Cable-guide block: a D outline (R50 about the origin plus the 50 × 50
    # square in the +x/+y quadrant), 50 deep along z, Ø25 through. A rope
    # groove of R16 centred on the perimeter at mid depth: a 270° revolve
    # cut round the R50 part (inner-half torus 81 879) continuing as a
    # straight half-cylinder channel along the y = 50 flat (20 106); the
    # x = 50 flat stays plain (right view). 419 524 − 24 544 − 81 879 −
    # 20 106 = 292 996.
    sk = (Sketch(front(0)).arc((0, 0), 50, 90, 360).line((50, 0), (50, 50)).line((50, 50), (0, 50))
          .circle((0, 0), 12.5))
    body = extrude(sk, (-20, -20), 50)
    # right plane: u = −z, v = y → tube centre (z = 25, y = 50); the axis is
    # given in sketch coords, u = −1 is world +z; 270° from +y must run
    # through −x and −y to +x (the round side), checked by the volume.
    revolve(Sketch(right(0)).circle((-25, 50), 16), (-25, 50), (0, 0), (-1, 0), angle=270, cut=[body])
    extrude(Sketch(right(0)).circle((-25, 50), 16), (-25, 50), 50, cut=[body])
    return body


@problem("6.10", 532863, features=("Extrude Boss", "Extrude Cut", "Revolve Cut"))
def p6_10():
    # Pipe tee with lugs: Ø80 vertical body 130 tall hanging from the
    # origin, Ø40 blind bore ending in a 90° drill point at the branch axis
    # (Section B-B), Ø55/Ø40 through branch 120 long along z centred 40 up
    # from the bottom; two 15-thick lugs at 35 below the top, R14 round end
    # about a Ø18 hole 55 from the axis, edges diverging 8° toward the body
    # (Detail A). Grid integration of this reading: 534 786.
    from kit import bottom, subtract
    body = extrude(Sketch(top(-130)).circle((0, 0), 40), (0, 0), 130)
    extrude(Sketch(front(-60)).circle((0, -90), 27.5), (0, -90), 120, union=[body])
    extrude(Sketch(bottom(0)).circle((0, 0), 20), (0, 0), 70, cut=[body])
    revolve(Sketch(front(0)).poly([(0, -70), (20, -70), (0, -90)]), (3, -72), (0, 0), (0, 1), cut=[body])
    extrude(Sketch(front(-61)).circle((0, -90), 20), (0, -90), 122, cut=[body])
    t = math.tan(math.radians(4))
    a = math.radians(94)
    tx, ty = 55 + 14 * math.cos(a), 14 * math.sin(a)          # tangent point of the 4° edge
    for s in (1, -1):
        cy = -35
        sk = (Sketch(front(-7.5))
              .line((s * 30, cy - ty - (tx - 30) * t), (s * tx, cy - ty))
              .arc((s * 55, cy), 14, -94 if s > 0 else 86, 94 if s > 0 else 274)
              .line((s * tx, cy + ty), (s * 30, cy + ty + (tx - 30) * t))
              .line((s * 30, cy + ty + (tx - 30) * t), (s * 30, cy - ty - (tx - 30) * t))
              .circle((s * 55, cy), 9))
        extrude(sk, (s * 48, cy + 11), 15, union=[body])
    return body


@problem("6.9", 537697, features=("Revolve", "Extrude Cut"))
def p6_9():
    # Revolve Ø75 x 115 + Ø100 x 70 head (185 total); one flat at z = 19
    # (top view chord) through head AND body — the side view's body width
    # (57 = 37.5 + 19) only fits the flat running the full height; 50-wide
    # slot 48 deep across the head; Ø32 through along z at y = 73; the
    # bottom 40 flatted at z = −12.5 (side view 25/40). Hand 558 200
    # (+3.8 %) — the front view's 40..115 band reads ~71 wide, not 75, so
    # the sheet is inconsistent under any dimensioned reading.
    from kit import bottom, back
    body = revolve(Sketch(front(0)).poly([(0, 0), (37.5, 0), (37.5, 115), (50, 115), (50, 185), (0, 185)]),
                   (20, 50), (0, 0), (0, 1))
    extrude(Sketch(front(19)).rect(-60, -1, 60, 190), (0, 90), 40, cut=[body])
    extrude(Sketch(bottom(185)).rect(-25, -60, 25, 60), (0, 0), 48, cut=[body])
    extrude(Sketch(front(-40)).circle((0, 73), 16), (0, 73), 80, cut=[body])
    extrude(Sketch(back(-12.5)).rect(-60, -1, 60, 40), (0, 20), 40, cut=[body])
    return body
