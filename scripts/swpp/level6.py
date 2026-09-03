"""Level 6 — Revolve Boss/Cut (20 problems)."""
import math
from kit import Sketch, front, top, right, extrude, revolve, fillet, edges_where

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
