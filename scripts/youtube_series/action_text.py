"""Scripts for the CAD-actions videos: chapters of steps. Each step has
`do` (the panel line and the caption under the app: what to tap) and `say`
(the narration). actions.py performs the same steps by touch.

Narration follows pronunciation.py (CAD is one syllable, fillet is FILL-it);
write numbers and units as words.
"""


def step(id, do, say):
    return {"id": id, "do": do, "say": say}


def chapter(title, *steps):
    return {"title": title, "steps": list(steps)}


DOWNLOAD = "Download app: https://apps.apple.com/us/app/openshape3d/id6792536439"

FOOTER = """OpenShape 3D is a free, open-source CAD app for iPhone, iPad and Mac. Source code, issues and releases:
https://github.com/laanlabs/openshape3d

CAD basics — every tap shown
Fillet · Chamfer · Extrude & cut · Revolve · Sweep · Loft · Twist · Shell · Pattern · Mirror

#CAD #3Dmodeling #iPad #iPhone #Mac #3Dprinting #OpenShape3D"""

BASE_TAGS = ["OpenShape 3D", "CAD tutorial", "CAD for beginners", "3D modeling", "iPad CAD", "iPhone CAD",
             "Mac CAD", "free CAD app", "open source CAD", "3D printing design", "Shapr3D alternative",
             "Fusion 360 alternative"]


def video(slug, name, n, chapters, title, thumb, description, tags):
    return {"slug": slug, "name": name, "series": f"CAD basics {n} · {name}", "chapters": chapters,
            "title": title, "thumb": thumb, "description": DOWNLOAD + "\n" + description, "footer": FOOTER,
            "tags": tags + BASE_TAGS, "outro_foot": "Next: more CAD basics, every tap shown",
            "badge": "iPhone · iPad · Mac"}


WORDS = {3: "three", 4: "four", 5: "five", 6: "six", 8: "eight", 10: "ten", 12: "twelve", 15: "fifteen",
         20: "twenty", 24: "twenty-four", 25: "twenty-five", 30: "thirty", 40: "forty", 50: "fifty",
         60: "sixty", 80: "eighty"}


def w(n):
    return WORDS.get(n, str(n))


# the shared opening: a block, drawn and extruded by touch
def block_chapter(width, depth, height, title="Make a block", fit_after=False):
    extra = [step("fit2", "Tap Fit View", "Tap Fit View to see the whole block.")] if fit_after else []
    return chapter(title,
        step("new", "Start a Blank Design",
             "Open OpenShape 3D and start a blank design."),
        step("rect_tool", "Tap Sketch, then Rectangle",
             "Tap Sketch in the tool bar on the left, then Rectangle."),
        step("ground", "Tap the green ground plane",
             "Three planes appear at the origin. Tap the green one, the ground plane, and the view turns to look straight down at it."),
        step("draw", "Drag from corner to corner",
             "Now drag from one corner to the opposite corner. The size doesn't matter yet."),
        step("width", f"Tap the width label, type {width}",
             f"Tap the width label and type {w(width)} millimeters on the keypad, then tap the check mark."),
        step("depth", f"Tap the depth label, type {depth}",
             f"Tap the other label and type {w(depth)}."),
        step("fit", "Tap Fit View",
             "Tap Fit View to see the whole rectangle."),
        step("exit", "Tap Exit Sketching",
             "That's the sketch. Tap Exit Sketching."),
        step("iso", "Views › Isometric",
             "Open the Views menu and pick Isometric, so we look at it from an angle."),
        step("tap_region", "Tap inside the rectangle",
             "Tap inside the rectangle. The Extrude bar comes up at the bottom."),
        step("height", f"Distance › type {height} › check",
             f"Tap the Distance field, type {w(height)}, and tap the check mark. The rectangle rises into a solid block."),
        *extra,
    )


def intro(action, what):
    return chapter(f"How to {action}",
        step("intro", f"How to {action} — every tap shown",
             f"In this video: how to {what} in OpenShape 3D, the free CAD app. It works the same on iPhone, iPad and Mac: "
             "on a Mac, just click where I tap. Every tap is marked with a circle."))


def outro(action, extra):
    return step("outro", "Works on iPhone, iPad and Mac",
                f"That's how to {action} in OpenShape 3D. {extra} It works the same on iPhone, iPad and Mac, "
                "and it's free. Thanks for watching.")


def views(*names):
    return [step(f"view_{n.lower()}", f"Views › {n}", f"Open the Views menu and pick {n}.") for n in names]


def deselect_step(id="desel"):
    return step(id, "Tap empty space", "Tap an empty spot to clear the selection.")


# ---- 1. fillet ----------------------------------------------------------------------------

FILLET = video("fillet", "Fillet: round edges", 1, [
    intro("fillet", "round the edges of a part with a fillet"),
    block_chapter(40, 30, 20),
    chapter("Round one edge",
        step("f1_tool", "Tap Modify, then Fillet",
             "To round an edge, tap Modify, then Fillet. The bar at the bottom says: tap edges to fillet."),
        step("f1_edge", "Tap the front corner edge",
             "Tap the corner edge nearest to you. It lights up, and the bar says one edge selected."),
        step("f1_size", "Radius › type 5 › check",
             "Tap the Radius field, type five, and tap the check mark. The preview shows the rounded corner."),
        step("f1_apply", "Tap Apply, then empty space",
             "Tap Apply. The corner is round. Tap an empty spot to see it without the selection."),
    ),
    chapter("Round several edges at once",
        step("f2_tool", "Tap Modify, then Fillet",
             "Pick Fillet again. This time we'll round more than one edge in one go."),
        step("f2_edges", "Tap the left and right corner edges",
             "Tap the corner edge on the left, then the one on the right. The bar counts two edges."),
        step("f2_size", "Radius › type 5 › check",
             "Type five again for the radius, and tap the check mark."),
        step("f2_apply", "Tap Apply, then empty space",
             "Tap Apply, and both corners are rounded. Tap an empty spot to see it without the selection."),
    ),
    chapter("Round a whole face",
        step("f3_tool", "Tap Modify, then Fillet",
             "One more fillet."),
        step("f3_face", "Tap the middle of the top face",
             "Tap the middle of the top face, and every edge around it is picked at once, the curves included."),
        step("f3_size", "Radius › type 2 › check",
             "Type two for a smaller radius, and tap the check mark."),
        step("f3_apply", "Tap Apply, then empty space",
             "Tap Apply. The whole top edge is soft now. Tap an empty spot to see it without the selection."),
    ),
    chapter("Take a look",
        *views("Front", "Isometric"),
        outro("fillet", "Each fillet is saved in the history, so you can change its radius later."),
    ),
], "How to Fillet (Round Edges) on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO FILLET\nround edges · every tap",
   """How to fillet — round the edges of a part — in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: we make a block, round one edge, round several edges at once, then round a whole face in one tap.

What you'll learn
• Modify › Fillet, and tapping the edges to round
• Typing an exact radius on the keypad
• Rounding several edges in one fillet
• Picking every edge of a face with one tap""",
   ["fillet", "round edges", "how to fillet", "fillet tutorial", "CAD fillet", "rounded corners"])

# ---- 2. chamfer ------------------------------------------------------------------------------

CHAMFER = video("chamfer", "Chamfer: bevel edges", 2, [
    intro("chamfer", "bevel the edges of a part with a chamfer"),
    block_chapter(40, 30, 20),
    chapter("Bevel one edge",
        step("c1_tool", "Tap Modify, then Chamfer",
             "To bevel an edge, tap Modify, then Chamfer. The bar says: tap edges to chamfer."),
        step("c1_edge", "Tap the top front edge",
             "Tap the top edge at the front. The bar says one edge selected."),
        step("c1_size", "Setback › type 4 › check",
             "Tap the Setback field and type four. That's how far the bevel cuts back from the edge. Then tap the check mark."),
        step("c1_apply", "Tap Apply, then empty space",
             "Tap Apply. The edge is cut at forty-five degrees. Tap an empty spot to see it without the selection."),
    ),
    chapter("Bevel two edges at once",
        step("c2_tool", "Tap Modify, then Chamfer",
             "Chamfer again, for two edges together."),
        step("c2_edges", "Tap the top right edge, then the right corner",
             "Tap the top edge on the right, then the corner edge below it. The bar counts two edges."),
        step("c2_size", "Setback › type 2 › check",
             "Type two, a smaller bevel, and tap the check mark."),
        step("c2_apply", "Tap Apply, then empty space",
             "Tap Apply. Tap an empty spot to see it without the selection."),
    ),
    chapter("Chamfer or fillet?",
        *views("Right", "Isometric"),
        outro("chamfer", "A chamfer is a flat bevel, and a fillet is a round one. Chamfers are great on the bottom edges of 3D prints."),
    ),
], "How to Chamfer (Bevel Edges) on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO CHAMFER\nbevel edges · every tap",
   """How to chamfer — bevel the edges of a part — in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: we make a block, bevel one edge with an exact setback, then bevel two edges at once.

What you'll learn
• Modify › Chamfer, and tapping the edges to bevel
• What the setback is, and typing it on the keypad
• Chamfering several edges in one step
• Chamfer or fillet: which to use""",
   ["chamfer", "bevel", "how to chamfer", "chamfer tutorial", "CAD chamfer", "bevel edges"])

# ---- 3. extrude, cut, push/pull -----------------------------------------------------------------------

EXTRUDE = video("extrude-and-cut", "Extrude & cut holes", 3, [
    intro("extrude and cut", "extrude a sketch, cut a hole and a pocket, and push a face"),
    block_chapter(60, 40, 10, title="Extrude a plate"),
    chapter("Cut a hole",
        step("h_tool", "Tap Sketch, then Circle",
             "Now a hole. Tap Sketch, then Circle."),
        step("h_face", "Tap the top face",
             "This time, tap the top face of the plate. We'll sketch right on it."),
        step("h_draw", "Drag from the centre out",
             "Press where the centre goes, and drag outwards to draw the circle."),
        step("h_size", "Tap the diameter, type 12",
             "Tap the diameter label and type twelve."),
        step("h_exit", "Tap Exit Sketching",
             "Tap Exit Sketching."),
        step("h_iso", "Views › Isometric", "Views, Isometric."),
        step("h_tap", "Tap inside the circle",
             "Tap inside the circle. The Extrude bar comes up."),
        step("h_sub", "Result › Subtract",
             "At the bottom, set Result to Subtract, so the circle cuts instead of adding."),
        step("h_depth", "Distance › type −10 › check",
             "Tap Distance and type minus ten: the minus is the plus-minus key. Negative goes down, into the plate. Tap the check mark, and there's the hole."),
    ),
    chapter("Cut a pocket",
        step("p_tool", "Tap Sketch, then Rectangle",
             "A pocket is the same idea with a shallower cut. Tap Sketch, then Rectangle."),
        step("p_face", "Tap the top face",
             "Tap the top face."),
        step("p_draw", "Drag from corner to corner",
             "Drag a rectangle beside the hole."),
        step("p_w", "Tap the width label, type 20",
             "Tap the width label and type twenty."),
        step("p_d", "Tap the depth label, type 12",
             "And twelve for the other side."),
        step("p_exit", "Tap Exit Sketching",
             "Exit Sketching."),
        step("p_iso", "Views › Isometric", "Views, Isometric."),
        step("p_tap", "Tap inside the rectangle",
             "Tap inside the rectangle."),
        step("p_sub", "Result › Subtract",
             "Result, Subtract."),
        step("p_depth", "Distance › type −4 › check",
             "Distance, minus four, and the check mark. A four millimeter pocket."),
    ),
    chapter("Push or pull a face",
        deselect_step(),
        step("pp_face", "Tap the front face",
             "You can also push or pull any flat face. Tap the front face. The bar says face selected, and an arrow appears."),
        step("pp_value", "Tap the arrow's value, type 5",
             "Drag the arrow, or tap its value and type five. The face moves out five millimeters."),
        step("pp_done", "Tap empty space",
             "Tap an empty spot when you're done."),
        outro("extrude, cut holes and push faces", "Extrude adds, Subtract cuts, and any face can be pushed or pulled."),
    ),
], "How to Extrude & Cut Holes on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "EXTRUDE & CUT\nholes · pockets · every tap",
   """How to extrude a sketch, cut a hole and a pocket, and push or pull a face in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown.

What you'll learn
• Extruding a sketch by tapping it and typing a distance
• Sketching on the face of a part
• Result › Subtract to cut holes and pockets
• Negative distances with the keypad's ± key
• Pushing and pulling a face""",
   ["extrude", "cut hole", "how to extrude", "pocket", "push pull", "extrude cut"])

# ---- 4. revolve -------------------------------------------------------------------------------------------

REVOLVE = video("revolve", "Revolve", 4, [
    intro("revolve", "revolve a profile around an axis"),
    chapter("Sketch a profile and an axis",
        step("new", "Start a Blank Design", "Start a blank design."),
        step("line_tool", "Tap Sketch, then Line",
             "Tap Sketch, then Line."),
        step("front", "Tap the blue front plane",
             "Tap the blue plane: the front plane. We're sketching upright."),
        step("axis", "Drag a vertical line: the axis",
             "Drag a short vertical line. This will be the axis we spin around."),
        step("rect_tool", "Tap Rectangle",
             "Now tap Rectangle."),
        step("draw", "Drag a rectangle beside the line",
             "Drag a rectangle just to the right of the line. It must not cross the axis."),
        step("width", "Tap the width label, type 10",
             "Tap the width label and type ten."),
        step("height", "Tap the height label, type 30",
             "Tap the height label and type thirty."),
        step("fit", "Tap Fit View", "Fit View."),
        step("exit", "Tap Exit Sketching", "Tap Exit Sketching."),
        step("iso", "Views › Isometric", "Views, Isometric."),
    ),
    chapter("Revolve it",
        step("tap_region", "Tap inside the rectangle",
             "Tap inside the rectangle. The Extrude bar comes up, and on its right there's Revolve."),
        step("rev", "Tap Revolve",
             "Tap Revolve. Now it asks for the axis."),
        step("axis_pick", "Tap the line: the axis",
             "Tap the line we drew."),
        step("angle", "Angle › type 270 › check",
             "The angle starts at a full turn. Tap Angle and type two hundred seventy, then the check mark. Three quarters of a ring."),
    ),
    chapter("Take a look",
        *views("Top", "Isometric"),
        outro("revolve", "Type three hundred sixty for a full turn: that's how you make anything round."),
    ),
], "How to Revolve on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO REVOLVE\nspin a profile · every tap",
   """How to revolve a sketch around an axis in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: sketch on the front plane, draw an axis line and a profile, then Revolve with an exact angle.

What you'll learn
• Sketching on the front plane
• Drawing an axis line and a profile beside it
• Revolve from the Extrude bar, and picking the axis
• Typing the angle: 270 or a full 360""",
   ["revolve", "how to revolve", "revolve tutorial", "CAD revolve", "lathe", "axis"])

# ---- 5. sweep --------------------------------------------------------------------------------------------------

SWEEP = video("sweep", "Sweep along a path", 5, [
    intro("sweep", "sweep a shape along a path"),
    chapter("Draw the path",
        step("new", "Start a Blank Design", "Start a blank design."),
        step("line_tool", "Tap Sketch, then Line",
             "The path first. Tap Sketch, then Line."),
        step("ground", "Tap the grid: the ground plane",
             "Tap the grid to sketch on the ground."),
        step("seg1", "Drag the first line",
             "Drag the first line, straight up the screen from the centre."),
        step("seg2", "Drag the second line from its end",
             "Then drag a second line from the end of the first, to the right. Together they're the path."),
        step("exit", "Tap Exit Sketching", "Exit Sketching."),
    ),
    chapter("Draw the profile",
        step("iso", "Views › Isometric", "Views, Isometric."),
        step("circle_tool", "Tap Sketch, then Circle",
             "Now the shape that travels along the path. Tap Sketch, then Circle."),
        step("front", "Tap the blue front plane",
             "Tap the blue front plane. It stands across the start of the path."),
        step("circle", "Drag a small circle at the start",
             "Drag a small circle from the centre, where the path starts."),
        step("exit2", "Tap Exit Sketching", "Exit Sketching."),
    ),
    chapter("Sweep",
        step("iso2", "Views › Isometric", "Isometric again."),
        step("tap_circle", "Tap inside the circle",
             "Tap inside the circle. The Extrude bar comes up."),
        step("sweep_btn", "Tap Sweep",
             "Tap Sweep. It asks for the path."),
        step("path1", "Tap the first line",
             "Tap the first line of the path."),
        step("path2", "Tap the second line",
             "And the second. The bar counts two path segments, and the preview follows the corner."),
        step("commit", "Tap Sweep to finish",
             "Tap Sweep to finish."),
        step("fit", "Tap Fit View", "Fit View."),
        outro("sweep", "Pipes, handles, wires and rails are all sweeps."),
    ),
], "How to Sweep Along a Path on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO SWEEP\nshape along a path · every tap",
   """How to sweep a shape along a path in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: draw a path on the ground, a circle on the front plane at its start, then Sweep and pick the path segments.

What you'll learn
• Drawing a path from line segments
• Putting the profile at the start of the path
• Sweep from the Extrude bar, and picking the path in order
• Finishing the sweep""",
   ["sweep", "how to sweep", "sweep tutorial", "CAD sweep", "pipe", "path"])

# ---- 6. loft ------------------------------------------------------------------------------------------------------

LOFT = video("loft", "Loft between shapes", 6, [
    intro("loft", "loft a smooth shape between a square and a circle"),
    block_chapter(40, 40, 10, title="Make a base"),
    chapter("A square on top",
        step("sq_tool", "Tap Sketch, then Rectangle",
             "Tap Sketch, then Rectangle."),
        step("sq_face", "Tap the top face",
             "Tap the top face of the base."),
        step("sq_draw", "Drag from corner to corner",
             "Drag a rectangle."),
        step("sq_w", "Tap the width label, type 30",
             "Width thirty."),
        step("sq_d", "Tap the depth label, type 30",
             "Depth thirty: a square."),
        step("sq_exit", "Tap Exit Sketching", "Exit Sketching."),
        step("sq_iso", "Views › Isometric", "Views, Isometric."),
    ),
    chapter("Add a plane above it",
        deselect_step(),
        step("pl_face", "Tap the top face, beside the square",
             "Tap the top face, just outside the square. The bar says face selected."),
        step("pl_offset", "Tap Offset Plane",
             "On the right of the bar, tap Offset Plane."),
        step("pl_dist", "Distance › type 40 › check",
             "Type forty and tap the check mark. A new plane floats forty millimeters above the top."),
    ),
    chapter("A circle on the plane",
        step("ci_tool", "Tap Sketch, then Circle",
             "Tap Sketch, then Circle."),
        step("ci_plane", "Tap the new plane",
             "Tap the new plane above the base."),
        step("ci_draw", "Drag from the centre out",
             "Drag a circle from the middle of the plane."),
        step("ci_size", "Tap the diameter, type 20",
             "Tap the diameter and type twenty."),
        step("ci_exit", "Tap Exit Sketching", "Exit Sketching."),
    ),
    chapter("Loft",
        step("lo_iso", "Views › Isometric", "Isometric."),
        step("lo_square", "Tap inside the square",
             "Tap inside the square. The Extrude bar comes up."),
        step("lo_btn", "Tap Loft",
             "Tap Loft."),
        step("lo_circle", "Tap inside the circle",
             "Now tap inside the circle. The bar says two sections, and the preview blends the square into the circle."),
        step("lo_commit", "Tap Loft to finish",
             "Tap Loft to finish."),
        step("lo_fit", "Tap Fit View", "Fit View."),
        outro("loft", "Add more sections on more planes, and the loft flows through all of them."),
    ),
], "How to Loft (Square to Round) on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO LOFT\nsquare to round · every tap",
   """How to loft between two shapes in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: make a base, add an offset plane above it, sketch a square and a circle, then Loft from one to the other.

What you'll learn
• Offset Plane from a face
• Sketching on a face and on a construction plane
• Loft from the Extrude bar, adding sections in order""",
   ["loft", "how to loft", "loft tutorial", "square to round", "offset plane", "transition"])

# ---- 7. twist ------------------------------------------------------------------------------------------------------

TWIST = video("twist", "Twist a shape", 7, [
    intro("twist a shape", "twist a solid by rotating its top face"),
    block_chapter(30, 30, 60, title="Make a tall block"),
    chapter("Twist the top face",
        step("desel", "Tap empty space, then Fit View",
             "Tap an empty spot to clear the selection, and Fit View to see the whole block."),
        step("tw_face", "Tap the top face",
             "Tap the top face. The bar says face selected."),
        step("tw_tool", "Tap Transform, then Rotate",
             "Tap Transform, then Rotate. Curved arrows appear on the face: one for each axis."),
        step("tw_ring", "Tap the flat, round arrow",
             "Tap the curved arrow that goes around the face, flat on top. That one spins the face in place."),
        step("tw_angle", "Angle › type 30 › check",
             "Type thirty and tap the check mark. The top turns thirty degrees, and the sides twist to follow."),
    ),
    chapter("Twist it further",
        step("tw2_ring", "Tap the same arrow again",
             "The tool stays on the face, so tap the same arrow again."),
        step("tw2_angle", "Angle › type 30 › check",
             "Another thirty. Sixty degrees in all."),
        step("tw_done", "Tap Done",
             "Tap Done at the top."),
    ),
    chapter("Take a look",
        *views("Front", "Isometric"),
        outro("twist a shape", "Rotate a face about its own axis to twist, or about the other arrows to tilt it."),
    ),
], "How to Twist a Shape on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO TWIST\nrotate a face · every tap",
   """How to twist a solid in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: make a tall block, select its top face, then Transform › Rotate and turn the face by an exact angle — the sides twist to follow.

What you'll learn
• Selecting a face
• Transform › Rotate on a face
• Picking the rotation arrow and typing an exact angle
• Twisting further in steps""",
   ["twist", "how to twist", "twisted shape", "rotate face", "twist tutorial", "twisted block"])

# ---- 8. shell -------------------------------------------------------------------------------------------------------

SHELL = video("shell", "Shell: hollow a part", 8, [
    intro("shell", "hollow out a solid with a shell"),
    block_chapter(40, 40, 30, fit_after=True),
    chapter("Shell with an open top",
        step("s1_tool", "Tap Modify, then Shell",
             "Tap Modify, then Shell. The bar says: tap a body to shell."),
        step("s1_face", "Tap the top face",
             "Tap the top face. That picks the block, and opens that face: the bar says one face open."),
        step("s1_thick", "Thickness › type 2 › check",
             "Tap Thickness and type two: that's the wall thickness. Tap the check mark."),
        step("s1_apply", "Tap Apply, then empty space",
             "Tap Apply. The inside is gone, leaving two millimeter walls. Tap an empty spot to see it without the selection."),
    ),
    chapter("Look inside",
        *views("Top", "Isometric"),
    ),
    chapter("Open two faces",
        step("undo", "Tap Undo",
             "Now let's undo, and try it with two open faces. Tap Undo at the top."),
        step("s2_tool", "Tap Modify, then Shell",
             "Shell again."),
        step("s2_top", "Tap the top face",
             "Tap the top face."),
        step("s2_front", "Tap the front face",
             "And the face in front. The bar says two faces open."),
        step("s2_thick", "Thickness › type 3 › check",
             "Three millimeter walls this time."),
        step("s2_apply", "Tap Apply, then empty space",
             "Tap Apply. Tap an empty spot to see it without the selection."),
        outro("shell", "Open as many faces as you like, or none for a closed hollow part."),
    ),
], "How to Shell (Hollow) a Part on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO SHELL\nhollow a part · every tap",
   """How to shell — hollow out — a part in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: make a block, shell it with an open top and two millimeter walls, then open two faces at once.

What you'll learn
• Modify › Shell, and tapping the faces to leave open
• Typing the wall thickness
• Undo, and opening more than one face""",
   ["shell", "hollow", "how to shell", "shell tutorial", "wall thickness", "hollow part"])

# ---- 9. pattern ------------------------------------------------------------------------------------------------------

PATTERN = video("pattern", "Pattern: linear & circular", 9, [
    intro("pattern", "repeat a part in a row and in a circle"),
    chapter("Make a blade",
        step("new", "Start a Blank Design", "Start a blank design."),
        step("rect_tool", "Tap Sketch, then Rectangle", "Tap Sketch, then Rectangle."),
        step("ground", "Tap the grid: the ground plane", "Tap the grid to sketch on the ground."),
        step("draw", "Drag from the centre out",
             "Drag a rectangle starting right at the centre."),
        step("width", "Tap the width label, type 30", "Width thirty."),
        step("depth", "Tap the depth label, type 4", "Depth four: a long thin blade."),
        step("fit", "Tap Fit View", "Fit View."),
        step("exit", "Tap Exit Sketching", "Exit Sketching."),
        step("iso", "Views › Isometric", "Views, Isometric."),
        step("tap_region", "Tap inside the rectangle", "Tap inside it."),
        step("height", "Distance › type 6 › check", "Distance six, and the check mark."),
    ),
    chapter("Linear pattern",
        step("l_tool", "Tap Transform, then Pattern",
             "The blade is selected. Tap Transform, then Pattern. Ghost copies show the preview."),
        step("l_count", "Count › type 4 › check", "Tap Count and type four."),
        step("l_spacing", "Spacing › type 10 › check", "Tap Spacing and type ten millimeters."),
        step("l_dir", "Tap Z for the direction", "Tap Z, so the copies line up side by side."),
        step("l_apply", "Tap Apply", "Tap Apply. Four blades in a row."),
    ),
    chapter("Circular pattern",
        step("undo", "Tap Undo", "Now undo that, and make a circle instead."),
        step("c_sel", "Double-tap the blade", "Double-tap the blade to select it."),
        step("c_tool", "Tap Transform, then Pattern", "Transform, Pattern."),
        step("c_type", "Type › Circular", "Tap Circular."),
        step("c_count", "Count › type 8 › check", "Count eight."),
        step("c_axis", "Tap Y for the axis", "Tap Y: spin around the vertical axis through the centre."),
        step("c_apply", "Tap Apply", "Tap Apply. Eight blades around the centre, like a fan."),
        outro("pattern", "Linear patterns make rows, and circular patterns go around an axis."),
    ),
], "How to Pattern (Linear & Circular) on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO PATTERN\nrows & circles · every tap",
   """How to make linear and circular patterns in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: make a blade, repeat it in a row with a count and spacing, undo, then repeat it eight times around the vertical axis.

What you'll learn
• Transform › Pattern on a selected body
• Linear: count, spacing and direction
• Circular: count and axis
• Undo, and selecting a body with a double-tap""",
   ["pattern", "circular pattern", "linear pattern", "how to pattern", "array", "polar array"])

# ---- 10. mirror ----------------------------------------------------------------------------------------------------------

MIRROR = video("mirror", "Mirror a part", 10, [
    intro("mirror", "mirror a part across a plane"),
    chapter("Make a block to one side",
        step("new", "Start a Blank Design", "Start a blank design."),
        step("rect_tool", "Tap Sketch, then Rectangle", "Tap Sketch, then Rectangle."),
        step("ground", "Tap the grid: the ground plane", "Tap the grid to sketch on the ground."),
        step("draw", "Drag a rectangle beside the centre",
             "Drag a rectangle a little away from the centre, so the mirror copy won't touch it."),
        step("width", "Tap the width label, type 20", "Width twenty."),
        step("depth", "Tap the depth label, type 15", "Depth fifteen."),
        step("fit", "Tap Fit View", "Fit View."),
        step("exit", "Tap Exit Sketching", "Exit Sketching."),
        step("iso", "Views › Isometric", "Views, Isometric."),
        step("tap_region", "Tap inside the rectangle", "Tap inside it."),
        step("height", "Distance › type 10 › check", "Distance ten, and the check mark."),
    ),
    chapter("Mirror across the side plane",
        step("m1_tool", "Tap Transform, then Mirror",
             "The block is selected. Tap Transform, then Mirror. A list of planes opens."),
        step("m1_plane", "Pick YZ Plane",
             "Pick YZ Plane, the side plane through the centre. A mirrored copy appears on the other side."),
    ),
    chapter("Mirror again",
        step("m2_tool", "Tap Transform, then Mirror",
             "The copy is selected now. Mirror it too."),
        step("m2_plane", "Pick XY Plane",
             "This time pick XY Plane, the front plane."),
        step("m3_sel", "Double-tap the first block",
             "Double-tap the first block to select it."),
        step("m3_tool", "Tap Transform, then Mirror", "Transform, Mirror."),
        step("m3_plane", "Pick XY Plane", "XY Plane. Four blocks, perfectly symmetric."),
        *views("Top", "Isometric"),
        outro("mirror", "Mirror always keeps the original; use Combine, Union to join the pieces."),
    ),
], "How to Mirror a Part on iPad, iPhone, Mac — Every Tap Shown (Free CAD Tutorial)",
   "HOW TO MIRROR\nsymmetric parts · every tap",
   """How to mirror a part across a plane in OpenShape 3D, the free CAD app for iPhone, iPad and Mac. Every tap is shown: make a block off to one side, mirror it across the side plane, then across the front plane, for four symmetric blocks.

What you'll learn
• Transform › Mirror on a selected body
• Choosing the mirror plane
• Selecting a body with a double-tap
• Building symmetric layouts step by step""",
   ["mirror", "how to mirror", "mirror tutorial", "symmetry", "symmetric", "mirror body"])


PROBE = video("probe", "Probe", 0, [block_chapter(40, 30, 20)],
              "probe", "PROBE", "probe", [])

EXPLORE = video("explore", "Explore", 0, [chapter("Explore",
    step("new", "Start", "Start."), step("rect_tool", "Explore", "Exploring the tools."), step("done", "Done", "Done."))],
    "explore", "EXPLORE", "explore", [])

VIDEOS = {"probe": PROBE, "explore": EXPLORE, "fillet": FILLET, "chamfer": CHAMFER, "extrude": EXTRUDE,
          "revolve": REVOLVE, "sweep": SWEEP, "loft": LOFT, "twist": TWIST, "shell": SHELL,
          "pattern": PATTERN, "mirror": MIRROR}
