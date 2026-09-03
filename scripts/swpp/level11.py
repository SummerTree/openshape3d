"""Level 11 — Hole Wizard (12 problems). The app has no hole wizard; the
standard counterbore/countersink sizes are cut as stacked cylinders and
patterned with Transform › Pattern."""
import math
from kit import (Sketch, front, top, right, extrude, fillet, chamfer, edges_where,
                 pattern, subtract, union, bodies, vol)

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Hole Wizard",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


# ANSI B18.3 socket-head cap screw counterbores (normal fit through holes)
CBORE = {"#8": (0.1770, 0.3130, 0.1640), "#10": (0.2010, 0.3750, 0.1900)}


@problem("11.1", 12.7, unit="in")
def p11_1():
    # IPS plate 0.50 thick: a 4.00 × 3.00 tab (x 0..4) joined to a 3.50 ×
    # 4.00 body (x 4..7.5) with R0.25 inside corners and 0.2 × 45° chamfers
    # on the four outer corners; 9 CBORE #8 holes on a 1.00 grid from
    # (4.75, 0) and 2 CBORE #10 holes 1.625 apart 2.00 from the left edge.
    s = 25.4
    plate = extrude(Sketch(top(0)).poly([(0, -1.5 * s), (4 * s, -1.5 * s), (4 * s, -2 * s), (7.5 * s, -2 * s),
                                          (7.5 * s, 2 * s), (4 * s, 2 * s), (4 * s, 1.5 * s), (0, 1.5 * s)]),
                    (2 * s, 0), 0.5 * s)
    # inside-corner rounds (the two vertical edges at x = 4, |v| = 1.5)
    fillet(plate, 0.25 * s, edges_where(plate, lambda e: abs(e["midpoint"][0] - 4 * s) < 0.5
                                        and abs(abs(e["midpoint"][2]) - 1.5 * s) < 0.5 and abs(e["lengthMM"] - 0.5 * s) < 0.5))
    chamfer(plate, 0.2 * s, edges_where(plate, lambda e: abs(e["lengthMM"] - 0.5 * s) < 0.5
                                        and ((abs(e["midpoint"][0]) < 0.5 and abs(abs(e["midpoint"][2]) - 1.5 * s) < 0.5)
                                             or (abs(e["midpoint"][0] - 7.5 * s) < 0.5 and abs(abs(e["midpoint"][2]) - 2 * s) < 0.5))))

    def cbore_cutter(x, v, spec):
        thru, cb, depth = CBORE[spec]
        c = extrude(Sketch(top(-0.1 * s)).circle((x, v), thru / 2 * s), (x, v), 0.7 * s, new_body=True)
        head = extrude(Sketch(top(0.5 * s - depth * s)).circle((x, v), cb / 2 * s), (x, v), depth * s + 0.1 * s, new_body=True)
        union(c, [head])
        return c

    # Sketch v = -z on the top plane: a hole drawn at v = -1.0 sits at world
    # z = +1.0, so the grid's second direction runs along -z.
    known = {b["id"] for b in bodies()}
    c8 = cbore_cutter(4.75 * s, -1.0 * s, "#8")
    pattern(c8, "linear", 3, axis=(1, 0, 0), spacing=1.0 * s)
    row = [b["id"] for b in bodies() if b["id"] not in known]
    for cid in list(row):
        pattern(cid, "linear", 3, axis=(0, 0, -1), spacing=1.0 * s)
    c10 = cbore_cutter(2.0 * s, -0.8125 * s, "#10")
    pattern(c10, "linear", 2, axis=(0, 0, -1), spacing=1.625 * s)
    tools = [b["id"] for b in bodies() if b["id"] not in known]
    assert len(tools) == 11, f"expected 11 hole cutters, found {len(tools)}"
    subtract(plate, tools)
    return plate


@problem("11.2", 29430, features=("Extrude Boss", "Hole (stacked cylinders)", "Pattern (as recipe)"))
def p11_2():
    # Plate 60 × 60 × 10; nine Ø8 through holes on a 3 × 3 grid rotated 45°
    # with 15 spacing about the centre; four M5 SHCS counterbores at the
    # corners (7 in): Ø5.5 through, Ø10 × 5 counterbore — the only size
    # pair that lands the 29430 (Ø9.5 × 5.4 is 0.3 % light).
    body = extrude(Sketch(top(0)).rect(0, 0, 60, 60), (30, 30), 10)
    s = 15 / math.sqrt(2)
    sk = Sketch(top(10))
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            sk.circle((30 + (i + j) * s, 30 + (i - j) * s), 4)
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            c = (30 + (i + j) * s, 30 + (i - j) * s)
            extrude(Sketch(top(10)).circle(c, 4), c, -10, cut=[body])
    for c in ((7, 7), (53, 7), (7, 53), (53, 53)):
        extrude(Sketch(top(10)).circle(c, 2.75), c, -10, cut=[body])
        extrude(Sketch(top(10)).circle(c, 5), c, -5, cut=[body])
    return body


@problem("11.3", 4.98, unit="in", features=("Extrude Boss", "Extrude Cut", "Hole (stacked cylinders)", "Pattern (as recipe)"))
def p11_3():
    # Disc Ø3.75 × 0.5625 with a Ø1.0 through hole ringed by a Ø1.25 × 0.125
    # recess (read as a recess: as a boss the part is 2.3 % heavy, and the
    # difference is exactly twice the ring); five 3/8 SHCS counterbores
    # (Ø0.4063 through, Ø0.5625 × 0.375) on R1.3125 from 270°, five 5/16-18
    # tapped holes (tap drill Ø0.257 through) between them.
    IN = 25.4
    disc = extrude(Sketch(top(0)).circle((0, 0), 1.875 * IN).circle((0, 0), 0.5 * IN), (1.2 * IN, 0), 0.5625 * IN)
    extrude(Sketch(top(0)).circle((0, 0), 0.625 * IN), (0, 0), 0.125 * IN, cut=[disc])
    for k in range(5):
        a = math.radians(270 + 72 * k)
        c = (1.3125 * IN * math.cos(a), 1.3125 * IN * math.sin(a))
        extrude(Sketch(top(0.5625 * IN)).circle(c, 0.4063 / 2 * IN), c, -0.5625 * IN, cut=[disc])
        extrude(Sketch(top(0.5625 * IN)).circle(c, 0.5625 / 2 * IN), c, -0.375 * IN, cut=[disc])
        b = math.radians(270 + 36 + 72 * k)
        t = (1.3125 * IN * math.cos(b), 1.3125 * IN * math.sin(b))
        extrude(Sketch(top(0.5625 * IN)).circle(t, 0.257 / 2 * IN), t, -0.5625 * IN, cut=[disc])
    return disc
