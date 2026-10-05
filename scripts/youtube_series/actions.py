"""Touch sequences for the CAD-actions videos — one builder per video.

Every step is performed by a real touch in ActionTakeUITests; nothing is
built over the bridge. The bridge is only READ: to turn world millimetres into
screen points (`/v1/project`) and to check that a step did what it should.
A step that does not land stops the take (`Missed`) instead of falling back,
so a video can never silently skip a step.

A builder is a generator that yields a step id (from action_text.py) and then
performs that step; the runner holds each step until its narration is done.
"""
import json, math, time
from common import call, bodies, edges, faces, log, normalized, nstr, POINTS


class Missed(RuntimeError):
    pass


class A:
    def __init__(self, take):
        self.t = take

    # ---- raw touches ------------------------------------------------------------------
    def touch(self, action, timeout=40, expect="done"):
        r = self.t.touch(action, timeout)
        if expect and not r.startswith(expect):
            raise Missed(f"{action} -> {r}")
        return r

    def pause(self, s):
        time.sleep(s)

    def screen(self, p):
        return normalized([p])[0]

    def visible(self, p):
        """Bring a world point on screen: tap Fit View (shown like any tap) if it isn't."""
        x, y = self.screen(p)
        if not (0.05 < x < 0.95 and 0.1 < y < 0.9):
            self.fit()
            x, y = self.screen(p)
        return x, y

    def tap(self, p, wait=0.9):
        self.touch("tap:" + nstr(self.visible(p))); self.pause(wait)

    def tap_edge(self, edge_mid, toward, points=8, wait=1.2):
        """Tap an edge a few points in from it, towards `toward` (a point on the
        face beside it): exactly on a silhouette edge a tap can miss the body.
        The app picks an edge within 18 pt, so 8 pt in still picks the edge."""
        self.visible(edge_mid)
        (ex, ey), (tx, ty) = normalized([edge_mid, toward])
        dx, dy = (tx - ex) * POINTS[0], (ty - ey) * POINTS[1]
        n = math.hypot(dx, dy) or 1.0
        x, y = ex + dx / n * points / POINTS[0], ey + dy / n * points / POINTS[1]
        self.touch(f"tap:{x:.4f},{y:.4f}"); self.pause(wait)

    def double_tap(self, p, wait=1.0):
        self.touch("double_tap:" + nstr(self.screen(p))); self.pause(wait)

    def drag(self, a, b, hold=0.35, wait=0.9):
        pa, pb = normalized([a, b])
        self.touch(f"drag:{nstr(pa)};{nstr(pb)};{hold}"); self.pause(wait)

    def tap_screen(self, x, y, wait=0.8):
        self.touch(f"tap:{x:.4f},{y:.4f}"); self.pause(wait)

    def button(self, label, wait=0.9):
        self.touch("tap_button:" + label); self.pause(wait)

    def tap_id(self, ident, wait=0.9):
        self.touch("tap_id:" + ident); self.pause(wait)

    def palette(self, group, ident, wait=1.0):
        self.touch(f"palette:{group}/{ident}"); self.pause(wait)

    def palette_label(self, group, label, wait=1.0):
        self.touch(f"palette_label:{group}/{label}"); self.pause(wait)

    def field(self, name, value, wait=1.0):
        self.touch(f"field:{name}={value}"); self.pause(wait)

    def dimension(self, value, index=0, wait=1.0):
        self.touch(f"dimension:{value}@{index}"); self.pause(wait)

    def exists(self, ident):
        return self.touch("exists:" + ident, expect="") == "done:yes"

    def says(self, text):
        return self.touch("text:" + text, expect="") == "done:yes"

    # ---- camera, by the Views menu and Fit View --------------------------------------------
    def view(self, name="Isometric", fit=True, wait=1.3):
        self.touch(f"menu:ViewsMenu/{name}"); self.pause(1.0)
        if fit:
            self.touch("tap_button:Fit View"); self.pause(wait)

    def fit(self, wait=1.2):
        self.touch("tap_button:Fit View"); self.pause(wait)

    # ---- the app's state (read only) -----------------------------------------------------------
    def state(self):
        return call("/v1/state")

    def mode(self):
        return self.state().get("mode")

    def bodies(self):
        return bodies()

    def new_body(self, before):
        new = [b for b in bodies() if b["id"] not in before]
        if not new:
            raise Missed("no new body")
        return new[0]

    def expect(self, cond, what):
        if not cond:
            raise Missed(what)

    def deselect(self, wait=0.7):
        """A tap on empty grid, bottom-left of the viewport."""
        self.tap_screen(0.14, 0.9, wait)

    # ---- common sequences ------------------------------------------------------------------------
    def new_design(self):
        self.touch("new_design"); self.pause(2.0)

    def start_sketch(self, tool_label, plane_point):
        """Sketch ▸ <tool>, then tap a plane tile or a face to sketch on."""
        self.palette_label("Sketch", tool_label, wait=1.6)
        self.tap(plane_point, wait=2.0)
        self.expect(str(self.mode()).startswith("sketching"), f"no sketch after picking {plane_point}")

    def sketch_plane(self):
        sk = call("/v1/sketches")["sketches"][-1]
        o, xa, ya = sk["plane"]["origin"], sk["plane"]["xAxis"], sk["plane"]["yAxis"]
        return sk, (lambda u, v: tuple(o[i] + xa[i] * u + ya[i] * v for i in range(3)))

    def exit_sketch(self):
        self.button("Exit Sketching", wait=1.4)

    def extrude_region(self, point, distance, result=None):
        """Tap a sketch region (the Extrude bar comes up), pick a Result, type the Distance."""
        before = {b["id"] for b in bodies()}
        self.tap(point, wait=1.4)
        self.expect(self.exists("Distance"), "the Extrude bar did not open")
        if result:
            self.button(result, wait=0.8)
        self.field("Distance", distance, wait=1.6)
        return before


# ---- geometry lookups (read only) ------------------------------------------------------------

def body_of(bid):
    return next(b for b in bodies() if b["id"] == bid)


def box(bid):
    (x0, y0, z0), (x1, y1, z1) = body_of(bid)["bounds"]
    return x0, y0, z0, x1, y1, z1


def near(a, b, tol=0.6):
    return abs(a - b) <= tol


def straight_edges(bid, length=None):
    out = []
    for e in edges(bid):
        if not e.get("midpoint"):
            continue
        if length is None or near(e["lengthMM"], length, 0.05):
            out.append(e)
    return out


def sketch_last():
    return call("/v1/sketches")["sketches"][-1]


def plane_fns(sk):
    o, xa, ya = sk["plane"]["origin"], sk["plane"]["xAxis"], sk["plane"]["yAxis"]
    def to_world(u, v):
        return tuple(o[i] + xa[i] * u + ya[i] * v for i in range(3))
    def to_local(p):
        d = [p[i] - o[i] for i in range(3)]
        return (sum(d[i] * xa[i] for i in range(3)), sum(d[i] * ya[i] for i in range(3)))
    return to_world, to_local


def entities(kind, sk=None):
    sk = sk or sketch_last()
    return [e for e in sk["entities"] if e["kind"] == kind]


def on_screen(a, pts, margin=0.06):
    return all(margin < x < 1 - margin and margin + 0.06 < y < 1 - margin for x, y in normalized(pts))


# ---- sketch steps -------------------------------------------------------------------------------

def pick_ground_by_grid(a):
    for x, y in ((0.74, 0.80), (0.30, 0.82), (0.82, 0.62)):
        a.tap_screen(x, y, wait=2.0)
        if str(a.mode()).startswith("sketching"):
            return
    raise Missed("the grid tap did not start a ground sketch")


def pick_tile(a, plane):
    a.tap(tile_point(plane), wait=2.0)
    a.expect(str(a.mode()).startswith("sketching"), f"the {plane} tile pick missed")
    n = sketch_last()["plane"]
    want = {"front": (0, 0, 1), "right": (1, 0, 0)}[plane]
    xa, ya = n["xAxis"], n["yAxis"]
    nrm = (xa[1] * ya[2] - xa[2] * ya[1], xa[2] * ya[0] - xa[0] * ya[2], xa[0] * ya[1] - xa[1] * ya[0])
    a.expect(all(near(nrm[i], want[i], 0.01) for i in range(3)), f"picked a plane with normal {nrm}, not {plane}")


def pick_face(a, point):
    a.tap(point, wait=2.0)
    a.expect(str(a.mode()).startswith("sketching"), f"the face pick at {point} missed")


def draw_rect(a, start_local, span=(3.0, 2.0)):
    """Drag a small rectangle whose first corner is `start_local`; a typed
    size then grows it away from that corner."""
    W, _ = plane_fns(sketch_last())
    before = len(entities("rect"))
    p0 = W(*start_local)
    p1 = W(start_local[0] + span[0], start_local[1] + span[1])
    if not on_screen(a, [p0, p1]):
        a.fit()
    a.drag(p0, p1, hold=0.35, wait=1.0)
    a.expect(len(entities("rect")) > before, "the rectangle was not drawn")


def draw_circle(a, center_local, r):
    W, _ = plane_fns(sketch_last())
    before = len(entities("circle"))
    a.drag(W(*center_local), W(center_local[0] + r, center_local[1]), hold=0.35, wait=1.0)
    a.expect(len(entities("circle")) > before, "the circle was not drawn")


def draw_line(a, p_local, q_local):
    W, _ = plane_fns(sketch_last())
    before = len(entities("line"))
    a.drag(W(*p_local), W(*q_local), hold=0.35, wait=1.0)
    a.expect(len(entities("line")) > before, "the line was not drawn")


def rect_size():
    r = entities("rect")[-1]
    return r["max"][0] - r["min"][0], r["max"][1] - r["min"][1]


def type_rect(a, width, depth):
    a.dimension(width, 0, wait=1.0)
    a.expect(near(rect_size()[0], width, 0.01), f"width is {rect_size()[0]}, not {width}")
    yield "__depth__"
    a.dimension(depth, 1, wait=1.0)
    a.expect(near(rect_size()[1], depth, 0.01), f"depth is {rect_size()[1]}, not {depth}")


def extrude_tap(a, point):
    a.tap(point, wait=1.5)
    a.expect(a.exists("Distance"), "the Extrude bar did not open")


def extrude_distance(a, distance, before):
    a.field("Distance", distance, wait=2.0)
    return a.new_body(before) if before is not None else None


def blend(a, tool, points, size, count_text):
    """(Fillet|Chamfer) is already armed: tap the edges, type the size, Apply."""


# ---- the shared opening: a block by touch -----------------------------------------------

def build_block(a, width, depth, height, fit_after=False):
    yield "new"
    a.new_design()
    yield "rect_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.6)
    yield "ground"
    for _ in range(2):
        a.tap((1.0, 0, 1.0), wait=2.2)                # the green ground tile at the origin
        if str(a.mode()).startswith("sketching"):
            break
    a.expect(str(a.mode()).startswith("sketching"), "the ground plane pick missed")
    yield "draw"
    draw_rect(a, (0.0, 0.0))
    yield "width"
    steps = type_rect(a, width, depth)
    next(steps)
    yield "depth"
    next(steps, None)
    yield "fit"
    a.fit()
    yield "exit"
    a.exit_sketch()
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    W, _ = plane_fns(sketch_last())
    before = {b["id"] for b in a.bodies()}
    extrude_tap(a, W(width / 2, depth / 2))
    yield "height"
    body = extrude_distance(a, height, before)["id"]
    if fit_after:
        yield "fit2"
        a.deselect()
        a.fit()
    return body


def intro_step(a):
    yield "intro"
    a.pause(2.5)


def views_steps(a, *names):
    for n in names:
        yield f"view_{n.lower()}"
        a.view(n)


def outro_step(a):
    yield "outro"
    a.deselect()
    a.pause(1.0)


# ---- 1. fillet -------------------------------------------------------------------------------------

def arm_blend(a, button):
    a.palette("Modify", button, wait=1.4)
    a.expect(a.exists("BlendApply"), f"{button} did not arm")


def apply_blend(a):
    before = body_of(a.last)["volumeMM3"] if getattr(a, "last", None) else None
    a.tap_id("BlendApply", wait=2.2)
    a.expect(not a.exists("BlendApply"), "Apply did not close the tool")
    a.deselect(wait=1.0)


def vertical_corner(bid, which):
    x0, y0, z0, x1, y1, z1 = box(bid)
    want = {"front": (x1, z1), "left": (x0, z1), "right": (x1, z0)}[which]
    h = y1 - y0
    for e in straight_edges(bid, h):
        m = e["midpoint"]
        if near(m[0], want[0]) and near(m[2], want[1]) and near(m[1], (y0 + y1) / 2):
            return tuple(m)
    raise Missed(f"no {which} corner edge")


def face_centre(bid, which):
    x0, y0, z0, x1, y1, z1 = box(bid)
    return {"front": ((x0 + x1) / 2, (y0 + y1) / 2, z1), "right": (x1, (y0 + y1) / 2, (z0 + z1) / 2),
            "top": ((x0 + x1) / 2, y1, (z0 + z1) / 2)}[which]


def build_fillet(a):
    yield from intro_step(a)
    body = yield from build_block(a, 40, 30, 20)
    a.last = body
    yield "f1_tool"
    arm_blend(a, "FilletButton")
    yield "f1_edge"
    a.tap_edge(vertical_corner(body, "front"), face_centre(body, "front"), wait=1.4)
    a.expect(a.says("1 edge"), "the front corner edge was not picked")
    yield "f1_size"
    a.field("BlendValueField", 5, wait=1.6)
    yield "f1_apply"
    apply_blend(a)
    yield "f2_tool"
    arm_blend(a, "FilletButton")
    yield "f2_edges"
    a.tap_edge(vertical_corner(body, "left"), face_centre(body, "front"), wait=1.4)
    a.tap_edge(vertical_corner(body, "right"), face_centre(body, "right"), wait=1.4)
    a.expect(a.says("2 edges"), "two corner edges were not picked")
    yield "f2_size"
    a.field("BlendValueField", 5, wait=1.6)
    yield "f2_apply"
    apply_blend(a)
    yield "f3_tool"
    arm_blend(a, "FilletButton")
    yield "f3_face"
    x0, y0, z0, x1, y1, z1 = box(body)
    a.tap(((x0 + x1) / 2, y1, (z0 + z1) / 2), wait=1.6)
    a.expect(a.says("edges"), "the top face's edges were not picked")
    yield "f3_size"
    a.field("BlendValueField", 2, wait=1.8)
    yield "f3_apply"
    apply_blend(a)
    yield from views_steps(a, "Front", "Isometric")
    yield from outro_step(a)


# ---- 2. chamfer ---------------------------------------------------------------------------------------

def top_edge(bid, side):
    """The top edge along X at the front (z max), or along Z at the right (x max)."""
    x0, y0, z0, x1, y1, z1 = box(bid)
    best = None
    for e in straight_edges(bid):
        m = e["midpoint"]
        if not near(m[1], y1):
            continue
        if side == "front" and near(m[2], z1) and not near(m[0], x0) and not near(m[0], x1):
            best = m
        if side == "right" and near(m[0], x1) and not near(m[2], z0) and not near(m[2], z1):
            best = m
    if best is None:
        raise Missed(f"no top {side} edge")
    return tuple(best)


def build_chamfer(a):
    yield from intro_step(a)
    body = yield from build_block(a, 40, 30, 20)
    yield "c1_tool"
    arm_blend(a, "ChamferButton")
    yield "c1_edge"
    a.tap_edge(top_edge(body, "front"), face_centre(body, "front"), wait=1.4)
    a.expect(a.says("1 edge"), "the top front edge was not picked")
    yield "c1_size"
    a.field("BlendValueField", 4, wait=1.6)
    yield "c1_apply"
    apply_blend(a)
    yield "c2_tool"
    arm_blend(a, "ChamferButton")
    yield "c2_edges"
    a.tap_edge(top_edge(body, "right"), face_centre(body, "right"), wait=1.4)
    a.tap_edge(vertical_corner(body, "right"), face_centre(body, "right"), wait=1.4)
    a.expect(a.says("2 edges"), "two edges were not picked")
    yield "c2_size"
    a.field("BlendValueField", 2, wait=1.6)
    yield "c2_apply"
    apply_blend(a)
    yield from views_steps(a, "Right", "Isometric")
    yield from outro_step(a)


# ---- 3. extrude, cut, push/pull ------------------------------------------------------------------------------

def build_extrude(a):
    yield from intro_step(a)
    body = yield from build_block(a, 60, 40, 10)
    x0, y0, z0, x1, y1, z1 = box(body)
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    # a hole
    yield "h_tool"
    a.palette_label("Sketch", "Circle", wait=1.6)
    yield "h_face"
    pick_face(a, (cx, y1, cz))
    yield "h_draw"
    W, Lc = plane_fns(sketch_last())
    hc = Lc((cx - 15, y1, cz))
    draw_circle(a, hc, 3)
    yield "h_size"
    a.dimension(12, 0, wait=1.2)
    r = entities("circle")[-1]["radius"]
    a.expect(near(r, 6, 0.01), f"hole radius is {r}")
    yield "h_exit"
    a.exit_sketch()
    yield "h_iso"
    a.view("Isometric")
    yield "h_tap"
    extrude_tap(a, (cx - 15, y1, cz))
    yield "h_sub"
    a.button("Subtract", wait=1.0)
    yield "h_depth"
    vol = body_of(body)["volumeMM3"]
    a.field("Distance", -10, wait=2.2)
    a.expect(body_of(body)["volumeMM3"] < vol - 500, "the hole was not cut")
    # a pocket
    yield "p_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.6)
    yield "p_face"
    pick_face(a, (cx + 12, y1, cz + 8))
    yield "p_draw"
    W, Lc = plane_fns(sketch_last())
    pc = Lc((cx + 12, y1, cz))
    draw_rect(a, (pc[0] - 10, pc[1] - 6))
    yield "p_w"
    steps = type_rect(a, 20, 12)
    next(steps)
    yield "p_d"
    next(steps, None)
    yield "p_exit"
    a.exit_sketch()
    yield "p_iso"
    a.view("Isometric")
    yield "p_tap"
    extrude_tap(a, (cx + 12, y1, cz))
    yield "p_sub"
    a.button("Subtract", wait=1.0)
    yield "p_depth"
    vol = body_of(body)["volumeMM3"]
    a.field("Distance", -4, wait=2.2)
    a.expect(body_of(body)["volumeMM3"] < vol - 500, "the pocket was not cut")
    # push/pull the front face
    yield "desel"
    a.deselect()
    yield "pp_face"
    a.tap((cx, (y0 + y1) / 2, z1), wait=1.4)
    a.expect(a.says("Face selected"), "the front face was not selected")
    yield "pp_value"
    a.touch("tap_pad:ExtrudeArrowValue|ExtrudeArrowField=5"); a.pause(2.0)
    a.expect(near(box(body)[5], z1 + 5, 0.05), f"the face did not move: {box(body)}")
    yield "pp_done"
    a.deselect()
    yield from outro_step(a)


# ---- 4. revolve ----------------------------------------------------------------------------------------------

def build_revolve(a):
    yield from intro_step(a)
    yield "new"
    a.new_design()
    yield "line_tool"
    a.palette_label("Sketch", "Line", wait=1.6)
    yield "front"
    pick_tile(a, "front")
    yield "axis"
    draw_line(a, (0, 0), (0, 5))
    yield "rect_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.0)
    yield "draw"
    draw_rect(a, (1.5, 0), span=(1.5, 3))
    yield "width"
    steps = type_rect(a, 10, 30)
    next(steps)
    yield "height"
    next(steps, None)
    yield "fit"
    a.fit()
    yield "exit"
    a.exit_sketch()
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    before = {b["id"] for b in a.bodies()}
    extrude_tap(a, (6.5, 15, 0))
    yield "rev"
    a.button("Revolve", wait=1.4)
    a.expect(a.says("axis"), "Revolve did not ask for the axis")
    yield "axis_pick"
    a.tap((0, 2.5, 0), wait=1.6)
    a.expect(a.exists("RevolveAngleField"), "the axis pick missed")
    yield "angle"
    a.field("RevolveAngleField", 270, wait=2.4)
    a.new_body(before)
    yield from views_steps(a, "Top", "Isometric")
    yield from outro_step(a)


# ---- 5. sweep --------------------------------------------------------------------------------------------------

def build_sweep(a):
    yield from intro_step(a)
    yield "new"
    a.new_design()
    yield "line_tool"
    a.palette_label("Sketch", "Line", wait=1.6)
    yield "ground"
    pick_ground_by_grid(a)
    yield "seg1"
    # the path's size: the largest that keeps all three points well on screen
    W, _ = plane_fns(sketch_last())
    L = next((l for l in (5, 4, 3, 2.5, 2, 1.5)
              if on_screen(a, [W(0, 0), W(0, l), W(l, l)], margin=0.14)), 1.0)
    draw_line(a, (0, 0), (0, L))
    yield "seg2"
    draw_line(a, (0, L), (L, L))
    path = sketch_last()
    yield "exit"
    a.exit_sketch()
    yield "iso"
    a.view("Isometric")
    yield "circle_tool"
    a.palette_label("Sketch", "Circle", wait=1.6)
    yield "front"
    pick_tile(a, "front")
    yield "circle"
    draw_circle(a, (0, 0), L / 5)
    yield "exit2"
    a.exit_sketch()
    yield "iso2"
    a.view("Isometric")
    yield "tap_circle"
    before = {b["id"] for b in a.bodies()}
    extrude_tap(a, (0, L / 8, 0))
    yield "sweep_btn"
    a.button("Sweep", wait=1.4)
    a.expect(a.says("path"), "Sweep did not ask for the path")
    yield "path1"
    a.tap((0, 0, -L / 2), wait=1.4)
    yield "path2"
    a.tap((L / 2, 0, -L), wait=1.4)
    a.expect(a.says("2 path"), "the two path lines were not picked")
    yield "commit"
    a.tap_id("SweepCommit", wait=2.4)
    a.new_body(before)
    yield "fit"
    a.fit()
    yield from outro_step(a)


# ---- 6. loft ---------------------------------------------------------------------------------------------------------

def build_loft(a):
    yield from intro_step(a)
    body = yield from build_block(a, 40, 40, 10)
    x0, y0, z0, x1, y1, z1 = box(body)
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    yield "sq_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.6)
    yield "sq_face"
    pick_face(a, (cx, y1, cz))
    yield "sq_draw"
    W, Lc = plane_fns(sketch_last())
    c = Lc((cx, y1, cz))
    draw_rect(a, (c[0] - 15, c[1] - 15))
    yield "sq_w"
    steps = type_rect(a, 30, 30)
    next(steps)
    yield "sq_d"
    next(steps, None)
    yield "sq_exit"
    a.exit_sketch()
    yield "sq_iso"
    a.view("Isometric")
    yield "desel"
    a.deselect()
    yield "pl_face"
    a.tap((x0 + 2.5, y1, z1 - 2.5), wait=1.4)
    a.expect(a.says("Face selected"), "the top face was not selected")
    yield "pl_offset"
    a.button("Offset Plane", wait=1.2)
    a.expect(a.exists("OffsetPlaneDistanceField"), "Offset Plane did not open")
    yield "pl_dist"
    a.field("OffsetPlaneDistanceField", 40, wait=2.0)
    a.fit()
    yield "ci_tool"
    a.palette_label("Sketch", "Circle", wait=1.6)
    yield "ci_plane"
    top = y1 + 40
    pick_face(a, (cx, top, cz))
    a.expect(near(sketch_last()["plane"]["origin"][1], top, 0.05), "that was not the new plane")
    yield "ci_draw"
    W, Lc = plane_fns(sketch_last())
    draw_circle(a, Lc((cx, top, cz)), 3)
    yield "ci_size"
    a.dimension(20, 0, wait=1.2)
    a.expect(near(entities("circle")[-1]["radius"], 10, 0.01), "the circle is not 20 across")
    yield "ci_exit"
    a.exit_sketch()
    yield "lo_iso"
    a.view("Isometric")
    yield "lo_square"
    vol = body_of(body)["volumeMM3"]
    extrude_tap(a, (cx + 8, y1, cz + 8))
    yield "lo_btn"
    a.button("Loft", wait=1.4)
    yield "lo_circle"
    a.tap((cx + 4, top, cz + 4), wait=1.6)
    a.expect(a.says("2 sections"), "the circle was not added to the loft")
    yield "lo_commit"
    a.tap_id("LoftCommit", wait=2.6)
    a.expect(body_of(body)["volumeMM3"] > vol + 1000 or len(a.bodies()) > 1, "the loft did not build")
    yield "lo_fit"
    a.fit()
    yield from outro_step(a)


# ---- 7. twist ------------------------------------------------------------------------------------------------------------

def build_twist(a):
    yield from intro_step(a)
    body = yield from build_block(a, 30, 30, 60)
    x0, y0, z0, x1, y1, z1 = box(body)
    yield "desel"
    a.deselect()
    a.fit()
    yield "tw_face"
    a.tap(((x0 + x1) / 2, y1, (z0 + z1) / 2), wait=1.4)
    a.expect(a.says("Face selected"), "the top face was not selected")
    yield "tw_tool"
    a.palette("Transform", "RotateAxisButton", wait=1.6)
    a.expect(a.exists("GizmoRing-Y"), "the rotate rings did not appear")
    yield "tw_ring"
    a.tap_id("GizmoRing-Y", wait=1.2)
    a.expect(a.exists("RotationAngleField"), "the ring tap did not open the angle")
    yield "tw_angle"
    vol = body_of(body)["volumeMM3"]
    a.field("RotationAngleField", 30, wait=2.4)
    yield "tw2_ring"
    a.tap_id("GizmoRing-Y", wait=1.2)
    a.expect(a.exists("RotationAngleField"), "the second ring tap did not open the angle")
    yield "tw2_angle"
    a.field("RotationAngleField", 30, wait=2.4)
    yield "tw_done"
    a.button("Done", wait=1.2)
    yield from views_steps(a, "Front", "Isometric")
    yield from outro_step(a)


# ---- 8. shell ---------------------------------------------------------------------------------------------------------------

def build_shell(a):
    yield from intro_step(a)
    body = yield from build_block(a, 40, 40, 30, fit_after=True)
    x0, y0, z0, x1, y1, z1 = box(body)
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    yield "s1_tool"
    a.palette("Modify", "ShellButton", wait=1.4)
    a.expect(a.exists("ShellApply"), "Shell did not arm")
    yield "s1_face"
    a.tap((cx, y1, cz), wait=1.4)
    a.expect(a.says("1 face"), "the top face did not open")
    yield "s1_thick"
    a.field("ShellThicknessField", 2, wait=1.6)
    yield "s1_apply"
    full = body_of(body)["volumeMM3"]
    a.tap_id("ShellApply", wait=2.4)
    a.expect(body_of(body)["volumeMM3"] < full / 2, "the shell did not hollow the block")
    a.deselect(wait=1.0)
    yield from views_steps(a, "Top", "Isometric")
    yield "undo"
    a.tap_id("UndoButton", wait=2.0)
    a.expect(near(body_of(body)["volumeMM3"], full, 1), "Undo did not restore the block")
    yield "s2_tool"
    a.palette("Modify", "ShellButton", wait=1.4)
    yield "s2_top"
    a.tap((cx, y1, cz), wait=1.4)
    yield "s2_front"
    a.tap((cx, (y0 + y1) / 2, z1), wait=1.4)
    a.expect(a.says("2 faces"), "two faces were not opened")
    yield "s2_thick"
    a.field("ShellThicknessField", 3, wait=1.6)
    yield "s2_apply"
    a.tap_id("ShellApply", wait=2.4)
    a.expect(body_of(body)["volumeMM3"] < full / 2, "the second shell did not build")
    a.deselect(wait=1.0)
    yield from outro_step(a)


# ---- 9. pattern ---------------------------------------------------------------------------------------------------------------

def build_pattern(a):
    yield from intro_step(a)
    yield "new"
    a.new_design()
    yield "rect_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.6)
    yield "ground"
    pick_ground_by_grid(a)
    yield "draw"
    draw_rect(a, (0.0, 0.0))
    yield "width"
    steps = type_rect(a, 30, 4)
    next(steps)
    yield "depth"
    next(steps, None)
    yield "fit"
    a.fit()
    yield "exit"
    a.exit_sketch()
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    W, _ = plane_fns(sketch_last())
    before = {b["id"] for b in a.bodies()}
    extrude_tap(a, W(15, 2))
    yield "height"
    blade = extrude_distance(a, 6, before)["id"]
    yield "l_tool"
    a.palette("Transform", "PatternButton", wait=1.6)
    a.expect(a.exists("PatternApply"), "Pattern did not open")
    yield "l_count"
    a.field("PatternCount", 4, wait=1.2)
    yield "l_spacing"
    a.field("PatternSpacing", 10, wait=1.2)
    yield "l_dir"
    a.button("Z", wait=1.2)
    yield "l_apply"
    a.tap_id("PatternApply", wait=2.2)
    a.expect(len(a.bodies()) == 4, f"{len(a.bodies())} bodies after the linear pattern")
    yield "undo"
    a.tap_id("UndoButton", wait=2.0)
    a.expect(len(a.bodies()) == 1, "Undo did not remove the copies")
    yield "c_sel"
    x0, y0, z0, x1, y1, z1 = box(blade)
    a.double_tap(((x0 + x1) / 2 + 5, y1, (z0 + z1) / 2), wait=1.4)
    yield "c_tool"
    a.palette("Transform", "PatternButton", wait=1.6)
    a.expect(a.exists("PatternApply"), "Pattern did not open with the blade selected")
    yield "c_type"
    a.button("Circular", wait=1.2)
    yield "c_count"
    a.field("PatternCount", 8, wait=1.2)
    yield "c_axis"
    a.button("Y", wait=1.2)
    yield "c_apply"
    a.tap_id("PatternApply", wait=2.4)
    a.expect(len(a.bodies()) == 8, f"{len(a.bodies())} bodies after the circular pattern")
    a.fit()
    yield from outro_step(a)


# ---- 10. mirror ------------------------------------------------------------------------------------------------------------------

def mirror_to(a, plane):
    a.tap_id("TransformGroup", wait=1.0)
    a.tap_id("Mirror", wait=1.2)
    return plane


def build_mirror(a):
    yield from intro_step(a)
    yield "new"
    a.new_design()
    yield "rect_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.6)
    yield "ground"
    pick_ground_by_grid(a)
    yield "draw"
    draw_rect(a, (2.0, 2.0))
    yield "width"
    steps = type_rect(a, 20, 15)
    next(steps)
    yield "depth"
    next(steps, None)
    yield "fit"
    a.fit()
    yield "exit"
    a.exit_sketch()
    yield "iso"
    a.view("Isometric")
    yield "tap_region"
    W, _ = plane_fns(sketch_last())
    before = {b["id"] for b in a.bodies()}
    extrude_tap(a, W(12, 9.5))
    yield "height"
    first = extrude_distance(a, 10, before)["id"]
    a.fit()
    for tool, plane, count in (("m1_tool", "YZ Plane", 2), ("m2_tool", "XY Plane", 3)):
        yield tool
        mirror_to(a, plane)
        yield tool.replace("tool", "plane")
        a.button(plane, wait=1.8)
        a.expect(len(a.bodies()) == count, f"{len(a.bodies())} bodies after mirroring across {plane}")
        a.fit()
    yield "m3_sel"
    x0, y0, z0, x1, y1, z1 = box(first)
    a.double_tap(((x0 + x1) / 2, y1, (z0 + z1) / 2), wait=1.4)
    yield "m3_tool"
    mirror_to(a, "XY Plane")
    yield "m3_plane"
    a.button("XY Plane", wait=1.8)
    a.expect(len(a.bodies()) == 4, f"{len(a.bodies())} bodies after the third mirror")
    a.fit()
    yield from views_steps(a, "Top", "Isometric")
    yield from outro_step(a)


def build_probe(a):
    body = yield from build_block(a, 40, 30, 20)
    a.deselect()


BUILDERS = {"probe": build_probe, "fillet": build_fillet, "chamfer": build_chamfer, "extrude": build_extrude,
            "revolve": build_revolve, "sweep": build_sweep, "loft": build_loft, "twist": build_twist,
            "shell": build_shell, "pattern": build_pattern, "mirror": build_mirror}


# ---- plane tiles ---------------------------------------------------------------------------

def tile_scale():
    """World size of the origin plane tiles right now: 1.5 gizmo units, a gizmo
    unit being 0.12 of the view height at the origin (PlanePicking /
    Renderer.gizmoScale). The view height comes from how many points a
    millimetre spans at the origin, averaged over the three axes."""
    o, x, y, z = normalized([(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)])
    s = 0.0
    for p in (x, y, z):
        s += ((p[0] - o[0]) * POINTS[0]) ** 2 + ((p[1] - o[1]) * POINTS[1]) ** 2
    k = math.sqrt(s / 2)                       # points per mm
    return 0.18 * POINTS[1] / k


def tile_point(plane):
    """The centre of an origin tile ('front' = XY, 'right' = YZ, 'ground')."""
    c = 0.565 * tile_scale()
    return {"front": (c, c, 0), "right": (0, c, -c), "ground": (c, 0, -c)}[plane]


# ---- exploration (not a video) ------------------------------------------------------------------

def build_explore(a):
    import subprocess, os
    from common import udid_for, S
    shots = os.path.join(S, "take-action-explore", "shots"); os.makedirs(shots, exist_ok=True)
    def snap(name):
        p = os.path.join(shots, name + ".png")
        subprocess.run(["xcrun", "simctl", "io", udid_for(), "screenshot", p], capture_output=True)
    def sk_last():
        return call("/v1/sketches")["sketches"][-1]
    def soft(f, what):
        try:
            f()
        except Exception as e:
            log(f"EXPLORE {what}: FAILED {e}")
    yield "new"
    a.new_design()
    yield "rect_tool"
    a.palette_label("Sketch", "Rectangle", wait=1.6)
    a.tap_screen(0.72, 0.78, wait=2.0)                       # bare grid → ground sketch?
    log(f"EXPLORE ground-by-grid mode={a.mode()}")
    snap("01-ground")
    # rectangle from the origin: how do typed sizes anchor it?
    a.drag((0, 0, 0), (4, 0, -3), hold=0.35)
    log(f"EXPLORE rect drawn {[e for e in sk_last()['entities'] if e['kind'] == 'rect']}")
    a.dimension(20, 0); a.dimension(15, 1)
    log(f"EXPLORE rect sized {[e for e in sk_last()['entities'] if e['kind'] == 'rect']}")
    a.fit()
    snap("02-rect")
    # a circle: is the typed value a diameter or a radius?
    a.palette_label("Sketch", "Circle", wait=1.0)
    a.drag((30, 0, -10), (33, 0, -10), hold=0.35)
    log(f"EXPLORE circle drawn {[e for e in sk_last()['entities'] if e['kind'] == 'circle']}")
    a.touch("dimension:12@0", expect="")
    log(f"EXPLORE circle sized {[e for e in sk_last()['entities'] if e['kind'] == 'circle']}")
    snap("03-circle")
    a.exit_sketch()
    a.view("Isometric")
    sk = sk_last(); P = lambda u, v: (u, 0, -v)
    r = next(e for e in sk["entities"] if e["kind"] == "rect")
    before = {b["id"] for b in a.bodies()}
    a.tap(P((r["min"][0] + r["max"][0]) / 2, (r["min"][1] + r["max"][1]) / 2), wait=1.4)
    a.field("Distance", 10, wait=1.8)
    body = [b for b in a.bodies() if b["id"] not in before]
    log(f"EXPLORE extruded {body and body[0]['bounds']}")
    snap("04-block")
    # mirror
    def mirror():
        a.tap_id("TransformGroup", wait=1.0)
        snap("05-transform-flyout")
        r = a.touch("menu:Mirror/YZ Plane", expect="")
        log(f"EXPLORE mirror -> {r}; bodies {[bb['bounds'] for bb in a.bodies()]}")
        snap("06-mirror")
    soft(mirror, "mirror")
    # circular pattern of the selected body
    def pattern():
        a.palette("Transform", "PatternButton", wait=1.4)
        log(f"EXPLORE pattern bar apply={a.exists('PatternApply')} circular={a.exists('Circular')}")
        snap("07-pattern-bar")
        a.touch("tap_button:Circular", expect=""); a.pause(0.8)
        a.touch("field:PatternCount=6", expect=""); a.pause(0.8)
        a.touch("tap_button:Y", expect=""); a.pause(0.8)
        snap("08-pattern-set")
        a.touch("tap_id:PatternApply", expect=""); a.pause(1.5)
        log(f"EXPLORE pattern -> {len(a.bodies())} bodies")
        snap("09-pattern")
    soft(pattern, "pattern")
    a.deselect()
    # twist: top face of the first block, Rotate, ring tap
    def twist():
        b = next(bb for bb in a.bodies() if bb["id"] == body[0]["id"])
        (x0, y0, z0), (x1, y1, z1) = b["bounds"]
        a.view("Isometric")
        a.tap(((x0 + x1) / 2, y1, (z0 + z1) / 2), wait=1.2)
        log(f"EXPLORE face selected: {a.says('Face selected')}")
        a.palette("Transform", "RotateAxisButton", wait=1.4)
        log(f"EXPLORE ring Y frame {a.touch('frame:GizmoRing-Y', expect='')}")
        snap("10-rotate-rings")
        a.touch("tap_id:GizmoRing-Y", expect=""); a.pause(1.0)
        ok = a.exists("RotationAngleField")
        log(f"EXPLORE ring tap opened angle field: {ok}")
        if ok:
            a.touch("field:RotationAngleField=30", expect=""); a.pause(1.5)
        snap("11-twisted")
        log(f"EXPLORE after twist {[bb['bounds'] for bb in a.bodies()]}")
    soft(twist, "twist")
    a.deselect(); a.deselect()
    # offset plane from a face
    def offset():
        b = a.bodies()[0]
        (x0, y0, z0), (x1, y1, z1) = b["bounds"]
        a.tap(((x0 + x1) / 2, y1, (z0 + z1) / 2), wait=1.2)
        a.touch("tap_button:Offset Plane", expect=""); a.pause(1.0)
        log(f"EXPLORE offset field {a.exists('OffsetPlaneDistanceField')}")
        a.touch("field:OffsetPlaneDistanceField=25", expect=""); a.pause(1.5)
        log(f"EXPLORE planes {json.dumps(a.state().get('planes', a.state().get('constructionPlanes')))[:300]}")
        snap("12-offset-plane")
    soft(offset, "offset")
    a.deselect()
    # the front plane tile
    def front():
        a.view("Isometric")
        p = tile_point("front")
        log(f"EXPLORE tile scale {tile_scale():.2f} front tile at {p}")
        a.palette_label("Sketch", "Line", wait=1.6)
        snap("13-plane-picker")
        a.tap(p, wait=2.0)
        log(f"EXPLORE front pick mode={a.mode()} plane={sk_last()['plane']}")
        snap("14-front")
    soft(front, "front")
    yield "done"


BUILDERS["explore"] = build_explore
