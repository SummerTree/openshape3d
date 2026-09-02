#!/usr/bin/env python3
"""Rebuild a plate cam with a cycloidal motion law in openshape3d — spline slice 3.

A cam's working outline is not lines and arcs: it is the displacement law
made into a curve. This one (base circle r = 20, lift 10): cycloidal rise
over 0–180°, dwell 180–270°, cycloidal return 270–360°, so
r(φ) = 20 + 10·(φ/π − sin 2φ / 2π) on the rise, 30 on the dwell, and the
mirror on the return. The outline goes into the sketch as ONE closed spline
through 72 sample points (every 5°) with a Ø10 bore, extruded 8 mm.

Two checks, both exact in their own right:
  1. the B-rep volume equals the area of the INTERPOLATING SPLINE ITSELF
     (the same centripetal Catmull–Rom → Bézier chain the app builds,
     integrated Gauss-exactly here) × 8, to 1e-6 — the kernel built the
     curve it was given;
  2. that spline's area against the TRUE cam area (½∮r² dφ, fine
     quadrature) — the sampling error of a 5° spline, reported, not hidden.
Live DEBUG app; OS3D_PORT.
"""

import json, math, os, sys, urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('OS3D_PORT', '8899')}"
R0, LIFT, THICK, BORE = 20.0, 10.0, 8.0, 5.0
N = int(os.environ.get("CAM_N", 72))


def X(p):
    r = urllib.request.urlopen(urllib.request.Request(
        BASE + "/v1/exec", data=json.dumps(p).encode(),
        headers={"Content-Type": "application/json"}), timeout=300)
    return json.load(r)


def G(path):
    return json.load(urllib.request.urlopen(BASE + path, timeout=120))


def radius(phi):
    phi %= 2 * math.pi
    if phi <= math.pi:                                   # cycloidal rise
        return R0 + LIFT * (phi / math.pi - math.sin(2 * phi) / (2 * math.pi))
    if phi <= 1.5 * math.pi:                             # dwell
        return R0 + LIFT
    psi = (phi - 1.5 * math.pi) / (0.5 * math.pi)        # cycloidal return, 0..1
    return R0 + LIFT * (1 - (psi - math.sin(2 * math.pi * psi) / (2 * math.pi)))


# ---- the true cam area: ½ ∮ r² dφ, composite Simpson on 36,000 steps -------
M = 36000
true_area = 0.0
for i in range(M):
    a, b = 2 * math.pi * i / M, 2 * math.pi * (i + 1) / M
    m = (a + b) / 2
    true_area += (b - a) / 6 * (radius(a) ** 2 + 4 * radius(m) ** 2 + radius(b) ** 2)
true_area /= 2

# ---- the 72 sample points and the interpolating spline's EXACT area --------
pts = [(radius(2 * math.pi * i / N) * math.cos(2 * math.pi * i / N),
        radius(2 * math.pi * i / N) * math.sin(2 * math.pi * i / N)) for i in range(N)]


def spline_area(points):
    """Centripetal Catmull–Rom through `points` (closed) as cubic Béziers —
    the app's own construction (`CatmullRomBezier.spans`) — and Green's
    theorem with 3-point Gauss–Legendre, exact for the degree-5 integrand."""
    n = len(points)
    def sub(a, b): return (a[0] - b[0], a[1] - b[1])
    def add(a, b): return (a[0] + b[0], a[1] + b[1])
    def mul(a, s): return (a[0] * s, a[1] * s)
    def ln(a): return math.hypot(*a)
    spans = []
    for s in range(n):
        p0, p1, p2, p3 = [points[(s - 1 + k) % n] for k in range(4)]
        t1 = math.sqrt(ln(sub(p1, p0))); t2 = t1 + math.sqrt(ln(sub(p2, p1))); t3 = t2 + math.sqrt(ln(sub(p3, p2)))
        d1 = mul(add(mul(sub(p1, p0), (t2 - t1) / t1), mul(sub(p2, p1), t1 / (t2 - t1))), 1 / t2)
        d2 = mul(add(mul(sub(p2, p1), (t3 - t2) / (t2 - t1)), mul(sub(p3, p2), (t2 - t1) / (t3 - t2))), 1 / (t3 - t1))
        h = t2 - t1
        spans.append((p1, add(p1, mul(d1, h / 3)), sub(p2, mul(d2, h / 3)), p2))
    g = math.sqrt(3 / 5)
    nodes = [(0.5 - g / 2, 5 / 18), (0.5, 8 / 18), (0.5 + g / 2, 5 / 18)]
    area = 0.0
    for (c0, c1, c2, c3) in spans:
        for u, w in nodes:
            v = 1 - u
            bx = c0[0] * v ** 3 + 3 * c1[0] * v * v * u + 3 * c2[0] * v * u * u + c3[0] * u ** 3
            by = c0[1] * v ** 3 + 3 * c1[1] * v * v * u + 3 * c2[1] * v * u * u + c3[1] * u ** 3
            dx = 3 * (c1[0] - c0[0]) * v * v + 6 * (c2[0] - c1[0]) * v * u + 3 * (c3[0] - c2[0]) * u * u
            dy = 3 * (c1[1] - c0[1]) * v * v + 6 * (c2[1] - c1[1]) * v * u + 3 * (c3[1] - c2[1]) * u * u
            area += w * (bx * dy - by * dx)
    return area / 2


spl_area = spline_area(pts)
print(f"Cycloidal cam: base r {R0:g}, lift {LIFT:g}, {N} spline points, {THICK:g} thick, bore Ø{2 * BORE:g}")
print(f"   true cam area {true_area:.6f} mm2 | interpolating spline area {spl_area:.6f} "
      f"({(spl_area - true_area) / true_area * 100:+.5f}% — the 5° sampling error)")

# ---- build it ----------------------------------------------------------------
sk = X({"op": "sketch.create", "args": {"name": "Cam", "origin": [0, 0, 0], "xAxis": [1, 0, 0], "yAxis": [0, 1, 0]}})["sketchID"]
X({"op": "sketch.addEntities", "args": {"sketchID": sk, "entities": [
    {"kind": "spline", "points": [list(p) for p in pts], "closed": True},
    {"kind": "circle", "center": [0, 0], "radius": BORE}]}})
res = X({"op": "feature.extrude", "args": {"sketchID": sk, "seedPoint": [12, 0], "distance": THICK}})
print(f"   extrude ok={res.get('ok')} errs={res.get('evalErrors')}")
cam = res.get("producedBodyIDs", [None])[0]
if cam is None:
    print("RESULT: FAIL (no body)"); sys.exit(1)
body = next(b for b in G("/v1/state")["bodies"] if b["id"] == cam)
vol = body["volumeMM3"]
want_spline = (spl_area - math.pi * BORE ** 2) * THICK
want_true = (true_area - math.pi * BORE ** 2) * THICK
faces = G(f"/v1/faces?body={cam}")
health = G("/v1/check").get("invalid")
ok1 = abs(vol - want_spline) / want_spline < 1e-6
print(f"-- B-rep volume {vol:.6f} vs spline-exact {want_spline:.6f} ({(vol - want_spline) / want_spline * 100:+.7f}%)  {'OK' if ok1 else 'FAIL'}")
print(f"-- against the TRUE cam {want_true:.6f}: {(vol - want_true) / want_true * 100:+.5f}% (sampling)")
print(f"   brep={body['brep']} faces={faces.get('count', len(faces.get('faces', [])))} invalid={health} bounds={body['bounds']}")
ok = ok1 and body["brep"] and health == 0
print("RESULT:", "ALL PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
