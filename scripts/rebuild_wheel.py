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

NOT a faithful 1:1 replica: the recipe's Mirror and second Boolean are not
replicated, and its 12.7 mm bolt-hole circle is unused.
"""

import json, math, urllib.request
def X(p):
    r=urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8787/v1/exec",
        data=json.dumps(p).encode(), headers={"Content-Type":"application/json"}), timeout=120)
    return json.load(r)
def arc(cx,cy,sx,sy,ex,ey):
    return {"kind":"arc","center":[cx,cy],"radius":math.hypot(sx-cx,sy-cy),
            "startAngle":math.atan2(sy-cy,sx-cx),"endAngle":math.atan2(ey-cy,ex-cx)}
def vols(res, label):
    print(f"-- {label}: ok={res['ok']} warn={res.get('warning')} errs={res.get('evalErrors')}")
    for b in res["bodies"]:
        print(f"     {b['name']:<20} {b['volumeMM3']:>14,.0f} mm3  brep={b['brep']}")

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
