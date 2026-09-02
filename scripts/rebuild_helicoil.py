#!/usr/bin/env python3
"""Rebuild a HELICOIL(R) Plus wire thread insert in openshape3d — a helical sweep.

The hardest catalogue shape so far: a wire of 60-degree DIAMOND section (its
two Vs form the internal and the external thread) swept along a HELIX, plus
the driving tang, a straight bar of the same wire across the bore. TraceParts
product: BENE INOX 219711 "filet rapporte HELICOIL Plus inox A2".

`feature.sweep` takes a `helix` spec (axis, radius, pitch, turns) and sweeps
the profile along the EXACT helix edge — a 2D line on a cylindrical surface,
MakePipeShell in Frenet mode — so by Pappus the coil encloses exactly
section area x true helix length, and that is what is checked (1e-4).
HC_EXACT=0 falls back to the older sampled POLYLINE spine
(SEGMENTS_PER_TURN mitred chords per turn): also exact for what it builds
(area x polyline length) but 1 - sin(pi/S)/(pi/S) short of the true helix.

Parameters default to M6 x 1.0, 1.5D (9 mm) Helicoil Plus geometry; adjust
from the datasheet. Run against a live DEBUG app; OS3D_PORT (default 8787;
newer machines 8899).
"""

import json, math, os, sys, urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('OS3D_PORT', '8787')}"

# ---- Helicoil Plus geometry (mm) --------------------------------------------
NOMINAL_D = float(os.environ.get("HC_D", 6.0))       # M6
PITCH = float(os.environ.get("HC_P", 1.0))           # x 1.0
LENGTH = float(os.environ.get("HC_L", 9.0))          # 1.5 D installed length
# Wire section: a rhombus. Its radial diagonal is the thread depth the wire
# spans (roughly 5/8 H of both threads), its axial diagonal a little under the
# pitch (the flanks must clear the mating thread).
WIRE_RADIAL = float(os.environ.get("HC_WR", 0.95))   # radial diagonal
WIRE_AXIAL = float(os.environ.get("HC_WA", 0.80))    # axial diagonal
# Centroid radius of the wire in the INSTALLED state: the mean of the
# internal thread's pitch-diameter radius and the STI external one.
R_CENTROID = float(os.environ.get("HC_R", (NOMINAL_D - 0.6495 * PITCH) / 2 + WIRE_RADIAL / 4))
TURNS = float(os.environ.get("HC_TURNS", LENGTH / PITCH - 1.0))   # coil turns (tang aside)
SEGMENTS_PER_TURN = int(os.environ.get("HC_S", 36))


def X(p):
    r = urllib.request.urlopen(urllib.request.Request(
        BASE + "/v1/exec", data=json.dumps(p).encode(),
        headers={"Content-Type": "application/json"}), timeout=300)
    return json.load(r)


def G(path):
    return json.load(urllib.request.urlopen(BASE + path, timeout=120))


def body(body_id):
    return next(b for b in G("/v1/state")["bodies"] if b["id"] == body_id)


def unit(v):
    n = math.sqrt(sum(c * c for c in v))
    return [c / n for c in v]


def sub(a, b): return [a[i] - b[i] for i in range(3)]
def dot(a, b): return sum(a[i] * b[i] for i in range(3))
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]


results = {}


def check(label, ok, detail):
    results[label] = ok
    print(f"-- {label}: {detail}  {'OK' if ok else 'FAIL'}")


# ---- 1. The helix spine: EXACT (axis = world Y, right-handed, angle 0 = +X) ----
EXACT = os.environ.get("HC_EXACT", "1") != "0"
helix = {"axisPoint": [0, 0, 0], "axisDirection": [0, 1, 0], "referenceDirection": [1, 0, 0],
         "radius": R_CENTROID, "pitch": PITCH, "turns": TURNS}


def helix_point(theta):   # the same right-handed frame the kernel uses: x = +X, y = n x x = -Z
    return [R_CENTROID * math.cos(theta), PITCH * theta / (2 * math.pi), -R_CENTROID * math.sin(theta)]


n_pts = int(round(TURNS * SEGMENTS_PER_TURN)) + 1
spine = [helix_point(2 * math.pi * TURNS * i / (n_pts - 1)) for i in range(n_pts)]
poly_len = sum(math.dist(spine[i], spine[i + 1]) for i in range(n_pts - 1))
true_len = TURNS * math.sqrt((2 * math.pi * R_CENTROID) ** 2 + PITCH ** 2)
area = WIRE_RADIAL * WIRE_AXIAL / 2
print(f"Helicoil M{NOMINAL_D:g} x {PITCH:g}, {LENGTH:g} mm: {TURNS:.2f} turns, "
      f"R_c {R_CENTROID:.3f}, wire {WIRE_RADIAL} x {WIRE_AXIAL} (A = {area:.4f} mm2)")
print(f"   spine: {'EXACT helix' if EXACT else 'sampled polyline'}; polyline {poly_len:.3f} mm vs "
      f"true helix {true_len:.3f} mm ({(1 - poly_len / true_len) * 100:.3f}% short)")

# ---- 2. Profile plane at the helix start, normal = the EXACT start tangent -----
p0 = [R_CENTROID, 0.0, 0.0]
t = unit([0.0, PITCH / (2 * math.pi), -R_CENTROID])       # d/dθ at θ = 0, right-handed about +Y
radial = [1.0, 0.0, 0.0]
xa = unit(sub(radial, [dot(radial, t) * c for c in t]))   # radial, made perpendicular to t
ya = cross(t, xa)                                         # so xa x ya = t (the sketch normal)
sk = X({"op": "sketch.create", "args": {
    "name": "Wire Section", "origin": p0, "xAxis": xa, "yAxis": ya}})["sketchID"]
hr, ha = WIRE_RADIAL / 2, WIRE_AXIAL / 2
X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
    {"kind": "line", "a": [hr, 0], "b": [0, ha]},
    {"kind": "line", "a": [0, ha], "b": [-hr, 0]},
    {"kind": "line", "a": [-hr, 0], "b": [0, -ha]},
    {"kind": "line", "a": [0, -ha], "b": [hr, 0]}]}})

# ---- 3. The coil: sweep the diamond along the helix ---------------------------
print(f"\n3. Coil (diamond section swept along the {'exact' if EXACT else 'sampled'} helix):")
args = {"sketchID": sk, "seedPoint": [0, 0]}
if EXACT:
    args["helix"] = helix          # the exec samples the render polyline from the same spec
else:
    args["spine"] = spine
res = X({"op": "feature.sweep", "args": args})
print(f"   ok={res.get('ok')} errs={res.get('evalErrors')} warn={res.get('warning')}")
coil = res.get("producedBodyIDs", [None])[0]
if coil is None:
    print("RESULT: FAIL (sweep produced no body)")
    sys.exit(1)
cb = body(coil)
cv = cb["volumeMM3"]
if EXACT:
    want = area * true_len
    check("coil volume = A x TRUE helix length (Pappus)", abs(cv - want) / want < 1e-4,
          f"{cv:.4f} mm3 vs {want:.4f}  brep={cb['brep']}")
else:
    want_poly = area * poly_len
    check("coil volume = A x polyline length", abs(cv - want_poly) / want_poly < 0.002,
          f"{cv:.4f} mm3 vs {want_poly:.4f} (mitred sweep is exact)  brep={cb['brep']}  "
          f"| true helix would be {area * true_len:.4f}")

# ---- 4. The tang: the same wire straight across the bore at the start ---------
print("\n4. Tang (straight bar of the wire across the bore):")
tang_spine = [[R_CENTROID, -WIRE_AXIAL, 0.0], [-R_CENTROID, -WIRE_AXIAL, 0.0]]
tt = unit(sub(tang_spine[1], tang_spine[0]))              # (-1, 0, 0)
txa = [0.0, 1.0, 0.0]                                     # axial, perpendicular to tt
tya = cross(tt, txa)
skt = X({"op": "sketch.create", "args": {
    "name": "Tang Section", "origin": tang_spine[0], "xAxis": txa, "yAxis": tya}})["sketchID"]
X({"op": "sketch.addEntities", "args": {"sketchID": skt, "entities": [
    {"kind": "line", "a": [ha, 0], "b": [0, hr]},
    {"kind": "line", "a": [0, hr], "b": [-ha, 0]},
    {"kind": "line", "a": [-ha, 0], "b": [0, -hr]},
    {"kind": "line", "a": [0, -hr], "b": [ha, 0]}]}})
rt = X({"op": "feature.sweep", "args": {"sketchID": skt, "seedPoint": [0, 0], "spine": tang_spine}})
tang = rt.get("producedBodyIDs", [None])[0]
if tang:
    tv = body(tang)["volumeMM3"]
    check("tang volume = A x 2R", abs(tv - area * 2 * R_CENTROID) / (area * 2 * R_CENTROID) < 0.002,
          f"{tv:.4f} mm3 vs {area * 2 * R_CENTROID:.4f}  brep={body(tang)['brep']}")
else:
    check("tang built", False, f"errs={rt.get('evalErrors')}")

# ---- 5. Mass, health ----------------------------------------------------------
total = cv + (body(tang)["volumeMM3"] if tang else 0)
print(f"\n5. Stainless A2 (7.9 g/cm3): {total:.3f} mm3 = {total * 7.9e-3 * 1000:.1f} mg")
health = G("/v1/check").get("invalid")
allbrep = cb["brep"] and (body(tang)["brep"] if tang else True)
print(f"health invalid subshapes: {health}   all analytic B-reps: {allbrep}")
ok = all(results.values()) and health == 0 and allbrep
print("RESULT:", "ALL PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
