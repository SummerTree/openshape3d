#!/usr/bin/env python3
"""Rebuild real catalogue CAD parts in openshape3d, verified against ground truth.

Three parts from (or matching) the TraceParts catalogue, chosen to cover the
core modelling operations and to each carry an INDEPENDENT check — a datasheet
weight or an exact analytic volume — that the geometry must reproduce:

  1. RÄDER-VOGEL 106/100/036/125/046/5/20 — grey cast-iron single-flanged
     wheel (a real TraceParts product). One REVOLVE of its radial section.
     Check: the datasheet's 2.5 kg weight.
  2. DIN 934 M16 hexagon nut (a TraceParts fastener class). HEXAGON extrude
     minus a bore. Check: exact hex geometry + analytic volume.
  3. EN 1092-1 DN50 PN16 bolt-circle flange. Extrude + central bore +
     CIRCULAR PATTERN of a bolt hole + boolean. Check: exact 4-hole volume
     (a wrong hole count is a 1.5%-per-hole volume error; the pattern is the
     point of this one).

Between them they exercise revolve, polygon extrude, circle extrude, boolean
cut, and circular pattern. Each is read back by body-id and held to <1%
volume drift, a valid B-rep, and 0 invalid subshapes.

Run against a live DEBUG app; OS3D_PORT (default 8787; newer machines 8899).
The three parts are built into one document (there is no reset op) and
verified individually — the render overlaps them, the numbers do not.
"""

import json, math, os, sys, urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('OS3D_PORT', '8787')}"


def X(p):
    r = urllib.request.urlopen(urllib.request.Request(
        BASE + "/v1/exec", data=json.dumps(p).encode(),
        headers={"Content-Type": "application/json"}), timeout=120)
    return json.load(r)


def G(path):
    return json.load(urllib.request.urlopen(BASE + path, timeout=120))


def sketch(name, xa=(1, 0, 0), ya=(0, 0, -1)):
    return X({"op": "sketch.create", "args": {
        "name": name, "origin": [0, 0, 0], "xAxis": list(xa), "yAxis": list(ya)}})["sketchID"]


def loop(pts):
    return [{"kind": "line", "a": pts[i], "b": pts[(i + 1) % len(pts)]}
            for i in range(len(pts))]


def vol(body):
    return next(b["volumeMM3"] for b in G("/v1/state")["bodies"] if b["id"] == body)


def brep(body):
    return next(b["brep"] for b in G("/v1/state")["bodies"] if b["id"] == body)


results = {}


def check(label, got, want, extra="", tol=0.01):
    drift = abs(got - want) / want
    ok = drift < tol
    results[label] = ok
    print(f"-- {label}: {got:,.0f} mm3  (want {want:,.0f}, drift {drift * 100:.2f}%)  "
          f"{extra}  {'OK' if ok else 'FAIL'}")


def ring(ro, ri, h):
    return math.pi * (ro * ro - ri * ri) * h


# ---- 1. RÄDER-VOGEL cast-iron single-flanged wheel (REVOLVE) -------------
print("1. RÄDER-VOGEL wheel (revolve, weight-verified):")
skw = sketch("Wheel Section", ya=(0, 1, 0))
X({"op": "sketch.addEntities", "args": {"sketchID": skw, "entities": loop(
    [[21, 0], [62.5, 0], [62.5, 10], [50, 10], [50, 46], [30, 46], [30, 54], [21, 54]])}})
rev = X({"op": "feature.revolve", "args": {
    "sketchID": skw, "seedPoint": [35, 25],
    "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360}})
wheel = rev["producedBodyIDs"][0]
wv = vol(wheel)
analytic = ring(62.5, 21, 10) + ring(50, 21, 36) + ring(30, 21, 8)
mass = wv * 7.15e-3 / 1000
check("wheel volume", wv, analytic,
      extra=f"mass {mass:.3f} kg vs 2.5 kg ({abs(mass - 2.5) / 2.5 * 100:.1f}%)")
results["wheel mass"] = abs(mass - 2.5) / 2.5 < 0.03

# ---- 2. DIN 934 M16 hex nut (HEXAGON extrude + bore) ---------------------
print("\n2. DIN 934 M16 hex nut (hexagon extrude + bore):")
R = 24.0 / math.sqrt(3)  # circumradius for across-flats 24
skn = sketch("Nut Hex")
X({"op": "sketch.addEntities", "args": {"sketchID": skn, "entities": [
    {"kind": "polygon", "center": [0, 0], "radius": R, "sides": 6}]}})
nut = X({"op": "feature.extrude", "args": {
    "sketchID": skn, "seedPoint": [0, 0], "distance": 13}})["producedBodyIDs"][0]
skb = sketch("Nut Bore")
X({"op": "sketch.addEntities", "args": {"sketchID": skb,
   "entities": [{"kind": "circle", "center": [0, 0], "radius": 7.35}]}})
X({"op": "feature.extrude", "args": {
    "sketchID": skb, "seedPoint": [0, 0], "distance": 20, "symmetric": True,
    "boolean": "subtract", "booleanTargets": [nut]}})
nv = vol(nut)
hexarea = (3 * math.sqrt(3) / 2) * R * R
check("hex nut volume", nv, hexarea * 13 - math.pi * 7.35 ** 2 * 13,
      extra=f"mass {nv * 7.85e-3:.1f} g vs ~31 g (chamfer/thread omitted)")

# ---- 3. EN 1092-1 DN50 PN16 flange (CIRCULAR PATTERN) --------------------
print("\n3. DN50 PN16 flange (extrude + bore + circular pattern):")
skf = sketch("Flange Disk")
X({"op": "sketch.addEntities", "args": {"sketchID": skf,
   "entities": [{"kind": "circle", "center": [0, 0], "radius": 82.5}]}})
flange = X({"op": "feature.extrude", "args": {
    "sketchID": skf, "seedPoint": [0, 0], "distance": 18}})["producedBodyIDs"][0]
skfb = sketch("Flange Bore")
X({"op": "sketch.addEntities", "args": {"sketchID": skfb,
   "entities": [{"kind": "circle", "center": [0, 0], "radius": 30}]}})
X({"op": "feature.extrude", "args": {
    "sketchID": skfb, "seedPoint": [0, 0], "distance": 30, "symmetric": True,
    "boolean": "subtract", "booleanTargets": [flange]}})
skc = sketch("Bolt Hole")
X({"op": "sketch.addEntities", "args": {"sketchID": skc,
   "entities": [{"kind": "circle", "center": [62.5, 0], "radius": 9}]}})
cutter = X({"op": "feature.extrude", "args": {
    "sketchID": skc, "seedPoint": [62.5, 0], "distance": 30, "symmetric": True}})["producedBodyIDs"][0]
pat = X({"op": "feature.pattern", "args": {
    "bodyID": cutter, "kind": "circular", "count": 4,
    "axis": [0, 1, 0], "center": [0, 0, 0], "totalAngleDegrees": 360}})
print(f"   pattern produced {len(pat.get('producedBodyIDs', []))} copies (+ original = 4)")
X({"op": "feature.boolean", "args": {
    "kind": "subtract", "targetBodyID": flange,
    "toolBodyIDs": [cutter] + pat.get("producedBodyIDs", [])}})
fv = vol(flange)
check("flange volume (4 holes)", fv,
      math.pi * (82.5 ** 2 - 30 ** 2) * 18 - 4 * math.pi * 9 ** 2 * 18,
      extra=f"mass {fv * 7.85e-3 / 1000:.2f} kg")

# ---- health + verdict ----------------------------------------------------
health = G("/v1/check").get("invalid")
allbrep = brep(wheel) and brep(nut) and brep(flange)
print(f"\nhealth invalid subshapes: {health}   all analytic B-reps: {allbrep}")
ok = all(results.values()) and health == 0 and allbrep
print("RESULT:", "ALL PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
