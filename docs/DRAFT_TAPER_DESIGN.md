# Draft / taper angle on extrude — design (to land as its own mission)

Status: **SLICE 1 LANDED (2026-09-01)** — hole-free profiles, single
direction, through `feature.extrude` with a `taperDegrees` argument. A
40×40 square drafted 10° over 20 mm produces exactly 26,689 mm³ (the
analytic square-frustum volume), end to end through exec, valid B-rep, 0
invalid. Slices 2 (holes, symmetric) and 3 (curved boundaries) remain, per
the staging at the bottom.

## Why

Real cast and moulded parts have DRAFT: the walls of an extruded feature
taper by a few degrees so the part releases from the mould. Every catalogue
and tutorial part that hit this gap named it explicitly — the Shapr3D
Motorcycle-cover's two 10° tapers, the wheel-cutter's −5°, casting features
generally — and each was rebuilt "extruded straight, taper unexpressed",
leaving downstream volumes approximate by design. A straight prism is the
one thing the extrude path cannot vary; this closes it.

## The mined pattern (FreeCAD `Part::ExtrusionHelper::makeDraft`)

Patterns only, re-derived, never copied (LGPL → MIT; playbook rules).
FreeCAD's tapered pad is NOT a special kernel primitive — it is a **loft
between the base profile wire and an OFFSET copy of that wire** at the far
end of the extrude:

- The offset distance is `tan(angle) × length`. A positive angle expands
  the section as it rises; negative contracts it.
- The offset is a **2D wire offset** (each boundary edge moved
  perpendicular by the offset distance, mitred at the corners), applied to
  the section wire, which is then translated by the extrude vector.
- **Holes offset the OTHER way.** An inner (hole) wire gets the negated
  offset, so a hole in a draughted wall stays a consistent wall thickness.
  Inner-vs-outer is decided by containment (FreeCAD builds prisms and
  checks which sits inside which).
- A symmetric (both-directions) pad lofts through three sections —
  reversed-offset, base, forward-offset — so both ends draught from the
  sketch plane.
- **OCC gotcha FreeCAD flags:** the 2D offset of a SINGLE-EDGE wire (a
  circle) misbehaves, so a circular hole is treated specially (not negated).
  Any curved-boundary profile inherits this care.

## Path validated in openshape3d (2026-09-01)

Because `feature.loft` landed first, the pattern is already reproducible
through `/v1/exec` by hand: loft between a base rect and a smaller rect (the
offset section) on a plane `length` away. A 40×40 square draughted 10°
inward over 20 mm — offset `20·tan(10°) = 3.527 mm`, top side `32.95 mm` —
lofts to **26,689 mm³, matching the analytic square-frustum volume
`h/3·(A₁+A₂+√(A₁A₂))` to 0.00%**, valid B-rep, 0 invalid subshapes. So the
geometry approach is proven; what remains is to AUTOMATE the offset so a
caller gives an angle, not a hand-computed second profile.

## Proposed openshape3d design

1. **Model.** Add an optional `taperAngle: Expr` (degrees, default 0) to
   `FeatureKind.extrude`. Zero preserves today's straight-prism path
   exactly (and the `hasTaper` guard keeps the fast path for the common
   case, as FreeCAD does — a straight prism has planar walls and needs no
   B-spline loft). Codable stays back-compatible via `decodeIfPresent`.
2. **Offset kit.** openshape3d already has 2D sketch offset (the `Offset`
   tool / `SketchOffset`), which is the piece to reuse for the section
   offset. First slice: POLYGONAL / line-loop profiles only (offset the
   polygon boundary by ±`distance` with mitred corners); defer circular and
   arc/spline boundaries to a follow-on that carries the single-edge-wire
   care above.
3. **Eval.** `evalExtrude`'s taper branch: `distance_offset =
   tan(taperAngle) · height`; build the offset outer profile (holes
   negated) at the extrude height; `OCCTKernel.loftSolid([base, offset])`
   (the op the manual validation used); symmetric splits into the
   three-section loft. Non-taper stays the current prism.
4. **Naming.** Free: loft naming (landed 2026-09-01) already names a lofted
   solid's caps and its walls from the FIRST section's profile edges — the
   base profile — which is exactly right for a draughted wall.
5. **Exec.** `feature.extrude` gains an optional `taperDegrees`; the
   validation above is the acceptance test (angle in → analytic frustum
   volume out).

## Staging

- **Slice 1** (this doc's next step): `taperAngle` on extrude for
  hole-free POLYGONAL profiles, straight (non-symmetric) direction. Test:
  the 26,689 mm³ frustum, driven by an ANGLE not a hand offset.
- **Slice 2**: holes (negated offset), symmetric (three-section loft).
- **Slice 3**: circular / curved boundaries, carrying the single-edge-wire
  offset care FreeCAD documents.

Ledgered in `FREECAD_PLAYBOOK.md` (the `makeDraft` = loft-between-offset
pattern).
