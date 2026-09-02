#!/usr/bin/env python3
"""Rebuild item Industrietechnik "Door Lock 6-8 Zn" (art. 0.0.488.45) in openshape3d.

A real TraceParts door-lock product (classification TP01009002003), rebuilt
from the manufacturer's dimensional drawing on item24.com and checked against
the datasheet weight. It is the first HOLLOW DIE CASTING in the rebuild set,
which is what makes it the complex one: a solid 53x64.5x30 block alone would
weigh ~680 g against a 560 g datasheet for the whole assembly, so the housing
has to be SHELLED to a casting wall — the drawing gives the envelope exactly,
the wall thickness is an engineering assumption stated below and bounded by
the weight.

Read off the drawing (mm):
  Housing (front view):  53 wide x 64.5 tall body, 75 overall (top bump);
           (plan view):  87 overall with the swivel-handle lever, body 30 deep,
                         lever region 20 deep; marks at 35 and 38.
  Lock case (front):     49.3 x 56;  (side): 10 overall, 6.2 flange.
Datasheet: m = 560 g, die-cast zinc housing + die-cast zinc lock case +
cylinder lock + 4 x M6 square nut inserts (steel). Zinc (Zamak) 6.6 g/cm3.

Operations exercised: extrude, SHELL with an open face chosen by kernel face
normal, union (lever, top bump, cylinder boss, catch boss), subtract (cylinder
bore, mounting holes, latch slot) — two bodies, all analytic B-reps.

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


def sketch(name, origin=(0, 0, 0)):
    # Ground-plane orientation: u -> +x, v -> -z, extrude along +y ("depth").
    return X({"op": "sketch.create", "args": {
        "name": name, "origin": list(origin),
        "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]}})["sketchID"]


def rect(u0, v0, u1, v1):
    return {"kind": "rect", "min": [u0, v0], "max": [u1, v1]}


def circle(u, v, r):
    return {"kind": "circle", "center": [u, v], "radius": r}


def extrude(name, entities, seed, distance, origin=(0, 0, 0), **kw):
    sk = sketch(name, origin)
    X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": entities}})
    args = {"sketchID": sk, "seedPoint": list(seed), "distance": distance}
    args.update(kw)
    return X({"op": "feature.extrude", "args": args})


def body(body_id):
    return next(b for b in G("/v1/state")["bodies"] if b["id"] == body_id)


results = {}


def check(label, ok, detail):
    results[label] = ok
    print(f"-- {label}: {detail}  {'OK' if ok else 'FAIL'}")


ZN = 6.6e-3        # g/mm3, die-cast zinc (Zamak 5)
WALL = 3.0         # assumed casting wall, mm (not on the drawing)
NON_ZINC_G = 60    # cylinder lock (brass) + 4 steel M6 inserts + spring/key

# ---- 1. Housing: 53 x 64.5 front outline, 30 deep, then SHELL open at back --
print("1. Housing (extrude 53x64.5x30, shell open at the mounting face):")
h = extrude("Housing Body", [rect(0, 0, 53, 64.5)], (26, 32), 30)
housing = h["producedBodyIDs"][0]
solid_v = body(housing)["volumeMM3"]
check("solid block volume", abs(solid_v - 53 * 64.5 * 30) < 1,
      f"{solid_v:,.0f} mm3 = 53x64.5x30 exactly (would be {solid_v * ZN:.0f} g solid)")

# The mounting face is the back cap: the one planar face whose outward normal
# points -y (the extrude ran +y from y=0). Chosen by kernel geometry, not by
# guessing an index.
faces = G(f"/v1/faces?body={housing}")["faces"]
back = [f for f in faces if f.get("kind") == "planar" and f["normal"][1] < -0.9]
check("back face found by normal", len(back) == 1,
      f"{len(faces)} kernel faces, {len(back)} with normal -y (index {back[0]['index'] if back else '?'})")
sh = X({"op": "feature.shell", "args": {
    "bodyID": housing, "thickness": WALL, "openFaces": [back[0]["index"]]}})
shell_v = body(housing)["volumeMM3"]
# Open-back shell: outer box minus the inner cavity (open on the y=0 side).
want_shell = 53 * 64.5 * 30 - (53 - 2 * WALL) * (64.5 - 2 * WALL) * (30 - WALL)
check("shell volume", abs(shell_v - want_shell) / want_shell < 0.01,
      f"ok={sh['ok']} errs={sh.get('evalErrors')}  {shell_v:,.0f} mm3 vs analytic {want_shell:,.0f}")

# ---- 2. Solid handle parts, unioned AFTER the shell so they stay solid -----
print("\n2. Swivel-handle lever (to 87 overall, 20 deep) + top bump (to 75 tall):")
# Overlap each into the wall it attaches to, so the union meets solid, not a face.
lev = extrude("Lever", [rect(53 - WALL, 20, 87, 45)], (70, 32), 20,
              boolean="union", booleanTargets=[housing])
bump = extrude("Top Bump", [rect(10, 64.5 - WALL, 45, 75)], (27, 70), 30,
               boolean="union", booleanTargets=[housing])
check("lever + bump unioned", lev["ok"] and bump["ok"] and not lev.get("evalErrors")
      and not bump.get("evalErrors"), f"volume now {body(housing)['volumeMM3']:,.0f} mm3")

# ---- 3. Cylinder-lock boss on the front face + its bore ---------------------
print("\n3. Cylinder boss (dia 22, +5 proud of the front) and dia 17 bore:")
# Front wall is y in [30-WALL, 30]; start the boss inside it so it overlaps.
boss = extrude("Cyl Boss", [circle(35, 32, 11)], (35, 32), WALL + 5,
               origin=(0, 30 - WALL, 0), boolean="union", booleanTargets=[housing])
bore = extrude("Cyl Bore", [circle(35, 32, 8.5)], (35, 32), 20,
               origin=(0, 20, 0), boolean="subtract", booleanTargets=[housing])
hv = body(housing)["volumeMM3"]
check("boss + bore", boss["ok"] and bore["ok"] and not boss.get("evalErrors")
      and not bore.get("evalErrors"), f"housing zinc volume {hv:,.0f} mm3 = {hv * ZN:.0f} g")

# ---- 4. Lock case: 49.3 x 56 plate, 6.2 flange, catch boss to 10 -----------
print("\n4. Lock case (49.3 x 56 x 6.2 plate + catch boss to 10, holes, latch slot):")
U0 = 120.0                     # placed beside the housing, not overlapping it
uc = U0 + 49.3 / 2             # 144.65, plate centre line
c = extrude("Case Plate", [rect(U0, 0, U0 + 49.3, 56)], (uc, 28), 6.2)
case = c["producedBodyIDs"][0]
extrude("Catch Boss", [rect(uc - 10, 13, uc + 10, 43)], (uc, 28), 10,
        boolean="union", booleanTargets=[case])
# One seeded extrude PER hole: a seedPoint selects a single profile region,
# so two circles under one seed cut only the seeded one (it cost exactly one
# hole's 206 mm3 the first time through).
for v in (8, 48):
    extrude(f"Mount Hole v{v}", [circle(uc, v, 3.25)], (uc, v), 20,
            symmetric=True, boolean="subtract", booleanTargets=[case])
extrude("Latch Slot", [rect(uc - 7, 24, uc + 7, 32)], (uc, 28), 20,
        symmetric=True, boolean="subtract", booleanTargets=[case])
cv = body(case)["volumeMM3"]
want_case = (49.3 * 56 * 6.2 + 20 * 30 * (10 - 6.2)
             - 2 * math.pi * 3.25 ** 2 * 6.2 - 14 * 8 * 10)
check("case volume", abs(cv - want_case) / want_case < 0.01,
      f"{cv:,.0f} mm3 vs analytic {want_case:,.0f} = {cv * ZN:.0f} g")

# ---- 5. Weight check against the datasheet ----------------------------------
print("\n5. Datasheet weight (m = 560 g for the assembly):")
zinc_g = (hv + cv) * ZN
total_g = zinc_g + NON_ZINC_G
drift = abs(total_g - 560) / 560
check("assembly mass vs 560 g", drift < 0.10,
      f"zinc {zinc_g:.0f} g + {NON_ZINC_G} g non-zinc = {total_g:.0f} g "
      f"({drift * 100:.1f}% off; {WALL} mm wall assumed)")

# ---- health + verdict ---------------------------------------------------------
health = G("/v1/check").get("invalid")
allbrep = body(housing)["brep"] and body(case)["brep"]
print(f"\nhealth invalid subshapes: {health}   both analytic B-reps: {allbrep}")
ok = all(results.values()) and health == 0 and allbrep
print("RESULT:", "ALL PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
