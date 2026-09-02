#!/usr/bin/env python3
"""Rebuild the Shapr3D "4 motorcycle wheel" through POST /v1/exec.

A worked example of the exec endpoint, and a manual regression for it: this is
the model that found all three of the bugs the endpoint shipped with. Geometry
comes from that tutorial model's own recipe, extracted with
`scripts/shapr_extract.py` and converted from metres to mm.

Run it against a live DEBUG app (see .claude/skills/drive-openshape3d/):

    SIMCTL_CHILD_OS3D_AGENT=1 SIMCTL_CHILD_OS3D_FRESH=1 \
      xcrun simctl launch <udid> com.laan.labs.openshape3d
    python3 scripts/rebuild_wheel.py

EXPECTED, and worth checking rather than eyeballing the render:

  Revolve   34,775,356 mm3   vs a 36.4M straight-line Pappus estimate. Lower is
                            CORRECT — the profile's large arc bulges inward, so
                            treating it as a chord overestimates the area.
  Cutter    10,131,479 mm3   note `symmetric` means +/- distance, so 400 spans
                            800: pi * 63.5^2 * 800 = 10,134,150.
  Subtract  30,221,686 mm3   4,553,670 removed by 5 holes = 910,734 each,
                            implying a 71.9 mm dish where the profile puts ~69.

A revolve whose angle is wrong by the degrees/radians confusion still LOOKS like
a plausible wheel. The volume is what catches it. Every op should report
ok=True with no warning and no evalErrors.

FULL recipe as of 2026-09-01: the 12.7 mm bolt holes (patterned with the
spokes), the Mirror, and the closing union are all replicated —

  Bolt subtract  30,086,565 mm3  (135,121 removed = 27,024 per hole)
  Full wheel     60,173,131 mm3  EXACTLY 2x the half (asserted at 0.1%):
                                 the union meets only on the mirror plane,
                                 so any mirror placement or seam error
                                 shows up here as a volume error.

The one remaining infidelity: the recipe's cutter extrude carries a -5 deg
taper (its -87.2665 slot is radians), which we cannot express — both hole
sets are straight.
"""

import json, math, os, urllib.request
def X(p):
    port=os.environ.get("OS3D_PORT","8787")
    r=urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/exec",
        data=json.dumps(p).encode(), headers={"Content-Type":"application/json"}), timeout=120)
    return json.load(r)
def arc(cx,cy,sx,sy,ex,ey):
    return {"kind":"arc","center":[cx,cy],"radius":math.hypot(sx-cx,sy-cy),
            "startAngle":math.atan2(sy-cy,sx-cx),"endAngle":math.atan2(ey-cy,ex-cx)}
def vols(res, label):
    print(f"-- {label}: ok={res['ok']} warn={res.get('warning')} errs={res.get('evalErrors')}")
    for b in res["bodies"]:
        print(f"     {b['name']:<20} {b['volumeMM3']:>14,.0f} mm3  brep={b['brep']}")
def vol_of(res, body_id):
    # By id, never positional: a boolean keeps its target body, and a
    # non-fresh document can have any body sitting at index 0.
    return next(b["volumeMM3"] for b in res["bodies"] if b["id"] == body_id)

# ---- 1. Revolve: the rim cross-section, spun about world X ----
sk = X({"op":"sketch.create","args":{"name":"Wheel Section",
        "origin":[0,0,0],"xAxis":[0,0,1],"yAxis":[1,0,0]}})["sketchID"]
X({"op":"sketch.addEntities","args":{"sketchID":sk,"entities":[
 {"kind":"line","a":[25.4,0.0],   "b":[25.4,101.6]},
 {"kind":"line","a":[25.4,101.6], "b":[38.1,101.6]},
 {"kind":"line","a":[38.1,101.6], "b":[56.58968790064914,50.80000000020321]},
 arc(0.0,590.2502859691338, 56.58968790064914,50.80000000020321,
     266.6999999989331,117.93671024933405),
 {"kind":"line","a":[266.6999999989331,117.93671024933405],"b":[279.3999999988823,130.63671024928336]},
 {"kind":"line","a":[279.3999999988823,130.63671024928336],"b":[279.3999999988823,143.33671024923256]},
 {"kind":"line","a":[279.3999999988824,143.33671024923245],"b":[304.7999999987807,149.89054836488488]},
 {"kind":"line","a":[304.7999999987807,149.89054836488488],"b":[354.497334070397,158.65352923099285]},
 arc(355.5999999985776,152.39999999939036, 358.7749999985649,146.90073868538117,
     354.497334070397,158.65352923099285),
 {"kind":"line","a":[358.7749999985649,146.90073868538117],"b":[321.9012329005316,125.61165932529617]},
 {"kind":"line","a":[321.9012329005316,125.61165932529617],"b":[321.9012329005316,0.0]},
 {"kind":"line","a":[321.9012329005316,0.0],"b":[25.4,0.0]}]}})
X({"op":"sketch.addEntities","args":{"sketchID":sk,
   "entities":[{"kind":"line","a":[0,0],"b":[0,590.2502859691338]}],"construction":[0]}})
rev=X({"op":"feature.revolve","args":{"sketchID":sk,"seedPoint":[150,30],
       "axisPoint":[0,0],"axisDirection":[0,1],"angleDegrees":360}})
vols(rev,"Revolve"); wheel=rev["producedBodyIDs"][0]

# ---- 2. Spoke-hole cutter on the wheel face (sketch plane 02: normal +X) ----
sk2=X({"op":"sketch.create","args":{"name":"Spoke Holes",
       "origin":[0,0,0],"xAxis":[0,1,0],"yAxis":[0,0,1]}})["sketchID"]
X({"op":"sketch.addEntities","args":{"sketchID":sk2,"entities":[
   {"kind":"circle","center":[0.0,152.39999999939036],"radius":63.499999999746}]}})
cut=X({"op":"feature.extrude","args":{"sketchID":sk2,"seedPoint":[0,152.4],
       "distance":400,"symmetric":True}})
vols(cut,"Cutter"); cid=cut["producedBodyIDs"][0]

# ---- 3. Pattern the CUTTER 5x about the axle, then subtract ----
pat=X({"op":"feature.pattern","args":{"bodyID":cid,"kind":"circular",
       "axis":[1,0,0],"center":[0,0,0],"count":5,"totalAngleDegrees":288}})
vols(pat,"Pattern x5")
tools=[cid]+pat.get("producedBodyIDs",[])
sub=X({"op":"feature.boolean","args":{"kind":"subtract","targetBodyID":wheel,
       "toolBodyIDs":tools}})
vols(sub,"Subtract")

# ---- 4. Bolt holes: the 12.7 cutter, patterned with the spokes ----
# The recipe's Extrusion 01 extrudes BOTH circles of Sketch plane 02 in one
# step and Boolean 01 subtracts all ten cutters at once; a second
# extrude/pattern/subtract is geometrically equivalent. (Its −87.2665 slot is
# −5° in radians — a cutter taper we don't support, ignored like the cover's.)
sk3=X({"op":"sketch.create","args":{"name":"Bolt Holes",
       "origin":[0,0,0],"xAxis":[0,1,0],"yAxis":[0,0,1]}})["sketchID"]
X({"op":"sketch.addEntities","args":{"sketchID":sk3,"entities":[
   {"kind":"circle","center":[-44.7892362245073,61.647094971124375],
    "radius":12.699999999949195}]}})
bolt=X({"op":"feature.extrude","args":{"sketchID":sk3,
       "seedPoint":[-44.7892362245073,61.647094971124375],
       "distance":400,"symmetric":True}})
vols(bolt,"Bolt cutter"); bid=bolt["producedBodyIDs"][0]
pat2=X({"op":"feature.pattern","args":{"bodyID":bid,"kind":"circular",
       "axis":[1,0,0],"center":[0,0,0],"count":5,"totalAngleDegrees":288}})
vols(pat2,"Bolt pattern x5")
sub2=X({"op":"feature.boolean","args":{"kind":"subtract","targetBodyID":wheel,
       "toolBodyIDs":[bid]+pat2.get("producedBodyIDs",[])}})
vols(sub2,"Bolt subtract")
half=vol_of(sub2, wheel)

# ---- 5. Mirror across the hub face and fuse: the FULL wheel ----
# The revolve profile is the half cross-section (world x >= 0); Mirror 01 +
# Boolean 02 in the recipe double it into the finished wheel. The union
# meets only on the x=0 plane, so the fused volume must be 2x the half —
# a mirror that lands anywhere else, or a union that leaves a wall, shows
# up here as a volume error, not as a subtly wrong render.
mir=X({"op":"feature.mirror","args":{"bodyID":wheel,"planeOrigin":[0,0,0],
       "planeNormal":[1,0,0],"keepOriginal":True}})
vols(mir,"Mirror")
uni=X({"op":"feature.boolean","args":{"kind":"union","targetBodyID":wheel,
       "toolBodyIDs":mir["producedBodyIDs"]}})
vols(uni,"Union (full wheel)")
full=vol_of(uni, wheel)
drift=abs(full-2*half)/(2*half)
print(f"full wheel {full:,.0f} mm3 vs 2x half {2*half:,.0f} ({drift*100:.3f}% off)")
assert drift < 0.001, "mirror+union must exactly double the half wheel"
for r in (sub2, mir, uni):
    assert not r.get("evalErrors"), r.get("evalErrors")
print("\n4 motorcycle wheel: FULL recipe rebuilt (cutter tapers excluded).")
