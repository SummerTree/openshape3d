"""Level 18 — CSWP exam-style parts (multi-stage). Only the first stage of
a multi-stage sheet is built; later stages' printed volumes go in the
worker notes. Recipes follow level14.py's conventions."""
import math
from kit import (Sketch, front, back, top, bottom, right, left, extrude, revolve, fillet, chamfer,
                 shell, edges_where, edges_near, union, subtract, bodies, pattern, mirror, plane_at,
                 draft_face, faces)

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss", "Extrude Cut")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("18.16", 176459.6, features=("Extrude Boss", "Extrude Cut", "Chamfer (as cut)", "Hole (as cut)"))
def p18_16():
    # Origin at the back-left-bottom corner; x right, y up, z toward the
    # viewer (0..50). Back slab z 0..30: tall block x 30..60 to 63, right
    # block x 60..100 to 48 (63 - 15), low-left region under an R30 arc
    # about (0, 35) from (0, 5) to the pin centre (30, 35). Front slab
    # z 30..50: the same blocks with a O50 half-scoop about (30, 35) out of
    # the tall block, the low-left region under R25 about (0, 35) from
    # (0, 10) to the cusp, a 20 deg plane down to (20, 10), flat to (30, 10).
    # O20 half boss (x >= 30) 8 long on the scoop floor, a solid O10 pin the
    # full depth (the left view's band and the top view's x 25..30 strip),
    # 20 deg x 18 chamfer on the tall block's back top edge, R20/x80 pocket
    # 9 deep in the right block's front face with the O9 hole through,
    # Detail A notch (20 deg from (45,0), 45 deg to (85,0), R10 crest) through.
    t20 = math.tan(math.radians(20))
    # cusp: 20 deg line y = 10 + (20 - x) t20 meets x^2 + (y-35)^2 = 625
    lo, hi = 5.0, 20.0
    for _ in range(60):
        mid = (lo + hi) / 2
        y = 10 + (20 - mid) * t20
        if mid * mid + (y - 35) ** 2 < 625:
            lo = mid
        else:
            hi = mid
    cx = (lo + hi) / 2; cy = 10 + (20 - cx) * t20
    cusp_ang = math.degrees(math.atan2(cy - 35, cx))
    back_sk = (Sketch(front(0)).poly([(0, 0), (100, 0), (100, 48), (60, 48), (60, 63), (30, 63), (30, 35)], close=False)
               .arc((0, 35), 30, 270, 360).line((0, 5), (0, 0)))
    body = extrude(back_sk, (50, 20), 30)
    # chamfer 18 tall x 18 tan20 deep on the back top edge of the tall block
    ch = Sketch(right(25)).poly([(0.5, 63.5), (-18 * t20 - 0.5 * t20, 63.5), (0.5, 45 - 0.5 / t20)])
    extrude(ch, (-1, 60), 40, cut=[body])
    fr = (Sketch(front(30)).poly([(0, 0), (100, 0), (100, 48), (60, 48), (60, 63), (30, 63), (30, 60)], close=False)
          .arc((30, 35), 25, -90, 90).line((30, 10), (20, 10)).line((20, 10), (cx, cy))
          .arc((0, 35), 25, -90, cusp_ang).line((0, 10), (0, 0)))
    extrude(fr, (80, 20), 20, union=[body])
    boss = Sketch(front(30)).arc((30, 35), 10, -90, 90).line((30, 45), (30, 25))
    extrude(boss, (35, 35), 8, union=[body])
    extrude(Sketch(front(0)).circle((30, 35), 5), (30, 35), 50, union=[body])
    pocket = (Sketch(front(50)).poly([(100, 48), (80, 48), (80, 35)], close=False).arc((100, 35), 20, 180, 270)
              .line((100, 15), (100, 48)))
    extrude(pocket, (90, 40), -9, cut=[body])
    extrude(Sketch(front(50)).circle((90, 35), 4.5), (90, 35), -50, cut=[body])
    # Detail A notch
    ax = (45 * t20 + 85) / (t20 + 1); ay = (ax - 45) * t20
    theta = math.radians(115); R = 10
    d = R / math.tan(theta / 2)
    u1 = (-math.cos(math.radians(20)), -math.sin(math.radians(20)))
    u2 = (math.cos(math.radians(45)), -math.sin(math.radians(45)))
    T1 = (ax + u1[0] * d, ay + u1[1] * d); T2 = (ax + u2[0] * d, ay + u2[1] * d)
    bx, by = u1[0] + u2[0], u1[1] + u2[1]; bl = math.hypot(bx, by)
    c = (ax + bx / bl * R / math.sin(theta / 2), ay + by / bl * R / math.sin(theta / 2))
    a1 = math.degrees(math.atan2(T1[1] - c[1], T1[0] - c[0])); a2 = math.degrees(math.atan2(T2[1] - c[1], T2[0] - c[0]))
    notch = (Sketch(front(-1)).line((45, 0), T1).arc(c, R, a2, a1).line(T2, (85, 0))
             .line((85, 0), (85, -2)).line((85, -2), (45, -2)).line((45, -2), (45, 0)))
    extrude(notch, (74, 3), 52, cut=[body])
    return body


@problem("18.21", 11756.4, features=("Extrude Boss", "Revolve", "Shell (as explicit walls)", "Rib (as extrude)", "Pattern (as recipe)"))
def p18_21():
    # Twin syringe: 50 x 25 x 2 plate with R10 corners (origin at its inner
    # face, barrels along +y), two O20 barrels 80 long at x = +-11, 1 SHELL
    # TYP open through the plate (O18 bores through it, the plate itself
    # not shelled), 1 thick tip caps, O5 x 8 nozzles at x = +-5 with 3 deg
    # draft, hollow (the shell follows them: O3 -> O2.16 bore, open tip,
    # Detail B's white hole), and 5 x 10 rib blocks bridging the 2 mm gap
    # centred 20 and 70 up (10 TYP tall, 50 apart). Hand (closed form):
    # plate 1310.4 + 2 x (tube 4715.5 + cap 306.9 + nozzle 90.0) + ribs
    # 2 x 110.6 = 11756.1 (-0.003 %).
    t3 = math.tan(math.radians(3))
    plate = Sketch(top(-2)).rounded_poly([(-25, -12.5), (25, -12.5), (25, 12.5), (-25, 12.5)], 10)
    plate.circle((11, 0), 9).circle((-11, 0), 9)
    body = extrude(plate, (0, 10), 2)
    for sx in (1, -1):
        cx = 11 * sx; nx = 5 * sx
        extrude(Sketch(top(0)).circle((cx, 0), 10).circle((cx, 0), 9), (cx + 9.5, 0), 79, union=[body])
        extrude(Sketch(top(79)).circle((cx, 0), 10).circle((nx, 0), 1.5), (cx + 7 * sx, 0), 1, union=[body])
        r_o0, r_o1 = 2.5, 2.5 - 8 * t3
        r_i0, r_i1 = 1.5, 1.5 - 8 * t3
        prof = Sketch(front(0)).poly([(nx + r_i0, 80), (nx + r_o0, 80), (nx + r_o1, 88), (nx + r_i1, 88)])
        revolve(prof, (nx + 2.0, 82), (nx, 80), (0, 1), union=[body])
    for yc in (20, 70):
        extrude(Sketch(front(-2.5)).rect(-1.4, yc - 5, 1.4, yc + 5), (0, yc), 5, union=[body])
    return body
