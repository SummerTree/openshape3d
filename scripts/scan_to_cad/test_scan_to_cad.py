#!/usr/bin/env python3
"""Offline tests for the scan-to-CAD helpers that need no app: the line-and-
arc fitter, the open-polyline arc fitter, and the fit inspector's verdicts
on synthetic pairs (a drum that should have been a bucket, a dome cut into
steps, an identical part).

    scripts/scan_to_cad/venv/bin/python -I scripts/scan_to_cad/test_scan_to_cad.py

Needs the pipeline venv (trimesh, numpy, scipy, rtree, pillow); the tests
skip themselves without it.
"""
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

try:
    import numpy as np
    import trimesh
    import fit_primitives as F
    HAVE_DEPS = True
except ImportError:
    HAVE_DEPS = False


def rounded_rectangle(w, h, r, per_arc=8):
    """A tessellated rounded rectangle, counter-clockwise, with the tangent
    points as vertices — the way a CAD kernel tessellates one."""
    pts = []
    corners = [(w / 2 - r, h / 2 - r, 0.0), (-w / 2 + r, h / 2 - r, math.pi / 2),
               (-w / 2 + r, -h / 2 + r, math.pi), (w / 2 - r, -h / 2 + r, 1.5 * math.pi)]
    for cx, cy, a0 in corners:
        for k in range(per_arc + 1):
            a = a0 + (math.pi / 2) * k / per_arc
            pts.append([cx + r * math.cos(a), cy + r * math.sin(a)])
    return np.array(pts)


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class FitPrimitivesTests(unittest.TestCase):
    def test_rounded_rectangle_is_four_lines_and_four_arcs(self):
        loop = rounded_rectangle(80, 50, 8)
        segs = F.segments_from_loop(loop, tol=0.05)
        kinds = [s["kind"] for s in segs]
        self.assertEqual(kinds.count("arc"), 4, segs)
        self.assertEqual(kinds.count("line"), 4, segs)
        for s in segs:
            if s["kind"] == "arc":
                self.assertAlmostEqual(s["radius"], 8.0, places=3)
        # The loop closes exactly: each segment ends where the next starts.
        for s, t in zip(segs, segs[1:] + segs[:1]):
            self.assertLess(np.linalg.norm(np.array(s["b"]) - np.array(t["a"])), 1e-6)
        ents = F.sketch_entities(segs)
        self.assertEqual(len(ents), 8)
        for e in ents:
            if e["kind"] == "arc":
                self.assertGreater(e["endAngle"], e["startAngle"])

    def test_chord_midpoints_and_stubs_do_not_break_arcs(self):
        loop = rounded_rectangle(80, 50, 8)
        # Split every edge in two (a collinear midpoint) and double every
        # vertex with a 0.2 mm stub, as the clamp's tessellation did.
        dense = []
        n = len(loop)
        for i in range(n):
            a, b = loop[i], loop[(i + 1) % n]
            dense += [a, a + (b - a) * 0.004, (a + b) / 2]
        segs = F.segments_from_loop(np.array(dense), tol=0.05)
        self.assertEqual(sum(s["kind"] == "arc" for s in segs), 4, segs)

    def test_two_arcs_joined_by_a_line_stay_two_arcs(self):
        # A stadium: two semicircles joined by two lines, all turning one
        # way — one run round the whole loop until it is split at the lines.
        loop = rounded_rectangle(80, 16, 8)
        segs = F.segments_from_loop(loop, tol=0.05)
        arcs = [s for s in segs if s["kind"] == "arc"]
        self.assertEqual(sum(s["kind"] == "line" for s in segs), 2, segs)
        sweep = 0.0
        for s in arcs:
            self.assertAlmostEqual(s["radius"], 8.0, places=3)
            sa, sb = (s["start"], s["end"]) if s["ccw"] else (s["end"], s["start"])
            sweep += (sb - sa) % (2 * math.pi)
        self.assertAlmostEqual(sweep, 2 * math.pi, places=3)       # the two semicircles, however they are split

    def test_profile_dome_becomes_an_arc(self):
        # A cylinder r 100 up to h 300 with a spherical dome on top: the
        # traced bands and a coarse simplified polyline through the dome.
        dense = [(100.0, h) for h in np.arange(0, 300, 4.0)]
        dense += [(100.0 * math.cos(t), 300 + 100.0 * math.sin(t)) for t in np.linspace(0, math.pi / 2, 40)[1:]]
        rng = np.random.default_rng(1)
        dense = [(r + rng.normal(0, 0.6), h) for r, h in dense]
        simplified = [(100.0, 0.0), (100.0, 300.0)] + [(100.0 * math.cos(t), 300 + 100.0 * math.sin(t))
                                                        for t in np.linspace(0, math.pi / 2, 6)[1:]]
        segs = F.arcs_in_polyline(simplified, dense, tol=2.5)
        kinds = [s["kind"] for s in segs]
        self.assertIn("arc", kinds, segs)
        arc = next(s for s in segs if s["kind"] == "arc")
        self.assertAlmostEqual(arc["radius"], 100.0, delta=2.0)
        self.assertEqual(kinds[0], "line")      # the cylinder wall stays a line

    def test_hollow_section_of_a_mug(self):
        # Outer profile: a foot, a convex belly (arc), a straight neck to the rim.
        outer = [{"kind": "line", "a": [60.0, 0.0], "b": [60.0, 20.0]},
                 {"kind": "arc", "center": [0.0, 100.0], "radius": 100.0, "start": math.atan2(-80, 60), "end": math.atan2(80, 60),
                  "ccw": True, "a": [60.0, 20.0], "b": [60.0, 180.0]},
                 {"kind": "line", "a": [60.0, 180.0], "b": [60.0, 200.0]}]
        for end in ("top", "bottom"):
            loop = F.hollow_section(outer, 200.0, 4.0, open_end=end)
            for s, t in zip(loop, loop[1:] + loop[:1]):
                self.assertLess(np.linalg.norm(np.array(s["b"]) - np.array(t["a"])), 1e-6, (end, s, t))
            arcs = [s for s in loop if s["kind"] == "arc"]
            self.assertEqual(len(arcs), 2, loop)
            self.assertAlmostEqual(min(a["radius"] for a in arcs), 96.0, places=6)     # the belly's inner face
            hs = [p[1] for s in loop for p in (s["a"], s["b"])]
            floor = 4.0 if end == "top" else 196.0
            self.assertTrue(any(abs(h - floor) < 1e-6 for h in hs), (end, sorted(set(round(h, 1) for h in hs))))
            self.assertEqual(len(F.sketch_entities(loop)), len(loop))

    def test_hollow_section_keeps_a_lip_one_wall_thick(self):
        # A pail: a tapered wall, then a lip stepping out at 248 mm and up to the rim.
        outer = [{"kind": "line", "a": [146.5, 0.0], "b": [166.4, 248.0]},
                 {"kind": "line", "a": [166.4, 248.0], "b": [189.4, 248.0]},
                 {"kind": "line", "a": [189.4, 248.0], "b": [186.5, 264.0]}]
        loop = F.hollow_section(outer, 264.0, 3.0, open_end="top")
        for s, t in zip(loop, loop[1:] + loop[:1]):
            self.assertLess(np.linalg.norm(np.array(s["b"]) - np.array(t["a"])), 1e-6, (s, t))
        # The lip's underside (h = 248, r 166 → 189) must have its inner face 3 mm ABOVE it, not on it.
        horizontals = [s for s in loop if abs(s["a"][1] - s["b"][1]) < 1e-6 and min(s["a"][0], s["b"][0]) > 150]
        heights = sorted(round(s["a"][1], 2) for s in horizontals)
        self.assertIn(248.0, heights)
        self.assertIn(251.0, heights, heights)
        # And the wall is nowhere thinner than the wall: no inner vertex within 2.9 mm of an outer vertex.
        outer_pts = np.array([p for s in outer for p in (s["a"], s["b"])])
        inner_pts = np.array([p for s in loop[5:-2] for p in (s["a"], s["b"])])     # after the rim line, before the floor
        d = np.linalg.norm(inner_pts[:, None, :] - outer_pts[None, :, :], axis=2).min(axis=1)
        self.assertGreaterEqual(d.min(), 2.9, d)

    def test_profile_with_steps_stays_lines(self):
        simplified = [(100.0, 0.0), (100.0, 100.0), (120.0, 100.0), (120.0, 140.0), (100.0, 140.0), (100.0, 300.0)]
        segs = F.arcs_in_polyline(simplified, simplified, tol=2.5)
        self.assertTrue(all(s["kind"] == "line" for s in segs), segs)


def run_inspect(reference, model, out, tolerance, up="y"):
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "inspect_fit.py"), "--reference", reference,
                    "--model", model, "--out", out, "--tolerance", str(tolerance), "--up", up, "--title", "test"],
                   check=True, capture_output=True, text=True)
    return json.load(open(os.path.join(out, "checks.json")))


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class InspectFitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="inspect-")

    def _cylinder(self, radius, height):
        m = trimesh.creation.cylinder(radius=radius, height=height, sections=96)
        m.apply_translation([0, 0, height / 2])
        return m

    def test_identical_parts_pass(self):
        a = self._cylinder(100, 300)
        pa, pb = os.path.join(self.tmp, "a.stl"), os.path.join(self.tmp, "b.stl")
        a.export(pa)
        a.export(pb)
        checks = run_inspect(pa, pb, os.path.join(self.tmp, "same"), 2.0, up="z")
        self.assertEqual(checks["overall"], "PASS", [c for c in checks["checks"] if c["verdict"] != "PASS"])

    def test_a_drum_for_a_bucket_fails_on_excess_and_depth(self):
        # Reference: an open bucket (a thin shell with no lid). Model: a solid drum.
        # The shell as an annulus plus a bottom disc (no boolean engine in the venv).
        ring = trimesh.creation.annulus(r_min=96, r_max=100, height=300, sections=96)
        ring.apply_translation([0, 0, 150])
        bottom = self._cylinder(100, 4)
        bucket = trimesh.util.concatenate([ring, bottom])
        drum = self._cylinder(100, 300)
        pr, pm = os.path.join(self.tmp, "bucket.stl"), os.path.join(self.tmp, "drum.stl")
        bucket.export(pr)
        drum.export(pm)
        checks = run_inspect(pr, pm, os.path.join(self.tmp, "drum"), 2.0, up="z")
        by = {c["check"]: c for c in checks["checks"]}
        self.assertEqual(checks["overall"], "FAIL")
        # The lid is an eighth of the drum's area: excess area at least warns…
        self.assertIn(by["model_excess_area"]["verdict"], ("WARN", "FAIL"), by["model_excess_area"])
        # …and seen from above the lid sits 300 mm nearer than the bucket's floor: that fails.
        self.assertEqual(by["depth_top"]["verdict"], "FAIL", by["depth_top"])
        self.assertGreater(by["depth_top"]["excessShare"], 0.5)

    def test_a_terraced_dome_fails_the_top_strip(self):
        # Reference: a cylinder with a spherical dome. Model: the dome cut into three flat steps.
        def revolve(profile):
            return trimesh.creation.revolve(np.array(profile), sections=96)
        dome = [(0, 0), (100, 0), (100, 300)] + [(100 * math.cos(t), 300 + 100 * math.sin(t)) for t in np.linspace(0, math.pi / 2, 30)[1:]]
        steps = [(0, 0), (100, 0), (100, 300), (100, 330), (70, 330), (70, 370), (35, 370), (35, 400), (0, 400)]
        ref, mod = revolve(dome), revolve(steps)
        pr, pm = os.path.join(self.tmp, "dome.stl"), os.path.join(self.tmp, "steps.stl")
        ref.export(pr)
        mod.export(pm)
        checks = run_inspect(pr, pm, os.path.join(self.tmp, "steps"), 3.0, up="z")
        by = {c["check"]: c for c in checks["checks"]}
        self.assertNotEqual(checks["overall"], "PASS")
        self.assertGreaterEqual(by["depth_front"]["worstStripShare"], 0.3, by["depth_front"])


if __name__ == "__main__":
    unittest.main()
