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
