"""Level 15 — Configurations, Design Tables, Suppress (16 problems). A
sheet's configurations are built side by side in one document and scored
together (meta["configs"], as in level16.py)."""
import math
from kit import Sketch, front, top, extrude, revolve

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
