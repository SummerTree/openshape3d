"""Level 14 — Rib (9 problems). The app has no rib feature: a rib is a
thin extrude between the faces it bridges (Extrude up to next where the
drawing lets it, otherwise a profile drawn to the neighbouring faces)."""
import math
from kit import (Sketch, front, back, top, bottom, right, left, extrude, revolve, fillet, chamfer,
                 edges_where, union, subtract, bodies, pattern, mirror)

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss", "Rib (as extrude)")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("14.1", 377718.5, features=("Extrude Boss", "Extrude Cut", "Rib (as extrude)"))
def p14_1():
    # Drawer tray: 190 × 150 × 25 body (x, z, y) with 10 walls on three
    # sides, closed on the fourth by a 170 × 45 × 10 front plate (z −10..160,
    # y 0..45) whose knob is Ø5 × 3 + Ø10 × 3; floor 6 thick; a 3-deep
    # recess over the whole interior, then ten 16-deep pockets left by
    # 3-thick ribs (columns 33.5 TYP from the far wall, the last 34; rows
    # 63.5 either side of one cross rib). The hint says the pockets need
    # not be equal.
    body = extrude(Sketch(top(0)).rect(0, -150, 190, 0), (5, -5), 25)
    extrude(Sketch(top(25)).rect(10, -140, 190, -10), (100, -75), -3, cut=[body])
    xs = [(10, 43.5), (46.5, 80), (83, 116.5), (119.5, 153), (156, 190)]
    zs = [(10, 73.5), (76.5, 140)]
    for (x0, x1) in xs:
        for (z0, z1) in zs:
            extrude(Sketch(top(22)).rect(x0, -z1, x1, -z0), ((x0 + x1) / 2, -(z0 + z1) / 2), -16, cut=[body])
    plate = Sketch(right(190)).rect(-160, 0, 10, 45)      # u = -z: z from -10 to 160
    extrude(plate, (-75, 20), 10, union=[body])
    extrude(Sketch(right(200)).circle((-75, 22.5), 2.5), (-75, 22.5), 3, union=[body])
    extrude(Sketch(right(203)).circle((-75, 22.5), 5), (-75, 22.5), 3, union=[body])
    return body


@problem("14.5", 23272, features=("Extrude Boss", "Extrude Cut", "Fillet", "Hole (as cut)", "Rib (as extrude)"))
def p14_5():
    # Base 42.5 x 15 x 5 (x -32.5..10, y -5..0) with a Ø9 hole at the origin
    # and R3 on its right top edge. A 15-wide slab (z ±7.5): column x -7.5..0
    # plus an R7.5 half-round back about the y axis, 75 tall, Ø9 down the
    # axis; a lobe of R15 round the Ø14 hole at (-12.5, 40), the front face
    # running tangent from the lobe up to the top's x = -7.5 (the top view's
    # 5 / -24.8 lines are the lobe's silhouette and that tangent edge); below
    # the lobe a leg x -20.5..-12.5 with a step at y = 11 (R3.5 outside, R2
    # inside) and a 6-high slot from x = -15 under the column. A 3-thick rib
    # from the base's left end (-32.5, 0) to the lobe's quadrant (-27.5, 40),
    # filling to the body as SOLIDWORKS' Rib does.
    C = (-12.5, 40.0); P = (-7.5, 75.0)
    d = math.dist(C, P)
    ta = math.degrees(math.atan2(P[1] - C[1], P[0] - C[0])) + math.degrees(math.acos(15 / d))
    T = (C[0] + 15 * math.cos(math.radians(ta)), C[1] + 15 * math.sin(math.radians(ta)))
    base = extrude(Sketch(top(-5)).rect(-32.5, -7.5, 10, 7.5).circle((0, 0), 4.5), (-25, 0), 5)
    fillet(base, 3.0, edges_where(base, lambda e: abs(e["midpoint"][0] - 10) < 0.5
                                  and abs(e["midpoint"][1]) < 0.5 and abs(e["lengthMM"] - 15) < 0.5))
    slab = (Sketch(front(-7.5)).line(P, T).arc(C, 15, ta, 270).line((-12.5, 25), (-12.5, 13))
            .arc((-14.5, 13), 2, 270, 360).line((-14.5, 11), (-17, 11)).arc((-17, 7.5), 3.5, 90, 180)
            .line((-20.5, 7.5), (-20.5, 0)).line((-20.5, 0), (-15, 0)).line((-15, 0), (-15, 6)).line((-15, 6), (-7.5, 6))
            .line((-7.5, 6), P))
    extrude(slab, (-15, 60), 15, union=[base])
    col = (Sketch(top(6)).line((-7.5, -7.5), (0, -7.5)).arc((0, 0), 7.5, -90, 90).line((0, 7.5), (-7.5, 7.5))
           .line((-7.5, 7.5), (-7.5, -7.5)).circle((0, 0), 4.5))
    extrude(col, (-6, 0), 69, union=[base])
    extrude(Sketch(front(-7.5)).circle(C, 7), C, 15, cut=[base])
    rib = (Sketch(front(-1.5)).line((-32.5, 0), (-20.5, 0)).line((-20.5, 0), (-20.5, 11)).line((-20.5, 11), (-12.5, 11))
           .line((-12.5, 11), (-12.5, 25)).arc(C, 15, 180, 270).line((-27.5, 40), (-32.5, 0)))
    extrude(rib, (-24, 5), 3, union=[base])
    return base


@problem("14.3", 1831893, features=("Revolve", "Extrude Boss", "Rib (as extrude)", "Pattern (as recipe)"))
def p14_3():
    # Grille: a revolved wall 80 tall, bore Ø420, outside Ø450 to y = 35,
    # tapering to Ø440 at y = 60 and straight to the top; 21 ribs 5 thick,
    # 10 tall, flush with the top at 20 spacing spanning the bore; two
    # 60-wide, 15-thick forked tabs reaching 26 past the slot's R10 end
    # (tip-to-tip 552: 500 between the slot ends), R6 tip corners.
    wall = Sketch(front(0)).poly([(210, 0), (225, 0), (225, 35), (220, 60), (220, 80), (210, 80)])
    body = revolve(wall, (217, 20), (0, 0), (0, 1))
    for i in range(-10, 11):
        x = 20 * i
        h = math.sqrt(215 ** 2 - (abs(x) + 2.5) ** 2)
        extrude(Sketch(top(70)).rect(x - 2.5, -h, x + 2.5, h), (x, 0), 10, union=[body])
    for s in (1, -1):
        sk = Sketch(top(0))
        def L(a, b):
            sk.line((s * a[0], a[1]), (s * b[0], b[1]))
        def A(c, r, a0, a1):
            if s > 0:
                sk.arc(c, r, a0, a1)
            else:
                sk.arc((-c[0], c[1]), r, 180 - a1, 180 - a0)
        L((210.5, -30), (270, -30)); A((270, -24), 6, 270, 360); L((276, -24), (276, -10))
        L((276, -10), (260, -10)); A((260, 0), 10, 90, 270); L((260, 10), (276, 10))
        L((276, 10), (276, 24)); A((270, 24), 6, 0, 90); L((270, 30), (210.5, 30)); L((210.5, 30), (210.5, -30))
        extrude(sk, (s * 240, 20), 15, union=[body])
    return body
