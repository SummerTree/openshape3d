"""Level 7 — Feature Patterning (48 problems): mirror, linear, circular."""
import math
from kit import (Sketch, front, top, bottom, right, left, extrude, fillet, chamfer, edges_where,
                 mirror, pattern, union, bodies, vol)

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss", "Mirror Pattern")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("7.49", 10822, features=("Extrude Boss", "Sketch: Polygon", "Extrude Cut", "Axis", "Circular Pattern"))
def p7_49():
    # Hex 19 AF × 37 with six 4 × 4 radial slots from the corners at the
    # top, patterned about the axis. One slot cutter is a new body, the
    # Transform › Pattern (circular, 6) makes the rest, Combine › Subtract.
    hexp = extrude(Sketch(top(0)).polygon_flats((0, 0), 19, 6), (0, 0), 37)
    cutter = extrude(Sketch(top(33)).rect(2.5, -2, 12, 2), (7, 0), 4, new_body=True)
    pattern(cutter, "circular", 6, axis=(0, 1, 0), center=(0, 0, 0))
    tools = [b["id"] for b in bodies() if b["id"] != hexp]
    assert len(tools) == 6, f"expected 6 cutters after the pattern, found {len(tools)}"
    from kit import subtract
    subtract(hexp, tools)
    return hexp


@problem("7.21", 20044, features=("Extrude Boss", "Extrude Cut", "Mirror Pattern"))
def p7_21():
    # Vise jaw 74 × 36 × 8 with two Ø5 holes at (13, 11) and (61, 11), a 90°
    # V-groove 3 deep across the face at y = 25 and another down the middle
    # at x = 37. Built as the left half (its half of the centre groove is a
    # 3 × 3 chamfer on the mating edge), then Transform › Mirror + Union.
    half = extrude(Sketch(front(0)).rect(0, 0, 37, 36).circle((13, 11), 2.5), (20, 20), 8)
    # horizontal V: triangular cutter on the right plane, run along +x
    vcut = Sketch(right(-1)).poly([(-5, 25), (-9, 29), (-9, 21)])
    extrude(vcut, (-7.5, 25), 40, cut=[half])
    # half of the centre V = a 45° chamfer 3 deep on the front edge at x = 37
    chamfer(half, 3.0, edges_where(half, lambda e: abs(e["midpoint"][0] - 37) < 0.5
                                   and abs(e["midpoint"][2] - 8) < 0.5 and e["lengthMM"] > 20))
    before = vol(half)
    mirror(half, (37, 0, 0), (1, 0, 0), keep=True)
    others = [b["id"] for b in bodies() if b["id"] != half]
    assert len(others) == 1, f"mirror should add one body, found {len(others)}"
    union(half, others)
    assert abs(vol(half) - 2 * before) < 1e-3 * before, "mirror + union should double the half"
    return half
