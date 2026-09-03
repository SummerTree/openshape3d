#!/usr/bin/env python3
"""Rebuild two TraceParts composite robots (AGV chassis + collaborative arm)
in openshape3d, using ONLY operations the app's tool palette offers.

  rokae  — ROKAE CMR-ST600-CR12-C (TraceParts 90-10052023-035374):
           differential-drive chassis 950 × 630 × 768 mm (datasheet), CR12
           arm (1,434 mm reach, ROKAE xMate CR datasheet 2026-08).
  lebai  — Lebai LM3 UP (TraceParts 27-05704395-097513): YUNJI UP base +
           LM3 arm, standby envelope 535 × 450 × 1200 mm (lebai.ltd), arm
           reach 638 mm, base mounting area ≈160 cm².

Neither vendor publishes a dimensioned drawing and the TraceParts 3D viewer
and STEP download sit behind a sign-in, so the shapes are proportioned from
the catalogue's product image and the link geometry is a generic 6-axis
layout scaled to the published reach. What IS checked, feature by feature:

  * every primitive's B-rep volume against its analytic volume (box,
    cylinder, filleted box) to 0.5 %,
  * every union against the sum of its parts (no lost tools, no doubled
    overlaps),
  * the finished bodies' bounding boxes against the datasheet envelopes,
  * a valid B-rep with 0 invalid subshapes for every body (/v1/check).

Each step names the palette tool a person would tap for it (Sketch › Rect,
Modify › Extrude, Modify › Fillet, Transform › Rotate, Combine › Union …)
so the run doubles as the UI-parity ledger for the report.

Run against a live DEBUG app with the agent up (OS3D_PORT, default 8899):

    python3 scripts/rebuild_composite_robots.py rokae
    python3 scripts/rebuild_composite_robots.py lebai

`--reuse-deck` adopts a chassis deck that was already built by hand in the
UI (matched by its bounding box) instead of extruding a new one.
"""

import json, math, os, sys, urllib.error, urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('OS3D_PORT', '8899')}"
TOL = 0.005          # 0.5 % volume tolerance for analytic checks
LEDGER = []          # (step, palette tool, result) rows for the report


def call(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise SystemExit(f"HTTP {e.code} on {path}: {body[:600]}")


def X(op, args):
    r = call("/v1/exec", {"op": op, "args": args})
    if not r.get("ok", True) or r.get("error"):
        raise SystemExit(f"{op} failed: {json.dumps(r)[:800]}")
    return r


def G(path):
    return call(path)


def bodies():
    return G("/v1/state")["bodies"]


def body(bid):
    for b in bodies():
        if b["id"] == bid:
            return b
    raise SystemExit(f"body {bid} vanished")


def vol(bid):
    return body(bid)["volumeMM3"]


def bounds(bid):
    """/v1/state encodes bounds as [[minx, miny, minz], [maxx, maxy, maxz]]."""
    b = body(bid)["bounds"]
    return b[0], b[1]


def extent(b):
    mn, mx = b["bounds"][0], b["bounds"][1]
    return [mx[i] - mn[i] for i in range(3)]


def edges(bid):
    return G(f"/v1/edges?body={bid}")["edges"]


def faces(bid):
    return G(f"/v1/faces?body={bid}")["faces"]


def check(bid, label):
    """/v1/check: {"checked", "invalid", "bodies": [{"health": {"valid", …}} | {"meshOnly"}]}."""
    r = G(f"/v1/check?body={bid}")
    row = (r.get("bodies") or [{}])[0]
    ok = r.get("invalid", 1) == 0 and not row.get("meshOnly") \
        and (row.get("health") or {}).get("valid") is True
    if not ok:
        raise SystemExit(f"{label}: B-rep check failed: {json.dumps(r)[:600]}")


def expect(label, got, want, tol=TOL):
    err = (got - want) / want if want else got
    flag = "ok" if abs(err) <= tol else "FAIL"
    print(f"  {label}: {got:,.1f} vs {want:,.1f} ({err:+.2%}) {flag}")
    if flag == "FAIL":
        raise SystemExit(f"{label} outside {tol:.1%}")


def ledger(step, tool, note):
    LEDGER.append((step, tool, note))
    print(f"[{len(LEDGER):02d}] {step}  —  {tool}  —  {note}")


# ---------------------------------------------------------------- planes ---
# World: X to the right (chassis length), Y up, Z toward the viewer (width).

def ground_sketch(name, y=0.0):
    """Sketch parallel to the ground at height y; (u, v) -> (u, y, -v); extrude +Y."""
    return X("sketch.create", {"name": name, "origin": [0, y, 0],
                               "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]})["sketchID"]


def front_sketch(name, z=0.0):
    """Sketch on a plane z = const facing +Z; (u, v) -> (u, v, z); extrude +Z."""
    return X("sketch.create", {"name": name, "origin": [0, 0, z],
                               "xAxis": [1, 0, 0], "yAxis": [0, 1, 0]})["sketchID"]


def side_sketch(name, x=0.0, toward=+1):
    """Sketch on a plane x = const; extrude along +X (toward=+1) or -X (-1)."""
    xa = [0, 0, -1] if toward > 0 else [0, 0, 1]
    return X("sketch.create", {"name": name, "origin": [x, 0, 0],
                               "xAxis": xa, "yAxis": [0, 1, 0]})["sketchID"]


def extrude(sk, seed, distance, taper=0.0, boolean=None, targets=None, symmetric=False):
    args = {"sketchID": sk, "seedPoint": list(seed), "distance": distance,
            "symmetric": symmetric}
    if taper:
        args["taperDegrees"] = taper
    if boolean:
        args["boolean"] = boolean
        args["booleanTargets"] = targets
    r = X("feature.extrude", args)
    ids = r.get("producedBodyIDs") or []
    return ids[0] if ids else (targets[0] if targets else None)


# ------------------------------------------------------------ primitives ---

def box(name, x0, x1, z0, z1, y0, h, taper=0.0, boolean=None, targets=None):
    """Sketch › Rect on a ground-parallel plane at y0, Modify › Extrude by h."""
    sk = ground_sketch(name, y0)
    X("sketch.addEntities", {"sketchID": sk, "entities": [
        {"kind": "rect", "min": [x0, -z1], "max": [x1, -z0]}]})
    seed = ((x0 + x1) / 2, -(z0 + z1) / 2)
    bid = extrude(sk, seed, h, taper=taper, boolean=boolean, targets=targets)
    if not boolean and not taper:
        expect(f"{name} volume", vol(bid), (x1 - x0) * (z1 - z0) * h)
    return bid


def cyl_y(name, cx, cz, r, y0, h, boolean=None, targets=None):
    """Vertical cylinder: Sketch › Circle on a ground plane, Modify › Extrude."""
    sk = ground_sketch(name, y0)
    X("sketch.addEntities", {"sketchID": sk, "entities": [
        {"kind": "circle", "center": [cx, -cz], "radius": r}]})
    bid = extrude(sk, (cx, -cz), h, boolean=boolean, targets=targets)
    if not boolean:
        expect(f"{name} volume", vol(bid), math.pi * r * r * h)
    return bid


def cyl_z(name, cx, cy, r, z0, length, boolean=None, targets=None):
    """Cylinder along +Z from z0: Sketch › Circle on a front plane, Extrude."""
    sk = front_sketch(name, z0)
    X("sketch.addEntities", {"sketchID": sk, "entities": [
        {"kind": "circle", "center": [cx, cy], "radius": r}]})
    bid = extrude(sk, (cx, cy), length, boolean=boolean, targets=targets)
    if not boolean:
        expect(f"{name} volume", vol(bid), math.pi * r * r * length)
    return bid


def cyl_x(name, cz, cy, r, x0, length, toward=+1, boolean=None, targets=None):
    """Cylinder along X from x0 (toward=+1 → +X): Circle on a side plane, Extrude."""
    sk = side_sketch(name, x0, toward)
    u = -cz if toward > 0 else cz
    X("sketch.addEntities", {"sketchID": sk, "entities": [
        {"kind": "circle", "center": [u, cy], "radius": r}]})
    bid = extrude(sk, (u, cy), length, boolean=boolean, targets=targets)
    if not boolean:
        expect(f"{name} volume", vol(bid), math.pi * r * r * length)
    return bid


def rect_on_front(name, x0, x1, y0, y1, z, depth, boolean=None, targets=None):
    """Rect on a front plane at z, extruded +Z by depth (negative = cut inward
    is expressed by the caller placing the plane and using subtract)."""
    sk = front_sketch(name, z)
    X("sketch.addEntities", {"sketchID": sk, "entities": [
        {"kind": "rect", "min": [x0, y0], "max": [x1, y1]}]})
    return extrude(sk, ((x0 + x1) / 2, (y0 + y1) / 2), depth,
                   boolean=boolean, targets=targets)


# ---------------------------------------------------------------- blends ---

def measured_edges(bid):
    """Edges that carry a mesh-side midpoint + length (seams/borders don't)."""
    return [e for e in edges(bid) if "midpoint" in e and "lengthMM" in e]


def vertical_edges(bid, y0, h, eps=1.0):
    ym = y0 + h / 2
    return [e["index"] for e in measured_edges(bid)
            if abs(e["lengthMM"] - h) < eps and abs(e["midpoint"][1] - ym) < eps]


def loop_at_y(bid, y, eps=0.5):
    return [e["index"] for e in measured_edges(bid) if abs(e["midpoint"][1] - y) < eps]


def circles_at_z(bid, z, r, eps=0.5):
    return [e["index"] for e in measured_edges(bid)
            if abs(e["midpoint"][2] - z) < eps and abs(e["lengthMM"] - 2 * math.pi * r) < 1.0]


def circles_at_x(bid, x, r, eps=0.5):
    return [e["index"] for e in measured_edges(bid)
            if abs(e["midpoint"][0] - x) < eps and abs(e["lengthMM"] - 2 * math.pi * r) < 1.0]


def fillet(bid, radius, edge_ids, label):
    if not edge_ids:
        raise SystemExit(f"{label}: no edges matched for the fillet")
    X("feature.fillet", {"bodyID": bid, "radius": radius, "edges": edge_ids})
    check(bid, label)


def chamfer(bid, setback, edge_ids, label):
    if not edge_ids:
        raise SystemExit(f"{label}: no edges matched for the chamfer")
    X("feature.chamfer", {"bodyID": bid, "setback": setback, "edges": edge_ids})
    check(bid, label)


# ------------------------------------------------------------- transforms ---

def rotate(bid, degrees, center, axis=(0, 0, 1)):
    X("feature.transform", {"bodyID": bid, "rotationDegrees": degrees,
                            "rotationAxis": list(axis), "rotationCenter": list(center)})


def union(target, tools, label):
    """Combine › Union. A fuse that OCCT rejects leaves the target's volume
    EXACTLY as it was and records an eval error — so the check is "the
    volume grew and nothing errored", not a loose ratio (a 0.6× ratio let
    a refused wrist union through once)."""
    own = vol(target)
    before = own + sum(vol(t) for t in tools)
    X("feature.boolean", {"kind": "union", "targetBodyID": target, "toolBodyIDs": tools})
    st = G("/v1/state")
    errs = st.get("evalErrors") or []
    after = vol(target)
    # Parts that only TOUCH fuse to exactly the sum of their volumes, give or
    # take the kernel's last digit — hence a relative slack on the top end.
    if errs or not (own + 1e-6 < after <= before * (1 + 1e-6) + 1e-3):
        raise SystemExit(f"{label}: union refused — volume {own:,.0f} → {after:,.0f} "
                         f"(parts {before:,.0f}); errors: {json.dumps(errs)[:300]}")
    check(target, label)
    print(f"  {label}: {len(tools)} tool(s) → {after:,.0f} mm³ (parts {before:,.0f})")
    return target


def subtract(target, tools, label):
    before = vol(target)
    X("feature.boolean", {"kind": "subtract", "targetBodyID": target, "toolBodyIDs": tools})
    after = vol(target)
    if not after < before:
        raise SystemExit(f"{label}: subtract removed nothing ({after:,.0f})")
    check(target, label)
    return before - after


# ------------------------------------------------------------ arm builder ---

def cobot_arm(p):
    """A generic 6-axis collaborative arm posed from the catalogue image.

    p: dict with base position (bx, bz) on a deck at y=top, base/link
    diameters and lengths, shoulder-height d1, link lengths a2/a3, the
    shoulder lean (deg from vertical toward -X) and the forearm angle
    (deg, measured the same way; 150 = down-left at 60° below horizontal).
    Every link is drawn upright on a ground-parallel plane and posed with
    Transform › Rotate about the joint axis, exactly as a person would.
    """
    bx, bz, top = p["bx"], p["bz"], p["top"]
    parts = []
    # Joint layout rule (learned the hard way): a link's end face must NOT
    # lie in a plane through its joint housing's axis, and a housing's end
    # cap must not be the plane a link starts on. OCCT's fuse rejected the
    # first layout ("boolean result failed validity checking") exactly
    # where the base column's top face ran through the shoulder axis. So
    # every link starts `lap` mm past its joint axis and pokes `lap` mm into
    # the side of its housing — real cobot knuckles overlap the same way.
    lap = p.get("lap", 10.0)

    # Base plate + base column (Sketch › Circle, Modify › Extrude ×2). The
    # column stops `lap` short of the shoulder axis. A plate/column already
    # in the document (a re-run after the undo stack bottomed out) is adopted
    # rather than duplicated — coincident solids are no fuse's friend.
    plate = find_body((2 * p["plate_r"], p["plate_h"], 2 * p["plate_r"]), tol=0.001) \
        or cyl_y("arm base plate", bx, bz, p["plate_r"], top, p["plate_h"])
    col_h = p["d1"] - p["plate_h"] - lap
    base = find_body((2 * p["base_r"], col_h, 2 * p["base_r"]), tol=0.001) \
        or cyl_y("arm base", bx, bz, p["base_r"], top + p["plate_h"], col_h)
    parts += [base]
    ledger("arm base plate + column", "Sketch › Circle, Modify › Extrude",
           f"Ø{2*p['plate_r']:.0f}×{p['plate_h']:.0f} + Ø{2*p['base_r']:.0f}, shoulder axis {p['d1']:.0f} above the deck")

    sy = top + p["d1"]                       # shoulder axis height
    # Shoulder housing along Z, centred on the base axis
    sh_r, sh_len = p["shoulder_r"], p["shoulder_len"]
    sh_z0 = bz - sh_len / 2
    shoulder = find_body((2 * sh_r, 2 * sh_r, sh_len), tol=0.001) \
        or cyl_z("shoulder housing", bx, sy, sh_r, sh_z0, sh_len)
    rims = circles_at_z(shoulder, sh_z0, sh_r) + circles_at_z(shoulder, sh_z0 + sh_len, sh_r)
    if rims:
        fillet(shoulder, p["joint_fillet"], rims, "shoulder end fillets")
    else:
        print("  shoulder housing already rounded (adopted) — skipping its fillet")
    parts.append(shoulder)
    ledger("shoulder housing", "Sketch › Circle (front plane), Modify › Extrude, Modify › Fillet",
           f"Ø{2*sh_r:.0f} × {sh_len:.0f} along Z, R{p['joint_fillet']:.0f} ends")

    # Upper arm: beside the housing's +Z end, drawn upright from just below
    # the shoulder axis, then rotated about that axis
    ua_z = sh_z0 + sh_len + p["upper_r"] - lap
    upper = cyl_y("upper arm", bx, ua_z, p["upper_r"], sy - lap, p["a2"] + lap)
    fillet(upper, p["link_fillet"], loop_at_y(upper, sy + p["a2"]), "upper arm cap fillet")
    lean = p["lean"]
    rotate(upper, lean, (bx, sy, ua_z))
    parts.append(upper)
    ex = bx - p["a2"] * math.sin(math.radians(lean))
    ey = sy + p["a2"] * math.cos(math.radians(lean))
    ledger("upper arm", "Sketch › Circle, Modify › Extrude, Modify › Fillet, Transform › Rotate",
           f"Ø{2*p['upper_r']:.0f} × {p['a2']:.0f}, rotated {lean:.0f}° about the shoulder axis → elbow at ({ex:.0f}, {ey:.0f})")

    # Elbow housing along Z, centred on the upper arm's axis
    el_r, el_len = p["elbow_r"], p["elbow_len"]
    el_z0 = ua_z - el_len / 2
    elbow = cyl_z("elbow housing", ex, ey, el_r, el_z0, el_len)
    fillet(elbow, p["joint_fillet"], circles_at_z(elbow, el_z0, el_r) + circles_at_z(elbow, el_z0 + el_len, el_r),
           "elbow end fillets")
    parts.append(elbow)
    ledger("elbow housing", "Sketch › Circle (front plane), Modify › Extrude, Modify › Fillet",
           f"Ø{2*el_r:.0f} × {el_len:.0f} along Z")

    # Forearm: beside the elbow housing's −Z end (back toward the base
    # plane), drawn upright from just below the elbow axis, rotated about it
    fa_z = el_z0 - p["fore_r"] + lap
    fore = cyl_y("forearm", ex, fa_z, p["fore_r"], ey - lap, p["a3"] + lap)
    fillet(fore, p["link_fillet"], loop_at_y(fore, ey + p["a3"]), "forearm cap fillet")
    fang = p["fore_angle"]
    rotate(fore, fang, (ex, ey, fa_z))
    parts.append(fore)
    wx = ex - p["a3"] * math.sin(math.radians(fang))
    wy = ey + p["a3"] * math.cos(math.radians(fang))
    ledger("forearm", "Sketch › Circle, Modify › Extrude, Modify › Fillet, Transform › Rotate",
           f"Ø{2*p['fore_r']:.0f} × {p['a3']:.0f}, rotated {fang:.0f}° about the elbow axis → wrist at ({wx:.0f}, {wy:.0f})")

    # Wrist 1 housing along Z centred on the forearm's axis; wrist 2 + flange
    # beside its −Z end, along the tool direction, skew to the wrist axis
    w_r, w_len = p["wrist_r"], p["wrist_len"]
    w_z0 = fa_z - w_len / 2
    wrist1 = cyl_z("wrist 1 housing", wx, wy, w_r, w_z0, w_len)
    fillet(wrist1, p["joint_fillet"] * 0.6, circles_at_z(wrist1, w_z0, w_r) + circles_at_z(wrist1, w_z0 + w_len, w_r),
           "wrist 1 end fillets")
    parts.append(wrist1)
    tz = w_z0 - p["wrist2_r"] + lap
    if p["tool_dir"] == "down":
        wrist2 = cyl_y("wrist 2", wx, tz, p["wrist2_r"], wy - p["wrist2_len"], p["wrist2_len"] + lap)
        flange = cyl_y("tool flange", wx, tz, p["flange_r"], wy - p["wrist2_len"] - p["flange_h"], p["flange_h"])
        tool_tip = (wx, wy - p["wrist2_len"] - p["flange_h"], tz)
    else:  # "left": tool axis along -X, a hair below the wrist axis (skew, not intersecting)
        ty = wy - lap * 0.8
        wrist2 = cyl_x("wrist 2", tz, ty, p["wrist2_r"], wx + lap, p["wrist2_len"] + lap, toward=-1)
        flange = cyl_x("tool flange", tz, ty, p["flange_r"], wx - p["wrist2_len"], p["flange_h"], toward=-1)
        tool_tip = (wx - p["wrist2_len"] - p["flange_h"], ty, tz)
    parts += [wrist2, flange]
    ledger("wrist 2 + tool flange", "Sketch › Circle, Modify › Extrude ×2",
           f"Ø{2*p['wrist2_r']:.0f} × {p['wrist2_len']:.0f}, flange Ø{2*p['flange_r']:.0f} × {p['flange_h']:.0f}, tool points {p['tool_dir']}")

    # One Combine › Union per link, base outward — the way a person joins
    # them, and the way a refusal names the joint it happened at.
    arm = plate
    for part, label in zip(parts, ["base", "shoulder", "upper arm", "elbow", "forearm",
                                   "wrist 1", "wrist 2", "flange"]):
        union(arm, [part], f"arm union + {label}")
    ledger("arm unions", "Combine › Union ×8", f"{len(parts)+1} link bodies → one arm body, joined base outward")
    return arm, tool_tip, (ex, ey)


# ------------------------------------------------------------- arm specs ---
# Generic 6-axis layouts scaled to the published reach (a2 + a3 + wrist).
# Link diameters and joint proportions follow the catalogue images.

ROKAE_ARM = {                                     # xMate CR12: reach 1,434 mm
    "bx": 150.0, "bz": -80.0, "top": 768.0,
    "plate_r": 100.0, "plate_h": 15.0, "base_r": 85.0, "d1": 150.0,
    "shoulder_r": 80.0, "shoulder_len": 190.0,
    "upper_r": 60.0, "a2": 650.0, "lean": 35.0,
    "elbow_r": 65.0, "elbow_len": 140.0,
    "fore_r": 50.0, "a3": 600.0, "fore_angle": 150.0,
    # Every housing is a few mm LARGER than the link it carries: equal radii
    # on perpendicular intersecting axes (forearm Ø100 into a Ø100 wrist)
    # is the degenerate Steinmetz case and OCCT's fuse refused it.
    # …and every housing is LONGER than its link is wide: a Ø100 forearm in
    # a 100-long wrist housing is tangent to both end caps, and that fuse
    # came back invalid too.
    "wrist_r": 55.0, "wrist_len": 130.0,
    "wrist2_r": 45.0, "wrist2_len": 120.0, "flange_r": 35.0, "flange_h": 20.0,
    "tool_dir": "down", "joint_fillet": 25.0, "link_fillet": 20.0, "lap": 10.0,
}

LEBAI_ARM = {                                     # LM3: reach 638 mm
    "bx": -30.0, "bz": 0.0, "top": 745.0,
    "plate_r": 70.0, "plate_h": 12.0, "base_r": 46.0, "d1": 112.0,
    "shoulder_r": 50.0, "shoulder_len": 125.0,
    "upper_r": 40.0, "a2": 300.0, "lean": -25.0,
    "elbow_r": 44.0, "elbow_len": 85.0,
    "fore_r": 30.0, "a3": 250.0, "fore_angle": 145.0,
    "wrist_r": 34.0, "wrist_len": 90.0,
    "wrist2_r": 28.0, "wrist2_len": 50.0, "flange_r": 25.0, "flange_h": 12.0,
    "tool_dir": "left", "joint_fillet": 15.0, "link_fillet": 14.0, "lap": 6.0,
}


def find_body(extent, tol=0.02):
    """The live body whose bounding box matches `extent` (dx, dy, dz)."""
    for b in bodies():
        if not b["bounds"]:
            continue
        got = extent_of(b)
        if all(abs(got[i] - extent[i]) <= tol * extent[i] for i in range(3)):
            return b["id"]
    return None


def extent_of(b):
    return extent(b)


# ----------------------------------------------------------------- ROKAE ---

def build_rokae(reuse_deck):
    print("=== ROKAE CMR-ST600-CR12-C ===")
    L, W = 950.0, 630.0                       # datasheet chassis footprint
    H = 768.0                                 # datasheet chassis height
    clearance, deck_h = 40.0, 230.0           # deck rides on wheels
    cab_top = H
    cab_y0 = clearance + deck_h               # 270
    cab_h = cab_top - cab_y0                  # 498

    deck = None
    if reuse_deck:
        for b in bodies():
            if not b["bounds"]:
                continue
            dx, dy, dz = extent(b)
            if abs(dx - L) < 0.03 * L and abs(dz - W) < 0.03 * W and abs(dy - deck_h) < 0.03 * deck_h:
                deck = b["id"]
                print(f"  reusing the hand-built deck {deck} ({dx:.0f} × {dz:.0f} × {dy:.0f})")
                # A touch-drawn sketch lands wherever the finger started; a
                # person would Transform › Move it onto the axes next. Do the
                # same so the rest of the recipe's coordinates line up.
                mn, mx = b["bounds"][0], b["bounds"][1]
                shift = [-(mn[0] + mx[0]) / 2, clearance - mn[1], -(mn[2] + mx[2]) / 2]
                if max(abs(s) for s in shift) > 0.01:
                    X("feature.transform", {"bodyID": deck, "translation": shift})
                    print(f"  moved it by ({shift[0]:.1f}, {shift[1]:.1f}, {shift[2]:.1f}) onto the axes")
                mn, mx = bounds(deck)
                deck_h = mx[1] - mn[1]        # keep the hand-typed height
                cab_y0 = clearance + deck_h
                cab_h = cab_top - cab_y0
                ledger("chassis deck", "built by touch in the UI (Sketch › Rect, Dimension, Modify › Extrude, Transform › Move)",
                       f"{dx:.0f} × {dz:.0f} × {dy:.0f} mm, adopted by bounding box and centred on the axes")
                break
        if deck is None:
            print("  no hand-built deck within 3 % of 950 × 630 × 230 — extruding one")
    if deck is None:
        deck = box("chassis deck", -L / 2, L / 2, -W / 2, W / 2, clearance, deck_h)
        ledger("chassis deck", "Sketch › Rect, Modify › Extrude", f"{L:.0f} × {W:.0f} × {deck_h:.0f} at {clearance:.0f} mm clearance")

    # Corner rounds + a soft top edge (Modify › Fillet, twice)
    r_v = 60.0
    box_v = L * W * deck_h
    rounded_v = box_v - (4 - math.pi) * r_v ** 2 * deck_h
    if abs(vol(deck) - rounded_v) < 1e-4 * box_v:
        print("  deck already carries its R60 corners (re-run) — skipping")
    else:
        fillet(deck, r_v, vertical_edges(deck, clearance, deck_h), "deck vertical fillets")
        expect("deck after R60 corners", vol(deck), rounded_v, tol=0.01)
    fillet(deck, 15.0, loop_at_y(deck, clearance + deck_h), "deck top-edge fillet")
    ledger("deck corner + top rounds", "Modify › Fillet ×2", "R60 verticals, R15 top loop")

    # Two lidar notches at opposite corners (Sketch › Rect on the deck top,
    # Modify › Extrude as Subtract), each with a lidar puck in it
    notch = 130.0
    for (sx, sz) in ((+1, +1), (-1, -1)):
        x0, x1 = sorted((sx * L / 2, sx * (L / 2 - notch)))
        z0, z1 = sorted((sz * W / 2, sz * (W / 2 - notch)))
        cut_h = 110.0
        cutter = box(f"lidar notch {sx:+d}{sz:+d}", x0, x1, z0, z1, clearance + deck_h - cut_h, cut_h + 5)
        removed = subtract(deck, [cutter], "lidar notch cut")
        puck = cyl_y("lidar puck", sx * (L / 2 - notch / 2), sz * (W / 2 - notch / 2), 32.0,
                     clearance + deck_h - cut_h, 70.0)
        union(deck, [puck], "lidar puck union")
    ledger("lidar notches + pucks", "Sketch › Rect, Extrude › Subtract, Sketch › Circle, Extrude, Combine › Union",
           "two 130 mm corner notches at opposite corners, Ø64 × 70 pucks")

    # Drive wheels, mostly hidden under the skirt
    for sz in (+1, -1):
        wheel = cyl_z("drive wheel", 0.0, 80.0, 80.0, sz * (W / 2 - 90) - 25, 50.0)
        union(deck, [wheel], "wheel union")
    ledger("drive wheels", "Sketch › Circle (front plane), Modify › Extrude, Combine › Union", "two Ø160 × 50 wheels, differential drive")

    # Cabinet: inset box, big corner rounds, dark chamfered top rim
    cab = box("cabinet", -440, 440, -280, 280, cab_y0, cab_h)
    v0 = vol(cab)
    fillet(cab, 70.0, vertical_edges(cab, cab_y0, cab_h), "cabinet vertical fillets")
    expect("cabinet after R70 corners", vol(cab), v0 - (4 - math.pi) * 70 ** 2 * cab_h, tol=0.01)
    chamfer(cab, 12.0, loop_at_y(cab, cab_top), "cabinet top chamfer")
    ledger("cabinet", "Sketch › Rect, Modify › Extrude, Modify › Fillet, Modify › Chamfer",
           f"880 × 560 × {cab_h:.0f}, R70 corners, 12 mm top chamfer (the dark rim)")

    # Door seam: a 4 mm groove down the front face, and a horizontal seam
    seam = rect_on_front("door seam", -62, -58, cab_y0 + 30, cab_top - 40, 280 - 3, 6)
    subtract(cab, [seam], "door seam cut")
    seam2 = rect_on_front("cabinet seam", -440, 440, cab_y0 + 28, cab_y0 + 32, 280 - 3, 6)
    subtract(cab, [seam2], "lower seam cut")
    ledger("door seams", "Sketch › Rect (front face), Modify › Extrude › Subtract ×2", "4 mm × 3 mm grooves")

    # Emergency stop on the front face: yellow collar + red mushroom button
    collar = cyl_z("e-stop collar", 330, 700, 30.0, 280, 8)
    button = cyl_z("e-stop button", 330, 700, 20.0, 288, 15)
    fillet(button, 6.0, circles_at_z(button, 303, 20.0), "e-stop button dome")
    union(cab, [collar, button], "e-stop union")
    # Two small handles / indicator buttons
    for hx in (-250, -130):
        h = rect_on_front("handle", hx - 10, hx + 10, 675, 715, 280, 8)
        union(cab, [h], "handle union")
    ledger("e-stop + handles", "Sketch › Circle/Rect on the front face, Modify › Extrude, Modify › Fillet, Combine › Union",
           "Ø60 collar, Ø40 button with R6 dome; two 20 × 40 × 8 handles")

    chassis = union(deck, [cab], "chassis union")
    ledger("chassis union", "Combine › Union", "deck + cabinet → one chassis body")

    arm, tip, elbow = cobot_arm(ROKAE_ARM)

    mn, mx = bounds(chassis)
    print(f"  chassis bounds: {mx[0]-mn[0]:.0f} × {mx[2]-mn[2]:.0f} × {mx[1]:.0f} (datasheet {L:.0f} × {W:.0f} × {H:.0f})")
    expect("chassis length", mx[0] - mn[0], L, tol=0.001)
    expect("chassis width", mx[2] - mn[2], W, tol=0.001)
    expect("chassis height", mx[1], H, tol=0.001)
    amn, amx = bounds(arm)
    reach = math.hypot(elbow[0] - 150.0, elbow[1] - (cab_top + 150.0)) + 600.0 + 120.0 + 20.0 + 50.0
    print(f"  arm bounds y: {amn[1]:.0f}..{amx[1]:.0f}; nominal stretched reach {reach:.0f} mm (datasheet 1,434)")
    expect("arm reach (a2+a3+wrist)", reach, 1434.0, tol=0.03)
    return chassis, arm


# ----------------------------------------------------------------- LEBAI ---

def build_lebai(reuse_deck):
    print("=== Lebai LM3 UP ===")
    L, W, H = 535.0, 450.0, 1200.0            # standby envelope (lebai.ltd)
    clearance = 30.0
    low_h = 350.0                             # lower chassis
    mid_y0 = clearance + low_h                # 380
    mid_h = 260.0
    slab_y0 = mid_y0 + mid_h                  # 640
    slab_h = 80.0
    plinth_y0 = slab_y0 + slab_h              # 720

    low = None
    if reuse_deck:
        for b in bodies():
            if not b["bounds"]:
                continue
            dx, dy, dz = extent(b)
            if abs(dx - L) < 0.03 * L and abs(dz - W) < 0.03 * W and abs(dy - low_h) < 0.03 * low_h:
                low = b["id"]
                print(f"  reusing the hand-built chassis {low} ({dx:.0f} × {dz:.0f} × {dy:.0f})")
                mn, mx = b["bounds"][0], b["bounds"][1]
                shift = [-(mn[0] + mx[0]) / 2, clearance - mn[1], -(mn[2] + mx[2]) / 2]
                if max(abs(s) for s in shift) > 0.01:
                    X("feature.transform", {"bodyID": low, "translation": shift})
                    print(f"  moved it by ({shift[0]:.1f}, {shift[1]:.1f}, {shift[2]:.1f}) onto the axes")
                mn, mx = bounds(low)
                low_h = mx[1] - mn[1]
                mid_y0 = clearance + low_h
                slab_y0 = mid_y0 + mid_h
                plinth_y0 = slab_y0 + slab_h
                ledger("lower chassis", "built by touch in the UI (Sketch › Rect, Dimension, Modify › Extrude, Transform › Move)",
                       f"{dx:.0f} × {dz:.0f} × {dy:.0f} mm, adopted by bounding box and centred on the axes")
                break
    if low is None:
        low = box("lower chassis", -L / 2, L / 2, -W / 2, W / 2, clearance, low_h)
        ledger("lower chassis", "Sketch › Rect, Modify › Extrude", f"{L:.0f} × {W:.0f} × {low_h:.0f}")
    v0 = vol(low)
    fillet(low, 80.0, vertical_edges(low, clearance, low_h), "chassis vertical fillets")
    expect("chassis after R80 corners", vol(low), v0 - (4 - math.pi) * 80 ** 2 * low_h, tol=0.01)
    fillet(low, 40.0, loop_at_y(low, clearance + low_h), "chassis top-edge fillet")
    ledger("chassis rounds", "Modify › Fillet ×2", "R80 verticals, R40 top loop")

    # Lidar window: a slot across the front face
    slot = rect_on_front("lidar window", -150, 150, 250, 285, W / 2 - 12, 20)
    subtract(low, [slot], "lidar window cut")
    # Bumper groove around the skirt height is left out (cosmetic paint line).
    for sz in (+1, -1):
        wheel = cyl_z("drive wheel", 0.0, 60.0, 60.0, sz * (W / 2 - 60) - 20, 40.0)
        union(low, [wheel], "wheel union")
    ledger("lidar window + wheels", "Sketch › Rect (front face), Extrude › Subtract, Sketch › Circle, Extrude, Union",
           "300 × 35 × 12 slot; two Ø120 × 40 wheels")

    # Mid cabinet: tapered (the image shows it narrowing upward) — Extrude with draft
    mid = box("mid cabinet", -230, 230, -190, 190, mid_y0, mid_h, taper=4.0)
    fillet(mid, 30.0, vertical_edges(mid, mid_y0, mid_h / math.cos(math.radians(4)), eps=2.0) or
           [e["index"] for e in edges(mid) if abs(e["lengthMM"] - mid_h / math.cos(math.radians(4))) < 3.0],
           "mid cabinet vertical fillets")
    ledger("mid cabinet", "Sketch › Rect, Modify › Extrude (4° draft), Modify › Fillet", f"460 × 380 × {mid_h:.0f}, 4° taper, R30 corners")

    # Top slab with the arm plinth
    slab = box("top slab", -210, 210, -170, 170, slab_y0, slab_h)
    fillet(slab, 25.0, vertical_edges(slab, slab_y0, slab_h), "slab vertical fillets")
    fillet(slab, 10.0, loop_at_y(slab, plinth_y0), "slab top-edge fillet")
    plinth = cyl_y("arm plinth", -30, 0, 65.0, plinth_y0, 25.0)
    union(slab, [plinth], "plinth union")
    # E-stop on the slab's front-right corner
    collar = cyl_y("e-stop collar", 170, -110, 25.0, plinth_y0, 10.0)
    button = cyl_y("e-stop button", 170, -110, 16.0, plinth_y0 + 10, 22.0)
    fillet(button, 5.0, loop_at_y(button, plinth_y0 + 32), "e-stop dome")
    union(slab, [collar, button], "e-stop union")
    ledger("top slab + plinth + e-stop", "Sketch › Rect/Circle, Modify › Extrude, Modify › Fillet, Combine › Union",
           "420 × 340 × 80 slab, Ø130 × 25 plinth, Ø50/Ø32 e-stop")

    chassis = union(low, [mid, slab], "chassis union")
    ledger("chassis union", "Combine › Union", "lower + mid + slab → one body")

    arm, tip, elbow = cobot_arm(dict(LEBAI_ARM, top=plinth_y0 + 25.0))

    # Gripper: body + two red fingers pointing -X from the flange
    tx, ty, tz = tip
    gbody = box("gripper body", tx - 45, tx, tz - 20, tz + 20, ty - 18, 36)
    fingers = []
    for sz in (+1, -1):
        f = box("gripper finger", tx - 95, tx - 45, tz + sz * 12 - 5, tz + sz * 12 + 5, ty - 8, 16)
        fingers.append(f)
    union(arm, [gbody] + fingers, "gripper union")
    ledger("gripper", "Sketch › Rect, Modify › Extrude ×3, Combine › Union", "45 × 40 × 36 body, two 50 × 10 × 16 fingers")

    mn, mx = bounds(chassis)
    amn, amx = bounds(arm)
    top = max(mx[1], amx[1])
    print(f"  envelope: {max(mx[0],amx[0])-min(mn[0],amn[0]):.0f} × {max(mx[2],amx[2])-min(mn[2],amn[2]):.0f} × {top:.0f} (datasheet {L:.0f} × {W:.0f} × {H:.0f})")
    expect("chassis length", mx[0] - mn[0], L, tol=0.001)
    expect("chassis width", mx[2] - mn[2], W, tol=0.001)
    expect("standby height", top, H, tol=0.06)
    reach = 300.0 + 250.0 + 50.0 + 12.0 + 26.0
    expect("arm reach (a2+a3+wrist)", reach, 638.0, tol=0.01)
    return chassis, arm


# ------------------------------------------------------------------ main ---

def arm_only(which):
    """Re-run just the arm on a document whose chassis is already built
    (matched by its datasheet envelope) — the arm layout was reworked once
    after the chassis passed, and the chassis takes minutes to rebuild."""
    if which == "rokae":
        chassis = find_body((950.0, 768.0, 630.0))
        spec = ROKAE_ARM
    else:
        chassis = find_body((535.0, 745.0, 450.0))
        spec = LEBAI_ARM
    if chassis is None:
        raise SystemExit("--arm-only: no finished chassis in the document")
    print(f"  arm only — chassis {chassis}")
    arm, tip, elbow = cobot_arm(spec)
    if which == "lebai":
        tx, ty, tz = tip
        gbody = box("gripper body", tx - 45, tx, tz - 20, tz + 20, ty - 18, 36)
        fingers = [box("gripper finger", tx - 95, tx - 45, tz + sz * 12 - 5, tz + sz * 12 + 5, ty - 8, 16)
                   for sz in (+1, -1)]
        union(arm, [gbody] + fingers, "gripper union")
    return chassis, arm


def verify_only(which):
    """Final datasheet checks on a document that already holds the finished
    chassis + arm (the chassis is the body with the datasheet footprint)."""
    L, W = (950.0, 630.0) if which == "rokae" else (535.0, 450.0)
    chassis = arm = None
    for b in bodies():
        if not b["bounds"]:
            continue
        dx, dy, dz = extent(b)
        if abs(dx - L) < 0.02 * L and abs(dz - W) < 0.02 * W:
            chassis = b["id"]
        else:
            arm = b["id"]
    if chassis is None or arm is None:
        raise SystemExit(f"--verify-only: need a chassis and an arm body, have {len(bodies())} bodies")
    mn, mx = bounds(chassis)
    amn, amx = bounds(arm)
    if which == "rokae":
        expect("chassis length", mx[0] - mn[0], L, tol=0.001)
        expect("chassis width", mx[2] - mn[2], W, tol=0.001)
        expect("chassis height", mx[1], 768.0, tol=0.001)
        reach = ROKAE_ARM["a2"] + ROKAE_ARM["a3"] + ROKAE_ARM["wrist2_len"] + ROKAE_ARM["flange_h"] + ROKAE_ARM["wrist_r"]
        expect("arm reach (a2+a3+wrist)", reach, 1434.0, tol=0.03)
        print(f"  arm envelope y {amn[1]:.0f}..{amx[1]:.0f} mm (elbow-up pose); chassis top {mx[1]:.0f}")
    else:
        top = max(mx[1], amx[1])
        expect("chassis length", mx[0] - mn[0], L, tol=0.001)
        expect("chassis width", mx[2] - mn[2], W, tol=0.001)
        expect("standby height", top, 1200.0, tol=0.06)
        reach = LEBAI_ARM["a2"] + LEBAI_ARM["a3"] + LEBAI_ARM["wrist2_len"] + LEBAI_ARM["flange_h"] + 26.0
        expect("arm reach (a2+a3+wrist)", reach, 638.0, tol=0.01)
        print(f"  envelope {max(mx[0],amx[0])-min(mn[0],amn[0]):.0f} × {max(mx[2],amx[2])-min(mn[2],amn[2]):.0f} × {top:.0f} (datasheet 535 × 450 × 1200)")
    return chassis, arm


def main():
    which = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
    reuse = "--reuse-deck" in sys.argv
    if which not in ("rokae", "lebai"):
        raise SystemExit("usage: rebuild_composite_robots.py rokae|lebai [--reuse-deck] [--arm-only] [--verify-only]")
    if not G("/v1/state").get("ok"):
        raise SystemExit("agent not answering")
    if "--verify-only" in sys.argv:
        chassis, arm = verify_only(which)
    elif "--arm-only" in sys.argv:
        chassis, arm = arm_only(which)
    else:
        chassis, arm = (build_rokae if which == "rokae" else build_lebai)(reuse)
    for bid, label in ((chassis, "chassis"), (arm, "arm")):
        check(bid, f"final {label}")
    call("/v1/command", {"id": "view.isometric"})
    call("/v1/command", {"id": "view.fit"})
    st = G("/v1/state")
    print(f"\nfeatures recorded: {st['featureCount']}; bodies: {len(st['bodies'])}; "
          f"eval errors: {len(st.get('evalErrors', []))}")
    print("\nUI ledger:")
    for i, (step, tool, note) in enumerate(LEDGER, 1):
        print(f"  {i:2d}. {step:28s} {tool}\n      {note}")
    out = os.environ.get("OS3D_LEDGER")
    if out:
        with open(out, "w") as f:
            json.dump([{"step": s, "tool": t, "note": n} for s, t, n in LEDGER], f, indent=1)
    print("\nRESULT: ALL PASS")


if __name__ == "__main__":
    main()
