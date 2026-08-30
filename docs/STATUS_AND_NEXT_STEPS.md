# Status & Next Steps — Handoff Notes

Last updated: 2026-08-28 (move-gizmo parity pass; §1/§4 re-audited against the
code). This is the living handoff document: what is DONE, how the newest
subsystems work, the dev workflow, and the prioritized next missions.
Companions: `IMPLEMENTATION_PLAN.md` (original phase plan),
`SHAPR3D_PARITY_SPEC.md` (feature spec), `PHASE_D_DESIGN.md` (feature-graph
design).

**Current test baseline, both suites green at the Replace Face commit
(2026-08-29): 839 unit tests in 93s, full UI suite 99 executed, 2 skipped,
0 failures, 43m14s** — 0 idle-timeouts, 0 field-clear retries, store pinned at
1 project. The skips are `CompactWidthBarUITests`, which skip by design on the
iPad destination.

The STEP-interchange commit before it ran the UI suite CLEAN TWICE IN A ROW
(96 executed, 42m29s each). Two runs, not one, was the point there: run 1's
build predated three late edits, and a run that does not test what you commit
proves nothing about what you commit.

Two runs, not one, is the point: the three runs before the fixes each surfaced
a DIFFERENT pair of failures, so a single green run proved nothing. Four other
numbers are worth reading alongside the pass count, because a green suite hid a
regression once already (see the ⌘A trap below) — all four were clean on both
runs above:

| Signal | Healthy | Why it matters |
|---|---|---|
| wall clock | ~42m | 78m with ⌘A firing Select All — and still green |
| `animations complete notification not received` | 0 | each one is a 60s idle-wait timeout |
| `OS3D_BUG field held` | 0 | the field-clear self-heal is not having to paper over anything |
| projects in the store | 1, before and after | it used to climb ~95 per run |

**The four long-serial-run flakes are fixed** (2026-08-28) — see "Flaky UI
tests: what they actually were" below. They were bad tests, not bad app code,
with one exception that was a real accessibility bug. Runs now also start from
an empty store (`OS3D_RESET_STORE`), so the suite no longer degrades as it goes.

Historical counts appear in the dated sections below — those are snapshots,
not the baseline.

**Sections dated in the past are history.** §1 and §4 are the only two that
claim to describe the present; if you find them disagreeing with the code,
the code wins — fix them in the same commit.

---

## 1. Where the project stands

| Phase | Status |
|---|---|
| **A** — planes, sketch tools, revolve, transform, items, views, IO | ✅ done |
| **B** — sweep, loft, split, pattern, offset, text, project, section, display, selection, materials, symbols | ✅ done |
| **C** — 2D constraint solver (Levenberg–Marquardt), dimensions, auto-constrain, DOF coloring, sketch mirror | ✅ done |
| **D** — parametric feature graph: topo naming, all creation ops, sketch associativity, variables/expressions, pattern-as-feature, rollback, **reorder + suppress** | ✅ done (tranches 1–6) |
| **E** — edge blends: chamfer/fillet, multi-edge, live preview, drag-to-size arrow | ✅ tranches 1–3 done |
| **E4** — Shell (face-removal + whole-body) | ✅ done — `FeatureKind.shell`, `KernelShellTests`/`FeatureShellEvalTests`/`ShellUITests` |
| **F (B-rep)** — OpenCASCADE port | ✅ largely landed — see §4 F for what is left |
| **STEP interchange** — exact-B-rep import/export | ✅ done 2026-08-29 — `STEPKit`, §4.1b |
| **Delete Face** — OCCT defeaturing, live | ✅ done 2026-08-29 — `DeleteFaceKit`, §4.1c |
| **Replace Face** — extend/trim a face onto a plane | ✅ done 2026-08-29 — `FeatureKind.replaceFace`, §4.1d |
| **Command Search** — fuzzy command launcher | ✅ done 2026-08-29 — `CommandSearchView`, §4.1e |

**The kernel seam has moved (re-audited 2026-08-28).** OCCT is no longer a
spike: when `OCCTKernel.useOCCTAsSourceOfTruth` is on and a body carries a
`brep`, extrude, boolean, **fillet, chamfer, shell and delete-face** all run
through OCCT (`FeatureGraph` for the parametric path, `EditorViewModel` for
the live preview), and breps persist through `DocumentSession`
(`OCCTKernel.serialize/deserialize`). The Euclid mesh blend is now the
**legacy fallback for brep-less bodies only** — a brep body whose OCCT blend
fails ERRORS rather than degrading to it (FeatureGraph ~L836 explains why:
the mesh path ships spiky facets on analytic solids and desyncs render from
brep). Read that comment before touching either path.

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

### Shapr3D tutorial + manual parity audit (2026-08-26/27)

Drove the "Introducing Shapr3D basics" starter series against the app on the
iPad sim, then read the official 343-page manual (pages 77–259 = sketching +
modeling) tool-by-tool. Full write-up in `MODELING_PARITY_GOALS.md` §2 and
goals G7–G9. Headlines:

- `SHAPR3D_PARITY_SPEC.md` is accurate — every manual tool maps to a spec
  section, and the statuses spot-checked against code were all correct.
- **The gap is depth, not breadth**: nearly every tool exists, but only as its
  default path. That became G9 (tool variants/options) and G8 (History exposes
  only four editable scalars, no reference pickers — so a feature's geometry is
  parametric while its inputs are frozen at creation time).
- Landed from the audit: the invisible-panel-label fix (see gotcha 10 — it had
  never been applied to the three side panels), hotkey routing
  (`CommandRegistry` was dead code with zero non-test references),
  **Offset Edge in sketch mode** (G7.1), and **construction axes** (§6.2).
- **Construction axes** are the first new SwiftData model type since Phase D.
  `PersistedAxis` was added the same way `PersistedFeature`/`PersistedVariable`
  were — a defaulted `@Relationship` on `Project`, no `VersionedSchema` —
  and lightweight migration was verified against the existing 95-project
  simulator store. Keep using that route for new row types.

**Baseline at the time of that audit: 797 unit tests, ~85 UI tests — all green**
(current numbers are in the header). Two UI tests
(`FaceFlowUITests/testTypeNegativeIntoArrowPill`,
`SweepLoftUITests/testSweepCircleAlongTwoSegmentLinePath`) are long-run flaky
(pass in isolation) — rerun individually before suspecting a regression.

**If the whole test target dies at bootstrap** with *"Early unexpected exit …
Test crashed with signal bus before establishing connection"*, and the app also
refuses `simctl launch` with `SBMainWorkspace` denials, suspect a **wedged
simulator, not your code** — confirm by stashing and launching a known-good
build, then `simctl shutdown` + `boot`. Do NOT `erase`: it destroys the saved
designs. (Hit 2026-08-27 after a long driving session.)

### Rotate orbit + exact angle (2026-08-28)

The rotate half of the same parity pass — `RotationOrbitOverlay`, the twin of
`MoveDistanceOverlay`.

- **Grabbing a rotation arc raises the orbit**: the full circle of that
  rotation, dashed, drawn in the ring's own plane at a radius that clears the
  selection (`rotationOrbitRadius` — the body's bounding radius + 8%, floored
  against the gizmo's own size), with the swept slice solid on top of it. The
  sweep starts where the drag was grabbed (`GizmoDragSession.ringStartAngle`),
  so the arc grows from under the finger.
- **The angle rides the arc**: a live pill at the sweep's leading end, stepping
  in the same 5° snap the drag applies (verified on device: −5°, −10°, … −35°).
- **Tapping an arc types an exact angle** — the rotate twin of tapping an
  arrow. `commitAngleRotate` skips the 5° snap (a typed angle is meant
  literally), goes through `beginMove`/`applyRotation`/`endMove` so it lands as
  ONE undoable step, and honours a repositioned pivot. Verified: typing 45 on a
  4 mm box gives bounds 5.66 × 5.66 × 4.00 = 4√2, exactly.
- `updateRotation` is now a snapping front end over a shared `applyRotation`,
  which is what let the typed path reuse the drag's tested math.
- The pill is clamped into the viewport and, while typing, into the top ~42% of
  it: the orbit is drawn at the BODY's radius, so its rim regularly projects
  off-screen, and the software keyboard owns the bottom half. That radius is
  also why the whole control only reads properly when the body is NOT filling
  the viewport — zoomed right in, the rim and the swept arc leave the screen
  and the clamped pill is all that survives. Shapr3D has the same property.
- A mid-drag capture of the finished control (orbit + swept arc + live pill +
  highlighted handle) was taken on the iPad sim; it lives at
  `marketing/screenshots/feature-rotate-orbit-mid-drag.png`, which is in the
  **gitignored** `marketing/` tree — a fresh clone will not have it, so re-shoot
  it with the recipe in §3 if you need it.

### Move gizmo parity pass (2026-08-28)

Driven from side-by-side screenshots of Shapr3D's move control. Everything
lives in `GizmoScreenLayout` (the one source of truth for where handles are)
+ `MoveGizmoOverlay` (drawing) + `ViewportView` (gestures).

- **Plane handles are tiles that lie IN their plane.** `planeCornersLocal` /
  `planeQuad` project the four corners of the tile's square, so the drawn
  shape is a parallelogram that leans with the model and shows which way it
  drags. The hit test uses that same quad: a tap INSIDE it grabs that plane
  outright — before the arrows, and exempt from the pivot dead zone. A tile
  seen edge-on is dropped from BOTH drawing and hit testing
  (`visiblePlaneQuads`), so what is drawn is exactly what is grabbable.
- **Root cause of "the squares don't drag in their plane":** the rotation
  arcs' deliberately fat 50pt touch band reached all the way back over the
  tiles, so a near-miss on a skinny tile became a ROTATION (which snaps in 5°
  steps — it read as the body swinging instead of sliding). Ring hits are now
  rejected inside `ringInnerFraction` (0.75) of the arc's own projected
  radius, and the band never exceeds 0.35 × that radius. Tiles also grew
  (`GizmoGeometry.planeMax` 0.34 → 0.38).
- **Tap the pivot to reposition the control.** The dot becomes a violet
  crosshair; dragging it slides the gizmo on the camera-facing plane while
  the model stays put (`gizmoPivotOffset`, scoped to the current selection by
  `GizmoPivotOwner` so a new selection never inherits a stale drop). A
  repositioned pivot is also the rotation centre. Drag-to-reposition is
  gated on the arming tap, so ordinary drags near the centre are unchanged.
- **Distance pill rides the handle** (`MoveDistanceOverlay`, twin of
  `ExtrudeGizmoOverlay`): live distance while dragging a handle, and tapping
  an arrow opens an inline field (Enter commits, ✕ cancels). The old
  bottom-bar `axisMoveBar` was removed — one input, where the user is looking.
- **Debug hook:** `OS3D_GIZMO_DEBUG=1` prints the grabbed part and each world
  delta (`ViewportView.gizmoDebug`, DEBUG-only, flag read once). It is what
  turned "doesn't lock to the plane" into the ring-band finding in minutes —
  reach for it before theorising about gizmo reports.

**811 unit tests green after this pass, and the user confirmed the gizmo on
device (2026-08-28)** — plane tiles, the on-arrow distance field and the
crosshair pivot are all accepted behaviour now. Treat changes to
`GizmoScreenLayout`'s tolerances as changes to tested, signed-off behaviour.

---

## 2. Architecture of the newest subsystems (Phase E blends)

> **Read §1's kernel-seam note first.** What follows describes the **mesh**
> blend, which is now the fallback for brep-less bodies: a body with a `brep`
> blends through OCCT instead (tangent chains and rolling-ball corners come
> free there — the "known v1 gaps" below are the MESH path's gaps). The
> selection, preview, command and UI plumbing described here is shared by both
> paths, which is why it is still the thing to read.

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

### Known v1 gaps of the MESH path (deliberate, documented)
- Corners where 3+ blended edges meet are best-effort (sequential CSG order).
- Concave edges unsupported (material-removal only; concave needs additive fill).
- No tangent-chain auto-propagation (spec: picking 2 edges of a chain rounds
  the whole chain).
- One body per blend feature.
- Fillet cross-section is a prismatic quarter-round (true rolling-ball corners
  and G2 need the B-rep kernel).

---

## 2b. Platforms — iPhone, iPad, and desktop (Mac Catalyst)

The app is universal (`TARGETED_DEVICE_FAMILY = "1,2"`) and builds for the Mac
through **Mac Catalyst** (`SUPPORTS_MACCATALYST = YES`).

**The one prerequisite is an OCCT Catalyst slice**, and it is already in the
repo: `ThirdParty/OCCT.xcframework` is COMMITTED (the static libs via Git LFS,
see `.gitattributes`), so a fresh checkout builds for iOS *and* Mac without
running the build script. Without a `ios-arm64-maccatalyst` slice the Mac build
fails at link with *"no library for this platform was found"* — that is the
only thing that was missing; the whole Swift/Obj-C++ tree compiles for Catalyst
unchanged.

Cost of carrying it: ~140 MB of static lib (LFS) plus the slice's own copy of
the OCCT headers (an xcframework duplicates headers per slice).

To REBUILD the slice — or add another platform — without rebuilding the iOS
ones (an xcframework assembly replaces the framework, so a Catalyst-only run
would otherwise delete them):

```
OCCT_SRC=/path/to/OCCT-7_8_1 \
IOS_TOOLCHAIN=/path/to/ios.toolchain.cmake \
PLATFORMS="MAC_CATALYST_ARM64" REUSE_EXISTING_SLICES=1 \
scripts/build_occt_ios.sh
```

`REUSE_EXISTING_SLICES=1` harvests the existing slices' libs and headers first
and folds them into the new framework. `DEPLOYMENT_TARGET` is an iOS version
(Catalyst is versioned on the iOS scale) and must stay ≤ the app's
`IPHONEOS_DEPLOYMENT_TARGET`.

Build/run for the Mac:

```
xcodebuild build -scheme openshape3d -destination 'platform=macOS,variant=Mac Catalyst'
```

Notes:
- **visionOS was removed** from `SUPPORTED_PLATFORMS`/`TARGETED_DEVICE_FAMILY`.
  It was declared but the platform isn't installed, so it only produced
  destinations that failed to resolve — which broke plain `-destination`
  commands. Re-add deliberately if visionOS is ever a target.
- **"Designed for iPad"** is the zero-work alternative: Apple Silicon Macs run
  the unmodified iOS build, no Catalyst slice needed
  (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` is already YES). It ships as a
  checkbox in App Store Connect, but gives an iPad-shaped window rather than a
  Mac app.
- AR Quick Look degrades to a plain 3D preview on Catalyst (AR needs a device);
  `QLPreviewController` itself is available, so nothing is guarded out.
- The Catalyst window has a 900×620 floor (`macWindowSizing`) so the layout
  stays in its regular-width form instead of collapsing to the compact bars.

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

### Debug env hooks (all `#if DEBUG`; prefix `SIMCTL_CHILD_` for `simctl`)

| Var | What it does |
|---|---|
| `OS3D_FRESH` | Open a brand-new document instead of the gallery/last file |
| `OS3D_AUTO_OPEN` | Open the most recent document straight away |
| `OS3D_DEBUG_SEED` | Seed a 4 mm box, **selected** (`.editingPrimitive`) — the fastest way to a live move gizmo |
| `OS3D_DEBUG_SEED_CYLINDER` | Circle extrude via OCCT (a TRUE smooth cylinder), `brep` and all — it calls `adoptBRep` exactly like `evalExtrude` |
| `OS3D_DEBUG_SEED_BOOLEAN` | Cylinder − cylinder, staying round through the brep path |
| `OS3D_DEBUG_SEED_HOLE` | 10×10×6 box with a Ø4 through-hole (524.62 mm³) — the only seed with a CYLINDRICAL face, so the one Delete Face needs |
| `OS3D_DEBUG_SEED_STEP` | Stepped block, low half to y=6 and high half to y=12 (1800 mm³) — two PARALLEL faces at different heights, which is the pair Replace Face needs and no single-box seed can offer |
| `OS3D_DEBUG_SEED_PRIMBOOL` | Cylinder primitive − box primitive (mixed analytic boolean) |
| `OS3D_DEBUG_SEED_IMAGE` | Reference image on the ground plane, left unselected |
| `OS3D_GIZMO_DEBUG` | Print the gizmo part each drag grabs, its world delta, and the rotation pill's live value |
| `OS3D_RESET_STORE` | **Destructive.** Delete the SwiftData store before it opens — the app starts with zero projects. Every UI test sets it (see below); do not put it in a shell profile or a scheme you also model in. |
| `OS3D_AGENT` / `OS3D_AGENT_PORT` | Loopback control channel (`Agent/AgentServer.swift`). Answers `GET /v1/health` and nothing else so far, and the MCP client its header names is **not in this repo** — treat it as a stub. |

To read `print()` output from a hook, launch through a console pty:

```
SIMCTL_CHILD_OS3D_FRESH=1 SIMCTL_CHILD_OS3D_DEBUG_SEED=1 \
SIMCTL_CHILD_OS3D_GIZMO_DEBUG=1 \
xcrun simctl launch --console-pty 69DB84F4-607C-46F2-9089-3E8C0770B4A9 \
  com.laan.labs.openshape3d > /tmp/os3d.log 2>&1 &
```

That loop — seed, drive the sim with taps/swipes, read the log — is how the
"plane squares don't drag in their plane" report was diagnosed in minutes
after a long stretch of theorising. Reach for it early.

### Flaky UI tests: what they actually were (2026-08-28)

Four tests failed only inside the 40-minute serial run and passed in isolation.
None of them was a race in the app. Three were bad tests, one was a real
accessibility bug, and the long run was only ever the thing that exposed them.

- **The store grows all run.** Every test launches with `OS3D_FRESH`, which
  creates a document and never removes it — the store was at **541 projects**,
  climbing ~95 per full run. A bigger store slows launch and save, which shifts
  focus and gesture timing. That is the mechanism behind "only in the long
  run": the FaceFlow bug below went from a rare flake to 3-in-5 IN ISOLATION
  once the store had filled up. `OS3D_RESET_STORE` (wired into all 66
  `OS3D_FRESH` launch sites) pins it at 1 project. Costs one 83s wipe the first
  time; per-test timing is unchanged.

- **Numeric fields arrive PRE-FILLED, and nothing was clearing them.** The
  extrude Distance field and the arrow pill both open holding the current
  value. Typing "-3" into a field holding "0" gave "0-3" (which the expression
  evaluator computes as -3 — right by luck) or "-30" (30 mm into a 4 mm box:
  refused, no command), depending on where the tap put the caret. The failure
  then surfaced ten lines later as "typing a negative should commit an inward
  push", blaming the commit. `replaceText` now clears first and verifies what
  landed. Every test that types a height went through the same trap — a "2"
  landing as "20" extrudes 20 mm and still commits, so it would have PASSED
  while building the wrong geometry.

- **`HistoryRow-<name>` cannot tell two extrudes apart.** Both features are
  named "Extrude", so the identifiers are identical and a reorder is invisible
  to a test. The two extrudes are now given different heights and the row's own
  distance field is read instead. The reorder is waited for and retried once;
  when it silently did not happen, the Undo undid the previous EXTRUDE and the
  test failed at the very end with "1 row" and no clue why.

- **A container `accessibilityIdentifier` hid every sketch point marker** —
  gotcha 2, in the wild. `SketchPointStateOverlay` had one, which collapses the
  overlay into a single element, so no test could tell whether a stroke had
  landed. Fixed with `accessibilityElement(children: .contain)`, the pattern
  `HistoryPanelView`'s rows already use.

- **Duplicate `Constraint_*` buttons.** The Constrain flyout and the Constrain
  MENU both carry them, so a frame with both up makes the query ambiguous
  ("Multiple matching elements found"). Drive-the-UI lookups in that test use
  `.firstMatch`.

#### Two traps when typing into a field from a UI test

Both of these cost a full suite run to find, and neither fails in a way that
points at itself:

1. **Never `typeKey("a", modifierFlags: .command)`.** ⌘A is the app's own
   Select All hotkey (`CommandRegistry` "edit.selectAll"), and shortcuts reach
   the app whether or not a text field has focus — that is what
   `CommandShortcutsView` is for. The app then never reports idle and XCTest
   waits its full 60s for animations on EVERY field edit: the suite went from
   41 to 78 minutes while still passing, one test going 66s → 847s. A green run
   is not enough; check the wall clock.
2. **Never `XCUIKeyboardKey.forwardDelete`.** iOS text input does not interpret
   it — it is typed in as an invisible character, so the field holds
   "2\u{F728}…" and you get `("2") is not equal to ("2")`.

   What works: tap the field's TRAILING edge (`coordinate(withNormalizedOffset:
   CGVector(dx: 0.95, dy: 0.5))`) so the caret lands after the last character,
   then backspace it empty. `field.tap()` hits the centre, and at caret
   position 0 backspaces delete nothing.

### Screenshotting a gesture MID-drag

Verifying a live overlay (the rotation orbit, the drag pill, a preview) means
catching a frame while a finger is still down. Two things make that harder than
it looks, both learned the slow way:

1. **A slow `swipe` is a LONG PRESS, not a drag.** Stretching a swipe to
   several seconds to leave room for a screenshot pops the Select Through menu
   instead: the touch sits still long enough for the long-press recogniser.
   Drive it with `touch_path` and keep every point moving — the movement is
   what cancels the long press.
2. **A single timed screenshot loses the race.** The tool call that starts the
   gesture has its own dispatch latency, so a `sleep N && screenshot` scheduled
   beforehand usually fires before the finger is down. Take a BURST and pick
   the frame:

```
for i in 1 2 3 4 5 6 7 8; do
  xcrun simctl io <UDID> screenshot frames/f$i.png; sleep 0.7
done
```

Identical file sizes = identical frames = the gesture had not started yet; the
first differing frame is the one you want.

### Gotchas that will bite you
1. **SwiftData in XCTest**: any in-process `ModelContainer` with the 7-type
   `PersistedFeature` schema crashes deterministically (malloc double-free).
   Never unit-test `DocumentSession`; use pure `DesignDocument` values +
   `FeatureGraph.evaluate` (see `FeatureGraphEvalTests`) and UI tests.
2. **a11y containers**: an `.accessibilityIdentifier` on a container HStack
   collapses it into ONE element and hides every child control from XCUITest.
   Ids go on leaf buttons/fields only — or put
   `.accessibilityElement(children: .contain)` BEFORE the identifier when the
   container itself needs one. This has bitten three times (the blend bar, then
   `SketchPointStateOverlay`, then `CommandSearchView`), and it never looks
   like an a11y problem: the symptom is a child query returning nothing while
   the container answers to the child's TYPE — the search field came back as
   `textFields["CommandSearchPanel"]`. If a leaf identifier "doesn't exist",
   dump `app.textFields.allElementsBoundByIndex.map(\.identifier)` before
   assuming the view is missing.
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
12. **Gizmo handles share screen space — every new touch band steals from a
   neighbour.** `GizmoScreenLayout.hitTest` resolves arrows, plane tiles and
   rotation arcs against tolerances that are all far larger than the drawn
   art, so a generous band added for one handle silently eats another's
   near-misses (the rotation arcs' 50pt band reached back over the plane
   tiles, turning a tile near-miss into a 5°-snapped rotation — it read as
   "the square doesn't drag in its plane"). When you add or widen a handle:
   bound the band by that handle's OWN projected size, and copy
   `testAGrabNearThePlaneTilesIsNeverARotation` — a radial sweep asserting no
   grab in one handle's neighbourhood resolves to a different kind.
13. **Bottom-edge insets must be measured, not hardcoded.** The palette and the
   bottom corner chips inset above the bars via `bottomBarInset`, fed by
   `BottomBarHeightKey`. The old fixed 96pt assumed an iPad-height bar and let
   the Copy badge sit on top of a taller compact bar.
14. **Only the LAST `.fileImporter` in a chain is alive.** Stack two on one
   view and the earlier one silently stops presenting — no error, no log, the
   button just does nothing. `EditorView` had four (STL, DXF, STEP, image), so
   STL and DXF import were dead for as long as the image importer sat below
   them, and the menu-listing tests passed the whole time because the entries
   existed. A second importer bound to `.constant(false)` is enough to break
   the first, so this is about the modifier's presence, not its state. There is
   now exactly ONE, switched by `EditorView.ImportRequest`; keep it that way
   (`ImportPickerUITests` fails the moment a second appears).
15. **`.step`, `.stp`, `.dxf` and `.os3d` have no system UTI** — measured, by
   printing the identifiers: `UTType(filenameExtension:)` returns a `dyn.…`
   placeholder for each, while `.stl` gets the real
   `public.standard-tesselated-geometry-format`. A dynamic type is fine for
   STAMPING an export (the saved `.step` file opens and reads back correctly)
   but is not something a file provider can match, so the importers pair it
   with `.data` — which is why `.os3d` already did, and the tell that this bit
   someone before. The cost is that those pickers list every file rather than
   only readable ones. The real fix is a `UTImportedTypeDeclarations` block,
   which needs the app off `GENERATE_INFOPLIST_FILE` first: with that setting
   on, Xcode ignores `INFOPLIST_FILE` outright and the keys never reach the
   built bundle (tried it — the declaration was simply absent).

---

## 4. Next missions (prioritized)

> **Re-audited against the code on 2026-08-28.** The list below used to open
> with "E4 — Shell (recommended next)"; Shell shipped (`FeatureKind.shell`,
> `shellThickness` UI, `KernelShellTests` / `FeatureShellEvalTests` /
> `ShellUITests`), as did most of the B-rep port that F describes as a spike.
> What remains is ranked here.

### 1. Wire the backends that have no UI — ✅ COMPLETE (2026-08-29)

Every item in this mission is done: STEP interchange (§1b), Delete Face (§1c),
Replace Face (§1d) and the Command Search launcher (§1e). **Mission 2 is now
the top of the list.**

The pattern is worth keeping in mind for the next one: all four were tested
kernels with no caller, and in all four cases wiring them up surfaced a bug in
the surrounding UI rather than in the kernel — dead `.fileImporter`s, a hole
wall that could not be selected, a fuse that left a seam, an a11y container
that swallowed its children.

- ~~**STEP import/export**~~ — **DONE 2026-08-29**, see below.
- ~~**Delete Face / Replace Face**~~ — **BOTH DONE 2026-08-29**, §1c and §1d.
- ~~**Command Search launcher**~~ — **DONE 2026-08-29**, see §1e.

### 1b. STEP interchange — DONE (2026-08-29)

`STEPKit` (`Kernel/STEPKit.swift`) sits on top of `OCCTKernel.writeSTEP` /
`readSTEP`; `EditorViewModel.exportSTEP()` / `importSTEP(data:fileName:)` wire
it to the Export and Import menus. Unlike every other export we offer, STEP
carries the EXACT B-rep — verified in the Simulator, not inferred: a cylinder
exported to `CYLINDRICAL_SURFACE('',#33,3.)` in millimetres, re-imported as an
analytic body, and exported AGAIN to the same single cylindrical surface. No
hop degrades to triangles.

Three things worth knowing before touching it:

- **Mesh-only bodies are skipped, by name.** A body with no `brep` (an imported
  STL, anything the mesh path built) has no analytic geometry to write, and
  triangulating it into a format whose whole value is that it is not triangles
  would be a lie. `STEPKit.ExportOutcome` reports the skipped names; the UI
  shows a notice for a partial export and an error when nothing is analytic.
- **Body transforms are baked in.** A `brep` lives in body-local space and flat
  STEP has no per-solid placement, so a moved body would otherwise export back
  at the origin — silently wrong, and only visible in another CAD tool
  (`testBodyTransformIsBakedIntoTheExportedSolid`).
- **Wiring it uncovered two UI traps, both pre-existing**, now gotchas 14 and
  15: every Import-menu picker was dead except the last one in the chain (so
  STL and DXF import had quietly never worked — that is the bug to be sorry
  about, not the missing STEP entry), and STEP/DXF have no system UTI.
  `ImportPickerUITests` guards the first, and fails if a second `.fileImporter`
  is ever added back.

`OS3D_DEBUG_SEED_CYLINDER` was also fixed in the same pass: it built a smooth
render mesh via `cylinderRenderMesh` and never called `adoptBRep`, so the
seeded body LOOKED like a real extrude while carrying no `brep` at all. It now
mirrors `evalExtrude` properly. A debug seed that behaves differently from the
app is worse than no seed — this one sent me hunting a STEP bug that did not
exist.

### 1c. Delete Face — DONE (2026-08-29)

`FeatureGraph.evalDeleteFace` (OCCT defeaturing) shipped with the B-rep port
and had no way in. `DeleteFaceKit` + a `.pickingDeleteFaces` mode now give it
one: arm Delete Face in Modify, tap faces, Apply. It is modelled on Shell —
same single-body pick, same live preview swapped in for the source, same
"reuse the preview at commit" rule — and records a `.deleteFace` node for a
feature-owned body so it replays.

- **It had to be a picking MODE, not an action on the current selection.** A
  hole's wall is the face worth deleting, and tapping one today routes to
  `beginCylinderRadial` or falls through to whole-body select, so the face
  never becomes selectable. This is also why the tool handles cylindrical
  faces at all: `DeleteFaceKit.target(in:seedTriangle:)` prefers the cylinder
  over the coplanar sliver `planarFace` returns on a curved surface.
- **The sample point is the whole trick.** OCCT is told WHICH face to remove
  by a point lying on it. The obvious centroid-of-triangles lands on a
  cylinder's AXIS — inside the solid — and removes nothing or the wrong face.
  `DeleteFaceKit` steps out to the surface at mid-height instead, matching
  what `evalDeleteFace` already did for replay.
- **Signatures are minted by `SignatureNaming`, not re-derived.** The live
  pick's `FaceRef` has to match what a rebuild enumerates, so the two private
  `signature(planar:)` / `signature(cylinder:)` builders are now internal and
  shared. Two copies of those formulas would drift, and the symptom would be
  "delete face forgets its face after a rebuild".
- **Refusals are visible.** No brep → a notice saying so (a mesh has no
  surfaces to extend). A pick OCCT cannot close → the bar says "The
  surrounding faces can't heal that" and Apply stays off, because §4.16 is
  explicit that some deletions legitimately leave a sheet body.

Verified on numbers, not screenshots: the `OS3D_DEBUG_SEED_HOLE` body is a
10 × 10 × 6 box with a Ø4 through-hole, 524.62 mm³. Deleting the hole's wall
takes it to **600.00 mm³ — exactly the full box** — and one undo puts it back.
`DeleteFaceUITests` asserts both numbers; `DeleteFaceKitTests` proves the same
heal at the kernel level (cylindrical faces 1 → 0, planar 6).

### 1d. Replace Face — DONE (2026-08-29)

`ReplaceFaceKit` was fully built and tested with no callers. It now has a
`FeatureKind.replaceFace`, an `evalReplaceFace`, and a `.pickingReplaceFace`
two-stage pick: tap the face to move, tap the face to move it onto, Flip if the
side is ambiguous, Apply.

- **The kit was Euclid-only, and that mattered.** Running an analytic body
  through its mesh booleans hands back a body with no `brep` — the shape still
  renders correctly and only degrades at the next save, which is exactly the
  C4 failure from the 2026-08-25 review. `sweptBRep` / `applyBRep` build the
  prism in OCCT and boolean it there; `sweptZRange` is shared with the Euclid
  path so the two can never disagree about which side the material goes.
- **The fuse leaves a seam, and the test caught it.** An extend meets the body
  ON the replaced face, so `BRepAlgoAPI_Fuse` returns BOTH coplanar faces plus
  the seam edge: a box extended by 6 mm came back with TEN planar faces instead
  of six. Right shape, wrong topology — and those extra edges are selectable
  and blendable by the user. Fixed with a new `OCCTKernel.unified` wrapping
  `ShapeUpgrade_UnifySameDomain`, applied to the replace result. It is a
  separate bridge call on purpose: folding it into `booleanOfShape` would
  change every existing boolean.
- **The target is a PLANE, not a `FaceRef`** — the v1 limitation worth knowing.
  The replace is associative to the face it MOVES (that rebuilds with its body)
  but not to the face it moves TO. `sweep` stores its spine the same way, for
  the same reason: a ref needs an owning body, and the target is routinely on a
  different one.
- **Cross-body targets convert through both transforms.** `convertPlane`
  rotates the normal and translates the origin separately; comparing a plane
  from one body's local space against a face in another's is a mistake that
  only shows up once two bodies are far apart.
- **Refusals reach the bar verbatim.** "The target face isn't parallel to the
  one being replaced" is a real geometric answer — the gap varies across the
  face, so one prism would be wrong everywhere but a line. `FeatureGraph
  .replaceRefusalText` is shared by replay and the live tool so both say it the
  same way.

Verified on numbers: `OS3D_DEBUG_SEED_STEP` is a stepped block (low half to
y = 6, high half to y = 12) at 1800 mm³. Replacing the low step's top onto the
high step's plane gives **2400.00 mm³, bounds 20 × 12 × 10** — one solid box —
and undo restores the step. `ReplaceFaceUITests` asserts that and the
not-parallel refusal; `ReplaceFaceBRepTests` and `ReplaceFaceEvalTests` pin the
analytic face counts, the two paths agreeing with each other, and the FaceRef
still resolving after an upstream edit.

### 1e. Command Search launcher — DONE (2026-08-29)

`CommandRegistry` has carried the fuzzy matcher, the recents list and the
Single Key Action flag since the hotkey pass, with no view that opened any of
it. `CommandSearchView` + `EditorViewModel.commandSearchActive` do now: the
toolbar's magnifier, `X`, or `⌘F` open a panel; type, Enter or tap runs.

- **It only offers commands that can actually run.** The catalog names 61
  commands; `runCommand` routes 39 of them. `CommandRegistry.launchableCommands`
  is the intersection minus the launcher itself, and `CommandSearchTests` pins
  it to `routableIDs` so a catalog entry can never appear in the launcher
  without a route. A result that does nothing when chosen is the same silent
  failure as a dead hotkey and harder to explain, because the user just read
  the name off a list. `unroutedChordedCommands` still tracks the gap.
- **A toolbar button, not only the chords.** X and ⌘F need a hardware
  keyboard; most iPads do not have one, and a launcher nobody can open is not
  a feature.
- **A command that is real but not applicable keeps the panel open** and says
  so in orange ("'Circle' isn't available right now" with no sketch open).
  Closing on a keystroke that did nothing is what makes a launcher feel broken.
- **Single Key Action is now real** (spec §8.4, `AppSettings.singleKeyAction`,
  Settings ▸ Interface). On `.commandSearch`, `CommandShortcutsView` stops
  registering bare-letter hotkeys and registers a–z instead, each opening the
  launcher PRE-TYPED with that letter — registering the whole alphabet rather
  than only the letters that happen to be hotkeys is what makes the setting
  mean what it says. Chorded shortcuts are untouched either way. A focused text
  field still wins, because the first responder is consulted first.
- **Routed two commands while here**: `model.deleteFace` and
  `model.replaceFace`, whose tools shipped earlier the same day. Without that
  the launcher would list two tools visible in the Modify palette that it could
  not start.

Gotcha 2 bit for the THIRD time on the way in: `.accessibilityIdentifier` on
the panel container collapsed it into one element, and the search field came
back as `textFields["CommandSearchPanel"]` while `CommandSearchField` did not
exist at all. `.accessibilityElement(children: .contain)` before the identifier
is the fix, as it was for `SketchPointStateOverlay`.

### 2. B-rep follow-through (F below is the design doc)

General (polygonal/arc) profiles as B-rep source, analytic holes, and
extrude-into-target boolean are the remaining Euclid-first paths — each one
still forces a body down the mesh route, which is where the blend fallback and
its known gaps live.

### 3. Blend polish (E5) — mesh path only, so rank it against mission 2

The first two items are things OCCT already does for a body with a `brep`
(FeatureGraph ~L833: the OCCT fillet "propagates along tangent chains for
free"). They only buy anything for brep-less bodies — which is an argument for
doing mission 2 instead, and letting these two die with the mesh path.

- **Tangent-chain propagation**: group `SelectableEdge`s whose endpoints touch
  and whose directions are near-parallel at the join; a tap selects the chain.
- **Concave edges**: additive corner fill (union the wedge instead of
  subtracting) — `isConvex` already classifies.
- **History edge re-pick**: "edit edges of an existing blend feature" (spec:
  additive edit-mode selection) — needs a History row action that re-enters
  `.pickingBlendEdges` seeded from the node's EdgeRefs.

### 4. F — OpenCASCADE B-rep port (mostly landed; this is its design record)
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
(`scripts/build_occt_ios.sh` → `ThirdParty/OCCT.xcframework`, modeling-only
~74 MB/arch — **committed to the repo via Git LFS**, see §2b; the "gitignored"
claim that used to sit here was stale, a fresh checkout builds without running
the script). OCCT is now **linked into the app** and callable
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
Euclid still computes CSG → suite 500 green. Repro: `scripts/run_occt_spike.sh`.

**Since then (verified in the code 2026-08-28), the rest of that "next" list
landed except the first three items:** B-rep persistence ships
(`DocumentSession` ↔ `OCCTKernel.serialize/deserialize`), and fillet, chamfer,
shell and delete-face all run on the brep in both `FeatureGraph` and
`EditorViewModel`. Still Euclid-first: general (polygonal/arc) profiles as
B-rep source, analytic holes, extrude-into-target boolean — see mission 2.
STEP is no longer a build-flag question either: the bridge is compiled in and
just needs UI (mission 1).

### 5. Deferred backlog (from Phase D)
- Transform-as-a-feature — **design blocker documented** in
  `PHASE_D_DESIGN.md` / memory: eval emits world-space+identity meshes while
  live tools store localized-mesh+pivot; needs an eval-representation rework
  (dedicated tranche).
- Sketch patterns, EdgeRef-based dimensioning, MaterialTagNaming (needs OS3D
  v2 blob format), linked copies, PrimitiveSpec-dim variables, full unit
  conversion.

---

## 4b. Retrospectives — passes already done (not missions)

These record what a review covered and what it deliberately left. Anything
still open from them is promoted into §4 above; read these for the reasoning,
not for a task list.

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

**Next (promoted to §4 mission 1 — still true a month later, and STEP joined
the list):** these are backends without UI. The highest-value follow-on is
wiring them into the palette/gizmo layer — Delete Face and Replace Face are single
gestures on an existing face selection, and Command Search needs only a
UIKit key-command bridge plus a launcher sheet.

---

## 5. Conventions for the next session

- One tranche = backend (pure, unit-tested) → UI → UI test → full-suite gate →
  commit. Keep commits per tranche with detailed messages (see `git log`).
- New geometry ops: `nonisolated` statics on `KernelOps`, end in
  `.makeWatertight()`, unit-test exact volumes on a cube first.
- New feature kinds: add the case + eval + arms in `HistoryPanelView.iconName`,
  `distanceValue`, `EditorViewModel.kindLabel`, `kind(_:replacingExpr:)` —
  the compiler's exhaustive-switch errors will walk you through them.
- Update this file at the end of each mission — and when you touch §1 or §4,
  re-audit them against the CODE, not against what this file last said. Both
  drifted for a month here: §1 called the B-rep port "not started" while OCCT
  was running fillet/chamfer/shell/delete-face, and §4's top mission (Shell)
  had already shipped with three test files. A grep for the type or the test
  file is a ten-second check that keeps the next session from building
  something twice.
