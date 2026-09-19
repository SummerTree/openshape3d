"""Scripts for the YouTube Shorts: "How do you model this?" in under a
minute, on an iPhone, every tap shown.

Each short opens on the finished part ("How do you model this?"), builds it
step by step, and ends on it again. A step is (id, caption, say): the id is
what shorts_actions.py yields, the caption is the big line on screen, `say`
the narration ("" = silent: compose plays that step fast). Narration follows
pronunciation.py — numbers and units as words.
"""

DOWNLOAD = "Download app: https://apps.apple.com/us/app/openshape3d/id6792536439"
HASHTAGS = "#shorts #CAD #3Dmodeling #iPhone #3Dprinting #OpenShape3D"
BASE_TAGS = ["shorts", "OpenShape 3D", "CAD", "3D modeling", "iPhone CAD", "CAD on iPhone", "iPad CAD",
             "free CAD app", "3D printing", "how to model", "CAD tips", "3D modeling tips"]


def block(w, d, h, what="block"):
    return [
        ("new", "New design", "New design."),
        ("rect_tool", "Sketch › Rectangle", "Rectangle tool,"),
        ("ground", "Tap the ground plane", "on the ground plane."),
        ("draw", "Drag a rectangle", "Drag it out,"),
        ("width", f"Width {w} mm", f"make it {num(w)}"),
        ("depth", f"Depth {d} mm", f"by {num(d)}."),
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
        ("tap_region", "Tap the rectangle", "Tap it,"),
        ("height", f"Extrude {h} mm", f"and pull it up {num(h)}."),
    ]


def disc(dia, h, hole=None):
    steps = [
        ("new", "New design", "New design."),
        ("circle_tool", "Sketch › Circle", "Circle tool,"),
        ("ground", "Tap the ground plane", "on the ground."),
        ("draw", "Drag a circle", ""),
        ("size", f"Diameter {dia} mm", f"{num(dia)} across."),
    ]
    if hole:
        steps += [
            ("fit", "Fit View", ""),
            ("hole", "Another circle", "Another one inside,"),
            ("hole_size", f"Diameter {hole} mm", f"{num(hole)} across."),
        ]
    return steps + [
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
    ] + ([("zoom", "Pinch to zoom in", "")] if hole else []) + [
        ("tap_region", "Tap the " + ("ring" if hole else "circle"), "Tap the " + ("ring" if hole else "circle") + ","),
        ("height", f"Extrude {h} mm", f"and pull it up {num(h)}."),
    ]


WORDS = {1: "one", 2: "two", 4: "four", 5: "five", 6: "six", 8: "eight", 10: "ten", 12: "twelve", 15: "fifteen",
         18: "eighteen", 20: "twenty", 24: "twenty-four", 25: "twenty-five", 30: "thirty", 35: "thirty-five",
         40: "forty", 60: "sixty", 80: "eighty", 360: "three sixty"}


def num(n):
    return WORDS.get(n, str(n))


def short(n, slug, name, hook, steps, reveal, title, what, tags):
    return {"n": n, "slug": slug, "name": name, "hook": hook,
            "steps": [("hook", "", hook)] + steps + [("reveal", "Made on iPhone", reveal)],
            "title": title,
            "description": f"{DOWNLOAD}\n\n{what}\n\nEvery tap is real, filmed on an iPhone in OpenShape 3D, a free, "
                           f"open-source CAD app for iPhone, iPad and Mac.\n\nCAD Tip #{n} of 10\n\n{HASHTAGS}",
            "tags": tags + BASE_TAGS}


SHORTS = {
    "spring": short(1, "spring", "Spring", "How do you model a spring?", [
        ("new", "New design", "New design."),
        ("circle_tool", "Sketch › Circle", "Circle tool,"),
        ("ground", "Tap the ground plane", "on the ground."),
        ("draw", "Drag a circle", "A small circle,"),
        ("size", "Diameter 4 mm", "four millimeters."),
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
        ("tap_region", "Tap the circle", "Tap it,"),
        ("helix", "Helix", "and pick Helix."),
        ("radius", "Radius 12 mm", "Radius twelve,"),
        ("pitch", "Pitch 8 mm", "pitch eight,"),
        ("turns", "5 turns", "five turns."),
        ("create", "Create", "Create."),
        ("steel", "Material › Steel", "Make it steel."),
    ], "That's a spring — a circle and a helix. Made on an iPhone.",
        "How do you model a spring? | CAD on iPhone #shorts",
        "A spring in 30 seconds: a 4 mm circle, then Helix — radius 12 mm, pitch 8 mm, 5 turns — and a steel finish.",
        ["spring", "helix", "coil spring CAD", "helix sweep"]),

    "vase": short(2, "twisted-vase", "Twisted vase", "How do you model a twisted vase?", [
        ("new", "New design", "New design."),
        ("poly_tool", "Sketch › Polygon", "Polygon tool,"),
        ("ground", "Tap the ground plane", "on the ground."),
        ("draw", "Drag a hexagon", "Drag a hexagon,"),
        ("size", "Radius 15 mm", "radius fifteen."),
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
        ("tap_region", "Tap the hexagon", "Tap it,"),
        ("height", "Extrude 60 mm", "and pull it up sixty."),
        ("top", "Tap the top face", "Tap the top face,"),
        ("rotate", "Transform › Rotate", "Rotate,"),
        ("ring", "Tap the ring", ""),
        ("angle", "Twist 30°", "and twist it thirty degrees."),
        ("done", "Done", ""),
        ("shell", "Modify › Shell", "Shell,"),
        ("open", "Tap the top face", "open the top,"),
        ("thick", "Walls 2 mm", "two millimeter walls."),
        ("apply", "Apply", ""),
        ("gloss", "Material › Plastic Gloss", "Glossy finish."),
    ], "A twisted vase, from a hexagon. Made on an iPhone.",
        "How do you model a twisted vase? | CAD on iPhone #shorts",
        "A twisted vase from a hexagon: radius 15 mm, 60 mm tall, rotate the top face 30°, then Shell it open with 2 mm walls.",
        ["twisted vase", "vase mode", "3D printed vase", "twist", "shell", "hexagon"]),

    "donut": short(3, "donut", "Donut", "How do you model a donut?", [
        ("new", "New design", "New design."),
        ("line_tool", "Sketch › Line", "Line tool,"),
        ("front", "Tap the front plane", "on the front plane."),
        ("axis", "Draw the axis", "Draw an axis,"),
        ("circle_tool", "Circle", ""),
        ("circle", "A circle beside it", "and a circle beside it."),
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
        ("tap_region", "Tap the circle", "Tap the circle,"),
        ("revolve", "Revolve", "Revolve,"),
        ("axis_pick", "Tap the axis", "around the line,"),
        ("angle", "360°", "all the way round."),
        ("gloss", "Material › Plastic Gloss", ""),
    ], "That's a donut — one circle, revolved. Made on an iPhone.",
        "How do you model a donut? | CAD on iPhone #shorts",
        "A torus in seconds: a line for the axis, a circle beside it, then Revolve 360° around the line.",
        ["donut", "torus", "revolve", "blender donut"]),

    "bowl": short(4, "bowl", "Bowl", "How do you model a bowl?", disc(80, 35) + [
        ("fillet", "Modify › Fillet", "Fillet,"),
        ("edge", "Tap the bottom edge", "the bottom edge,"),
        ("radius", "Radius 25 mm", "twenty-five millimeters."),
        ("apply", "Apply", ""),
        ("shell", "Modify › Shell", "Shell it,"),
        ("open", "Tap the top face", "open the top,"),
        ("thick", "Walls 2 mm", "two millimeters."),
        ("shell_apply", "Apply", ""),
        ("wood", "Material › Wood", "And make it wood."),
    ], "A wooden bowl: a cylinder, a fillet and a shell. Made on an iPhone.",
        "How do you model a bowl? | CAD on iPhone #shorts",
        "A bowl from a cylinder: 80 mm across, 35 tall, a 25 mm fillet on the bottom edge, then Shell with 2 mm walls and a wood finish.",
        ["bowl", "fillet", "shell", "wooden bowl"]),

    "nut": short(5, "hex-nut", "Hex nut", "How do you model a hex nut?", [
        ("new", "New design", "New design."),
        ("poly_tool", "Sketch › Polygon", "Polygon tool,"),
        ("ground", "Tap the ground plane", "on the ground."),
        ("draw", "Drag a hexagon", "Drag a hexagon,"),
        ("size", "Radius 12 mm", "radius twelve."),
        ("fit", "Fit View", ""),
        ("circle_tool", "Circle", "A circle in the middle,"),
        ("hole", "Drag from the centre", ""),
        ("hole_size", "Diameter 12 mm", "twelve across."),
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
        ("tap_region", "Tap between them", "Tap between them,"),
        ("height", "Extrude 10 mm", "pull it up ten."),
        ("chamfer", "Modify › Chamfer", "Chamfer"),
        ("top", "Tap the top face", "the top edges,"),
        ("size2", "1 mm", "one millimeter."),
        ("apply", "Apply", ""),
        ("steel", "Material › Steel", "Steel."),
    ], "That's a hex nut. Made on an iPhone.",
        "How do you model a hex nut? | CAD on iPhone #shorts",
        "A hex nut: a hexagon with a 12 mm circle inside, extrude the ring 10 mm, chamfer the top edges 1 mm, steel finish.",
        ["hex nut", "nut", "polygon", "chamfer"]),

    "loft": short(6, "square-to-round", "Square to round", "How do you model a square-to-round adapter?", block(50, 50, 6) + [
        ("sq_tool", "Sketch › Rectangle", "A square on top,"),
        ("sq_face", "Tap the top face", ""),
        ("sq_draw", "Drag a rectangle", ""),
        ("sq_w", "Width 30 mm", "thirty"),
        ("sq_d", "Depth 30 mm", "by thirty."),
        ("sq_exit", "Exit Sketching", ""),
        ("sq_iso", "Views › Isometric", ""),
        ("pl_face", "Tap the top face", "Tap the top face,"),
        ("pl_offset", "Offset Plane", "Offset Plane,"),
        ("pl_dist", "40 mm up", "forty up."),
        ("ci_tool", "Sketch › Circle", "A circle"),
        ("ci_plane", "Tap the new plane", "on the new plane,"),
        ("ci_draw", "Drag a circle", ""),
        ("ci_size", "Diameter 24 mm", "twenty-four across."),
        ("ci_exit", "Exit Sketching", ""),
        ("ci_iso", "Views › Isometric", ""),
        ("lo_square", "Tap the square", "Tap the square,"),
        ("loft", "Loft", "Loft,"),
        ("pick", "Tap the circle", "to the circle."),
        ("commit", "Create", ""),
    ], "Square to round, with one loft. Made on an iPhone.",
        "How do you model a square-to-round adapter? | CAD on iPhone #shorts",
        "A square-to-round transition: a 30 mm square and a 24 mm circle 40 mm above it, joined with Loft.",
        ["loft", "square to round", "transition", "adapter"]),

    "pipe": short(7, "bent-pipe", "Bent pipe", "How do you model a bent pipe?", [
        ("new", "New design", "New design."),
        ("line_tool", "Sketch › Line", "Line tool,"),
        ("ground", "Tap the ground plane", "on the ground."),
        ("line1", "Draw a line", "One line,"),
        ("len1", "Length 30 mm", "thirty long,"),
        ("line2", "Draw the next line", "and another,"),
        ("len2", "Length 30 mm", "thirty."),
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
        ("circle_tool", "Sketch › Circle", "Now a circle"),
        ("front", "Tap the front plane", "on the front plane,"),
        ("circle", "Drag a circle", ""),
        ("size", "Diameter 20 mm", "twenty across."),
        ("exit2", "Exit Sketching", ""),
        ("iso2", "Views › Isometric", ""),
        ("tap_region", "Tap the circle", "Tap it,"),
        ("sweep", "Sweep", "Sweep,"),
        ("path1", "Tap the first line", "along the path."),
        ("path2", "Tap the second line", ""),
        ("commit", "Create", ""),
        ("shell", "Modify › Shell", "Shell,"),
        ("end1", "Tap one end", "open both ends,"),
        ("end2", "Tap the other end", ""),
        ("thick", "Walls 2 mm", "two millimeters."),
        ("apply", "Apply", ""),
    ], "A bent pipe: a path, a circle, a sweep. Made on an iPhone.",
        "How do you model a bent pipe? | CAD on iPhone #shorts",
        "A pipe elbow: two 30 mm lines for the path, a 20 mm circle, Sweep along the path, then Shell both ends open with 2 mm walls.",
        ["pipe", "sweep", "elbow", "tube"]),

    "gem": short(8, "gem", "Gem", "How do you model a gem?", [
        ("new", "New design", "New design."),
        ("poly_tool", "Sketch › Polygon", "Polygon,"),
        ("ground", "Tap the ground plane", "on the ground,"),
        ("sides", "8 sides", "eight sides."),
        ("draw", "Drag an octagon", ""),
        ("size", "Radius 15 mm", "Radius fifteen."),
        ("exit", "Exit Sketching", ""),
        ("iso", "Views › Isometric", ""),
        ("tap_region", "Tap the octagon", "Tap it,"),
        ("height", "Extrude 6 mm", "pull it up six."),
        ("chamfer", "Modify › Chamfer", "Chamfer"),
        ("top", "Tap the top face", "the top,"),
        ("size2", "5 mm", "five millimeters."),
        ("apply", "Apply", ""),
        ("gloss", "Material › Plastic Gloss", ""),
        ("select", "Double-tap the body", "Select it,"),
        ("mirror", "Transform › Mirror", "and mirror it"),
        ("ground_plane", "Ground (ZX)", "across the ground."),
        ("front_view", "Views › Front", ""),
        ("gloss2", "Material › Plastic Gloss", "Same finish on the copy."),
    ], "A gem: an octagon, a chamfer and a mirror. Made on an iPhone.",
        "How do you model a gem? | CAD on iPhone #shorts",
        "A cut gem: an octagon extruded 6 mm, a 5 mm chamfer round the top, then Mirror across the ground plane.",
        ["gem", "diamond", "chamfer", "mirror", "octagon"]),

    "frame": short(9, "cube-frame", "Cube frame", "How do you model this cube frame?", block(30, 30, 30) + [
        ("c1_tool", "Sketch › Rectangle", "A square on top,"),
        ("c1_face", "Tap the top face", ""),
        ("c1_draw", "Drag a rectangle", ""),
        ("c1_w", "Width 20 mm", "twenty"),
        ("c1_d", "Depth 20 mm", "by twenty."),
        ("c1_exit", "Exit Sketching", ""),
        ("c1_iso", "Views › Isometric", ""),
        ("c1_tap", "Tap the square", "Tap it,"),
        ("c1_sub", "Subtract", "subtract,"),
        ("c1_depth", "Cut −30 mm", "all the way through."),
        ("c2_tool", "Sketch › Rectangle", "Same on the front."),
        ("c2_face", "Tap the front face", ""),
        ("c2_draw", "Drag a rectangle", ""),
        ("c2_w", "Width 20 mm", ""),
        ("c2_d", "Depth 20 mm", ""),
        ("c2_exit", "Exit Sketching", ""),
        ("c2_iso", "Views › Isometric", ""),
        ("c2_tap", "Tap the square", ""),
        ("c2_sub", "Subtract", ""),
        ("c2_depth", "Cut −30 mm", ""),
        ("c3_tool", "Sketch › Rectangle", "And the side."),
        ("c3_face", "Tap the side face", ""),
        ("c3_draw", "Drag a rectangle", ""),
        ("c3_w", "Width 20 mm", ""),
        ("c3_d", "Depth 20 mm", ""),
        ("c3_exit", "Exit Sketching", ""),
        ("c3_iso", "Views › Isometric", ""),
        ("c3_tap", "Tap the square", ""),
        ("c3_sub", "Subtract", ""),
        ("c3_depth", "Cut −30 mm", ""),
    ], "Three cuts, and the cube is a frame. Made on an iPhone.",
        "How do you model this cube frame? | CAD on iPhone #shorts",
        "A cube frame: a 30 mm cube, then a 20 mm square cut straight through the top, the front and the side.",
        ["cube frame", "hollow cube", "boolean", "subtract", "CAD puzzle"]),

    "ring": short(10, "ring", "Ring", "How do you model a ring?", disc(26, 6, hole=18) + [
        ("fillet", "Modify › Fillet", "Fillet"),
        ("top", "Tap the top face", "the top edges,"),
        ("radius", "Radius 1 mm", "one millimeter."),
        ("apply", "Apply", ""),
        ("brass", "Material › Brass", "And make it brass."),
    ], "A brass ring: two circles, a fillet and a finish. Made on an iPhone.",
        "How do you model a ring? | CAD on iPhone #shorts",
        "A ring: circles 26 and 18 mm across, extrude the band 6 mm, fillet the top edges 1 mm, brass finish.",
        ["ring", "jewelry CAD", "fillet", "brass"]),
}
