"""Level 16 — Global Variables, Link Values and Equations (20 problems).
Each sheet prints several volumes for different variable values; the
runner scores every configuration in one row (meta["configs"])."""
import math
from kit import Sketch, front, top, extrude

PROBLEMS = {}


def problem(pid, configs, unit="mm", features=("Extrude Boss",)):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": configs[0][1], "configs": list(configs), "unit": unit,
                          "features": list(features)}, fn)
        return fn
    return deco


@problem("16.2", [("80x50x500", 847654.9), ("80x50x1000", 1704734.5),
                  ("120x50x1000", 2092953.5), ("120x50x1000_no_holes", 2114159.3)],
         features=("Extrude Boss", "Extrude Cut", "Equations (as recipe)"))
def p16_2():
    # U-channel: web WIDTH wide, 10 thick, flanges 10 thick to 60 (50 inside),
    # bent corners inner R5 / outer R15; three Ø(WIDTH/4) holes through the
    # web at 0.2/0.5/0.8 of LENGTH. The table's differences pin it: the
    # holes are 3π(W/8)²·10 and the section is 10W + 914.16 mm².
    out = []
    for k, (L, W, holes) in enumerate(((500, 80, True), (1000, 80, True), (1000, 120, True), (1000, 120, False))):
        ox = k * 400
        pts = [(ox, 0), (ox + W, 0), (ox + W, 60), (ox + W - 10, 60), (ox + W - 10, 10),
               (ox + 10, 10), (ox + 10, 60), (ox, 60)]
        body = extrude(Sketch(front(0)).rounded_poly(pts, [15, 15, 0, 0, 5, 5, 0, 0]), (ox + W / 2, 5), L)
        if holes:
            for f in (0.2, 0.5, 0.8):
                c = (ox + W / 2, -f * L)
                extrude(Sketch(top(0)).circle(c, W / 8), c, 10, cut=[body])
        out.append([body])
    return out


@problem("16.3", [("A=1200", 117120000), ("A=900", 65880000)],
         features=("Extrude Boss", "Equations (as recipe)"))
def p16_3():
    # T-slot plate 1000 long: width A, height B = A/10; slots C = B/3 deep
    # at the neck (F = 4C/5 wide), head E = 2B/3 wide down to G = 3B/5;
    # seven slots at pitch D = B + C starting B in from the edge. The sheet
    # prints cm³ (117 120 and 65 880).
    out = []
    for k, A in enumerate((1200, 900)):
        B = A / 10; C = B / 3; D = B + C; E = 2 * B / 3; F = 4 * C / 5; G = 3 * B / 5
        ox = k * 1500
        n = int(round((A - 2 * B) / D)) + 1
        centres = [B + i * D for i in range(n)]
        pts = [(ox, 0), (ox + A, 0), (ox + A, B)]
        for xc in reversed(centres):
            x = ox + xc
            pts += [(x + F / 2, B), (x + F / 2, B - C), (x + E / 2, B - C), (x + E / 2, B - G),
                    (x - E / 2, B - G), (x - E / 2, B - C), (x - F / 2, B - C), (x - F / 2, B)]
        pts.append((ox, B))
        out.append([extrude(Sketch(front(0)).poly(pts), (ox + A / 2, B * 0.2), 1000)])
    return out


def _cutout(sk, alpha, C, B, w, rf):
    """One radial cutout: chord w at radius C, radial sides, outer arc at
    radius B with rounds rf at its two corners; centred on angle alpha (deg)."""
    a = math.radians(alpha)
    phi = math.asin(w / 2 / C)
    psi = phi - math.asin(rf / (B - rf))
    u = lambda t: (math.cos(t), math.sin(t))
    ang = lambda v: math.degrees(math.atan2(v[1], v[0])) % 360
    sk.arc((0, 0), C, math.degrees(a - phi), math.degrees(a + phi))
    sk.arc((0, 0), B, math.degrees(a - psi), math.degrees(a + psi))
    for sgn in (-1, 1):
        ray = u(a + sgn * phi)
        Fc = ((B - rf) * u(a + sgn * psi)[0], (B - rf) * u(a + sgn * psi)[1])
        t = Fc[0] * ray[0] + Fc[1] * ray[1]
        foot = (t * ray[0], t * ray[1])
        sk.line((C * ray[0], C * ray[1]), foot)
        a1, a2 = ang((foot[0] - Fc[0], foot[1] - Fc[1])), math.degrees(a + sgn * psi) % 360
        lo, hi = sorted((a1, a2))
        if hi - lo > 180:
            lo, hi = hi, lo + 360
        sk.arc(Fc, rf, lo, hi)
    return sk


@problem("16.4", [("SMALL", 19491), ("MEDIUM", 28052), ("LARGE", 34084)],
         features=("Extrude Boss", "Extrude Cut", "Equations (as recipe)", "Pattern (as recipe)"))
def p16_4():
    # Ring radius A, bore 0.6A, 5 thick; E = round(0.2A) cutouts between
    # radii 0.7A and 0.9A, 10 wide at the inner edge with radial sides and
    # R2 rounds at the outer corners.
    out = []
    for k, A in enumerate((50, 60, 66)):
        B, C, D, E = 0.9 * A, 0.7 * A, 0.6 * A, int(round(0.2 * A))
        ox = k * 200
        ring = extrude(Sketch(top(0)).circle((ox, 0), A).circle((ox, 0), D), (ox + (A + D) / 2, 0), 5)
        for i in range(E):
            alpha = 90 + 360 * i / E
            sk = Sketch(top(5))
            # build about the origin, then shift by ox: the helper takes the
            # centre at (0, 0), so pass a shifted sketch through a wrapper.
            _cutout_shifted(sk, alpha, C, B, 10, 2, ox)
            r = (B + C) / 2
            seed = (ox + r * math.cos(math.radians(alpha)), r * math.sin(math.radians(alpha)))
            extrude(sk, seed, -5, cut=[ring])
        out.append([ring])
    return out


def _cutout_shifted(sk, alpha, C, B, w, rf, ox):
    class Shift:
        def line(self, p, q):
            return sk.line((p[0] + ox, p[1]), (q[0] + ox, q[1]))

        def arc(self, c, r, a0, a1):
            return sk.arc((c[0] + ox, c[1]), r, a0, a1)
    _cutout(Shift(), alpha, C, B, w, rf)
    return sk


@problem("16.5", [("W=50", 38167), ("W=60", 58674), ("W=70", 82781)],
         features=("Extrude Boss", "Equations (as recipe)", "Pattern (as recipe)"))
def p16_5():
    # Strip W × 6W × 3 with Ø10 holes: outer rows 10 in from the long edges,
    # spacing A = W − 20, right-aligned 10 from the end; the centre row sits
    # between them offset A/2 with one hole fewer. Counts per the table:
    # 10/9/10, 9/8/9, 8/7/8.
    out = []
    for k, (W, n_outer) in enumerate(((50, 10), (60, 9), (70, 8))):
        A, L = W - 20, 6 * W
        oy = k * 120
        sk = Sketch(top(0)).rect(0, oy, L, oy + W)
        for i in range(n_outer):
            x = L - 10 - i * A
            sk.circle((x, oy + 10), 5).circle((x, oy + W - 10), 5)
        for i in range(n_outer - 1):
            sk.circle((L - 10 - A / 2 - i * A, oy + W / 2), 5)
        out.append([extrude(sk, (2, oy + 2), 3)])
    return out


@problem("16.1", [("RibThickness=2", 36190.0), ("RibThickness=3", 41215.2)],
         features=("Extrude Boss", "Extrude Cut", "Revolve", "Pattern (as recipe)", "Link Values (as recipe)"))
def p16_1():
    # Spool, axis along +y, floor at y = 0. Floor: R65 × 1 with the Ø16 bore
    # through; drum wall R49..R50 from the floor to the open end; open-end
    # flange R50..R65 × 1 (y 24..25); spindle Ø20 with a wall equal to the
    # rib thickness (bore Ø16 for t = 2), from the floor to 10 below the
    # open end (y = 15); six ribs t thick from the spindle to the wall,
    # full height (top at y = 20, 5 below the rim) from R39 to R49, then
    # the top falls straight to the spindle top (y = 15) — the section's
    # 20° / 2 × R10 arcs are read as this taper and its end rounds (area-
    # neutral, omitted). Closed form 35 248 / 39 887 (−2.6 % / −3.2 %).
    out = []
    for k, t in enumerate((2.0, 3.0)):
        ox = k * 200
        rb = 10 - t                                     # spindle bore radius
        body = extrude(Sketch(top(0)).circle((ox, 0), 65).circle((ox, 0), rb), (ox + 40, 0), 1)
        extrude(Sketch(top(1)).circle((ox, 0), 50).circle((ox, 0), 49), (ox + 49.5, 0), 24, union=[body])
        extrude(Sketch(top(24)).circle((ox, 0), 65).circle((ox, 0), 50), (ox + 57, 0), 1, union=[body])
        extrude(Sketch(top(1)).circle((ox, 0), 10).circle((ox, 0), rb), (ox + 10 - t / 2, 0), 14, union=[body])
        for i in range(6):
            a = math.radians(60 * i)
            # rib profile in a plane containing the axis: sketch on a vertical
            # plane through the axis rotated by a; u = radial, v = y
            from kit import plane_at
            xa = (math.cos(a), 0, -math.sin(a))          # radial direction (plan v = -z)
            pl = plane_at((ox, 0, 0), xa, (0, 1, 0))
            prof = Sketch(pl).poly([(10, 1), (49, 1), (49, 20), (39, 20), (10, 15)])
            extrude(prof, (30, 8), t / 2, symmetric=True, union=[body])
        out.append([body])
    return out
