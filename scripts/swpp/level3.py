"""Level 3 — Global Variables & Sketch Patterns (20 problems). The app has
no sketch-pattern tool; repeated profile features are laid out by the
recipe as one polygon (the same shape a sketch pattern would leave)."""
import math
from kit import Sketch, front, top, right, plane_at, extrude

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


@problem("3.1", 38144, features=("Extrude Boss", "Extrude Cut", "Sketch pattern (as polygon)"))
def p3_1():
    # Rack: bar 164 centre to centre, 16 wide, 12 tall; 24 teeth 2.5 tall
    # (top 2, 40° included, pitch 6) centred on it; Ø16 bosses 20 tall
    # (4 below the bar) at the ends with Ø7.5 through. 6275 + 31 488 +
    # 2792 − 2412 (bar inside the bosses) = 38 143.
    half = 2.5 * math.tan(math.radians(20))
    pts = [(-82, 0), (82, 0), (82, 12)]
    for k in range(24):
        c = 69 - 6 * k                         # right to left
        pts += [(c + 1 + half, 12), (c + 1, 14.5), (c - 1, 14.5), (c - 1 - half, 12)]
    pts.append((-82, 12))
    body = extrude(Sketch(front(0)).poly(pts), (0, 6), 8, symmetric=True)
    # Solid bosses first, holes after the union: the bar ends at the boss
    # centres and would otherwise fill half of each hole (+530 mm³).
    for x in (-82, 82):
        extrude(Sketch(top(-4)).circle((x, 0), 8), (x, 0), 20, union=[body])
    for x in (-82, 82):
        extrude(Sketch(top(16)).circle((x, 0), 3.75), (x, 0), -20, cut=[body])
    return body


@problem("3.2", 98479, features=("Extrude Boss", "Sketch pattern (as polygon)"))
def p3_2():
    # Heat sink 80 long: base 5 thick, 12 fins 30 tall, 1 wide at the top,
    # flanks 3° off vertical (87°/93°), gaps 1 at the base — the base is
    # 12 × 4.1445 + 11 = 60.73 wide. 24 293 + 74 081 = 98 374.
    t = 30 * math.tan(math.radians(3))
    fb = 1 + 2 * t                               # fin width at the base
    W = 12 * fb + 11
    pts = [(0, 0), (W, 0), (W, 5)]
    x = W
    for i in range(12):
        pts += [(x, 5), (x - t, 35), (x - t - 1, 35), (x - fb, 5)]
        x -= fb + 1
    pts.append((0, 5))
    return extrude(Sketch(front(0)).poly(pts), (W / 2, 2.5), 80)


def _lobes_concave(sk, rl, rc, d, angles_deg):
    """Closed outline of lobes (radius rl, centred d out at angles_deg)
    joined by concave arcs of radius rc tangent to neighbouring lobes."""
    n = len(angles_deg)
    u = lambda a: (math.cos(math.radians(a)), math.sin(math.radians(a)))
    ang = lambda v: math.degrees(math.atan2(v[1], v[0])) % 360
    L = [(d * u(a)[0], d * u(a)[1]) for a in angles_deg]
    # Concave-arc centres on each bisector, (rl + rc) from both lobes.
    C, T = [], []
    for i in range(n):
        j = (i + 1) % n
        half = (angles_deg[j] - angles_deg[i]) % 360 / 2
        mid = angles_deg[i] + half
        b = 2 * d * math.cos(math.radians(half))
        c = (rl + rc) ** 2 - d * d
        dc = (b + math.sqrt(b * b + 4 * c)) / 2
        Ci = (dc * u(mid)[0], dc * u(mid)[1])
        C.append(Ci)
        Ti = (L[i][0] + rl * (Ci[0] - L[i][0]) / (rl + rc), L[i][1] + rl * (Ci[1] - L[i][1]) / (rl + rc))
        Tj = (L[j][0] + rl * (Ci[0] - L[j][0]) / (rl + rc), L[j][1] + rl * (Ci[1] - L[j][1]) / (rl + rc))
        T.append((Ti, Tj))
        a1, a2 = ang((Ti[0] - Ci[0], Ti[1] - Ci[1])), ang((Tj[0] - Ci[0], Tj[1] - Ci[1]))
        lo, hi = sorted((a1, a2))
        if hi - lo > 180:
            lo, hi = hi, lo + 360
        sk.arc(Ci, rc, lo, hi)
    for i in range(n):
        start = T[i - 1][1]          # tangent with the previous concave arc
        end = T[i][0]                # tangent with the next one
        s2, e2 = ang((start[0] - L[i][0], start[1] - L[i][1])), ang((end[0] - L[i][0], end[1] - L[i][1]))
        if e2 < s2:
            e2 += 360
        aa = angles_deg[i] % 360
        if not (s2 <= aa <= e2 or s2 <= aa + 360 <= e2):
            s2, e2 = e2 % 360, s2 + 360 if s2 < e2 % 360 else s2
        sk.arc(L[i], rl, s2, e2)
    return sk


@problem("3.5", 132122, features=("Extrude Boss", "Extrude Cut", "Sketch pattern (as polygon)"))
def p3_5():
    # Disc Ø115 × 15, Ø32 bore, 3 × Ø15 on Ø80 at 30°/150°/270°, three
    # 10 × 8 rim notches at 90°/210°/330°.
    sk = Sketch(top(0)).circle((0, 0), 57.5).circle((0, 0), 16)
    for a in (30, 150, 270):
        sk.circle((40 * math.cos(math.radians(a)), 40 * math.sin(math.radians(a))), 7.5)
    body = extrude(sk, (50, 0), 15)
    for a in (90, 210, 330):
        r = math.radians(a)
        plane = plane_at((0, 0, 0), (math.cos(r), 0, -math.sin(r)), (0, 0, -1) if False else (-math.sin(r), 0, -math.cos(r)))
        # notch as a rect in the top plane instead: rotate the rect corners
        pts = []
        for (x, y) in ((49.5, -5), (70, -5), (70, 5), (49.5, 5)):
            pts.append((x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)))
        extrude(Sketch(top(15)).poly(pts), (55 * math.cos(r), 55 * math.sin(r)), -15, cut=[body])
    return body


@problem("3.6", 108939, features=("Extrude Boss", "Sketch: Polygon", "Sketch pattern (as arcs)"))
def p3_6():
    # Five R15 lobes on Ø125 (one at the top) joined by concave R50 arcs;
    # Ø16 holes at the lobe centres; a pentagon hole inscribed in Ø35; 10 thick.
    angles = [90 + 72 * k for k in range(5)]
    sk = _lobes_concave(Sketch(top(0)), 15, 50, 62.5, angles)
    for a in angles:
        sk.circle((62.5 * math.cos(math.radians(a)), 62.5 * math.sin(math.radians(a))), 8)
    # Ø35 is the pentagon's INSCRIBED circle (SOLIDWORKS' default); on the
    # circumscribed reading the part is 3.5 % heavy.
    sk.polygon_flats((0, 0), 35, 5, 90)
    return extrude(sk, (0, 30), 10)


@problem("3.7", 407164, features=("Extrude Boss", "Sketch pattern (as circles)"))
def p3_7():
    # Plate 260 × 180 × 10, R15 corners, 12 × Ø25 at x = 40 + 60k, y = 45 + 45k.
    sk = Sketch(top(0)).rounded_poly([(0, 0), (260, 0), (260, 180), (0, 180)], 15)
    for i in range(4):
        for j in range(3):
            sk.circle((40 + 60 * i, 45 + 45 * j), 12.5)
    return extrude(sk, (20, 20), 10)


@problem("3.8", 42645, features=("Extrude Boss", "Extrude Cut", "Sketch pattern (as circles)"))
def p3_8():
    # Ring Ø115 / Ø90 × 10 with six Ø16 bosses centred on the outer edge
    # at 0°/60°/…, each with a Ø9 hole. 40 251 + 6 × 103.7 × 10 − 3 817.
    body = extrude(Sketch(top(0)).circle((0, 0), 57.5).circle((0, 0), 45), (50, 0), 10)
    for k in range(6):
        a = math.radians(60 * k)
        c = (57.5 * math.cos(a), 57.5 * math.sin(a))
        extrude(Sketch(top(0)).circle(c, 8), c, 10, union=[body])
    for k in range(6):
        a = math.radians(60 * k)
        c = (57.5 * math.cos(a), 57.5 * math.sin(a))
        extrude(Sketch(top(10)).circle(c, 4.5), c, -10, cut=[body])
    return body


@problem("3.4", 9921, features=("Extrude Boss", "Sketch: Offset", "Sketch: Fillets", "Sketch pattern (as polygon)"))
def p3_4():
    # T-slot extrusion 110 long. Section: 12 square (half-size 1.5 lip + 2
    # cavity + 2.5 core, the overall size is not printed); four T-slots
    # with a 2-wide throat, 1.5 lips, a 2-tall cavity whose 45° sides run
    # down to the 5-square core, leaving 1.5-wide diagonal webs between
    # neighbouring cavities (which fixes the cavity's top half-width at
    # 4.5 − 1.5/√2 = 3.44); Ø2 centre hole; 36 × R0.25 on every corner.
    # Closed form 9920.
    a = 4.5 - 1.5 / math.sqrt(2); b = a - 2
    S = [(1, 6), (1, 4.5), (a, 4.5), (b, 2.5), (-b, 2.5), (-a, 4.5), (-1, 4.5), (-1, 6)]
    rot = lambda p, k: p if k == 0 else rot((-p[1], p[0]), k - 1)
    pts = []
    for k in range(4):
        pts.append(rot((6, 6), k))
        pts += [rot(p, k) for p in S]
    sk = Sketch(front(0)).rounded_poly(pts, 0.25).circle((0, 0), 1)
    return extrude(sk, (0, 1.75), 110)


@problem("3.3", 81601, features=("Extrude Boss", "Extrude Cut", "Sketch pattern (as polygon)", "Fillet"))
def p3_3():
    # Spoked gear, callout reading: 24 straight-flanked teeth (top land 4,
    # height 6, flanks 20° off radial = the 40° included angle) on a Ø96
    # root circle, tips Ø108, teeth 14 wide (section: 2 in from each face
    # of the 18 rim); rim R41.5..R48 (6.50) 18 wide; web recessed 1 per
    # side (16); eight 5-wide spokes; hub R14, 18 wide, Ø16 bore with a
    # 3-wide keyway to 10; 32 × R2 at the spoke roots. Closed form ≈
    # 70 400 (−14 %): the printed volume needs more web than these
    # callouts give (a rim ~10 wide would close it; the sheet says 6.50).
    from kit import fillet, edges_where
    half = 2 + 6 * math.tan(math.radians(20))          # root half-width 4.18
    a_top = math.degrees(math.atan2(2, 54)); a_root = math.degrees(math.atan2(half, 48))
    sk = Sketch(top(0))
    for k in range(24):
        c = 15 * k
        P = lambda r, a: (r * math.cos(math.radians(a)), r * math.sin(math.radians(a)))
        # root arc from the previous tooth's flank end to this one, then the tooth
        sk.arc((0, 0), 48, c - 15 + a_root, c - a_root)
        sk.line(P(48, c - a_root), P(54, c - a_top))
        sk.line(P(54, c - a_top), P(54, c + a_top))
        sk.line(P(54, c + a_top), P(48, c + a_root))
    sk.circle((0, 0), 47)                              # inner loop: the seed region is the teeth, not the disc
    teeth = extrude(sk, (51, 0), 7, symmetric=True)
    rim = extrude(Sketch(top(-9)).circle((0, 0), 48).circle((0, 0), 41.5), (45, 0), 18, union=[teeth])
    body = rim
    hub = Sketch(top(-9)).circle((0, 0), 14)
    extrude(hub, (11, 0), 18, union=[body])
    for k in range(8):
        a = math.radians(45 * k)
        d = (math.cos(a), math.sin(a)); n = (-math.sin(a), math.cos(a))
        pts = [(10 * d[0] + 2.5 * n[0], 10 * d[1] + 2.5 * n[1]), (44 * d[0] + 2.5 * n[0], 44 * d[1] + 2.5 * n[1]),
               (44 * d[0] - 2.5 * n[0], 44 * d[1] - 2.5 * n[1]), (10 * d[0] - 2.5 * n[0], 10 * d[1] - 2.5 * n[1])]
        extrude(Sketch(top(-8)).poly(pts), (27 * d[0], 27 * d[1]), 16, union=[body])
    # bore with keyway: Ø16 + a 3-wide slot up to 10 from the centre
    bore = (Sketch(top(9)).line((-1.5, math.sqrt(64 - 2.25)), (-1.5, 10)).line((-1.5, 10), (1.5, 10))
            .line((1.5, 10), (1.5, math.sqrt(64 - 2.25)))
            .arc((0, 0), 8, math.degrees(math.atan2(math.sqrt(64 - 2.25), -1.5)),
                 math.degrees(math.atan2(math.sqrt(64 - 2.25), 1.5)) + 360))
    extrude(bore, (0, 0), -18, cut=[body])
    # R2 at the 32 spoke-root corners (vertical edges 16 long at R14 and R41.5)
    rad = lambda e: math.hypot(e["midpoint"][0], e["midpoint"][2])
    ids = edges_where(body, lambda e: abs(e["midpoint"][1]) < 0.6 and 10 < e["lengthMM"] < 18
                      and (abs(rad(e) - math.sqrt(14 ** 2 - 2.5 ** 2)) < 0.6 or abs(rad(e) - math.sqrt(41.5 ** 2 - 2.5 ** 2)) < 0.6))
    if ids:
        fillet(body, 2.0, ids)
    return body
