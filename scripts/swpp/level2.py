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
