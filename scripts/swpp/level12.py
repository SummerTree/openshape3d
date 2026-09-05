"""Level 12 - Draft. Drafts as taper extrudes (positive taper narrows along
the extrude direction) or kit.draft_face on existing faces; fillets after
drafts, as the sheets' hints say."""
import math
from kit import (Sketch, front, back, top, bottom, right, left, plane_at, extrude, revolve, fillet, chamfer,
                 shell, edges_where, edges, faces, union, subtract, mirror, pattern, bodies, vol, draft_face)

PROBLEMS = {}


def problem(pid, volume, unit="mm", features=("Extrude Boss", "Draft")):
    def deco(fn):
        PROBLEMS[pid] = ({"volume": volume, "unit": unit, "features": list(features)}, fn)
        return fn
    return deco


# F3 worker -------------------------------------------------------------
@problem("12.9", 37.1, unit="in", features=("Extrude Boss (draft)", "Extrude Cut (draft)", "Fillet", "Hole Wizard (CBORE)"))
def p12_9():
    # IPS. Block 6.5 x 4.5 at the TOP face (the top view's 6.5 / 4.5 run to
    # the inner outline; the footprint outline is 6.85 measured = 6.5 +
    # 2 x 1.5 tan 8), 1.5 thick, 8 deg outward draft; R.4 measured on the
    # footprint corners -> a constant R.4 fillet after the draft. Pockets
    # dimensioned at their top openings (the '2' runs to the outer pocket
    # lines), R.25 corners, 5 deg draft narrowing down: left 2 x 3.5 at
    # .5 from the left edge and .5 above the bottom edge, 1.0 deep (the
    # section's '1'); right 1.5 x 1 (centre 1.75 REF from the right edge,
    # .5 below the top edge) and 2.5 x 1.5 (.5 from the right and bottom
    # edges), .75 deep ('.75 X2'). CBORE for 3/8 SHCS at the plan centre
    # (3.25 REF): SW ANSI normal fit O.4062 thru, O.5938 x .375 c'bore.
    s = 25.4
    t8, t5 = math.tan(math.radians(8)), math.tan(math.radians(5))
    W, H = 6.5 + 2 * 1.5 * t8, 4.5 + 2 * 1.5 * t8
    body = extrude(Sketch(top(-1.5 * s)).rect_c(0, 0, W * s, H * s), (0, 0), 1.5 * s, taper=8.0)
    # the corner edges slant in x AND z: 1.5 * sqrt(1 + 2 tan^2 8) = 1.5296 in
    corners = edges_where(body, lambda e: abs(e["lengthMM"] - 1.5 * s * math.sqrt(1 + 2 * t8 * t8)) < 0.3)
    assert len(corners) == 4, corners
    fillet(body, 0.4 * s, corners)

    def pocket(x0, x1, z0, z1, depth):
        pts = [(x0 * s, z0 * s), (x1 * s, z0 * s), (x1 * s, z1 * s), (x0 * s, z1 * s)]
        extrude(Sketch(bottom(0)).rounded_poly(pts, 0.25 * s), ((x0 + x1) / 2 * s, (z0 + z1) / 2 * s),
                depth * s, taper=5.0, cut=[body])
    pocket(-2.75, -0.75, -1.75, 1.75, 1.0)
    pocket(0.75, 2.25, 0.75, 1.75, 0.75)
    pocket(0.25, 2.75, -1.75, -0.25, 0.75)
    extrude(Sketch(bottom(0)).circle((0, 0), 0.5938 / 2 * s), (0, 0), 0.375 * s, cut=[body])
    extrude(Sketch(bottom(0.1)).circle((0, 0), 0.4062 / 2 * s), (0, 0), 1.7 * s, cut=[body])
    return body
