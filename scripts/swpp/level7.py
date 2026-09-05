"""Level 7 — Feature Patterning (48 problems): mirror, linear, circular."""
import math
from kit import (Sketch, front, back, top, bottom, right, left, extrude, revolve, fillet, chamfer, edges_where,
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


@problem("7.4", 421, features=("Revolve", "Extrude Boss", "Pattern: Circular"))
def p7_4():
    # Bead bracelet: a band of outer R14.5 with a 2 (radial) × 1 (axial)
    # section, and 8 bead rings (outer R3, inner R2, 2 wide) whose axes are
    # tangent to the band, centred on the band's centreline r = 13.5. The
    # band passes through each bead's hole without touching it, so the
    # bodies stay separate and the sheet's volume is their sum:
    # 2π·13.5·2 + 8·2π·2.5·2 = 169.6 + 251.3 = 420.9.
    band = revolve(Sketch(front(0)).rect(12.5, -0.5, 14.5, 0.5), (13.5, 0), (0, 0), (0, 1))
    bead = extrude(Sketch(front(-1)).circle((13.5, 0), 3).circle((13.5, 0), 2), (13.5, 2.5), 2)
    pattern(bead, "circular", 8, axis=(0, 1, 0), center=(0, 0, 0), total_angle=315)
    ids = [b["id"] for b in bodies()]
    assert len(ids) == 9, f"expected 9 bodies, found {len(ids)}"
    return ids


@problem("7.15", 17573, features=("Revolve", "Extrude Cut", "Mirror Pattern"))
def p7_15():
    # Ball handle: Ø30 centre ball with flats at +10 / −12 (y), an Ø8 bore
    # down the axis with a 3-wide keyway reaching 6 from the axis; Ø10
    # necks to Ø18 end balls 55 apart (centres ±27.5), each flatted at
    # y = −8 only and drilled Ø5 through. One arm is revolved + drilled,
    # mirrored (Transform › Mirror, keep) and both unioned to the ball.
    from kit import subtract
    yt, yb = 10.0, -12.0
    xb, xt = math.sqrt(225 - yb * yb), math.sqrt(225 - yt * yt)
    ball = revolve(Sketch(front(0)).line((0, yb), (xb, yb)).line((xt, yt), (0, yt)).line((0, yt), (0, yb))
                   .arc((0, 0), 15, math.degrees(math.atan2(yb, xb)), math.degrees(math.atan2(yt, xt))),
                   (5, 0), (0, 0), (0, 1))
    # arm: neck Ø10 from the axis out to the end ball, then the flatted ball
    arm = extrude(Sketch(right(0)).circle((0, 0), 5), (0, 0), 27.5, new_body=True)
    cx, yf = 27.5, -8.0
    xf = math.sqrt(81 - yf * yf)
    revolve(Sketch(front(0)).line((cx, yf), (cx + xf, yf)).line((cx, 9), (cx, yf))
            .arc((cx, 0), 9, math.degrees(math.atan2(yf, xf)), 90),
            (cx + 2, 0), (cx, 0), (0, 1), union=[arm])
    extrude(Sketch(top(-9)).circle((cx, 0), 2.5), (cx, 0), 20, cut=[arm])
    mirror(arm, (0, 0, 0), (1, 0, 0), keep=True)
    arms = [b["id"] for b in bodies() if b["id"] != ball]
    assert len(arms) == 2, f"expected two arms, found {len(arms)}"
    union(ball, arms)
    # Ø8 bore and the 3 × 6 keyway toward −x, straight through
    extrude(Sketch(top(-13)).circle((0, 0), 4), (0, 0), 25, cut=[ball])
    extrude(Sketch(top(-13)).rect(-6, -1.5, 0, 1.5), (-3, 0), 25, cut=[ball])
    return ball


@problem("7.13", 214512, features=("Extrude Boss", "Sketch: Slot", "Sketch: Fillets", "Extrude Cut", "Mirror Pattern"))
def p7_13():
    # Bracket: a 15-thick plate (origin at its bottom face, back edge,
    # centre; z toward the front). Plan: 98 wide at the back, R7 concave
    # rounds into R18 lobes centred on the slot ends (±53.5, 44), a 7-wide
    # slot between them, R22 concave rounds from the lobes' bottom tangent
    # (z 62) into a 58-wide stem ending at z 108. Two 14 × 24 legs (z
    # 108–132) 66 tall from the plate top, the +x one 16 shorter, joined
    # by a 9-thick web (z 99–108) that also stops 16 short at +x; two Ø9
    # holes through the web. Two 16 × 16 lugs (R8 top, Ø5) at the back
    # corners, one mirrored.
    from kit import subtract
    zf7 = 44 - math.sqrt(25 ** 2 - 2.5 ** 2)                 # R7 centre depth (56, 19.125)
    t7 = (53.5 + 18 * (56 - 53.5) / 25, 44 + 18 * (zf7 - 44) / 25)
    a7 = math.degrees(math.atan2(t7[1] - zf7, t7[0] - 56))  # 106.3° in the xz frame
    al = math.degrees(math.atan2(t7[1] - 44, t7[0] - 53.5))  # −73.7°
    sk = Sketch(top(0))                                       # (u, v) = (x, −z)
    sk.line((-49, 0), (49, 0)).line((49, 0), (49, -zf7)).line((-49, -zf7), (-49, 0))
    sk.arc((56, -zf7), 7, -180, -a7).arc((-56, -zf7), 7, 180 - (-a7) - 360, 0)
    sk.arc((53.5, -44), 18, -90, -al).arc((-53.5, -44), 18, 180 + al, 270)
    sk.line((53.5, -62), (51, -62)).line((-51, -62), (-53.5, -62))
    sk.arc((51, -84), 22, 90, 180).arc((-51, -84), 22, 0, 90)
    sk.line((29, -84), (29, -108)).line((29, -108), (-29, -108)).line((-29, -108), (-29, -84))
    sk.slot((-53.5, -44), (53.5, -44), 3.5)
    plate = extrude(sk, (0, -20), 15)
    extrude(Sketch(bottom(15)).rect(-29, 108, -15, 132), (-22, 120), 66, union=[plate])
    extrude(Sketch(bottom(15)).rect(15, 108, 29, 132), (22, 120), 50, union=[plate])
    extrude(Sketch(bottom(0)).rect(-29, 99, 15, 108), (-7, 103.5), 51, union=[plate])
    extrude(Sketch(bottom(0)).rect(15, 99, 29, 108), (22, 103.5), 35, union=[plate])
    for yh in (-40, -18):
        extrude(Sketch(front(98)).circle((0, yh), 4.5), (0, yh), 11, cut=[plate])
    lug = extrude(Sketch(front(0)).line((33, 15), (49, 15)).line((49, 15), (49, 28)).line((33, 28), (33, 15))
                  .arc((41, 28), 8, 0, 180).circle((41, 28), 2.5), (41, 20), 16, new_body=True)
    mirror(lug, (0, 0, 0), (1, 0, 0), keep=True)
    lugs = [b["id"] for b in bodies() if b["id"] != plate]
    assert len(lugs) == 2, f"expected two lugs, found {len(lugs)}"
    union(plate, lugs)
    return plate


@problem("7.16", 91250, features=("Extrude Boss", "Extrude Cut", "Revolve", "Fillets and Chamfers", "Mirror Pattern"))
def p7_16():
    # Yoke: a 10-thick bent strap 28 deep (arms 68 outside, R16/R6
    # concentric bends, floor top at y 5, bottom at −5) embedded 5 into a
    # Ø45 × 12 flange whose top is the origin plane; Ø26 shaft to y −82
    # with an R2 fillet at the flange. Each arm carries a full Ø28 × 17 ear
    # (axis x at y 29, flush inside, 7 overhanging) with a Ø12 hole; one
    # ear is built and mirrored.
    from kit import subtract
    strap = Sketch(front(-14))
    strap.line((34, 29), (34, 11)).arc((18, 11), 16, -90, 0).line((18, -5), (-18, -5)).arc((-18, 11), 16, 180, 270)
    strap.line((-34, 11), (-34, 29)).line((-34, 29), (-24, 29)).line((-24, 29), (-24, 11)).arc((-18, 11), 6, 180, 270)
    strap.line((-18, 5), (18, 5)).arc((18, 11), 6, 270, 360).line((24, 11), (24, 29)).line((24, 29), (34, 29))
    body = extrude(strap, (30, 20), 28)
    ear = extrude(Sketch(right(24)).circle((0, 29), 14), (0, 40), 17, new_body=True)
    mirror(ear, (0, 0, 0), (1, 0, 0), keep=True)
    ears = [b["id"] for b in bodies() if b["id"] != body]
    assert len(ears) == 2, f"expected two ears, found {len(ears)}"
    union(body, ears)
    extrude(Sketch(right(-42)).circle((0, 29), 6), (0, 29), 84, cut=[body])
    extrude(Sketch(top(-12)).circle((0, 0), 22.5), (0, 0), 12, union=[body])
    extrude(Sketch(top(-82)).circle((0, 0), 13), (0, 0), 70, union=[body])
    fillet(body, 2.0, edges_where(body, lambda e: abs(e["midpoint"][1] + 12) < 0.3
                                  and abs(math.hypot(e["midpoint"][0], e["midpoint"][2]) - 13) < 0.3))
    return body


@problem("7.18", 1052931, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Mirror Pattern"))
def p7_18():
    # Two 130 × 140 × 15 end caps (R20 corners, four Ø15 holes 20 in from
    # the edges) 210 apart, joined by a 15-thick hourglass plate (straight
    # edges 75° to the cap faces, R25 concave rounds into an R57 bulge
    # about the hub), a 15 × 55 rib along the axis and a Ø57 × 75 hub with
    # a Ø30 bore. The plate/hub are centred on the origin; the caps sit
    # 25 above the hub top (y −77.5 … 62.5). One cap is mirrored.
    t = math.tan(math.radians(15)); h = math.hypot(t, 1)
    # R25 concave fillet centre: 25 above the 15° edge and 82 from the axis
    # (externally tangent to R57); solved once here for the recipe.
    cx, cz = 37.66279968, 72.83895606
    t1 = (cx + 25 * t / h, cz - 25 / h)          # tangent on the straight edge
    a1, a2 = -75.0, math.degrees(math.atan2(cz * 57 / 82 - cz, cx * 57 / 82 - cx))
    b1 = math.degrees(math.atan2(cz, cx))
    sk = Sketch(top(-7.5))                        # (u, v) = (x, −z); outline symmetric in z
    sk.line((105, 65), (105, -65)).line((-105, 65), (-105, -65))
    for sx in (1, -1):
        for sz in (1, -1):
            sk.line((sx * 105, sz * 65), (sx * t1[0], sz * t1[1]))
            if sx == 1 and sz == 1:
                sk.arc((cx, cz), 25, a2, a1).arc((0, 0), 57, b1, 90)
            elif sx == -1 and sz == 1:
                sk.arc((-cx, cz), 25, 180 - a1, 180 - a2).arc((0, 0), 57, 90, 180 - b1)
            elif sx == -1 and sz == -1:
                sk.arc((-cx, -cz), 25, a2 + 180, a1 + 180).arc((0, 0), 57, 180 + b1, 270)
            else:
                sk.arc((cx, -cz), 25, -a1, -a2).arc((0, 0), 57, 270, 360 - b1)
    body = extrude(sk, (80, 0), 15)
    extrude(Sketch(top(-37.5)).circle((0, 0), 28.5), (20, 0), 75, union=[body])
    extrude(Sketch(front(-7.5)).rect(-105, -27.5, 105, 27.5), (60, 0), 15, union=[body])
    extrude(Sketch(top(-40)).circle((0, 0), 15), (0, 0), 80, cut=[body])
    cap = Sketch(right(105)).rounded_poly([(-65, -77.5), (65, -77.5), (65, 62.5), (-65, 62.5)], 20)
    for u in (-45, 45):
        for v in (-57.5, 42.5):
            cap.circle((u, v), 7.5)
    cap = extrude(cap, (0, 0), 15, new_body=True)
    mirror(cap, (0, 0, 0), (1, 0, 0), keep=True)
    caps = [b["id"] for b in bodies() if b["id"] != body]
    assert len(caps) == 2, f"expected two caps, found {len(caps)}"
    union(body, caps)
    return body


@problem("7.17", 21475, features=("Extrude Boss", "Sketch: Slot", "Sketch: Fillets", "Extrude Cut", "Linear Pattern"))
def p7_17():
    # Bent strap, 6 thick × 40 wide, sketched on its outer/bottom face
    # through the origin: leg 27 tall (R10 outer bend), 52 to the 28° bend
    # (R12 on the bottom, i.e. the inner radius), the slope carrying an R20
    # round end centred 29 past the bend vertex with a Ø26 hole and a
    # 5-wide slit at 42°. Three 6 × 18 (c-c) slots 12 apart, 25 from the
    # leg; an 11 × 8 notch in the leg top. The slots are three seeded cuts.
    c28, s28 = math.cos(math.radians(28)), math.sin(math.radians(28))
    tt = math.tan(math.radians(14))
    xb = 52 - 12 * tt                                   # bottom-face tangent of the R12 bend
    d, n = (c28, -s28), (s28, c28)                      # slope direction, its upward normal
    V = (52.0, 0.0)
    bend_end_deg = 90 - 28
    e_in = (xb + 12 * math.cos(math.radians(bend_end_deg)), -12 + 12 * math.sin(math.radians(bend_end_deg)))
    e_out = (xb + 18 * math.cos(math.radians(bend_end_deg)), -12 + 18 * math.sin(math.radians(bend_end_deg)))
    b_end = (V[0] + 49 * d[0], V[1] + 49 * d[1])
    t_end = (b_end[0] + 6 * n[0], b_end[1] + 6 * n[1])
    sk = Sketch(front(-20))
    sk.line((0, 27), (0, 10)).arc((10, 10), 10, 180, 270).line((10, 0), (xb, 0))
    sk.arc((xb, -12), 12, bend_end_deg, 90).line(e_in, b_end).line(b_end, t_end).line(t_end, e_out)
    sk.arc((xb, -12), 18, bend_end_deg, 90).line((xb, 6), (10, 6)).arc((10, 10), 4, 180, 270)
    sk.line((6, 10), (6, 27)).line((6, 27), (0, 27))
    body = extrude(sk, (3, 20), 40)
    # sloped end: a plane parallel to the slope, 10 above the top face, u along the slope from the ring centre, v = z
    rc = (V[0] + 29 * d[0] + 16 * n[0], V[1] + 29 * d[1] + 16 * n[1], 0.0)
    slope = ((rc[0], rc[1], 0.0), [d[0], d[1], 0.0], [0.0, 0.0, 1.0])       # extrudes along -n (down through the strap)
    extrude(Sketch(slope).circle((0, 0), 13), (0, 0), 30, cut=[body])
    extrude(Sketch(slope).line((0, 20), (22, 20)).line((22, 20), (22, -20)).line((22, -20), (0, -20))
            .arc((0, 0), 20, -90, 90), (21, 0), 30, cut=[body])
    a = math.radians(42); ca, sa = math.cos(a), math.sin(a)
    slit = [(r * ca - w * sa, r * sa + w * ca) for r, w in ((10, -2.5), (25, -2.5), (25, 2.5), (10, 2.5))]
    extrude(Sketch(slope).poly(slit), (17.5 * ca, 17.5 * sa), 30, cut=[body])
    for zc in (-12, 0, 12):
        extrude(Sketch(bottom(7)).slot((25, zc), (43, zc), 3), (34, zc), 8, cut=[body])
    extrude(Sketch(bottom(28)).rect(-1, -5.5, 7, 5.5), (3, 0), 9, cut=[body])
    return body


@problem("7.19", 1244, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Mirror Pattern", "Reference Geometry: Planes"))
def p7_19():
    # 1-thick × 18-wide clip: top flat 40 between bend vertices (origin on
    # the top face), R2 outer bends, legs splayed at equal angles so the
    # sketch-path (outer face) tips are 8 (−x) and 11 (+x) below the top
    # and 52 apart (57.7°), ends square to the legs, R3 on the four tip
    # corners. Two 1-thick ears on
    # the strip edges: base 0…17, hole Ø2 at (12, 6) with an R2 crown, the
    # right edge square to the left one, R2 into the vertical at 17. One
    # ear is built and mirrored across the strip's mid-plane.
    import numpy as np
    th = math.atan2(19, 12)                      # equal leg angles: 8 + 11 drop over 52 − 40
    s, c = math.sin(th), math.cos(th)
    L1, L2 = 8 / s, 11 / s                        # sketch-path (outer face) leg lengths
    tl = 2 * math.tan(th / 2)
    deg = math.degrees(th)
    cl, cr = (-20 + tl, -2.0), (20 - tl, -2.0)
    # left leg: direction (-c, -s), inward normal (s, -c); right leg mirrored
    ol = (-20 - tl * c, -tl * s); pl = (-20 - L1 * c, -L1 * s)
    pli = (pl[0] + s, pl[1] - c); oli = (ol[0] + s, ol[1] - c)
    o_r = (20 + tl * c, -tl * s); pr = (20 + L2 * c, -L2 * s)
    pri = (pr[0] - s, pr[1] - c); ori = (o_r[0] - s, o_r[1] - c)
    sk = Sketch(front(-9))
    sk.line(pl, ol).arc(cl, 2, 90, 90 + deg).line((cl[0], 0), (cr[0], 0)).arc(cr, 2, 90 - deg, 90)
    sk.line(o_r, pr).line(pr, pri).line(pri, ori).arc(cr, 1, 90 - deg, 90).line((cr[0], -1), (cl[0], -1))
    sk.arc(cl, 1, 90, 90 + deg).line(oli, pli).line(pli, pl)
    body = extrude(sk, (0, -0.5), 18)
    fillet(body, 3.0, edges_where(body, lambda e: abs(e["lengthMM"] - 1) < 0.05 and abs(abs(e["midpoint"][2]) - 9) < 0.05
                                  and e["midpoint"][1] < -4))
    # ear profile
    C = np.array([12.0, 6.0]); rt = rf = 2.0
    d = float(np.linalg.norm(C)); phi = math.atan2(C[1], C[0]); al = math.asin(rt / d)
    u = np.array([math.cos(phi + al), math.sin(phi + al)]); v = np.array([u[1], -u[0]])
    T1 = u * math.sqrt(d * d - rt * rt); T2 = C + rt * u
    a = (17 - rf - T2[0] + rf * u[0]) / v[0]; F = T2 + a * v - rf * u; T3 = F + rf * u
    ang = lambda cen, p: math.degrees(math.atan2(p[1] - cen[1], p[0] - cen[0]))
    ear = Sketch(front(8))
    ear.line((0, 0), tuple(T1)).arc(tuple(C), rt, ang(C, T2), ang(C, T1)).line(tuple(T2), tuple(T3))
    ear.arc(tuple(F), rf, 0, ang(F, T3)).line((17, F[1]), (17, 0)).line((17, 0), (0, 0)).circle((12, 6), 1)
    ear = extrude(ear, (12, 2), 1, new_body=True)
    mirror(ear, (0, 0, 0), (0, 0, 1), keep=True)
    ears = [b["id"] for b in bodies() if b["id"] != body]
    assert len(ears) == 2, f"expected two ears, found {len(ears)}"
    union(body, ears)
    return body


@problem("7.20", 14462, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Mirror Pattern"))
def p7_20():
    # Paddle 5 thick: 8 × 24 head, 15-wide neck to 45 from the end, an
    # R11 concave / R5 convex S-transition to the 24-wide blade ending in
    # an R12 round about the Ø9 hole (origin), 130 from the head. The top
    # half is drawn and mirrored across the centreline.
    c1 = (-85.0, 18.5)
    xc = -85 + math.sqrt(16 ** 2 - 11.5 ** 2); c2 = (xc, 7.0)
    t = (c1[0] + (c2[0] - c1[0]) * 11 / 16, c1[1] + (c2[1] - c1[1]) * 11 / 16)
    a1 = math.degrees(math.atan2(t[1] - c1[1], t[0] - c1[0])) % 360
    a2 = math.degrees(math.atan2(t[1] - c2[1], t[0] - c2[0]))
    sk = Sketch(front(0))
    sk.line((-130, 0), (-130, 12)).line((-130, 12), (-122, 12)).line((-122, 12), (-122, 7.5)).line((-122, 7.5), (-85, 7.5))
    sk.arc(c1, 11, 270, a1).arc(c2, 5, 90, a2).line((xc, 12), (0, 12)).arc((0, 0), 12, 0, 90).line((12, 0), (-130, 0))
    half = extrude(sk, (-50, 6), 5)
    mirror(half, (0, 0, 0), (0, 1, 0), keep=True)
    others = [b["id"] for b in bodies() if b["id"] != half]
    assert len(others) == 1
    union(half, others)
    extrude(Sketch(front(-1)).circle((0, 0), 4.5), (0, 0), 7, cut=[half])
    return half


@problem("7.22", 123310, features=("Extrude Boss", "Sketch: Slot", "Extrude Cut", "Mirror Pattern"))
def p7_22():
    # Stadium link 125 × 50 × 25 (R25 ends about hole centres ±37.5).
    # Two 35 × 10 × 5 rails stand 5 proud of the front face along the top
    # and bottom edges (one mirrored), each split by a 15 × 5 notch that
    # runs through the full thickness. On the back, a 24-wide R12-ended
    # pocket 10 deep from the −x end to the left hole. Both holes are
    # Ø20 for half the thickness and Ø15 for the other half, handed: the
    # left one Ø20 from the front, the right one Ø20 from the back.
    slab = extrude(Sketch(front(0)).slot((-37.5, 0), (37.5, 0), 25), (0, 0), 25)
    rail = extrude(Sketch(front(-5)).rect(-17.5, 15, 17.5, 25), (0, 20), 5, new_body=True)
    mirror(rail, (0, 0, 0), (0, 1, 0), keep=True)
    rails = [b["id"] for b in bodies() if b["id"] != slab]
    assert len(rails) == 2, f"expected two rails, found {len(rails)}"
    union(slab, rails)
    for y0, y1 in ((20, 26), (-26, -20)):
        extrude(Sketch(front(-6)).rect(-7.5, y0, 7.5, y1), (0, (y0 + y1) / 2), 32, cut=[slab])
    pocket = Sketch(front(15)).line((-70, 12), (-37.5, 12)).arc((-37.5, 0), 12, -90, 90) \
        .line((-37.5, -12), (-70, -12)).line((-70, -12), (-70, 12))
    extrude(pocket, (-45, 0), 11, cut=[slab])
    extrude(Sketch(front(-1)).circle((-37.5, 0), 10), (-37.5, 0), 13.5, cut=[slab])
    extrude(Sketch(front(12.5)).circle((-37.5, 0), 7.5), (-37.5, 0), 3, cut=[slab])
    extrude(Sketch(front(-1)).circle((37.5, 0), 7.5), (37.5, 0), 13.5, cut=[slab])
    extrude(Sketch(front(12.5)).circle((37.5, 0), 10), (37.5, 0), 13, cut=[slab])
    return slab


@problem("7.26", 882, features=("Revolve", "Extrude Cut", "Mirror Pattern"))
def p7_26():
    # Ø12 × 11 body with 1 × 45° chamfers at both ends, a Ø6 × 3 boss, a
    # Ø4 bore through all 14; two flats 9 apart along the body (rectangle
    # cuts, top and bottom) and a Ø4 cross hole through the flats.
    body = revolve(Sketch(front(0)).poly([(0, 2), (0, 5), (1, 6), (10, 6), (11, 5), (11, 3), (14, 3), (14, 2)]),
                   (5, 4), (0, 0), (1, 0))
    extrude(Sketch(front(-7)).rect(-1, 4.5, 12, 7), (5, 5.5), 14, cut=[body])
    extrude(Sketch(front(-7)).rect(-1, -7, 12, -4.5), (5, -5.5), 14, cut=[body])
    extrude(Sketch(top(-7)).circle((5.5, 0), 2), (5.5, 0), 14, cut=[body])
    return body


@problem("7.28", 148769, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Mirror Pattern"))
def p7_28():
    # U-channel 62 wide × 40 tall × 120 long, 7 walls and floor (floor
    # bottom on the origin plane), 45° × 15 chamfers on the wall tops at
    # both ends; two 12-thick feet at the ends hanging 35 below the floor,
    # 45° × 15 chamfers on their bottom corners and a Ø11 hole 20 up from
    # the bottom. One foot is mirrored.
    ch = extrude(Sketch(front(-60)).poly([(-31, 0), (31, 0), (31, 40), (24, 40), (24, 7), (-24, 7), (-24, 40), (-31, 40)]),
                 (0, 3), 120)
    tri = Sketch(right(-32)).poly([(60, 25), (60, 40), (45, 40)]).poly([(-60, 25), (-60, 40), (-45, 40)])   # u = −z
    extrude(tri, (57, 38), 64, cut=[ch])
    extrude(tri, (-57, 38), 64, cut=[ch])
    foot = extrude(Sketch(front(48)).poly([(-31, 0), (31, 0), (31, -20), (16, -35), (-16, -35), (-31, -20)])
                   .circle((0, -15), 5.5), (0, -5), 12, new_body=True)
    mirror(foot, (0, 0, 0), (0, 0, 1), keep=True)
    feet = [b["id"] for b in bodies() if b["id"] != ch]
    assert len(feet) == 2, f"expected two feet, found {len(feet)}"
    union(ch, feet)
    return ch


@problem("7.30", 1908, features=("Extrude Boss", "Sketch: Offset", "Extrude Cut", "Fillets and Chamfers", "Circular Pattern", "Mirror Pattern"))
def p7_30():
    # 1-thick gasket: outer edge = Ø72 about the origin joined to Ø40 at
    # (43, 0) by R10 concave rounds, inner edge the 7 offset (R17 rounds).
    # Six Ø10 lugs with Ø5 holes centred on the outer edge: at 122°, 52°,
    # 180° and mirrored below, plus one at (63, 0); R3 concave blends at
    # the lug necks. The 122°/52° lugs are mirrored across the x axis.
    from kit import subtract
    d = 43.0
    def fillet_centre(ra, rb, r):
        a = ((ra + r) ** 2 - (rb + r) ** 2 + d * d) / (2 * d)
        return (a, math.sqrt((ra + r) ** 2 - a * a))
    cx, cy = fillet_centre(36, 20, 10)
    ang = lambda c, p: math.degrees(math.atan2(p[1] - c[1], p[0] - c[0]))
    def loop(sk, rb, rs, rf):
        tb = (cx * rb / (rb + rf), cy * rb / (rb + rf))                     # tangent on the big circle
        ts = (d + (cx - d) * rs / (rs + rf), cy * rs / (rs + rf))           # tangent on the small circle
        ab, as_ = ang((0, 0), tb), ang((d, 0), ts)
        sk.arc((0, 0), rb, ab, 360 - ab).arc((d, 0), rs, -as_, as_)
        f0, f1 = ang((cx, cy), tb), ang((cx, cy), ts)                       # both negative; CCW from f0 to f1
        sk.arc((cx, cy), rf, f0, f1).arc((cx, -cy), rf, -f1, -f0)
    sk = Sketch(front(0))
    loop(sk, 36, 20, 10)
    loop(sk, 29, 13, 17)
    plate = extrude(sk, (-32.5, 0), 1)
    centres = [(36 * math.cos(math.radians(a)), 36 * math.sin(math.radians(a))) for a in (122, 52)]
    lugs = [extrude(Sketch(front(0)).circle(c, 5), c, 1, new_body=True) for c in centres]
    for lg in lugs:
        mirror(lg, (0, 0, 0), (0, 1, 0), keep=True)
    for c in ((-36, 0), (63, 0)):
        lugs.append(extrude(Sketch(front(0)).circle(c, 5), c, 1, new_body=True))
    others = [b["id"] for b in bodies() if b["id"] != plate]
    assert len(others) == 6, f"expected six lugs, found {len(others)}"
    union(plate, others)
    all_c = centres + [(x, -y) for x, y in centres] + [(-36, 0), (63, 0)]
    def neck(e):
        m = e["midpoint"]
        if abs(e["lengthMM"] - 1) > 0.05:
            return False
        return any(abs(math.dist((m[0], m[1]), c) - 5) < 0.2 for c in all_c)
    fillet(plate, 3.0, edges_where(plate, neck))
    for c in all_c:
        extrude(Sketch(front(-1)).circle(c, 2.5), c, 3, cut=[plate])
    return plate


@problem("7.32", 101245, features=("Extrude Boss", "Sketch: Slot", "Cut with Surface", "Reference Geometry: Planes", "Mirror Pattern"))
def p7_32():
    # 32 × 32 bar, 90 long plus a 30 tip that tapers in plan from the full
    # width to an R2 round at x 120 (sides from (90, ±16) tangent to the
    # round). R5 slot, centres at x 50 and 66, through. The four corners at
    # the x = 0 end are cut by planes through (0,16,10)-(0,10,16)-(40,16,16):
    # one wedge cutter mirrored across two planes, then one subtract.
    from kit import subtract
    import numpy as np
    from scipy.optimize import brentq
    bar = extrude(Sketch(right(0)).rect(-16, -16, 16, 16), (0, 0), 120)
    xa = brentq(lambda x: x - 2 / math.sin(math.atan2(16, x - 90)) - 118, 115, 140)
    th = math.atan2(16, xa - 90); L = 2 / math.tan(th)
    t1 = (xa - L * math.cos(th), L * math.sin(th)); a = math.degrees(math.atan2(t1[1], t1[0] - 118))
    tip = Sketch(top(-17)).line((90, 16), t1).arc((118, 0), 2, -a, a).line((t1[0], -t1[1]), (90, -16)) \
        .line((90, -16), (130, -16)).line((130, -16), (130, 16)).line((130, 16), (90, 16))
    extrude(tip, (125, 10), 34, cut=[bar])
    extrude(Sketch(top(-17)).slot((50, 0), (66, 0), 5), (58, 0), 34, cut=[bar])
    A, B, D, C = np.array([0, 16, 10.]), np.array([0, 10, 16.]), np.array([40, 16, 16.]), np.array([0, 16, 16.])
    u = (D - A) / np.linalg.norm(D - A); v0 = B - A; v = v0 - v0.dot(u) * u; v /= np.linalg.norm(v)
    if np.cross(u, v).dot(C - A) < 0:
        v = -v
    wedge = extrude(Sketch((A.tolist(), u.tolist(), v.tolist())).rect(-20, -20, 60, 20), (10, 0), 6, new_body=True)
    mirror(wedge, (0, 0, 0), (0, 1, 0), keep=True)
    for w in [b["id"] for b in bodies() if b["id"] != bar]:
        mirror(w, (0, 0, 0), (0, 0, 1), keep=True)
    tools = [b["id"] for b in bodies() if b["id"] != bar]
    assert len(tools) == 4, f"expected four corner wedges, found {len(tools)}"
    subtract(bar, tools)
    return bar


@problem("7.34", 2404013, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Circular Pattern", "Mirror Pattern"))
def p7_34():
    # 20-thick double flange: two R165 lobes centred at (±125, 0) joined by
    # R30 concave rounds, Ø145 bores, R17 bolt holes on R125 at 0/90/180/
    # 270° of each lobe (the two inner ones coincide at the origin). One
    # hole cutter is patterned ×4 about the right lobe and the three
    # off-origin copies mirrored; one subtract with the seven cutters.
    from kit import subtract
    cf = math.sqrt(195 ** 2 - 125 ** 2)
    t1 = (125 - 125 * 165 / 195, cf * 165 / 195)
    a1 = math.degrees(math.atan2(t1[1], t1[0] - 125))          # ≈129.9°
    f1 = math.degrees(math.atan2(t1[1] - cf, t1[0]))            # ≈−50.1°
    sk = Sketch(front(0))
    sk.arc((125, 0), 165, -a1, a1).arc((-125, 0), 165, 180 - a1, 180 + a1)
    sk.arc((0, cf), 30, -180 - f1, f1).arc((0, -cf), 30, -f1, 180 + f1)
    plate = extrude(sk, (125, 100), 20)
    for cx in (125, -125):
        extrude(Sketch(front(-1)).circle((cx, 0), 72.5), (cx, 0), 22, cut=[plate])
    cutter = extrude(Sketch(front(-1)).circle((250, 0), 17), (250, 0), 22, new_body=True)
    pattern(cutter, "circular", 4, axis=(0, 0, 1), center=(125, 0, 0))
    for b in [b for b in bodies() if b["id"] != plate]:
        c = [(lo + hi) / 2 for lo, hi in zip(*b["bounds"])]
        if abs(c[0]) > 1:
            mirror(b["id"], (0, 0, 0), (1, 0, 0), keep=True)
    tools = [b["id"] for b in bodies() if b["id"] != plate]
    assert len(tools) == 7, f"expected seven hole cutters, found {len(tools)}"
    subtract(plate, tools)
    return plate


@problem("7.35", 1157728, features=("Extrude Boss", "Mirror Pattern"))
def p7_35():
    # 170 × 135 block in three bands. Middle band (75, mid-plane): a wedge
    # rising at 41° from the origin to a 65 plateau that runs to the back.
    # Outer bands (30 each): 35 tall, then a 35° slope up to 95 at the back
    # (from x = 170 − 60/tan 35°). One outer band is mirrored.
    xp = 65 / math.tan(math.radians(41))
    xs = 170 - 60 / math.tan(math.radians(35))
    mid = extrude(Sketch(front(-37.5)).poly([(0, 0), (170, 0), (170, 65), (xp, 65)]), (120, 30), 75)
    side = extrude(Sketch(front(37.5)).poly([(0, 0), (170, 0), (170, 95), (xs, 35), (0, 35)]), (60, 17), 30, new_body=True)
    mirror(side, (0, 0, 0), (0, 0, 1), keep=True)
    sides = [b["id"] for b in bodies() if b["id"] != mid]
    assert len(sides) == 2, f"expected two side bands, found {len(sides)}"
    union(mid, sides)
    return mid


@problem("7.36", 82315, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Mirror Pattern"))
def p7_36():
    # Clevis: 40 × 60 × 75 block with an R20 round top, Ø25 hole at the arc
    # centre, two 15-wide slots 65 deep from the top (R5 bottom corners)
    # leaving three 10 fingers; R1 rounds on the fingers' D-profile edges.
    # One slot cutter is mirrored across the mid-plane.
    from kit import subtract
    body = extrude(Sketch(front(-30)).line((0, 0), (40, 0)).line((40, 0), (40, 55)).arc((20, 55), 20, 0, 180)
                   .line((0, 55), (0, 0)).circle((20, 55), 12.5), (20, 20), 60)
    slot = Sketch(right(-1)).rounded_poly([(-20, 10), (-5, 10), (-5, 80), (-20, 80)], [5, 5, 0, 0])   # u = −z: slot z 5…20
    cutter = extrude(slot, (-12.5, 40), 42, new_body=True)
    mirror(cutter, (0, 0, 0), (0, 0, 1), keep=True)
    tools = [b["id"] for b in bodies() if b["id"] != body]
    assert len(tools) == 2, f"expected two slot cutters, found {len(tools)}"
    subtract(body, tools)
    def d_edge(e):
        z = abs(e["midpoint"][2]); L = e["lengthMM"]
        return min(abs(z - 5), abs(z - 20), abs(z - 30)) < 0.3 and (abs(L - 40) < 0.3 or abs(L - 55) < 0.3 or abs(L - 20 * math.pi) < 0.3)
    # "R1 TYP": D-profile loops, hole rims and the bottom long edges in ONE
    # call (a second call on the bottom edges fails once they end on blends)
    fillet(body, 1.0, edges_where(body, lambda e: d_edge(e) or abs(e["lengthMM"] - 25 * math.pi) < 0.3
                                  or (abs(e["lengthMM"] - 60) < 0.3 and abs(e["midpoint"][1]) < 0.1)))
    return body


@problem("7.38", 3043291, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Linear Pattern"))
def p7_38():
    # Tag: 230 × 450 × 15 plate (origin at mid-height on the boss-side
    # face) with a 51-tall gable above the shoulders, R20 on the shoulders
    # and bottom corners, Ø18 hole 20 below the peak. A 127 × 250 × 50
    # boss on the −z face from 65 above the bottom, its top chamfered 45°
    # (50 × 50); six 5-wide slots at 20 pitch, 11 in from the boss ends,
    # 40 deep from the boss top and 40 out from the plate (one cutter,
    # Transform › Pattern linear ×6, one subtract).
    from kit import subtract
    plate = extrude(Sketch(front(0)).rounded_poly([(-115, -225), (115, -225), (115, 225), (0, 276), (-115, 225)],
                                                  [20, 20, 20, 0, 20]).circle((0, 256), 9), (0, 0), 15)
    extrude(Sketch(back(0)).rect(-63.5, -160, 63.5, 90), (0, 0), 50, union=[plate])
    extrude(Sketch(right(-70)).poly([(0, 90), (50, 40), (50, 90)]), (40, 80), 140, cut=[plate])
    cutter = extrude(Sketch(bottom(100)).rect(-52.5, -40, -47.5, 0), (-50, -20), 50, new_body=True)
    pattern(cutter, "linear", 6, axis=(1, 0, 0), spacing=20)
    tools = [b["id"] for b in bodies() if b["id"] != plate]
    assert len(tools) == 6, f"expected six slot cutters, found {len(tools)}"
    subtract(plate, tools)
    return plate


@problem("7.39", 79684, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Mirror Pattern"))
def p7_39():
    # Diamond base 11 thick: R14 ends about (0, ±40) with Ø12 holes, flat
    # sides at x = ±35 over the 32-wide tabs, tangent edges between. Two
    # 11-thick tabs (x 24…35) 32 wide with a full R16 top about the Ø12
    # hole 35 above the bottom; one tab mirrored. R3 on the base's top
    # outline and the tabs' vertical edges.
    C = (0.0, 40.0); P = (35.0, 16.0)
    d = math.dist(P, C); ang = math.atan2(C[1] - P[1], C[0] - P[0]); al = math.asin(14 / d)
    L = math.sqrt(d * d - 196); t = ang - al
    T = (P[0] + L * math.cos(t), P[1] + L * math.sin(t))
    a0 = math.degrees(math.atan2(T[1] - C[1], T[0] - C[0]))
    sk = Sketch(top(0))                                          # (u, v) = (x, −z); outline symmetric
    sk.line((35, -16), (35, 16)).line((35, 16), T).arc(C, 14, a0, 180 - a0).line((-T[0], T[1]), (-35, 16))
    sk.line((-35, 16), (-35, -16)).line((-35, -16), (-T[0], -T[1])).arc((0, -40), 14, 180 + a0, 360 - a0)
    sk.line((T[0], -T[1]), (35, -16)).circle((0, 40), 6).circle((0, -40), 6)
    base = extrude(sk, (0, 0), 11)
    tab = extrude(Sketch(right(24)).line((-16, 11), (16, 11)).line((16, 11), (16, 35)).arc((0, 35), 16, 0, 180)
                  .line((-16, 35), (-16, 11)).circle((0, 35), 6), (0, 20), 11, new_body=True)
    mirror(tab, (0, 0, 0), (1, 0, 0), keep=True)
    tabs = [b["id"] for b in bodies() if b["id"] != base]
    assert len(tabs) == 2, f"expected two tabs, found {len(tabs)}"
    union(base, tabs)
    diag = math.dist(P, T); arcl = 14 * math.radians(180 - 2 * a0)
    # as the hint says: the base's top outline first, the tabs' vertical
    # edges second (one call with both fails validity checking in the app)
    fillet(base, 3.0, edges_where(base, lambda e: abs(e["midpoint"][1] - 11) < 0.1
                                  and (abs(e["lengthMM"] - diag) < 0.3 or abs(e["lengthMM"] - arcl) < 0.3)))
    fillet(base, 3.0, edges_where(base, lambda e: abs(e["lengthMM"] - 24) < 0.3 and abs(abs(e["midpoint"][2]) - 16) < 0.1
                                  and (abs(abs(e["midpoint"][0]) - 35) < 0.1 or abs(abs(e["midpoint"][0]) - 24) < 0.1)))
    return base


@problem("7.43", 749997, features=("Extrude Boss", "Extrude Cut", "Fillets and Chamfers", "Reference Geometry: Planes", "Mirror Pattern"))
def p7_43():
    # 225 × 130 × 10 plate (origin on its top face centre) with 13-thick
    # end walls hanging 80 below the top (R13 outer-bottom rounds), a
    # Ø62/Ø50 boss 65 tall with a 5 × 45° chamfer at its foot, and four
    # 15-thick gussets 13 in from the plate edges: R20 round about a Ø16
    # hole 40 outboard of the wall, tangent edge into the wall's round.
    # One gusset, mirrored across both planes (primary + secondary).
    C1, C2 = (-152.5, -20.0), (-99.5, -67.0)
    d = math.dist(C1, C2); base = math.atan2(C2[1] - C1[1], C2[0] - C1[0]); al = math.asin(7 / d)
    n = base - (math.pi / 2 + al); nd = math.degrees(n) % 360
    T1 = (C1[0] + 20 * math.cos(n), C1[1] + 20 * math.sin(n)); T2 = (C2[0] + 13 * math.cos(n), C2[1] + 13 * math.sin(n))
    plate = extrude(Sketch(bottom(0)).rect(-112.5, -65, 112.5, 65), (0, 0), 10)
    wall = Sketch(front(-65)).line((-112.5, 0), (-99.5, 0)).line((-99.5, 0), (-99.5, -80)).arc(C2, 13, 180, 270) \
        .line((-112.5, -67), (-112.5, 0))
    extrude(wall, (-106, -30), 130, union=[plate])
    wall2 = Sketch(front(-65)).line((112.5, 0), (99.5, 0)).line((99.5, 0), (99.5, -80)).arc((99.5, -67), 13, 270, 360) \
        .line((112.5, -67), (112.5, 0))
    extrude(wall2, (106, -30), 130, union=[plate])
    extrude(Sketch(top(0)).circle((0, 0), 31), (28, 0), 65, union=[plate])
    revolve(Sketch(front(0)).poly([(31, 0), (36, 0), (31, 5)]), (32.5, 1), (0, 0), (0, 1), union=[plate])
    extrude(Sketch(top(-11)).circle((0, 0), 25), (0, 0), 80, cut=[plate])
    ear = Sketch(front(37)).line((-112.5, 0), (-152.5, 0)).arc(C1, 20, 90, nd).line(T1, T2).arc(C2, 13, 180, nd) \
        .line((-112.5, -67), (-112.5, 0)).circle(C1, 8)
    ear = extrude(ear, (-135, -30), 15, new_body=True)
    mirror(ear, (0, 0, 0), (1, 0, 0), keep=True)
    for b in [b["id"] for b in bodies() if b["id"] != plate]:
        mirror(b, (0, 0, 0), (0, 0, 1), keep=True)
    ears = [b["id"] for b in bodies() if b["id"] != plate]
    assert len(ears) == 4, f"expected four gussets, found {len(ears)}"
    union(plate, ears)
    return plate
