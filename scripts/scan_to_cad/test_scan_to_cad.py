#!/usr/bin/env python3
"""Offline tests for the scan-to-CAD helpers that need no app: the line-and-
arc fitter, the open-polyline arc fitter, the shared half-section the build,
film and reel revolve, and the fit inspector's verdicts and patches
on synthetic pairs (a drum that should have been a bucket, a dome cut into
steps, a cylinder whose boss the model lacks, an identical part).

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


@unittest.skipUnless(HAVE_DEPS, "needs the pipeline venv")
class BodySectionTests(unittest.TestCase):
    """`build_hydrant.body_section` / `boss_section`: the one half-section the
    build, the film and the reel all revolve."""

    def setUp(self):
        import build_hydrant as B
        self.B = B

    def closed(self, entities):
        """Each entity shares an endpoint with the next (an arc entity carries
        centre, radius and angles, so its ends are computed)."""
        def ends(e):
            if e["kind"] == "line":
                return [np.array(e["a"]), np.array(e["b"])]
            c, r = np.array(e["center"]), e["radius"]
            return [c + r * np.array([math.cos(a), math.sin(a)]) for a in (e["startAngle"], e["endAngle"])]
        for s, t in zip(entities, entities[1:] + entities[:1]):
            gap = min(np.linalg.norm(p - q) for p in ends(s) for q in ends(t))
            self.assertLess(gap, 1e-3, (s, t))                        # angles are written to 6 places

    def test_plain_profile_is_the_straight_loop(self):
        analysis = {"profile": [[100.0, 0.0], [100.0, 0.0], [100.0, 200.0]], "heightMM": 200.0, "bodyRadiusMM": 100.0}
        sec = self.B.body_section(analysis)
        self.assertEqual(sec["outline"], [[0.0, 0.0], [100.0, 0.0], [100.0, 200.0], [0.0, 200.0]])   # the repeat dropped
        self.assertEqual([e["kind"] for e in sec["entities"]], ["line"] * 4)
        self.assertEqual(sec["seed"], [50.0, 100.0])
        self.assertIsNone(sec["hollow"])
        self.closed(sec["entities"])

    def test_dome_segments_become_lines_and_an_arc_closed_on_the_axis(self):
        segments = [{"kind": "line", "a": [60.0, 0.0], "b": [60.0, 100.0]},
                    {"kind": "arc", "center": [0.0, 100.0], "radius": 60.0, "start": 0.0, "end": math.pi / 2,
                     "ccw": True, "a": [60.0, 100.0], "b": [0.0, 160.0]}]
        analysis = {"profile": [[60.0, 0.0], [60.0, 100.0], [0.0, 160.0]], "heightMM": 160.0, "bodyRadiusMM": 60.0,
                    "profileSegments": segments}
        sec = self.B.body_section(analysis)
        kinds = [e["kind"] for e in sec["entities"]]
        self.assertEqual(kinds.count("arc"), 1, kinds)
        self.assertEqual(sec["entities"][0]["a"], [0.0, 0.0])
        self.assertEqual(sec["entities"][-1]["b"], [0.0, 0.0])
        self.assertIsNone(sec["hollow"])
        self.closed(sec["entities"])

    def test_open_container_is_a_solid_with_a_cavity_to_subtract(self):
        segments = [{"kind": "line", "a": [146.5, 0.0], "b": [166.4, 248.0]},
                    {"kind": "line", "a": [166.4, 248.0], "b": [189.4, 248.0]},
                    {"kind": "line", "a": [189.4, 248.0], "b": [186.5, 264.0]}]
        analysis = {"profile": [[146.5, 0.0], [166.4, 248.0], [189.4, 248.0], [186.5, 264.0]], "heightMM": 264.0,
                    "bodyRadiusMM": 160.0, "profileSegments": segments,
                    "openTop": {"end": "top", "wallMM": 3.0, "depthMM": 240.0}}
        sec = self.B.body_section(analysis)
        self.assertEqual(sec["hollow"], {"wallMM": 3.0, "measuredWallMM": 3.0, "openEnd": "top"})
        # The outer loop is the solid revolve; the cavity is its own loop,
        # a wall in, from the floor to past the rim, with its seed inside.
        self.assertEqual([e["kind"] for e in sec["entities"]], ["line"] * 6)   # axis, foot, wall, rim top, lip, back
        self.closed(sec["entities"])
        inner = sec["inner"]
        self.assertIn("cavity", inner["note"])
        self.closed(inner["entities"])
        us = [e["a"][0] for e in inner["entities"]] + [e["b"][0] for e in inner["entities"]]
        vs = [e["a"][1] for e in inner["entities"]] + [e["b"][1] for e in inner["entities"]]
        self.assertLessEqual(max(us), 189.4 - 3.0 + 1e-6)
        self.assertAlmostEqual(min(vs), 24.0)                              # the floor: 240 mm down from the 264 mm rim (the rays' depth)
        self.assertGreater(max(vs), 264.0)                                 # out through the open rim
        self.assertLess(3.0, inner["seed"][1])
        self.assertLess(inner["seed"][1], 264.0)
        self.assertLess(inner["seed"][0], 146.5 - 3.0)
        # A measured wall wider than the part can hold is capped under half the smallest radius.
        analysis["openTop"]["wallMM"] = 100.0
        self.assertAlmostEqual(self.B.body_section(analysis)["hollow"]["wallMM"], 0.45 * 146.5)

    def test_an_arc_ending_past_the_axis_is_kept_off_it(self):
        # A dome arc whose rounded end lands at u = -8e-5 revolved to nothing.
        arc = {"kind": "arc", "center": [8.8467, 1049.6848], "radius": 156.5869, "startAngle": 0.146325, "endAngle": 1.627324}
        self.B.keep_off_axis([arc])
        u = arc["center"][0] + arc["radius"] * math.cos(arc["endAngle"])
        self.assertAlmostEqual(u, 0.05, places=4)
        self.assertAlmostEqual(arc["startAngle"], 0.146325)                # the other end untouched

    def test_section_loop_is_revolved_as_it_is(self):
        loop = [[0.0, 0.0], [100.0, 0.0], [100.0, 40.0], [60.0, 40.0], [60.0, 20.0], [0.0, 20.0]]   # a dished disc
        sec = self.B.body_section({"profile": [[100.0, 0.0], [100.0, 40.0]], "heightMM": 40.0, "bodyRadiusMM": 100.0,
                                   "sectionLoop": loop})
        self.assertEqual(len(sec["entities"]), 6)
        self.assertIn("dished", sec["note"])
        self.closed(sec["entities"])
        u, v = sec["seed"]
        self.assertTrue(0 < u < 100 and 0 < v < 40 and not (u < 60 and v > 20), sec["seed"])   # inside, not in the dish

    def test_boss_section_closes_along_its_axis(self):
        entities, seed = self.B.boss_section({"profile": [[10.0, 0.0], [10.0, 30.0], [10.0, 30.0], [14.0, 30.0], [14.0, 40.0]]})
        self.assertEqual(entities[0]["a"], [0.0, 0.0])
        self.assertEqual(entities[-1]["b"], [0.0, 0.0])
        self.assertEqual(entities[-1]["a"], [0.0, 40.0])
        self.assertEqual(len(entities), 6)                                 # the repeated point makes no line
        self.assertEqual(seed, [4.0, 12.0])
        self.closed(entities)


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class TracerHelperTests(unittest.TestCase):
    """analyze_scan's surface-grid helpers and the noise estimate."""

    def test_is_dished_sees_a_wide_gap_but_not_a_wall(self):
        import analyze_scan as A
        wall = np.zeros((20, 60), dtype=bool)
        wall[:, 50] = True
        wall[:, 47] = True                                                   # two skins 3 cells apart
        self.assertFalse(A.is_dished(wall, cell=2.0, min_gap_mm=40.0))
        dish = wall.copy()
        dish[5:15, 10] = True                                                # a hub ring far inside the tyre
        self.assertTrue(A.is_dished(dish, cell=2.0, min_gap_mm=40.0))

    def test_noise_of_a_clean_cylinder_is_small(self):
        import analyze_scan as A
        rng = np.random.default_rng(1)
        n = 40000
        h = rng.uniform(0, 100, n)
        az = rng.uniform(-180, 180, n)
        r = 50.0 + rng.normal(0, 0.05, n)
        self.assertLess(A.estimate_noise(h, r, az), 0.15)
        r2 = 50.0 + rng.normal(0, 1.5, n)
        self.assertGreater(A.estimate_noise(h, r2, az), 0.8)

    def test_cavity_of_a_drum_open_at_the_bottom_reaches_past_its_rim(self):
        segs = [{"kind": "line", "a": [290.0, 0.0], "b": [290.0, 900.0]},
                {"kind": "line", "a": [290.0, 900.0], "b": [100.0, 920.0]},
                {"kind": "line", "a": [100.0, 920.0], "b": [100.0, 929.0]}]
        loop, seed = F.cavity_section(segs, 929.0, 5.0, "bottom")
        vs = [e["a"][1] for e in loop] + [e["b"][1] for e in loop]
        us = [e["a"][0] for e in loop] + [e["b"][0] for e in loop]
        self.assertLess(min(vs), 0.0)                                       # out through the open bottom
        self.assertLess(max(vs), 929.0 - 5.0 + 1e-6)                        # the floor a wall in from the chime's top
        self.assertLessEqual(max(us), 285.0 + 1e-6)
        self.assertTrue(0 < seed[1] < 900 and 0 < seed[0] < 285)

    def test_a_tyre_on_a_hub_is_dished_and_not_an_open_container(self):
        """From the hub side a wheel's rim dish reads as an open end (rays
        fall into the dish and through the hub's bore); the dish test must
        run first, or the cavity cuts the rim away (the truck wheel, 21 mm
        mean deviation). A tyre (annulus 150–200 mm, 60 wide) and a hub
        disc (r 50, 20 thick) in one plane: dished, no open end."""
        import numpy as np
        import trimesh
        import analyze_scan as A
        n = 96
        a = np.linspace(0, 2 * np.pi, n, endpoint=False)
        V = []
        for r in (150.0, 200.0):
            for z in (-30.0, 30.0):
                V += [[r * np.cos(t), r * np.sin(t), z] for t in a]
        F = []

        def band(i0, i1):
            for k in range(n):
                k2 = (k + 1) % n
                F.append([i0 + k, i1 + k, i1 + k2])
                F.append([i0 + k, i1 + k2, i0 + k2])
        band(2 * n, 3 * n)      # outer wall
        band(n, 0)              # inner wall
        band(0, 2 * n)          # one face
        band(3 * n, n)          # the other
        tyre = trimesh.Trimesh(np.array(V), np.array(F), process=True)
        tyre.fix_normals()
        hub = trimesh.creation.cylinder(radius=50.0, height=20.0, sections=64)
        wheel = trimesh.util.concatenate([tyre, hub])
        with tempfile.TemporaryDirectory() as out:
            analysis = A.analyze(wheel, out_dir=out, name="wheel", samples=10000, axis_choice="0,0,1!", multi=False)
        self.assertIsNone(analysis.get("openTop"))
        self.assertTrue(analysis.get("sectionLoop"), "the half-section should be traced as a region")
        self.assertAlmostEqual(analysis["heightMM"], 60.0, delta=2.0)


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class BoreTests(unittest.TestCase):
    """`analyze_scan.detect_bores` on synthetic pipes, and `body_section`
    folding a bore into the one half-section loop."""

    @staticmethod
    def pipe(radius, height, bore=None, depth=None, through=False):
        """A cylinder along z from z = 0 to `height`; with `bore`, a hole of
        that radius `depth` deep from the top (or right through)."""
        import trimesh
        outer = trimesh.creation.cylinder(radius=radius, height=height, sections=96)
        outer.apply_translation([0, 0, height / 2])
        if bore is None:
            return outer
        d = height + 10.0 if through else depth
        inner = trimesh.creation.cylinder(radius=bore, height=d + 10.0, sections=96)
        inner.apply_translation([0, 0, height - d / 2 + 5.0])            # from the top face down to `depth`
        return trimesh.boolean.difference([outer, inner], engine="manifold")

    def analyse(self, mesh, **kw):
        import analyze_scan as A
        with tempfile.TemporaryDirectory() as out:
            return A.analyze(mesh, out_dir=out, name="pipe", samples=30000, axis_choice="0,0,1!", multi=False, **kw)

    def test_a_pipe_with_a_bored_end_is_bored(self):
        a = self.analyse(self.pipe(20.0, 150.0, bore=12.0, depth=20.0))
        self.assertIsNone(a["openTop"])                                    # 20 mm in is no container
        self.assertEqual(len(a["bores"]), 1, a["bores"])
        b = a["bores"][0]
        self.assertEqual(b["end"], "end")
        self.assertAlmostEqual(b["rInnerMM"], 12.0, delta=0.8)
        self.assertAlmostEqual(b["depthMM"], 20.0, delta=3.0)
        self.assertAlmostEqual(b["wallMM"], 8.0, delta=1.0)
        self.assertGreaterEqual(b["share"], 0.9)
        self.assertFalse(b["through"])
        self.assertEqual(b["profile"][0][1], 0.0)
        self.assertAlmostEqual(b["profile"][-1][1], b["depthMM"])

    def test_a_pipe_with_a_solid_end_has_no_bore(self):
        a = self.analyse(self.pipe(20.0, 150.0))
        self.assertEqual(a["bores"], [])
        self.assertIsNone(a["openTop"])

    def test_a_bucket_is_an_open_container_and_not_a_bore(self):
        a = self.analyse(self.pipe(60.0, 160.0, bore=57.0, depth=150.0))
        self.assertIsNotNone(a["openTop"])                                 # (the floor's disc makes the closed end read narrower: it is the "bottom" either way up)
        self.assertAlmostEqual(a["openTop"]["depthMM"], 150.0, delta=5.0)
        self.assertEqual(a["bores"], [])

    def test_a_through_pipe_is_one_through_bore(self):
        a = self.analyse(self.pipe(20.0, 100.0, bore=14.0, through=True), secondary=True)
        self.assertEqual(len(a["bores"]), 1, a["bores"])
        b = a["bores"][0]
        self.assertTrue(b["through"])
        self.assertAlmostEqual(b["depthMM"], a["heightMM"], delta=0.1)
        self.assertAlmostEqual(b["rInnerMM"], 14.0, delta=0.8)

    def test_a_branch_keeps_a_deep_bore_at_its_free_end(self):
        # A secondary body never runs the open-end test: a 60 mm bore in a
        # 150 mm branch is a bore, not a cavity.
        a = self.analyse(self.pipe(20.0, 150.0, bore=14.0, depth=60.0), secondary=True)
        self.assertEqual(len(a["bores"]), 1, a["bores"])
        self.assertAlmostEqual(a["bores"][0]["depthMM"], 60.0, delta=3.0)
        self.assertFalse(a["bores"][0]["through"])

    def test_body_section_folds_a_bore_into_one_simple_loop(self):
        import build_hydrant as B
        import preview_model as P
        bore = {"end": "end", "rInnerMM": 12.0, "depthMM": 20.0, "wallMM": 8.0, "share": 1.0, "through": False,
                "profile": [[12.0, 0.0], [12.0, 20.0]]}
        analysis = {"axisOrigin": [0.0, 0.0, 0.0], "axisDirection": [0.0, 0.0, 1.0], "azimuthZero": [1.0, 0.0, 0.0],
                    "azimuthNinety": [0.0, 1.0, 0.0], "heightMM": 150.0, "bodyRadiusMM": 20.0,
                    "profile": [[20.0, 0.0], [20.0, 150.0]], "bores": [bore]}
        sec = B.body_section(analysis)
        self.assertEqual(sec["outline"], [[0.0, 0.0], [20.0, 0.0], [20.0, 150.0], [12.0, 150.0], [12.0, 130.0], [0.0, 130.0]])
        self.assertEqual(len(sec["entities"]), 6)
        self.assertIn("bored r 12 mm 20 deep at its end", sec["note"])
        self.assertEqual(sec["bores"][0]["depthMM"], 20.0)
        loops = P.loops_of_entities(sec["entities"])
        self.assertEqual(len(loops), 1)
        self.assertTrue(P.point_in_loop(sec["seed"], loops[0]), sec["seed"])
        self.assertFalse(F.loop_self_intersects([{"kind": "line", "a": e["a"], "b": e["b"]} for e in sec["entities"]]))
        body, cavity, _ = P.body_mesh(analysis, sections=128)
        self.assertIsNone(cavity)
        expect = math.pi * 400 * 150 - math.pi * 144 * 20
        self.assertAlmostEqual(body.volume, expect, delta=0.01 * expect)
        # A bore at the foot with a step, under a domed top: still one loop,
        # the arc kept, the seed in the wall.
        segments = [{"kind": "line", "a": [60.0, 0.0], "b": [60.0, 100.0]},
                    {"kind": "arc", "center": [0.0, 100.0], "radius": 60.0, "start": 0.0, "end": math.pi / 2,
                     "ccw": True, "a": [60.0, 100.0], "b": [0.0, 160.0]}]
        stepped = {"end": "start", "rInnerMM": 40.0, "depthMM": 50.0, "wallMM": 20.0, "share": 1.0, "through": False,
                   "profile": [[40.0, 0.0], [40.0, 20.0], [25.0, 20.0], [25.0, 50.0]]}
        dome = {"profile": [[60.0, 0.0], [60.0, 100.0], [0.0, 160.0]], "heightMM": 160.0, "bodyRadiusMM": 60.0,
                "profileSegments": segments, "bores": [stepped]}
        sec = B.body_section(dome)
        self.assertEqual(sum(e["kind"] == "arc" for e in sec["entities"]), 1)
        self.assertEqual(sec["entities"][0]["a"], [0.0, 50.0])
        self.assertEqual(sec["entities"][-1]["b"], [0.0, 50.0])
        loops = P.loops_of_entities(sec["entities"])
        self.assertEqual(len(loops), 1)
        self.assertTrue(P.point_in_loop(sec["seed"], loops[0]), sec["seed"])
        self.assertEqual([round(v, 1) for v in sec["entities"][0]["b"]], [25.0, 50.0])
        self.assertEqual([round(v, 1) for v in sec["entities"][2]["b"]], [40.0, 20.0])
        # Through: an annulus, no axis segment; and a bore wider than the
        # profile it sits in is pulled a wall inside it.
        through = {"end": "start", "rInnerMM": 14.0, "depthMM": 100.0, "wallMM": 6.0, "share": 1.0, "through": True,
                   "profile": [[14.0, 0.0], [14.0, 100.0]]}
        tube = {"profile": [[20.0, 0.0], [20.0, 100.0]], "heightMM": 100.0, "bodyRadiusMM": 20.0, "bores": [through]}
        sec = B.body_section(tube)
        self.assertEqual(sec["outline"], [[14.0, 100.0], [14.0, 0.0], [20.0, 0.0], [20.0, 100.0]])
        self.assertTrue(all(abs(e["a"][0]) > 1e-9 for e in sec["entities"]))
        self.assertIn("right through", sec["note"])
        wide = dict(bore, rInnerMM=19.5, profile=[[19.5, 0.0], [19.5, 20.0]])
        sec = B.body_section(dict(analysis, bores=[wide], profile=[[20.0, 0.0], [20.0, 100.0], [15.0, 100.0], [15.0, 150.0]]))
        self.assertLessEqual(sec["bores"][0]["rInnerMM"], 15.0 - 1.5 + 1e-6)
        self.assertEqual(B.body_section(dict(analysis, bores=[]))["outline"], [[0.0, 0.0], [20.0, 0.0], [20.0, 150.0], [0.0, 150.0]])

    def test_a_through_bore_from_the_foot_under_an_arc_is_an_annulus(self):
        # A through bore read from the START of a body whose profile ends in
        # an arc: the loop closes along the top face to the bore's wall, and
        # never spikes to the axis (the arc branch once re-added the axis
        # point a through bore had taken away).
        import build_hydrant as B
        import preview_model as P
        segments = [{"kind": "line", "a": [20.0, 0.0], "b": [20.0, 90.0]},
                    {"kind": "arc", "center": [10.0, 90.0], "radius": 10.0, "start": 0.0, "end": math.pi / 2,
                     "ccw": True, "a": [20.0, 90.0], "b": [10.0, 100.0]}]
        through = {"end": "start", "rInnerMM": 6.0, "depthMM": 100.0, "wallMM": 14.0, "share": 1.0, "through": True,
                   "profile": [[6.0, 0.0], [6.0, 100.0]]}
        base = {"axisOrigin": [0.0, 0.0, 0.0], "axisDirection": [0.0, 0.0, 1.0], "azimuthZero": [1.0, 0.0, 0.0],
                "azimuthNinety": [0.0, 1.0, 0.0], "profile": [[20.0, 0.0], [20.0, 90.0], [10.0, 100.0]],
                "heightMM": 100.0, "bodyRadiusMM": 20.0, "profileSegments": segments}
        volumes = []
        for bore in (through, dict(through, end="end")):
            sec = B.body_section(dict(base, bores=[bore]))
            lines = [e for e in sec["entities"] if e["kind"] == "line"]
            self.assertEqual(sum(e["kind"] == "arc" for e in sec["entities"]), 1)
            self.assertEqual(len(lines), 4, lines)
            self.assertTrue(all(abs(e["a"][0]) > 1e-9 and abs(e["b"][0]) > 1e-9 for e in lines), lines)   # no axis point
            self.assertIn({"kind": "line", "a": [10.0, 100.0], "b": [6.0, 100.0]}, lines)                 # the top face, in to the wall
            self.assertIn({"kind": "line", "a": [6.0, 100.0], "b": [6.0, 0.0]}, lines)                    # the wall
            self.assertFalse(F.loop_self_intersects(lines))
            loops = P.loops_of_entities(sec["entities"])
            self.assertEqual(len(loops), 1)
            self.assertTrue(P.point_in_loop(sec["seed"], loops[0]), sec["seed"])
            body, cavity, _ = P.body_mesh(dict(base, bores=[bore]), sections=128)
            self.assertTrue(body.is_watertight)
            volumes.append(body.volume)
        self.assertAlmostEqual(volumes[0], volumes[1], delta=1.0)                                          # the same solid either way round
        # Without the bore the arc branch still closes down the axis.
        sec = B.body_section(dict(base, bores=[]))
        self.assertEqual(sec["entities"][-1]["b"], [0.0, 0.0])
        self.assertEqual(sec["entities"][-1]["a"], [0.0, 100.0])

    def test_a_bucket_with_a_thin_floor_is_no_through_bore_without_the_open_end_test(self):
        # The container rule stands on its own: with the open-end test
        # silent (a rim or a handle can spoil its rays) a bucket whose floor
        # is a sixteenth of its height has its inner wall seen almost the
        # whole way — but its FLOOR is seen too, so the hole is not through,
        # and a 150 mm hole r 54 in a 160 mm body is a cavity, not a bore.
        import analyze_scan as A
        kept = A.detect_open_top
        A.detect_open_top = lambda *args, **kw: None
        try:
            a = self.analyse(self.pipe(60.0, 160.0, bore=54.0, depth=150.0))
        finally:
            A.detect_open_top = kept
        self.assertIsNone(a["openTop"])
        self.assertEqual(a["bores"], [])
        # The same walls on a branch (no open-end test ever) keep the bore,
        # with its floor: 150 deep, not through.
        a = self.analyse(self.pipe(60.0, 160.0, bore=54.0, depth=150.0), secondary=True)
        self.assertEqual(len(a["bores"]), 1, a["bores"])
        self.assertFalse(a["bores"][0]["through"])
        self.assertAlmostEqual(a["bores"][0]["depthMM"], 150.0, delta=5.0)

    def test_a_recess_round_a_nut_is_no_bore(self):
        # A hydrant's bonnet: a raised ring r 45 with its operating nut 10 mm
        # down inside it, the recess floor 28 mm down. The ring's inner wall
        # reads like a bore's, but the nut's flanks face OUT inside it over
        # the depth — a recess round a nut, left to the residual fit.
        import trimesh
        body = trimesh.creation.cylinder(radius=45.0, height=200.0, sections=96)
        body.apply_translation([0, 0, 100.0])
        recess = trimesh.creation.cylinder(radius=36.0, height=40.0, sections=96)
        recess.apply_translation([0, 0, 172.0 + 20.0])
        ring = trimesh.boolean.difference([body, recess], engine="manifold")
        a = self.analyse(ring)
        self.assertIsNone(a["openTop"])
        self.assertEqual(len(a["bores"]), 1, a["bores"])                   # the empty ring IS a bore, 28 deep
        self.assertAlmostEqual(a["bores"][0]["rInnerMM"], 36.0, delta=0.8)
        self.assertAlmostEqual(a["bores"][0]["depthMM"], 28.0, delta=3.0)
        nut = trimesh.creation.cylinder(radius=12.0, height=18.0, sections=48)
        nut.apply_translation([0, 0, 172.0 + 9.0])
        a = self.analyse(trimesh.boolean.union([ring, nut], engine="manifold"))
        self.assertIsNone(a["openTop"])
        self.assertEqual(a["bores"], [])

    def test_bore_profile_keeps_the_measured_mouth_when_the_profile_is_lengthened(self):
        # `tube_fit` lengthens a cone's end by far + 4 mm into what it meets
        # AFTER `cone_mouth` measured the mouth; the cut is laid from the
        # measured mouth plane (`boreMouthHMM`), not the lengthened end.
        import build_features as BF
        feature = {"kind": "revolve", "axis": {"origin": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, 1.0]},
                   "profile": [[10.0, 0.0], [30.0, 200.0], [30.0, 212.0]], "cone": True,
                   "boreRadiusMM": 27.5, "boreDepthMM": 100.0, "wallMM": 2.5, "boreMouth": "end", "boreMouthHMM": 200.0}
        inner = BF.bore_profile(feature)
        self.assertAlmostEqual(inner[0][1], 100.0)                       # the floor, 100 below the MEASURED mouth
        self.assertAlmostEqual(inner[-1][1], 205.0)                      # 5 mm past it
        self.assertAlmostEqual(inner[-1][0], 27.5, delta=0.6)
        old = dict(feature)
        del old["boreMouthHMM"]
        self.assertAlmostEqual(BF.bore_profile(old)[0][1], 112.0)        # an older record: the profile's end

    def test_a_hollow_horn_has_an_open_mouth_and_is_cut_hollow(self):
        """`fit_features.cone_mouth` on a thin-walled cone's points, and the
        bored horn built hollow by `build_features.bore_profile` /
        `preview_model.feature_mesh`; a solid cone is left alone."""
        import trimesh
        import fit_features as FF
        import build_features as BF
        import preview_model as P
        rng = np.random.default_rng(3)
        n = 6000
        h = rng.uniform(0, 200, n)
        r_out = 10.0 + 0.1 * h                                          # 10 → 30 mm over 200
        wall = 2.5
        t = rng.uniform(0, 2 * math.pi, n)
        # Outer skin (normals out) and inner skin (normals in) along +z.
        outer = np.column_stack([r_out * np.cos(t), r_out * np.sin(t), h])
        inner = np.column_stack([(r_out - wall) * np.cos(t), (r_out - wall) * np.sin(t), h])
        n_out = np.column_stack([np.cos(t), np.sin(t), np.full(n, -0.1)])
        pts = np.vstack([outer, inner])
        nrm = np.vstack([n_out, -n_out])
        prof = [[10.0, 0.0], [30.0, 200.0]]
        mouth = FF.cone_mouth(pts, nrm, np.zeros(3), np.array([0.0, 0.0, 1.0]), prof, tol=3.0)
        self.assertIsNotNone(mouth)
        self.assertEqual(mouth["boreMouth"], "end")
        self.assertAlmostEqual(mouth["wallMM"], wall, delta=0.6)
        self.assertAlmostEqual(mouth["boreRadiusMM"], 30.0 - wall, delta=0.8)
        self.assertGreater(mouth["boreDepthMM"], 150.0)                 # the inner skin is seen the whole way
        self.assertGreaterEqual(mouth["boreShare"], 0.9)
        for r_seen, h_seen in mouth["boreProfile"]:                      # the inner skin, where the scanner saw it
            self.assertAlmostEqual(r_seen, 10.0 + 0.1 * h_seen - wall, delta=0.8)
        # The same cone with only its outer skin: solid, no bore.
        self.assertIsNone(FF.cone_mouth(outer, n_out, np.zeros(3), np.array([0.0, 0.0, 1.0]), prof, tol=3.0))
        # A disc across the mouth: covered, no bore.
        lid = np.column_stack([rng.uniform(0, 15, 800) * np.cos(t[:800]), rng.uniform(0, 15, 800) * np.sin(t[:800]),
                               np.full(800, 199.5)])
        self.assertIsNone(FF.cone_mouth(np.vstack([pts, lid]), np.vstack([nrm, np.tile([0, 0, 1.0], (800, 1))]),
                                        np.zeros(3), np.array([0.0, 0.0, 1.0]), prof, tol=3.0))
        feature = {"kind": "revolve", "axis": {"origin": [5.0, -3.0, 2.0], "direction": [0.0, 0.0, 1.0]},
                   "profile": prof, "cone": True, "part": "horn", "radiusMM": 20.0, "lengthMM": 200.0}
        self.assertIsNone(BF.bore_profile(feature))
        bored = dict(feature, **mouth)
        bored["boreDepthMM"] = 100.0
        inner_prof = BF.bore_profile(bored)
        self.assertAlmostEqual(inner_prof[-1][1], 205.0)                 # 5 mm past the mouth
        self.assertAlmostEqual(inner_prof[0][1], 100.0)                  # the floor
        self.assertAlmostEqual(inner_prof[0][0], 20.0 - mouth["wallMM"], delta=0.7)
        self.assertEqual(mouth["boreMouthHMM"], 200.0)
        solid = P.feature_mesh(feature, sections=128)
        self.assertIsNone(P.feature_cut_mesh(feature, sections=128))
        cut_mesh = P.feature_cut_mesh(bored, sections=128)
        self.assertTrue(cut_mesh.is_watertight)
        hollow = trimesh.boolean.difference([solid, cut_mesh], engine="manifold")
        self.assertTrue(hollow.is_watertight)
        cut = math.pi * 100 * ((30 - wall) ** 2 + (30 - wall) * (20 - wall) + (20 - wall) ** 2) / 3   # the inner frustum, 100 tall
        self.assertAlmostEqual(solid.volume - hollow.volume, cut, delta=0.06 * cut)
        # The preview takes the cut out of the WHOLE model after the horn's
        # union, as `build_feature` does (its target is the body): a rod
        # standing in the horn's throat goes with it.
        frame = {"axisDirection": [0.0, 0.0, 1.0], "azimuthZero": [1.0, 0.0, 0.0], "azimuthNinety": [0.0, 1.0, 0.0],
                 "bores": [], "bosses": [], "bodies": []}
        rod = dict(frame, axisOrigin=[5.0, -3.0, 2.0 + 152.0], heightMM=40.0, bodyRadiusMM=8.0,
                   profile=[[8.0, 0.0], [8.0, 40.0]])
        model, notes, parts = P.build_preview(rod, [bored], sections=128)
        self.assertTrue(parts[-1].get("bored"), parts[-1])
        self.assertTrue(model.is_watertight, notes)
        self.assertAlmostEqual(model.volume, hollow.volume, delta=0.01 * hollow.volume)             # the rod is cut away
        apart = dict(rod, axisOrigin=[200.0, 0.0, 0.0])
        model, notes, parts = P.build_preview(apart, [bored], sections=128)
        self.assertAlmostEqual(model.volume, hollow.volume + math.pi * 64 * 40, delta=0.01 * hollow.volume)
        self.assertIn("bored 55 mm, 100 deep", BF.part_caption(bored))
        self.assertIn("bored", BF.feature_caption(dict(bored, part=None)))
        self.assertNotIn("bored", BF.part_caption(feature))


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class FeatureBuilderTests(unittest.TestCase):
    def test_oval_is_four_tangent_arcs_spanning_the_axes(self):
        import build_features as BF
        ents = BF.oval_entities(16.0, 11.0)
        self.assertEqual([e["kind"] for e in ents], ["arc"] * 4)
        pts = []
        for e in ents:
            c, r = e["center"], e["radius"]
            pts.append([(c[0] + r * math.cos(a), c[1] + r * math.sin(a)) for a in (e["startAngle"], e["endAngle"])])
        for (_, b), (a2, _) in zip(pts, pts[1:] + pts[:1]):
            self.assertLess(math.hypot(b[0] - a2[0], b[1] - a2[1]), 1e-3)   # tangent joins, closed
        xs = [ents[0]["center"][0] + ents[0]["radius"], ents[2]["center"][0] - ents[2]["radius"]]
        ys = [ents[1]["center"][1] + ents[1]["radius"], ents[3]["center"][1] - ents[3]["radius"]]
        self.assertAlmostEqual(xs[0], 16.0, places=3)
        self.assertAlmostEqual(xs[1], -16.0, places=3)
        self.assertAlmostEqual(ys[0], 11.0, places=3)
        self.assertAlmostEqual(ys[1], -11.0, places=3)
        self.assertEqual(BF.oval_entities(10.0, 9.8)[0]["kind"], "circle")   # nearly round: a circle

    def test_alpha_outline_of_a_plate_is_its_rectangle(self):
        import fit_features as FF
        rng = np.random.default_rng(2)
        xy = np.column_stack([rng.uniform(0, 40, 3000), rng.uniform(0, 20, 3000)])
        loop = FF.alpha_outline(xy, alpha=3.0)
        self.assertIsNotNone(loop)
        self.assertAlmostEqual(float(loop[:, 0].min()), 0.0, delta=1.0)
        self.assertAlmostEqual(float(loop[:, 0].max()), 40.0, delta=1.0)
        self.assertAlmostEqual(float(loop[:, 1].max()), 20.0, delta=1.0)


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class BarFitTests(unittest.TestCase):
    def test_raster_outline_of_a_ring_is_its_outer_circle(self):
        import fit_features as FF
        rng = np.random.default_rng(3)
        r = rng.uniform(8.0, 10.0, 4000)
        a = rng.uniform(0, 2 * math.pi, 4000)
        xy = np.column_stack([r * np.cos(a), r * np.sin(a)])
        loop, area, seed = FF.raster_outline(xy, cell=1.0)
        radii = np.linalg.norm(loop, axis=1)
        self.assertAlmostEqual(float(radii.max()), 10.0, delta=1.5)
        self.assertGreater(float(radii.min()), 8.0)          # the outer boundary, not the hole's
        self.assertAlmostEqual(area, math.pi * (100 - 64), delta=0.5 * math.pi * 36)   # the ring's own cells
        self.assertLess(math.hypot(*seed), 10.5)
        self.assertFalse(FF._loop_crosses_itself(loop))

    def test_a_welded_frame_is_two_bars(self):
        """A post and a beam at right angles (an L of 20 mm square bars),
        standing clear of a plate: two bars, each along its own axis, each
        about 20 mm square, each about as long as the box it came from."""
        import fit_features as FF
        post = trimesh.creation.box(extents=(20, 20, 200))
        post.apply_translation((0, 0, 100))
        beam = trimesh.creation.box(extents=(150, 20, 20))
        beam.apply_translation((75, 0, 190))
        frame = trimesh.util.concatenate([post, beam])
        plate = trimesh.creation.box(extents=(300, 300, 10))
        plate.apply_translation((0, 0, -100))
        res = FF.bar_fit(frame, 2.0, 5.0, FF.surface_tree(plate))
        self.assertIsNotNone(res)
        self.assertEqual(res["kind"], "bar")
        self.assertEqual(len(res["features"]), 2)
        self.assertGreater(res["coverage"], 0.7)           # of the boxes' 16 corners (the joint hides a few)
        by_axis = {}
        for f in res["features"]:
            self.assertEqual(f["kind"], "extrude")
            self.assertTrue(f.get("bar"))
            self.assertTrue(f.get("symmetric"))
            normal = np.cross(f["plane"]["xAxis"], f["plane"]["yAxis"])
            axis = int(np.argmax(np.abs(normal)))
            self.assertGreater(abs(normal[axis]), 0.98)
            by_axis[axis] = f
            self.assertTrue(16.0 <= f["sectionMM"] <= 27.0, f["sectionMM"])
            # the seed lies inside the outline, as the sketch's region pick needs
            loop = np.array([s["a"] for s in f["segments"] if s["kind"] == "line"])
            self.assertTrue(FF.point_in_polygon(f["seed"], loop))
        self.assertEqual(sorted(by_axis), [0, 2])                          # along x (the beam) and z (the post)
        self.assertAlmostEqual(by_axis[2]["lengthMM"], 200.0, delta=12.0)
        self.assertAlmostEqual(by_axis[0]["lengthMM"], 150.0, delta=12.0)
        # the extrude is symmetric about the bar's middle: the post's origin sits at mid-height
        self.assertAlmostEqual(by_axis[2]["plane"]["origin"][2], 100.0, delta=12.0)


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class PartsLibraryTests(unittest.TestCase):
    """fit_features' parts library: a stadium plate, a hex nut, a bent
    tube and a hoop come out as the parts they are."""

    def _far_plate(self):
        """A body the pieces stand clear of (so no end reaches into it)."""
        import fit_features as FF
        plate = trimesh.creation.box(extents=(600, 600, 10))
        plate.apply_translation((0, 0, -300))
        return FF.surface_tree(plate)

    def test_a_stadium_plate_is_a_lever(self):
        import fit_features as FF
        import preview_model as P
        loop = rounded_rectangle(90, 24, 12, per_arc=16)                 # a stadium 90 × 24 (the arcs meet at r = 12)
        lever = P.extrude_loop(loop, [30.0, -20.0, 50.0], [math.cos(0.4), math.sin(0.4), 0.0],
                               [-math.sin(0.4), math.cos(0.4), 0.0], 3.0, symmetric=True)
        res = FF.extrude_fit(lever, 1.0, 4.0, self._far_plate())
        self.assertIsNotNone(res)
        f = res["features"][0]
        self.assertEqual(f.get("shape", {}).get("kind"), "stadium", f.get("shape"))
        self.assertAlmostEqual(f["shape"]["lengthMM"], 90.0, delta=4.5)
        self.assertAlmostEqual(f["shape"]["widthMM"], 24.0, delta=1.2)
        self.assertEqual(FF.name_part(f), "lever")
        self.assertGreater(res["coverage"], 0.9)
        kinds = [s["kind"] for s in f["segments"]]
        self.assertEqual(kinds.count("arc"), 2)
        self.assertEqual(kinds.count("line"), 2)
        # The outline is drawn as the sketch takes it: a closed chain of lines and arcs.
        ents = F.sketch_entities(f["segments"])
        self.assertEqual(len(ents), 4)
        self.assertTrue(FF.point_in_polygon(f["seed"], FF.segments_polyline(f["segments"])))

    def test_a_hexagonal_prism_is_a_nut(self):
        import fit_features as FF
        across_flats = 36.0
        R = across_flats / 2 / math.cos(math.pi / 6)
        import preview_model as P
        hexagon = np.array([[R * math.cos(a), R * math.sin(a)] for a in np.linspace(0, 2 * math.pi, 6, endpoint=False) + 0.3])
        nut = P.extrude_loop(hexagon, [-40.0, 25.0, 80.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], 7.0, symmetric=True)
        res = FF.extrude_fit(nut, 1.0, 4.0, self._far_plate())
        self.assertIsNotNone(res)
        f = res["features"][0]
        self.assertEqual(f.get("shape", {}).get("kind"), "hexagon", f.get("shape"))
        self.assertAlmostEqual(f["shape"]["acrossFlatsMM"], across_flats, delta=0.05 * across_flats)
        self.assertEqual(FF.name_part(f), "nut")
        self.assertEqual(len(f["segments"]), 6)
        self.assertGreater(res["coverage"], 0.9)

    def test_a_bent_tube_is_one_sweep_with_one_radius(self):
        import fit_features as FF
        # A 6 mm tube along a quarter circle of 120 mm (an arch), standing clear of the body.
        t = np.linspace(0, math.pi / 2, 40)
        spine = np.column_stack([120 * np.cos(t), 120 * np.sin(t), np.zeros_like(t)])
        rings = []
        for i in range(len(t)):
            tangent = np.array([-math.sin(t[i]), math.cos(t[i]), 0.0])
            n1 = np.array([math.cos(t[i]), math.sin(t[i]), 0.0])
            n2 = np.cross(tangent, n1)
            rings.append([spine[i] + 6.0 * (math.cos(a) * n1 + math.sin(a) * n2) for a in np.linspace(0, 2 * math.pi, 24, endpoint=False)])
        rings = np.array(rings)
        faces = []
        k = 24
        for i in range(len(t) - 1):
            for j in range(k):
                a, b = i * k + j, i * k + (j + 1) % k
                c, d = (i + 1) * k + j, (i + 1) * k + (j + 1) % k
                faces += [[a, b, d], [a, d, c]]
        tube = trimesh.Trimesh(vertices=rings.reshape(-1, 3), faces=np.array(faces))
        tube.apply_translation((0, 0, 100))
        res = FF.tube_fit(tube, 1.0, 4.0, self._far_plate())
        self.assertIsNotNone(res)
        sweeps = [f for f in res["features"] if f["kind"] == "sweep"]
        self.assertEqual(len(res["features"]), 1, [f["kind"] for f in res["features"]])
        self.assertEqual(len(sweeps), 1)
        self.assertEqual(sweeps[0]["profile"]["shape"], "circle", sweeps[0]["profile"])
        self.assertNotIn("section", sweeps[0])                            # a tube is still a tube, not a bent bar
        self.assertAlmostEqual(sweeps[0]["profile"]["radius"], 6.0, delta=1.0)
        self.assertGreater(res["coverage"], 0.8)
        self.assertEqual(sweeps[0]["attached"], [False, False])
        self.assertIsNone(FF.name_part(sweeps[0]))                       # no body to hang from, no horn: the rules do not know
        self.assertEqual(FF.name_part(dict(sweeps[0], attached=[True, True])), "handle")
        self.assertEqual(FF.name_part(dict(sweeps[0], intoHorn=True)), "hose")
        # A bent round bar is the tube's: the bent-bar fit stands down (its
        # section is not flat), whatever legs it could lay through the arch.
        self.assertIsNone(FF.bent_bar_fit(tube, 1.0, 4.0, self._far_plate()))

    @staticmethod
    def _flat_bar(width=20.0, thick=5.0, legs=(80.0, 50.0), bend_deg=90.0):
        """A flat bar `width` × `thick` whose first leg runs along +x from
        the origin and whose second turns by `bend_deg` in the x/y plane
        (the wide face normal is z: an L bent edgewise, like a lever); a
        straight bar when `bend_deg` is 0. Subdivided so the sampler sees
        a scan's worth of points."""
        import preview_model as P
        sec = np.array([[-width / 2, -thick / 2], [width / 2, -thick / 2], [width / 2, thick / 2], [-width / 2, thick / 2]])
        a = math.radians(bend_deg)
        d2 = np.array([math.cos(a), math.sin(a), 0.0])
        corner = np.array([legs[0], 0.0, 0.0])
        spine = [[0, 0, 0], corner.tolist(), (corner + d2 * legs[1]).tolist()] if bend_deg else [[0, 0, 0], [legs[0] + legs[1], 0, 0]]
        mesh = P.sweep_section(sec, spine, [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]).subdivide().subdivide().subdivide()
        mesh.apply_translation([30.0, -20.0, 100.0])
        return mesh

    def test_an_l_shaped_flat_bar_is_one_bent_bar(self):
        """Two legs of 80 and 50 mm, a 20 × 5 mm section, a 90° bend: ONE
        sweep of a 20 × 5 rectangle along a three-point spine, the bend
        within 5°, the section within 10 %; the preview rebuilds it to
        its volume; the sketch is the designed section; it is a lever
        when it hangs from a body at one end."""
        import fit_features as FF
        import preview_model as P
        from build_features import sweep_sketch, feature_caption, part_caption
        from fit_primitives import sketch_entities
        bar = self._flat_bar()
        res = FF.bent_bar_fit(bar, 1.0, 4.0, self._far_plate())
        self.assertIsNotNone(res)
        self.assertEqual(res["kind"], "bentbar")
        self.assertEqual(len(res["features"]), 1)
        f = res["features"][0]
        self.assertEqual(f["kind"], "sweep")
        self.assertTrue(f["bent"])
        self.assertEqual(len(f["bendsDeg"]), 1)
        self.assertAlmostEqual(f["bendsDeg"][0], 90.0, delta=5.0)
        self.assertAlmostEqual(f["section"]["widthMM"], 20.0, delta=2.0)
        self.assertAlmostEqual(f["section"]["thicknessMM"], 5.0, delta=0.5)
        self.assertIn(f["section"]["shape"], ("rectangle", "stadium"))
        # The spine: three points for a sharp corner, the arc's points drawn
        # in otherwise; an arc clears the section's reach toward the bend's
        # centre (half the width, 10 mm, for a bar bent edgewise) by a
        # tolerance at least, and no ring of the sweep folds back.
        self.assertAlmostEqual(f["bendReachMM"], 10.0, delta=1.0)
        if f["bendRadiusMM"] == 0:
            self.assertEqual(len(f["spine"]), 3)
        else:
            self.assertGreater(len(f["spine"]), 3)
            self.assertGreaterEqual(f["bendRadiusMM"], f["bendReachMM"] + 1.0)
        self.assertEqual(FF.sweep_folds(FF.segments_polyline(f["section"]["segments"], 1.0), f["spine"], f["xAxis"]), [])
        self.assertEqual(len(f["corners"]), 1)
        self.assertAlmostEqual(sorted(f["legsMM"])[0], 50.0, delta=5.0)
        self.assertAlmostEqual(sorted(f["legsMM"])[1], 80.0, delta=8.0)
        self.assertGreater(res["coverage"], 0.85)
        # The sketch the app gets: the designed section, closed, of the bar's area.
        plane, entities, seed = sweep_sketch(f)
        loops = P.loops_of_entities(entities)
        self.assertEqual(len(loops), 1)
        self.assertAlmostEqual(abs(P.signed_area(loops[0])), 100.0, delta=12.0)
        self.assertTrue(P.point_in_loop(seed, loops[0]))
        self.assertEqual(entities, sketch_entities(f["section"]["segments"]))
        # The preview mirrors it: one closed solid of the bar's volume (its
        # free ends run on a tolerance each).
        mesh = P.feature_mesh(f)
        self.assertTrue(mesh.is_watertight)
        self.assertAlmostEqual(mesh.volume, 20 * 5 * 132, delta=0.06 * 20 * 5 * 132)
        # Named by where it hangs; captioned with its sizes and its bend.
        self.assertEqual(FF.name_part(f), "bar")
        self.assertEqual(FF.name_part(dict(f, attached=[True, False])), "lever")
        self.assertEqual(FF.name_part(dict(f, joins=[False, True])), "lever")
        self.assertEqual(FF.name_part(dict(f, attached=[True, True])), "handle")
        caption = part_caption(dict(f, part="lever"))
        self.assertTrue(caption.startswith("A lever · a 20 × 5 mm"), caption)
        self.assertIn("bent 9", caption)
        self.assertIn("mm long", feature_caption(f))
        # `tube_fit` on the same bar reads its flat run the same way: one sweep of a flat section.
        tube = FF.tube_fit(bar, 1.0, 4.0, self._far_plate())
        self.assertIsNotNone(tube)
        self.assertEqual(len(tube["features"]), 1)
        self.assertIn("section", tube["features"][0])
        self.assertAlmostEqual(tube["features"][0]["bendsDeg"][0], 90.0, delta=5.0)
        self.assertAlmostEqual(tube["features"][0]["section"]["widthMM"], 20.0, delta=2.0)

    def test_a_bend_never_folds_the_section(self):
        """An arc of half the width round a bar bent edgewise has no inside
        — the sweep's rings fold back on themselves, yet the mesh still
        closes at a plausible volume. `sweep_folds` sees the fold and the
        preview refuses it; the fit keeps the bend's radius clear of the
        section's reach (or the corner sharp): a 20 × 5 bar bent 30° and
        60° edgewise gets arcs of 12 mm (reach 10 + 10 % of the width),
        not the 10 it once got; a 150° hairpin, whose bins the geodesic
        cannot order, is no bar at all; and a sweep whose xAxis lies
        along its first leg gets the build's fallback frame, not a zero
        one."""
        import fit_features as FF
        import preview_model as P
        from build_features import sweep_sketch
        sec = np.array([[-10.0, -2.5], [10.0, -2.5], [10.0, 2.5], [-10.0, 2.5]])
        corner = [np.array([0.0, 0, 0]), np.array([80.0, 0, 0]), np.array([80.0, 50.0, 0])]
        for R, folds in ((0.0, False), (8.0, True), (10.0, True), (12.0, False), (20.0, False)):
            poly, _ = FF.fillet_spine(corner, R)
            legs = FF.sweep_folds(sec, poly, [0.0, 1.0, 0.0])
            self.assertEqual(bool(legs), folds, (R, legs))
            if folds:
                with self.assertRaises(ValueError):
                    P.sweep_section(sec, poly, [0.0, 1.0, 0.0], None)
            else:
                mesh = P.sweep_section(sec, poly, [0.0, 1.0, 0.0], None)
                self.assertTrue(mesh.is_watertight)
        for deg in (30.0, 60.0):
            res = FF.bent_bar_fit(self._flat_bar(bend_deg=deg), 1.0, 4.0, self._far_plate())
            self.assertIsNotNone(res, deg)
            f = res["features"][0]
            self.assertAlmostEqual(f["bendsDeg"][0], deg, delta=5.0)
            self.assertAlmostEqual(f["bendReachMM"], 10.0, delta=1.0)
            self.assertTrue(f["bendRadiusMM"] == 0 or f["bendRadiusMM"] >= 12.0 - 0.1, f["bendRadiusMM"])
            self.assertEqual(FF.sweep_folds(FF.segments_polyline(f["section"]["segments"], 1.0), f["spine"], f["xAxis"]), [])
            self.assertTrue(P.feature_mesh(f).is_watertight)
        hairpin = self._flat_bar(bend_deg=150.0)
        self.assertIsNone(FF.tube_fit(hairpin, 1.0, 4.0, self._far_plate()))
        self.assertIsNone(FF.bent_bar_fit(hairpin, 1.0, 4.0, self._far_plate()))
        frames = FF.sweep_frames([[0, 0, 0], [100, 0, 0], [100, 100, 0]], [1.0, 0, 0])
        plane, _, _ = sweep_sketch({"spine": [[0, 0, 0], [100, 0, 0], [100, 100, 0]], "xAxis": [1.0, 0, 0],
                                    "profile": {"shape": "circle", "radius": 1.0}})
        np.testing.assert_allclose(frames[0][3], plane["xAxis"], atol=1e-9)
        self.assertAlmostEqual(float(np.linalg.norm(frames[1][3])), 1.0, places=9)

    def test_a_straight_bar_is_still_a_bar(self):
        """A straight 20 × 5 × 130 bar: the bent-bar fit stands down (its
        spine is one leg) and `bar_fit` reads it as one bar of that section."""
        import fit_features as FF
        bar = self._flat_bar(bend_deg=0.0)
        self.assertIsNone(FF.bent_bar_fit(bar, 1.0, 4.0, self._far_plate()))
        res = FF.bar_fit(bar, 1.0, 4.0, self._far_plate())
        self.assertIsNotNone(res)
        self.assertEqual(res["kind"], "bar")
        self.assertEqual(len(res["features"]), 1)
        f = res["features"][0]
        self.assertTrue(f["bar"])
        self.assertAlmostEqual(f["lengthMM"], 130.0, delta=8.0)
        self.assertAlmostEqual(f["sectionMM"], 20.0, delta=2.0)
        self.assertEqual(FF.name_part(f), "bar")

    def test_corner_spine_counts_the_legs(self):
        """The spine fitter on centreline samples: a straight run is one
        leg, a 60° elbow two, a Z three; a quarter circle of ten widths'
        radius reads as three gentle legs (which the bend radius then
        rounds), a semicircle as none — a curve, left to the sweep."""
        import fit_features as FF
        rng = np.random.default_rng(7)

        def run(points, n):
            P = np.asarray(points, dtype=float)
            seg = np.linalg.norm(np.diff(P, axis=0), axis=1)
            s = np.concatenate([[0.0], np.cumsum(seg)])
            t = np.linspace(0, s[-1], n)
            C = np.column_stack([np.interp(t, s, P[:, k]) for k in range(3)])
            return C + rng.normal(0, 0.3, C.shape)
        straight = FF.corner_spine(run([[0, 0, 0], [100, 0, 0]], 20), 1.0, 20.0)
        self.assertEqual(straight["legs"], 1)
        elbow = FF.corner_spine(run([[0, 0, 0], [80, 0, 0], [80 + 60 * math.cos(math.radians(60)), 60 * math.sin(math.radians(60)), 0]], 28), 1.0, 20.0)
        self.assertEqual(elbow["legs"], 2)
        self.assertAlmostEqual(elbow["bendsDeg"][0], 60.0, delta=4.0)
        self.assertLess(np.linalg.norm(np.asarray(elbow["points"][1]) - [80, 0, 0]), 3.0)
        zee = FF.corner_spine(run([[0, 0, 0], [70, 0, 0], [70, 60, 0], [140, 60, 0]], 40), 1.0, 20.0)
        self.assertEqual(zee["legs"], 3)
        self.assertEqual(len(zee["bendsDeg"]), 2)
        a = np.linspace(0, math.pi / 2, 30)
        arc = np.column_stack([120 * np.cos(a), 120 * np.sin(a), np.zeros_like(a)])
        quarter = FF.corner_spine(arc, 1.0, 12.0)
        self.assertEqual(quarter["legs"], 3)
        self.assertLess(quarter["residualMM"], 1.8)
        a = np.linspace(0, math.pi, 60)
        half = np.column_stack([120 * np.cos(a), 120 * np.sin(a), np.zeros_like(a)])
        self.assertIsNone(FF.corner_spine(half, 1.0, 12.0))

    def test_a_ring_round_the_body_axis_is_a_hoop(self):
        import fit_features as FF
        # The body: a cylinder r 100, h 300 on y; the piece: a 10 × 12 mm hoop round it at h 150.
        body = trimesh.creation.cylinder(radius=100.0, height=300.0, sections=96)
        body.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))
        body.apply_translation([0, 150.0, 0])
        hoop = trimesh.creation.annulus(r_min=100.0, r_max=112.0, height=10.0, sections=96)
        hoop.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))
        hoop.apply_translation([0, 150.0, 0])
        analysis = {"axisOrigin": [0.0, 0.0, 0.0], "axisDirection": [0.0, 1.0, 0.0], "heightMM": 300.0,
                    "profile": [[100.0, 0.0], [100.0, 300.0]]}
        frame = FF.body_frame(analysis, 4.0)
        res = FF.hoop_fit(hoop, 1.0, 4.0, FF.surface_tree(body), body=frame)
        self.assertIsNotNone(res)
        self.assertEqual(res["kind"], "hoop")
        self.assertEqual(len(res["features"]), 1)
        f = res["features"][0]
        self.assertEqual(f["kind"], "revolve")
        self.assertTrue(f["hoop"])
        self.assertEqual(FF.name_part(f), "hoop")
        self.assertGreater(abs(f["axis"]["direction"][1]), 0.999)
        self.assertAlmostEqual(f["radiusMM"], 112.0, delta=1.5)
        self.assertAlmostEqual(f["lengthMM"], 10.0, delta=3.0)
        self.assertGreater(res["coverage"], 0.6)
        # The section is closed (first point = last) so a hollow body keeps its cavity…
        self.assertEqual(f["profile"][0], f["profile"][-1])
        self.assertGreater(min(p[0] for p in f["profile"]), 80.0)
        # …and it revolves to a ring of the right volume, placed on the body.
        import preview_model as P
        mesh = P.feature_mesh(f, sections=128)
        self.assertTrue(mesh.is_watertight)
        self.assertAlmostEqual(float(mesh.bounds[1][0]), 112.0, delta=1.5)
        self.assertGreater(mesh.volume, 0.8 * math.pi * (112 ** 2 - 100 ** 2) * 10)
        # A one-sided bulge is not a hoop (it spans 3 of the 24 sectors)…
        bulge = trimesh.creation.box(extents=(20, 40, 60))
        bulge.apply_translation([108.0, 150.0, 0])
        self.assertIsNone(FF.hoop_fit(bulge, 1.0, 4.0, FF.surface_tree(body), body=frame))
        # …nor is a ring all the way round that is out of round: the same
        # hoop stretched 10 % on x has its sectors' outer radii 112 → 123 mm,
        # a spread of ~11 mm against the max(2 tol, 4 %) = 4.5 allowed.
        oval = hoop.copy()
        oval.apply_scale([1.10, 1.0, 1.0])
        self.assertIsNone(FF.hoop_fit(oval, 1.0, 4.0, FF.surface_tree(body), body=frame))
        # …nor a round wall standing a few mm proud over most of the body's
        # height: 24 sectors at one radius, but 120 mm tall on a 216 mm
        # diameter — a ring is no taller than 0.35 of its diameter.
        wall = trimesh.creation.annulus(r_min=104.0, r_max=108.0, height=120.0, sections=96)
        wall.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))
        wall.apply_translation([0, 150.0, 0])
        self.assertIsNone(FF.hoop_fit(wall, 1.0, 4.0, FF.surface_tree(body), body=frame))
        # The same wall only 20 mm tall is a band round the body again.
        short = trimesh.creation.annulus(r_min=104.0, r_max=108.0, height=20.0, sections=96)
        short.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))
        short.apply_translation([0, 150.0, 0])
        res = FF.hoop_fit(short, 1.0, 4.0, FF.surface_tree(body), body=frame)
        self.assertIsNotNone(res)
        self.assertAlmostEqual(res["features"][0]["lengthMM"], 20.0, delta=3.0)


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
        # Nothing is far from anything: no patch of either kind.
        self.assertEqual(checks["patches"]["missing"], [])
        self.assertEqual(checks["patches"]["excess"], [])
        by = {c["check"]: c for c in checks["checks"]}
        self.assertEqual(by["largest_missing_patch"]["value"], 0.0)
        self.assertEqual(by["largest_excess_patch"]["value"], 0.0)

    def test_a_missing_boss_is_one_patch_where_the_boss_is(self):
        # Reference: a cylinder with a 20 mm boss on its +x side in the upper
        # third. Model: the plain cylinder. The boss's five exposed faces are
        # 2 000 mm²; the strip of its sides within 1.5 tolerances of the
        # wall does not count, so a little under that.
        plain = self._cylinder(100, 300)
        boss = trimesh.creation.box(extents=[20, 20, 20])
        boss.apply_translation([110, 0, 250])
        with_boss = trimesh.util.concatenate([self._cylinder(100, 300), boss])
        pr, pm = os.path.join(self.tmp, "boss.stl"), os.path.join(self.tmp, "plain.stl")
        with_boss.export(pr)
        plain.export(pm)
        checks = run_inspect(pr, pm, os.path.join(self.tmp, "boss-out"), 2.0, up="z")
        missing = checks["patches"]["missing"]
        self.assertEqual(len(missing), 1, missing)
        patch = missing[0]
        self.assertAlmostEqual(patch["areaMM2"], 2000.0, delta=500.0, msg=patch)
        self.assertIn("upper third", patch["location"])
        self.assertIn("on the right", patch["location"])          # +x is screen right in the front view
        self.assertAlmostEqual(patch["centreMM"][2], 250.0, delta=3.0)
        self.assertAlmostEqual(patch["centreMM"][0], 110.0, delta=3.0)
        self.assertGreater(patch["meanMM"], 5.0)
        by = {c["check"]: c for c in checks["checks"]}
        # The cylinder is 254 000 mm², so the limits are 0.25 % = 635 mm²
        # (WARN) and 1 % = 2 536 mm² (FAIL): the lost boss warns the part even
        # though every mean deviation passes — it is 0.7 % of the surface.
        self.assertEqual(by["largest_missing_patch"]["verdict"], "WARN", by["largest_missing_patch"])
        self.assertIn("on the right", by["largest_missing_patch"]["why"])
        self.assertEqual(by["ref_to_model_mean"]["verdict"], "PASS")

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
        # …and the lid is the largest excess patch: a disc at the rim's height.
        lid = checks["patches"]["excess"][0]
        self.assertGreater(lid["areaMM2"], 20000.0, lid)          # π·93² = 27 000 mm² beyond 3 mm of the ring
        self.assertAlmostEqual(lid["centreMM"][2], 300.0, delta=3.0, msg=lid)
        self.assertIn("upper third", lid["location"])
        self.assertEqual(by["largest_excess_patch"]["verdict"], "FAIL", by["largest_excess_patch"])

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


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class PreviewModelTests(unittest.TestCase):
    """`preview_model.py`: the offline solids have the volumes the app's ops
    would give, and the app-style measure reads an identical pair as perfect."""

    def test_oval_entities_chain_into_one_loop(self):
        import preview_model as P
        from build_features import oval_entities
        loops = P.loops_of_entities(oval_entities(8.0, 4.0))
        self.assertEqual(len(loops), 1)
        area = abs(P.signed_area(loops[0]))
        self.assertAlmostEqual(area, math.pi * 8 * 4, delta=0.06 * math.pi * 8 * 4)   # a four-centre oval, not an ellipse

    def test_revolve_extrude_and_sweep_volumes(self):
        import preview_model as P
        origin, x, y = [10.0, -5.0, 3.0], [0.0, 0.0, 1.0], [0.0, 1.0, 0.0]
        rev = P.revolve_loop(np.array([[0, 0], [12, 0], [12, 30], [0, 30]], float), origin, x, y, sections=128)
        self.assertTrue(rev.is_watertight)
        self.assertAlmostEqual(rev.volume, math.pi * 144 * 30, delta=0.01 * math.pi * 144 * 30)
        # revolved about the sketch's y axis, placed at the origin
        self.assertAlmostEqual(float(rev.bounds[0][1]), -5.0, places=5)
        self.assertAlmostEqual(float(rev.bounds[1][1]), 25.0, places=5)
        square = np.array([[-5, -5], [5, -5], [5, 5], [-5, 5]], float)
        tilted = [0.6, 0.8, 0.0]
        ext = P.extrude_loop(square, [1.0, 2.0, 3.0], tilted, [0.0, 0.0, 1.0], 7.0, symmetric=True)
        self.assertTrue(ext.is_watertight)
        self.assertAlmostEqual(ext.volume, 100 * 14, delta=1e-6)
        circle = np.column_stack([6 * np.cos(np.linspace(0, 2 * math.pi, 64, endpoint=False)),
                                  6 * np.sin(np.linspace(0, 2 * math.pi, 64, endpoint=False))])
        spine = [[0, 0, 0], [40, 0, 0], [40, 30, 0]]          # an L: a mitred corner keeps area × length
        swp = P.sweep_section(circle, spine, [0.0, 0.0, 1.0], [0.0, 1.0, 0.0])
        self.assertTrue(swp.is_watertight)
        area = abs(P.signed_area(circle))
        self.assertAlmostEqual(swp.volume, area * 70, delta=0.01 * area * 70)

    def test_build_preview_matches_pappus_and_measures_itself_perfect(self):
        import preview_model as P
        analysis = {"axisOrigin": [100.0, 20.0, -30.0], "axisDirection": [0.0, 1.0, 0.0],
                    "azimuthZero": [0.0, 0.0, 1.0], "azimuthNinety": [-1.0, 0.0, 0.0],
                    "heightMM": 100.0, "bodyRadiusMM": 20.0, "profile": [[20.0, 0.0], [20.0, 100.0]],
                    "profileSegments": None, "openTop": None, "sectionLoop": None,
                    "bosses": [{"azimuthDeg": 0.0, "centerHeightMM": 50.0, "reachMM": 60.0, "bodyRadiusMM": 20.0,
                                "innerStartMM": 8.0, "widthMM": 20.0, "neckWidthMM": 20.0, "heightSpanMM": 20.0,
                                "profile": [[10.0, 0.0], [10.0, 52.0]]}]}
        model, notes, parts = P.build_preview(analysis, sections=128)
        self.assertEqual(notes, [], notes)
        self.assertTrue(model.is_watertight)
        body = math.pi * 400 * 100
        boss_outside = math.pi * 100 * 40                     # the nozzle past the barrel's skin, near enough
        self.assertAlmostEqual(model.volume, body + boss_outside, delta=0.03 * (body + boss_outside))
        self.assertEqual([p["what"] for p in parts], ["revolve", "boss"])
        # the boss points along azimuth 0 = azimuthZero (+z) from the axis at x = 100
        self.assertAlmostEqual(float(model.bounds[1][2]), -30.0 + 60.0, places=3)
        metrics = P.app_metrics(model, model.copy(), 1.0)
        self.assertEqual(metrics["overallIoU"], 1.0)
        self.assertLess(metrics["modelToReference"]["maxMM"], 1e-6)
        self.assertLess(metrics["areaWeighted"]["referenceToModel"]["maxMM"], 1e-6)
        shifted = model.copy()
        shifted.apply_translation([0, 0, 6.0])
        self.assertLess(P.app_metrics(model, shifted, 1.0)["overallIoU"], 0.95)

    def test_build_preview_revolves_bodies_on_their_own_axes(self):
        """A body traced on its own axis (analysis["bodies"]) is revolved
        in its own sketch frame and unioned in, after the main revolve."""
        import preview_model as P
        pipe = {"index": 1, "parent": 0, "junction": "start", "extendedMM": [5.0, 0.0],
                "axisOrigin": [100.0, 50.0, -15.0], "axisDirection": [0.0, 0.0, 1.0],
                "azimuthZero": [1.0, 0.0, 0.0], "azimuthNinety": [0.0, 1.0, 0.0],
                "heightMM": 60.0, "bodyRadiusMM": 8.0, "profile": [[8.0, 0.0], [8.0, 60.0]],
                "profileSegments": None, "openTop": None, "sectionLoop": None}
        analysis = {"axisOrigin": [100.0, 20.0, -30.0], "axisDirection": [0.0, 1.0, 0.0],
                    "azimuthZero": [0.0, 0.0, 1.0], "azimuthNinety": [-1.0, 0.0, 0.0],
                    "heightMM": 100.0, "bodyRadiusMM": 20.0, "profile": [[20.0, 0.0], [20.0, 100.0]],
                    "profileSegments": None, "openTop": None, "sectionLoop": None, "bosses": [], "bodies": [pipe]}
        model, notes, parts = P.build_preview(analysis, sections=128)
        self.assertEqual(notes, [], notes)
        self.assertTrue(model.is_watertight)
        self.assertEqual([p["what"] for p in parts], ["revolve", "body"])
        self.assertEqual(parts[1]["extendedMM"], [5.0, 0.0])
        body = math.pi * 400 * 100
        # The pipe's foot (z = −15) sits inside the barrel (skin at z = −10);
        # 55 mm of it stand out, to z = 45.
        pipe_outside = math.pi * 64 * 55
        self.assertAlmostEqual(model.volume, body + pipe_outside, delta=0.03 * (body + pipe_outside))
        self.assertAlmostEqual(float(model.bounds[1][2]), 45.0, places=3)
        # The placement check leaves out what sits inside the model built
        # before the body and reads a body on its own surface as on it.
        fit = P.surface_to_scan(parts[1]["_mesh"], model, inside_of=parts[1]["_before"])
        self.assertLess(fit["meanMM"], 0.2)
        self.assertGreater(fit["points"], 50)
        self.assertLess(fit["points"], 3000)                       # the foot inside the barrel left out
        self.assertEqual(P.surface_to_scan(parts[1]["_mesh"], model)["points"], 3000)



class AxisFinderTests(unittest.TestCase):
    """fit_axes on a synthetic T: a vertical body with a horizontal pipe
    running into it, and the secondary-body helpers of analyze_scan."""

    @classmethod
    def setUpClass(cls):
        import trimesh
        sys.path.insert(0, HERE)
        import fit_axes
        import analyze_scan
        cls.F, cls.A, cls.tm = fit_axes, analyze_scan, trimesh
        body = trimesh.creation.cylinder(radius=30.0, height=240.0, sections=96)
        body.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))   # axis along y
        body.apply_translation([50.0, 120.0, 0.0])
        pipe = trimesh.creation.cylinder(radius=15.0, height=160.0, sections=64)
        pipe.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [0, 1, 0]))   # axis along x
        pipe.apply_translation([-50.0, 60.0, 0.0])                                             # x from -130 to 30: into the body
        cls.mesh = trimesh.util.concatenate([body, pipe])
        cls.result = fit_axes.find_axes(cls.mesh, samples=40000)

    def test_two_bodies_with_the_pipe_running_into_the_body(self):
        axes = self.result["axes"]
        self.assertEqual(len(axes), 2, [a["direction"] for a in axes])
        body, pipe = axes
        self.assertGreater(abs(body["direction"][1]), 0.995)
        self.assertGreater(abs(pipe["direction"][0]), 0.995)
        self.assertAlmostEqual(body["radiusMM"], 30.0, delta=1.0)
        self.assertAlmostEqual(pipe["radiusMM"], 15.0, delta=1.0)
        self.assertEqual(pipe["parent"], 0)
        self.assertIn(pipe["junction"], ("start", "end"))
        self.assertAlmostEqual(pipe["junctionParentRadiusMM"], 30.0, delta=1.5)
        # The pipe's extent stops at the body's skin, not at its axis.
        c, d = self.tm.util.np.array(pipe["origin"]), self.tm.util.np.array(pipe["direction"])
        ends = sorted(float((c + d * h)[0]) for h in (pipe["hMin"], pipe["hMax"]))
        self.assertAlmostEqual(ends[0], -130.0, delta=6.0)
        self.assertLess(ends[1], 26.0)

    def test_faces_are_labelled_by_body(self):
        labels = self.F.label_faces(self.mesh, self.result)
        centres = self.mesh.triangles_center
        on_pipe = centres[:, 0] < 10
        self.assertGreater((labels[on_pipe] == 1).mean(), 0.8)
        self.assertGreater((labels[~on_pipe] == 0).mean(), 0.8)

    def test_a_single_cylinder_has_one_axis(self):
        can = self.tm.creation.cylinder(radius=40.0, height=200.0, sections=96)
        can.apply_transform(self.tm.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))
        result = self.F.find_axes(can, samples=30000)
        self.assertEqual(len(result["axes"]), 1)
        self.assertAlmostEqual(result["axes"][0]["radiusMM"], 40.0, delta=1.0)

    def test_extend_and_trim_profile(self):
        a = {"axisOrigin": [0.0, 0.0, 0.0], "axisDirection": [0.0, 1.0, 0.0], "heightMM": 50.0,
             "profile": [[10.0, 0.0], [10.0, 20.0], [14.0, 20.0], [14.0, 50.0]],
             "profileSegments": [{"kind": "line", "a": [10.0, 0.0], "b": [10.0, 20.0]},
                                 {"kind": "line", "a": [10.0, 20.0], "b": [14.0, 20.0]},
                                 {"kind": "line", "a": [14.0, 20.0], "b": [14.0, 50.0]}]}
        self.A.trim_profile(a, 5.0, 0.0)
        self.assertAlmostEqual(a["heightMM"], 45.0)
        self.assertAlmostEqual(a["axisOrigin"][1], 5.0)
        self.assertEqual(a["profile"][0], [10.0, 0.0])
        self.assertEqual(a["profileSegments"][0]["a"], [10.0, 0.0])
        self.A.extend_profile(a, 12.0, 3.0)
        self.assertAlmostEqual(a["heightMM"], 60.0)
        self.assertAlmostEqual(a["axisOrigin"][1], -7.0)                   # the foot moved down by the extension
        self.assertEqual(a["profileSegments"][0], {"kind": "line", "a": [10.0, 0.0], "b": [10.0, 12.0]})
        self.assertEqual(a["profileSegments"][-1]["b"], [14.0, 60.0])
        self.assertEqual(a["extendedMM"], [12.0, 3.0])

    def test_a_full_ring_beats_continuity(self):
        # A hand-wheel's rim (36 mm, most sectors) above a 6 mm stem: the
        # band is the rim's, not the stem's.
        sectors = [36.0] * 30 + [7.0] * 6
        self.assertAlmostEqual(self.A.agreed_radius(sectors, previous=6.0, sector_medians=sectors), 36.0)
        # Three caps (a third of the sectors each, in three pieces) round a
        # barrel keep the barrel's radius.
        meds = ([150.0] * 5 + [80.0] * 7) * 3
        self.assertAlmostEqual(self.A.agreed_radius(meds, previous=80.0, sector_medians=meds), 80.0)


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class NutTests(unittest.TestCase):
    """analyze_scan.find_nuts and build_hydrant.nut_sections: a hexagonal
    prism on a cylinder is a hex nut (its sides, across-flats and phase
    read back), a round collar is not, an octagon is eight-sided, a
    hexagon at a branch's root is recorded on that body, and the polygon
    the build extrudes has the corners where the scan had them."""

    @staticmethod
    def prism(n, apothem, phase_deg, z0, z1):
        import preview_model as P
        R = apothem / math.cos(math.pi / n)
        phi = math.radians(phase_deg)
        loop = np.array([[R * math.cos(phi + math.pi / n + 2 * math.pi * k / n),
                          R * math.sin(phi + math.pi / n + 2 * math.pi * k / n)] for k in range(n)])
        return P.extrude_loop(loop, [0, 0, z0], [1, 0, 0], [0, 1, 0], z1 - z0)

    @classmethod
    def on_a_cylinder(cls, tool):
        body = trimesh.creation.cylinder(radius=15.0, height=200.0, sections=128)
        body.apply_translation([0, 0, 100.0])
        return trimesh.boolean.union([body, tool], engine="manifold")

    @staticmethod
    def analyse(mesh):
        import analyze_scan as A
        return A.analyze(mesh, out_dir=None, name="nut", samples=20000, axis_choice="0,0,1!", multi=False)

    def test_a_hexagonal_prism_on_a_cylinder_is_a_hex_nut(self):
        a = self.analyse(self.on_a_cylinder(self.prism(6, 23.0, 20.0, 100.0, 118.0)))
        self.assertEqual(len(a["nuts"]), 1, a["nuts"])
        nut = a["nuts"][0]
        self.assertEqual(nut["sides"], 6)
        self.assertAlmostEqual(nut["acrossFlatsMM"], 46.0, delta=0.02 * 46.0)
        self.assertLess(abs((nut["phaseDeg"] - 20.0 + 30.0) % 60.0 - 30.0), 3.0)
        self.assertAlmostEqual(nut["h0"], 100.0, delta=3.0)
        self.assertAlmostEqual(nut["h1"], 118.0, delta=3.0)
        self.assertGreaterEqual(nut["share"], 0.8)
        # The revolve runs inside the flats over the nut's span: nothing
        # round pokes out of them, the prism carries the corners.
        inside = [r for r, h in a["profile"] if 100.0 <= h <= 118.0 and r > 16.0]
        self.assertTrue(inside and max(inside) <= 23.0 + 0.3, a["profile"])

    def test_a_round_collar_is_not_a_nut(self):
        collar = trimesh.creation.cylinder(radius=23.0, height=18.0, sections=128)
        collar.apply_translation([0, 0, 109.0])
        a = self.analyse(self.on_a_cylinder(collar))
        self.assertEqual(a["nuts"], [])
        self.assertAlmostEqual(max(r for r, h in a["profile"] if 100.0 <= h <= 118.0), 23.0, delta=0.3)

    def test_an_octagon_is_an_eight_sided_nut(self):
        a = self.analyse(self.on_a_cylinder(self.prism(8, 30.0, 10.0, 60.0, 84.0)))
        self.assertEqual([n["sides"] for n in a["nuts"]], [8])
        self.assertAlmostEqual(a["nuts"][0]["acrossFlatsMM"], 60.0, delta=0.02 * 60.0)
        self.assertLess(abs((a["nuts"][0]["phaseDeg"] - 10.0 + 22.5) % 45.0 - 22.5), 3.0)

    def test_a_hexagon_at_a_branch_root_is_the_branch_body_s_nut(self):
        """The T of AxisFinderTests (a body r 30 on y, a pipe r 15 on x
        running into it at x = 20) with a 34 mm hex nut on the pipe where
        it meets the body (x 8–20, a flat facing +z). The nut is read on
        the pipe's own axis before its root is trimmed, recorded on that
        body, and the build's prism sits where the scan's nut is."""
        import analyze_scan as A
        import build_hydrant as B
        import preview_model as P
        body = trimesh.creation.cylinder(radius=30.0, height=240.0, sections=96)
        body.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))
        body.apply_translation([50.0, 120.0, 0.0])
        pipe = trimesh.creation.cylinder(radius=15.0, height=160.0, sections=64)
        pipe.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [0, 1, 0]))
        pipe.apply_translation([-50.0, 60.0, 0.0])
        nut = self.prism(6, 17.0, 90.0, 8.0, 20.0)                        # on z; a flat's normal along +y…
        nut.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [0, 1, 0]))   # …now on x, that flat facing +z? no: (y stays y)
        nut.apply_translation([0.0, 60.0, 0.0])
        # After the turn about y the prism's axis is +x and the flat that
        # faced +y still faces +y; the pipe's azimuth zero is +z, so that
        # flat's normal sits at ±90° — a corner at 0°, a flat at 30°.
        mesh = trimesh.boolean.union([trimesh.boolean.union([body, pipe], engine="manifold"), nut], engine="manifold")
        self.assertTrue(mesh.is_watertight)
        # The main axis as the corpus gets it: the finder's strongest body
        # (a refined "0,1,0" is dragged onto the diagonal by the pipe).
        a = A.analyze(mesh, out_dir=None, name="tee", samples=40000, axis_choice="auto", multi=True)
        self.assertEqual(len(a["bodies"]), 1, [b.get("tag") for b in a["bodies"]])
        branch = a["bodies"][0]
        self.assertEqual(len(branch["nuts"]), 1, branch["nuts"])
        found = branch["nuts"][0]
        self.assertEqual(found["sides"], 6)
        self.assertAlmostEqual(found["acrossFlatsMM"], 34.0, delta=0.02 * 34.0)
        self.assertLess(abs((found["phaseDeg"] - 30.0 + 30.0) % 60.0 - 30.0), 3.0)
        self.assertEqual(a["nuts"], [])                                   # nothing polygonal on the body's own axis
        # In the world: the nut's span along the pipe's axis is x 8–20.
        o, d = np.array(branch["axisOrigin"]), np.array(branch["axisDirection"])
        ends = sorted(float((o + d * h)[0]) for h in (found["h0"], found["h1"]))
        self.assertAlmostEqual(ends[0], 8.0, delta=3.0)
        self.assertAlmostEqual(ends[1], 20.0, delta=3.0)
        # The build: one prism on the branch's axis, 34 mm across the
        # flats, placed where the nut is; the preview unions it in.
        sections = B.nut_sections(a)
        self.assertEqual(len(sections), 1)
        sec = sections[0]
        self.assertEqual(sec["body"], branch["index"])
        self.assertEqual(len(sec["entities"]), 6)
        self.assertAlmostEqual(abs(np.cross(sec["plane"]["xAxis"], sec["plane"]["yAxis"])[0]), 1.0, places=3)
        self.assertAlmostEqual(min(sec["plane"]["origin"][0], sec["plane"]["origin"][0] + sec["distance"] * np.sign(d[0])), 8.0, delta=3.0)
        model, notes, parts = P.build_preview(a, sections=64)
        self.assertIn("nut", [p["what"] for p in parts])
        self.assertTrue(model.is_watertight, notes)
        self.assertLess(abs(model.volume - mesh.volume) / mesh.volume, 0.04)

    def test_nut_sections_polygon_has_the_corners_where_the_record_says(self):
        import build_hydrant as B
        import preview_model as P
        analysis = {"axisOrigin": [10.0, -5.0, 2.0], "axisDirection": [0.0, 1.0, 0.0],
                    "azimuthZero": [0.0, 0.0, 1.0], "azimuthNinety": [-1.0, 0.0, 0.0],
                    "heightMM": 100.0, "bodyRadiusMM": 15.0, "profile": [[15.0, 0.0], [15.0, 100.0]],
                    "profileSegments": None, "openTop": None, "sectionLoop": None, "bosses": [], "bodies": [],
                    "nuts": [{"h0": 40.0, "h1": 58.0, "sides": 6, "acrossFlatsMM": 46.0, "phaseDeg": 20.0, "share": 1.0}]}
        secs = B.nut_sections(analysis)
        self.assertEqual(len(secs), 1)
        sec = secs[0]
        self.assertEqual(sec["distance"], 18.0)
        self.assertEqual(sec["plane"]["origin"], [10.0, 35.0, 2.0])
        x, y = np.array(sec["plane"]["xAxis"]), np.array(sec["plane"]["yAxis"])
        # x is azimuth zero (+z) turned 20° toward azimuth ninety (−x); the extrude (x × y) runs up the axis.
        self.assertTrue(np.allclose(x, [-math.sin(math.radians(20.0)), 0.0, math.cos(math.radians(20.0))], atol=1e-6))
        self.assertTrue(np.allclose(np.cross(x, y), [0.0, 1.0, 0.0], atol=1e-6))
        # Six corners at the corner radius, the first pair ±30° from the flat's normal (+x of the sketch).
        pts = [e["a"] for e in sec["entities"]]
        self.assertEqual(len(pts), 6)
        R = 23.0 / math.cos(math.pi / 6)
        for p in pts:
            self.assertAlmostEqual(math.hypot(*p), R, places=3)
        angles = sorted(round(math.degrees(math.atan2(p[1], p[0])) % 360.0) for p in pts)
        self.assertEqual(angles, [30, 90, 150, 210, 270, 330])
        self.assertEqual(B.nut_words(analysis["nuts"][0]), "a 46 mm hex nut, 18 mm tall")
        import build_features as BF
        self.assertEqual(BF.nut_caption(sec), "A 46 mm hex nut · a hexagon on the body's axis, extruded 18 mm and unioned in")
        # The preview: the cylinder plus what the prism adds outside it.
        model, notes, parts = P.build_preview(analysis, sections=128)
        self.assertEqual(notes, [])
        self.assertEqual([p["what"] for p in parts], ["revolve", "nut"])
        expected = math.pi * 225.0 * 100.0 + (2 * math.sqrt(3) * 23.0 ** 2 - math.pi * 225.0) * 18.0
        self.assertAlmostEqual(model.volume, expected, delta=0.01 * expected)
        self.assertAlmostEqual(float(model.bounds[1][1]), 95.0, places=3)                 # the axis origin sits at y = −5

    def test_the_bands_over_a_nut_are_clamped_but_a_crown_round_it_is_not(self):
        import analyze_scan as A
        nut = {"h0": 10.0, "h1": 20.0, "sides": 6, "acrossFlatsMM": 46.0, "phaseDeg": 0.0, "share": 1.0}
        bands = [{"h": 5.0, "median": 25.0}, {"h": 12.0, "median": 25.0}, {"h": 15.0, "median": 42.0}, {"h": 18.0, "median": 23.5}]
        self.assertEqual(A.clamp_bands_to_nuts(bands, [nut], 0.1), 2)
        self.assertEqual([b["median"] for b in bands], [25.0, 23.0, 42.0, 23.0])


@unittest.skipUnless(HAVE_DEPS, "needs the scan_to_cad venv (trimesh, numpy, scipy, rtree, pillow)")
class ScanColorTests(unittest.TestCase):
    """`analyze_scan.scan_color` reads the scan's dominant colour off its
    texture or vertex colours, and `build_hydrant.model_color` resolves a
    spec's colour against it."""

    @staticmethod
    def textured_quad(image):
        # A unit quad whose UVs span the whole texture, so the texture's
        # area shares are the surface's.
        quad = trimesh.Trimesh([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], [[0, 1, 2], [0, 2, 3]], process=False)
        # A glTF-style material, as the corpus scans carry: the texture with
        # no base-colour factor (trimesh's SimpleMaterial would export a
        # default grey diffuse as a factor of 0.4 and darken the swatch).
        material = trimesh.visual.material.PBRMaterial(baseColorTexture=image)
        quad.visual = trimesh.visual.TextureVisuals(uv=[[0, 0], [1, 0], [1, 1], [0, 1]], material=material)
        return quad

    def test_texture_that_is_mostly_one_colour_gives_that_colour(self):
        import analyze_scan as A
        from PIL import Image
        # 70 % of the columns blue, 30 % yellow.
        image = Image.new("RGB", (100, 20), (51, 102, 204))
        image.paste((230, 200, 25), (70, 0, 100, 20))
        found = A.scan_color_record(self.textured_quad(image))
        self.assertEqual(found["source"], "texture")
        for got, want in zip(found["rgb"], [0.2, 0.4, 0.8]):
            self.assertAlmostEqual(got, want, delta=0.03)
        self.assertAlmostEqual(found["share"], 0.7, delta=0.05)
        self.assertEqual(len(A.scan_color(self.textured_quad(image))), 3)

    def test_a_painted_colour_beats_a_slightly_larger_neutral_one(self):
        # A spray can: 45 % white lettering and bare metal, 40 % blue label,
        # 15 % yellow cap — the eye calls it blue, and so does the vote.
        import analyze_scan as A
        from PIL import Image
        image = Image.new("RGB", (100, 20), (235, 235, 230))
        image.paste((15, 25, 105), (45, 0, 85, 20))
        image.paste((225, 200, 25), (85, 0, 100, 20))
        found = A.scan_color_record(self.textured_quad(image))
        r, g, b = found["rgb"]
        self.assertGreater(b, 0.3)
        self.assertLess(r, 0.15)
        self.assertAlmostEqual(found["share"], 0.4, delta=0.05)

    def test_dark_colour_is_lifted_with_its_hue(self):
        import analyze_scan as A
        rgb = A.lift_shadow([0.10, 0.02, 0.02])
        self.assertAlmostEqual(rgb[0], 0.25, places=3)
        self.assertAlmostEqual(rgb[1] / rgb[0], 0.2, places=3)
        self.assertEqual(A.lift_shadow([0.5, 0.5, 0.5]), [0.5, 0.5, 0.5])

    def test_textured_glb_round_trip_by_path(self):
        import analyze_scan as A
        from PIL import Image
        image = Image.new("RGB", (16, 16), (51, 102, 204))
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "quad.glb")
            self.textured_quad(image).export(path)
            rgb = A.scan_color(path)
        for got, want in zip(rgb, [0.2, 0.4, 0.8]):
            self.assertAlmostEqual(got, want, delta=0.03)

    def test_vertex_colours_are_the_fallback_and_a_plain_mesh_has_none(self):
        import analyze_scan as A
        box = trimesh.creation.box()
        self.assertIsNone(A.scan_color(box))
        self.assertIsNone(A.scan_color_record(box))
        box.visual.vertex_colors = [200, 30, 40, 255]
        found = A.scan_color_record(box)
        self.assertEqual(found["source"], "vertex")
        for got, want in zip(found["rgb"], [200 / 255, 30 / 255, 40 / 255]):
            self.assertAlmostEqual(got, want, delta=0.01)

    def test_base_colour_factor_multiplies_in_linear_light(self):
        # glTF's baseColorFactor scales the texture in linear light: half
        # of white is 0.5 linear, 0.735 in sRGB — not a mid grey of 0.5.
        import analyze_scan as A
        from PIL import Image
        quad = self.textured_quad(Image.new("RGB", (16, 16), (255, 255, 255)))
        quad.visual.material.baseColorFactor = [0.5, 0.5, 0.5, 1.0]
        found = A.scan_color_record(quad)
        for c in found["rgb"]:
            self.assertAlmostEqual(c, 0.735, delta=0.01)
        # The curve is its own inverse, and 0.5 linear is the known 0.735.
        self.assertAlmostEqual(float(A.linear_to_srgb(A.srgb_to_linear(0.3))), 0.3, places=6)
        self.assertAlmostEqual(float(A.linear_to_srgb(0.5)), 0.7354, places=3)

    def test_color_option_takes_scan_or_three_numbers_only(self):
        from build_hydrant import color_option
        self.assertEqual(color_option(None), "scan")
        self.assertEqual(color_option(["scan"]), "scan")
        self.assertEqual(color_option(["0.1", "0.2", "0.3"]), [0.1, 0.2, 0.3])
        for bad in (["scan", "1", "2"], ["0.1", "0.2"], ["red"], ["a", "b", "c"]):
            with self.assertRaises(SystemExit):
                color_option(bad)

    def test_every_profile_writing_recursion_of_analyze_forwards_the_source(self):
        # analyze() traces an open drum again when its rim comes out at the
        # bottom, and the inner call is the one that writes profile.json —
        # so it must carry `source`, or the profile has no scanColor and
        # the model falls back to hydrant red. A full run on a synthetic
        # cup takes 40 s, so the call is checked where it stands.
        import ast
        with open(os.path.join(HERE, "analyze_scan.py")) as f:
            tree = ast.parse(f.read())
        analyze = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "analyze")
        recursions = [n for n in ast.walk(analyze)
                      if isinstance(n, ast.Call) and getattr(n.func, "id", None) == "analyze"]
        self.assertTrue(recursions)
        for call in recursions:
            keywords = {k.arg: k.value for k in call.keywords}
            writes = not (isinstance(keywords.get("out_dir"), ast.Constant) and keywords["out_dir"].value is None)
            if writes:
                self.assertIn("source", keywords, ast.unparse(call))

    def test_the_colour_resolver_is_standard_library_only(self):
        # `run_corpus.py` runs under any python3 and imports the resolver
        # from `spec_color`; it must not pull numpy in behind it.
        import ast
        with open(os.path.join(HERE, "spec_color.py")) as f:
            tree = ast.parse(f.read())
        imported = [n.names[0].name for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom))]
        self.assertEqual(imported, [])
        with open(os.path.join(HERE, "run_corpus.py")) as f:
            self.assertNotIn("from build_hydrant", f.read())

    def test_model_color_resolves_the_spec_against_the_analysis(self):
        from build_hydrant import model_color, HYDRANT_RED
        analysis = {"scanColor": {"rgb": [0.2, 0.4, 0.8], "share": 0.7, "source": "texture"}}
        self.assertEqual(model_color({"color": [0.1, 0.2, 0.3]}, analysis), [0.1, 0.2, 0.3])   # a list is itself
        self.assertEqual(model_color({"color": "scan"}, analysis), [0.2, 0.4, 0.8])            # "scan": the analysis
        self.assertEqual(model_color({}, analysis), [0.2, 0.4, 0.8])                           # absent: the same
        self.assertEqual(model_color({"color": "scan"}, {}), HYDRANT_RED)                      # no colour recorded
        self.assertEqual(model_color({}, None), HYDRANT_RED)
        with self.assertRaises(ValueError):
            model_color({"color": "red"}, analysis)


if __name__ == "__main__":
    unittest.main()
