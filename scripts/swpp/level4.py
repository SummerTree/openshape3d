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
