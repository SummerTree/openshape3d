#!/usr/bin/env python3
"""Rebuild the reference tutorial's "Frame" main tubes through POST /v1/exec — a PROBE.

The Frame is the last tutorial model with real history, and the most
demanding: 35 steps, sketches on DERIVED construction planes, two sweeps,
plate extrudes with three mirrors, a shell, and an imported Parasolid part.
The extractor resolves every derived plane to a concrete origin/normal/udir,
which is what makes any of it drivable without implementing the CG-plane ops.

The first act drives the TUBE SKELETON — the stages that exercise sweep
over exec (feature.sweep landed for exactly this):

  Extrusion 01  seat tube   circle r19.05 on a 15°-tilted plane, 217.5 long
  Sweep 01      down tube   circle r15.875 swept along line–arc–line
  Sweep 03      chain stay  circle r12.7 along a five-piece line/arc path
  Mirror 01     the stay pair, mirrored across the bike's x=0 plane

Stages are NON-FATAL on purpose: this is a probe harness, each failure is
auto-captured by the kernel capture layer, and a partial skeleton still
reports what worked. Plane bases: the recipe stores (origin, normal n,
u-dir); the sketch's second axis is v = n × u, so app sketches are created
with xAxis=u, yAxis=v (the app derives its normal as u × v = n). Arc paths
are tessellated into the polyline spine `FeatureKind.sweep` stores — the
analytic-spine pipe is future work, so the bends are faceted.

The PLATE/HEAD stages (added 2026-09-01) decode the recipe's second act:

  Extrusion 03  slab        289.56 x 254.0 rect at z=12.7, 6.35 thick
  Extrusion 04  window plug the 106.68 x 88.9 inner rect of Sketch 11 at
                            z=19.05, extruded -6.35 — the SAME layer as the
                            slab. Sketch 11's other lines are leftover
                            region-splitting geometry; the tutorial's click
                            seeds the window, so we seed there too.
  Mirror 02     left plug   across the bike plane x=0 (same ref as Mirror 01)
  Mirror 03     back pair   across y=82.55 — the recipe's Plane 06 base is
                            unresolved (CG plane from edge+face+angle), but
                            mirroring the plate region [-44.45, 82.55] across
                            y=82.55 lands EXACTLY on [82.55, 209.55], flush
                            with the slab edge: the geometry pins the plane.
  Boolean 01    windows     slab MINUS the four plugs (recipe op int32=2;
                            subtract is the only reading where the windows
                            exist in the result — union of coincident
                            coplanar slabs would erase them). Expected
                            volume asserts this decode: slab - 4 windows.
  Extrusion 05  head tube   circle r31.75 at world (0, 323.85, 76.2) on the
                            x=0 plane, 109.5375 along +x.

Still out of scope, with reasons: Face Offset 01 + Align (no exec op / no
FeatureKind), Shell 01 + Boolean 02 (their operands are Parasolid face/body
refs we cannot decode, and unlike Plane 06 the geometry does not pin which
six faces the shell opens — needs the tutorial's visual intent), Import 01
(Parasolid). Run with OS3D_PORT as usual.
"""

import json, math, os, urllib.error, urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('OS3D_PORT', '8787')}"

def call(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=180))
    except urllib.error.HTTPError as e:
        return json.load(e)

def X(p):
    return call("/v1/exec", p)

def cross(a, b):
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]

def sketch_on(name, origin, normal, udir):
    v = cross(normal, udir)
    return X({"op": "sketch.create", "args": {
        "name": name, "origin": origin, "xAxis": udir, "yAxis": v}})["sketchID"]

def world(origin, udir, v, a, b):
    return [origin[i] + udir[i]*a + v[i]*b for i in range(3)]

def arc_points(c, s, e, n=16):
    r = math.hypot(s[0]-c[0], s[1]-c[1])
    a0 = math.atan2(s[1]-c[1], s[0]-c[0])
    a1 = math.atan2(e[1]-c[1], e[0]-c[0])
    # shorter way round — these paths bend, they don't loop
    if a1 - a0 > math.pi: a1 -= 2*math.pi
    if a0 - a1 > math.pi: a1 += 2*math.pi
    return [[c[0]+r*math.cos(a0+(a1-a0)*i/n), c[1]+r*math.sin(a0+(a1-a0)*i/n)]
            for i in range(n+1)]

results = {}

def stage(label, fn):
    try:
        out = fn()
        ok = out.get("ok") and not out.get("failed")
        vol = out["bodies"][-1]["volumeMM3"] if out.get("bodies") else None
        results[label] = (ok, out.get("evalErrors") or out.get("message"))
        print(f"-- {label}: ok={ok} errs={out.get('evalErrors')}")
        for b in out.get("bodies", []):
            print(f"     {b['name']:<18} {b['volumeMM3']:>14,.1f} mm3  brep={b['brep']}")
        return out if ok else None
    except Exception as err:  # timeouts included — the probe must keep going
        results[label] = (False, str(err))
        print(f"-- {label}: EXCEPTION {err}")
        return None

# ---- 1. Seat tube (Extrusion 01) -----------------------------------------
SEAT_O = [0.0, 78.0488, 291.282]
SEAT_N = [0.0, -0.2588190451025204, -0.9659258262890684]
SEAT_U = [0.0, -0.9659258262890684, 0.25881904510252063]

def seat_tube():
    sk = sketch_on("Seat Tube", SEAT_O, SEAT_N, SEAT_U)
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
        {"kind": "circle", "center": [507.3613, 0.0], "radius": 19.05}]}})
    return X({"op": "feature.extrude", "args": {
        "sketchID": sk, "seedPoint": [507.3613, 0.0], "distance": 217.4875}})

seat = stage("Seat tube (Extrusion 01)", seat_tube)
expect = math.pi * 19.05**2 * 217.4875
if seat:
    print(f"     expected pi*r2*L = {expect:,.1f} mm3")

# ---- 2. Down tube (Sweep 01) ---------------------------------------------
# Path on the x=0 plane: u=(0,1,0), v=(0,0,1) → sketch (a,b) = world (0,a,b).
PATH_U, PATH_V = [0, 1, 0], [0, 0, 1]
def path_world(pts):
    return [world([0, 0, 0], PATH_U, PATH_V, a, b) for a, b in pts]

TUBE_O = [0.0, -489.5644, 155.7268]
TUBE_N = [0.0, -0.9529503286952246, 0.3031264934638074]
TUBE_U = [1.0, 0.0, 0.0]

def down_tube():
    sk = sketch_on("Down Tube Section", TUBE_O, TUBE_N, TUBE_U)
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
        {"kind": "circle", "center": [0.0, 236.45], "radius": 15.875}]}})
    # line → arc → line; the line ends are the arc ends, so splice once.
    spine = [[-413.078, 396.1801], [-66.9243, 286.0711]] \
        + arc_points([139.7, 935.644], [-66.9243, 286.0711], [139.7, 254.0])[1:] \
        + [[342.9, 254.0]]
    return X({"op": "feature.sweep", "args": {
        "sketchID": sk, "seedPoint": [0.0, 236.45],
        "spine": path_world(spine)}})

stage("Down tube (Sweep 01)", down_tube)

# ---- 3. Chain stay (Sweep 03) --------------------------------------------
STAY_O = [-150.5752, -367.8418, 289.2523]
STAY_N = [-0.30631090954837237, -0.7482901441826874, 0.588417782541199]
STAY_U = [0.9519315241610864, -0.24078353206411385, 0.18934007498435462]

STAY_PATH_O = [104.0323, 0.0, 54.1558]
STAY_PATH_N = [0.8870108331782217, 1.5392773481735353e-12, 0.4617486132350339]
STAY_PATH_U = [-1.3653556830957712e-12, 1.0, -7.107591809032304e-13]

def chain_stay():
    sk = sketch_on("Stay Section", STAY_O, STAY_N, STAY_U)
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
        {"kind": "circle", "center": [158.1786, -82.946], "radius": 12.7}]}})
    v = cross(STAY_PATH_N, STAY_PATH_U)
    # The main chain of Sketch 07 (its other lines are the dropout tips):
    # line → arc → line → arc → line, dropout to dropout.
    pts = ([[-457.2, 225.3008], [-203.9795, 0.8166]]
           + arc_points([-47.8637, 176.9169], [-203.9795, 0.8166],
                        [-47.8637, -58.42])[1:]
           + [[195.2707, -58.42]]
           + arc_points([195.2707, 17.78], [195.2707, -58.42],
                        [266.4583, -9.4002])[1:]
           + [[356.0698, 225.3008]])
    spine = [world(STAY_PATH_O, STAY_PATH_U, v, a, b) for a, b in pts]
    return X({"op": "feature.sweep", "args": {
        "sketchID": sk, "seedPoint": [158.1786, -82.946], "spine": spine}})

stay = stage("Chain stay (Sweep 03)", chain_stay)

# ---- 4. Mirror the stay across the bike's symmetry plane -----------------
if stay:
    sid = stay["producedBodyIDs"][0]
    stage("Stay pair (Mirror 01)", lambda: X({
        "op": "feature.mirror", "args": {
            "bodyID": sid, "planeOrigin": [0, 0, 0],
            "planeNormal": [1, 0, 0], "keepOriginal": True}}))

# ---- 5. Plate slab (Extrusion 03) ----------------------------------------
# Sketch 10's rect, recipe-literal mm. Its dangling (0,0)->(0,82.55) line is
# a reference for later steps, not a boundary — omitted.
PX = 144.77999999942084          # rect half-width in x
PY0, PY1 = -44.44999999982222, 209.54999999916177
PYM = 82.54999999966978          # the abutment line Mirror 03 folds over
PLATE_T = 6.35

def slab():
    sk = sketch_on("Plate Slab", [0.0, 0.0, 12.7000000000508], [0, 0, 1], [1, 0, 0])
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
        {"kind": "line", "a": [-PX, PY0], "b": [PX, PY0]},
        {"kind": "line", "a": [PX, PY0], "b": [PX, PY1]},
        {"kind": "line", "a": [PX, PY1], "b": [-PX, PY1]},
        {"kind": "line", "a": [-PX, PY1], "b": [-PX, PY0]}]}})
    return X({"op": "feature.extrude", "args": {
        "sketchID": sk, "seedPoint": [0.0, 100.0], "distance": PLATE_T}})

slab_out = stage("Plate slab (Extrusion 03)", slab)
slab_v = 2 * PX * (PY1 - PY0) * PLATE_T
if slab_out:
    print(f"     expected rect*t = {slab_v:,.1f} mm3")

# ---- 6. Window plug (Extrusion 04) ---------------------------------------
# Sketch 11 drawn in full (recipe-literal), seeded INSIDE the inner rect so
# the detector picks the window region exactly as the tutorial's click did.
WX0, WX1 = 12.699999999949267, 119.37999999952244
WY0, WY1 = -19.04999999992381, 69.84999999972055

def window_plug():
    sk = sketch_on("Plate Window", [0.0, 0.0, 19.0500000000254], [0, 0, 1], [1, 0, 0])
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
        {"kind": "line", "a": [0.0, PY0], "b": [0.0, PYM]},
        {"kind": "line", "a": [-PX, PY0], "b": [PX, PY0]},
        {"kind": "line", "a": [0.0, PYM], "b": [PX, PYM]},
        {"kind": "line", "a": [PX, PY0], "b": [PX, PY1]},
        {"kind": "line", "a": [WX0, WY1], "b": [WX1, WY1]},
        {"kind": "line", "a": [WX1, WY0], "b": [WX1, WY1]},
        {"kind": "line", "a": [WX0, WY0], "b": [WX1, WY0]},
        {"kind": "line", "a": [WX0, WY1], "b": [WX0, WY0]}]}})
    return X({"op": "feature.extrude", "args": {
        "sketchID": sk, "seedPoint": [(WX0 + WX1) / 2, (WY0 + WY1) / 2],
        "distance": -PLATE_T}})

plug_out = stage("Window plug (Extrusion 04)", window_plug)
window_v = (WX1 - WX0) * (WY1 - WY0) * PLATE_T
if plug_out:
    print(f"     expected window*t = {window_v:,.1f} mm3")

# ---- 7-8. Mirrors: left plug, then the back pair -------------------------
plugs = []
if plug_out:
    plugs.append(plug_out["producedBodyIDs"][0])
    m2 = stage("Left plug (Mirror 02)", lambda: X({
        "op": "feature.mirror", "args": {
            "bodyID": plugs[0], "planeOrigin": [0, 0, 0],
            "planeNormal": [1, 0, 0], "keepOriginal": True}}))
    if m2:
        plugs.append(m2["producedBodyIDs"][0])
    for i, pid in enumerate(list(plugs)):
        m3 = stage(f"Back plug {i + 1} (Mirror 03)", lambda pid=pid: X({
            "op": "feature.mirror", "args": {
                "bodyID": pid, "planeOrigin": [0, PYM, 0],
                "planeNormal": [0, 1, 0], "keepOriginal": True}}))
        if m3:
            plugs.append(m3["producedBodyIDs"][0])

# ---- 9. Boolean 01: punch the four windows -------------------------------
if slab_out and len(plugs) == 4:
    def punch():
        return X({"op": "feature.boolean", "args": {
            "kind": "subtract",
            "targetBodyID": slab_out["producedBodyIDs"][0],
            "toolBodyIDs": plugs}})
    punched = stage("Windowed slab (Boolean 01)", punch)
    if punched:
        got = next(b["volumeMM3"] for b in punched["bodies"]
                   if b["id"] == slab_out["producedBodyIDs"][0]) \
            if any(b.get("id") == slab_out["producedBodyIDs"][0]
                   for b in punched["bodies"]) \
            else punched["bodies"][-1]["volumeMM3"]
        want = slab_v - 4 * window_v
        drift = abs(got - want) / want
        print(f"     slab - 4 windows = {want:,.1f} mm3, got {got:,.1f} "
              f"(drift {drift * 100:.2f}%)")
        results["Boolean 01 volume decode"] = (
            drift < 0.001, f"drift {drift * 100:.2f}%")

# ---- 10. Head tube (Extrusion 05) ----------------------------------------
def head_tube():
    sk = sketch_on("Head Tube", [0.0, 0.0, 0.0], [1, 0, 0], [0, 1, 0])
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
        {"kind": "circle", "center": [323.8499999987045, 76.2],
         "radius": 31.749999999873}]}})
    return X({"op": "feature.extrude", "args": {
        "sketchID": sk, "seedPoint": [323.8499999987045, 76.2],
        "distance": 109.53750000043816}})

head = stage("Head tube (Extrusion 05)", head_tube)
if head:
    want = math.pi * 31.75**2 * 109.5375
    got = head["bodies"][-1]["volumeMM3"]
    print(f"     expected pi*r2*L = {want:,.1f} mm3 (mesh under-reads a "
          f"cylinder slightly; got {got:,.1f})")

# ---- naming coverage: the revolve/sweep naming slice, live ---------------
# Every OCCT-owned body minted since 279a311 should answer /v1/faces with a
# name on each referenceable face. Swept tubes exercise the sweep harvest.
def naming_coverage():
    named = unnamed = 0
    for b in call("/v1/state")["bodies"]:
        faces = call(f"/v1/faces?body={b['id']}")
        for f in faces.get("faces", []):
            if not f.get("referenceable", True):
                continue
            if f.get("name"):
                named += 1
            else:
                unnamed += 1
    return named, unnamed

try:
    named, unnamed = naming_coverage()
    print(f"\nNAMING: {named} referenceable faces carry element names, "
          f"{unnamed} do not")
    results["Naming coverage"] = (named > 0, f"{named} named / {unnamed} bare")
except Exception as err:
    results["Naming coverage"] = (False, str(err))

# ---- summary -------------------------------------------------------------
print("\nSTATE:", json.dumps({
    "bodies": [{k: b[k] for k in ("name", "volumeMM3", "brep")}
               for b in call("/v1/state")["bodies"]],
}, indent=1))
h = call("/v1/check")
print("health invalid:", h.get("invalid"))
print("\nSTAGES:")
for label, (ok, note) in results.items():
    print(f"  {'PASS' if ok else 'FAIL':<5} {label}" + ("" if ok else f"  ({str(note)[:120]})"))
