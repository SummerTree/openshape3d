"""Touch sequences for the YouTube Shorts ("How do you model this?"), shot
upright on an iPhone (the `os3d-shorts` simulator, 440 × 956 points).

Same rules as actions.py: every step is a real touch that the test reports
(so compose can ring it), the bridge is only READ, and a step that does not
land raises `Missed` instead of falling back. Differences on the phone:

* the palette covers the left fifth of the screen and the bars the bottom,
  so "on screen" means the free viewport between them (`VIEW`);
* picking a plane does not always turn the camera at once — when the app
  offers "Look at Sketch", tap it;
* the aligned sketch camera can be very close (≈ 94 points per millimetre)
  or not, so first drags are sized in screen points (`span`) and the typed
  dimension sets the real size.

A builder yields step ids (shorts_text.py) and then performs the step; the
last step is always "reveal", an orbit of the finished part that compose also
uses for the opening hook.
"""
import math
from common import call, normalized, POINTS, log
import actions
from actions import (A, Missed, near, box, body_of, plane_fns, sketch_last, entities, extrude_tap,
                     extrude_distance, arm_blend, apply_blend)

VIEW = (0.22, 0.95, 0.15, 0.78)          # x0, x1, y0, y1 of the free viewport, window-normalised


class P(A):
    def visible(self, p):
        x, y = self.screen(p)
        if not (VIEW[0] < x < VIEW[1] and VIEW[2] < y < VIEW[3]):
            self.fit()
            x, y = self.screen(p)
        return x, y

    def look(self):
        """Tap Look at Sketch when the camera did not turn to the new sketch."""
        if self.touch("exists:Look at Sketch", expect="") == "done:yes":
            self.button("Look at Sketch", wait=1.4)

    def deselect(self, wait=0.7):
        """A tap on empty grid under the palette; check that it took."""
        for x, y in ((0.14, 0.9), (0.9, 0.26)):
            self.tap_screen(x, y, wait)
            if not call("/v1/state").get("selection"):
                return
        raise Missed("could not clear the selection")

    def double_tap(self, p, wait=1.0):
        self.touch("double_tap:" + actions.nstr(self.visible(p))); self.pause(wait)

    def selected(self):
        return call("/v1/state").get("selection") or []


# ---- sizes on screen ------------------------------------------------------------------------------

def ppm(W):
    """Screen points per sketch millimetre at the sketch origin."""
    (x0, y0), (x1, y1) = normalized([W(0, 0), W(1, 0)])
    return math.hypot((x1 - x0) * POINTS[0], (y1 - y0) * POINTS[1])


def span(W, pts):
    """A length in mm that spans about `pts` points, on the 0.5 mm snap grid."""
    return max(0.5, round(pts / ppm(W) * 2) / 2)


def rect(a, start=(0.0, 0.0), pts=(70, 50)):
    W, _ = plane_fns(sketch_last())
    actions.draw_rect(a, start, span=(span(W, pts[0]), span(W, pts[1])))


def circle(a, centre=(0.0, 0.0), pts=45):
    W, _ = plane_fns(sketch_last())
    actions.draw_circle(a, centre, span(W, pts))


def clear_point(candidates, curves):
    """The candidate (world) farthest ON SCREEN from every curve (each a list
    of world points): a tap within ~18 pt of a sketch curve picks the curve."""
    pts = normalized(list(candidates) + [p for c in curves for p in c])
    cand, rest = pts[:len(candidates)], pts[len(candidates):]
    def gap(i):
        return min(math.hypot((cand[i][0] - q[0]) * POINTS[0], (cand[i][1] - q[1]) * POINTS[1]) for q in rest)
    best = max(range(len(cand)), key=gap)
    return candidates[best], gap(best)


def circle_pts(c, r, axes, n=72):
    (ux, uy, uz), (vx, vy, vz) = axes
    return [(c[0] + r * (math.cos(t) * ux + math.sin(t) * vx), c[1] + r * (math.cos(t) * uy + math.sin(t) * vy),
             c[2] + r * (math.cos(t) * uz + math.sin(t) * vz)) for t in (2 * math.pi * k / n for k in range(n))]


def line_pts(p, q, n=40):
    return [tuple(p[i] + (q[i] - p[i]) * k / n for i in range(3)) for k in range(n + 1)]


def region_tap(a, world):
    before = {b["id"] for b in a.bodies()}
    extrude_tap(a, world)
    return before


def pick_ground(a):
    for _ in range(2):
        a.tap((1.0, 0, 1.0), wait=2.4)               # the green ground tile at the origin
        if str(a.mode()).startswith("sketching"):
            break
    a.expect(str(a.mode()).startswith("sketching"), "the ground plane pick missed")
    a.look()


def plane_normal(sk):
    xa, ya = sk["plane"]["xAxis"], sk["plane"]["yAxis"]
    return (xa[1] * ya[2] - xa[2] * ya[1], xa[2] * ya[0] - xa[0] * ya[2], xa[0] * ya[1] - xa[1] * ya[0])


def pick_face(a, point, normal):
    """Tap a face to sketch on it, and check the sketch is on THAT face: the
    plane picker's origin tiles can sit over a face near the origin and win
    the tap. Tap well away from the origin."""
    actions.pick_face(a, point)
    n = plane_normal(sketch_last())
    a.expect(all(near(n[i], normal[i], 0.01) for i in range(3)), f"sketching on a plane with normal {n}, not {normal}")
    a.look()


def exit_iso(a):
    a.fit()
    a.exit_sketch()


def material(a, point, preset, select=True):
    if select:
        a.double_tap(point, wait=1.4)
        a.expect(a.selected(), f"the double tap at {point} selected nothing")
    a.tap_id("MaterialButton", wait=1.6)
    a.expect(a.exists("MaterialApply"), "the Material sheet did not open")
    a.tap_id("MaterialPreset" + preset.replace(" ", ""), wait=1.0)
    a.tap_id("MaterialApply", wait=1.8)
    a.deselect()


def focus(a):
    """Where the finished part sits on screen (window-normalised box), for the hook's zoom."""
    xs, ys = [], []
    for b in a.bodies():
        (x0, y0, z0), (x1, y1, z1) = b["bounds"]
        corners = [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]
        for x, y in normalized(corners):
            xs.append(x); ys.append(y)
    return [min(xs), min(ys), max(xs), max(ys)]


def reveal(a, view=None):
    yield "reveal"
    if a.selected():
        a.deselect()
    if view:
        a.view(view)
    a.fit(wait=1.4)
    a.t.tl.cur["focus"] = focus(a)
    a.t.tl.mark()                                       # the orbit starts: the hook plays from here
    a.touch("orbit:0.93,0.24;0.45,0.25;90"); a.pause(0.8)


# ---- the shared opening: a block ---------------------------------------------------------------

def block(a, width, depth, height):
    yield "new"
    a.new_design()
    yield "rect_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.4)
    yield "ground"
    pick_ground(a)
    yield "draw"
    rect(a)
    yield "width"
    a.dimension(width, 0)
    a.expect(near(actions.rect_size()[0], width, 0.01), "the width did not take")
    yield "depth"
    a.dimension(depth, 1)
    a.expect(near(actions.rect_size()[1], depth, 0.01), "the depth did not take")
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    W, _ = plane_fns(sketch_last())
    before = region_tap(a, W(width / 2, depth / 2))
    yield "height"
    body = extrude_distance(a, height, before)["id"]
    a.deselect()
    a.fit()
    return body


def disc(a, diameter, height, then_hole=None):
    """A circle on the ground (optionally with a concentric hole), extruded."""
    yield "new"
    a.new_design()
    yield "circle_tool"
    a.palette_label("Sketch", "Circle", wait=1.4)
    yield "ground"
    pick_ground(a)
    yield "draw"
    circle(a)
    yield "size"
    a.dimension(diameter, 0, wait=1.2)
    a.expect(near(entities("circle")[-1]["radius"], diameter / 2, 0.01), "the diameter did not take")
    if then_hole:
        yield "fit"
        a.fit()
        yield "hole"
        circle(a, pts=40)
        yield "hole_size"
        a.dimension(then_hole, 0, wait=1.2)
        a.expect(near(entities("circle")[-1]["radius"], then_hole / 2, 0.01), "the hole size did not take")
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    if then_hole:
        # the band is thinner on screen than the edge-pick radius: zoom in, and
        # tap it where it is widest on screen (its left/right, not front/back)
        yield "zoom"
        a.touch("pinch:2.0;1.2"); a.pause(1.0)
    yield "tap_region"
    r = (diameter / 2 + then_hole / 2) / 2 if then_hole else 0.0
    before = region_tap(a, (r * 0.7071, 0, -r * 0.7071))
    yield "height"
    body = extrude_distance(a, height, before)["id"]
    a.deselect()
    a.fit()
    return body


# ---- 1. spring (Helix) ---------------------------------------------------------------------------------

def build_spring(a):
    yield "new"
    a.new_design()
    yield "circle_tool"
    a.palette_label("Sketch", "Circle", wait=1.4)
    yield "ground"
    pick_ground(a)
    yield "draw"
    circle(a)
    yield "size"
    a.dimension(4, 0, wait=1.2)
    a.expect(near(entities("circle")[-1]["radius"], 2, 0.01), "the circle is not 4 across")
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    before = region_tap(a, (0, 0, 0))
    yield "helix"
    a.button("Helix", wait=1.6)
    a.expect(a.exists("HelixRadius"), "the Helix sheet did not open")
    yield "radius"
    a.field("HelixRadius", 12)
    yield "pitch"
    a.field("HelixPitch", 8)
    yield "turns"
    a.field("HelixTurns", 5)
    yield "create"
    a.tap_id("HelixCreate", wait=3.0)
    spring = a.new_body(before)["id"]
    a.fit()
    yield "steel"
    a.expect(a.selected(), "the new spring is not selected")
    material(a, None, "Steel", select=False)
    yield from reveal(a)


# ---- 2. twisted vase (Rotate a face, Shell) -------------------------------------------------------------

def build_vase(a):
    # a hexagon turned 30° at the top: half its symmetry, so the walls
    # spiral without folding (a square turned 60° folds them)
    yield "new"
    a.new_design()
    yield "poly_tool"
    a.palette_label("Sketch", "Polygon", wait=1.4)
    yield "ground"
    pick_ground(a)
    yield "draw"
    W, _ = plane_fns(sketch_last())
    a.drag(W(0, 0), W(span(W, 55), 0), hold=0.35, wait=1.0)
    a.expect(entities("polygon"), "the hexagon was not drawn")
    yield "size"
    a.dimension(15, 0, wait=1.2)
    a.expect(near(entities("polygon")[-1]["radius"], 15, 0.01), "the hexagon is not R15")
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    before = region_tap(a, (0, 0, 0))
    yield "height"
    body = extrude_distance(a, 60, before)["id"]
    a.deselect()
    a.fit()
    x0, y0, z0, x1, y1, z1 = box(body)
    top = (0, y1, 0)
    yield "top"
    a.tap(top, wait=1.4)
    a.expect(a.says("Face selected"), "the top face was not selected")
    yield "rotate"
    a.palette("Transform", "RotateAxisButton", wait=1.6)
    a.expect(a.exists("GizmoRing-Y"), "the rotate rings did not appear")
    yield "ring"
    a.tap_id("GizmoRing-Y", wait=1.2)
    a.expect(a.exists("RotationAngleField"), "the ring tap did not open the angle")
    yield "angle"
    a.field("RotationAngleField", 30, wait=2.4)
    yield "done"
    a.button("Done", wait=1.2)
    full = body_of(body)["volumeMM3"]
    yield "shell"
    a.palette("Modify", "ShellButton", wait=1.4)
    a.expect(a.exists("ShellApply"), "Shell did not arm")
    yield "open"
    a.tap(top, wait=1.4)
    a.expect(a.says("1 face"), "the top face did not open")
    yield "thick"
    a.field("ShellThicknessField", 2, wait=1.6)
    yield "apply"
    a.tap_id("ShellApply", wait=2.6)
    a.expect(body_of(body)["volumeMM3"] < full / 2, "the shell did not hollow the vase")
    a.deselect()
    yield "gloss"
    inr = 15 * math.cos(math.pi / 6)
    material(a, (inr * math.cos(math.pi / 6), 20, inr * math.sin(math.pi / 6)), "Plastic Gloss")
    yield from reveal(a)


# ---- 3. donut (Revolve) -----------------------------------------------------------------------------------

def build_donut(a):
    yield "new"
    a.new_design()
    yield "line_tool"
    a.palette_label("Sketch", "Line", wait=1.4)
    yield "front"
    actions.pick_tile(a, "front")
    a.look()
    W, _ = plane_fns(sketch_last())
    s = span(W, 45)
    yield "axis"
    actions.draw_line(a, (0, -s), (0, s))
    yield "circle_tool"
    a.palette_label("Sketch", "Circle", wait=1.0)
    yield "circle"
    actions.draw_circle(a, (2 * s, 0), s)
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    before = region_tap(a, W(2 * s, 0))
    yield "revolve"
    a.button("Revolve", wait=1.4)
    a.expect(a.says("axis"), "Revolve did not ask for the axis")
    yield "axis_pick"
    a.tap(W(0, s * 0.5), wait=1.6)
    a.expect(a.exists("RevolveAngleField"), "the axis pick missed")
    yield "angle"
    a.field("RevolveAngleField", 360, wait=2.6)
    donut = a.new_body(before)["id"]
    a.deselect()
    a.fit()
    yield "gloss"
    x0, y0, z0, x1, y1, z1 = box(donut)
    material(a, ((x0 + x1) / 2, y1, z1 - (z1 - z0) / 4), "Plastic Gloss")
    yield from reveal(a)


# ---- 4. bowl (Fillet, Shell) --------------------------------------------------------------------------------

def build_bowl(a):
    body = yield from disc(a, 80, 35)
    c = math.cos(math.pi / 4) * 40
    yield "fillet"
    arm_blend(a, "FilletButton")
    yield "edge"
    a.tap_edge((c, 0, c), (c, 12, c), wait=1.4)
    # a sketched circle extrudes as a loop of short edges: the tap picks them all
    a.expect(a.says("selected"), "the bottom edge was not picked")
    yield "radius"
    a.field("BlendValueField", 25, wait=1.8)
    yield "apply"
    apply_blend(a)
    full = body_of(body)["volumeMM3"]
    yield "shell"
    a.palette("Modify", "ShellButton", wait=1.4)
    a.expect(a.exists("ShellApply"), "Shell did not arm")
    yield "open"
    a.tap((0, 35, 0), wait=1.4)
    a.expect(a.says("1 face"), "the top face did not open")
    yield "thick"
    a.field("ShellThicknessField", 2, wait=1.6)
    yield "shell_apply"
    a.tap_id("ShellApply", wait=2.6)
    a.expect(body_of(body)["volumeMM3"] < full / 2, "the shell did not hollow the bowl")
    a.deselect()
    yield "wood"
    material(a, (c, 31, c), "Wood")
    yield from reveal(a)


# ---- 5. hex nut (Polygon, Chamfer) ----------------------------------------------------------------------------

def build_nut(a):
    yield "new"
    a.new_design()
    yield "poly_tool"
    a.palette_label("Sketch", "Polygon", wait=1.4)
    yield "ground"
    pick_ground(a)
    yield "draw"
    W, _ = plane_fns(sketch_last())
    r = span(W, 55)
    a.drag(W(0, 0), W(r, 0), hold=0.35, wait=1.0)
    a.expect(entities("polygon"), "the hexagon was not drawn")
    yield "size"
    a.dimension(12, 0, wait=1.2)
    a.expect(near(entities("polygon")[-1]["radius"], 12, 0.01), f"the hexagon is {entities('polygon')[-1]}")
    yield "fit"
    a.fit()
    yield "circle_tool"
    a.palette_label("Sketch", "Circle", wait=1.0)
    yield "hole"
    circle(a, pts=30)
    yield "hole_size"
    a.dimension(12, 0, wait=1.2)
    a.expect(near(entities("circle")[-1]["radius"], 6, 0.01), "the hole is not 12 across")
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    before = region_tap(a, (9, 0, 0))
    yield "height"
    body = extrude_distance(a, 10, before)["id"]
    a.deselect()
    a.fit()
    yield "chamfer"
    arm_blend(a, "ChamferButton")
    yield "top"
    a.tap((9, 10, 0), wait=1.6)
    a.expect(a.says("edges"), "the top face's edges were not picked")
    yield "size2"
    a.field("BlendValueField", 1, wait=1.8)
    yield "apply"
    apply_blend(a)
    yield "steel"
    inr = 12 * math.cos(math.pi / 6)
    material(a, (inr * math.cos(math.pi / 6), 5, inr * math.sin(math.pi / 6)), "Steel")
    yield from reveal(a)


# ---- 6. square to round (Offset Plane, Loft) ------------------------------------------------------------------

def build_loft(a):
    body = yield from block(a, 50, 50, 6)             # a 10 mm rim round the 30 mm square: room to tap
    x0, y0, z0, x1, y1, z1 = box(body)
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    yield "sq_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.4)
    yield "sq_face"
    pick_face(a, (x1 - 6, y1, z0 + 6), (0, 1, 0))
    yield "sq_draw"
    W, Lc = plane_fns(sketch_last())
    c = Lc((cx, y1, cz))
    a.fit()
    actions.draw_rect(a, (c[0] - 15, c[1] - 15), span=(span(W, 50), span(W, 40)))
    yield "sq_w"
    a.dimension(30, 0)
    yield "sq_d"
    a.dimension(30, 1)
    a.expect(near(actions.rect_size()[1], 30, 0.01), "the square is not 30 × 30")
    yield "sq_exit"
    exit_iso(a)
    yield "sq_iso"
    a.view("Isometric")
    a.deselect()
    yield "pl_face"
    a.tap((x1 - 5, y1, z0 + 5), wait=1.4)
    a.expect(a.says("Face selected"), "the top face was not selected")
    yield "pl_offset"
    a.button("Offset Plane", wait=1.2)
    a.expect(a.exists("OffsetPlaneDistanceField"), "Offset Plane did not open")
    yield "pl_dist"
    a.field("OffsetPlaneDistanceField", 40, wait=2.0)
    a.fit()
    top = (cx, y1 + 40, cz)
    yield "ci_tool"
    a.palette_label("Sketch", "Circle", wait=1.4)
    yield "ci_plane"
    actions.pick_face(a, top)
    a.expect(near(sketch_last()["plane"]["origin"][1], top[1], 0.05), "that was not the new plane")
    a.look()
    yield "ci_draw"
    W2, L2 = plane_fns(sketch_last())
    circle(a, L2(top))
    yield "ci_size"
    a.dimension(24, 0, wait=1.2)
    a.expect(near(entities("circle")[-1]["radius"], 12, 0.01), "the circle is not 24 across")
    yield "ci_exit"
    exit_iso(a)
    yield "ci_iso"
    a.view("Isometric")
    yield "lo_square"
    vol = body_of(body)["volumeMM3"]
    extrude_tap(a, (cx + 9, y1, cz + 9))
    yield "loft"
    a.button("Loft", wait=1.4)
    yield "pick"
    a.tap((cx + 5, top[1], cz + 5), wait=1.6)
    a.expect(a.says("2 sections"), "the circle was not added to the loft")
    yield "commit"
    a.tap_id("LoftCommit", wait=2.8)
    a.expect(body_of(body)["volumeMM3"] > vol + 1000 or len(a.bodies()) > 1, "the loft did not build")
    a.deselect()
    a.fit()
    yield from reveal(a)


# ---- 7. bent pipe (Sweep, Shell) -------------------------------------------------------------------------------

def build_pipe(a):
    L, D = 30, 20                                        # legs, pipe diameter
    yield "new"
    a.new_design()
    yield "line_tool"
    a.palette_label("Sketch", "Line", wait=1.4)
    yield "ground"
    pick_ground(a)
    W, _ = plane_fns(sketch_last())
    yield "line1"
    actions.draw_line(a, (0, 0), (0, span(W, 60)))
    yield "len1"
    a.dimension(L, 0, wait=1.2)
    a.fit()
    yield "line2"
    actions.draw_line(a, (0, L), (span(W, 60), L))
    yield "len2"
    a.dimension(L, 0, wait=1.2)
    lines = entities("line")
    a.expect(len(lines) == 2, f"{len(lines)} lines in the path")
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    yield "circle_tool"
    a.palette_label("Sketch", "Circle", wait=1.4)
    yield "front"
    actions.pick_tile(a, "front")
    a.look()
    yield "circle"
    circle(a)
    yield "size"
    a.dimension(D, 0, wait=1.2)
    a.expect(near(entities("circle")[-1]["radius"], D / 2, 0.01), "the circle is not the pipe's size")
    yield "exit2"
    exit_iso(a)
    yield "iso2"
    a.view("Isometric")
    # the path starts at the circle's centre: tap the circle where it is
    # clear of both its own edge and the path line
    yield "tap_region"
    front = ((1, 0, 0), (0, 1, 0))
    inside = [p for r in (0.25, 0.4, 0.55) for p in circle_pts((0, 0, 0), r * D / 2, front, 16)]
    at, gap = clear_point(inside, [circle_pts((0, 0, 0), D / 2, front), line_pts((0, 0, 0), (0, 0, -L)),
                                   line_pts((0, 0, -L), (L, 0, -L))])
    log(f"circle tap {at}: {gap:.0f} pt clear")
    before = region_tap(a, at)
    yield "sweep"
    a.button("Sweep", wait=1.4)
    a.expect(a.says("path"), "Sweep did not ask for the path")
    yield "path1"
    a.tap((0, 0, -L * 0.65), wait=1.4)
    yield "path2"
    a.tap((L * 0.65, 0, -L), wait=1.4)
    a.expect(a.says("2 path"), "the two path lines were not picked")
    yield "commit"
    a.tap_id("SweepCommit", wait=2.6)
    pipe = a.new_body(before)["id"]
    a.deselect()
    a.fit()
    full = body_of(pipe)["volumeMM3"]
    yield "shell"
    a.palette("Modify", "ShellButton", wait=1.4)
    a.expect(a.exists("ShellApply"), "Shell did not arm")
    yield "end1"
    a.tap(at, wait=1.4)
    yield "end2"
    a.tap((L, -D * 0.2, -L + D * 0.25), wait=1.4)
    a.expect(a.says("2 faces"), "both pipe ends were not opened")
    yield "thick"
    a.field("ShellThicknessField", 2, wait=1.6)
    yield "apply"
    a.tap_id("ShellApply", wait=2.6)
    a.expect(body_of(pipe)["volumeMM3"] < full / 2, "the shell did not hollow the pipe")
    a.deselect()
    yield from reveal(a)


# ---- 8. gem (Polygon, Chamfer, Mirror) ---------------------------------------------------------------------------

def build_gem(a):
    yield "new"
    a.new_design()
    yield "poly_tool"
    a.palette_label("Sketch", "Polygon", wait=1.4)
    yield "ground"
    pick_ground(a)
    yield "sides"
    a.field("PolygonSidesField", 8, wait=1.0)
    yield "draw"
    W, _ = plane_fns(sketch_last())
    a.drag(W(0, 0), W(span(W, 55), 0), hold=0.35, wait=1.0)
    a.expect(entities("polygon") and entities("polygon")[-1]["sides"] == 8, f"no octagon: {entities('polygon')}")
    yield "size"
    a.dimension(15, 0, wait=1.2)
    a.expect(near(entities("polygon")[-1]["radius"], 15, 0.01), "the octagon is not R15")
    yield "exit"
    exit_iso(a)
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    before = region_tap(a, (0, 0, 0))
    yield "height"
    body = extrude_distance(a, 6, before)["id"]
    a.deselect()
    a.fit()
    yield "chamfer"
    arm_blend(a, "ChamferButton")
    yield "top"
    a.tap((0, 6, 0), wait=1.6)
    a.expect(a.says("edges"), "the top face's edges were not picked")
    yield "size2"
    a.field("BlendValueField", 5, wait=1.8)
    yield "apply"
    apply_blend(a)
    yield "gloss"
    material(a, (0, 6, 0), "Plastic Gloss")
    yield "select"
    a.double_tap((0, 6, 0), wait=1.4)
    a.expect(a.selected(), "the gem was not selected")
    yield "mirror"
    a.tap_id("TransformGroup", wait=1.0)
    a.tap_id("Mirror", wait=1.2)
    yield "ground_plane"
    a.button("Ground (ZX)", wait=1.8)
    a.expect(len(a.bodies()) == 2, f"{len(a.bodies())} bodies after the mirror")
    a.deselect()
    # the copy keeps the default grey: finish it too, from the front, where
    # the lower half is not hidden under the upper one
    yield "front_view"
    a.view("Front")
    yield "gloss2"
    material(a, (0, -3, 0), "Plastic Gloss")
    yield from reveal(a, view="Front")      # from above, the lower half hides under the upper


# ---- 9. cube frame (three through cuts) ----------------------------------------------------------------------------

def build_frame(a):
    body = yield from block(a, 30, 30, 30)
    x0, y0, z0, x1, y1, z1 = box(body)
    cx, cy, cz = (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
    # tap each face away from the origin (its plane tiles), draw the square at its centre
    for tag, centre, at, normal in (("c1", (cx, y1, cz), (x1 - 6, y1, z0 + 6), (0, 1, 0)),
                                    ("c2", (cx, cy, z1), (x1 - 6, y1 - 6, z1), (0, 0, 1)),
                                    ("c3", (x1, cy, cz), (x1, y1 - 6, z0 + 6), (1, 0, 0))):
        yield f"{tag}_tool"
        a.palette_label("Sketch", "Rectangle", wait=1.4)
        yield f"{tag}_face"
        pick_face(a, at, normal)
        yield f"{tag}_draw"
        W, Lc = plane_fns(sketch_last())
        c = Lc(centre)
        a.fit()
        actions.draw_rect(a, (c[0] - 10, c[1] - 10), span=(span(W, 50), span(W, 40)))
        yield f"{tag}_w"
        a.dimension(20, 0)
        yield f"{tag}_d"
        a.dimension(20, 1)
        a.expect(near(actions.rect_size()[1], 20, 0.01), "the square is not 20 × 20")
        yield f"{tag}_exit"
        exit_iso(a)
        yield f"{tag}_iso"
        a.view("Isometric")
        yield f"{tag}_tap"
        extrude_tap(a, centre)
        yield f"{tag}_sub"
        a.button("Subtract", wait=1.0)
        yield f"{tag}_depth"
        vol = body_of(body)["volumeMM3"]
        a.field("Distance", -30, wait=2.4)
        a.expect(body_of(body)["volumeMM3"] < vol - 1000, f"cut {tag} did not go through")
        a.deselect()
    yield from reveal(a)


# ---- 10. ring (two circles, Fillet, Brass) ----------------------------------------------------------------------------

def build_ring(a):
    body = yield from disc(a, 26, 6, then_hole=18)
    yield "fillet"
    arm_blend(a, "FilletButton")
    yield "top"
    a.touch("pinch:2.0;1.2"); a.pause(1.0)                 # the 4 mm band: a tap mid-band must pick the FACE
    a.tap((11 * 0.7071, 6, -11 * 0.7071), wait=1.6)
    a.expect(a.says("edges"), "the top face's edges were not picked")
    yield "radius"
    a.field("BlendValueField", 1, wait=1.8)
    yield "apply"
    apply_blend(a)
    yield "brass"
    c = math.cos(math.pi / 4) * 13
    material(a, (c, 3, c), "Brass")
    yield from reveal(a)


BUILDERS = {"spring": build_spring, "vase": build_vase, "donut": build_donut, "bowl": build_bowl,
            "nut": build_nut, "loft": build_loft, "pipe": build_pipe, "gem": build_gem,
            "frame": build_frame, "ring": build_ring}
