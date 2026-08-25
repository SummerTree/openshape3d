# Status & Next Steps — Handoff Notes

Last updated: 2026-07-21 (after commit `ee5baee`). This is the living handoff
document: what is DONE, how the newest subsystems work, the dev workflow, and
the prioritized next missions. Companions: `IMPLEMENTATION_PLAN.md` (original
phase plan), `SHAPR3D_PARITY_SPEC.md` (feature spec), `PHASE_D_DESIGN.md`
(feature-graph design).

---

## 1. Where the project stands

| Phase | Status |
|---|---|
| **A** — planes, sketch tools, revolve, transform, items, views, IO | ✅ done |
| **B** — sweep, loft, split, pattern, offset, text, project, section, display, selection, materials, symbols | ✅ done |
| **C** — 2D constraint solver (Levenberg–Marquardt), dimensions, auto-constrain, DOF coloring, sketch mirror | ✅ done |
| **D** — parametric feature graph: topo naming, all creation ops, sketch associativity, variables/expressions, pattern-as-feature, rollback, **reorder + suppress** | ✅ done (tranches 1–6) |
| **E** — edge blends (mesh-domain): chamfer/fillet, multi-edge, live preview, drag-to-size arrow | ✅ tranches 1–3 done |
| **E (B-rep)** — OpenCASCADE port for high-quality fillet/shell/offset | ❌ not started |

**Architecture review (2026-08-25): `ARCHITECTURE_REVIEW_2026-08-25.md`** —
four-pass deep review; criticals: silent data loss on save of undecodable
rows, no schema versioning, undo-stomp from armed transform tools, and the
path-dependent Euclid-vs-OCCT kernel seam. Read it before the next tranche.
**Same-day fix pass:** all four criticals fixed (C4 largely — see the fix
table in the review doc), plus the S3 lifecycle bugs, S6 composite undo,
the OCCT exception barrier, the `pullArrowState` orbit-perf fix, and every
ship-config item (privacy manifest, iOS 17.0 target, display name,
encryption key, `#if DEBUG` hooks).

**Round 2 (same day, deeper + adversarial):** fixed two crash-on-input
classes — an `Int32` weld-key trap at **20 sites in 6 files** (including
both importers: any model past ±21 m or containing a NaN crashed on
import/tap) and `MeshBlob.decode` accepting out-of-range indices (a shared
`.os3d` could crash on open). The adversarial pass over round 1's own fixes
found and closed three real gaps in them: C1 leaked at column granularity
(brep/material/primitive blobs were still being nil-ed over), C3's guard
covered only 3 of 8 history-mutating entry points, and the ghost-preview fix
missed the History-panel delete. **Read the R2 open list before the next
tranche** — it includes two criticals (a radial cylinder drag silently
deleting features; sketch delete/trim orphaning constraints so a driving
dimension quietly stops driving) and an unvalidated-solver-writeback issue.
Still open from round 1, in rough order: off-main eval/preview service (S1),
full scene caching + GPU buffer pooling (S2), `ToolLifecycle` registry
refactor (S3), ref-resolution margin checks (S4), relative epsilons (S5).

Also landed recently (all on `main`): context-sensitive Shapr3D-style tool
palette with flyout groups; extrude gizmo = SF Symbol `arrow.up.and.down` +
value pill; drag-reorder of History rows; bug-hunt regression tests.

Sketch/select UX pass (2026-07-21):
- **Orbit mid-sketch**: `EditorMode.sketching`'s tool is now OPTIONAL. Tapping
  the active sketch tool deselects it (same toggle pattern as CreateTool);
  with no tool armed, empty-space drags orbit (taps still select, drags on
  entities/gizmo still edit), so a plane can be sketched from any angle —
  the existing "Look at Sketch" pill button restores head-on. Re-opening a
  sketch from Items now starts with no tool armed.
- **Profile tap arms extrude at 0 mm** (`startExtrude`): pull arrow + bar
  only, no default 2 mm slab; committing at 0 cancels. UI tests type a height
  via the shared `typeExtrudeHeight(_:)` helper (`PullArrowTestSupport`).
- **Select mode selects sketch entities**: tap fallback
  (`toggleSketchEntityUnderRay`) + marquee candidates now built for the
  Sketches-only filter too (was `filter == .bodiesAndSketchEntities`).
- **Consumed sketches auto-hide again (2026-08-25, reversing 2026-07-21)** —
  the user ruled the stay-visible behavior a bug vs Shapr3D: a tool that
  makes a body now hides every sketch that fed it (profile + loft sections +
  sweep spine) via `consumedSketchHideCommands`, in the same undo step. The
  Items eye (a11y value "hidden"/"visible") brings a sketch back.
- **Delete works on Select-mode sketch picks** (`deleteSelection`): selected
  sketch entities delete outside sketch mode too (bodies + entities in one
  undo step); the palette Delete button enables for them; a plain tap
  elsewhere clears a stale sketch-entity highlight.
- **Extrude no longer grabs flush neighbors** (`commitToolResult`): the
  auto-boolean "touch" test now requires real overlap VOLUME
  (`KernelOps.volume(of:)` on the intersection > 1e-4) instead of any
  intersection polygon — bodies sharing a flush wall produced zero-volume
  slivers that falsely counted as touching. Covered by
  `PushPullKernelTests.testFlushPrismsHaveNoIntersectionVolume`.
- **Orientation Cube = universal orbit control** (`ViewportView.
  gestureDragBegan`): a drag starting on the cube orbits the camera in every
  mode (checked before all mode-specific drag handling); a tap still snaps to
  the view. See spec §7.2.

**Test baseline: 464 unit tests, ~78 UI tests — all green.** Two UI tests
(`FaceFlowUITests/testTypeNegativeIntoArrowPill`,
`SweepLoftUITests/testSweepCircleAlongTwoSegmentLinePath`) are long-run flaky
(pass in isolation) — rerun individually before suspecting a regression.

---

## 2. Architecture of the newest subsystems (Phase E blends)

The mesh-domain chamfer/fillet the spec §4.3 blesses for prismatic edges.
Everything routes through the same three seams as the rest of the app:
`KernelOps` (geometry), `DocumentCommand` (mutation), `EditorViewModel`
(state machine).

- `openshape3d/Kernel/EdgeTopology.swift` — `SelectableEdge` (endpoints + the
  two adjacent face normals + convexity); `selectableEdges(from:)` welds
  positions and merges collinear same-face-pair creases into maximal straight
  edges; `signature(of:)` / `resolve(_:in:sizeScale:)` re-find an edge after a
  rebuild (adjacent-face-normal PAIR dominates the score).
- `openshape3d/Kernel/KernelOps.swift` — `chamferEdge` (subtract a triangular
  corner-wedge prism), `filletEdge` (subtract the corner parallelogram MINUS a
  tangent cylinder **centered on the edge** — Euclid's `extrude` is centered,
  so the cylinder must be too).
- `openshape3d/Model/FeatureRefs.swift` — `EdgeRef`/`EdgeSignature`.
- `openshape3d/Model/FeatureGraph.swift` — `FeatureKind.chamfer/.fillet`,
  `evalEdgeBlend`: resolves `EdgeRef`s against the **input** body (a blend
  destroys the edge it names), errors → History badge. JSON-Codable kinds, so
  no schema migration was needed.
- `openshape3d/Editor/EditorViewModel.swift` — blend section:
  `beginBlend/handleBlendEdgeTap/commitBlend/cancelBlend`, live `blendPreview`
  (recomputed on edge toggle + `blendValue` didSet, rendered IN PLACE of the
  source body, high-bit GPU-cache revision `(1<<62)|n`),
  `beginBlendDrag/updateBlendDrag/endBlendDrag`, `resetBlendState()` (state
  only — **never mutates `selection`**; wired into `cancelTransientPicks` and
  `sanitizeAfterHistoryChange`).
- `openshape3d/UI/ViewportView.swift` — `.pickingBlendEdges` drag branch:
  geometric screen-space arrow grab (same as face push/pull); drag delta
  projects onto the arrow's **on-screen** direction × `worldUnitsPerPoint`.
- `openshape3d/UI/EditorView.swift` — `blendBar` replaces `NumericInputBar`
  in the bottom stack while picking (never two bottom overlays — see gotchas).
- Arrow rendering is free: publishing `scene.pullArrow` during the pick makes
  `ExtrudeGizmoOverlay` draw the handle; `extrudeArrowLabel` is nil in blend
  mode so no extrude pill appears. `isValid=false` (preview ate the body)
  renders it red, and `canCommitBlend` disables Apply.

Tests: `openshape3dTests/KernelBlendTests.swift` (exact volumes),
`openshape3dTests/FeatureBlendEvalTests.swift` (parametric eval, edit-rebuild,
multi-edge additivity, error surfacing),
`openshape3dUITests/BlendUITests.swift` (4 end-to-end flows incl. drag).

### Known v1 gaps (deliberate, documented)
- Corners where 3+ blended edges meet are best-effort (sequential CSG order).
- Concave edges unsupported (material-removal only; concave needs additive fill).
- No tangent-chain auto-propagation (spec: picking 2 edges of a chain rounds
  the whole chain).
- One body per blend feature.
- Fillet cross-section is a prismatic quarter-round (true rolling-ball corners
  and G2 need the B-rep kernel).

---

## 3. Dev workflow essentials

- Simulator UDID: `69DB84F4-607C-46F2-9089-3E8C0770B4A9` (iPad). Ad-hoc
  screenshots: `scripts/run_sim.sh`.
- Build: `xcodebuild build -scheme openshape3d -destination 'platform=iOS Simulator,id=69DB84F4-...'`
- Tests (always `-parallel-testing-enabled NO`):
  - unit: `-only-testing:openshape3dTests`
  - UI: `-only-testing:openshape3dUITests/<Class>[/<test>]`
- UI-test helpers in `openshape3dUITests/PullArrowTestSupport.swift`:
  `startSketchTool(app,"Rect")`, `tapPaletteTool(app, group:"Modify", id:/label:)`
  (opens the flyout only if the tool isn't already hittable), `dragPullArrow`.
  Fresh-document launch: `app.launchEnvironment["OS3D_FRESH"] = "1"`.
- Verification hooks: `SelectionInfoBar` rows (Volume/Bounds/Area/Edges…),
  History ids `HistoryRow-<name>` / `HistoryError-<name>` /
  `HistorySuppress-<name>` / `HistoryDistanceField`, Items `ItemRow-*`, error
  alert title "Something Went Wrong".

### Gotchas that will bite you
1. **SwiftData in XCTest**: any in-process `ModelContainer` with the 7-type
   `PersistedFeature` schema crashes deterministically (malloc double-free).
   Never unit-test `DocumentSession`; use pure `DesignDocument` values +
   `FeatureGraph.evaluate` (see `FeatureGraphEvalTests`) and UI tests.
2. **a11y containers**: an `.accessibilityIdentifier` on a container HStack
   collapses it into ONE element and hides every child control from XCUITest.
   Ids go on leaf buttons/fields only.
3. **Bottom overlays**: `EditorView` has a single bottom `.overlay` VStack
   (info strip + input bar). Add bars INSIDE it (conditionally), never as a
   second `.overlay(alignment: .bottom)` — they cover each other.
4. **SourceKit noise**: per-file diagnostics ("Cannot find type …", "No such
   module XCTest") are cross-file/-target indexing noise. `xcodebuild` is the
   authority.
5. **GPU mesh cache** keys on `(BodyID, meshRevision)` — any transient preview
   body must bump a revision (use a high-bit counter to avoid colliding with
   document revisions).
6. **`MainActor` default isolation** (`SWIFT_DEFAULT_ACTOR_ISOLATION`):
   kernel/graph types must be explicitly `nonisolated` (nested enums too).
7. **Selection mutation**: `deleteSelection` deletes whatever is in
   `selection` — internal cleanup paths must never write to `selection`
   (that's why `resetBlendState` exists apart from `cancelBlend`).
8. **Isolated-deinit double-free**: with `SWIFT_DEFAULT_ACTOR_ISOLATION =
   MainActor`, an implicitly-`@MainActor` `@Observable` class gets a
   MainActor-*isolated* `deinit` (SE-0371). Deallocating one routes through
   `swift_task_deinitOnExecutorImpl`, which double-frees on the current
   toolchain (Xcode 26.2 / Swift 6.2) — deterministic malloc crash whenever a
   test lets such an instance go out of scope (bit `AppSettings`). Fix: give
   the class an explicit `nonisolated deinit {}` (no teardown work to isolate).
9. **Bottom bars are size-class adaptive**: every contextual bar goes through
   `AdaptiveBar` (`UI/AdaptiveBar.swift`) — one row at regular width; stacked
   scrollable rows (controls / actions / optional footer) at compact width;
   and back to a *single* scrolling row when the height is also compact
   (landscape phone), where three stacked rows cost over half the screen and
   scroll most of the tool palette out of reach.
   Build new bars with it rather than a bare `HStack`: at iPhone width a fixed
   HStack compresses each label to its minimum and wraps it one character per
   line. Keep button titles as words — the UI suite matches several by title
   (`buttons["Extrude"]`, `["Cancel"]`, `["Revolve"]`, `["Done"]`), so
   icon-only compact labels would break those tests.
10. **Hierarchical `.secondary` disappears inside a `ScrollView` over a
   material.** `.foregroundStyle(.secondary)` is a *hierarchical* style, drawn
   with vibrancy against `.regularMaterial`; vibrancy does not composite inside
   a ScrollView, so the text renders fully transparent while still taking its
   layout width (the bars read "Box [4] [4] [4]" with no W/D/H). `Color
   .secondary` is hierarchical too and is NOT an escape hatch. Use the concrete
   `.barLabel` (`Color(uiColor: .secondaryLabel)`) for bar captions and for
   `.tint` on off-state bar buttons. This is invisible to XCUITest — a
   transparent label still `exists` and is `isHittable` — so it needs a visual
   check, not a test.
11. **Advisory copy in a bar goes through `BarHint`**, which renders nothing at
   compact width. A hint is the least important thing in the row and the most
   expensive: "Drag the arrow, or type a distance" pushed Offset Plane's own
   Distance field off the right edge. Controls too wide to share a compact row
   (the Pattern pickers, the image Opacity slider) move to the footer instead —
   pass `showsFooter: isCompact`, because an `if` inside the footer builder
   yields `_ConditionalContent`, not `EmptyView`, and would still claim the
   row's stack spacing at regular width.
12. **Bottom-edge insets must be measured, not hardcoded.** The palette and the
   bottom corner chips inset above the bars via `bottomBarInset`, fed by
   `BottomBarHeightKey`. The old fixed 96pt assumed an iPad-height bar and let
   the Copy badge sit on top of a taller compact bar.

---

## 4. Next missions (prioritized)

### E4 — Shell (recommended next; spec §4.4)
Hollow a solid to a uniform wall by removing selected face(s); whole-body mode
cores it hollow. The spec blesses a prismatic mesh approximation:
- Face-removal mode: reuse the face-selection context
  (`FaceTopology.planarFace` outline/holes) → inset the outline by thickness
  (`SketchOffset` does 2D offset already) → extrude the inset profile into the
  body and subtract (`KernelOps` has all the pieces).
- Whole-body mode: scale/offset a copy inward and subtract (exact for convex
  prisms; document the gap for concave).
- Parametric: `FeatureKind.shell(body: BodyRef, face: FaceRef?, thickness:
  Expr)`; eval mirrors `evalPushPull` (resolve FaceRef → kernel op → relabel).
- Live red/blue validity on the thickness drag mirrors the blend arrow's
  `isValid` wiring exactly.

### E5 — Blend polish
- **Tangent-chain propagation**: group `SelectableEdge`s whose endpoints touch
  and whose directions are near-parallel at the join; a tap selects the chain.
- **Concave edges**: additive corner fill (union the wedge instead of
  subtracting) — `isConvex` already classifies.
- **History edge re-pick**: "edit edges of an existing blend feature" (spec:
  additive edit-mode selection) — needs a History row action that re-enters
  `.pickingBlendEdges` seeded from the node's EdgeRefs.

### F — OpenCASCADE B-rep port (the big one)
Behind the existing `KernelOps` facade (see `IMPLEMENTATION_PLAN.md` Phase E
section for scope): OCCT compiled for iOS, solids become B-rep, Euclid stays
the render/preview path. Unlocks true fillets (tangent chains, rolling-ball
corners, G2), robust booleans, shell/offset-face quality. Start with a spike:
build OCCT.xcframework, round-trip one box through
`BRepPrimAPI_MakeBox` → mesh → `RenderMesh`.
**Concrete ordered scope + spike/kill-criteria: `docs/OCCT_BREP_PORT_DESIGN.md`.**
This is what fixes extruded circles rendering as 48-gon prisms (no mesh-side fix
exists — the representation itself must become analytic).
**M0 spike + M1 wiring DONE (2026-07-22):** OCCT 7.8.1 cross-built for iOS
(`scripts/build_occt_ios.sh` → `ThirdParty/OCCT.xcframework`, gitignored,
modeling-only ~74 MB/arch). OCCT is now **linked into the app** and callable
from Swift via `OCCTKernel` (Obj-C++ `OCCTBridge` behind a dedicated bridging
header — NOT `ShaderTypes.h`, which Metal shares). `openshape3dTests/
OCCTKernelTests` proves it in-suite (extruded circle = 1 analytic cylinder);
**full suite 499 green**. STEP/IGES deferred (build-flag flip; ~doubles the lib).
**A circle extrude now renders as a TRUE smooth cylinder** (OCCT analytic
tessellation + surface normals), visually confirmed on-device — behind
`OCCTKernel.renderCircleExtrudesWithOCCT`, Euclid still owns CSG. Seed a demo
with `SIMCTL_CHILD_OS3D_FRESH=1 SIMCTL_CHILD_OS3D_DEBUG_SEED_CYLINDER=1`.
**OCCT is now the source of truth for circle extrude + boolean:** `Body.brep`
(`BRepHandle`) carries the analytic solid; `evalBoolean` composes breps
(`BRepAlgoAPI_Fuse/Cut/Common`) and renders smooth — so a cylinder MINUS a
cylinder stays round (verified on-device: `SIMCTL_CHILD_OS3D_DEBUG_SEED_BOOLEAN=1`).
Euclid still computes CSG → suite 500 green. Next: general (polygonal/arc)
profiles as B-rep source, analytic holes, extrude-into-target boolean, B-rep
persistence, then fillet/shell on B-rep. Repro: `scripts/run_occt_spike.sh`.

### Shapr3D UI parity review (2026-07-23)

A pass over the sketch and solid-modeling UI against Shapr3D, driving the app
on the iPad sim and comparing on screen:

- **Live sketch dimensions** while drawing (`LiveDimensionKit` +
  `SketchLiveDimensionOverlay`): width/height on a rectangle, Ø on a circle
  (ticked where it meets the curve), length/R for line/arc.
- **Draw from the current camera** — entering a sketch no longer snaps
  head-on; it only re-aims from a grazing (>80°) view. Look at Sketch is
  recomputed on entry so it appears from an angled view.
- **Orientation-cube face names** (Top/Front/Right…), fading as faces turn away.
- **Overlay alignment fix** — every projected overlay was ~85pt low (Metal
  viewport full-bleed vs safe-area-inset SwiftUI overlay); all now
  `.ignoresSafeArea()` and re-publish the camera on layout/resize.
- **Named snap chip** (`SnapChipOverlay`) + typed snapping
  (`SnapEngine.SnapKind`): Endpoint/Midpoint/Center, ranked; rectangles gained
  edge-midpoint and centre snaps.
- **Selection accent orange → Shapr3D blue** (with the user's sign-off), kept
  distinct from the under-defined blue.

Remaining Shapr-vs-ours gaps noted but NOT yet done: the sketch grid is drawn
on the world ground plane only (Shapr3D re-orients it to the active sketch
plane); mid-draw numeric entry into the live dimension; rectangle dimensions
pinning to the drag-facing sides.

### Spec §1–§12 gap sweep (2026-07-22) — suite 658 green

Every ❌ in `SHAPR3D_PARITY_SPEC.md` through §12 was re-audited and closed
except §7.5 (SpaceMouse/Wacom — needs a vendor SDK and physical hardware, so
it cannot be built or tested here). Each landed as a tested backend with the
UI wiring called out as missing in its spec entry:

| § | What shipped | Where |
|---|---|---|
| 1.2 | Automatic line/arc from a pen stroke; wiggle toggles it | `StrokeClassifier` |
| 2.4 | Re-host a sketch on another plane | `ChangeSketchPlaneCommand` |
| 2.5 | Live sketch pattern link (edit seed → instances follow) | `SketchPatternLink` |
| 4.12 | Replace Face: extend/trim onto a parallel plane | `ReplaceFaceKit` |
| 4.13 | Offset Edge (3D), Single + Chain | `EdgeOffsetKit` |
| 4.15 | Wrap & Emboss onto a cylinder, no stretch | `WrapKit` |
| 4.16 | Delete Face + surface healing (OCCT defeaturing) | `FeatureGraph.evalDeleteFace` |
| 6.5 | Insert Project WITH editable history | `ProjectMergeKit` |
| 8.4 | Hotkeys + fuzzy Command Search | `CommandRegistry` |
| 12.1 | OBJ import (round-trips `OBJExporter`) | `OBJImporter` |

Stale statuses corrected in the same pass: §4.14 (ships as §1.13's 3D entry
point), §6.4 (import exists), §17 (Settings ships).

**Next:** these are backends without UI. The highest-value follow-on is wiring
them into the palette/gizmo layer — Delete Face and Replace Face are single
gestures on an existing face selection, and Command Search needs only a
UIKit key-command bridge plus a launcher sheet.

### Deferred backlog (from Phase D)
- Transform-as-a-feature — **design blocker documented** in
  `PHASE_D_DESIGN.md` / memory: eval emits world-space+identity meshes while
  live tools store localized-mesh+pivot; needs an eval-representation rework
  (dedicated tranche).
- Sketch patterns, EdgeRef-based dimensioning, MaterialTagNaming (needs OS3D
  v2 blob format), linked copies, PrimitiveSpec-dim variables, full unit
  conversion.

---

## 5. Conventions for the next session

- One tranche = backend (pure, unit-tested) → UI → UI test → full-suite gate →
  commit. Keep commits per tranche with detailed messages (see `git log`).
- New geometry ops: `nonisolated` statics on `KernelOps`, end in
  `.makeWatertight()`, unit-test exact volumes on a cube first.
- New feature kinds: add the case + eval + arms in `HistoryPanelView.iconName`,
  `distanceValue`, `EditorViewModel.kindLabel`, `kind(_:replacingExpr:)` —
  the compiler's exhaustive-switch errors will walk you through them.
- Update this file at the end of each mission.
