"""Level 4 — Extrude Cut & Fillet/Chamfer (70 problems)."""
import math
from kit import Sketch, front, top, bottom, right, left, extrude, fillet, chamfer, edges_where

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
