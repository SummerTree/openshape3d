# Architecture & code review — 2026-08-25

Four parallel deep-review passes (editor/state, model/persistence,
kernel/OCCT, rendering/UI/concurrency) over the full app source, each
finding verified against the code with file:line evidence; the two most
severe claims were independently re-verified. Ordered by severity.
Companion to `STATUS_AND_NEXT_STEPS.md`.

## Fix status (same day, 2026-08-25 — see git log for the commits)

| Finding | Status |
|---|---|
| C1 data loss (load-skip + save-diff delete) | ✅ fixed — unreadable rows tracked & preserved, encode-failure guards, save errors surfaced |
| C2 no schema version | ✅ `Project.formatVersion` scalar; newer stores open read-only (save refuses) |
| C3 undo stomp from armed transform tools | ✅ `prepareForHistoryChange()` before undo/redo/rollback; sanitize case is now state-only |
| C4 dual-kernel path dependence | ✅ largely: brep carried through copy/resize/merge/archive (v2); extrude-cut + live boolean compose OCCT breps; live blend/shell branch on brep like eval. Remaining: revolve/sweep/loft-into-target stays mesh-only (OCCT has no revolve/sweep yet); `emitFullSolid` merges likewise |
| S1 main-thread geometry | ◑ prerequisites done (OCCT exception barrier on tessellation; BRepHandle Sendable caveat documented). The off-main eval/preview service itself is NOT done — next big tranche |
| S2 scene rebuilt per camera frame | ◑ `pullArrowState` extracted — orbiting no longer re-assembles the scene. Full scene caching, GPU buffer pooling, measurement caching still open |
| S3 lifecycle drift bugs | ✅ the four concrete bugs fixed (stale scaleEntry/axisEntry in `cancelTransientPicks`; unconditional pick-cancel in `deleteItem`; async boolean changeCount revalidation; empty provisional sketches removed on exit). The `ToolLifecycle` refactor itself is still open |
| S4 silent ref rebinding | ❌ open (margin check, nearest-edge OCCT matching, partial-resolution badges) |
| S5 numerical scale-dependence | ❌ open |
| S6 sketch edit + rebuild as separate undo steps | ✅ `performWithSketchRebuild` composes them for delete/trim/plane-change/constraint/dimension; residual: live drags (amended commands) and `lastEvalErrors` not restored on undo |
| Ship config | ✅ PrivacyInfo.xcprivacy bundled; deployment target 17.0; display name "OpenShape 3D"; ITSAppUsesNonExemptEncryption=NO; OS3D_* hooks behind `#if DEBUG`. Remaining: document types (`.os3d`/STEP in Files), real-device/archive testing |

---

## Critical

### C1. Silent permanent data loss: load-skip + save-diff deletes undecodable rows
`DocumentSession.load()` **skips** any row that fails to decode
(`guard let render = try? MeshBlob.decode(...) else { continue }` —
DocumentSession.swift:502; same `try?` pattern for sketches/planes/symbols
~:527-545 and features via `decodeFeature → nil` :560-565). `save()` then
**deletes** every persisted row whose ID isn't in the live document
(`for persisted in project.bodies where !liveIDs.contains(...) {
modelContext.delete(persisted) }` :636-638; same for features :750-752,
sketches, planes, images, symbols). So one corrupt byte, one unknown
`FeatureKind` case written by a newer build, or one `MeshBlob` version bump
(MeshBuffers.swift:95 requires exact equality) is not a graceful skip: the
first autosave (2 s debounce) after any edit permanently destroys the row.
`try? modelContext.save()` (:784) also swallows save failures, and
`(try? JSONEncoder().encode(...)) ?? Data()` (:647, :667, :690) can persist
an empty blob that becomes the next load's casualty.
**Fix direction:** carry undecodable rows as opaque unknowns (id + raw blob),
round-trip them on save, surface "N items couldn't be read"; never delete
what you couldn't parse. Log save failures.

### C2. No schema-versioning story for the JSON payloads
The SwiftData columns rely on defaulted-property additive migration only
(PersistenceModels.swift:33, :146, :181). The JSON payloads (`kindData`,
`sketchData`, `FeatureKind`'s synthesized Codable) carry **no version tag**,
so any non-additive evolution (rename an associated value, change `Expr`,
remove a case) throws at decode — and C1 then deletes the data.
`ProjectArchive` has a version gate (v1, refuses newer — good); the primary
SwiftData path has nothing. `MeshBlob` rejects `!=` its version rather than
handling older ones.
**Fix direction:** add a format-version scalar on `Project` + a version field
in the `FeatureKind` envelope now, while everything is still v1.

### C3. Undo while a transform-preview tool is armed re-applies stale transforms
`undo()` runs `session.undo()` **then** `sanitizeAfterHistoryChange()`
(EditorViewModel.swift:3162-3170), which for `.rotatingAroundAxis` calls
`cancelRotateAxis()` (:3231-3234) — and that writes `state.before`
transforms, captured **before** the undo, back into the document via
`session.preview` (:1797-1811), outside the undo stack. Sequence: translate
body → arm Rotate Around Axis → Undo → document reverts, then the baseline
restore stomps it back; Redo then double-applies. Same shape for
`.translating`/`.aligning`. Verified directly.
**Fix direction:** cancel previews *before* `session.undo()`, or store
baselines as "revert to committed document state" (re-read after undo)
instead of replaying snapshots.

### C4. The dual-kernel seam is path-dependent, not rule-based
Bodies only acquire a `brep` via feature-graph **replay**
(FeatureGraph.swift:368-378, :438-452, :548-554) or document reload.
Every **live** commit builds Euclid-only bodies with `brep = nil`
(`commitToolResult` EditorViewModel.swift:4904+, `runBoolean` :4017+,
`commitBlend` :2462+, `commitShell` :2651+), and `AppendFeatureCommand`
doesn't re-evaluate. Consequences:
- Extrude a circle live → 48-gon mesh body; nudge any sketch later → full
  replay silently swaps in the smooth OCCT cylinder and re-runs booleans
  through `BRepAlgoAPI` instead of Euclid. Geometry, tessellation, face
  signatures, and success/failure change on an unrelated edit.
- Live blend/shell on a brep body runs the mesh path the graph itself
  documents as broken ("Euclid asserts in debug, ships spiky facets" —
  FeatureGraph.swift:799-820); replay then routes the same node through
  `BRepFilletAPI`, which can *error* on a blend the user watched succeed.
  Shell likewise (planar-inset live vs OCCT replay, :881-885).
- Breps are silently dropped by: `.os3d` archive (no brep field —
  ProjectArchive.swift:32-40), Insert Project (ProjectMergeKit.swift:166-175),
  `duplicateSelectionForDrag` (EditorViewModel.swift:1505-1514),
  `ResizePrimitiveCommand` (Commands.swift:1074-1087), and the
  extrude-into-target / emitFullSolid replay branches
  (FeatureGraph.swift:458-495, :1044-1070) which compose meshes only —
  the next autosave then persists `brepData = nil`: a **permanent** smooth →
  faceted degrade.
(Note: `DocumentSession` does persist breps — `save()`:611 / `load()`:523 —
the STATUS doc's "B-rep persistence not done" is stale.)
**Fix direction:** one choke point for body geometry changes that either
updates or explicitly clears `brep`; make live tools call the same `eval*`
code the graph replays, so the kernel decision is per-operation, not
per-code-path; carry `brepData` through archive/merge/duplicate.

---

## Significant — systemic themes

### S1. All heavy geometry runs synchronously on the MainActor
Independently flagged by all four passes:
- `performRebuild` replays the **entire** feature graph inline on the
  MainActor on every parameter edit, suppress, reorder, variable change, and
  sketch drag-commit (DocumentSession.swift:219-241) — O(history) per edit,
  O(n²) over a session; FeatureGraph.swift:13's "replayed off the main
  actor" is aspirational.
- Preview CSG per drag tick: blend `blendValue.didSet` →
  `KernelOps.blendEdges` (EditorViewModel.swift:2359-2381), shell :2616-2637,
  extrude validity CSG :4355-4451, face pull union :4814.
- Autosave re-encodes the whole document (mesh blobs + `BRepTools::Write`
  ASCII breps) on-main every debounced 2 s with no dirty tracking
  (DocumentSession.swift:592-785).
- Sketch solver: dense LM (O(n³) Cholesky) + a second Jacobian for
  null-space analysis + a third SVD for DOF badges, rebuilt from scratch
  2-3× per interaction (SketchSolverBridge.swift:86-103, :560-647).
The correct pattern already exists in exactly one place: `runBoolean`'s
`Task.detached` + cancel token (EditorViewModel.swift:4028-4042).
**Fix direction:** one preview/eval computation service (serial background
executor, latest-wins cancellation, revision-tagged results) used by replay
and every drag preview; per-collection dirty tracking for save.
**Prerequisites before going off-main:** (a) OCCT tessellation/query paths
have **no C++ exception barrier** (`TessellateShape` OCCTBridge.mm:114-176,
`renderMeshFromShape:` :719-723 — constructive ops are wrapped, these
aren't; a degenerate shape = hard crash today, on the main success path via
`adoptBRep`); (b) `BRepHandle: @unchecked Sendable` claims immutability but
`BRepMesh_IncrementalMesh` mutates the shared `TShape`, and handles are
aliased by undo snapshots and identity transforms (OCCTKernel.swift:16-23,
:155-157) — serialize all OCCT access on one executor first.

### S2. The viewport scene is rebuilt from scratch on every camera frame
`EditorViewModel.scene` (~600 lines, :312-909) rebuilds every drawable,
re-tessellates every visible sketch, and — while sketching — runs a full
constraint solve via `entityStates` on **every access**. `ExtrudeGizmoOverlay`
is mounted unconditionally (EditorView.swift:705-708), observes `cameraEpoch`
(bumped per camera move, ViewportView.swift:672), and reads
`viewModel.scene.pullArrow` — so plain **orbiting** rebuilds the scene every
frame even with no tool active; a blend drag rebuilds it ≥3× per tick.
Related: per-frame `device.makeBuffer` for every sketch-line/fill batch
(Renderer.swift:234-238, :261-265); preview bodies re-upload all four GPU
buffers per tick (GPUResourceCache.swift:65-75); `selectionMeasurements`
walks every triangle per drag tick from `SelectionInfoBar.body`
(EditorViewModel.swift:8060-8093). Rebuilds also mint a fresh `meshRevision`
for **every** feature body (no changed-check, DocumentSession.swift:271-281),
so one parameter edit invalidates the GPU cache for the whole scene — and
each of up to 50 undo generations retains full unshared geometry snapshots
(UndoStack.swift:17).
**Fix direction:** cache the built scene keyed on (changeCount +
mode-relevant state); expose `pullArrow` as a cheap stored property; skip
no-op body replaces in rebuild; pool transient GPU buffers; cache
measurements per (bodyID, meshRevision).

### S3. EditorViewModel: 9,278 lines, ~30 hand-rolled tool lifecycles, 4 drifted cleanup registries
The same "clear transient state" concern is re-implemented with different
member lists in `cancelTransientPicks` (:2073), `sanitizeAfterHistoryChange`
(:3172), `deleteSelection` (:3097), `deleteItem` (:8451), `finishSketch`
(:6431). Concrete bugs from the drift:
- **Stale `scaleEntryActive`**: checked in `handleTap` before the mode
  switch (:3488-3497) but not cleared by `beginPattern`/`armBoolean`/
  `beginBlend`/`beginShell` — typing a scale factor then arming Pattern and
  tapping empty space commits a stray scale mid-pick.
- **Deleted-body ghost**: `deleteItem(.body)` only cancels picks for
  rotate/pattern (:8457); deleting the blend/shell source body from Items
  mid-pick leaves `blendPreview` rendering a ghost with the mode stuck.
- **Async boolean staleness**: `runBoolean` captures target/tool/`toolIndex`
  (an array index) before the await and commits without revalidation
  (:4017-4076); the "Computing…" card disables nothing, so undo/delete/move
  during the compute lands a command built from stale snapshots, and
  `BooleanCommand.revert` re-inserts at a wrong index (Commands.swift:140-143).
  `UndoStack.amendLast` (:34-41) can likewise swallow an unrelated command
  pushed by that async completion mid-drag.
- **Seam bypass**: `beginSketch` creates sketches via `session.preview`
  (:6405), not `AddSketchCommand` (which exists, Commands.swift:990, used
  only by DXF import) — an empty sketch created by tapping a plane and
  exiting can never be removed by undo. The only real DocumentCommand-seam
  violation found; the other 10 `preview` sites are legitimate transient
  drags.
- Blend vs Shell and the three Face* sessions are copy-paste families; the
  preview GPU-cache namespaces are scattered magic literals (`1<<62` blend,
  `1<<61` shell, `1<<60` face move).
- `mode`-embedded BodyIDs and `selection` are parallel state repaired by
  hand at every commit site; nothing prevents `mode == .selected(A)` with
  `selection == [B]`.
**Fix direction:** a `ToolLifecycle` protocol (arm/commit/cancel/sanitize)
with one registry every entry point iterates; a preview-namespace enum;
derive mode-IDs from selection (or a single `transition(to:)`); route all
async commits through a changeCount-guarded revalidation. Extraction order:
SceneBuilder, sketch editor (~2,450 lines), export/import, per-tool sessions.

### S4. Reference resolution silently rebinds instead of failing
- Face/edge resolvers pick best-score-above-threshold with **no runner-up
  margin** (TopoNaming.swift:146-167; EdgeTopology.swift:279-308): parallel
  same-normal faces tie on normal+area and are separated only by centroid
  proximity, so an upstream edit silently moves a pushPull/chamfer to a
  sibling face at high "confidence".
- `.derived(index:)` roles are **area-rank** ordered (TopoNaming.swift:310-315)
  — any edit reshuffling face areas renumbers them, making `roleBoost`
  point at the wrong face.
- OCCT edge targeting accepts **every** edge with a sample within tolerance
  (1-2% of the AABB diagonal, OCCTBridge.mm:504-521; FeatureGraph.swift:810,
  :897): on a 300×2 mm plate both rims match one pick.
- `evalEdgeBlend` silently `continue`s over unresolved edges — a 4-edge
  chamfer quietly becomes 3-edge (FeatureGraph.swift:781-789); missing hole
  loops in `resolveProfile` silently fill the hole with no badge
  (FeatureGraph.swift:1303-1333).
**Fix direction:** require a best-vs-second margin, else surface
`.brokenRef` for re-pick; nearest-edge (not all-within-tolerance) OCCT
matching; creation-stable derived indices; badge partial resolutions.

### S5. Numerical scale-dependence
- Absolute epsilons: cut tools padded 0.001-0.002 mm and shifted 1 µm off
  the sketch plane — **baked into committed geometry** (KernelOps.swift:112-123);
  boolean touch test `volume > 1e-4 mm³` absolute (EditorViewModel.swift:4926);
  `moveFacePlaneTolerance = 1e-3` absolute (KernelOps.swift:1105); OCCT
  deflection fixed 0.1 mm (OCCTKernel.swift:31-32).
- Blend-chain endpoint quantum 1e-5 on Float32 coordinates
  (KernelOps.swift:437-443, EdgeTopology.swift:42): beyond ~100 mm, Float
  ULP exceeds the quantum, rim chains shatter, and blends fall back to the
  overlapping-wedge path the swept-tool exists to avoid.
- Solver residual units are inconsistent (parallel/colinear scale as
  length², perpendicular as raw dot, distances linear —
  Constraints.swift:82-86, :206-231): the absolute 1e-3 over-constraint gate
  (EditorViewModel.swift:7149) can refuse satisfiable large sketches and
  pass conflicting small ones. `SketchSolverBridge.solve` discards
  `result.converged` entirely (:54-62).
**Fix direction:** one `modelEpsilon = k × bodyDiagonal` threaded through;
quantize relative to AABB; normalize solver residuals and make the gate
relative; surface convergence.

### S6. Sketch edits and their rebuilds are separate undo steps
`rebuildForSketchChange` lands as its own undo step
(DocumentSession.swift:203-211): one Cmd-Z reverts only the rebuild, leaving
new sketch geometry with old solids; a subsequent edit clears redo and the
desync is permanent until the sketch is touched again. A variable edit
produces up to 2+N separate steps (:441-495). `lastEvalErrors` is never
restored by undo/redo, so History badges go stale.
**Fix direction:** compose the sketch command with the rebuild diff via the
existing `performRebuild(leadingCommands:)`.

---

## Ship-configuration (documented in APP_STORE_READINESS.md, still ALL outstanding)
Verified 2026-08-25: no `PrivacyInfo.xcprivacy` anywhere in the tree
(UserDefaults is a required-reason API — submission blocker);
`IPHONEOS_DEPLOYMENT_TARGET = 26.2` (17.0 verified compiling in July);
no `CFBundleDisplayName`; no `ITSAppUsesNonExemptEncryption`; no document
types for `.os3d`/STEP/STL; `OS3D_*` debug hooks compiled into Release
(ProjectGalleryView.swift:121-123, EditorViewModel.swift:8540-8643).

## What's in good shape
On-demand rendering (paused MTKView + gesture depth counter) is correct;
GPU cache eviction is correct; projection math is single-sourced
(`worldToScreen`); OCCT bridge memory management is clean (single .mm TU,
ARC'd handles, `catch(...)` on constructive ops — no leaks/double-frees
found); the DocumentCommand seam holds everywhere except sketch creation;
selection-mutation discipline (gotcha #7) is honored; `AutoConstraintEngine`
is pure and clean; zero TODO/FIXME debt; MARK discipline and per-tranche
docs are excellent.

## Suggested priority order
1. **C1+C2** — data-safety: never delete unparseable rows; add format
   versions. Small, contained, protects every user document.
2. **C3** — undo stomp: cancel previews before `session.undo()`. Small.
3. **S3's concrete bugs** — stale `scaleEntryActive`, deleted-body ghost,
   async-boolean revalidation, `beginSketch` via command. Each small; then
   the `ToolLifecycle` refactor to stop the class of bug.
4. **C4** — unify live-commit and replay paths per op (start: extrude +
   boolean), carry breps through archive/merge/duplicate.
5. **S2** — scene caching + `pullArrow` extraction (biggest perceived-perf
   win for the least risk).
6. **S1** — off-main eval/preview service (after the OCCT exception barrier
   + handle serialization it requires).
7. **S4/S5/S6** — as they bite; S4's margin check and S6's composite are
   the cheapest of the three.
