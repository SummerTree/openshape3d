"""Level 1 — Basic Sketch & Extrusion (20 problems, Extrude Boss only).

Each recipe reads its dimensions off the sheet; the expected volume is the
number printed on it. Coordinates follow the sheet's origin where it
matters for later features, otherwise the profile's own corner.
"""
from kit import Sketch, front, top, bottom, right, left, extrude

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("1.1", 72593)
def p1_1():
    # Front view: 60 wide base 30 tall with a Ø12 hole at (44, 16); a stepped
    # tower 20/12/16 wide to 75/50/38 high; base 28 deep, tower 20 deep at
    # the back (top view: 20 | 12 | 12 across, 20 of 28 deep).
    base = extrude(Sketch(front(0)).rect(0, 0, 60, 30).circle((44, 16), 6), (10, 10), 28)
    tower = Sketch(front(8)).poly([(0, 30), (48, 30), (48, 38), (32, 38), (32, 50),
                                   (20, 50), (20, 75), (0, 75)])
    return extrude(tower, (10, 50), 20, union=[base])


@problem("1.3", 16268)
def p1_3():
    # Lever: hub Ø32 / Ø20 bore, 14 tall; arm 6 thick as the hull of R16
    # (hub) and R9 (small end 38 away) with a Ø6 hole; a Ø18 pin 24 long
    # hanging below the small end, the Ø6 hole through it.
    hub = extrude(Sketch(top(0)).circle((0, 0), 16).circle((0, 0), 10), (13, 0), 14)
    arm = Sketch(top(0)).hull2((0, 0), 16, (38, 0), 9).circle((0, 0), 10).circle((38, 0), 3)
    extrude(arm, (20, 0), 6, union=[hub])
    pin = Sketch(top(-24)).circle((38, 0), 9).circle((38, 0), 3)
    return extrude(pin, (44, 0), 24, union=[hub])


@problem("1.4", 0.146, unit="in", features=("Extrude Boss", "Sketch: Polygon"))
def p1_4():
    # IPS. An elliptical plate 1.6 × 0.5 × 0.15 with two Ø0.125 holes 0.175
    # in from the tips, a Ø0.45 × 0.45 boss underneath carrying a blind
    # hexagonal socket (0.25 across flats, 0.30 deep from the bottom, which
    # is the only size that returns the sheet's 0.146 in³).
    s = 25.4
    plate = extrude(Sketch(top(0)).ellipse((0, 0), 0.8 * s, 0.25 * s)
                    .circle((-0.625 * s, 0), 0.0625 * s).circle((0.625 * s, 0), 0.0625 * s),
                    (0.3 * s, 0), 0.15 * s)
    boss = Sketch(top(-0.45 * s)).circle((0, 0), 0.225 * s).polygon_flats((0, 0), 0.25 * s, 6)
    extrude(boss, (0.2 * s, 0), 0.45 * s, union=[plate])
    # the socket floor: fill the hex back in from 0.30 up to 0.45 deep
    cap = Sketch(top(-0.15 * s)).polygon_flats((0, 0), 0.25 * s, 6)
    return extrude(cap, (0, 0), 0.15 * s, union=[plate])


@problem("1.5", 0.5492, unit="in", features=("Extrude Boss", "Sketch: Polygon"))
def p1_5():
    # IPS wrench, 0.3 thick: Ø0.8 open-end head with a 0.5-wide jaw (flats
    # 0.25 long from the rim, then a V to the centre), a 0.4-wide handle to
    # a R0.4 ring 3.25 away holding a 0.5 across-flats hexagon.
    s = 25.4
    head = extrude(Sketch(top(0)).circle((0, 0), 0.4 * s), (0.2 * s, 0), 0.3 * s)
    jaw = Sketch(top(0)).poly([(-0.6 * s, 0.25 * s), (-0.15 * s, 0.25 * s), (0, 0),
                               (-0.15 * s, -0.25 * s), (-0.6 * s, -0.25 * s)])
    extrude(jaw, (-0.3 * s, 0), 0.3 * s, cut=[head])
    extrude(Sketch(top(0)).rect(0, -0.2 * s, 3.25 * s, 0.2 * s), (1.5 * s, 0), 0.3 * s, union=[head])
    ring = Sketch(top(0)).circle((3.25 * s, 0), 0.4 * s).polygon_flats((3.25 * s, 0), 0.5 * s, 6)
    return extrude(ring, (3.25 * s + 0.35 * s, 0), 0.3 * s, union=[head])


@problem("1.6", 24032)
def p1_6():
    # Bracket: 60 × 30 × 5 plate (R8 corners, two Ø8 holes 40 apart) with a
    # lug hanging below: a 9-wide full-length blade whose side profile is
    # a 15° slope from the plate's bottom corner tangent to a Ø25 boss 40
    # from the plate's top face, a flat underside flush with the plate's
    # edge, and a Ø8 hole; plus an 18-wide slab over the same profile that
    # stops at a concave R14 around the boss (1.5 mm clearance).
    import math
    t = math.tan(math.radians(15))
    cy, r = -35.0, 12.5
    cz = 15 + t * cy - r * math.sqrt(1 + t * t)          # slope tangent to the boss
    plate = extrude(Sketch(top(0)).rect(-30, -15, 30, 15)
                    .circle((-20, 0), 4).circle((20, 0), 4), (0, 10), 5)
    # R8 corners: the four vertical edges of the plate
    from kit import fillet, edges_where
    fillet(plate, 8.0, edges_where(plate, lambda e: abs(e["lengthMM"] - 5) < 0.5
                                   and abs(abs(e["midpoint"][0]) - 30) < 0.5))
    # side profiles in (u = -z, v = y) on the right plane at x = -w/2
    def profile(width, pocket_r):
        sk = Sketch(right(-width / 2))
        A = (-15, 0)                                         # plate bottom corner (z=15, y=0)
        if pocket_r is None:
            n = (-math.sin(math.radians(15)), math.cos(math.radians(15)))  # up-left normal in (y,z)
            T = (cy + r * n[0], cz + r * n[1])               # tangent point (y, z)
            yb = cy + math.sqrt(r * r - (-15 - cz) ** 2)     # boss meets z=-15, plate side
            aT = math.degrees(math.atan2(T[1] - cz, T[0] - cy))
            aB = math.degrees(math.atan2(-15 - cz, yb - cy)) + 360
            sk.line(A, (-T[1], T[0]))
            # (y, z) → sketch (u, v) = (-z, y) is a +90° rotation, so an angle
            # θ in the y–z frame is θ + 90° on the sketch and CCW stays CCW.
            sk.arc((-cz, cy), r, aT + 90, aB + 90)
            sk.line((15, yb), (15, 0))
            sk.line((15, 0), A)
            sk.circle((-cz, cy), 4)
        else:
            R = pocket_r
            a, b, c = 1 + t * t, 2 * (-cy) + 2 * t * (15 - cz), cy * cy + (15 - cz) ** 2 - R * R
            # (y - cy)^2 + (15 + t y - cz)^2 = R^2  →  y^2(1+t^2) + y(-2cy + 2t(15-cz)) + cy^2 + (15-cz)^2 - R^2 = 0
            disc = math.sqrt(b * b - 4 * a * c)
            y1 = (-b + disc) / (2 * a)                       # plate-side intersection
            z1 = 15 + t * y1
            yb = cy + math.sqrt(R * R - (-15 - cz) ** 2)
            a1 = math.degrees(math.atan2(z1 - cz, y1 - cy))
            aB = math.degrees(math.atan2(-15 - cz, yb - cy))
            sk.line(A, (-z1, y1))
            sk.arc((-cz, cy), R, aB + 90, a1 + 90)
            sk.line((15, yb), (15, 0))
            sk.line((15, 0), A)
        return sk
    extrude(profile(9, None), (0, -20), 9, union=[plate])
    extrude(profile(18, 14.0), (0, -10), 18, union=[plate])
    return plate


@problem("1.12", 177233)
def p1_12():
    # Corner bracket: 125 × 75 × 10 base with a Ø20 hole at (62.5, 25), a
    # 125 × 55 × 10 wall along the back edge, and a 10-thick triangular
    # gusset at one end spanning the wall's top and the base's front edge.
    base = extrude(Sketch(top(0)).rect(0, 0, 125, 75).circle((62.5, 25), 10), (10, 60), 10)
    extrude(Sketch(top(10)).rect(0, 65, 125, 75), (60, 70), 55, union=[base])
    # gusset on the plane x = 0 … 10: profile in (u = -z, v = y)
    g = Sketch(right(0)).poly([(0, 10), (-65, 10), (-65, 65)])
    return extrude(g, (-50, 15), 10, union=[base])


@problem("1.14", 581662)
def p1_14():
    # 300 × 175 × 10 plate, R20 corners with Ø20 holes concentric to them;
    # a 10-thick blade 120 wide standing across the middle, 75 tall from
    # the plate's underside (R10 top corners) with a Ø25 hole 55 up.
    from kit import fillet, edges_where
    plate = extrude(Sketch(top(0)).rect(-150, -87.5, 150, 87.5)
                    .circle((-130, -67.5), 10).circle((130, -67.5), 10)
                    .circle((-130, 67.5), 10).circle((130, 67.5), 10), (0, 0), 10)
    fillet(plate, 20.0, edges_where(plate, lambda e: abs(e["lengthMM"] - 10) < 0.5
                                    and abs(abs(e["midpoint"][0]) - 150) < 0.5))
    blade = Sketch(right(-5)).rect(-60, 10, 60, 75).circle((0, 55), 12.5)
    bid = extrude(blade, (-40, 20), 10, union=[plate])
    fillet(plate, 10.0, edges_where(plate, lambda e: abs(e["lengthMM"] - 10) < 0.5
                                    and abs(e["midpoint"][1] - 75) < 0.5
                                    and abs(abs(e["midpoint"][2]) - 60) < 0.5))
    return plate


@problem("1.16", 157066)
def p1_16():
    # 125 × 60 × 15 base; a 40-wide lug (x 30..70) on the front 40 of the
    # depth: rectangle up to the Ø20 hole centre 35 up, capped by R20.
    base = extrude(Sketch(top(0)).rect(0, 0, 125, 60), (60, 30), 15)
    lug = (Sketch(front(0)).line((30, 15), (70, 15)).line((70, 15), (70, 35))
           .arc((50, 35), 20, 0, 180).line((30, 35), (30, 15)).circle((50, 35), 10))
    return extrude(lug, (50, 25), 40, union=[base])


@problem("1.17", 38693)
def p1_17():
    # Bent bar 10 thick: a 24-wide arm from x=135 back to a bend, a 24-wide
    # leg at 50° down to an R12 end at the origin; Ø11 holes at the origin
    # and 35 in from the arm's end on its centreline.
    import math
    c, s = math.cos(math.radians(50)), math.sin(math.radians(50))
    n = (-s, c)                                          # leg's upper-edge normal
    up = (-12 * s, 12 * c); lo = (12 * s, -12 * c)
    t_up = (65 - up[1]) / s; x_up = up[0] + t_up * c     # upper edge meets y=65
    t_lo = (41 - lo[1]) / s; x_lo = lo[0] + t_lo * c     # lower edge meets y=41
    sk = (Sketch(front(0)).arc((0, 0), 12, 140, 320)
          .line(lo, (x_lo, 41)).line((x_lo, 41), (135, 41)).line((135, 41), (135, 65))
          .line((135, 65), (x_up, 65)).line((x_up, 65), up)
          .circle((0, 0), 5.5).circle((100, 53), 5.5))
    return extrude(sk, (100, 45), 10)


@problem("1.19", 26719)
def p1_19():
    # L-bracket: 75 × 40 × 5 base with a 15 × 15 corner chamfer and two Ø8
    # holes 15 in from the front edge (x = 20, 55); a 5-thick wall along the
    # back edge 35 tall with its free top corner rounded R25; a 5-thick
    # gusset at x = 0 … 5 running 21 out from the wall, 20 tall at the wall
    # and 12 at the tip, both above the base.
    base = extrude(Sketch(top(0)).poly([(0, 0), (60, 0), (75, 15), (75, 40), (0, 40)])
                   .circle((20, 15), 4).circle((55, 15), 4), (30, 30), 5)
    wall = (Sketch(front(-40)).line((0, 5), (75, 5)).line((75, 5), (75, 10))
            .arc((50, 10), 25, 0, 90).line((50, 35), (0, 35)).line((0, 35), (0, 5)))
    extrude(wall, (30, 20), 5, union=[base])       # z from -40 to -35 (the back strip)
    gusset = Sketch(right(0)).poly([(35, 5), (35, 25), (14, 17), (14, 5)])
    return extrude(gusset, (30, 8), 5, union=[base])


@problem("1.18", 295296)
def p1_18():
    # Two 155 × 32 × 20 rails 100 apart (outside), 20 × 32 × 10 blocks on
    # their far ends, and a 100 × 100 × 10 plate with a Ø45 hole bridging
    # them 8 in from the near end — the only reading that returns the
    # sheet's 295,296 exactly (the plate spans the full 100, not 84).
    rails = extrude(Sketch(top(0)).rect(0, -32, 155, 0), (80, -16), 20)
    extrude(Sketch(top(0)).rect(0, -100, 155, -68), (80, -84), 20, union=[rails])
    for v0 in (-32, -100):
        extrude(Sketch(top(20)).rect(135, v0, 155, v0 + 32), (145, v0 + 16), 10, union=[rails])
    plate = Sketch(top(20)).rect(8, -100, 108, 0).circle((58, -50), 22.5)
    return extrude(plate, (20, -20), 10, union=[rails])


@problem("1.20", 177882)
def p1_20():
    # Ø110 × 10 disc with a Ø32 hole; four identical 12 × 20 bars tangent
    # to the hole (inner faces 16 out), straight-ended at the chord their
    # outer face makes with the rim: two on top along z, two below along x.
    import math
    disc = extrude(Sketch(top(0)).circle((0, 0), 55).circle((0, 0), 16), (40, 0), 10)
    half = math.sqrt(55 ** 2 - 28 ** 2)
    for sgn in (1, -1):
        bar = Sketch(top(10)).rect(sgn * 16, -half, sgn * 28, half)
        extrude(bar, (sgn * 22, 0), 20, union=[disc])
        leg = Sketch(top(-20)).rect(-half, sgn * 16, half, sgn * 28)
        extrude(leg, (0, sgn * 22), 20, union=[disc])
    return disc


@problem("1.9", 944900)
def p1_9():
    # 175 × 100 plate, 55 thick, with 40 × 22 × 25 corner bosses on top and
    # 40 × 22 × 30 corner cutouts underneath (front view: 25 up, 30 down).
    plate = extrude(Sketch(top(0)).rect(0, 0, 175, 100), (80, 50), 55)
    corners = [(0, 0), (135, 0), (0, 78), (135, 78)]
    for (x, v) in corners:
        extrude(Sketch(top(55)).rect(x, v, x + 40, v + 22), (x + 20, v + 11), 25, union=[plate])
    for (x, v) in corners:
        extrude(Sketch(top(0)).rect(x, v, x + 40, v + 22), (x + 20, v + 11), 30, cut=[plate])
    return plate


@problem("1.11", 96716)
def p1_11():
    # 125 × 55 × 10 plate with two Ø15 holes 75 apart on the centreline, and
    # a 20-wide gusset on one face: 45 out, 15 tall at the tip, rising to
    # the plate's top edge (right view).
    plate = extrude(Sketch(front(0)).rect(-62.5, 0, 62.5, 55)
                    .circle((-37.5, 27.5), 7.5).circle((37.5, 27.5), 7.5), (0, 5), 10)
    gusset = Sketch(right(-10)).poly([(-10, 0), (-55, 0), (-55, 15), (-10, 55)])
    return extrude(gusset, (-30, 8), 20, union=[plate])


@problem("1.15", 45867)
def p1_15():
    # Front-view body 20 deep (z 0..20): 40 wide, 65 tall, a 10 × 14 foot at
    # the bottom-left, the left flank sloping 30° from vertical between
    # (10, 35) and the top; a 5-thick lug behind (z −5..0) from x = 10 to
    # the R7 end round the Ø7 hole at (55, 7); a 5-thick arm in front
    # (z 20..25) from the flank's top x = 27.32: top edge y = 65 to the R7
    # end round the Ø6 hole 45 out at y = 58, underside 65° from vertical.
    import math
    xs = 10 + 30 * math.tan(math.radians(30))
    body = extrude(Sketch(front(0)).poly([(0, 0), (40, 0), (40, 65), (xs, 65), (10, 35), (10, 14), (0, 14)]),
                   (30, 20), 20)
    lug = (Sketch(front(-5)).line((10, 0), (55, 0)).arc((55, 7), 7, -90, 90).line((55, 14), (10, 14))
           .line((10, 14), (10, 0)).circle((55, 7), 3.5))
    extrude(lug, (30, 7), 5, union=[body])
    cx, cy = xs + 45, 58
    a = math.radians(25)
    T = (cx + 7 * math.sin(a), cy - 7 * math.cos(a))
    yl = T[1] - math.tan(a) * (T[0] - xs)
    arm = (Sketch(front(20)).line((xs, yl), T).arc((cx, cy), 7, -65, 90).line((cx, 65), (xs, 65))
           .line((xs, 65), (xs, yl)).circle((cx, cy), 3))
    extrude(arm, (cx - 10, 60), 5, union=[body])
    return body


@problem("1.13", 9534)
def p1_13():
    # Symmetric two-arm wing plate 5 thick: Ø40 hub with a Ø23 hole; the
    # arms' R5 tip circles are centred on the Ø125 circle at 16° below the
    # horizontal, the lower edges parallel to those 16° radials (R25
    # blends into the hub) and the upper edges 4° steeper; each upper
    # edge blends through a concave R75 into the R3 apex round centred on
    # the hub circle at (0, 20).
    import math
    R, Rt, r3, R75, R25 = 62.5, 5.0, 3.0, 75.0, 25.0
    a16, a20 = math.radians(16), math.radians(20)
    C = (R * math.cos(a16), -R * math.sin(a16))
    d1 = (math.cos(a16), -math.sin(a16)); n1 = (-math.sin(a16), -math.cos(a16))
    d2 = (math.cos(a20), -math.sin(a20)); n2 = (math.sin(a20), math.cos(a20))
    LT = (C[0] + Rt * n1[0], C[1] + Rt * n1[1]); UT = (C[0] + Rt * n2[0], C[1] + Rt * n2[1])
    A = (0, 20)
    Q = (UT[0] + R75 * n2[0], UT[1] + R75 * n2[1]); w = (Q[0] - A[0], Q[1] - A[1])
    b = 2 * (w[0] * d2[0] + w[1] * d2[1]); c = w[0] ** 2 + w[1] ** 2 - (R75 + r3) ** 2
    t = (-b + math.sqrt(b * b - 4 * c)) / 2
    O75 = (Q[0] + t * d2[0], Q[1] + t * d2[1])
    TU = (O75[0] - R75 * n2[0], O75[1] - R75 * n2[1])
    T3 = (A[0] + r3 * (O75[0] - A[0]) / (R75 + r3), A[1] + r3 * (O75[1] - A[1]) / (R75 + r3))
    Q2 = (LT[0] + R25 * n1[0], LT[1] + R25 * n1[1]); b = 2 * (Q2[0] * d1[0] + Q2[1] * d1[1])
    c = Q2[0] ** 2 + Q2[1] ** 2 - (20 + R25) ** 2
    t = (-b + math.sqrt(b * b - 4 * c)) / 2
    O25 = (Q2[0] + t * d1[0], Q2[1] + t * d1[1])
    TL = (O25[0] - R25 * n1[0], O25[1] - R25 * n1[1]); TH = (O25[0] * 20 / 45, O25[1] * 20 / 45)
    ang = lambda cc, p: math.degrees(math.atan2(p[1] - cc[1], p[0] - cc[0]))
    sk = Sketch(front(0))
    half = [("arc", (0, 0), 20, -90, ang((0, 0), TH)),
            ("arc", O25, R25, ang(O25, TL), ang(O25, TH)),
            ("line", TL, LT),
            ("arc", C, Rt, ang(C, LT), ang(C, UT) + 360),
            ("line", UT, TU),
            ("arc", O75, R75, ang(O75, T3), ang(O75, TU)),
            ("arc", A, r3, ang(A, T3), 90)]
    for e in half:
        if e[0] == "line":
            sk.line(e[1], e[2]); sk.line((-e[2][0], e[2][1]), (-e[1][0], e[1][1]))
        else:
            _, cc, r, a0, a1 = e
            sk.arc(cc, r, a0, a1); sk.arc((-cc[0], cc[1]), r, 180 - a1, 180 - a0)
    sk.circle((0, 0), 11.5)
    return extrude(sk, (0, -16), 5)
