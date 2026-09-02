# Spline as an exact profile — design

Status: **DESIGN + SLICE 0 LANDED (2026-09-02).** `CatmullRomBezier`
(`openshape3d/Kernel/CatmullRomBezier.swift`) converts the centripetal
Catmull–Rom to its exact cubic Bézier spans and integrates a closed
piecewise cubic's area exactly (3-point Gauss–Legendre on the degree-5
integrand); `CatmullRomBezierTests` pin it against `splinePoints` itself to
1e-9 (closed point-for-point, open interior, straight end spans, the
classic uniform tangent) and the area against a dense polygon. Slices 1–3
below are not started.

## Today

- A sketch spline is `SketchEntity.spline(id:points:closed:)`, drawn as a
  **centripetal Catmull–Rom** through every control point
  (`SketchEntity.splinePoints`).
- `ProfileDetector` has no spline notion: the samples are chained as a
  polyline, so a spline profile is `.polygonal` with an EMPTY `segments`
  (only arcs populate it), and the kernel builds a polyline wire.
- Consequences: an extruded spline has ~N facet walls (named
  `profileWall(entity: spline, occurrence: k)`), fillets on its "edges" hit
  facet creases, STEP export carries a polyline, and the B-rep-exact volume
  readback is exact for the wrong solid. The render mesh and the B-rep agree
  only because both are the polyline.
- The OCCT bridge has no B-spline curve construction (only the unify
  concat in `OS3DUnify…`).

## The one decision that matters: which curve

The kernel must build the curve the user sees, or the render, the B-rep,
hit-testing and every existing document disagree by up to the sagitta of a
span. Two ways:

1. **Keep Catmull–Rom as the definition; build it exactly.** A centripetal
   Catmull–Rom span between points Pᵢ, Pᵢ₊₁ (with neighbours Pᵢ₋₁, Pᵢ₊₂ and the
   centripetal knot spacing) is exactly one cubic Bézier — the conversion is
   closed-form (Yuksel/Schaefer/Keyser 2011; the same math `splinePoints`
   samples). So: per span, a `Geom_BezierCurve`; joined, one C1
   `Geom_BSplineCurve` via `GeomConvert_CompCurveToBSplineCurve`. The B-rep
   curve IS the drawn curve; nothing in any saved sketch changes shape.
2. Replace the definition with OCCT's `GeomAPI_Interpolate` B-spline and
   sample it for the render. Cleaner in the kernel, but every existing
   spline sketch changes shape slightly on the next replay and the sketch
   UI's own sampling would have to call into OCCT per frame.

**Choose 1.** Exactness without a migration, and the sketch layer stays pure
Swift. The conversion is a pure function unit-tested against
`splinePoints` (sampled Bézier == sampled Catmull–Rom to 1e-9).

## One wall per spline

Join the spans into ONE B-spline edge per spline entity (closed spline =
one periodic edge). Then a spline profile extrudes to **one smooth wall
face**, which is what a person expects to tap, fillet, or name:
`profileWall(entity: spline, occurrence: 0)`. Per-span edges would work in
the kernel but give N faces to select and N names to carry — the facet
problem in analytic clothing.

## Data channel

`Profile.Segment` gains an optional `controlPoints: [SIMD2<Double>]` (the
Catmull–Rom points of the span run from `start` to `end`; `mid` stays nil).
The bridge's segment record is today a fixed 7-double stride — `[kind,
start.x, start.y, end.x, end.y, mid.x, mid.y]`, kind 0 line / 1 arc — and
`SegWire` is its ONLY parser (`packSegments` its only writer). So a spline
is an INLINE variable-length record rather than a side blob: kind 2 (open)
or 3 (closed), then `count`, then `count` x,y pairs. `SegWire` walks
records by kind; lines and arcs stay byte-for-byte as they are, and no
bridge signature changes. For a kind-2/3 record `SegWire` converts the
points with the same Catmull–Rom → Bézier math as `CatmullRomBezier`
(re-derived in C++, pinned by a cross-language test that the kernel's
sampled edge equals `splinePoints`), builds one `Geom_BezierCurve` per span
and joins them with `GeomConvert_CompCurveToBSplineCurve` into ONE edge —
periodic for kind 3. `ProfileDetector` emits it for `.spline` chains (and fills
`segmentEntityIDs`, one entry per spline). Everything downstream that reads
`segments` — extrude, revolve, sweep, loft — gets exact splines for free;
`boundaryIdentity(wireEdge:wireEdgeCount:)` already maps one wire edge to
one segment.

## What does NOT change

- The render mesh keeps sampling Catmull–Rom — by construction the same
  curve, so mesh and B-rep agree as they do today for arcs.
- Draft/taper: the exact offset of a cubic is not a cubic. `SegmentOffset`
  returns nil for a spline segment and the draft takes the polygon path
  (documented in `DRAFT_TAPER_DESIGN.md`). Exact spline draft is not a goal.
- Persisted sketches: untouched. The memo is per session (empty on load),
  so a loaded document simply replays with the new kernel wire.

## Acceptance

1. Pure: Catmull–Rom → Bézier conversion reproduces `splinePoints` to 1e-9
   on open and closed splines.
2. Kernel: a closed-spline extrude is 2 caps + **1 wall** (`faceTypeCounts`
   total 3), and its B-rep volume equals height × the closed-form area of
   the piecewise cubic (Green's theorem over each Bézier span — a
   polynomial integral, so exact), to 1e-6.
3. Naming: that wall is `profileWall(entity: spline, occurrence: 0)`; a
   fillet on the cap/wall edge composes through as any other.
4. Stress: fillet a spline wall's edge on a curvature-varying spline; valid
   or graceful typed failure, never a crash (the existing blend stress
   harness).
5. Live: `/v1/exec` already accepts `spline` entities; the rebuild script
   for a spline-outlined part reads the exact volume.

## Slices

0. **Pure conversion + area** (Swift, no kernel): `CatmullRom.bezierSpans`
   and `closedArea`, tested against `splinePoints`.
1. **Bridge + channel**: `Segment.controlPoints`, `packSegments` record,
   `SegWire` B-spline edge (per-span Bézier → joined B-spline; periodic for
   closed), detector emission. Extrude test 2 above.
2. **Naming + draft fallback + docs**: one wall named; `SegmentOffset` nil
   for splines pinned by a test; `AGENT_CONTROL` note.
3. **Stress + a real part**: blend stress on spline walls; one catalogue
   part with a splined outline rebuilt and volume-checked.

Ledgered against the "spline-as-profile" line in `STATUS_AND_NEXT_STEPS.md`
§4 next missions.
