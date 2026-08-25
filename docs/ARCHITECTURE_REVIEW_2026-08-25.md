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

---

# Round 2 (same day) — five deeper passes

Round 1 covered the four layers architecturally. Round 2 went into the areas
it skipped — import/export parsers, the sketch subsystem, the secondary
geometry kits, rendering internals/UI panels — plus an ADVERSARIAL pass over
round 1's own fixes. Findings below; the round-1 report follows unchanged.

## R2 fixed immediately (committed same day)

### R2-C1. Any oversized or NaN coordinate crashed the app — 20 sites, 6 files ✅ FIXED
`Int32((v * 1e5).rounded())` **traps** on a non-finite value or past
±21.47 m of model space. It appeared in every vertex-weld key in the
codebase: `EuclidBridge` (render weld), `FeatureEdges`, `FaceTopology`
(runs for every vertex on every face tap), `EdgeTopology` (×2), and — worst
— **`STLImporter` and `OBJImporter`**, i.e. exactly where a metre- or
inch-unit file's coordinates arrive. A degenerate kernel op emitting one
NaN (the sweep can, see R2-6) did it too. Not a wrong result: a hard,
non-catchable crash while merely building a mesh.
**Fixed:** one clamped `MeshQuantize.key` helper, used at all 20 sites.
Note the first attempt was itself buggy — `Float(Int32.max)` rounds UP to
2^31, so a Float-space clamp still traps; the new test caught it on the
first run. Clamping is done in Double space, which represents both bounds
exactly.

### R2-C2. A shared `.os3d` file could crash on open ✅ FIXED
`MeshBlob.decode` validated byte LENGTHS but never index VALUES
(MeshBuffers.swift). Every consumer subscripts `positions[index]` directly
(`HitTester`, `FaceTopology`, `EdgeTopology`) and Metal reads the buffer
raw, so one corrupt or hostile index trapped on first touch — and `.os3d`
is a shareable document type. **Fixed:** decode now rejects a non-multiple
-of-3 index count and any index ≥ vertexCount.
(`MeshBuffers` had zero tests; it now has 14, including the malformed-input
cases and the extreme-coordinate weld.)

### R2-C3. My own C1 fix leaked at COLUMN granularity ✅ FIXED
The adversarial pass caught this: round 1 protected whole ROWS, but
`primitiveData`/`materialData`/`brepData` decode with `try?` per column —
a failure yields nil, the row is fine so it wasn't tracked, and `save()`
wrote that nil back over the blob. A truncated brep, or one written by a
newer OCCT, was therefore destroyed by the next autosave: exactly the
"recoverable skip → permanent loss" C1 set out to stop. **Fixed:** column
failures are tracked and those columns are left untouched on save, with a
separate, honest warning ("N shape(s) opened without some detail…").

### R2-C4. C3's undo-stomp fix covered only 3 of 8 entry points ✅ FIXED
`prepareForHistoryChange()` guarded undo/redo/rollback, but `deleteFeature`,
`setFeatureSuppressed`, `moveFeature`, `editFeature*`, `editPatternFeature`
and `variablesDidChange` all reach the same rebuild and stomp the same way.
**Fixed:** all now guard; the three that remove geometry also sanitize
(the History-panel twin of the Items ghost-preview bug, likewise fixed).

Also fixed: `ResizePrimitiveCommand` silently dropped `isHidden`/`material`;
the gallery multi-delete's silent `try?` now surfaces failures and resolves
projects via the live query instead of `model(for:)` (which can trap).

## R2 open — highest value first

**R2-1 (CRITICAL, unfixed): a radial cylinder drag silently deletes
features.** `FaceTopology.matchesWholeBody` accepts "this body IS a
cylinder" on a volume ratio > 0.95 with no upper bound and no shape check,
so a cylinder with a boss, pocket, hole or chamfer under ~5% of volume
qualifies; `faceModifiedMesh` then **discards the source mesh** and rebuilds
a clean cylinder. Dragging a drilled cylinder's wall destroys the drilling,
under an undo entry labelled "extrude". Fix: require the fit to explain all
triangles, or edit by boolean rather than whole-body rebuild.

**R2-2 (CRITICAL, unfixed): deleting or trimming a sketch entity orphans
its constraints and dimensions.** `RemoveSketchEntitiesCommand` and
`TrimCommand` touch `entities` only — verified. Trim is worse: fragments get
fresh UUIDs, so a trimmed line's constraints dangle although the geometry is
still on screen. Dangling refs are then dropped SILENTLY by the solver, so a
driving dimension quietly stops driving while still displaying its value.

**R2-3 (CRITICAL, unfixed): solver results are written back without ever
checking convergence.** `SketchSolverBridge.solve` discards
`SolveResult.converged` (independently flagged in round 1). The drag path has
no gate at all, so on a conflicting system LM's best-fit compromise is
amended into the document every frame.

**R2-4 (SIGNIFICANT): `FaceTopology`'s planar basis depends on randomised
Dictionary order** — `loops3D[0]` may be a hole, and Swift seeds hashing per
process, so a face's `origin`/`basisX` differ across launches. Those feed
`TopoNaming.signature` directly, undermining the identity guarantee that is
the whole point of topological naming.

**R2-5 (SIGNIFICANT): Y-up model written into Z-up STL and 3MF with no axis
conversion** — parts arrive in slicers lying on their side. GLB/USDZ are
correct, so the codebase is inconsistent rather than uniformly wrong.

**R2-6 (SIGNIFICANT): sweep emits NaN geometry when the spine reverses** —
the mitre factor is clamped but the bisector is not; `simd_normalize` of a
zero vector yields NaN, which propagates into the body mesh (and used to
crash the weld, R2-C1).

**R2-7 (SIGNIFICANT): loft twists on non-parallel sections** — Euclid's
alignment pass is skipped for equal-count rings unless the sections are
parallel; `SweepLoftKit` doesn't compensate, so a CAD loft between tilted
sketches can twist up to half a turn or bow-tie.

**R2-8 (SIGNIFICANT): Wrap/Emboss drops the profile's end walls** — the cut
-edge test matches real profile edges at the x-extremes, and the result never
gets `.makeWatertight()`. The tests miss it because the fixture is centred on
the origin, where the missing faces contribute exactly zero signed volume.
(Kit is test-only today — no call sites.)

**R2-9 (SIGNIFICANT): sketch-stroke lines render at HALF their intended
width** — the NDC↔pixel conversion in the shader uses `viewport` where one
NDC unit is `viewport/2` px. This is the hairline complaint the thick-line
pipeline was written to fix.

**R2-10 (SIGNIFICANT): the tool palette moves under in-flight taps** — it is
vertically centred with a live `bottomBarInset`, so any bottom-bar height
change shifts every button by half the delta, and the flyout animates
horizontally for 180 ms. This is the root cause of the UI-test flake class
fixed today with settle-waits; two one-line hardenings (anchor top-leading,
use an opacity transition) would remove it at the source.

**R2-11 (SIGNIFICANT): thumbnail capture submits GPU work in `.background`
and blocks the main thread on `waitUntilCompleted`** — a watchdog shape.
Good news from the same check: **`scenePhase` DOES force a `save()`**, so the
2-second autosave debounce is not a data-loss window.

**R2-12 (SIGNIFICANT): my blend/shell OCCT preview may have made drags
heavier** — the live preview now runs an OCCT fillet + full re-tessellation
per drag tick. The claim is plausible but UNMEASURED (the previous Euclid
path ran dozens of CSG subtractions for a rim chain, so it may even be
faster). Measure before changing; the proper home is the S1 off-main
preview service.

**R2-13 (SIGNIFICANT): gizmo ring rotation cannot exceed ±180°** — found
directly, not by an agent. `rotationDelta` wraps to (−π, π] and both
consumers pass it through as an ABSOLUTE angle from the drag anchor, so
circling past half a turn snaps the body backwards ~358°. Fix: accumulate
the unwrapped angle in the drag session.

**Also open:** `enumerateFaces` is O(faces × triangles) (rebuilds the whole
adjacency map per seed; three per body tap); negative face pull runs two full
CSG subtractions + two heals per drag frame; `MeasureKit.boundingBox` reports
an inflated box for rotated bodies while claiming correctness; the
read-only-store guard is leaky (`saveThumbnail` mutates `project.thumbnail`,
flushed by SwiftData's own autosave); a brand-new row that fails to encode is
skipped with no warning; `amendLast` still has no interaction-identity check
(all four call sites are correctly guarded today, and today's changeCount
guard closed the known async offender); OBJ import is complete and tested but
**unreachable from the UI** while the status doc lists it as shipped.

**Test-coverage gaps:** `UndoStack`, `MeshBuffers` (now covered),
`TopoNaming`, `PersistenceModels` and both gesture controllers have no unit
tests; and none of today's fixes had a regression test pinning the new
behavior until the MeshBlob suite landed. The SwiftData-in-XCTest crash makes
`DocumentSession` untestable in-process — extracting the save-diff deletion
rule as a pure function would make the most dangerous logic testable.

---

# Round 1

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
