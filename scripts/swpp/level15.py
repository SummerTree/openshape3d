"""Level 15 — Configurations, Design Tables, Suppress (16 problems). A
sheet's configurations are built side by side in one document and scored
together (meta["configs"], as in level16.py)."""
import math
from kit import Sketch, front, top, right, extrude, revolve

PROBLEMS = {}


def problem(pid, configs, unit="mm", features=("Revolve", "Configurations (as recipe)")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": configs[0][1], "configs": list(configs), "unit": unit,
                          "features": list(features)}, fn)
        return fn
    return deco


@problem("15.1", [("GROOVE 1", 159098.0), ("GROOVE 2", 157605.7), ("NO GROOVE", 164698.0)],
         features=("Revolve", "Extrude Cut", "Hole (as revolve)", "Configurations (as recipe)"))
def p15_1():
    # Ø130 disc: 6 thick at the rim, a cone up to a Ø55 flat at 18; on the
    # underside an annular groove Ø B..Ø C, A deep; a CSINK for an M5 flat
    # head screw through the centre (Ø5.5 through, Ø10.4 × 90° countersink)
    # — groove and hole suppressed in the third configuration.
    out = []
    D, h = 10.4, (10.4 - 5.5) / 2
    for k, (A, B, C) in enumerate(((5, 60, 70), (6, 65, 75), (None, None, None))):
        ox = k * 200
        if A is None:
            prof = Sketch(front(0)).poly([(ox, 0), (ox + 65, 0), (ox + 65, 6), (ox + 27.5, 18), (ox, 18)])
        else:
            prof = Sketch(front(0)).poly([(ox + 2.75, 0), (ox + 65, 0), (ox + 65, 6), (ox + 27.5, 18),
                                          (ox + D / 2, 18), (ox + 2.75, 18 - h)])
        body = revolve(prof, (ox + 40, 3), (ox, 0), (0, 1))
        if A is not None:
            extrude(Sketch(top(0)).circle((ox, 0), C / 2).circle((ox, 0), B / 2), (ox + (B + C) / 4, 0), A, cut=[body])
        out.append([body])
    return out


@problem("15.2B", [("CONFIG 2", 107.51)], unit="in",
         features=("Extrude Boss", "Extrude Cut", "Configurations (as recipe)"))
def p15_2B():
    # IPS hand wheel, configuration 2: Ø14 disc 1.5 thick with a 0.5 rim
    # (Ø13 inside), a 0.5 web (0.5 recessed from each face between the
    # Ø3 hub and the rim), a Ø3 × 1.75 hub with a 1.5 square through
    # bore, and four 0.25 spokes flush with the faces out to R5.25, then
    # sloping 20° down toward the rim (Section B-B's triangles, Detail
    # .5 = web). Hand: 107.50 in³.
    s = 25.4
    drop = 1.25 * math.tan(math.radians(20))
    body = extrude(Sketch(front(-0.75 * s)).circle((0, 0), 7 * s), (0, 0), 1.5 * s)
    extrude(Sketch(front(0.75 * s)).circle((0, 0), 6.5 * s).circle((0, 0), 1.5 * s), (4 * s, 0), -0.5 * s, cut=[body])
    extrude(Sketch(front(-0.75 * s)).circle((0, 0), 6.5 * s).circle((0, 0), 1.5 * s), (4 * s, 0), 0.5 * s, cut=[body])
    extrude(Sketch(front(-0.875 * s)).circle((0, 0), 1.5 * s), (0, 0), 1.75 * s, union=[body])
    prof = [(1.5, -0.75), (5.25, -0.75), (6.5, -0.75 + drop), (6.5, 0.75 - drop), (5.25, 0.75), (1.5, 0.75)]
    for sgn in (1, -1):
        # spokes along ±x: profile in the top plane (u = x, v = -z), 0.25 thick in y
        extrude(Sketch(top(-0.125 * s)).poly([(sgn * u * s, v * s) for u, v in prof]), (sgn * 3 * s, 0), 0.25 * s, union=[body])
        # spokes along ±y: profile in the right plane (u = -z, v = y), 0.25 thick in x
        extrude(Sketch(right(-0.125 * s)).poly([(v * s, sgn * u * s) for u, v in prof]), (0, sgn * 3 * s), 0.25 * s, union=[body])
    extrude(Sketch(front(-1.0 * s)).rect_c(0, 0, 1.5 * s, 1.5 * s), (0, 0), 2.0 * s, cut=[body])
    return [[body]]


# ---------------------------------------------------------------- F4 batch ---
from kit import (Sketch as _Sk, front as _front, top as _top, right as _right, extrude as _ex,  # noqa: E402
                 revolve as _rev, union as _union, fillet as _fillet, shell as _shell,
                 edges_where as _edges_where, faces as _faces)


def _face_where(bid, pred):
    return [f["index"] for f in _faces(bid) if pred(f["centroid"], f["normal"])]


@problem("15.6", [("PIN.1", 1366.1), ("PIN.2", 3909.9), ("PIN.3", 4758.1), ("PIN.4", 7614.3)],
         features=("Extrude Boss", "Revolve", "Configurations (as recipe)"))
def p15_6():
    # Bent pin: a rod of DIA D swept along an L path — A along +x, B down
    # -y from the corner (the origin), the corner filleted RC. Hand: the
    # path length is A + B - 2 RC + pi RC / 2, times pi (D/2)^2: 1366.1 /
    # 3909.9 / 4758.1 / 7614.3 exactly. Built exactly as two cylinders
    # plus a quarter torus (revolve), all unioned.
    out = []
    for k, (A, B, RC, D) in enumerate(((80, 30, 3, 4), (110, 30, 4, 6), (130, 40, 4, 6), (150, 50, 5, 7))):
        z0 = k * 40.0
        r = D / 2
        horiz = _ex(_Sk(_right(RC)).circle((-z0, 0), r), (-z0, 0), A - RC)
        vert = _ex(_Sk(_top(-RC)).circle((0, -z0), r), (0, -z0), -(B - RC))
        bend = _rev(_Sk(_top(-RC)).circle((0, -z0), r), (0, -z0), (RC, -z0), (0, 1), angle=90)
        _union(horiz, [vert, bend])
        out.append([horiz])
    return out


@problem("15.3", [("UH.1", 2392.4), ("UH.2", 6601.9), ("UH.3", 11735.8), ("UH.4", 17681.5)],
         features=("Extrude Boss", "Extrude Cut", "Hole (as cut)", "Configurations (as recipe)"))
def p15_3():
    # U bracket (design table): legs A tall, B wide overall, C deep, THK D,
    # bend R4 OUTSIDE (R4 - D inside); a O6 hole through the top centre and
    # a O E hole through each leg 10 up; UH.4 adds a linear pattern: three
    # top holes at 30 (60 between the outer ones, the iso view). Hand
    # (closed form, sheet metal section x C minus holes): 2392.5 / 6602.0 /
    # 11735.9 / 17681.5.
    out = []
    for k, (A, B, C, D, E, extra) in enumerate(((30, 68, 20, 1, 5, False), (40, 95, 20, 2, 5, False),
                                                 (50, 105, 30, 2, 6, False), (50, 110, 30, 3, 7, True))):
        ox = k * 250.0
        pts = [(ox - B / 2, 0), (ox - B / 2, A), (ox + B / 2, A), (ox + B / 2, 0),
               (ox + B / 2 - D, 0), (ox + B / 2 - D, A - D), (ox - B / 2 + D, A - D), (ox - B / 2 + D, 0)]
        body = _ex(_Sk(_front(-C / 2)).rounded_poly(pts, [0, 4, 4, 0, 0, 4 - D, 4 - D, 0]), (ox, A - D / 2), C)
        for x in ([ox - 30, ox, ox + 30] if extra else [ox]):
            _ex(_Sk(_top(A + 1)).circle((x, 0), 3), (x, 0), -(D + 2), cut=[body])
        for s in (1, -1):
            x0 = ox + s * (B / 2 + 1)
            _ex(_Sk(_right(x0)).circle((0, 10), E / 2), (0, 10), -s * (D + 2), cut=[body])
        out.append([body])
    return out


@problem("15.5", [("ASSY*", 571697.6)],
         features=("Extrude Boss", "Extrude Cut", "Configurations (as recipe)"))
def p15_5():
    # Wheel, ASSY configuration (web recesses and R3 fillets suppressed):
    # a O D=160 disc B=28 thick, the O C=58 hub carried on to A=45 overall,
    # O32 bore. Hand 571601.4 (-0.017 %). The other rows of the table need
    # the recessed web (O58..O124, both faces) and R3 TYP ALL: STANDARD
    # 381071.9, W7-225 462223.3, W7-25 646967.2, W8-3 762963.1.
    body = _ex(_Sk(_top(0)).circle((0, 0), 80), (0, 0), 28)
    _ex(_Sk(_top(-17)).circle((0, 0), 29), (0, 0), 17, union=[body])
    _ex(_Sk(_top(-18)).circle((0, 0), 16), (0, 0), 47, cut=[body])
    return [[body]]


def _wall_plate(W, H, cutouts, screws, t=3.0, depth=6.0, R=5.0):
    """15.4 wall plate: a W x H x depth block, R5 on the four front edges,
    shelled t from the back; `cutouts` are callables drawing a closed
    profile on a front sketch; `screws` are (x, y) of CS M2 flat-head
    holes (O2.2 through, 90 deg countersink O4.4)."""
    body = _ex(_Sk(_front(0)).rect(-W / 2, -H / 2, W / 2, H / 2), (0, 0), depth)
    top_edges = _edges_where(body, lambda e: abs(e["midpoint"][2] - depth) < 0.1 and e["lengthMM"] > 10)
    assert len(top_edges) == 4, top_edges
    _fillet(body, R, top_edges)
    back = _face_where(body, lambda c, n: abs(n[2] + 1) < 1e-6 and abs(c[2]) < 0.05)
    assert len(back) == 1, back
    _shell(body, t, back)
    for draw in cutouts:
        sk = _Sk(_front(depth + 1))
        seed = draw(sk)
        _ex(sk, seed, -(depth + 2), cut=[body])
    for (x, y) in screws:
        _ex(_Sk(_front(depth + 1)).circle((x, y), 1.1), (x, y), -(depth + 2), cut=[body])
        # countersink: a 45 deg triangle in the plane x = const (u = -z,
        # v = y) revolved about the hole axis (u direction through (-depth, y))
        prof = _Sk(_right(x)).poly([(-depth, y), (-depth, y + 2.2), (-depth + 2.2, y)])
        _rev(prof, (-depth + 0.4, y + 0.4), (-depth, y), (1, 0), 360, cut=[body])
    return body


def _rect_cut(w, h, cx=0.0, cy=0.0):
    def draw(sk):
        sk.rect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
        return (cx, cy)
    return draw


def _duplex_cut(cy, width=34.0, height=29.0, r=19.0):
    """Receptacle opening: flats `height` apart, side arcs R`r` whose
    centres sit inside so the opening is `width` across."""
    def draw(sk):
        h = height / 2
        c = width / 2 - r                       # arc-centre offset (negative)
        th = math.degrees(math.asin(h / r))
        xt = -c + math.sqrt(r * r - h * h)       # flat half-width... arc x at the flat
        xt = c + math.sqrt(r * r - h * h)
        sk.arc((c, cy), r, -th, th)              # right arc
        sk.arc((-c, cy), r, 180 - th, 180 + th)  # left arc
        sk.line((xt, cy + h), (-xt, cy + h))
        sk.line((-xt, cy - h), (xt, cy - h))
        return (0, cy)
    return draw


@problem("15.4A", [("BLANK", 25490.9)], features=("Extrude Boss", "Fillet", "Shell", "Hole (as cut)", "Configurations (as recipe)"))
def p15_4A():
    # Blank wall plate 70 x 114, 6 deep, 3.00 THK, R5 round on the front
    # edges (R2 inside after the shell), one CS M2 flat-head hole at the
    # centre. Hand (block - mitred R5 fillets, minus the offset cavity,
    # minus the hole): 25488.7.
    return [[_wall_plate(70, 114, [], [(0, 0)])]]


@problem("15.4B", [("DUPLEX", 20265.1)], features=("Extrude Boss", "Fillet", "Shell", "Extrude Cut", "Configurations (as recipe)"))
def p15_4B():
    # Duplex: two receptacle openings 29 tall centred 20 above/below the
    # centre screw, side arcs R19 (the '19 TYP'), 34 across (the table's
    # 5225.8 mm3 difference to the blank is 871 mm2 per opening; a full
    # R19 circle with flats would be 983 mm2). Hand 20288.9 (+0.12 %).
    return [[_wall_plate(70, 114, [_duplex_cut(20), _duplex_cut(-20)], [(0, 0)])]]


@problem("15.4C", [("SWITCH", 24722.5)], features=("Extrude Boss", "Fillet", "Shell", "Extrude Cut", "Configurations (as recipe)"))
def p15_4C():
    # Toggle switch: a 10 x 25 opening at the centre, two CS M2 holes 85 apart.
    return [[_wall_plate(70, 114, [_rect_cut(10, 25)], [(0, 42.5), (0, -42.5)])]]


@problem("15.4D", [("DIMMER", 25385.0)], features=("Extrude Boss", "Fillet", "Shell", "Extrude Cut", "Configurations (as recipe)"))
def p15_4D():
    # Dimmer: an 80 x 127 plate with a 34 x 67 opening, screws 85 apart.
    return [[_wall_plate(80, 127, [_rect_cut(34, 67)], [(0, 42.5), (0, -42.5)])]]
