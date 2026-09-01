#!/usr/bin/env python3
"""Rebuild the FreeCAD "Basic modeling tutorial" iron angle through /v1/exec.

https://wiki.freecad.org/Basic_modeling_tutorial — the beginner tutorial
models an iron angle (an L-section table foot, 750 mm tall) TWO ways, and
both must produce the identical solid. That coincidence is the regression:
this script drives both through openshape3d's exec surface and asserts they
agree with each other AND with the analytic volume.

  Method 1 (CSG):  box 50×50×750  minus  box 40×40×750 at the shared corner.
  Method 2 (extrude): the L-profile the tutorial's relative-coordinate Draft
                      wire traces, extruded 750.

  L cross-section area = 50×50 − 40×40 = 900 mm²   (equivalently the L polygon)
  volume               = 900 × 750 = 675,000 mm³   (both methods)

openshape3d has no box PRIMITIVE over exec and no "rect" sketch entity, so
each rectangle is four lines and the profile is closed line loops — exactly
what the ProfileDetector consumes. Run against a live DEBUG app; port from
OS3D_PORT (default 8787; this repo's newer machines use 8899, see NEXT.md).
"""

import json, os, sys, urllib.error, urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('OS3D_PORT', '8787')}"
EXPECTED = 675_000.0


def call(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        return json.load(e)


def X(p):
    return call("/v1/exec", p)


def loop(pts):
    """Closed line loop through pts (list of [x, y])."""
    return [{"kind": "line", "a": pts[i], "b": pts[(i + 1) % len(pts)]}
            for i in range(len(pts))]


def sketch_ground(name):
    # The tutorial drafts on XY; openshape3d's ground plane is the modelling
    # floor. Absolute placement is irrelevant to the volume cross-check.
    return X({"op": "sketch.create", "args": {
        "name": name, "origin": [0, 0, 0],
        "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]}})["sketchID"]


def extrude(name, pts, seed, dist=750.0):
    sk = sketch_ground(name)
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": loop(pts)}})
    r = X({"op": "feature.extrude", "args": {
        "sketchID": sk, "seedPoint": seed, "distance": dist}})
    return r


def vol(body_id):
    for b in call("/v1/state")["bodies"]:
        if b["id"] == body_id:
            return b["volumeMM3"]
    return None


results = {}


def check(label, got, want, tol=1e-3):
    drift = abs(got - want) / want if want else abs(got)
    ok = drift < tol
    results[label] = ok
    print(f"-- {label}: {got:,.1f} mm3  (want {want:,.1f}, "
          f"drift {drift * 100:.3f}%)  {'OK' if ok else 'FAIL'}")
    return ok


# ---- Method 1: CSG (two boxes, cut) --------------------------------------
print("Method 1 — CSG (box 50 − box 40):")
a = extrude("Angle A (50)", [[0, 0], [50, 0], [50, 50], [0, 50]], [25, 25])
big = a["producedBodyIDs"][0]
check("box 50×50×750", vol(big), 50 * 50 * 750)

b = extrude("Angle B (40)", [[0, 0], [40, 0], [40, 40], [0, 40]], [20, 20])
small = b["producedBodyIDs"][0]
check("box 40×40×750", vol(small), 40 * 40 * 750)

cut = X({"op": "feature.boolean", "args": {
    "kind": "subtract", "targetBodyID": big, "toolBodyIDs": [small]}})
print("   cut ok:", cut["ok"], "errs:", cut.get("evalErrors"))
csg_vol = cut["bodies"][0]["volumeMM3"]
check("Method 1 angle", csg_vol, EXPECTED)

# ---- Method 2: extrude the L-profile -------------------------------------
# The tutorial's relative Draft wire, resolved to absolute (x, y):
#   (0,0) → +50x → (50,0) → +10y → (50,10) → −40x → (10,10)
#         → +40y → (10,50) → −10x → (0,50) → close.
print("\nMethod 2 — extrude the L-profile:")
L = [[0, 0], [50, 0], [50, 10], [10, 10], [10, 50], [0, 50]]
m2 = extrude("Angle L-profile", L, [5, 5])
print("   extrude ok:", m2["ok"], "errs:", m2.get("evalErrors"))
l_vol = m2["bodies"][-1]["volumeMM3"]
check("Method 2 angle", l_vol, EXPECTED)

# ---- The cross-check the tutorial is really about ------------------------
print("\nCross-check — the two methods must agree:")
check("Method 1 == Method 2", csg_vol, l_vol)

# ---- Geometry health -----------------------------------------------------
h = call("/v1/check")
print("\nhealth invalid subshapes:", h.get("invalid"))

print("\nRESULT:", "ALL PASS" if all(results.values()) and h.get("invalid", 1) == 0
      else "FAIL")
sys.exit(0 if all(results.values()) else 1)
