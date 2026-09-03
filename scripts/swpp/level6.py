"""Level 6 — Revolve Boss/Cut (20 problems)."""
import math
from kit import Sketch, front, top, right, extrude, revolve, fillet, edges_where

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Revolve",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


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
