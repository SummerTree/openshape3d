# Phase D — Parametric History Engine: Architecture & Tranche Plan

Companion to `IMPLEMENTATION_PLAN.md` (Phase D). Records the architecture chosen
after scouting the command/session/document/persistence/kernel layers and
validating Euclid's material/CSG behavior against its source.

## Decision summary

- **Goal:** a feature graph where the document is the evaluation result of
  replaying editable feature nodes, *including a topological-naming layer* so
  even face push/pull becomes an editable parametric feature (the user chose the
  most ambitious scope).
- **Topological naming is delivered behind a swappable `TopoNaming` facade.**
  Tranche 1 uses **geometric `SignatureNaming`** (re-resolve a face by
  centroid + normal + area after each rebuild). `MaterialTagNaming` (encode a
  stable tag in `Euclid.Polygon.material`) is a tranche-2 swap behind the same
  facade — it is deferred because the app's `EuclidBridge.renderMesh` and the
  "OS3D" mesh blob currently **drop** per-polygon material, so it needs a new
  `RenderMesh` tag channel + OS3D format v2. Geometric signatures need **zero**
  mesh-format change and are the ground-truth resolver regardless.
- **Integration is additive (Option B), not a source-of-truth rewrite.** The
  existing `DocumentCommand`/`DesignDocument`/`UndoStack` model stays intact
  (zero churn to the 357-test baseline and the 100+ `document` reads). A
  `FeatureNode` is recorded at each solid-modeling commit (recapturing the
  `ToolContext` params that are discarded today). Editing a step's parameter
  re-evaluates downstream and applies the diff through the existing
  `ReplaceBodyCommand`/`AddBodyCommand`/`DeleteBodiesCommand` in one undoable
  `CompositeCommand`.

## Why not the alternatives

- **Material-tag naming first:** Euclid *does* propagate `Polygon.material`
  through CSG (verified in Euclid 0.8.18 `Mesh+CSG.swift`, `Polygon+CSG.swift`),
  but `EuclidBridge.renderMesh` reads only position+normal and `MeshBlob` (OS3D
  v1) serializes only positions/normals/indices — the tag is lost at the render
  and persist boundaries. Adopting it requires a format migration; not worth the
  risk in tranche 1. Kept as a tranche-2 optimization (O(1) tag lookup) behind
  the facade.
- **Full source-of-truth rewrite:** rewriting all 33 commands + 74 `perform`
  sites + 100+ `document` reads, and forcing sketch/constraint/solver mutations
  (which are not feature-graph ops) through the graph, would break the baseline
  en masse. Rejected.

## Core contracts (tranche 1)

Persistent references (all `Codable, Hashable, Sendable`, `nonisolated`):

- `FeatureID { raw: UUID }`
- `BodyRef { producer: FeatureID; bodyID: BodyID }` — a feature output
- `ProfileRef { sketchID: SketchID; entityIDs: [UUID]; holeEntityIDs: [[UUID]]; seedPoint: SIMD2<Double>? }`
- `PlaneRef { source: .sketch(SketchID) | .construction(ConstructionPlaneID) | .ground | .explicit(SketchPlane) }`
- `AxisRef { source: .sketchLine(SketchID, UUID) | .explicit(RevolveAxis) }`
- `FaceRef { body: BodyRef; creator: FeatureID; role: FaceRole; signature: FaceSignature }`
- `FaceRole` = `boxFace(BoxFace) | cylinderSide | cylinderCap(top:) | sphereSurface | extrudeStartCap | extrudeEndCap | extrudeWall(loopIndex:,edgeIndex:) | derived(index:)`
- `FaceSignature { kind: .planar|.cylindrical(radius:); normal; centroid; area; planeOffset }`

Naming facade:

```
protocol TopoNaming {
  func faceTable(for: Body, createdBy: FeatureID, scheme: FaceScheme) -> FaceTable
  func propagate(inputs: [FaceTable], output: Body, op: TopoOp) -> FaceTable
  func resolve(_ ref: FaceRef, in: Body, table: FaceTable?) -> ResolvedFace?
}
struct SignatureNaming: TopoNaming { … }   // tranche 1
```

Graph model:

- `Expr { value: Double; formula: String? }` — struct now, so tranche-2
  expressions/variables need no schema change (`ExpressionEvaluator` exists).
- `BooleanIntent { op: .newBody|.union|.subtract|.intersect; resolvedTargets: [BodyRef] }`
  — the boolean decision is captured at commit, never re-derived by sample-point
  auto-detect, so replay is deterministic.
- `FeatureKind` (tranche 1 records/evaluates `primitive`, `extrude`, `boolean`,
  `pushPull(.planarAxial)`; `revolve/sweep/loft/transform/mirror/pattern`
  defined but recorded/evaluated in tranche 2):
  `primitive(spec:,placement:) | extrude(profile:,plane:,distance:Expr,symmetric:,boolean:,extraProfiles:) | revolve(...) | sweep(...) | loft(...) | boolean(kind:,target:,tools:) | transform(...) | mirror(...) | pattern(...) | pushPull(face:FaceRef,distance:Expr,mode:)`
- `FeatureNode { id: FeatureID; name; kind: FeatureKind; suppressed; outputBodyIDs: [BodyID] }`
  — `outputBodyIDs` are minted once and reused on every rebuild so selection /
  transform / material survive.
- `FeatureGraph { nodes: [FeatureNode] }`; `evaluate(sketches:planes:naming:) -> EvalResult { bodies; faceTables; errors }` — linear replay in order.

Session seams (additive):

- `DocumentSession`: `graph: FeatureGraph`, `naming: TopoNaming = SignatureNaming()`,
  `record(_ node:)`, `rebuildFrom(_ id:)` (evaluate → diff → `perform(Composite)`).
  `perform/amend/preview/undo/redo` unchanged.
- `Commands.swift`: new `EditFeatureCommand { featureID; before: FeatureKind; after: FeatureKind }`
  bundled inside the rebuild `CompositeCommand` so one undo reverts both meshes
  and node params.
- Persistence: `PersistedFeature @Model { featureID (unique); orderIndex; name;
  suppressed; kindData (JSON); outputBodyIDData (JSON); project }` +
  `Project.features` cascade + schema registration. Pre-Phase-D projects load as
  an empty graph (bodies render from their baked `PersistedBody` meshes; the
  graph evaluates only on edit) — following the `decodeIfPresent ?? default`
  convention so old stores open with no error.

UI: `HistoryPanelView` (ordered rows, select/rename/delete/suppress/zoomTo,
edit-param → rebuild, broken-ref badge) attached beside the Items panel.

## Invariant (tested)

After any `record`/`rebuildFrom`, for every feature-owned `BodyID`:
`document.bodies[id].render == evaluate().bodies[id].render`. Non-feature bodies
(imported STL, copies, debug seed) coexist untouched until tranche 2.

## Tranche 1 proof

primitive box → extrude (new body) → boolean subtract → push/pull a planar
face. Then edit the extrude distance → box, boolean, and push/pull all rebuild,
and the pushed face's `FaceRef` still resolves to the moved face and re-applies
its own distance. This proves topological naming end-to-end.

## Deferred to tranche 2+

`Expr.formula` + variables/expressions; reorder / insert-at / rollback
breakpoints; recording+eval of revolve/sweep/loft/transform/mirror/pattern;
true boolean-membership associativity; sketch-edit → auto-rebuild; `EdgeRef`
resolution; `MaterialTagNaming` (needs RenderMesh tag channel + OS3D v2);
linked/instanced copies; fillet/chamfer (needs the Phase E kernel).
