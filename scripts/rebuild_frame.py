#!/usr/bin/env python3
"""Rebuild the Shapr3D "Frame" main tubes through POST /v1/exec — a PROBE.

The Frame is the last tutorial model with real history, and the most
demanding: 35 steps, sketches on DERIVED construction planes, two sweeps,
plate extrudes with three mirrors, a shell, and an imported Parasolid part.
The extractor resolves every derived plane to a concrete origin/normal/udir,
which is what makes any of it drivable without implementing the CG-plane ops.

This script drives the TUBE SKELETON — the stages that exercise sweep over
exec (feature.sweep landed for exactly this):

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

Out of scope, with reasons: the plate/head stages (three mirrors deep — next
iteration), OffsetFace and Align (no exec op / no FeatureKind), Import 01
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
