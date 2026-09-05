"""Level 2 — Sketch Tools & End Conditions (20 problems)."""
from kit import Sketch, front, top, bottom, right, left, extrude

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("2.13", 8009, features=("Extrude Boss", "Sketch: Polygon"))
def p2_13():
    # Hexagonal prism, 17 across flats (the Ø17 inscribed circle), 32 tall.
    return extrude(Sketch(top(0)).polygon_flats((0, 0), 17, 6), (0, 0), 32)


@problem("2.7", 56490, features=("Extrude Boss", "Sketch: Slot", "Sketch: Trim"))
def p2_7():
    # Clevis bracket, 9 thick throughout: base 40 wide from x = -86 to an
    # R20 end about the origin, with a 14-wide slot between centres 23 apart
    # ending at the origin; two ears 35 wide × 9 thick on the outer edges,
    # Ø35 round tops about a Ø14 hole 38 up.
    base = (Sketch(top(0)).line((-86, 20), (0, 20)).arc((0, 0), 20, -90, 90)
            .line((0, -20), (-86, -20)).line((-86, -20), (-86, 20))
            .slot((-23, 0), (0, 0), 7))
    body = extrude(base, (-60, 10), 9)
    for z0 in (11, -20):
        ear = (Sketch(front(z0)).line((-86, 0), (-51, 0)).line((-51, 0), (-51, 38))
               .arc((-68.5, 38), 17.5, 0, 180).line((-86, 38), (-86, 0))
               .circle((-68.5, 38), 7))
        extrude(ear, (-68.5, 15), 9, union=[body])
    return body


def _offset_polygon(pts, d):
    """Offset a CCW polygon inward by d (line-line intersections)."""
    import math
    n = len(pts)
    lines = []
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        ex, ey = q[0] - p[0], q[1] - p[1]
        L = math.hypot(ex, ey)
        nx, ny = -ey / L, ex / L                    # inward normal for CCW
        lines.append(((p[0] + nx * d, p[1] + ny * d), (ex / L, ey / L)))
    out = []
    for i in range(n):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        # solve p1 + t d1 = p2 + s d2
        det = d1[0] * (-d2[1]) - d1[1] * (-d2[0])
        rx, ry = p2[0] - p1[0], p2[1] - p1[1]
        t = (rx * (-d2[1]) - ry * (-d2[0])) / det
        out.append((p1[0] + t * d1[0], p1[1] + t * d1[1]))
    return out


@problem("2.8", 118440, features=("Extrude Boss", "Sketch: Offset", "Sketch: Trim"))
def p2_8():
    # Triangular frame 12 thick: outer (0,0)-(150,0)-(150,20)-(30,250)-(0,250),
    # a 15-wide wall (inner outline offset 15), inner corners rounded R6.
    outer = [(0, 0), (150, 0), (150, 20), (30, 250), (0, 250)]
    inner5 = _offset_polygon(outer, 15)
    # The offset of the 20-tall right edge is a 1.3 mm sliver that no R6
    # can round; drop it and let the bottom and hypotenuse offsets meet.
    (x1, y1), (x2, y2) = inner5[2], inner5[3]
    t = (15 - y1) / (y2 - y1)
    xc = x1 + t * (x2 - x1)
    inner = [inner5[0], (xc, 15), inner5[3], inner5[4]]
    # The inner top edge is only 5.9 long: two R6 rounds cannot both fit on
    # it (their tangent points would cross), so the top-left stays sharp.
    sk = Sketch(front(0)).poly(outer).rounded_poly(inner, [6, 6, 6, 0])
    return extrude(sk, (5, 5), 12)


@problem("2.11", 1387, features=("Extrude Boss", "Sketch: Trim", "Sketch: Convert", "Sketch: Mirror/Dynamic Mirror"))
def p2_11():
    # Ø25 disc with flats at x = ±10, 3 thick, Ø8 hole; 3-wide rails 2 tall
    # along both flats (the middle is a channel). One rail is mirrored.
    import math
    from kit import mirror, union, bodies
    y10 = math.sqrt(12.5 ** 2 - 100)
    a10 = math.degrees(math.atan2(y10, 10))
    base = (Sketch(top(0)).line((10, -y10), (10, y10)).arc((0, 0), 12.5, a10, 180 - a10)
            .line((-10, y10), (-10, -y10)).arc((0, 0), 12.5, 180 + a10, 360 - a10)
            .circle((0, 0), 4))
    body = extrude(base, (0, 8), 3)
    y7 = math.sqrt(12.5 ** 2 - 49)
    a7 = math.degrees(math.atan2(y7, 7))
    rail = (Sketch(top(3)).line((7, -y7), (7, y7)).arc((0, 0), 12.5, a10, a7)
            .line((10, y10), (10, -y10)).arc((0, 0), 12.5, -a7, -a10))
    extrude(rail, (8.5, 0), 2, union=[body])
    # the other rail by Transform › Mirror of a fresh rail body, then union
    rail2 = extrude(Sketch(top(3)).line((7, -y7), (7, y7)).arc((0, 0), 12.5, a10, a7)
                    .line((10, y10), (10, -y10)).arc((0, 0), 12.5, -a7, -a10), (8.5, 0), 2, new_body=True)
    mirror(rail2, (0, 0, 0), (1, 0, 0), keep=False)
    others = [b["id"] for b in bodies() if b["id"] != body]
    union(body, others)
    return body


@problem("2.17", 16206, features=("Extrude Boss", "Sketch: Slot"))
def p2_17():
    # 5-thick plate: 75 wide, 33 tall at the sides, top edge at 55 with the
    # left corner cut 35° from vertical and the right 50°; Ø12 hole at
    # (18, 33), Ø10 at (59.5, 33), an R4 slot centred at x = 37.5 between
    # y = 10 and 33.
    import math
    xl = 22 * math.tan(math.radians(35))
    xr = 75 - 22 * math.tan(math.radians(50))
    sk = (Sketch(front(0)).poly([(0, 0), (75, 0), (75, 33), (xr, 55), (xl, 55), (0, 33)])
          .circle((18, 33), 6).circle((59.5, 33), 5).slot((37.5, 10), (37.5, 33), 4))
    return extrude(sk, (10, 10), 5)


@problem("2.15", 26512, features=("Extrude Boss", "Sketch: Polygon"))
def p2_15():
    # Hex 21 AF × 61, a Ø14 × 6 neck, then a 6-thick hex head of the same size.
    body = extrude(Sketch(top(0)).polygon_flats((0, 0), 21, 6), (0, 0), 61)
    extrude(Sketch(top(61)).circle((0, 0), 7), (0, 0), 6, union=[body])
    return extrude(Sketch(top(67)).polygon_flats((0, 0), 21, 6), (0, 0), 6, union=[body])


@problem("2.14", 23839, features=("Extrude Boss", "Sketch: Polygon"))
def p2_14():
    # Hex prism 21 across flats × 60 with a Ø14 × 6 boss on top.
    body = extrude(Sketch(top(0)).polygon_flats((0, 0), 21, 6), (0, 0), 60)
    return extrude(Sketch(top(60)).circle((0, 0), 7), (0, 0), 6, union=[body])


def _lobed_outline(sk, R, rl, rf, d, angles_deg):
    """Closed outline: a disc of radius R with lobes of radius rl centred d
    from the origin at `angles_deg`, joined by concave fillets of radius rf
    (tangent to both). Offsetting inward by t is the same call with
    (R-t, rl-t, rf+t): the fillet centres do not move."""
    import math
    cosT = ((R + rf) ** 2 + d ** 2 - (rl + rf) ** 2) / (2 * (R + rf) * d)
    th = math.degrees(math.acos(cosT))
    u = lambda a: (math.cos(math.radians(a)), math.sin(math.radians(a)))
    ang = lambda v: math.degrees(math.atan2(v[1], v[0])) % 360
    n = len(angles_deg)
    for i, a in enumerate(angles_deg):
        a_prev = angles_deg[i - 1]
        s, e = (a_prev + th) % 360, (a - th) % 360
        if e < s:
            e += 360
        sk.arc((0, 0), R, s, e)                      # disc arc between lobes
        L = (d * u(a)[0], d * u(a)[1])
        F = {}
        for sign in (-1, +1):
            fa = a + sign * th
            F[sign] = ((R + rf) * u(fa)[0], (R + rf) * u(fa)[1])
            a1 = (fa + 180) % 360                    # towards the disc tangent point
            a2 = ang((L[0] - F[sign][0], L[1] - F[sign][1]))  # towards the lobe tangent point
            lo, hi = sorted((a1, a2))
            if hi - lo > 180:
                lo, hi = hi, lo + 360
            sk.arc(F[sign], rf, lo, hi)               # concave fillet
        pm = ang((F[-1][0] - L[0], F[-1][1] - L[1]))
        pp = ang((F[+1][0] - L[0], F[+1][1] - L[1]))
        s2, e2 = pm, pp
        if e2 < s2:
            e2 += 360
        aa = a % 360
        if not (s2 <= aa <= e2 or s2 <= aa + 360 <= e2):
            s2, e2 = pp, (pm + 360 if pm < pp else pm)
        sk.arc(L, rl, s2, e2)                         # lobe arc through the tip
    return sk


@problem("2.4", 42236, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs"))
def p2_4():
    # Three-lobed cover: R43 disc, 3 lobes R15 centred 43 out at 90/210/330°,
    # 6 concave R7 fillets; base layer 3 thick, a second layer 3 thick inset
    # 3 all round (Detail B); Ø16 bosses to 18 total at the lobe centres,
    # Ø11 bored, over Ø6 holes through the plate.
    import math
    angles = (90, 210, 330)
    L = [(43 * math.cos(math.radians(a)), 43 * math.sin(math.radians(a))) for a in angles]
    body = extrude(_lobed_outline(Sketch(top(0)), 43, 15, 7, 43, angles), (0, 0), 3)
    extrude(_lobed_outline(Sketch(top(3)), 40, 12, 10, 43, angles), (0, 0), 3, union=[body])
    for c in L:
        extrude(Sketch(top(6)).circle(c, 8), c, 12, union=[body])
    # Ø11 bores the full boss height, Ø6 through the two plate layers (the
    # section shows the boss as a cup over the small hole); read the other
    # way round the part is 1202 mm³ heavy — exactly 3 × Ø11 × 6 more bore.
    for c in L:
        extrude(Sketch(top(18)).circle(c, 5.5), c, -12, cut=[body])
        extrude(Sketch(top(0)).circle(c, 3), c, 6, cut=[body])
    return body


@problem("2.18", 139372, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot"))
def p2_18():
    # Arm: plate 20 thick — a Ø65 hub at the origin, a 30-wide tab out to
    # x = −55, an arm tangent to the hub ending 35 wide at x = 100 with R5
    # corners; a 15-wide slot whose round end is centred 32 from the arm's
    # end (read to the centre: to the apex the part is 1.5 % heavy); a Ø65
    # boss 20 more on top and a Ø45 hole through all 40.
    import math
    r, E = 32.5, (100.0, 17.5)
    d = math.hypot(*E)
    ang = math.degrees(math.atan2(E[1], E[0])) + math.degrees(math.acos(r / d))
    tu = (r * math.cos(math.radians(ang)), r * math.sin(math.radians(ang)))
    tl = (tu[0], -tu[1])
    body = extrude(Sketch(top(0)).circle((0, 0), r), (0, 0), 20)
    extrude(Sketch(top(0)).rounded_poly([tl, (100, -17.5), (100, 17.5), tu], [0, 5, 5, 0]), (60, 0), 20, union=[body])
    extrude(Sketch(top(0)).rect(-55, -15, 0, 15), (-40, 0), 20, union=[body])
    extrude(Sketch(top(20)).slot((68, 0), (110, 0), 7.5), (90, 0), -20, cut=[body])
    extrude(Sketch(top(20)).circle((0, 0), r), (0, 20), 20, union=[body])
    extrude(Sketch(top(40)).circle((0, 0), 22.5), (0, 0), -40, cut=[body])
    return body


@problem("2.2", 13031, features=("Extrude Boss", "Extrude Cut", "Sketch: Fillets", "Sketch: Offset"))
def p2_2():
    # Bottle opener 101 × 18: R9 end about the Ø9.5 hole at the origin, R4 /
    # R5 far corners; the notch is an R5 hook whose top edge falls 12° to
    # the right into a concave R5 (centre 22.5 right of the hook) and a
    # vertical tooth wall 9 in from the end, the hook joining the bottom
    # edge through a convex R2.5. Section A-A: a 1-wide, 1-tall rim on both
    # faces of a 9 core ("edge thickness is constant"). Not dimensioned and
    # read off the view: hook centre y = -1.85 (its top 3.15 above the
    # centreline), tooth wall at x = 83. Closed form 13080 (+0.4 %).
    import math
    s12, c12 = math.sin(math.radians(12)), math.cos(math.radians(12))
    H = (55.5, -1.85); xw = 83.0; C3x = xw - 5
    dy = H[1] + 6.5; dx = math.sqrt(7.5 ** 2 - dy * dy); C2 = (H[0] - dx, -6.5)
    T1 = (H[0] + 5 * s12, H[1] + 5 * c12)
    c3y = T1[1] + (-5 - (C3x - T1[0]) * s12) / c12; C3 = (C3x, c3y); T2 = (C3[0] + 5 * s12, C3[1] + 5 * c12)
    ang = lambda c, p: math.degrees(math.atan2(p[1] - c[1], p[0] - c[0])) % 360
    aHook = ang(H, C2)                       # hook/R2.5 tangency (~217°)
    aC2 = ang(C2, H)                         # R2.5's end on the hook side (~37°)

    def outline(sk, t):
        """Outline offset inward by t (t = 0 outer, 1 = rim inner edge)."""
        sk.arc((0, 0), 9 - t, 90, 270)
        sk.line((0, -9 + t), (C2[0], -9 + t))
        sk.arc(C2, 2.5 - t, -90, aC2)
        sk.arc(H, 5 + t, 78, aHook)
        sk.line((T1[0] + t * s12, T1[1] + t * c12), (T2[0] + t * s12, T2[1] + t * c12))
        sk.arc(C3, 5 + t, 0, 78)
        sk.line((xw + t, c3y), (xw + t, -9 + t))          # the tooth's wall offsets toward the tooth
        sk.line((xw + t, -9 + t), (87, -9 + t))
        sk.arc((87, -4), 5 - t, -90, 0)
        sk.line((92 - t, -4), (92 - t, 5))
        sk.arc((88, 5), 4 - t, 0, 90)
        sk.line((88, 9 - t), (0, 9 - t))
        return sk
    body = extrude(outline(Sketch(front(0)), 0).circle((0, 0), 4.75), (20, 0), 11)
    extrude(outline(Sketch(front(11)), 1), (20, 0), -1, cut=[body])
    extrude(outline(Sketch(front(0)), 1), (20, 0), 1, cut=[body])
    return body


@problem("2.3", 325633, features=("Extrude Boss", "Extrude Cut", "Sketch: Offset", "Sketch: Arcs"))
def p2_3():
    # Flange: Ø105/Ø81 boss 63 tall; two lugs Ø47.33/Ø23.33 (12 ring), 25
    # tall, 175 apart; a 12-thick base whose outline is the hull of the
    # three circles. Each side carries a pocket 3 deep (section: floor at
    # 9) bounded by the lug and boss circles offset 3 and the tangent lines
    # offset 3 ("thickness all around = 3"), its four corners R3 ("8X3").
    # Closed form 325 317 before the fillets (-0.10 %).
    import math
    rA, rB, d = 23.67, 52.5, 87.5                 # 23.67 = 11.67 + 12
    nx = -(rB - rA) / d; ny = math.sqrt(1 - nx * nx); tau = (ny, -nx)
    TB = (rB * nx, rB * ny); TA = (-d + rA * nx, rA * ny)
    aB = math.degrees(math.atan2(TB[1], TB[0]))                     # ~109°
    aA = math.degrees(math.atan2(TA[1], TA[0] + d))                 # ~109° on the lug
    sk = Sketch(top(0))
    sk.line(TA, TB).arc((0, 0), rB, 180 - aB, aB)
    sk.line((-TB[0], TB[1]), (-TA[0], TA[1])).arc((d, 0), rA, -(180 - aA), 180 - aA)
    sk.line((-TA[0], -TA[1]), (-TB[0], -TB[1])).arc((0, 0), rB, 180 + (180 - aB), 360 - (180 - aB))
    sk.line((TB[0], -TB[1]), (TA[0], -TA[1])).arc((-d, 0), rA, aA, 360 - aA)
    sk.circle((0, 0), 40.5).circle((-d, 0), 11.67).circle((d, 0), 11.67)
    body = extrude(sk, (-60, 0), 12)
    extrude(Sketch(top(12)).circle((0, 0), rB).circle((0, 0), 40.5), (46, 0), 51, union=[body])
    for x in (-d, d):
        extrude(Sketch(top(12)).circle((x, 0), rA).circle((x, 0), 11.67), (x + 17, 0), 13, union=[body])
    # left pocket, upper half: fillet centres on the line n·p = 46.5 (the
    # offset line 49.5 less 3), 58.5 from the boss centre / 29.67 from the lug
    h = rB - 6
    tB = -math.sqrt(58.5 ** 2 - h ** 2)
    FB = (h * nx + tB * tau[0], h * ny + tB * tau[1])
    k = h - nx * (-d)                                                # n·(F − cA)
    s = math.sqrt(29.67 ** 2 - k * k)                                # tau·(F − cA)
    tA = s + tau[0] * (-d)
    FA = (h * nx + tA * tau[0], h * ny + tA * tau[1])
    ang = lambda c, p: math.degrees(math.atan2(p[1] - c[1], p[0] - c[0]))
    PA_arc = (-d + 26.67 * (FA[0] + d) / 29.67, 26.67 * FA[1] / 29.67)   # on lug+3
    PA_lin = (FA[0] + 3 * nx, FA[1] + 3 * ny)
    PB_lin = (FB[0] + 3 * nx, FB[1] + 3 * ny)
    PB_arc = (55.5 * FB[0] / 58.5, 55.5 * FB[1] / 58.5)                  # on boss+3
    aBp = ang((0, 0), PB_arc); aAp = ang((-d, 0), PA_arc)

    def tarc(sk2, c, r, a0, a1, sx, sy):
        """Arc under the reflection (x, y) -> (sx·x, sy·y)."""
        lo, hi = sorted((a0, a1))
        if sx < 0:
            lo, hi = 180 - hi, 180 - lo
        if sy < 0:
            lo, hi = -hi, -lo
        sk2.arc((sx * c[0], sy * c[1]), r, lo, hi)

    for sx in (1, -1):
        pk = Sketch(top(12))
        for sy in (1, -1):
            M = lambda p: (sx * p[0], sy * p[1])
            pk.line(M(PA_lin), M(PB_lin))
            tarc(pk, FA, 3, ang(FA, PA_arc), ang(FA, PA_lin), sx, sy)
            tarc(pk, FB, 3, ang(FB, PB_lin), ang(FB, PB_arc), sx, sy)
        tarc(pk, (0, 0), 55.5, aBp, 360 - aBp, sx, 1)
        tarc(pk, (-d, 0), 26.67, -aAp, aAp, sx, 1)
        extrude(pk, (sx * -58, 0), -3, cut=[body])
    return body


@problem("2.5", 62810, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot"))
def p2_5():
    # Angle bracket, 7 thick throughout. Base 78 × 41 (z 0..−41) with Ø10
    # holes at x = 20 / 58, 12 back from the front edge; a vertical plate
    # at z −34..−41 whose top falls 25° from 69.4 (x = 0) to 33 (x = 78);
    # a 7-thick gusset at x 0..7 (YZ triangle: 34 along the base, 25 up the
    # plate); the keyhole plate, 7 thick, lying flush on the slope and
    # extending 38 behind the vertical plate (45 from its front face),
    # 67 long along the slope, centred (read off Detail B and the right
    # view; not called out). Keyhole: Ø18 20 from the plate's far edge and
    # 20 from its right end, an 8-wide slot 30 long to an R4 end.
    import math
    from kit import plane_at
    t25 = math.tan(math.radians(25)); c25, s25 = math.cos(math.radians(25)), math.sin(math.radians(25))
    ytop = 33 + 78 * t25
    base = extrude(Sketch(top(0)).rect(0, 0, 78, 41).circle((20, 12), 5).circle((58, 12), 5), (39, 30), 7)
    wall = Sketch(front(-41)).poly([(0, 7), (78, 7), (78, 33), (0, ytop)])
    extrude(wall, (39, 20), 7, union=[base])
    gusset = Sketch(right(0)).poly([(0, 7), (34, 7), (34, 32)])       # (u = -z, v = y)
    extrude(gusset, (30, 10), 7, union=[base])
    # keyhole plate: sketch on the slope plane; u along the slope (down to
    # the right), v = -z; the plate occupies z -41..-79 -> v 41..79
    L = 67.0; Ls = 78 / c25; u0 = (Ls - L) / 2
    pl = plane_at((0, ytop, 0), (c25, -s25, 0), (0, 0, -1))         # normal (s25, c25, 0): outward from the slope
    kp = Sketch(pl).rect(u0, 41, u0 + L, 79)
    extrude(kp, (u0 + 5, 60), -7, union=[base])                     # 7 thick below the slope surface
    cu, cv = u0 + L - 20, 79 - 20
    hole = (Sketch(pl).arc((cu, cv), 9, -90 + 0.0, 90).line((cu, cv + 9), (cu, cv + 9)))
    kh = Sketch(pl)
    # Ø18 round + 8-wide slot 30 long to an R4 end, as one closed loop
    a = math.degrees(math.asin(4 / 9))
    kh.arc((cu, cv), 9, -180 + a, 180 - a)
    kh.line((cu - 9 * math.cos(math.radians(a)), cv + 4), (cu - 30, cv + 4))
    kh.arc((cu - 30, cv), 4, 90, 270)
    kh.line((cu - 30, cv - 4), (cu - 9 * math.cos(math.radians(a)), cv - 4))
    extrude(kh, (cu, cv), -8, cut=[base])
    return base


@problem("2.10", 36748, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs", "Sketch: Fillets", "Fillet"))
def p2_10():
    # Sector bracket 7 thick. Hub R18 about a Ø21 hole at the origin; rim
    # R51..R64; two 13-wide spokes — one with its left edge on the line 30°
    # from vertical (60° from +x), one with its upper edge on the line 15°
    # below −x — whose outer edges also end the rim; an 18-wide arm along
    # +x to a Ø32/Ø16 boss 85 out. R6 TYP (Detail A) at every concave
    # corner, done as body fillets on the vertical edges.
    import math
    from kit import fillet, edges_where
    u = (math.cos(math.radians(60)), math.sin(math.radians(60)))
    pu = (math.sin(math.radians(60)), -math.cos(math.radians(60)))           # 13 to the right of the 60° line
    w = (-math.cos(math.radians(15)), -math.sin(math.radians(15)))
    pw = (math.sin(math.radians(15)), -math.cos(math.radians(15)))            # 13 below the 15° line
    body = extrude(Sketch(top(0)).circle((0, 0), 18), (0, 0), 7)
    extrude(Sketch(top(0)).circle((85, 0), 16), (85, 0), 7, union=[body])
    extrude(Sketch(top(0)).rect(0, -9, 85, 9), (40, 0), 7, union=[body])

    def hit(p, d, r):
        t = math.sqrt(r * r - 13 * 13)
        return (13 * p[0] + t * d[0], 13 * p[1] + t * d[1])
    # spokes from the hub centre out to the rim's outer circle (the chord
    # between 64·d and the outer edge's hit is inside the rim)
    for d, p in ((u, pu), (w, pw)):
        pts = [(0, 0), (64 * d[0], 64 * d[1]), hit(p, d, 64), (13 * p[0], 13 * p[1])]
        extrude(Sketch(top(0)).poly(pts), (35 * d[0] + 6 * p[0], 35 * d[1] + 6 * p[1]), 7, union=[body])
    A1, A2 = hit(pu, u, 51), hit(pu, u, 64)
    B1, B2 = hit(pw, w, 51), hit(pw, w, 64)
    ang = lambda q: math.degrees(math.atan2(q[1], q[0])) % 360
    rim = (Sketch(top(0)).line(A1, A2).arc((0, 0), 64, ang(A2), ang(B2)).line(B2, B1)
           .arc((0, 0), 51, ang(A1), ang(B1)))
    extrude(rim, (57.5 * math.cos(math.radians(120)), 57.5 * math.sin(math.radians(120))), 7, union=[body])
    extrude(Sketch(top(7)).circle((0, 0), 10.5), (0, 0), -7, cut=[body])
    extrude(Sketch(top(7)).circle((85, 0), 8), (85, 0), -7, cut=[body])
    # concave vertical edges: spoke-left/hub, spoke-right/arm-top, spoke-left/
    # rim, lower spoke/hub (both edges), lower spoke/rim, arm-bottom/hub,
    # arm/boss (both)
    xi = 13 * pu[0] + (9 + 6.5) / u[1] * u[0]
    corners = [(18 * u[0], 18 * u[1]), (xi, 9), (51 * u[0], 51 * u[1]),
               (18 * w[0], 18 * w[1]), hit(pw, w, 18), (51 * w[0], 51 * w[1]),
               (math.sqrt(18 ** 2 - 81), -9),
               (85 - math.sqrt(16 ** 2 - 81), 9), (85 - math.sqrt(16 ** 2 - 81), -9)]
    ids = []
    for c in corners:
        ids += edges_where(body, lambda e, c=c: abs(e["lengthMM"] - 7) < 0.5
                           and abs(e["midpoint"][0] - c[0]) < 0.6 and abs(-e["midpoint"][2] - c[1]) < 0.6)
    fillet(body, 6.0, sorted(set(ids)))
    return body


@problem("2.6", 109681, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot", "Sketch: Arcs", "Sketch: Fillets"))
def p2_6():
    # Keyhole plate 8 thick. Outline from the origin: bottom edge 142; left
    # edge 150 long at 58°; right edge 150 long at 72° (108° interior);
    # top edge joining the two, R32 at the top-right corner. Bottom notch:
    # the upper half of an R9 slot from x = 47 to 99, 9 tall. Keyhole on the
    # construction line from P1 (71 up the left edge) to P2 (82 up the
    # right edge): Ø34 centre 41 to the right of P1, a 14-wide slot 55 long
    # to an R7 end, R8 blends where the circle meets the slot sides. The
    # notch's R9 corners are read (not called out). Closed form 110 083.
    import math
    c58, s58 = math.cos(math.radians(58)), math.sin(math.radians(58))
    c72, s72 = math.cos(math.radians(72)), math.sin(math.radians(72))
    T = (150 * c58, 150 * s58); V = (142 + 150 * c72, 150 * s72)
    body = extrude(Sketch(front(0)).rounded_poly([(0, 0), (142, 0), V, T], [0, 0, 32, 0]), (70, 40), 8)
    extrude(Sketch(front(8)).slot((56, 0), (90, 0), 9), (73, 3), -8, cut=[body])
    P1 = (71 * c58, 71 * s58); P2 = (142 + 82 * c72, 82 * s72)
    ax = (P2[0] - P1[0], P2[1] - P1[1]); L = math.hypot(*ax); ax = (ax[0] / L, ax[1] / L)
    n = (-ax[1], ax[0])
    t = 41 / ax[0]
    C = (P1[0] + ax[0] * t, P1[1] + ax[1] * t)
    E = (C[0] + 55 * ax[0], C[1] + 55 * ax[1])
    P = lambda a, b: (C[0] + a * ax[0] + b * n[0], C[1] + a * ax[1] + b * n[1])   # (along, across)
    ang = lambda c, p: math.degrees(math.atan2(p[1] - c[1], p[0] - c[0]))
    base = math.degrees(math.atan2(ax[1], ax[0]))
    sk = Sketch(front(8))
    # R8 blends: centres 20 along, ±15 across (25 from C, 8 from the sides)
    G = {+1: P(20, 15), -1: P(20, -15)}
    Tc = {s: (C[0] + 17 * (G[s][0] - C[0]) / 25, C[1] + 17 * (G[s][1] - C[1]) / 25) for s in (1, -1)}
    Tl = {s: P(20, s * 7) for s in (1, -1)}
    # main circle arc from Tc[+1] CCW round the back to Tc[-1]
    sk.arc(C, 17, ang(C, Tc[1]), ang(C, Tc[-1]) + 360)
    for s in (1, -1):
        a0, a1 = ang(G[s], Tc[s]), ang(G[s], Tl[s])
        lo, hi = sorted((a0, a1))
        if hi - lo > 180:
            lo, hi = hi, lo + 360
        sk.arc(G[s], 8, lo, hi)
    sk.line(Tl[1], P(55, 7)).line(P(55, -7), Tl[-1])
    sk.arc(E, 7, base - 90, base + 90)
    extrude(sk, C, -8, cut=[body])
    return body


@problem("2.20", 50984, features=("Extrude Boss", "Extrude Cut", "Sketch: Polygon"))
def p2_20():
    # Hexagonal ring 100 across flats (flats top and bottom in the plan),
    # wall 10 TYP, 10 tall; three lugs centred on alternate edges: 10 thick
    # (the wall), 30 wide along the edge, a Ø12 hole 35 above the ring's
    # bottom under an R15 full-round top (Ø30 TYP). Plain reading: 31 177
    # (ring) + 3 × 9 903 (lugs) = 60 886 — the printed 50 984 is not
    # reproduced by any consistent reading (see notes).
    import math
    from kit import plane_at
    ring = Sketch(top(0)).polygon_flats((0, 0), 100, 6, 0).polygon_flats((0, 0), 80, 6, 0)
    body = extrude(ring, (0, 45), 10)
    # rotation 0: vertices at 0°, 60°, …; the flats are centred at 30°, 90°, …
    for k in range(3):
        a = math.radians(30 + 120 * k)                 # edge midpoints at 30°, 150°, 270°
        # lug plane: contains the edge direction and +Y, offset so the lug
        # spans the wall (apothem 40..50); sketch u along the edge, v = y
        ex, ez = -math.sin(a), math.cos(a)             # edge direction in the XZ plane (plan v = -z)
        ox, oz = 45 * math.cos(a), -45 * math.sin(a)   # wall centreline point (plan coords -> world z = -v)
        # world: plan (x, v) -> (x, y, -v); the edge midpoint at plan (45cos a, 45 sin a)
        origin = (45 * math.cos(a), 0, -45 * math.sin(a))
        xa = (-math.sin(a), 0, -math.cos(a))            # along the edge in world (plan (−sin a, cos a) -> z = -cos a)
        ya = (0, 1, 0)
        pl = plane_at(origin, xa, ya)                  # normal = xa × ya
        nrm = (xa[1] * ya[2] - xa[2] * ya[1], xa[2] * ya[0] - xa[0] * ya[2], xa[0] * ya[1] - xa[1] * ya[0])
        # shift the plane 5 outward along its normal direction (radial) so a
        # +10 extrude covers the wall from apothem 40 to 50
        rad = (math.cos(a), 0, -math.sin(a))
        s = 1 if (nrm[0] * rad[0] + nrm[2] * rad[2]) > 0 else -1
        o2 = (origin[0] - s * 5 * nrm[0], 0, origin[2] - s * 5 * nrm[2])
        pl = plane_at(o2, xa, ya)
        lug = (Sketch(pl).line((-15, 10), (15, 10)).line((15, 10), (15, 35)).arc((0, 35), 15, 0, 180)
               .line((-15, 35), (-15, 10)).circle((0, 35), 6))
        extrude(lug, (0, 22), s * 10, union=[body])
    return body


@problem("2.16", 59708, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot", "Sketch: Arcs", "Sketch: Fillets"))
def p2_16():
    # Slotted bracket. Plate 10 thick: a 45-wide base (R5 bottom corners)
    # rising to two R18 circles at (±32.5, 45) joined by concave R5 blends,
    # an R60 arc over the top tangent to both circles (centre (0, 18.4)).
    # Bosses: rings Ø36/Ø25, 10 long, behind the plate at the circle
    # centres (the front view shows no through-bore; bore read as Ø25).
    # Slot 12 wide, centred, lower end at the origin 17 above the bottom
    # edge, upper end on the circles' centreline (length read: 28).
    import math
    from kit import fillet, edges_where
    cy = 45 - math.sqrt(42 ** 2 - 32.5 ** 2)                     # R60 centre height
    d = 42.0
    tp = lambda sx: (sx * 60 * 32.5 / d, cy + 60 * (45 - cy) / d)   # tangency on the R60
    aT = math.degrees(math.atan2(45 - cy, 32.5))                 # ~39.6°
    # concave R5 between the circle (R18 about (±32.5,45)) and the side x = ±22.5:
    # centre at x = ±(22.5 + 5) = ±27.5, 23 from the circle centre
    fy = 45 - math.sqrt(23 ** 2 - 5 ** 2)
    F = lambda sx: (sx * 27.5, fy)
    tcirc = lambda sx: (sx * (32.5 + 18 * (27.5 - 32.5) / 23), 45 + 18 * (fy - 45) / 23)
    ang = lambda c, p: math.degrees(math.atan2(p[1] - c[1], p[0] - c[0]))
    sk = Sketch(front(-17))
    # bottom edge with R5 corners (base at y from 0)
    sk.line((-17.5, 0), (17.5, 0)).arc((17.5, 5), 5, -90, 0).line((22.5, 5), (22.5, fy))
    # right concave blend from (22.5, fy) to the circle
    a0, a1 = ang(F(1), (22.5, fy)), ang(F(1), tcirc(1))
    sk.arc(F(1), 5, min(a0, a1), max(a0, a1) if max(a0, a1) - min(a0, a1) < 180 else min(a0, a1) + 360)
    # right circle from the blend tangency round the outside up to the R60 tangency
    sk.arc((32.5, 45), 18, ang((32.5, 45), tcirc(1)), aT)
    sk.arc((0, cy), 60, aT, 180 - aT)
    sk.arc((-32.5, 45), 18, 180 - aT, 180 - ang((32.5, 45), tcirc(1)))
    b0, b1 = 180 - a1, 180 - a0
    sk.arc(F(-1), 5, min(b0, b1), max(b0, b1) if max(b0, b1) - min(b0, b1) < 180 else min(b0, b1) + 360)
    sk.line((-22.5, fy), (-22.5, 5)).arc((-17.5, 5), 5, 180, 270)
    sk.slot((0, 17), (0, 45), 6)
    body = extrude(sk, (0, 8), 10)
    for x in (-32.5, 32.5):
        extrude(Sketch(front(-17)).circle((x, 45), 18).circle((x, 45), 12.5), (x + 15, 45), -10, union=[body])
    return body


@problem("2.12", 26501, features=("Extrude Boss", "Extrude Cut", "Sketch: Offset", "Sketch: Arcs", "Sketch: Fillets"))
def p2_12():
    # Offset-cutout plate 5 thick. Outline: R23 bottom arc about the origin,
    # 45° sides tangent to it, an R60 arc over the top centred on the axis
    # 37 up (tangent to the R23 at the bottom point; read from the view).
    # Cutout: the outline offset 11 inward (R49 top, R12 bottom, parallel
    # sides) less R15 lobes about the Ø21 holes at (±32.5, 40), the lobes
    # blended into the walls with R18 (the labelled R18 at the top applied
    # to all four; the lower ones are not called out). The "R TYP" corner
    # rounds where the sides meet the R60 are near-tangent (area-neutral)
    # and omitted.
    import math
    c, rf = 37.0, 18.0
    k = 23 * math.sqrt(2)
    # side line y = x - k meets the R60: x^2 + (x - k - c)^2 = 3600
    b = -(k + c); q = (k + c) ** 2 - 3600
    xc = (-2 * b + math.sqrt(4 * b * b - 8 * q)) / 4
    yc = xc - k
    ang = lambda cc, p: math.degrees(math.atan2(p[1] - cc[1], p[0] - cc[0]))
    tb = (23 / math.sqrt(2), -23 / math.sqrt(2))
    sk = Sketch(front(0))
    sk.line((xc, yc), tb).arc((0, 0), 23, -135, -45).line((-tb[0], tb[1]), (-xc, yc))
    sk.arc((0, c), 60, ang((0, c), (xc, yc)), 180 - ang((0, c), (xc, yc)))
    sk.circle((32.5, 40), 10.5).circle((-32.5, 40), 10.5)
    body = extrude(sk, (0, 10), 5)
    # cutout
    H = (32.5, 40.0)
    def circ_int(c1, r1, c2, r2):
        dd = math.dist(c1, c2); a = (r1 * r1 - r2 * r2 + dd * dd) / (2 * dd); h = math.sqrt(max(r1 * r1 - a * a, 0))
        mx = c1[0] + a * (c2[0] - c1[0]) / dd; my = c1[1] + a * (c2[1] - c1[1]) / dd
        return [(mx + h * (c2[1] - c1[1]) / dd, my - h * (c2[0] - c1[0]) / dd),
                (mx - h * (c2[1] - c1[1]) / dd, my + h * (c2[0] - c1[0]) / dd)]
    G1 = max(circ_int((0, c), 49 - rf, H, 15 + rf), key=lambda p: p[0] + p[1])
    off = 11 * math.sqrt(2) - k                                     # inner right line: x - y = -off … i.e. y = x + off
    # G2 on the line parallel to the inner side, rf toward the cutout: y = x + off + rf*sqrt2, and |G2 - H| = 15 + rf
    o2 = off + rf * math.sqrt(2)
    A = 2; B = 2 * (o2 - H[1]) - 2 * H[0]; Cq = H[0] ** 2 + (o2 - H[1]) ** 2 - (15 + rf) ** 2
    disc = math.sqrt(B * B - 4 * A * Cq); x2 = (-B - disc) / (2 * A); G2 = (x2, x2 + o2)
    T1 = (49 * G1[0] / (49 - rf), c + 49 * (G1[1] - c) / (49 - rf))           # on the R49
    T2 = (H[0] + 15 * (G1[0] - H[0]) / (15 + rf), H[1] + 15 * (G1[1] - H[1]) / (15 + rf))
    T3 = (H[0] + 15 * (G2[0] - H[0]) / (15 + rf), H[1] + 15 * (G2[1] - H[1]) / (15 + rf))
    nn = (1 / math.sqrt(2), -1 / math.sqrt(2))
    T4 = (G2[0] + rf * nn[0], G2[1] + rf * nn[1])                                # on the inner side line
    tb2 = (12 / math.sqrt(2), -12 / math.sqrt(2))

    def tarc(s2, cc, r, a0, a1, sx):
        lo, hi = sorted((a0, a1))
        if hi - lo > 180:
            lo, hi = hi, lo + 360
        if sx < 0:
            lo, hi = 180 - hi, 180 - lo
        s2.arc((sx * cc[0], cc[1]), r, lo, hi)
    ck = Sketch(front(5))
    ck.arc((0, c), 49, ang((0, c), T1), 180 - ang((0, c), T1))
    ck.arc((0, 0), 12, -135, -45)
    for sx in (1, -1):
        M = lambda p: (sx * p[0], p[1])
        tarc(ck, G1, rf, ang(G1, T1), ang(G1, T2), sx)
        tarc(ck, H, 15, ang(H, T2), ang(H, T3), sx)      # the lobe's outer side (short way round)
        tarc(ck, G2, rf, ang(G2, T3), ang(G2, T4), sx)
        ck.line(M(T4), M(tb2))
    extrude(ck, (0, 30), -5, cut=[body])
    return body


@problem("2.19", 463671, features=("Extrude Boss", "Sketch: Arcs", "Sketch: Offset"))
def p2_19():
    # Arched tunnel on a hollow base, 90 deep (z ±45), 10 wall throughout.
    # Outer: 135 × 45 base, 90-wide legs from y = 45 to the R45 arch whose
    # centre is 100 up (the 100 runs to the centre line; crown at 145).
    # Inner: the outer offset 10 (115 × 25 cavity, 70-wide tunnel, R35).
    # A solid boss on the right leg's outer face: 35 wide × 20 tall
    # rectangle from y = 45 topped by an R17.5 semicircle (centre 65 up),
    # from x = 45 out to the base's end at 67.5, centred in depth.
    sk = Sketch(front(0))
    sk.poly([(-67.5, 0), (67.5, 0), (67.5, 45), (45, 45), (45, 100)], close=False)
    sk.arc((0, 100), 45, 0, 180).line((-45, 100), (-45, 45)).line((-45, 45), (-67.5, 45)).line((-67.5, 45), (-67.5, 0))
    sk.poly([(-57.5, 10), (57.5, 10), (57.5, 35), (35, 35), (35, 100)], close=False)
    sk.arc((0, 100), 35, 0, 180).line((-35, 100), (-35, 35)).line((-35, 35), (-57.5, 35)).line((-57.5, 35), (-57.5, 10))
    body = extrude(sk, (0, 5), 45, symmetric=True)      # 45 each side
    boss = (Sketch(right(45)).line((-17.5, 45), (17.5, 45)).line((17.5, 45), (17.5, 65))
            .arc((0, 65), 17.5, 0, 180).line((-17.5, 65), (-17.5, 45)))
    extrude(boss, (0, 60), 22.5, union=[body])
    return body
