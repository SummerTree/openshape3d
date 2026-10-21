#!/usr/bin/env python3
"""The video, built and rendered inside Blender. Run by `make_video.py`:

    Blender -b --python blender_video.py -- --run RUN --scan scan.glb --timing timing.json --frames out/frames

One Blender scene, one timeline. Every segment of `timing.json` (title,
scan, analysis, MCP calls, build-up, comparison, heatmap, overlays, numbers,
outro) owns a frame range; objects are shown and hidden by keyframed
`hide_render`, the camera jumps between keyframes with constant
interpolation and orbits inside a segment, and the 2D cards are text and
image planes parked in front of a second, fixed camera. EEVEE renders PNG
frames; ffmpeg (in make_video.py) assembles them with the narration.

Inputs from the build run: `stages/*.stl` (the model after each feature),
the finished model, the scan (GLB), the app's overlay pictures, the app's
screenshots, `accuracy.json`, and `heatmap.ply` (the scan coloured by its
distance to the model, from make_video.py).
"""
import json
import math
import os
import sys

import bpy
from mathutils import Vector

def _fail(kind, value, tb):
    import traceback
    traceback.print_exception(kind, value, tb)
    sys.stdout.flush()
    os._exit(1)


sys.excepthook = _fail

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
opts = {}
for i in range(0, len(argv), 2):
    opts[argv[i].lstrip("-")] = argv[i + 1]
RUN = opts["run"]
SCAN = opts["scan"]
TIMING = json.load(open(opts["timing"]))
FRAMES_DIR = opts["frames"]
FPS = int(opts.get("fps", "30"))
SAMPLES = int(opts.get("samples", "16"))
WIDTH, HEIGHT = 1920, 1080

summary = json.load(open(os.path.join(RUN, "summary.json")))
accuracy = json.load(open(os.path.join(RUN, "accuracy.json")))

MM = 0.001
BLUE = (0.16, 0.44, 0.86, 1)
RED = (0.86, 0.17, 0.12, 1)
INK = (0.10, 0.12, 0.16, 1)
MUTED = (0.42, 0.46, 0.52, 1)


# ---------------------------------------------------------------- helpers

def material(name, color, alpha=1.0, roughness=0.5, metallic=0.0, emission=0.0, vertex_colors=False):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes["Principled BSDF"]
    if vertex_colors:
        attr = nodes.new("ShaderNodeVertexColor")
        attr.layer_name = "Col"
        mat.node_tree.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Alpha"].default_value = alpha
    if emission:
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = emission
    if alpha < 1:
        mat.blend_method = "BLEND"
        mat.surface_render_method = "BLENDED"
        mat.show_transparent_back = False
    return mat


def flat_material(name, color=None, image=None):
    """Emission only — cards, captions and pictures keep their exact colours
    whatever the lights do."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    for node in list(nodes):
        nodes.remove(node)
    out = nodes.new("ShaderNodeOutputMaterial")
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Strength"].default_value = 1.0
    if image is not None:
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = image
        links.new(tex.outputs["Color"], emission.inputs["Color"])
    else:
        emission.inputs["Color"].default_value = color
    links.new(emission.outputs["Emission"], out.inputs["Surface"])
    return mat


def import_stl(path, name, mat):
    before = set(bpy.data.objects)
    bpy.ops.wm.stl_import(filepath=path, global_scale=MM, forward_axis="NEGATIVE_Z", up_axis="Y")
    ob = [o for o in bpy.data.objects if o not in before][0]
    ob.name = name
    ob.data.materials.clear()
    ob.data.materials.append(mat)
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.shade_smooth()
    return ob


def import_glb(path, name, mat):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before and o.type == "MESH"]
    ob = new[0]
    if len(new) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for o in new:
            o.select_set(True)
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.join()
    ob.name = name
    ob.data.materials.clear()
    ob.data.materials.append(mat)
    return ob


def import_ply(path, name, mat):
    before = set(bpy.data.objects)
    bpy.ops.wm.ply_import(filepath=path, global_scale=1.0, forward_axis="NEGATIVE_Z", up_axis="Y")
    ob = [o for o in bpy.data.objects if o not in before][0]
    ob.name = name
    ob.data.materials.clear()
    ob.data.materials.append(mat)
    return ob


def bounds(ob):
    pts = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


def hide(ob, frame, hidden):
    ob.hide_render = hidden
    ob.hide_viewport = hidden
    ob.keyframe_insert("hide_render", frame=frame)
    ob.keyframe_insert("hide_viewport", frame=frame)


def show_only(objects, visible, frame):
    for ob in objects:
        hide(ob, frame, ob not in visible)


def action_fcurves(ob):
    """The F-curves of an object's action, on Blender 4.x (`action.fcurves`)
    and 5.x (layered actions: layer → strip → the channel bag of the slot)."""
    ad = ob.animation_data
    if not ad or not ad.action:
        return []
    action = ad.action
    curves = getattr(action, "fcurves", None)
    if curves is not None:
        return list(curves)
    out = []
    for layer in action.layers:
        for strip in layer.strips:
            bag = strip.channelbag(ad.action_slot) if ad.action_slot else None
            if bag:
                out += list(bag.fcurves)
    return out


def set_interpolation(ob, mode):
    for fcurve in action_fcurves(ob):
        for kp in fcurve.keyframe_points:
            kp.interpolation = mode


def constant_interpolation(ob):
    set_interpolation(ob, "CONSTANT")


def text_object(name, body, size, color, location, align="LEFT", width=None, emission=1.0):
    curve = bpy.data.curves.new(name, type="FONT")
    curve.body = body
    curve.size = size
    curve.align_x = align
    if width:
        curve.text_boxes[0].width = width
    ob = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(ob)
    ob.location = location
    # Stand the text up on the board: its face toward the card camera (−Y).
    ob.rotation_euler = (math.radians(90), 0, 0)
    ob.data.materials.append(flat_material(name + "-mat", color))
    return ob


def image_plane(name, path, width, location):
    img = bpy.data.images.load(path)
    aspect = img.size[1] / img.size[0]
    bpy.ops.mesh.primitive_plane_add(size=1, location=location)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (width, width * aspect, 1)
    ob.data.materials.append(flat_material(name + "-mat", image=img))
    return ob, aspect


# ---------------------------------------------------------------- scene

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.eevee.taa_render_samples = SAMPLES
scene.render.resolution_x, scene.render.resolution_y = WIDTH, HEIGHT
scene.render.fps = FPS
# JPEG frames: a 100 s film is ~3,000 frames, and as PNGs that was several
# gigabytes of scratch before ffmpeg ever ran (this Blender build has no
# video output format at all).
scene.render.image_settings.file_format = "JPEG"
scene.render.image_settings.quality = 92
scene.render.filepath = os.path.join(FRAMES_DIR, "frame_")
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"
world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.93, 0.94, 0.96, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.8

# Lights.
bpy.ops.object.light_add(type="SUN", location=(2, -2, 4))
sun = bpy.context.active_object
sun.data.energy = 1.8
sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(40))
bpy.ops.object.light_add(type="AREA", location=(-2.5, -2.5, 2.5))
fill = bpy.context.active_object
fill.data.energy = 120
fill.data.size = 3

# ---- the models
scan_mat = material("scan", (0.55, 0.62, 0.72, 1), roughness=0.9)
scan_ghost = material("scan-ghost", (0.16, 0.44, 0.86, 1), alpha=0.2, roughness=0.6)
cad_mat = material("cad", RED, roughness=0.45)
scan = import_glb(SCAN, "Scan", scan_mat)
scan_lo, scan_hi = bounds(scan)
centre = (scan_lo + scan_hi) / 2
size = max(scan_hi - scan_lo)
# Stand everything on z = 0 at the origin: move the scan's base there and
# every model by the same amount (they were built in the scan's frame).
shift = Vector((-centre.x, -centre.y, -scan_lo.z))
scan.location += shift
ghost = scan.copy()
ghost.data = scan.data.copy()
ghost.name = "ScanGhost"
ghost.data.materials.clear()
ghost.data.materials.append(scan_ghost)
bpy.context.collection.objects.link(ghost)

stages = []
for stage in summary.get("stages", []):
    ob = import_stl(stage["path"], stage["label"], cad_mat)
    ob.location += shift
    stages.append(ob)
cad = import_stl(summary["exports"]["stl"]["path"], "CAD", cad_mat)
cad.location += shift

heatmap = None
heatmap_path = os.path.join(RUN, "heatmap.ply")
if os.path.exists(heatmap_path):
    heatmap = import_ply(heatmap_path, "Heatmap", material("heat", (1, 1, 1, 1), roughness=0.8, vertex_colors=True))
    heatmap.location += shift

models = [scan, ghost, cad, *stages] + ([heatmap] if heatmap else [])

# Ground disc with a soft shadow catcher look.
bpy.ops.mesh.primitive_circle_add(vertices=96, radius=size * 1.6, fill_type="NGON", location=(0, 0, -0.001))
ground = bpy.context.active_object
ground.data.materials.append(material("ground", (0.90, 0.91, 0.93, 1), roughness=1.0))

# ---- cameras
target = bpy.data.objects.new("Target", None)
bpy.context.collection.objects.link(target)
target.location = (0, 0, (scan_hi.z - scan_lo.z) * 0.5)
orbit = bpy.data.objects.new("Orbit", None)
bpy.context.collection.objects.link(orbit)
orbit.location = target.location
cam_data = bpy.data.cameras.new("Cam")
cam_data.lens = 45
cam = bpy.data.objects.new("Cam", cam_data)
bpy.context.collection.objects.link(cam)
cam.parent = orbit
height = scan_hi.z - scan_lo.z
cam.location = (0, -height * 3.4, height * 0.32)
track = cam.constraints.new("TRACK_TO")
track.target = target
track.track_axis = "TRACK_NEGATIVE_Z"
track.up_axis = "UP_Y"

# A card camera far away, looking at a 16:9 board where the 2D segments live.
BOARD = Vector((0, 40, 0))
card_data = bpy.data.cameras.new("CardCam")
card_data.type = "ORTHO"
card_data.ortho_scale = 16
card_cam = bpy.data.objects.new("CardCam", card_data)
bpy.context.collection.objects.link(card_cam)
card_cam.location = BOARD + Vector((0, -10, 0))
card_cam.rotation_euler = (math.radians(90), 0, 0)
bpy.ops.mesh.primitive_plane_add(size=1, location=BOARD)
board = bpy.context.active_object
board.name = "Board"
board.rotation_euler = (math.radians(90), 0, 0)
board.scale = (16, 9, 1)
board.data.materials.append(flat_material("board", (0.985, 0.985, 0.99, 1)))


def on_board(x, y, z=0.02):
    """Board coordinates: x right (−8…8), y up (−4.5…4.5)."""
    return BOARD + Vector((x, -z, y))


# ---- the segments
segments = TIMING["segments"]
frame = 1
starts = {}
for seg in segments:
    starts[seg["id"]] = frame
    seg["start"] = frame
    seg["frames"] = max(int(round(seg["seconds"] * FPS)), FPS)
    frame += seg["frames"]
scene.frame_start, scene.frame_end = 1, frame - 1

cards = []       # (object, segment id) for things on the board


def card(ob, seg_id):
    cards.append((ob, seg_id))
    return ob


# Title.
card(text_object("Title", TIMING.get("title", "Scan to CAD"), 1.0, INK, on_board(-7.3, 1.7), width=14.4), "title")
card(text_object("Subtitle", TIMING.get("subtitle", ""), 0.48, MUTED, on_board(-7.3, -0.9), width=14.4), "title")
card(text_object("TitleFoot", "OpenShape 3D  ·  Model Context Protocol  ·  Blender", 0.34, MUTED,
                 on_board(-7.3, -3.6)), "title")

# Analysis: the two charts.
analysis_dir = os.path.join(os.path.dirname(RUN.rstrip("/")), "analysis")
if os.path.exists(os.path.join(analysis_dir, "profile.png")):
    p, _ = image_plane("Profile", os.path.join(analysis_dir, "profile.png"), 5.0, on_board(-4.6, -0.5))
    p.rotation_euler = (math.radians(90), 0, 0)
    card(p, "analysis")
    a, _ = image_plane("Azimuth", os.path.join(analysis_dir, "azimuth.png"), 7.6, on_board(3.2, -0.5))
    a.rotation_euler = (math.radians(90), 0, 0)
    card(a, "analysis")
card(text_object("AnalysisTitle", "1 · Read the scan: axis, radial profile, nozzles", 0.55, INK, on_board(-7.3, 3.7)), "analysis")

# MCP calls: lines of the transcript, revealed one by one.
calls = TIMING.get("calls", [])
mcp_title = card(text_object("MCPTitle", "2 · Build it over MCP — the os3d tool, one call at a time", 0.55, INK,
                             on_board(-7.3, 3.7)), "mcp")
call_objects = []
mono = None
for candidate in ("/System/Library/Fonts/Monaco.ttf", "/System/Library/Fonts/Menlo.ttc",
                  "/System/Library/Fonts/Supplemental/Courier New.ttf"):
    if os.path.exists(candidate):
        try:
            mono = bpy.data.fonts.load(candidate)
            break
        except RuntimeError:
            continue
for i, line in enumerate(calls[:14]):
    ob = text_object("Call%d" % i, line, 0.3, INK if not line.startswith("#") else MUTED,
                     on_board(-7.3, 2.9 - i * 0.47))
    if mono is not None:
        ob.data.font = mono
    call_objects.append(ob)
    card(ob, "mcp")

# Build-up labels.
stage_labels = ["Revolve the profile on the scan's axis"] + [
    "Nozzle %d: circle → extrude → union" % i for i in range(1, len(stages))]
build_title = card(text_object("BuildTitle", "3 · The model takes shape", 0.55, INK, on_board(-7.3, 3.7)), None)

# Comparison / heatmap titles live in 3D space as HUD text parented to the camera.
def hud(name, body, y, size=0.42, color=INK):
    """A caption parked in front of the orbit camera (its local −Z), inside
    the frame of a 45 mm lens at 4 m: half-height 0.9, half-width 1.6."""
    ob = text_object(name, body, size, color, (0, 0, 0))
    ob.parent = cam
    ob.rotation_euler = (0, 0, 0)
    ob.location = (-1.45, y, -4.0)
    ob.scale = (0.22, 0.22, 0.22)
    return ob


hud_scan = hud("HudScan", "The scan — %s triangles, a TrueDepth iPhone capture" % "{:,}".format(accuracy["referenceTriangles"]), 0.72)
hud_build = hud("HudBuild", "", 0.72)
hud_compare = hud("HudCompare", "4 · Scan and model, in place — no registration, same axis", 0.72)
hud_heat = hud("HudHeat", "Distance from each scan point to the model  ·  green ≤ %.1f mm · red ≥ %.1f mm" % (
    accuracy["options"]["toleranceMM"], accuracy["options"]["toleranceMM"] * 3), 0.72)
hud_sub = hud("HudSub", "", 0.60, size=0.3, color=(0.3, 0.33, 0.4, 1))
huds = [hud_scan, hud_build, hud_compare, hud_heat, hud_sub]

# Overlays card.
overlay_planes = []
x = -7.4
for view in ("front", "top", "right"):
    path = os.path.join(RUN, "overlays", view + ".jpg")
    if not os.path.exists(path):
        continue
    ob, aspect = image_plane("Overlay-" + view, path, 4.6, on_board(x + 2.3, 0.0))
    ob.rotation_euler = (math.radians(90), 0, 0)
    # Tall pictures: fit the height instead.
    if 4.6 * aspect > 7.2:
        s = 7.2 / aspect
        ob.scale = (s, 7.2, 1)
    card(ob, "overlays")
    overlay_planes.append(ob)
    x += 5.0
card(text_object("OverlayTitle", "5 · The app's accuracy report — scan filled, model outlined",
                 0.5, INK, on_board(-7.3, 3.9)), "overlays")

# Numbers card.
r2m = accuracy["referenceToModel"]
m2r = accuracy["modelToReference"]
tol = accuracy["options"]["toleranceMM"]
per_view = "   ".join("%s %.1f%%" % (o["view"], o["iou"] * 100) for o in accuracy["overlays"])
numbers = [
    ("Silhouette overlap (IoU)", "%.1f%%   (%s)" % (accuracy["overallIoU"] * 100, per_view)),
    ("Scan → model deviation", "mean %.2f mm · 95%% within %.2f mm · max %.2f mm" % (r2m["meanMM"], r2m["p95MM"], r2m["maxMM"])),
    ("Within %.1f mm" % tol, "%.1f%% of %s scan points" % (r2m["withinTolerance"] * 100, "{:,}".format(r2m["samples"]))),
    ("Model → scan deviation", "mean %.2f mm · 95%% within %.2f mm" % (m2r["meanMM"], m2r["p95MM"])),
    ("Size difference (model − scan)", "%+.1f × %+.1f × %+.1f mm" % tuple(accuracy["extentDeltaMM"])),
    ("MCP calls", "%d, %.0f s in the app" % (summary.get("calls", 0), summary.get("secondsInApp", 0))),
]
card(text_object("NumbersTitle", "6 · By the numbers", 0.6, INK, on_board(-7.3, 3.6)), "numbers")
for i, (label, value) in enumerate(numbers):
    card(text_object("NumL%d" % i, label, 0.38, MUTED, on_board(-7.3, 2.4 - i * 0.95)), "numbers")
    card(text_object("NumV%d" % i, value, 0.46, INK, on_board(-7.3, 1.95 - i * 0.95)), "numbers")

# Outro.
card(text_object("Outro1", "OpenShape 3D is open source", 0.9, INK, on_board(-7.3, 1.2)), "outro")
card(text_object("Outro2", "app.openshape3d.com  ·  github.com/laanlabs/openshape3d", 0.5, MUTED, on_board(-7.3, 0.1)), "outro")
card(text_object("Outro3", "Scan: CC-BY laanlabs on Sketchfab  ·  Built with Claude over MCP", 0.36, MUTED,
                 on_board(-7.3, -3.6)), "outro")

# ---- keyframes
all_objects = models + [ground] + [c for c, _ in cards] + huds + [board]
board_segments = {"title", "analysis", "mcp", "overlays", "numbers", "outro"}


def set_camera(seg_id, frame):
    scene.timeline_markers.new(seg_id, frame=frame).camera = card_cam if seg_id in board_segments else cam


for seg in segments:
    sid, f0, n = seg["id"], seg["start"], seg["frames"]
    f1 = f0 + n - 1
    set_camera(sid, f0)
    visible = set(c for c, s in cards if s == sid)
    if sid in board_segments:
        visible.add(board)
    if sid == "scan":
        visible |= {scan, ground, hud_scan}
    elif sid == "build":
        visible |= {ghost, ground, hud_build, hud_sub}
    elif sid == "compare":
        visible |= {ghost, cad, ground, hud_compare, hud_sub}
    elif sid == "heatmap":
        visible |= {heatmap or scan, ground, hud_heat}
    show_only(all_objects, visible, f0)
    if sid == "mcp":
        # Reveal the calls one after another.
        for i, ob in enumerate(call_objects):
            at = f0 + int(n * (0.08 + 0.8 * i / max(len(call_objects), 1)))
            hide(ob, f0, True)
            hide(ob, at, False)
    if sid == "build":
        # Stages appear in turn over the ghosted scan.
        per = n / max(len(stages), 1)
        for i, ob in enumerate(stages):
            at = f0 + int(per * i)
            hide(ob, at, False)
            if i + 1 < len(stages):
                hide(ob, f0 + int(per * (i + 1)), True)
    if sid in ("scan", "build", "compare", "heatmap"):
        turns = {"scan": 1.0, "build": 0.6, "compare": 0.8, "heatmap": 0.9}[sid]
        orbit.rotation_euler = (0, 0, 0)
        orbit.keyframe_insert("rotation_euler", frame=f0)
        orbit.rotation_euler = (0, 0, math.radians(360 * turns))
        orbit.keyframe_insert("rotation_euler", frame=f1)

for ob in all_objects:
    constant_interpolation(ob)
set_interpolation(orbit, "LINEAR")

# The build HUD text cannot be keyframed per character in every Blender;
# use one label per stage instead, shown with its stage.
hud_build.hide_render = True
for i, ob in enumerate(stages):
    label = hud("HudStage%d" % i, stage_labels[i] if i < len(stage_labels) else "", 0.72)
    all_objects.append(label)
    seg = next(s for s in segments if s["id"] == "build")
    per = seg["frames"] / max(len(stages), 1)
    hide(label, 1, True)
    hide(label, seg["start"] + int(per * i), False)
    hide(label, seg["start"] + int(per * (i + 1)) if i + 1 < len(stages) else seg["start"] + seg["frames"], True)
    constant_interpolation(label)

hud_sub.data.body = "scan ghosted in blue · model in red"

os.makedirs(FRAMES_DIR, exist_ok=True)
only = opts.get("only")
if only:
    seg = next(s for s in segments if s["id"] == only)
    scene.frame_start, scene.frame_end = seg["start"], seg["start"] + seg["frames"] - 1
if opts.get("preview"):
    # One frame per segment, for a quick look.
    scene.render.image_settings.file_format = "PNG"
    for seg in segments:
        scene.frame_set(seg["start"] + seg["frames"] // 2)
        scene.render.filepath = os.path.join(FRAMES_DIR, "preview_%s.png" % seg["id"])
        bpy.ops.render.render(write_still=True)
else:
    bpy.ops.render.render(animation=True)
json.dump({"fps": FPS, "segments": segments}, open(os.path.join(FRAMES_DIR, "segments.json"), "w"), indent=1)
print("rendered", scene.frame_end, "frames to", FRAMES_DIR)
