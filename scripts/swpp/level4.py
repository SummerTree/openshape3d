"""Level 4 — Extrude Cut & Fillet/Chamfer (70 problems)."""
import math
from kit import Sketch, front, top, bottom, right, left, back, plane_at, extrude, revolve, fillet, chamfer, edges_where, edges_near, edges_along, union, subtract, move, mirror, pattern

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss", "Extrude Cut")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("4.41", 107609, features=("Extrude Boss", "Sketch: Slot", "Extrude Cut", "Fillet and Chamfer"))
def p4_41():
    # Ø62 tube, 5 wall, 80 long (axis y) with two 12-thick mid-plane lugs:
    # 44-wide tabs to R22 ends 55 out, Ø20 holes; R2 on the lug edges.
    tube = extrude(Sketch(top(-40)).circle((0, 0), 31).circle((0, 0), 26), (28, 0), 80)
    for sgn in (1, -1):
        cx = sgn * 55
        lug = (Sketch(top(-6)).line((0, 22), (cx, 22)).line((cx, -22), (0, -22))
               .line((0, -22), (0, 22))
               .arc((cx, 0), 22, -90 if sgn > 0 else 90, 90 if sgn > 0 else 270)
               .circle((cx, 0), 10))
        extrude(lug, (sgn * 40, 15), 12, union=[tube])
    # keep the bore clear: cut it again through everything
    extrude(Sketch(top(-41)).circle((0, 0), 26), (0, 0), 82, cut=[tube])
    # R2 on the lugs' outline edges (top and bottom faces, outside the tube)
    ids = edges_where(tube, lambda e: abs(abs(e["midpoint"][1]) - 6) < 0.5
                      and math.hypot(e["midpoint"][0], e["midpoint"][2]) > 31.5
                      and e["lengthMM"] > 5)
    fillet(tube, 2.0, ids)
    return tube


@problem("4.28", 412728)
def p4_28():
    # L-block 150 long, 75 deep: a 25-thick top bar (y 50..75) and a 65-wide
    # leg (x 85..150) down to y = 0; Ø25 hole through the bar 35 in from
    # the left; a 40 × 50 × 50 notch out of the leg's far end.
    body = extrude(Sketch(front(0)).poly([(0, 50), (0, 75), (150, 75), (150, 0), (85, 0), (85, 50)]),
                   (100, 60), 75)
    extrude(Sketch(top(50)).circle((35, -37.5), 12.5), (35, -37.5), 25, cut=[body])
    extrude(Sketch(top(-1)).rect(110, -75, 150, -25), (130, -50), 51, cut=[body])
    return body


@problem("4.25", 17428, features=("Extrude Boss", "Extrude Cut", "Fillet and Chamfer"))
def p4_25():
    # Clevis pin: Ø11 shank 48 tall; a 26 × 16 head above it with an R9
    # round top about the Ø8 hole at y = 79, a Ø6 hole at (7, 64), the
    # sides running tangent from (±13, 64) up to the round; 1 × 45° chamfer
    # on the shank's end.
    P = (13.0, 64.0); C = (0.0, 79.0); R = 9.0
    d = math.hypot(P[0] - C[0], P[1] - C[1])
    base = math.atan2(C[1] - P[1], C[0] - P[0])
    off = math.asin(R / d)
    L = math.sqrt(d * d - R * R)
    ang = base - off                       # tangent touching the circle's right side
    T = (P[0] + L * math.cos(ang), P[1] + L * math.sin(ang))
    aT = math.degrees(math.atan2(T[1] - C[1], T[0] - C[0]))
    head = (Sketch(front(-8)).line((-13, 48), (13, 48)).line((13, 48), P).line(P, T)
            .arc(C, R, aT, 180 - aT).line((-T[0], T[1]), (-13, 64)).line((-13, 64), (-13, 48))
            .circle((0, 79), 4).circle((7, 64), 3))
    body = extrude(head, (0, 55), 16)
    extrude(Sketch(top(0)).circle((0, 0), 5.5), (0, 0), 48.5, union=[body])
    chamfer(body, 1.0, edges_where(body, lambda e: abs(e["midpoint"][1]) < 0.5 and abs(e["lengthMM"] - 2 * math.pi * 5.5) < 1))
    return body


@problem("4.38", 152280, features=("Extrude Boss", "Extrude Cut"))
def p4_38():
    # L-bracket 23 thick: 96-wide arm 52 tall at the top of a 28-wide,
    # 150-tall leg; R23 outer / R9 inner corners; Ø12 through the arm at
    # (23, 124) with a Ø30 × 12 counterbore from the front, a 20 × 16
    # rectangular cut off the arm's end overlapping it; Ø6 across the leg
    # 12 up from the bottom.
    prof = Sketch(front(0)).poly([(0, 98), (0, 150), (96, 150), (96, 0), (68, 0), (68, 98)])
    body = extrude(prof, (80, 100), 23)
    fillet(body, 23.0, edges_where(body, lambda e: abs(e["midpoint"][0] - 96) < 0.5 and abs(e["midpoint"][1] - 150) < 0.5))
    fillet(body, 9.0, edges_where(body, lambda e: abs(e["midpoint"][0] - 68) < 0.5 and abs(e["midpoint"][1] - 98) < 0.5))
    extrude(Sketch(front(-1)).circle((23, 124), 6), (23, 124), 25, cut=[body])
    extrude(Sketch(front(23)).circle((23, 124), 15), (23, 124), -12, cut=[body])
    extrude(Sketch(front(23)).rect(-1, 97, 20, 151), (10, 120), -16, cut=[body])
    extrude(Sketch(right(60)).circle((-11.5, 12), 3), (-11.5, 12), 40, cut=[body])
    return body


@problem("4.65", 90519)
def p4_65():
    # 90 × 40 × 35 block: a Ø25 half-round channel along the top (axis
    # along x on the top edge's centreline), a Ø25 half-round notch across
    # the bottom front-to-back, two Ø10 vertical holes 64 apart.
    # top plane v = -z: rect v ∈ [-40, 0] puts the block at z ∈ [0, 40]
    body = extrude(Sketch(top(0)).rect(0, -40, 90, 0), (45, -20), 35)
    extrude(Sketch(right(-1)).circle((-20, 35), 12.5), (-20, 35), 92, cut=[body])    # channel along x at z = 20
    extrude(Sketch(front(-1)).circle((45, 0), 12.5), (45, 0), 42, cut=[body])        # notch along z at the bottom
    for x in (13, 77):
        extrude(Sketch(top(-1)).circle((x, -20), 5), (x, -20), 37, cut=[body])
    return body


@problem("4.44", 90831, features=("Extrude Boss", "Sketch: Offset", "Sketch: Trim", "Sketch: Convert", "Extrude Cut", "Fillet and Chamfer"))
def p4_44():
    # Fork: an 11-thick stem 30 wide with an R15 round bottom about the
    # origin and Ø13 holes at y = 0 and 30, rising to a 64 × 35 × 48 head at
    # y = 64 (R10 at the junction); two 11-wide prongs 18 tall on the head
    # with a Ø24 half-round across their tops 22 in from the back.
    head = extrude(Sketch(front(0)).rect(-32, 64, 32, 99), (0, 80), 48)
    extrude(Sketch(front(-1)).rect(-21, 81, 21, 100), (0, 90), 50, cut=[head])
    extrude(Sketch(right(-33)).circle((-22, 99), 12), (-22, 99), 66, cut=[head])
    stem = (Sketch(front(0)).line((-15, 0), (-15, 64)).line((-15, 64), (15, 64)).line((15, 64), (15, 0))
            .arc((0, 0), 15, 180, 360).circle((0, 0), 6.5).circle((0, 30), 6.5))
    extrude(stem, (0, 45), 11, union=[head])
    fillet(head, 10.0, edges_where(head, lambda e: abs(abs(e["midpoint"][0]) - 15) < 0.5
                                   and abs(e["midpoint"][1] - 64) < 0.5 and abs(e["lengthMM"] - 11) < 0.5))
    return head


@problem("4.45", 27348, features=("Extrude Boss", "Sketch: Offset", "Extrude Cut", "Fillet and Chamfer"))
def p4_45():
    # Bent handle, 21 wide × 7 thick: an arm along x to an R20 eye (Ø18)
    # 85 from the leg's outer face, a 90° bend (R14 outside, R7 inside),
    # a leg down to a second R20 eye 55 below the arm's top face.
    xj = 85 - math.sqrt(400 - 10.5 ** 2)            # strip edges meet the eye's circle
    aj = math.degrees(math.atan2(10.5, xj - 85))    # ≈ 148.3°
    arm = (Sketch(top(-7)).line((14, 10.5), (xj, 10.5)).arc((85, 0), 20, -aj, aj)
           .line((xj, -10.5), (14, -10.5)).line((14, -10.5), (14, 10.5)).circle((85, 0), 9))
    body = extrude(arm, (40, 0), 7)
    bend = Sketch(front(-10.5)).arc((14, -14), 14, 90, 180).arc((14, -14), 7, 90, 180) \
        .line((0, -14), (7, -14)).line((14, -7), (14, 0))
    extrude(bend, (14 - 10.5 * math.cos(math.radians(45)), -14 + 10.5 * math.sin(math.radians(45))), 21, union=[body])
    vj = -55 + math.sqrt(400 - 10.5 ** 2)           # strip edges meet the lower eye
    bj = math.degrees(math.atan2(vj + 55, 10.5))    # ≈ 58.3°
    leg = (Sketch(right(0)).line((10.5, -14), (10.5, vj)).arc((0, -55), 20, 180 - bj, 360 + bj)
           .line((-10.5, vj), (-10.5, -14)).line((-10.5, -14), (10.5, -14)).circle((0, -55), 9))
    extrude(leg, (0, -30), 7, union=[body])
    return body


@problem("4.69", 11120, features=("Extrude Boss", "Sketch: Polygon", "Extrude Cut"))
def p4_69():
    # Hex prism 19 across flats (flats left/right), 40 tall at the left
    # edge, the top cut by a plane falling 25° to the right.
    hexp = extrude(Sketch(top(0)).polygon_flats((0, 0), 19, 6, rotation_deg=90), (0, 0), 40)
    t = math.tan(math.radians(25))
    cutter = Sketch(front(-20)).poly([(-20, 40 + 10.5 * t), (20, 40 - 29.5 * t), (20, 60), (-20, 60)])
    extrude(cutter, (0, 55), 40, cut=[hexp])
    return hexp


@problem("4.10", 65203)
def p4_10():
    # U-bracket 39 deep: inner R23 semicircle about the origin with vertical
    # inner walls at ±23 rising to y = 16; outer walls at ±32.5 from y = 16
    # down to −16.5, 45° to a 26-wide flat bottom at −36; 6-thick flanges
    # (y 10..16) out to ±55 with four Ø8 holes at (±40, ±9.5).
    sk = (Sketch(front(-19.5))
          .poly([(-55, 16), (-55, 10), (-32.5, 10), (-32.5, -16.5), (-13, -36), (13, -36),
                 (32.5, -16.5), (32.5, 10), (55, 10), (55, 16), (23, 16), (23, 0)], close=False)
          .arc((0, 0), 23, 180, 360)
          .line((-23, 0), (-23, 16)).line((-23, 16), (-55, 16)))
    body = extrude(sk, (-28, 0), 39)
    holes = Sketch(top(10))
    for x in (-40, 40):
        for v in (-9.5, 9.5):
            holes.circle((x, v), 4)
    for x in (-40, 40):
        for v in (-9.5, 9.5):
            extrude(Sketch(top(10)).circle((x, v), 4), (x, v), 6, cut=[body])
    return body


@problem("4.8", 258631, features=("Extrude Boss", "Extrude Cut"))
def p4_8():
    # Base 190 × 50 × 12 with 25 × 20 corner chamfers on the far edge and
    # 2 × Ø15 at 155 apart, 18 in from the near edge; two uprights 18 thick,
    # 55 apart, 50 deep, with R40 tops about Ø16 holes 58 above the base's
    # bottom (top at 98); an 8 rib between them 28 above the base, centred
    # on the base holes' line. 103 759 + 142 520 + 12 320 = 258 599.
    import math
    base = Sketch(top(0)).poly([(-95, -20), (-70, 0), (70, 0), (95, -20), (95, -50), (-95, -50)])
    base.circle((-77.5, -32), 7.5).circle((77.5, -32), 7.5)
    body = extrude(base, (0, -25), 12)
    ys = 58 + math.sqrt(40 ** 2 - 25 ** 2)          # where the R40 top meets the sides
    a0 = math.degrees(math.atan2(ys - 58, 25))
    for x0 in (27.5, -45.5):
        up = (Sketch(right(x0)).line((0, 6), (0, ys)).arc((-25, 58), 40, a0, 180 - a0)
              .line((-50, ys), (-50, 6)).line((-50, 6), (0, 6)).circle((-25, 58), 8))
        extrude(up, (-25, 30), 18, union=[body])
    extrude(Sketch(top(12)).rect(-27.5, -36, 27.5, -28), (0, -32), 28, union=[body])
    return body


@problem("4.15", 118919, features=("Extrude Boss", "Extrude Cut", "Fillet and Chamfer"))
def p4_15():
    # 65 × 41 × 80 block. Section shape S (floor 13 to x = 16, an R60 arc
    # centred on the left edge up to the 35° slope that starts at x = 44,
    # 5 × 45° chamfer top-left) runs the full 80; the full profile P (top
    # at 41, Ø10 at (12, 31)) stands as a 10 wall at the far end (z −40..−30)
    # and a 4 wall at z 30..34 behind a 6 front strip. A 22-wide channel 5
    # deep along the bottom and a 22 × 5 full-height slot in the right end.
    t = math.tan(math.radians(35))
    yR = 41 - 21 * t
    yc = 13 + math.sqrt(3600 - 256)                  # arc centre (0, yc)
    lo, hi = 44.0, 65.0
    for _ in range(80):
        m = (lo + hi) / 2
        if yc - math.sqrt(3600 - m * m) > 41 - (m - 44) * t:
            hi = m
        else:
            lo = m
    xi = lo; yi = 41 - (xi - 44) * t
    aI = math.degrees(math.atan2(yi - yc, xi)); a16 = math.degrees(math.atan2(13 - yc, 16))
    S = (Sketch(front(-40)).poly([(0, 0), (65, 0), (65, yR), (xi, yi)], close=False)
         .arc((0, yc), 60, a16, aI).line((16, 13), (0, 13)).line((0, 13), (0, 0)))
    body = extrude(S, (30, 5), 80)
    for z0, th in ((-40, 10), (30, 4)):
        P = Sketch(front(z0)).poly([(0, 0), (65, 0), (65, yR), (44, 41), (5, 41), (0, 36)])
        extrude(P, (20, 20), th, union=[body])
    extrude(Sketch(front(-41)).circle((12, 31), 5), (12, 31), 82, cut=[body])
    extrude(Sketch(right(-1)).rect(-11, -1, 11, 5), (0, 2), 67, cut=[body])
    extrude(Sketch(bottom(42)).rect(60, -11, 66, 11), (63, 0), 43, cut=[body])
    return body


@problem("4.16", 164805, features=("Extrude Boss", "Extrude Cut", "Fillet and Chamfer"))
def p4_16():
    # Lever: R21 eye (Ø18) about the origin, 36 wide (5 step on the near
    # side, to x = 21); 41-wide arm with its top at 21 to x = 50, a 55°
    # slope down to the block top above x = 65 (y = 21 − 15·tan55), block
    # 45 long × 32 tall, R10 between the arm's bottom and the block's back
    # face; Ø12 vertical holes at x = 36 and 86 on the centreline, a 12 × 7
    # slot along the block's bottom, 3 × 45° chamfers on the block's end
    # corners and the arm's top near edge.
    y0 = 21 - 15 * math.tan(math.radians(55))
    eye = (Sketch(front(-20.5)).line((0, 21), (21, 21)).line((21, 21), (21, -21)).line((21, -21), (0, -21))
           .arc((0, 0), 21, 90, 270).circle((0, 0), 9))
    body = extrude(eye, (14, 0), 36)
    arm = (Sketch(front(-20.5)).poly([(21, 21), (50, 21), (65, y0), (110, y0), (110, y0 - 32), (65, y0 - 32), (65, -31)], close=False)
           .arc((55, -31), 10, 0, 90).line((55, -21), (21, -21)).line((21, -21), (21, 21)))
    extrude(arm, (40, 0), 41, union=[body])
    for x in (36, 86):
        extrude(Sketch(bottom(30)).circle((x, 0), 6), (x, 0), 70, cut=[body])
    extrude(Sketch(left(111)).rect(-6, y0 - 33, 6, y0 - 25), (0, y0 - 29), 61, cut=[body])
    chamfer(body, 3.0, edges_where(body, lambda e: abs(e["midpoint"][0] - 110) < 0.5 and abs(abs(e["midpoint"][2]) - 20.5) < 0.5 and e["lengthMM"] > 20)
            + edges_where(body, lambda e: abs(e["midpoint"][1] - 21) < 0.5 and abs(e["midpoint"][2] - 20.5) < 0.5 and abs(e["lengthMM"] - 29) < 0.5))
    return body


@problem("4.17", 255293, features=("Extrude Boss", "Sketch: Slot", "Extrude Cut", "Fillet and Chamfer"))
def p4_17():
    # Base 95 × 82 × 24 with a 26 × 8 groove along x under the slot line
    # (v = 21 from the near edge); a 71 × 35 × 47 tower along the far edge
    # with a 20 × 45° chamfer on its top-right edge and a 13 × 17 slot along
    # x through it; a stadium boss 4 tall (R11.5, centres (25, 21) and
    # (70, 21)) with a 13-wide through slot (5 wall) down through the base.
    body = extrude(Sketch(top(0)).rect(0, 0, 95, 82), (47, 41), 24)
    extrude(Sketch(front(-82)).poly([(0, 24), (71, 24), (71, 51), (51, 71), (0, 71)]), (30, 40), 35, union=[body])
    extrude(Sketch(bottom(72)).rect(-1, -71, 72, -58), (30, -64.5), 18, cut=[body])
    extrude(Sketch(top(24)).slot((25, 21), (70, 21), 11.5), (47.5, 21), 4, union=[body])
    extrude(Sketch(bottom(29)).slot((25, -21), (70, -21), 6.5), (47.5, -21), 30, cut=[body])
    extrude(Sketch(right(-1)).rect(8, -1, 34, 8), (21, 3), 97, cut=[body])
    return body


@problem("4.18", 337082, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs", "Sketch: Fillets"))
def p4_18():
    # Hanger: 20-thick plate 145 wide from y = 0 down to R19 rounds about
    # Ø15 holes at (±53.5, −45) and (0, −75), tangent lines between them;
    # a 145 × 12 bar on top, 42 deep, set 7 back from the plate's front;
    # two 22-wide ears (R21 about Ø21 holes at y = 33, mid-depth) at its ends.
    c1 = (53.5, -45.0); c0 = (0.0, -75.0); R = 19.0
    d = (c0[0] - c1[0], c0[1] - c1[1]); L = math.hypot(*d)
    n = (-d[1] / L, d[0] / L)
    ang = math.degrees(math.atan2(n[1], n[0]))              # ≈ −60.7°
    T1 = (c1[0] + R * n[0], c1[1] + R * n[1]); T0 = (c0[0] + R * n[0], c0[1] + R * n[1])
    sk = (Sketch(front(0)).line((-72.5, 0), (72.5, 0)).line((72.5, 0), (72.5, -45))
          .arc(c1, R, ang, 0).line(T1, T0).arc(c0, R, -90, ang)
          .arc(c0, R, -180 - ang, -90).line((-T0[0], T0[1]), (-T1[0], T1[1]))
          .arc((-53.5, -45), R, 180, 180 - ang).line((-72.5, -45), (-72.5, 0))
          .circle(c1, 7.5).circle((-53.5, -45), 7.5).circle(c0, 7.5))
    body = extrude(sk, (0, -20), 20)
    extrude(Sketch(front(7)).rect(-72.5, 0, 72.5, 12), (0, 6), 42, union=[body])
    for x0 in (50.5, -72.5):
        ear = (Sketch(right(x0)).line((-49, 12), (-7, 12)).line((-7, 12), (-7, 33)).arc((-28, 33), 21, 0, 180)
               .line((-49, 33), (-49, 12)).circle((-28, 33), 10.5))
        extrude(ear, (-28, 20), 22, union=[body])
    return body


@problem("4.19", 73407, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot", "Sketch: Arcs", "Fillet"))
def p4_19():
    # Saddle: 9-thick strip 115 long (x −58..57), 50 wide, with an R23/R32
    # arch about the origin and a 9 × 42 upright at the right end; 3 × R2
    # in the concave corners, 4 × R7 on the strip's left corners and the
    # upright's top corners, 2 × Ø8 at (−51, ±18), a 12-wide round-ended
    # slot 18 deep (to its centre) through the upright.
    xo = math.sqrt(32 ** 2 - 81)                       # outer arc meets y = 9
    ao = math.degrees(math.atan2(9, xo))
    sk = (Sketch(front(-25)).poly([(-58, 0), (-58, 9), (-xo, 9)], close=False)
          .arc((0, 0), 32, ao, 180 - ao)
          .poly([(xo, 9), (48, 9), (48, 42), (57, 42), (57, 0), (23, 0)], close=False)
          .arc((0, 0), 23, 0, 180).line((-23, 0), (-58, 0)))
    body = extrude(sk, (-45, 4.5), 50)
    fillet(body, 2.0, edges_near(body, (48, 9, 0), 0.6) + edges_near(body, (xo, 9, 0), 0.6) + edges_near(body, (-xo, 9, 0), 0.6))
    fillet(body, 7.0, edges_near(body, (-58, 4.5, 25), 0.6) + edges_near(body, (-58, 4.5, -25), 0.6)
           + edges_near(body, (52.5, 42, 25), 0.6) + edges_near(body, (52.5, 42, -25), 0.6))
    for z in (18, -18):
        extrude(Sketch(bottom(10)).circle((-51, z), 4), (-51, z), 11, cut=[body])
    extrude(Sketch(left(58)).slot((0, 24), (0, 50), 6), (0, 30), 10, cut=[body])
    return body


@problem("4.20", 436580, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot", "Fillet"))
def p4_20():
    # Split clamp on a stand: base 125 × 75 × 22 (top at y = 0) with two
    # 11 × 17 slots along z at x = ±42.5; a 28 × 48 stem up to a Ø83/Ø55
    # cylinder 55 long along x centred at y = 80; a Ø32 ear 58 long along z
    # centred 45 above the cylinder axis with a Ø13 hole and a 5 slit down
    # into the bore. R5 fillets on the base's edges and the stem's foot
    # (the sheet says R5 everywhere; the rest is left sharp).
    body = extrude(Sketch(top(-22)).rect(-62.5, -37.5, 62.5, 37.5), (0, 0), 22)
    extrude(Sketch(top(0)).rect(-14, -24, 14, 24), (0, 0), 50, union=[body])
    extrude(Sketch(right(-27.5)).circle((0, 80), 41.5).circle((0, 80), 27.5), (0, 115), 55, union=[body])
    ear = Sketch(front(-29)).line((-16, 100), (16, 100)).line((16, 100), (16, 125)).arc((0, 125), 16, 0, 180).line((-16, 125), (-16, 100))
    extrude(ear, (0, 120), 58, union=[body])
    extrude(Sketch(right(-28)).circle((0, 80), 27.5), (0, 80), 56, cut=[body])
    extrude(Sketch(front(-30)).circle((0, 125), 6.5), (0, 125), 60, cut=[body])
    extrude(Sketch(bottom(150)).rect(-28, -2.5, 28, 2.5), (0, 0), 80, cut=[body])
    for x in (42.5, -42.5):
        extrude(Sketch(bottom(1)).slot((x, -8.5), (x, 8.5), 5.5), (x, 0), 24, cut=[body])
    fillet(body, 5.0, edges_where(body, lambda e: abs(e["midpoint"][1] + 11) < 0.5 and abs(abs(e["midpoint"][0]) - 62.5) < 0.5))
    fillet(body, 5.0, edges_where(body, lambda e: abs(e["midpoint"][1]) < 0.01 and (abs(e["midpoint"][0]) > 60 or abs(e["midpoint"][2]) > 36)))
    fillet(body, 5.0, edges_where(body, lambda e: abs(e["midpoint"][1]) < 0.01 and (abs(abs(e["midpoint"][0]) - 14) < 0.5 or abs(abs(e["midpoint"][2]) - 24) < 0.5)))
    return body


@problem("4.22", 106977, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs"))
def p4_22():
    # Ø42/Ø25 tube 45 long along z about the origin; a 52 × 37 × 35 block
    # under its right half (top at y = 0) carrying a 35-wide, 15-thick arm
    # to an R17.5 end about the Ø12 hole at x = 77; Ø12 at x = 41 through
    # the block, Ø22 × 2 rings round both holes, a 12 × 8 slot along the
    # block's bottom (the hole tangent to its faces). R2 rounds left out.
    body = extrude(Sketch(front(-22.5)).circle((0, 0), 21).circle((0, 0), 12.5), (16, 0), 45)
    extrude(Sketch(front(-17.5)).rect(0, -37, 52, 0), (30, -20), 35, union=[body])
    arm = Sketch(top(-15)).line((52, -17.5), (52, 17.5)).line((52, 17.5), (77, 17.5)).arc((77, 0), 17.5, -90, 90).line((77, -17.5), (52, -17.5))
    extrude(arm, (70, 0), 15, union=[body])
    extrude(Sketch(front(-23)).circle((0, 0), 12.5), (0, 0), 46, cut=[body])
    for x, depth in ((41, 41), (77, 20)):
        extrude(Sketch(top(0)).circle((x, 0), 11).circle((x, 0), 6), (x + 8.5, 0), 2, union=[body])
        extrude(Sketch(bottom(3)).circle((x, 0), 6), (x, 0), depth, cut=[body])
    extrude(Sketch(right(-1)).rect(-6, -38, 6, -29), (0, -33), 54, cut=[body])
    return body


@problem("4.24", 87204, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs", "Fillet"))
def p4_24():
    # 108 × 54 × 11 base (R10 on the near corners, 4 × Ø8 at 10 in from the
    # ends, 10 and 35 from the far edge); a 52-wide block whose section is
    # an R49 arc from the near edge up to 21 at z = 40.2, then a 12-high
    # step to 48 (6 of base left bare); a V-groove along z: 18-wide floor 6
    # up, sides tangent to the R15 circle centred on the block's top plane.
    zc = math.sqrt(49 ** 2 - 28 ** 2)                       # 40.21 from the near edge
    body = extrude(Sketch(top(0)).rect(-54, -27, 54, 27), (0, 0), 11)
    fillet(body, 10.0, edges_where(body, lambda e: abs(e["midpoint"][1] - 5.5) < 0.5 and abs(e["midpoint"][2] - 27) < 0.5 and abs(abs(e["midpoint"][0]) - 54) < 0.5))
    for x in (-44, 44):
        for z in (-17, 8):
            extrude(Sketch(bottom(12)).circle((x, z), 4), (x, z), 13, cut=[body])
    u_pk = -27 + zc; a0 = math.degrees(math.atan2(28, -zc))   # start angle of the arc (near edge)
    prof = (Sketch(right(-26)).arc((u_pk, -17), 49, 90, a0)
            .line((u_pk, 32), (u_pk, 23)).line((u_pk, 23), (21, 23)).line((21, 23), (21, 11)).line((21, 11), (-27, 11)))
    extrude(prof, (0, 15), 52, union=[body])
    d = math.hypot(9, 15); L = math.sqrt(d * d - 225)
    ang = math.atan2(15, -9) - math.asin(15 / d)           # tangent from (9, 17) to the R15 circle at (0, 32)
    k = math.cos(ang) / math.sin(ang)
    hw = 9 + 23 * k
    extrude(Sketch(back(30)).poly([(-9, 17), (9, 17), (hw, 40), (-hw, 40)]), (0, 20), 60, cut=[body])
    return body


@problem("4.29", 792960)
def p4_29():
    # Wedge 200 × 100: 90 tall at the left, a 20° slope down to 25 at the
    # right end; between the left plate (up to where the slope meets the
    # top) and the ramp block 55 further on only a 20-deep back band
    # remains; a 50 × 45 slot through the ramp's end.
    t = 200 - 65 / math.tan(math.radians(20))
    body = extrude(Sketch(front(0)).poly([(0, 0), (200, 0), (200, 25), (t, 90), (0, 90)]), (100, 10), 100)
    extrude(Sketch(top(-1)).rect(t, -101, t + 55, -20), (t + 27, -60), 92, cut=[body])
    extrude(Sketch(top(-1)).rect(155, -75, 201, -25), (178, -50), 92, cut=[body])
    return body


@problem("4.31", 106460, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs"))
def p4_31():
    # Open-end wrench: 40 × 5 handle from an R20 eye (Ø12) about the
    # origin, R30 neck fillets tangent to the handle and to the R38 head
    # disc centred 315 away; the disc alone is 15 thick (the side view
    # shows the thick part starting at the disc's edge). Jaw 35 wide with
    # an R25 bottom whose apex is 34 from the disc's far edge (x = 311).
    x30 = -math.sqrt(68 ** 2 - 50 ** 2); xt = 38 * x30 / 68; yt = 38 * 50 / 68
    X30 = 315 + x30
    aT = math.degrees(math.atan2(yt, xt))                     # ≈ 132.7°
    aU = math.degrees(math.atan2(yt - 50, xt - x30))          # upper fillet end angle ≈ −47.4°
    thin = (Sketch(front(-2.5)).line((0, 20), (X30, 20)).arc((X30, 50), 30, -90, aU)
            .arc((315, 0), 38, 360 - aT, 360 + aT).arc((X30, -50), 30, -aU, 90)
            .line((X30, -20), (0, -20)).arc((0, 0), 20, 90, 270).circle((0, 0), 6))
    body = extrude(thin, (150, 0), 5)
    extrude(Sketch(front(-7.5)).circle((315, 0), 38), (300, 0), 15, union=[body])
    cx = 311 + 25; xb = cx - math.sqrt(625 - 17.5 ** 2)
    aJ = math.degrees(math.atan2(17.5, xb - cx))              # ≈ 135.6°
    jaw = (Sketch(front(-8)).line((xb, 17.5), (360, 17.5)).line((360, 17.5), (360, -17.5)).line((360, -17.5), (xb, -17.5))
           .arc((cx, 0), 25, aJ, 360 - aJ))
    extrude(jaw, (330, 0), 16, cut=[body])
    return body


@problem("4.32", 104271, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot", "Fillet"))
def p4_32():
    # 100 × 42 × 10 base with a 60-long block at the right end: vertical
    # face 31 tall, a 25-long face rising at 58° to a ridge, then a 32°
    # face down to the right end; R3 on the four outline corners. Stadium
    # boss R7 × 4 (centres 19 apart along z at x = −83) with an R5 through
    # slot. A 23-wide groove 7 deep with 55° sides runs down the 32° face.
    a = math.radians(58); t32 = math.tan(math.radians(32))
    px = -60 + 25 * math.cos(a); py = 31 + 25 * math.sin(a)
    yend = py - (0 - px) * t32
    prof = Sketch(front(-21)).poly([(-100, 0), (0, 0), (0, yend), (px, py), (-60, 31), (-60, 10), (-100, 10)])
    body = extrude(prof, (-30, 15), 42)
    fillet(body, 3.0, edges_where(body, lambda e: abs(abs(e["midpoint"][2]) - 21) < 0.5 and e["lengthMM"] > 5
                                  and (abs(e["midpoint"][0]) < 0.5 or abs(e["midpoint"][0] + 100) < 0.5)))
    extrude(Sketch(top(10)).slot((-83, -9.5), (-83, 9.5), 7), (-83, 0), 4, union=[body])
    extrude(Sketch(bottom(15)).slot((-83, -9.5), (-83, 9.5), 5), (-83, 0), 16, cut=[body])
    s32, c32 = math.sin(math.radians(32)), math.cos(math.radians(32))
    O = (5.0, py - (5 - px) * t32, 0.0)
    hb = 11.5 - 7 / math.tan(math.radians(55))
    groove = Sketch(plane_at(O, (0, 0, 1), (s32, c32, 0))).poly([(-11.5, 0), (-11.5, 5), (11.5, 5), (11.5, 0), (hb, -7), (-hb, -7)])
    extrude(groove, (0, -3), 75, cut=[body])
    return body


@problem("4.42", 359860, features=("Extrude Boss", "Extrude Cut"))
def p4_42():
    # V-block 135 long: 60 × 52 block with a 30° half-angle V (42 wide at
    # the top) on an 18 × 23 stem whose underside carries four right-angle
    # sawteeth of 28 pitch.
    d = 21 / math.tan(math.radians(30))
    prof = Sketch(front(0)).poly([(-30, 0), (-30, 52), (-21, 52), (0, 52 - d), (21, 52), (30, 52), (30, 0),
                                   (9, 0), (9, -23), (-9, -23), (-9, 0)])
    body = extrude(prof, (-20, 20), 135)
    for i in range(4):
        u0 = -28 * i
        tooth = Sketch(right(-10)).poly([(u0 + 1, -24), (u0 - 29, -24), (u0 - 14, -9)])
        extrude(tooth, (u0 - 14, -20), 20, cut=[body])
    return body


@problem("4.37", 14449, features=("Extrude Boss", "Extrude Cut", "Fillet and Chamfer"))
def p4_37():
    # Ø50 × 13 disc, Ø7 centre hole, four radial slots of width 12 / 11 /
    # 10 / 13 (top, right, bottom, left) whose round inner ends are centred
    # on an R12 circle; 2 × 45° chamfer on one face's rim.
    body = extrude(Sketch(front(0)).circle((0, 0), 25).circle((0, 0), 3.5), (15, 0), 13)
    for ang, w in ((90, 12), (0, 11), (270, 10), (180, 13)):
        a = math.radians(ang); c = (12 * math.cos(a), 12 * math.sin(a)); o = (40 * math.cos(a), 40 * math.sin(a))
        extrude(Sketch(front(-1)).slot(c, o, w / 2), (20 * math.cos(a), 20 * math.sin(a)), 15, cut=[body])
    chamfer(body, 2.0, edges_where(body, lambda e: abs(e["midpoint"][2]) < 0.01
                                   and abs(math.hypot(e["midpoint"][0], e["midpoint"][1]) - 25) < 0.6))
    return body


@problem("4.43", 152537, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs"))
def p4_43():
    # 124 × 164 × 5 back plate (3 × Ø12 at 15 from the edges) with a
    # U-channel (R35 outer, 5 wall, legs 75 long) standing 55 proud of it;
    # the legs are cut back by a plane from full depth 14 above the arc
    # centre to nothing at their tops.
    plate = Sketch(front(-5)).rect(-62, -62, 62, 102).circle((0, 87), 6).circle((47, -47), 6).circle((-47, -47), 6)
    body = extrude(plate, (-55, 80), 5)
    u = (Sketch(front(0)).line((-35, 75), (-35, 0)).arc((0, 0), 35, 180, 360).line((35, 0), (35, 75))
         .line((35, 75), (30, 75)).line((30, 75), (30, 0)).arc((0, 0), 30, 180, 360).line((-30, 0), (-30, 75))
         .line((-30, 75), (-35, 75)))
    extrude(u, (-32.5, 30), 55, union=[body])
    extrude(Sketch(right(-40)).poly([(-55, 14), (-56, 14), (-56, 110), (0, 110), (0, 75)]), (-30, 90), 80, cut=[body])
    return body


@problem("4.52", 219660, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot (arc)", "Fillet"))
def p4_52():
    # L-bracket: 150 × 80 × 15 base whose far end is an R75 arc about the
    # Ø12 hole at x = 75 (Ø25 × 5 counterbore), an R50 centre-point arc
    # slot 16 wide spanning ±30° about that hole; a 15-thick upright 75
    # tall overall with R20 top corners and two Ø15 holes.
    xa = 75 + math.sqrt(75 ** 2 - 40 ** 2); aa = math.degrees(math.atan2(40, xa - 75))
    base = Sketch(top(0)).poly([(0, -40), (0, 40), (xa, 40)], close=False).arc((75, 0), 75, -aa, aa).line((xa, -40), (0, -40))
    body = extrude(base, (40, 0), 15)
    up = Sketch(right(0)).rounded_poly([(-40, 15), (40, 15), (40, 75), (-40, 75)], [0, 0, 20, 20])
    extrude(up, (0, 40), 15, union=[body])
    for z in (-20, 20):
        extrude(Sketch(right(-1)).circle((z, 55), 7.5), (z, 55), 17, cut=[body])
    extrude(Sketch(bottom(16)).circle((75, 0), 6), (75, 0), 17, cut=[body])
    extrude(Sketch(bottom(15)).circle((75, 0), 12.5), (75, 0), 5, cut=[body])
    c1 = (75 + 50 * math.cos(math.radians(30)), 25.0); c2 = (c1[0], -25.0)
    slot = (Sketch(bottom(16)).arc((75, 0), 58, -30, 30).arc(c1, 8, 30, 210).arc((75, 0), 42, -30, 30)
            .arc(c2, 8, 150, 330))
    extrude(slot, (125, 0), 17, cut=[body])
    return body


@problem("4.53", 195556, features=("Extrude Boss", "Extrude Cut", "Fillet"))
def p4_53():
    # Angle bracket: 15-thick bar 175 long; the left 65 (80 at the bottom,
    # a 45° face) is 90 wide with a 16 × 25 leg hanging from its left end
    # (R10 bottom corners, 2 × Ø10 through), the rest a 30-wide arm ending
    # in a 30-square eye 16 tall with an R15 top and Ø15 hole; 2 × Ø8
    # through the wide part at x = 30 and 55.
    body = extrude(Sketch(front(-45)).poly([(0, 0), (65, 0), (80, -15), (16, -15), (16, -40), (0, -40)]), (30, -8), 90)
    extrude(Sketch(front(-15)).rect(60, -15, 175, 0), (120, -8), 30, union=[body])
    eye = (Sketch(front(-15)).line((145, 0), (145, 16)).arc((160, 16), 15, 0, 180).line((175, 16), (175, 0))
           .line((175, 0), (145, 0)).circle((160, 16), 7.5))
    extrude(eye, (160, 5), 30, union=[body])
    for x in (30, 55):
        extrude(Sketch(bottom(1)).circle((x, 0), 4), (x, 0), 17, cut=[body])
    fillet(body, 10.0, edges_where(body, lambda e: abs(e["midpoint"][1] + 40) < 0.5 and abs(abs(e["midpoint"][2]) - 45) < 0.5))
    for z in (-35, 35):
        extrude(Sketch(right(-1)).circle((-z, -27.5), 5), (-z, -27.5), 18, cut=[body])
    return body


@problem("4.54", 120198, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot"))
def p4_54():
    # Fork wedge: 112 × 62 × 15 plate whose far half tapers 8 in per side
    # over the last 50 and carries an 18-wide slot with a Ø18 end 29 from
    # the tip; a 27-long house-section block (62 wide, 15 sides above the
    # plate, 28° roof rising 12) at the near end with 7 × 11 notches cut
    # out of its two outer corners and a Ø7 hole along x 9 below the ridge.
    run = 12 / math.tan(math.radians(28)); hw = 31 - run
    house = Sketch(right(0)).poly([(-62, 0), (0, 0), (0, 30), (-31 + hw, 42), (-31 - hw, 42), (-62, 30)])
    body = extrude(house, (-31, 10), 27)
    plate = (Sketch(top(0)).poly([(0, 0), (0, -62), (62, -62), (112, -54), (112, -40), (83, -40)], close=False)
             .arc((83, -31), 9, 90, 270).line((83, -22), (112, -22)).line((112, -22), (112, -8)).line((112, -8), (62, 0))
             .line((62, 0), (0, 0)))
    extrude(plate, (40, -31), 15, union=[body])
    for v0, v1 in ((-11, 1), (-63, -51)):
        extrude(Sketch(top(-1)).rect(-1, v0, 7, v1), (3, (v0 + v1) / 2), 45, cut=[body])
    extrude(Sketch(right(-1)).circle((-31, 33), 3.5), (-31, 33), 29, cut=[body])
    return body


@problem("4.35", 3179, features=("Extrude Boss", "Extrude Cut", "Fillet"))
def p4_35():
    # C-clip, 5 thick throughout, 10 deep: 25-long flanges with a 2-deep,
    # 8-long groove inside leaving a 3 lip at each tip, a 28-tall web with
    # a 45° corner up to the top flange (top at 37); R2 in the square
    # inner corner; Ø3 through each flange (x = 18) and Ø5 through the
    # web 12 up.
    c = -28 + 5 * math.sqrt(2)
    prof = Sketch(front(0)).poly([(0, 0), (25, 0), (25, 5), (22, 5), (22, 3), (14, 3), (14, 5), (5, 5), (5, 5 - c),
                                   (32 + c, 32), (14, 32), (14, 34), (22, 34), (22, 32), (25, 32), (25, 37), (9, 37), (0, 28)])
    body = extrude(prof, (2.5, 15), 10)
    fillet(body, 2.0, edges_near(body, (5, 5, 5), 0.6))
    for y0, d in ((-1, 7), (31, 7)):
        extrude(Sketch(bottom(y0 + d)).circle((18, 5), 1.5), (18, 5), d + 1, cut=[body])
    extrude(Sketch(right(-1)).circle((-5, 12), 2.5), (-5, 12), 7, cut=[body])
    return body


@problem("4.48", 886973, features=("Extrude Boss", "Extrude Cut", "Fillet"))
def p4_48():
    # Omega clamp 100 deep: Ø129/Ø95 ring about the origin; two parallel
    # 17-thick legs leaning at 60°, each tangent to both circles (the right
    # leg's inner edge through the origin); a 17-thick base whose underside
    # is 90 below the origin, spanning x = −110..115, open between the
    # legs; R20 / R12
    # in the foot corners; 2 × Ø20 at x = ±90.
    n = (math.cos(math.radians(30)), math.sin(math.radians(30)))
    def on_line(s, y):                      # x where n·p = s at height y
        return (s - n[1] * y) / n[0]
    def circ_pts(s, R):                     # lower intersection of n·p = s with r = R
        h = math.sqrt(max(0.0, R * R - s * s)); px, py = s * n[0], s * n[1]
        return (px + h * 0.5, py - h * math.sqrt(3) / 2)
    xl = -110.0
    body = extrude(Sketch(front(-50)).rect(xl, -90, 115, -73), (0, -80), 100)
    extrude(Sketch(front(-50)).circle((0, 0), 64.5).circle((0, 0), 47.5), (56, 0), 100, union=[body])
    T = circ_pts(-64.5, 64.5); P = circ_pts(-47.5, 64.5)
    aT = math.degrees(math.atan2(T[1], T[0])); aP = math.degrees(math.atan2(P[1], P[0]))
    left = (Sketch(front(-50)).line((on_line(-64.5, -90), -90), T).arc((0, 0), 64.5, aT, aP)
            .line(P, (on_line(-47.5, -90), -90)).line((on_line(-47.5, -90), -90), (on_line(-64.5, -90), -90)))
    extrude(left, (on_line(-56, -80), -80), 100, union=[body])
    D = circ_pts(17, 64.5); E = circ_pts(0, 64.5)
    aD = math.degrees(math.atan2(D[1], D[0])); aE = math.degrees(math.atan2(E[1], E[0]))
    rightleg = (Sketch(front(-50)).line((on_line(0, -90), -90), (on_line(17, -90), -90)).line((on_line(17, -90), -90), D)
                .arc((0, 0), 64.5, aE, aD).line(E, (on_line(0, -90), -90)))
    extrude(rightleg, (on_line(8.5, -80), -80), 100, union=[body])
    extrude(Sketch(front(-51)).circle((0, 0), 47.5), (0, 0), 102, cut=[body])
    gap = Sketch(front(-51)).poly([(on_line(-47.5, -91), -91), (on_line(0, -91), -91), (on_line(0, -20), -20), (on_line(-47.5, -20), -20)])
    extrude(gap, (on_line(-23, -80), -80), 102, cut=[body])
    fillet(body, 20.0, edges_near(body, (on_line(-64.5, -73), -73, 0), 0.6))
    fillet(body, 12.0, edges_near(body, (on_line(17, -73), -73, 0), 0.6))
    for x in (-90, 90):
        extrude(Sketch(bottom(-72)).circle((x, 0), 10), (x, 0), 19, cut=[body])
    return body


@problem("4.59", 144672, features=("Extrude Boss", "Extrude Cut", "Sketch: Arcs"))
def p4_59():
    # 150 × 50 × 15 plate with an R25 end about the Ø25 hole at the origin
    # and a Ø15 at x = 135; a 15-thick R15 lug (Ø12) standing 30 up at
    # x = 35 on the near 15 of the width, and a matching lug hanging 30
    # down beside the near edge at x = 135.
    plate = Sketch(top(0)).line((0, 25), (150, 25)).line((150, 25), (150, -25)).line((150, -25), (0, -25)).arc((0, 0), 25, 90, 270)
    plate.circle((0, 0), 12.5).circle((135, 0), 7.5)
    body = extrude(plate, (75, 10), 15)
    up = Sketch(front(-25)).line((20, 15), (20, 30)).arc((35, 30), 15, 0, 180).line((50, 30), (50, 15)).line((50, 15), (20, 15)).circle((35, 30), 6)
    extrude(up, (35, 20), 15, union=[body])
    down = Sketch(front(-40)).line((120, 15), (150, 15)).line((150, 15), (150, -15)).arc((135, -15), 15, 180, 360).line((120, -15), (120, 15)).circle((135, -15), 6)
    extrude(down, (135, 0), 15, union=[body])
    return body


@problem("4.56", 190758, features=("Extrude Boss", "Extrude Cut", "Sketch: Slot"))
def p4_56():
    # 150 × 55 × 32 bar with R32 quarter-round ends on top, a 37 × 20
    # channel along its top, a 125 × 55 × 10 pad under it, and two 12-wide
    # slots (33 between centres, 28 apart) through the channel floor.
    prof = (Sketch(front(-27.5)).line((0, 0), (150, 0)).line((150, 0), (150, 0.0001)) if False else
            Sketch(front(-27.5)).line((0, 0), (150, 0)).arc((118, 0), 32, 0, 90).line((118, 32), (32, 32)).arc((32, 0), 32, 90, 180))
    body = extrude(prof, (75, 15), 55)
    extrude(Sketch(front(-27.5)).rect(12.5, -10, 137.5, 0), (75, -5), 55, union=[body])
    extrude(Sketch(bottom(40)).rect(-1, -18.5, 151, 18.5), (75, 0), 28, cut=[body])
    for a, b in ((28, 61), (89, 122)):
        extrude(Sketch(bottom(13)).slot((a, 0), (b, 0), 6), ((a + b) / 2, 0), 24, cut=[body])
    return body


@problem("4.57", 347206, features=("Extrude Boss", "Extrude Cut", "Fillet"))
def p4_57():
    # Ø65/Ø32 tube 100 long along x; a 45 × 65 lug block from the axis
    # level down to an R22.5 eye centred 52 below (Ø25 hole, 10 × 5 keyway
    # above it); R6 where the lug's flanks meet the tube (see below).
    body = extrude(Sketch(right(-50)).circle((0, 0), 32.5).circle((0, 0), 16), (0, 24), 100)
    lug = (Sketch(front(-32.5)).line((-22.5, 0), (22.5, 0)).line((22.5, 0), (22.5, -52)).arc((0, -52), 22.5, 180, 360)
           .line((-22.5, -52), (-22.5, 0)).circle((0, -52), 12.5))
    extrude(lug, (0, -20), 65, union=[body])
    extrude(Sketch(right(-51)).circle((0, 0), 16), (0, 0), 102, cut=[body])
    extrude(Sketch(front(-33)).rect(-5, -40, 5, -34), (0, -37), 66, cut=[body])
    # The R6 blends along the flank/tube arcs end where the lug's z-faces
    # are tangent to the tube; OCCT rejects them ("blended solid failed
    # validity checking"), so they are left off (about -0.4 %).
    return body
