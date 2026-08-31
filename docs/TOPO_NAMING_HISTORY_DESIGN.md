# Kernel-history element naming — design (to land as its own mission)

Status: **STEP 1 LANDED** (2026-08-31); steps 2–5 remain design. Landed as
two slices, both zero-behavior-change and fully gated:

- **1a** — per-triangle OCCT face channel on `OCCTRenderMesh`
  (`faceIndices`, `OCCTKernel.renderMeshFaceChannel`), 1-based indexed-map
  numbering shared with the health report. `RenderMeshFaceChannelTests`.
- **1b** — boolean ancestry: `booleanOfShape:…history:` fills an
  `OCCTShapeHistory` (packed rows: result face ← input sub-shape, relation
  same/modified/generated), composed across the `UnifySameDomain` hop via its
  own `History()`, every row validated against the FINAL shape (the phantom
  gate), higher-level reports demoted to faces, history queries
  try/catch-wrapped (OCCT throws on unknown sub-shapes). Swift face:
  `ShapeAncestry` + `OCCTKernel.booleanResultWithAncestry`.
  `ShapeAncestryTests` pins the two-hop case (fused tower's merged walls
  list BOTH parents) and tool-only bore-wall descent.

The per-op reliability catalog mined from FreeCAD's Mapper classes (which
OCCT history calls to trust per op, known gaps, workarounds) is preserved in
the 2026-08-31 session research; headline rules now encoded in
`OS3DCollectMakerHistory`/`OS3DFillHistory`: wrap every history query,
validate in-result, demote higher-level reports, treat absence as "history
doesn't know" and fall back to signatures. Note one design correction:
FreeCAD does NOT route history through `ShapeUpgrade_UnifySameDomain` (it
uses its own FaceUniter); our two-hop composition rides OCCT's documented
`History()` with the in-result gate as the safety net — watch it.

Prerequisites landed in the FreeCAD-hardening tranche: boolean result
normalization (single-solid unwrap + unify, `OCCTBridge.mm`), deterministic
face basis + `FaceSignature.kind` honored in resolve (R4-N1/N4 — tranche 2).

## Why

`SignatureNaming` matches faces across rebuilds by geometric scoring
(centroid/normal/area + role boosts). Six documented defects follow from that
(ARCHITECTURE_REVIEW_2026-08-25 R4-N1..N6): refs re-bind to wrong faces after
rebuilds, reorders, or relaunches, and `propagate` can hand a parent's label to
a face that never belonged to it. This is the "editing an earlier feature
breaks later ones" pain — the topological naming problem.

FreeCAD solved it for 1.0 with realthunder's element maps: names are derived
from the KERNEL'S OWN history (`BRepBuilderAPI_MakeShape::Modified() /
Generated() / IsDeleted()`, BOPAlgo history, `UnifySameDomain::History()`),
not from geometric resemblance. Since OCCT is now openshape3d's source of
truth, the same history is available through `OCCTBridge`.

Reference (patterns, never code — LGPL): `src/Mod/Part/App/TopoShapeExpansion.cpp`
(the `Mapper`/`MapperMaker`/`MapperHistory` classes are a catalog of WHICH
OCCT history calls are trustworthy per op, including the known `Generated()`
gaps), `src/App/ElementMap.h/.cpp` (name-composition concept),
realthunder's topological-naming docs, FreeCAD wiki "Topological naming problem".

## Shape

**Layer `HistoryNaming` UNDER `SignatureNaming` — never replace it.**

1. **`OCCTShapeHistory`** (bridge): additive `...WithHistory` variants of the
   mutating ops return the result shape plus, per output face index, its
   ancestor list `(inputOrdinal, inputSubshapeIndex, relation)` where relation
   ∈ {modified, generated, same}, plus the deleted-input list. Built with
   `TopTools_IndexedMapOfShape` over inputs/output. For blends, history is
   indexed per input EDGE (blend faces are Generated from edges). Compose
   across the `unified()` step via `ShapeUpgrade_UnifySameDomain::History()`
   (two-hop composition).
2. **`ElementName`** (new `openshape3d/Model/ElementNaming.swift`): small
   Codable/Hashable value composed from persisted stable IDs the app already
   owns — `FeatureID` creator, sketch-entity `UUID` source, `FaceRole`, op tag,
   disambiguator index. No string grammar, no hashing (graphs are small).
   Examples: extrude wall = `(creator: extrudeNode, source: sketchLine UUID)`;
   boolean survivor inherits its parent's name; a genuinely new section face =
   `(op: cut(node), parent: <input name>, k)` with `k` from deterministic
   `TopExp` order.
3. **Tessellation face channel**: `OCCTRenderMesh` gains a per-triangle
   OCCT-face-index array (`TessellateShape` already iterates per face — the
   channel is nearly free). Names attach to the EXISTING mesh-derived
   `FaceTable` entries by majority triangle vote. `FaceTable` is rebuilt every
   evaluate and never persisted ⇒ zero persisted bytes change.
4. **Name-first resolve**: `FaceRef.elementName: ElementName?` and
   `EdgeRef.faceNames` (unordered adjacent-face-name pair + occurrence index)
   as `decodeIfPresent` optionals — old documents load unchanged. Resolution:
   exact name hit → confidence 1.0; miss → today's signature scoring WITH the
   S4 margin check; both miss → honest `.brokenRef` badge. Signatures stay
   mandatory and their math untouched — that is the migration story.
5. **Opportunistic ref upgrade**: when a signature-resolved ref matches with
   high confidence AND margin, write `elementName` back during the next
   legitimate rebuild command (rides undo machinery; never an out-of-band
   mutation).
6. **Edge identity for blends**: resolve `EdgeRef.faceNames` against the input
   body's OCCT edges via adjacent-face names; `evalEdgeBlend` then picks OCCT
   edges BY IDENTITY (new bridge entry `filletedShape:edgeIndices:radius:`)
   instead of midpoint-within-tolerance. This is the single biggest
   "rebuild broke my fillet" fix.

## Sequencing (S/M/L)

1. (M) Bridge history exposure + face-index tessellation channel.
2. (M) `ElementName` + creation-op naming (primitives, extrude, revolve).
3. (L) Boolean history through `evalBoolean`/`evalExtrude` cut branch +
   `HistoryNaming` wrapper composing maps across `unified()`.
4. (M) Name-first resolve + additive ref fields + opportunistic upgrade +
   edge names / identity-based blend targeting.
5. (M) Modifier-op history (fillet/chamfer/shell/deleteFace/replaceFace) —
   today these relabel `.generic`, destroying all names downstream.

Out of scope forever: mesh-only bodies (Euclid sweeps, holed lofts, STL/OBJ
imports) stay pure `SignatureNaming`; pattern copies share the source's map.

## Risks

- **A wrong name match is worse than a broken ref.** Names are unique per
  body by construction; during bake-in, sanity-check name hits against the
  signature and debug-assert on disagreement.
- **OCCT history has gaps** (`Generated()` on some BOPAlgo section-face
  paths; UnifySameDomain merge renames). Mine FreeCAD's Mapper classes for
  the known workarounds instead of rediscovering them.
- **Blast radius**: every eval site changes, but op-by-op, each with a
  "no history → today's behavior" fallback. No flag day; steps 1–2 ship with
  zero user-visible resolution change.
