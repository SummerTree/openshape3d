#!/usr/bin/env python3
"""Rebuild Ganter GN 115 lockable latch (zinc die casting, type LCG) in openshape3d.

GANTER-Normteile is a supplier in the TraceParts door-locks classification
(TP01009002003); this is its GN 115 latch rebuilt from the Ganter STANDARD
SHEET (live-katalog.ganternorm.com/pdf/ganter/en/115ab.pdf) and checked
against the catalogue weight of the selected LCG (L-handle, same lock) part:
m = 0.250 kg. Unlike the Zn door lock this is a REVOLVED housing — a
different op family — with the bore carried in the revolve profile itself.

From the standard sheet (mm):
  d  = 32  housing collar dia for LCG/LUG/SCK/SUK/SCT/SUT (28 for SC/SU)
  28       housing body length behind the collar; panel thickness max. 8
  h  = 6   latch-arm joggle; latch arm 19 wide, 45 +/-1 reach
  L-handle (LCG): 100 long, 32 hub width.  (T-handle 76: 24/32; wing 50: 12/14)
Assumptions (not on the sheet, stated not tuned): threaded body dia 22 (the
GN 115 M22 thread, modelled plain), collar 5 thick, cylinder bore dia 17,
L-handle 10 thick with a 14-wide lever, latch arm 3 thick.
Materials: zinc die casting 6.6 g/cm3 (housing, handle); steel 7.85 g/cm3
(latch arm). Not modelled, allowed for: brass lock cylinder (~40 g), steel
nut + washer (~18 g), 2 keys (~16 g) = 74 g.

Run against a live DEBUG app; OS3D_PORT (default 8787; newer machines 8899).
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


def sketch(name, origin=(0, 0, 0), xa=(1, 0, 0), ya=(0, 0, -1)):
    return X({"op": "sketch.create", "args": {
        "name": name, "origin": list(origin), "xAxis": list(xa), "yAxis": list(ya)}})["sketchID"]


def loop(pts):
    return [{"kind": "line", "a": pts[i], "b": pts[(i + 1) % len(pts)]} for i in range(len(pts))]


def body(body_id):
    return next(b for b in G("/v1/state")["bodies"] if b["id"] == body_id)


results = {}


def check(label, ok, detail):
    results[label] = ok
    print(f"-- {label}: {detail}  {'OK' if ok else 'FAIL'}")


ZN, ST = 6.6e-3, 7.85e-3
R_COLLAR, T_COLLAR = 16.0, 5.0     # d = 32
R_BODY, L_BODY = 11.0, 28.0        # thread dia 22, body 28 behind the collar
R_BORE = 8.5                       # cylinder bore dia 17
R_BOSS, T_BOSS = 9.0, 3.0          # front boss the handle sits on
BACK = 5.0                         # solid back wall under the arm stud
ARM_W, ARM_L, ARM_T = 19.0, 45.0, 3.0
HANDLE_L, HUB_R, LEVER_W, HANDLE_T = 100.0, 16.0, 14.0, 10.0

# ---- 1. Housing: ONE revolve, bore carried in the profile -------------------
# Sketch (u, v) = (radius, axial y); revolve about the v axis = world Y.
print("1. Housing (revolve of the section, bore in the profile):")
v_front = -T_BOSS                  # boss face
v_panel = T_COLLAR                 # collar back face = panel front
v_end = T_COLLAR + L_BODY          # 33: back of the body
v_bore = v_end - BACK              # bore stops 5 short of the back
profile = [[R_BORE, v_front], [R_BOSS, v_front], [R_BOSS, 0], [R_COLLAR, 0],
           [R_COLLAR, v_panel], [R_BODY, v_panel], [R_BODY, v_end], [0, v_end],
           [0, v_bore], [R_BORE, v_bore]]
sk = sketch("GN115 Section", xa=(1, 0, 0), ya=(0, 1, 0))
X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": loop(profile)}})
rev = X({"op": "feature.revolve", "args": {
    "sketchID": sk, "seedPoint": [10, 15],
    "axisPoint": [0, 0], "axisDirection": [0, 1], "angleDegrees": 360}})
housing = rev["producedBodyIDs"][0]
hv = body(housing)["volumeMM3"]


def ring(ro, ri, h):
    return math.pi * (ro * ro - ri * ri) * h


want_h = (ring(R_BOSS, R_BORE, T_BOSS) + ring(R_COLLAR, R_BORE, T_COLLAR)
          + ring(R_BODY, R_BORE, v_bore - v_panel) + math.pi * R_BODY ** 2 * BACK)
check("housing volume", abs(hv - want_h) / want_h < 0.005,
      f"{hv:,.0f} mm3 vs analytic {want_h:,.0f} = {hv * ZN:.0f} g zinc")

# ---- 2. L-handle (LCG): hub disc + lever, bored for the cylinder ------------
print("\n2. L-handle LCG (100 long, dia-32 hub, lever, bored):")
plane_h = (0, v_front - HANDLE_T, 0)          # sits on the boss, extrudes +y
skh = sketch("Handle Hub", origin=plane_h)
X({"op": "sketch.addEntities", "args": {"sketchID": skh,
   "entities": [{"kind": "circle", "center": [0, 0], "radius": HUB_R}]}})
hub = X({"op": "feature.extrude", "args": {
    "sketchID": skh, "seedPoint": [0, 0], "distance": HANDLE_T}})
handle = hub["producedBodyIDs"][0]
lever_len = HANDLE_L - HUB_R                  # tip at +84 so overall = 100
skl = sketch("Handle Lever", origin=plane_h)
X({"op": "sketch.addEntities", "args": {"sketchID": skl, "entities": [
    {"kind": "rect", "min": [0, -LEVER_W / 2], "max": [lever_len, LEVER_W / 2]}]}})
X({"op": "feature.extrude", "args": {
    "sketchID": skl, "seedPoint": [40, 0], "distance": HANDLE_T,
    "boolean": "union", "booleanTargets": [handle]}})
skb = sketch("Handle Bore", origin=(0, v_front - HANDLE_T - 1, 0))
X({"op": "sketch.addEntities", "args": {"sketchID": skb,
   "entities": [{"kind": "circle", "center": [0, 0], "radius": R_BORE}]}})
X({"op": "feature.extrude", "args": {
    "sketchID": skb, "seedPoint": [0, 0], "distance": HANDLE_T + 2,
    "boolean": "subtract", "booleanTargets": [handle]}})
lv = body(handle)["volumeMM3"]
want_l = (math.pi * HUB_R ** 2 * HANDLE_T + (lever_len - HUB_R) * LEVER_W * HANDLE_T
          - math.pi * R_BORE ** 2 * HANDLE_T)
check("handle volume", abs(lv - want_l) / want_l < 0.005,
      f"{lv:,.0f} mm3 vs analytic {want_l:,.0f} = {lv * ZN:.0f} g zinc")

# ---- 3. Latch arm (steel): 19 x 45 x 3 on the back stud ---------------------
print("\n3. Latch arm (steel, 19 wide x 45 reach x 3):")
ska = sketch("Latch Arm", origin=(0, v_end, 0))
X({"op": "sketch.addEntities", "args": {"sketchID": ska, "entities": [
    {"kind": "rect", "min": [-HUB_R / 2, -ARM_W / 2], "max": [ARM_L - HUB_R / 2, ARM_W / 2]}]}})
arm = X({"op": "feature.extrude", "args": {
    "sketchID": ska, "seedPoint": [10, 0], "distance": ARM_T}})["producedBodyIDs"][0]
av = body(arm)["volumeMM3"]
want_a = ARM_W * ARM_L * ARM_T
check("arm volume", abs(av - want_a) < 1, f"{av:,.0f} mm3 = 19x45x3 exactly = {av * ST:.0f} g steel")

# ---- 4. Weight vs the catalogue's 0.250 kg for GN 115-LCG ------------------
print("\n4. Catalogue weight (0.250 kg, type LCG):")
NON_MODELLED_G = 74
zinc_g = (hv + lv) * ZN
steel_g = av * ST
total = zinc_g + steel_g + NON_MODELLED_G
drift = abs(total - 250) / 250
check("assembly mass vs 250 g", drift < 0.10,
      f"zinc {zinc_g:.0f} g + steel {steel_g:.0f} g + {NON_MODELLED_G} g not modelled "
      f"= {total:.0f} g ({drift * 100:.1f}% off; handle {HANDLE_T:.0f} mm thick assumed)")

health = G("/v1/check").get("invalid")
allbrep = all(body(b)["brep"] for b in (housing, handle, arm))
print(f"\nhealth invalid subshapes: {health}   all analytic B-reps: {allbrep}")
ok = all(results.values()) and health == 0 and allbrep
print("RESULT:", "ALL PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
