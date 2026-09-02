#!/usr/bin/env python3
"""Rebuild the E2 Systems BEG 55 electro-hydraulic tapping unit lineup in openshape3d.

TraceParts product 90-29052019-034131 is not one machine but EIGHT: the series
laid out 200 mm apart along -X — {small Ø150-octagon motor, big Ø178} x
{drive train behind the body, drive train mirrored to the front (about the
plane z = 42)} x {plain Ø52 spindle nose, Ø64 collet chuck}. Nine parts per
unit: body (belt housing), hydraulic feed housing, mounting bracket, spindle
quill, motor, motor plate, top (switch) box, belt-cover ring, feed valve.

Every profile below was measured from the reference tessellation: plane cuts
through the viewer's mesh, chained into loops and simplified to 0.4 mm. World
axes as the reference: X = lineup, Y = up, Z = spindle axis (front = -Z).

The base parts are built once at x = 0 and patterned x8; each drive-train
variant is built once and patterned x2 (its twin sits 400 mm further along).
Prints a part-by-part comparison (volume, envelope) against the reference
capture and writes it as JSON for the report. Live DEBUG app; OS3D_PORT.
"""

import json, math, os, sys, urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('OS3D_PORT', '8899')}"
CAPTURE = os.environ.get("BEG55_CAPTURE", "")     # beg55_capture.json (reference units table)
OUT = os.environ.get("BEG55_OUT", "")             # where to write the comparison JSON


def X(p):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            BASE + "/v1/exec", data=json.dumps(p).encode(),
            headers={"Content-Type": "application/json"}), timeout=600)
    except urllib.error.HTTPError as e:
        print(f"   !! HTTP {e.code} on {p['op']}: {e.read()[:300].decode(errors='replace')}")
        raise
    res = json.load(r)
    if not res.get("ok") or res.get("evalErrors"):
        print(f"   !! {p['op']} {p['args'].get('name', '')}: ok={res.get('ok')} err={res.get('error')} evalErrors={res.get('evalErrors')}")
    return res


def G(path):
    return json.load(urllib.request.urlopen(BASE + path, timeout=300))


# ---- sketch / feature helpers ----------------------------------------------
def sketch(name, origin, xAxis, yAxis, ents):
    print(f"   -> {name}", flush=True)
    s = X({"op": "sketch.create", "args": {"name": name, "origin": origin, "xAxis": xAxis, "yAxis": yAxis}})["sketchID"]
    X({"op": "sketch.addEntities", "args": {"sketchID": s, "entities": ents}})
    return s


def XY(z, cx=0.0):   # plane z = const, normal +Z; local (u, v) = (x - cx, y)
    return ([cx, 0.0, z], [1, 0, 0], [0, 1, 0])


def XZ(y, cx=0.0):   # plane y = const, normal +Y; local (u, v) = (z, x - cx)
    return ([cx, y, 0.0], [0, 0, 1], [1, 0, 0])


def YZ(x):           # plane x = const, normal +X; local (u, v) = (y, z)
    return ([x, 0.0, 0.0], [0, 1, 0], [0, 0, 1])


def poly(pts):
    return [{"kind": "line", "a": list(pts[i]), "b": list(pts[(i + 1) % len(pts)])} for i in range(len(pts))]


def rect(x0, y0, x1, y1):
    return {"kind": "rect", "min": [min(x0, x1), min(y0, y1)], "max": [max(x0, x1), max(y0, y1)]}


def circle(cx, cy, r):
    return {"kind": "circle", "center": [cx, cy], "radius": r}


def extrude(name, plane, ents, seed, dist, boolean=None, target=None, taper=0.0):
    s = sketch(name, *plane, ents)
    args = {"sketchID": s, "seedPoint": list(seed), "distance": dist}
    if taper:
        args["taperDegrees"] = taper      # a DRAFT extrude: positive contracts the walls
    if boolean:
        args["boolean"], args["booleanTargets"] = boolean, [target]
    r = X({"op": "feature.extrude", "args": args})
    return r.get("producedBodyIDs", [target])[0] if not boolean else target


def revolve(name, plane, ents, seed, axisPoint, boolean=None, target=None):
    s = sketch(name, *plane, ents)
    args = {"sketchID": s, "seedPoint": list(seed), "axisPoint": list(axisPoint), "axisDirection": [0, 1], "angleDegrees": 360}
    if boolean:
        args["boolean"], args["booleanTargets"] = boolean, [target]
    r = X({"op": "feature.revolve", "args": args})
    return r.get("producedBodyIDs", [target])[0] if not boolean else target


def loft(name, planeA, entsA, seedA, planeB, entsB, seedB, boolean=None, target=None):
    a = sketch(name + " A", *planeA, entsA)
    b = sketch(name + " B", *planeB, entsB)
    args = {"sections": [{"sketchID": a, "seedPoint": list(seedA)}, {"sketchID": b, "seedPoint": list(seedB)}]}
    if boolean:
        args["boolean"], args["booleanTargets"] = boolean, [target]
    r = X({"op": "feature.loft", "args": args})
    return r.get("producedBodyIDs", [target])[0] if not boolean else target


def mirror_z(body, cx, z0=42.0):
    r = X({"op": "feature.mirror", "args": {"bodyID": body, "planeOrigin": [cx, 0, z0], "planeNormal": [0, 0, 1], "keepOriginal": False}})
    return r.get("producedBodyIDs", [body])[0]


def pattern_x(body, count, spacing):
    r = X({"op": "feature.pattern", "args": {"bodyID": body, "kind": "linear", "count": count, "axis": [-1, 0, 0], "spacing": spacing}})
    return r.get("producedBodyIDs", [])


def scaled(pts, sx, sy, cx=0.0, cy=0.0):
    return [(cx + (x - cx) * sx, cy + (y - cy) * sy) for x, y in pts]


def shifted(pts, dx=0.0, dy=0.0):
    return [(x + dx, y + dy) for x, y in pts]


CY = 165.7   # motor / belt axis height

# ---- measured profiles (unit at x = 0) --------------------------------------
BODY_XZ = [(-39.2, -51), (-121, -51), (-121, 51), (-112.2, 51), (-109.6, 51.7), (-103.5, 58.9), (-98.6, 63.3), (-90.3, 67.6), (-81.1, 69.1), (0, 69.1), (10.1, 70), (84, 70), (84, -70), (12.7, -69.7), (9.8, -68.6), (6.4, -65.2), (5.3, -62.3), (4.8, -54.5), (3.5, -52.4), (1.6, -51.3)]   # (z, x) at y = 0
COLUMN_XY = [(-70, -47), (-56, -47), (-53.7, -47.6), (-30, -71), (25.9, -71), (29.1, -70.4), (32.9, -68.1), (53.6, -47.7), (56.1, -47), (62.2, -46.8), (64.3, -46), (67.1, -44.1), (69.5, -40.2), (70, -37), (70, 209.4), (63.7, 218.1), (52.8, 229), (40, 237.8), (25.8, 244), (10.7, 247.4), (0, 248.2), (-10.7, 247.4), (-25.8, 244), (-40, 237.8), (-52.8, 229), (-63.7, 218.1), (-70, 209.4)]   # (x, y) at z = 40
FEED_XY = [(-15.7, 73), (-15.7, 74.8), (-24.7, 76.5), (-38, 76.5), (-38, -45.5), (-32.5, -45.5), (-32.5, -52.5), (-38, -52.5), (-38, -72), (38, -72), (38, -52.5), (32.5, -52.5), (32.5, -45.5), (38, -45.5), (38, 76.5), (26.3, 76.5), (26.3, 73)]
FEED_HOLES = [(21, -61), (-21, -61), (24, 64), (-24, 64)]   # Ø11 tie-rod holes
BRACKET_XY = [(61.6, -45.2), (58.8, -44), (55.5, -44.7), (31.3, -68.7), (27.8, -70.7), (-62, -71), (-64.1, -70.7), (-67.7, -68.7), (-69.7, -65.1), (-70, -63), (-70, 68), (-69.7, 70.1), (-67.7, 73.7), (-64.1, 75.7), (-62, 76), (62, 76), (64.1, 75.7), (67.7, 73.7), (69.7, 70.1), (70, 68), (70, -41.5), (69.4, -43.8), (66.8, -46.2), (64.4, -46.5)]
PLATE_XY = [(53.6, 86.5), (35.9, 83.3), (18, 81.3), (0, 80.7), (-18, 81.3), (-35.9, 83.3), (-54.3, 86.7), (-60, 90.8), (-69.3, 99.5), (-70, 102), (-70, 229.4), (-68.6, 232.9), (-55.4, 244.1), (-53.6, 244.9), (-35.9, 248.1), (-18, 250.1), (0, 250.7), (18, 250.1), (35.9, 248.1), (54.3, 244.7), (60, 240.6), (69.3, 231.9), (70, 229.4), (70, 102), (69.3, 99.5), (64.4, 94.5), (55.4, 87.3)]
VALVE_HEX = [(-21.4, 138.5), (0, 132.2), (21.4, 138.5), (23.6, 139.8), (25, 143.3), (25, 174.1), (23.6, 177.6), (21.4, 178.9), (0, 185.2), (-21.4, 178.9), (-23.6, 177.6), (-25, 174.1), (-25, 143.3), (-24.3, 140.8)]
QUILL_PLAIN = [(0, -161.8), (30, -161.8), (30, -181.8), (26, -181.8), (26, -324.8), (8, -324.8), (8, -331.3), (7.1, -331.8), (6.2, -355.8), (5.2, -356.8), (2.7, -356.8), (1.6, -354.8), (1.6, -338.8), (0, -337.8)]   # (r, z)
QUILL_CHUCK = [(0, -161.8), (30, -161.8), (30, -181.8), (26, -181.8), (26, -324.8), (28, -324.8), (32, -328.8), (32, -357.3), (30.5, -358.8), (8.8, -358.8), (8.8, -288.8), (0, -288.8)]
COVER_SMALL = [(40, 66), (74.8, 66), (79.8, 77.2), (79.8, 80.4), (81.5, 84), (74, 84), (69.8, 75), (61.5, 75), (61.5, 73), (40, 73)]   # (r, z) about the motor axis
COVER_BIG = [(47.5, 66), (74.8, 66), (80, 77.2), (80, 80.4), (81.7, 84), (84.8, 84), (84.8, 92), (77.7, 92), (71.5, 75), (47.5, 75)]

MOTOR = {   # half across-flats, corner chamfer, body z-range, frustum end half-width, shaft (r, z0, z1), terminal box (y0 straight, y1 chamfer start, y2 top, z0, z1)
    "small": dict(half=75, ch=25, z0=98, z1=278, end=54.5, shaft=(7, 43, 73), box=(240.7, 260.7, 275.7, 111.3, 205.7)),
    "big": dict(half=89, ch=25, z0=91, z1=311, end=67.7, shaft=(12, 16, 66), box=(254.7, 272.7, 287.7, 110.3, 192.7)),
}


def octagon(half, ch, cy=CY, cx=0.0, s=1.0):
    pts = [(half, cy - (half - ch)), (half, cy + (half - ch)), (half - ch, cy + half), (-(half - ch), cy + half),
           (-half, cy + (half - ch)), (-half, cy - (half - ch)), (-(half - ch), cy - half), (half - ch, cy - half)]
    return scaled(pts, s, s, 0.0, cy)


built = []   # (unit_cx, part, bodyID)


def add(cx, part, bid):
    built.append((cx, part, bid))
    return bid


ONLY = os.environ.get("BEG55_ONLY", "")   # "drive" = one small/back drive train and nothing else (bisecting a crash)


# ---- 1. Base parts at x = 0 (identical in all eight units) ------------------
def base_parts():
  print("1. Body (belt housing) — footprint extrude + column + cap + flanges, rib cut, front top")
  body = extrude("Body Footprint", XZ(-71), poly(BODY_XZ), (-60, 0), 138.2)
  extrude("Body Rib Cut", XY(-121), [rect(51, 9.7, 70, 67.2)], (60, 40), 139, "subtract", body)
  extrude("Body Column", XY(18), poly(COLUMN_XY), (0, 150), 48, "union", body)
  extrude("Body Cap", XY(0), [rect(-53, 240.6, 53, 250.7)], (0, 245), 84, "union", body)
  extrude("Body Flange Front", XY(11), [rect(-70, 67, 70, 209)], (0, 150), 7, "union", body)
  extrude("Body Flange Back", XY(66), [rect(-70, 67, 70, 209)], (0, 150), 7, "union", body)
  extrude("Body Front Top", XY(-121), [rect(-45, 67.2, 45, 75)], (0, 71), 94, "union", body)
  add(0, "body", body)

  print("2. Feed housing — profile with tie-rod holes, rear flange, nose boss, Ø60 / Ø52 bores")
  feed = extrude("Feed Housing", XY(-311.8), poly(FEED_XY) + [circle(x, y, 5.5) for x, y in FEED_HOLES], (0, 0), 183)
  extrude("Feed Rear Flange", XY(-128.8), [rect(-50, -68.5, 50, 76.5)], (0, 0), 7.8, "union", feed)
  extrude("Feed Nose Boss", XY(-314.8), [circle(0, 0, 35)], (0, 0), 3, "union", feed)
  extrude("Feed Bore", XY(-301.8), [circle(0, 0, 30)], (0, 0), 140, "subtract", feed)
  extrude("Feed Nose Bore", XY(-314.8), [circle(0, 0, 26)], (0, 0), 13, "subtract", feed)
  # Ø15.2 depth-stop rod out of the front face (this is what carries the envelope to z = -354.8)
  extrude("Feed Stop Rod", XY(-354.8), [circle(21.5, 42, 7.6)], (21.5, 42), 41, "union", feed)
  # two lugs on the top face (y 76.5..84) — the x = 0 section shows them at z -276..-265.6 and -262.9..-253.7
  for z0, z1 in [(-276, -265.6), (-262.9, -253.7)]:
      extrude("Feed Top Lug", XY(z0), [rect(-20, 73, 20, 84)], (0, 78), z1 - z0, "union", feed)
  add(0, "feed", feed)

  print("3. Bracket")
  bracket = add(0, "bracket", extrude("Bracket", XY(84), poly(BRACKET_XY), (0, 0), 57.5))

  print("   patterning body / feed / bracket x8 along -X (200 mm)")
  for part, bid in [("body", body), ("feed", feed), ("bracket", bracket)]:
      ids = pattern_x(bid, 8, 200)
      for i, nid in enumerate(ids):
          add(-200 * (i + 1) if nid != bid else 0, part, nid)


# ---- 2. Spindle quills: plain pairs at (0, -200) and (-800, -1000); chuck pairs at (-400, -600) and (-1200, -1400)
def quills():
  print("4. Spindle quills (revolved)")
  for cx, prof, name in [(0, QUILL_PLAIN, "plain"), (-800, QUILL_PLAIN, "plain"), (-400, QUILL_CHUCK, "chuck"), (-1200, QUILL_CHUCK, "chuck")]:
      q = revolve(f"Quill {name} @{cx}", YZ(cx), poly(prof), (15, -250), (0, 0))
      add(cx, "quill", q)
      for i, nid in enumerate(pattern_x(q, 2, 200)):
          if nid != q:
              add(cx - 200, "quill", nid)


# ---- 3. Drive trains: (small, back) @0, (small, front) @-200, (big, back) @-800, (big, front) @-1000; each patterned x2 at 400
def drive_train(cx, size, front):
    m = dict(MOTOR[size])
    if size == "big" and front:
        # the big motor's front mounting mirrors about z = 37.5, not 42: build it
        # 9 mm further back, so the mirror about 42 lands it at -261..59
        m["z0"] += 9; m["z1"] += 9
        m["shaft"] = (m["shaft"][0], m["shaft"][1] + 9, m["shaft"][2] + 9)
        b = m["box"]; m["box"] = (b[0], b[1], b[2], b[3] + 9, b[4] + 9)
    tag = f"{size}/{'front' if front else 'back'} @{cx}"
    print(f"5. Drive train {tag}")
    # motor: octagonal body, two frustum end caps (lofts), terminal box, shaft
    motor = extrude("Motor Body", XY(m["z0"], cx), poly(octagon(m["half"], m["ch"])), (0, CY), m["z1"] - m["z0"])
    # End caps are octagonal frustums: 25 mm long, flats from `half` in to `end`
    # (the end section is the body's octagon scaled about the axis), lofted
    # between the two sections and unioned into the body. The loft's inner
    # section sits exactly on the body's end face — the coincident-cap union
    # that used to kill the app (fixed 2026-09-02, `LoftOctagonTests`); a
    # draft extrude stood in for it meanwhile.
    s = m["end"] / m["half"]
    full, end = poly(octagon(m["half"], m["ch"])), poly(octagon(m["half"], m["ch"], s=s))
    loft("Motor Front Cap", XY(m["z0"] - 25, cx), end, (0, CY), XY(m["z0"], cx), full, (0, CY), "union", motor)
    loft("Motor Rear Cap", XY(m["z1"], cx), full, (0, CY), XY(m["z1"] + 25, cx), end, (0, CY), "union", motor)
    y0, y1, y2, bz0, bz1 = m["box"]
    extrude("Motor Terminal Box", XY(bz0, cx), poly([(48.5, y0), (48.5, y1), (33.5, y2), (-33.5, y2), (-48.5, y1), (-48.5, y0)]), (0, (y0 + y2) / 2), bz1 - bz0, "union", motor)
    r, sz0, sz1 = m["shaft"]
    extrude("Motor Shaft", XY(sz0, cx), [circle(0, CY, r)], (0, CY), sz1 - sz0, "union", motor)
    # motor plate: 6 mm full outline, lofted 18 mm chamfered slab, centre rib, holes
    plate = extrude("Plate Base", XY(-6, cx), poly(PLATE_XY), (30, 120), 6)
    # The slab's top face is inset 10.8 (x) / 22 (y) at z = 18: one uniform draft
    # stands in for the two-rate chamfer. 12 mm over 18 — the outline's 12.7 mm
    # corner segments survive that offset; 16 mm consumed them (self-intersection).
    # The measured outline carries 2 mm corner segments that the 14 mm inward
    # offset consumes; since 6ae1699 the draft collapses those onto the
    # neighbouring corners instead of refusing, so the slab drafts the real
    # outline (its top lands at about ±56 x 98..233, corners rounded).
    extrude("Plate Slab", XY(0, cx), poly(PLATE_XY), (30, 120), 18, "union", plate, taper=math.degrees(math.atan(14 / 18)))
    # the 68-wide rib on the back exists in four runs (x = 0 section), not one bar
    for y0, y1 in [(96.6, 122.7), (127.7, 149.7), (181.7, 188.7), (193.7, 227.2)]:
        extrude("Plate Rib", XY(-17.5, cx), [rect(-34, y0, 34, y1)], (0, (y0 + y1) / 2), 11.5, "union", plate)
    extrude("Plate Bore", XY(-20, cx), [circle(0, CY, 16)], (0, CY), 40, "subtract", plate)
    for hx, hy in [(58, 100.7), (-58, 100.7), (58, 230.7), (-58, 230.7)]:
        extrude("Plate Bolt Hole", XY(-20, cx), [circle(hx, hy, 4.75)], (hx, hy), 40, "subtract", plate)
    for hy in (125.2, 191.2):
        extrude("Plate Pin Hole", XY(-20, cx), [circle(0, hy, 2.5)], (0, hy), 40, "subtract", plate)
    # top (switch) box with its slot and the two round bosses on the back
    top = extrude("Top Box", XY(-71, cx), [rect(-70, 215.7, 70, 290.7)], (0, 250), 65)
    extrude("Top Box Slot", XY(-71, cx), [rect(-30, 226.4, 30, 232.9)], (0, 229.6), 65, "subtract", top)
    extrude("Top Box Boss A", XY(-121, cx), [circle(28, 263.7, 15)], (28, 263.7), 50, "union", top)
    extrude("Top Box Boss B", XY(-121, cx), [circle(-40, 264.7, 13.4)], (-40, 264.7), 50, "union", top)
    # belt-cover ring: revolve the measured (r, z) profile about the motor axis
    prof = COVER_BIG if size == "big" else COVER_SMALL
    cover = revolve("Cover Ring", YZ(cx), poly([(CY + r_, z_) for r_, z_ in prof]), (CY + prof[0][0] + 8, 69.5), (CY, 0))
    if size == "small":
        revolve("Cover Rim", YZ(cx), [rect(CY + 79.3, 84, CY + 85, 95)], (CY + 82, 90), (CY, 0), "union", cover)
        extrude("Cover Clip Top", XY(60, cx), [rect(-100, 235.7, 100, 300)], (0, 260), 40, "subtract", cover)
        extrude("Cover Clip Bottom", XY(60, cx), [rect(-100, 30, 100, 95.7)], (0, 60), 40, "subtract", cover)
    # feed valve: hex body, flange, tabs, nose
    valve = extrude("Valve Hex", XY(-75, cx), poly(VALVE_HEX), (0, CY), 45)
    # chamfered end z -80..-75: ±20 opening to ±25 (a 45° draft on a rect stand-in)
    extrude("Valve End Chamfer", XY(-80, cx), [rect(-20, 137.5, 20, 179.9)], (0, 158.7), 5, "union", valve, taper=-45)
    extrude("Valve Flange", XY(-30, cx), [rect(-25, 128.3, 25, 188.1)], (0, CY), 12.5, "union", valve)
    extrude("Valve Tab Low", XY(-30, cx), [rect(-25, 118.7, 25, 122.1)], (0, 120.4), 12.5, "union", valve)
    extrude("Valve Tab High", XY(-30, cx), [rect(-25, 194.3, 25, 198.7)], (0, 196.5), 12.5, "union", valve)
    extrude("Valve Nose", XY(-17.5, cx), [rect(-10.9, 154.8, 10.9, 176.6)], (0, CY), 4, "union", valve)
    parts = {"motor": motor, "plate": plate, "topbox": top, "cover": cover, "valve": valve}
    if front:
        parts = {k: mirror_z(v, cx) for k, v in parts.items()}
    for k, v in parts.items():
        add(cx, k, v)
        for nid in pattern_x(v, 2, 400):
            if nid != v:
                add(cx - 400, k, nid)


if ONLY == "drive":
    drive_train(0, "small", False)
else:
    base_parts()
    quills()
    drive_train(0, "small", False)
    drive_train(-200, "small", True)
    drive_train(-800, "big", False)
    drive_train(-1000, "big", True)

# ---- 4. Compare with the reference capture ---------------------------------
state = G("/v1/state")
bodies = {b["id"]: b for b in state["bodies"]}
health = G("/v1/check")
print(f"\nBodies: {len(bodies)}   invalid subshapes: {health.get('invalid')}   all B-rep: {all(b['brep'] for b in bodies.values())}")
total_v = sum(b["volumeMM3"] for b in bodies.values())
print(f"Total volume: {total_v:,.0f} mm3")

report = {"bodies": len(bodies), "invalid": health.get("invalid"), "totalVolume": total_v, "parts": []}
def kind_of(size):
    """Which of the nine parts a reference envelope is — the sizes are distinctive."""
    sx, sy, sz = size
    if abs(sy - 321.7) < 1: return "body"
    if abs(sz - 233.8) < 1: return "feed"
    if abs(sz - 57.5) < 1: return "bracket"
    if abs(sy - 75) < 1 and abs(sz - 115) < 1: return "topbox"
    if abs(sz - 35.5) < 1: return "plate"
    if sz > 190 and sx < 70: return "quill"
    if abs(sy - 80) < 1 and abs(sz - 66.5) < 1: return "valve"
    if sz < 30: return "cover"
    return "motor"


if CAPTURE:
    ref = json.load(open(CAPTURE))["units"]
    by_unit_kind = {}
    for cx, part, bid in built:
        if bid in bodies:
            by_unit_kind.setdefault((round(cx), part), []).append(bodies[bid])
    worst = 0.0
    for ux in sorted(ref, key=lambda s: float(s)):
        for rp in ref[ux]:
            rmin = rp["min"]; rmax = [rp["min"][i] + rp["size"][i] for i in range(3)]
            rc = [(rmin[i] + rmax[i]) / 2 for i in range(3)]
            kind = kind_of(rp["size"])
            cands = by_unit_kind.get((round(float(ux)), kind), [])
            if not cands:
                print(f"  unit {float(ux):>7.0f}  {kind:8s} ref vol {rp['vol']:>9,.0f} | MISSING in my build")
                report["parts"].append({"unit": float(ux), "kind": kind, "refMin": rmin, "refMax": rmax, "refVol": rp["vol"], "missing": True})
                continue
            b = min(cands, key=lambda b: math.dist([(b["bounds"][0][i] + b["bounds"][1][i]) / 2 for i in range(3)], rc))
            mn, mx = b["bounds"]
            dv = (b["volumeMM3"] - rp["vol"]) / rp["vol"] * 100
            env = max(max(abs(mn[i] - rmin[i]), abs(mx[i] - rmax[i])) for i in range(3))
            worst = max(worst, abs(dv))
            report["parts"].append({"unit": float(ux), "kind": kind, "refMin": rmin, "refMax": rmax, "refVol": rp["vol"], "myMin": mn, "myMax": mx, "myVol": b["volumeMM3"], "volPct": dv, "envMaxDev": env, "brep": b["brep"]})
            print(f"  unit {float(ux):>7.0f}  {kind:8s} ref {rp['size']!s:>22} vol {rp['vol']:>9,.0f} | mine {b['volumeMM3']:>9,.0f} ({dv:+6.2f}%)  envelope max dev {env:5.1f} mm")
    ref_total = sum(rp["vol"] for ux in ref for rp in ref[ux])
    claimed = {id(b) for cands in by_unit_kind.values() for b in cands}
    extras = [b for b in bodies.values() if id(b) not in claimed]
    print(f"\nReference total {ref_total:,.0f} mm3 vs mine {total_v:,.0f} ({(total_v - ref_total) / ref_total * 100:+.2f}%)   worst part {worst:.1f}%")
    if extras:
        print(f"  {len(extras)} bodies not tied to any unit/part (strays):")
        for b in extras[:12]:
            print(f"     {b['name']:>16s} vol {b['volumeMM3']:>10,.0f}  min {[round(v, 1) for v in b['bounds'][0]]}")
    report["refTotal"] = ref_total
    report["strays"] = len(extras)
    report["kinds"] = sorted({p["kind"] for p in report["parts"]})
if OUT:
    json.dump(report, open(OUT, "w"), indent=1)
    print("wrote", OUT)
