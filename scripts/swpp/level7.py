"""Level 7 — Feature Patterning (48 problems): mirror, linear, circular."""
import math
from kit import (Sketch, front, top, bottom, right, left, extrude, revolve, fillet, chamfer, edges_where,
                 mirror, pattern, union, bodies, vol)

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss", "Mirror Pattern")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("7.29", 103384, features=("Extrude Boss", "Sketch: Slot", "Extrude Cut", "Mirror Pattern"))
def p7_29():
    # Two 10-thick stadium plates (R25 ends 75 apart, Ø30 holes at the
    # centres) 55 apart outside-to-outside, joined by a 10 × 50 web; R2 in
    # the web corners, R1 round the plates' outline edges.
    from kit import subtract
    top_plate = extrude(Sketch(top(17.5)).slot((-37.5, 0), (37.5, 0), 25)
                        .circle((-37.5, 0), 15).circle((37.5, 0), 15), (0, 20), 10)
    web = extrude(Sketch(top(-17.5)).rect(-5, -25, 5, 25), (0, 0), 35, union=[top_plate])
    mirror(top_plate, (0, 0, 0), (0, 1, 0), keep=True)
    others = [b["id"] for b in bodies() if b["id"] != top_plate]
    assert len(others) == 1
    union(top_plate, others)
    # the mirrored copy carries the web too; overlapping union is fine
    fillet(top_plate, 2.0, edges_where(top_plate, lambda e: abs(abs(e["midpoint"][0]) - 5) < 0.5
                                       and abs(abs(e["midpoint"][1]) - 17.5) < 0.5 and e["lengthMM"] > 40))
    fillet(top_plate, 1.0, edges_where(top_plate, lambda e: abs(abs(e["midpoint"][1]) - 27.5) < 0.5
                                       and math.hypot(abs(e["midpoint"][0]) - 37.5 if abs(e["midpoint"][0]) > 37.5 else 0,
                                                      e["midpoint"][2]) > 24.5 - 1e-6 or
                                       (abs(abs(e["midpoint"][1]) - 17.5) < 0.5 and abs(abs(e["midpoint"][2]) - 25) < 0.5 and e["lengthMM"] > 70)))
    return top_plate


@problem("7.31", 179795, features=("Extrude Boss", "Sketch: Slot", "Sketch: Offset", "Extrude Cut", "Mirror Pattern"))
def p7_31():
    # Channel 150 long: 90 wide, 64 tall, 5-thick base and walls, T-caps
    # 25 × 5 on the walls; an R8 slot 65 between centres through the base.
    prof = Sketch(front(-75)).poly([
        (-45, 0), (45, 0), (45, 59), (52.5, 59), (52.5, 64), (27.5, 64), (27.5, 59), (40, 59),
        (40, 5), (-40, 5), (-40, 59), (-27.5, 59), (-27.5, 64), (-52.5, 64), (-52.5, 59), (-45, 59)])
    body = extrude(prof, (0, 2.5), 150)
    cutter = Sketch(top(-1)).slot((0, -32.5), (0, 32.5), 8)
    extrude(cutter, (0, 0), 7, cut=[body])
    return body


@problem("7.48", 6277, features=("Extrude Cut", "Revolve", "Sketch: Slot", "Circular Pattern"))
def p7_48():
    # Pin: Ø17 base tapering 6° up 34 to a Ø15 × 10 head at the top (44);
    # a 3-wide cross slot, 4 deep to an R1.5 round bottom, patterned twice.
    from kit import subtract
    t = math.tan(math.radians(6))
    r34 = 8.5 - 34 * t
    pin = revolve(Sketch(front(0)).poly([(0, 0), (8.5, 0), (r34, 34), (7.5, 34), (7.5, 44), (0, 44)]),
                  (3, 10), (0, 0), (0, 1))
    cutter = extrude(Sketch(front(-10)).slot((0, 40), (0, 47), 1.5), (0, 43), 20, new_body=True)
    # totalAngle is the first→last sweep: two instances 90° apart
    pattern(cutter, "circular", 2, axis=(0, 1, 0), center=(0, 0, 0), total_angle=90)
    tools = [b["id"] for b in bodies() if b["id"] != pin]
    assert len(tools) == 2, f"expected 2 slot cutters, found {len(tools)}"
    subtract(pin, tools)
    return pin


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
