#!/usr/bin/env python3
"""A stand-in for a real 3D scan: a fire hydrant generated in Blender with
scan-like noise, saved as GLB (metres, Y up — what a phone scanner app and
Sketchfab's glTF export both produce).

    /Applications/Blender.app/Contents/MacOS/Blender -b --python synthetic_hydrant.py -- out.glb [--seed 1]

The pipeline (`analyze_scan.py` → `build_hydrant.py` → `make_video.py` →
`report.py`) is exercised on this file whenever the real scan is not at
hand; nothing downstream knows the difference. The shape follows the
classic American dry-barrel hydrant: a flanged base, a barrel, a bonnet with
a pentagon operating nut on top, two side hose nozzles with caps and a
larger pumper nozzle at the front.
"""
import math
import random
import sys

import bpy
import bmesh
from mathutils import Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "synthetic_hydrant.glb"
SEED = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1

# Half cross-section of the body of revolution: (height mm, radius mm),
# bottom to top. Built with Blender's Z up; the glTF exporter turns that
# into the file's Y up, as a phone scanner app writes it.
PROFILE = [
    (0, 165), (28, 165), (28, 118), (60, 118), (60, 104),           # base flange, lower barrel step
    (330, 104),                                                      # barrel
    (330, 118), (352, 118), (352, 108),                              # upper flange ring
    (470, 108),                                                      # upper barrel
    (470, 128), (486, 128),                                          # bonnet flange
    (486, 120), (540, 112), (590, 92), (630, 64), (650, 42),         # bonnet dome
    (650, 0),
]
NOZZLES = [  # (azimuth degrees, centre height mm, radius mm, length from the axis mm, cap radius)
    (90, 240, 46, 175, 54),    # side hose nozzle
    (-90, 240, 46, 175, 54),   # side hose nozzle, opposite
    (0, 250, 62, 190, 72),     # pumper nozzle, front
]
NUT = (26, 650, 60)  # pentagon circumradius mm, base height, height
MM = 0.001


def revolve_profile(name, profile, segments=96):
    bm = bmesh.new()
    rings = []
    for h, r in profile:
        if r > 0:
            ring = []
            for i in range(segments):
                a = 2 * math.pi * i / segments
                ring.append(bm.verts.new((r * math.sin(a) * MM, r * math.cos(a) * MM, h * MM)))
        else:
            # A point on the axis: one apex vertex, the ring below fans to it.
            apex = bm.verts.new((0, 0, h * MM))
            ring = [apex] * segments
        rings.append(ring)
    bm.verts.ensure_lookup_table()
    for k in range(len(rings) - 1):
        a, b = rings[k], rings[k + 1]
        for i in range(segments):
            j = (i + 1) % segments
            quad = []
            for v in (a[i], a[j], b[j], b[i]):
                if v not in quad:
                    quad.append(v)
            if len(quad) >= 3:
                try:
                    bm.faces.new(quad)
                except ValueError:
                    pass
    # Cap the bottom.
    bottom = [v for v in rings[0] if v is not None]
    if len(bottom) >= 3:
        try:
            bm.faces.new(list(reversed(bottom)))
        except ValueError:
            pass
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def cylinder(name, radius, depth, location, rotation, vertices=48):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius * MM, depth=depth * MM,
                                        location=location, rotation=rotation)
    ob = bpy.context.active_object
    ob.name = name
    return ob


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    random.seed(SEED)
    body = revolve_profile("hydrant", PROFILE)
    parts = [body]
    for azimuth, h, r, length, cap in NOZZLES:
        a = math.radians(azimuth)
        direction = Vector((math.sin(a), math.cos(a), 0))
        base = Vector((0, 0, h * MM))
        # Nozzle barrel from the axis out; cap at the end.
        centre = base + direction * ((length / 2) * MM)
        rot = direction.to_track_quat("Z", "X").to_euler()
        parts.append(cylinder("nozzle", r, length, centre, rot))
        cap_centre = base + direction * ((length + 12) * MM)
        parts.append(cylinder("cap", cap, 24, cap_centre, rot))
    # Pentagon operating nut on top.
    bpy.ops.mesh.primitive_cylinder_add(vertices=5, radius=NUT[0] * MM, depth=NUT[2] * MM,
                                        location=(0, 0, (NUT[1] + NUT[2] / 2) * MM),
                                        rotation=(0, 0, math.radians(18)))
    parts.append(bpy.context.active_object)

    # Join, then union everything into one surface.
    bpy.ops.object.select_all(action="DESELECT")
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()
    ob = bpy.context.active_object
    ob.name = "FireHydrantScan"
    # Consistent outward normals: the voxel remesh unions closed shells by
    # their signed distance, and an inside-out barrel leaves the nozzles'
    # inner ends standing inside it.
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    mod = ob.modifiers.new("remesh", "REMESH")
    mod.mode = "VOXEL"
    mod.voxel_size = 0.004
    mod.use_remove_disconnected = True
    bpy.ops.object.modifier_apply(modifier="remesh")
    # Scan-like noise on every vertex (≈ ±1 mm), plus a jittered sample of
    # the ground the scanner caught under the base.
    me = ob.data
    for v in me.vertices:
        v.co += Vector((random.gauss(0, 0.0007), random.gauss(0, 0.0007), random.gauss(0, 0.0007)))
    # Remove the bottom cap, as a scan from standing height never sees it.
    bm = bmesh.new()
    bm.from_mesh(me)
    low = [f for f in bm.faces if all(v.co.z < 0.004 for v in f.verts)]
    bmesh.ops.delete(bm, geom=low, context="FACES")
    bm.to_mesh(me)
    bm.free()
    # Scan placement: tilted a few degrees and offset, as a scanner's world
    # frame never lines up with the object.
    ob.rotation_euler = (math.radians(2.0), math.radians(-1.5), math.radians(37.0))
    ob.location = (0.21, 0.44, -0.03)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True)
    print("wrote", OUT, "vertices", len(me.vertices), "faces", len(me.polygons))


main()
