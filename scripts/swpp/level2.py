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
