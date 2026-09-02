# Status & Next Steps — Handoff Notes

Last updated: 2026-09-01 (naming-mission completion + real-part validation +
exec-surface completion — see the mission log just below). This is the living
handoff document: what is DONE, how the newest subsystems work, the dev
workflow, and the prioritized next missions.
Companions: `IMPLEMENTATION_PLAN.md` (original phase plan),
`SHAPR3D_PARITY_SPEC.md` (feature spec), `PHASE_D_DESIGN.md` (feature-graph
design), `FREECAD_PLAYBOOK.md` (the FreeCAD-derived hardening ledger),
`TOPO_NAMING_HISTORY_DESIGN.md` (element-naming design, now complete), and
`AGENT_CONTROL.md` (the `/v1/exec` scripting surface).

## Mission log — 2026-09-01 (landed, all committed, 1115/1115 green)

- **Rebuild regression retest + first HOLLOW-CASTING part (2026-09-01, late;
  suite 1128/1128).** Every prior rebuild script passes again in a fresh
  document (TraceParts wheel/nut/flange ALL PASS; FreeCAD angle exact both
  ways; wheel mirror+union 0.000%). Two scripts had read result bodies
  POSITIONALLY (`bodies[0]`) and false-failed in a non-fresh document — the
  volume they printed was a leftover body while the real result in the same
  output was exactly right; fixed to read by id (a79c7eb). New:
  `scripts/rebuild_doorlock_zn.py` — item Industrietechnik **Door Lock 6-8
  Zn** (TraceParts door-locks TP01009002003, art. 0.0.488.45) rebuilt from
  its item24 dimensional drawing: die-cast housing extruded to the drawn
  53×64.5×30 envelope then SHELLED to a 3 mm wall with the mounting face
  left open (chosen by kernel face normal via `/v1/faces`, not a guessed
  index), swivel-lever/top-bump/cylinder-boss unions, Ø17 bore; strike
  plate 49.3×56 with 6.2 flange, catch boss to 10, two mounting holes and
  the latch slot. Envelope exact, shell volume = analytic to the mm³,
  assembly **550 g vs the 560 g datasheet (1.7%)** with the wall thickness
  the only assumption. Identical on three runs, including inside a heavy
  document. Second complex part from the same category: **Ganter GN 115
  lockable latch, type LCG** (`scripts/rebuild_ganter_gn115.py`), rebuilt
  from its standard sheet (d = 32 collar, 28 body, 19×45 arm, 100×32
  L-handle) — a REVOLVED housing with the bore carried in the profile, a
  unioned L-handle, and the steel latch arm as its own body so the mass
  check is per material: **251 g vs the 250 g catalogue weight (0.3%)**,
  0 invalid, all B-reps (handle thickness the one stated assumption). By
  contrast item's Door Lock 8 (PA-GF, ribbed moulding, only a pictorial
  drawing) was judged NOT verifiable from public data and deliberately not
  rebuilt — a plain shell of its envelope would land ±50% on mass, which
  is a guess, not a check. Draft/taper extrude also landed earlier today
  (three slices, `DRAFT_TAPER_DESIGN.md`).
- **Volume readback is now B-rep-exact.** The real-part pass exposed that
  every curved part read ~0.3% low (wheel, latch housing, drafted cone —
  0.27–0.29% each): the reported volume was integrated over the render
  mesh, an inscribed tessellation. `MeasureKit.volume(of:)` now prefers the
  B-rep's `BRepGProp` volume (mesh fallback when there is none), and both
  the info bar and `/v1/state.volumeMM3` use it — so a cylinder reads
  π·r²·h to the mm³ and the "accurate" claim no longer carries a faceting
  asterisk. Pinned by `BRepVolumeReadbackTests`.
- **MEASURED: evaluation is not incremental across independent bodies.**
  With the 60M mm³ wheel chain sitting in the document, each of the lock's
  ~14 exec ops cost ~13 s (whole rebuild ~3 min vs ~4 s in a fresh document)
  and RSS climbed 253 MB → 1.6 GB: every op re-evaluates unrelated upstream
  chains. **FIXED the same day — memoised replay** (`INCREMENTAL_EVAL_DESIGN.md`,
  slices 1+2, `EvalCache.swift`): each node is fingerprinted from its kind,
  its referenced sketches/planes and the stamps of the bodies it consumes
  (a Merkle chain over producer fingerprints), and an unchanged node is
  spliced from its journaled delta instead of re-run; the session then skips
  the `ReplaceBodyCommand` for bodies whose revision is unchanged, so the
  GPU does not rebuild them either, and the read-only replays (error
  refresh on load/undo/redo, edit previews) use a discarded copy of the
  memo. Same document, same script: the heavy-document trivial extrude went
  **18–21 s → 0.04 s (~500×)**, RSS per op **+70 MB → +0.2 MB**, undo
  **full replay → 0.04 s**. Correctness rests on `consumedBodyIDs`
  enumerating every body a kind reads — an op that reads an undeclared
  body must declare it or run uncached (gotcha 19). **Gated by the full UI
  suite (2026-09-02): 105 tests, 2 skipped, 1 failure — and that one was
  `DeleteFaceUITests` pinned to the old faceted 524.62 mm³; with the B-rep-
  exact 524.60 it passes (1a4d332).** No regression from the memo anywhere.
  Then **off-main eval slice 0** (`OFF_MAIN_EVAL_DESIGN.md`): the rebuild
  planner — replay, diff, commands — extracted from `performRebuild` as a
  pure function (`RebuildPlanner.plan`) so the diff semantics are unit-
  tested as values for the first time (`RebuildPlannerTests`, 7 cases,
  incl. "unchanged rebuild → no commands"); verbatim, zero behaviour
  change, 1146/1146. It is the seam the detached evaluate needs.
  Then **draft/taper slice 3, arcs** (`DRAFT_TAPER_DESIGN.md`): rounded
  profiles — slots, rounded rectangles — now draft EXACTLY via
  `SegmentOffset` (lines shift, arcs stay concentric, tangent joints
  sealed, line–line corners mitred; both loft sections on the segments
  channel so arc walls are true cones). Closed-form acceptance: the
  drafted slot matches Steiner's A₀h − P₀·tanθ·h²/2 + π·tan²θ·h³/3 from
  the B-rep to 1e-4. Non-tangent arc joints fall back to the polygon path
  by design. 1154/1154. And **composed hole-wall naming**: the holed draft
  now lofts each bore with a history, names it from its hole profile, and
  composes through every subtraction exactly as `evalBoolean` does — a
  drafted bore's walls resolve by identity (`profileWall(entity: hole)`),
  closing the topological-naming mission's last "relabels by geometry"
  case. Then the last gap: **non-tangent arc joints** trim or extend both
  offset pieces to their carriers' nearest intersection (line–arc via
  line–circle, arc–arc via circle–circle) and re-derive the arc's mid,
  refusing only when the carriers no longer meet — pinned by a "D" and a
  lens in closed form. **Draft/taper (playbook M1) is complete for every
  line/arc profile.** 1156/1156.
  Then **spline-as-profile slice 0** (`SPLINE_PROFILE_DESIGN.md`):
  `CatmullRomBezier` — the exact cubic Bézier spans of the centripetal
  Catmull–Rom the sketch draws (so the kernel can build the SAME curve, no
  shape change for existing sketches) plus a Gauss-exact closed area;
  pinned against `splinePoints` to 1e-9. 1161/1161.
  **Slice 1 landed the same day:** a sketch spline is an exact profile end
  to end — one `Geom_BSplineCurve` edge assembled directly from the Bézier
  chain, `ProfileDetector` making splines participate (a `.spline` entity
  had been ignored entirely — not a profile at all), one smooth wall named
  by the entity, draft falling back to the polygon path. Pinned pole for
  pole against the kernel and by exact volume (closed form, 1e-6). **And a
  finding: `BRepGProp`'s default volume rule is inexact on B-spline
  geometry** (0.4–1.3% depending on parameterisation alone); `OS3DVolume`
  now uses Gauss–Kronrod per knot span and matches to twelve figures —
  gotcha 20. 1166/1166. **Slice 2 landed too:** blends on the spline wall
  build or refuse typed across every edge and radius, a rim fillet adds a
  blend face, a chamfer builds, oversize and out-of-range edge indices
  refuse typed (`SplineBlendStressTests`). 1170/1170. Slice 3 (a real
  splined part) remains.
- **Curved sweeps were wrong; fixed (2026-09-02).** Asked to build a
  Helicoil (a diamond-section wire swept along a helix), the sweep's B-rep
  came out at 0.8% of its volume — valid per BRepCheck, right-looking in
  the mesh. Minimal probes showed V/(A·L) = mean cos(chord angle):
  `BRepOffsetAPI_MakePipe` translates the profile along a polyline without
  turning it. `sweptShape` now uses `MakePipeShell` with mitred corners
  and a section rotated normal to the spine by our own transform (so the
  history survives), and a polyline sweep encloses exactly A·L
  (`SweepSpineTests`: quarter arc, 90° corner, bends, radii). Gotcha 21
  has the three traps. 1175/1175. **Then the exact helix landed:**
  `FeatureKind.sweep` gains an optional `HelixSpec` (axis, reference
  direction, radius, pitch, turns, start angle) — the B-rep sweeps along a
  true helix edge (a line in a cylinder's (angle, height) parameter space,
  Frenet mode) while the render polyline is sampled from the same spec;
  `feature.sweep` accepts `"helix"`. By Pappus a helical sweep is exactly
  section area × turns·√((2πr)²+p²): `testExactHelixSweepIsAreaTimesTrueLength`
  (two caps + four helicoidal walls, 1e-5), and the HELICOIL rebuild
  (`rebuild_helicoil.py`, exact mode) matches to 1e-4. Documents written
  before helices decode with `helix` absent. 1176/1176.
- **2026-09-02 — BEG 55 tapping-unit lineup (E2 Systems, TraceParts
  90-29052019-034131), `scripts/rebuild_beg55.py`.** The "product" is eight
  variants 200 mm apart (Ø150/Ø178 octagonal motor × drive train behind or
  mirrored to the front about z = 42 × plain Ø52 nose or Ø64 collet chuck),
  nine parts each — 72 reference parts, 112,982 triangles. The TraceParts
  preview archive was not fetched; the reference is the product page's own three.js viewer:
  its WebGL draw calls were intercepted for one frame and every position
  buffer read back (world mm, one modelView for all draws), then bounding
  boxes, signed volumes, and plane-cut section polygons (chained, DP 0.4 mm)
  were computed in-page. Every profile in the rebuild comes from those
  sections. Result (`beg55_report.json`, report artifact "BEG 55 Rebuild"):
  bracket −0.07 %, feed housing +0.4 %, switch box −1.2 %, quills +1 %,
  motors +2.2/+2.5 %, body +4.3 % (the belt housing modelled solid), valve
  +4.9 %, plate +6.3 %, belt-cover ring −10/−16 % (not a body of revolution);
  total +2.3 %; envelopes exact (≤ 0.7 mm) on all but the cover (4.8 mm
  behind; 15 mm on the front-mounted units, where the reference cover is
  rotated 90° — its ears sit along y, the mirror keeps them along x);
  72 bodies, all analytic, 0 invalid. Then, with the user's OK, the
  manufacturer's dimension sheet (`beg55-1200.pdf`, 294 KB, one page, no
  text layer — the site 403s plain http, https with browser headers works;
  read by eye at 3400 px) was fetched and 19 callouts compared, datum = the
  housing front face: 12 exact to the millimetre (width 140, A 150/178, axis
  heights 72/237.7, feed top 148.5, width 76, Ø52/64/70, boss 3, flange 183,
  T-slot 7/5.5/19.5, stop rod 21.5/42); body back −0.2, switch box −2,
  overall height +2.7 (the sheet's 360 is the Ø178 terminal-box top), quill
  45 vs the 43–47 stroke, bracket back −5.7 (the 459 likely runs to a cover
  plate the CAD omits), motor B +9 (B excludes the 9 mm front cap). The CAD
  and the rebuild agree with the sheet identically — the rebuild's profiles
  came from the CAD. **Then transform-as-a-feature (2026-09-02, `3f3c4ca`):**
  `FeatureKind.transform` had been a "tranche 2" eval error; `evalTransform`
  now composes the delta onto the body's placement (as a pattern instance
  carries one — no kernel call, analytic solid + element names kept, same
  id, revision bumped so the session replaces the render; scale refused),
  and `feature.transform {bodyID, translation, rotationDegrees, rotationAxis,
  rotationCenter}` exposes it (rotation about a centre folded in as
  T·R·T⁻¹; identity refused). The interactive Move tool still writes
  `body.transform` directly — moving it onto the node is the remaining half
  of the mission. 1183/1183. **Then the draft's consumed edges (`6ae1699`):**
  `ProfileOffset.offsetLoop` refused any outline whose short edges an inward
  offset consumed (every 2 mm corner cut under a 14 mm draft — measured
  outlines are full of them). Each run of consumed edges now collapses onto
  the meeting point of its surviving neighbours' carriers, keeping the vertex
  count (the draft lofts edge-for-edge) with the run's vertices 1e-3 apart,
  so the wall over a consumed edge is a sliver; survivors that still reverse,
  or fewer than three, stay nil. Pinned by the prismoid-exact volume of a
  drafted chamfered outline (45,306.67 mm³). 1186/1186. Landed on the way:
  `/v1/state` bodies now carry `bounds` (mesh min/max, mm); `feature.mirror`
  `keepOriginal:false` now CONSUMES the source (it was a documented no-op —
  `testMirrorWithoutKeepOriginalConsumesTheSource`); a draft extrude refuses
  offsets that eat a profile's short segments ("offsets the profile into
  itself" — the plate outline's 2 mm corners), so drafted slabs use a clean
  rectangle. Found, not fixed (task filed): `feature.loft` between two
  similar octagons on parallel planes KILLS the app (connection closed, no
  .ips) — the octagonal motor frustums use draft extrudes instead. Also:
  a headless-booted simulator gets shut down by later xcodebuild runs — boot
  it under Simulator.app (`open -a Simulator --args -CurrentDeviceUDID …`).
  1179/1179.
- Two app deaths mid-exec during this pass did NOT reproduce under
  controlled repeats (fresh doc ×2, then the heavy doc, all monitored):
  no crash report, no jetsam, RSS modest; the simulator-control helper
  segfaulted in the same window. Filed as transient/external, not an app
  bug — but see gotcha 17, which is the one way to kill the live app on
  purpose.
- **Topological-naming mission COMPLETE.** Every creation op (primitive,
  extrude, revolve, sweep, loft, boolean) and every modifier (fillet,
  chamfer, shell, push/pull, delete/replace-face, mirror, pattern) composes
  element names; both FaceRefs and EdgeRefs opportunistically upgrade legacy
  refs to identity. Revolve/sweep/loft naming and the EdgeRef upgrade were
  the final deferrals. See `TOPO_NAMING_HISTORY_DESIGN.md`.
- **Real-part validation.** openshape3d builds real CAD parts to spec,
  verified against independent ground truth across three sources:
  FreeCAD tutorials (iron angle exact both ways; op-coverage matrix,
  `scripts/rebuild_freecad_angle.py`), TraceParts catalogue parts (a
  RÄDER-VOGEL cast-iron wheel matched its datasheet weight to 0.7%; a
  hex nut and bolt-circle flange to exact volumes — `rebuild_traceparts.py`),
  and the Shapr3D models. A published comparison artifact shows five of them
  reference-vs-render. Fillet/chamfer stress tests on curved revolved
  geometry are robust (valid or graceful typed failure, never crash/hang).
- **`/v1/exec` scripting surface COMPLETE.** Now exposes every FeatureKind
  that has a live tool: all construction ops, all modifiers, the full
  direct-modeling face family (push/pull, move/scale/rotate face), mirror,
  pattern, and all seven sketch entity kinds (line/circle/arc/spline/rect/
  polygon/ellipse). Also hardened: a wrong-typed `boolean` intent is refused
  (`bad_boolean_type`) instead of silently making a stray body. Only
  `primitive` (covered by sketch+extrude) remains unexposed —
  `feature.transform` landed 2026-09-02 (below). See `AGENT_CONTROL.md`.
- **Sketch conflict diagnosis stages 2–3 + scale-free residuals** (playbook
  S6/S7): the conflict chip now names WHICH constraints clash (red glyphs)
  and add-time refusals name the clashing partners; the four mm² residuals
  read sin/cos/mm so the conflict gate is scale-honest.

Next missions are genuinely different in kind — architectural refactors
(§4.5: off-main eval slices 1–3 per `OFF_MAIN_EVAL_DESIGN.md`, scene
caching, `ToolLifecycle` registry) and new kernel capability
(spline-as-profile — designed in `SPLINE_PROFILE_DESIGN.md`, not started;
transform-as-a-feature). Draft/taper angles for cast parts landed
2026-09-01/02 (`DRAFT_TAPER_DESIGN.md`, complete for line/arc profiles);
the memoised replay landed 2026-09-02. Each remaining mission warrants its
own design pass, not incremental continuation.

**Current test baseline (2026-09-02): 1170 unit tests in ~20s** (draft/taper incl.
arc profiles and non-tangent joints, spline profiles with exact B-spline walls, B-rep volume readback, memoised replay, rebuild planner all added on 2026-09-01/02; the
previous line follows) — **(2026-09-01): 1115 unit tests in ~17s** (1 skipped:
the on-demand `OCCTFuzzTests` hostile-input sweep, run with
`TEST_RUNNER_OS3D_FUZZ=1`). Earlier this session: 1086 → the naming
completions, real-part regressions, exec expansion, and conflict-diagnosis
work added the rest. Historical: 1013 after the FreeCAD-hardening tranches,
920 on 2026-08-30 (down from ~100 s once booleans stopped running both
kernels, §3b). Prior baseline paragraph, for the record:

**(historical) Current test baseline (2026-09-01): 1086 unit tests in ~17s** — the
debug-tooling tranche (§4 mission 0c) added 21, topo-naming steps 1–5a added
~35 (ancestry, element naming, name-first resolve, identity blends,
modifier-op history), the exec identity ops most of the rest, and
revolve/sweep naming (landed 2026-09-01, commit 279a311 — including the
OCCT full-revolve `Generated()` gap and its `Revol().Shape(edge)` recovery,
see `TOPO_NAMING_HISTORY_DESIGN.md`) the last 4, on top of the 1013 the
FreeCAD-hardening tranches left. Previous baseline (2026-08-30):
920 unit tests in 18s — down from ~100 s after booleans stopped running both
kernels (see §3b). **Full UI suite last measured 2026-09-02** (105 tests in 46.5 min after the memoised replay: 104 green + the DeleteFace expectation corrected to the B-rep-exact volume; previously 2026-09-01) (covering all
of the above): 104 executed, 2 skipped, 46m19s — 1 failure
(`DragSolveUITests.testDragTopCornerKeepsHorizontalEdgeAndCoalesces`, passed
clean in isolation immediately after: the documented long-run-flake pattern,
and a sketch-solver test unrelated to the naming work), 2 idle-timeouts,
0 field-clear retries. The ~2 min over the prior 44m28s tracks the two 60 s
idle-waits plus one more executed test. The skips are
`CompactWidthBarUITests`, which skip by design on the iPad destination.

UI wall clock is flat across the whole of mission 2 (44m18s → 44m10s →
44m28s): it added 29 unit tests and no UI tests. The run before THAT was 43m14s, and the minute
it gained was the four `CommandSearchUITests` (~41s in isolation) — worth
checking rather than assuming, since that commit registers keyboard shortcuts,
and a keyboard change is what once took a suite from 41 to 78 minutes while
still reporting green (the ⌘A trap below).

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
**2026-09-02:** the "don't recompute" layer under S1/S2 landed as the
memoised replay (`INCREMENTAL_EVAL_DESIGN.md`: heavy-document op 18 s →
0.04 s, RSS flat); S1 itself is designed in `OFF_MAIN_EVAL_DESIGN.md` —
recommended first slice S1a, a synchronous facade over a detached evaluate,
because `performRebuild` has 9 session callers and 17 external call sites
that all read results immediately.

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
| `OS3D_DEBUG_SEED_HOLE` | 10×10×6 box with a Ø4 through-hole (524.60 mm³ B-rep-exact; the mesh read 524.62 before 2026-09-02) — the only seed with a CYLINDRICAL face, so the one Delete Face needs |
| `OS3D_DEBUG_SEED_STEP` | Stepped block, low half to y=6 and high half to y=12 (1800 mm³) — two PARALLEL faces at different heights, which is the pair Replace Face needs and no single-box seed can offer |
| `OS3D_DEBUG_SEED_PRIMBOOL` | Cylinder primitive − box primitive (mixed analytic boolean) |
| `OS3D_DEBUG_SEED_IMAGE` | Reference image on the ground plane, left unselected |
| `OS3D_GIZMO_DEBUG` | Print the gizmo part each drag grabs, its world delta, and the rotation pill's live value |
| `OS3D_RESET_STORE` | **Destructive.** Delete the SwiftData store before it opens — the app starts with zero projects. Every UI test sets it (see below); do not put it in a shell profile or a scheme you also model in. |
| `OS3D_AGENT` / `OS3D_AGENT_PORT` | Loopback control channel for driving the app from Claude (`Agent/`). Health, command catalog, editor state (incl. per-feature `evalErrors`), `POST /v1/command`, `POST /v1/exec`, `GET /v1/check` (geometry health), `POST /v1/capture` (repro snapshot), and a PNG of the viewport. Clients: `.claude/skills/drive-openshape3d/` (Claude Code, via curl) and `scripts/mcp_openshape3d.py` (Claude Desktop). Protocol: **`docs/AGENT_CONTROL.md`**. NOTE: another local service may squat port 8787 (it did on this machine) — the app then binds IPv6 only and curl answers from the wrong server; launch with `OS3D_AGENT_PORT=8899`. |
| `OS3D_KERNEL_CAPTURE` | Failing kernel ops auto-dump their inputs + params as replayable bundles to `Documents/KernelCaptures` (`=0` disables; default ON in the app, OFF under XCTest). Pull with `scripts/fetch_captures.sh`; promote to `openshape3dTests/Fixtures/Captures`. **`docs/KERNEL_DEBUG_TOOLING.md`** is the workflow. |

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

Do NOT background a `--console-pty` launch from inside an agent tool call: the
call's process group is killed when it returns, the pty closes, and the app dies
with it — presenting a minute later as an inexplicable "connection refused" from
the agent bridge. Plain `simctl launch` survives indefinitely (verified: 80s+
idle, repeated requests). Interactively it is fine; the pty outlives your shell.

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
16. **One simulator, one `xcodebuild` at a time.** Running a second
   `xcodebuild test` (or a plain `build`, which reinstalls the app) against a
   destination that already has a suite running corrupts BOTH. Measured
   2026-08-30, cost one 44-minute UI run: the interference showed up in the
   second run's output as `Error getting main window Unknown kAXError value
   -25218` with element queries returning `(null)`, and in the UI suite as a
   lone `FaceFlowUITests.testSelectFaceAndPull` failure that reads exactly
   like a real regression. Kill and re-run on a quiet simulator; do not try to
   interpret the results. Note the failure did NOT look like a crash, which is
   what makes it expensive — and do not use the `kAXErrorServerNotFound`
   count as the tell, since a healthy run emits those too.

17. **Running the unit suite kills the live agent app.** The test host IS
    `openshape3d.app`: `xcodebuild test` reinstalls and relaunches it, so any
    `/v1/exec` session in flight dies with "remote end closed connection
    without response" — no crash report, no `[agent]` log line, nothing to
    debug. Never run the suite (even `run_in_background`) while driving the
    live app; sequence them, and relaunch with `SIMCTL_CHILD_OS3D_AGENT=1`
    afterwards. Also: `OS3D_AGENT_PORT` alone does nothing — the listener
    is gated on `OS3D_AGENT` being set at all.

18. **`seedPoint` selects ONE profile region.** Two circles in one sketch
    under a single seed extrude (or cut) only the seeded one, silently. Cut
    several holes with one seeded extrude each, or `feature.pattern` on one
    cutter. It cost the door-lock rebuild exactly one hole's 206 mm³ before
    it seeded each. Corollary for rebuild scripts: read result bodies BY ID
    (`producedBodyIDs`, or the boolean's target id) — never `bodies[0]`,
    which reads whatever leftover body sits first in a non-fresh document.

19. **The replay memo is only as correct as `consumedBodyIDs`.** A node is
    spliced from `EvalCache` (skipped, not re-run) whenever its kind, its
    referenced sketches/planes and the stamps of the bodies it CONSUMES are
    unchanged — so an eval that reads a body it does not declare would be
    silently stale when only that body changed. Every kind's inputs are read
    straight off its refs in `FeatureNode.consumedBodyIDs`; when you add a
    kind, or make an existing eval read another body (a second target, a
    reference face on a different body), declare it there. If it genuinely
    cannot be enumerated, leave the node out of the memo (always re-run) —
    correct-by-default. `IncrementalEvalTests` pins the contract on a
    boolean graph; add a case there for any new consumer relationship.

20. **`BRepGProp::VolumeProperties`' default rule is NOT exact on B-spline
    geometry.** Its fixed-order Gauss integration is exact for planar and
    analytic faces but not across a B-spline's knot spans: a spline-walled
    extrude read 0.4% high with one parameterisation of the SAME curve and
    1.3% high with another, and the `Eps` "adaptive" overload read 0.3% low.
    `OS3DVolume` (the source of `MeasureKit.volume(of:)`, the info bar and
    `/v1/state.volumeMM3`) now uses `VolumePropertiesGK(…, Eps 1e-7,
    IsUseSpan: true)` — Gauss–Kronrod per span — and matches closed forms to
    twelve figures. It costs ~2 s across the 1166-test suite. Anything that
    integrates a B-spline face elsewhere has the same exposure:
    `faceInfoOfShape:`'s `SurfaceProperties(face, props)` areas are still
    the default rule (they feed identification heuristics, not checks) — use
    the GK/`IsUseSpan` form before trusting a B-spline face area.

21. **`BRepOffsetAPI_MakePipe` along a polyline does not turn the profile.**
    Found building a Helicoil (2026-09-02): the sweep's B-rep came out at
    0.8% of its expected volume while BRepCheck called it valid and the mesh
    sweep looked right. MakePipe TRANSLATES the profile along each spine
    edge without re-orienting it, so on a curved spine every chord is a
    skewed prism with an oblique section — measured V/(A·L) equals the mean
    of cos(chord angle): 0.69 for a 9-chord quarter arc, 0.5 for one 90°
    corner, ~0 around a full turn. `sweptShape` now uses
    `BRepOffsetAPI_MakePipeShell` with `RightCorner` transitions (mitred
    polyline corners, section kept normal: exactly A·L) — with three
    details that each cost a round: (a) do NOT use its `WithCorrection` /
    `WithContact`: they sweep a transformed COPY of the profile and key the
    history by the copy's edges, so face ancestry vanishes — rotate the
    section normal to the spine yourself and keep the edge map;
    (b) after `MakeSolid` its `FirstShape/LastShape` are the cap FACES, use
    them directly; (c) never find a cap by "the face containing the section
    wire's edges" — a one-edge circular section's only edge is shared with
    the wall beside the cap, and the wall gets found first (every face then
    carries two names and the naming drops them all). `SweepSpineTests`
    pins the volumes; `testASweepSiblingFaceMintsInsteadOfDuplicating` the
    history.

22. **A failed `build-for-testing` leaves the PREVIOUS test bundle in place,
    and `test-without-building` then runs it — green, against stale code.**
    Bitten 2026-09-02: a new test with a type error failed to compile, the
    suite step "passed 1176/1176" (the old bundle, without the new tests),
    and a gate that only looked at the test output let a commit through
    with an uncompilable test. Any gate must check the BUILD step's result
    (grep `error:` / `BUILD FAILED` in its log and stop) before trusting a
    test run, and should assert the expected test COUNT, not just zero
    failures — a count that did not grow is the tell.

---

## 4. Next missions (prioritized)

> **Re-audited against the code on 2026-08-28.** The list below used to open
> with "E4 — Shell (recommended next)"; Shell shipped (`FeatureKind.shell`,
> `shellThickness` UI, `KernelShellTests` / `FeatureShellEvalTests` /
> `ShellUITests`), as did most of the B-rep port that F describes as a spike.
> What remains is ranked here.

### 0. FreeCAD-reference hardening — ✅ TRANCHES 1+2 DONE (2026-08-31)

FreeCAD (the largest open-source OCCT consumer) is now a local reference
checkout; `docs/FREECAD_PLAYBOOK.md` is the ledger — pattern, FreeCAD source
ref, licensing classification (reference-not-copy; FreeCAD is LGPL, we are
MIT), the change here, the defect closed, the pinning test. Landed:

- **Typed kernel diagnostics** (`OCCTOpStatus`/`OCCTOpError`): every mutating
  bridge op says WHY it failed; `Result` variants beside the old `?` shims.
- **Fillet/chamfer** (the top user pain): edge pre-qualification (seam/
  degenerate/tangent picks refused with the reason), `NbFaultyContours` +
  per-edge `Generated()` checks — a partial build is DISCARDED (R4-O4), the
  Ø10-rim r=6 crash is a typed error, and the drag is clamped to a
  kernel-derived max radius (bisection over real checked builds) shown in the
  blend bar.
- **Booleans**: analyzer pre-check on operands (+1 heal), non-destructive
  builder, auto-fuzzy from combined extent (one 10× retry), single-solid
  unwrap + `UnifySameDomain` + validation before storing (R4-O3); a
  body-splitting cut is REPORTED (`solidCount`); OCCT-owned failures surface
  as node errors instead of silently degrading to the Euclid mesh.
- **Closed-hollow shell actually works now** (offset+cut — `BySimple` never
  worked and the mesh fallback was covering for it); shell validates and
  must REMOVE material; brep bodies error rather than degrade to the
  clamping mesh inset (R3-E).
- **Tolerances** (S5): `OCCTKernel.matchTolerance` — deflection-derived +
  per-shape `ShapeAnalysis_ShapeTolerance`, replacing all four AABB-scaled
  sites (the thin-plate mistargeting class).
- **Face targeting** (R4-O2): exact `BRepExtrema_DistShapeShape` to the
  trimmed face; the 5×5 UV-bbox grid is gone.
- **Hang containment** (H1): mesher/read deadline via a progress indicator,
  heal-and-validate at the STEP and blob trust boundaries, finite-bounds
  gates at op entries. **Persistence** (R4-O5): brep blobs written without
  triangulation at pinned `TopTools_FormatVersion_VERSION_2`.
- **Sketch integrity** (R2-2/R2-3): solver writeback gated on the structural
  residual (conflicts spring back + red "Constraints conflict" chip; the
  variable-driven solve keeps prior geometry); delete cascades constraints/
  dimensions in the same undo step; trim re-anchors onto surviving fragments
  and visibly drops the rest; `Sketch.validateConstraintRefs()` for tests.
- **Badges on load/undo** (R4-N6/S6): `DocumentSession.refreshEvalErrors()` —
  an errors-only replay after `load()`/`undo()`/`redo()`.
- **Naming prerequisites** (R4-N1/N4): deterministic face basis (outer loop
  by area, canonical start vertex — kills "moves replay rotated after
  relaunch") and `resolve` now hard-vetoes surface-kind mismatches.
- **Oracle tests** (R3-D): `GeometryOracleTests` — exact analytic volumes
  (incl. a Pappus-derived rim fillet) so wrong-but-non-empty can't pass.

### 0c. Debug tooling — ✅ DONE (2026-08-31)

Motivated by the tutorial-model thread (§4b of NEXT.md): every complex
rebuild surfaces a kernel bug, and each bug cost a hand-built repro. Mined
FreeCAD's debugging machinery and landed the three patterns that shorten the
loop (playbook rows D1–D3; **`docs/KERNEL_DEBUG_TOOLING.md`** is the
worked workflow):

- **Geometry health report** (`OCCTKernel.healthReport` / `GET /v1/check`):
  FreeCAD's Check Geometry re-derived — per-subshape `BRepCheck` faults with
  "Face3"-style names (self AND in-context statuses), tolerance min/avg/max,
  free boundary loops, counts, volume, opt-in BOP self-intersection check
  (only on BRepCheck-clean shapes, on a copy, under the kernel deadline).
- **Failing-op capture** (`KernelCapture`): every `*Result` failure dumps its
  input breps + manifest (op, params, typed error, per-input health) as a
  bundle; `POST /v1/capture` snapshots on demand;
  `scripts/fetch_captures.sh` pulls them; newest-20 retention.
- **Capture replay + fixtures** (`KernelCaptureReplay`,
  `KernelCaptureReplayTests`): a bundle replays through the SAME kernel entry
  points (inputs loaded RAW — no heal), and a committed bundle with an
  `expect` block is a permanent regression test. Seed fixture:
  `overradius-fillet-d10-rim`.
- `/v1/state` now carries per-feature `evalErrors`, so driving sessions see
  which feature broke without exec replies.

Three traps encoded on the way: synchronized-group resources FLAT-COPY (two
fixture `manifest.json`s break the build — Fixtures/ is pbxproj-excluded and
read via `#filePath`); replay must use `rawShapeFromSerialized:` because the
normal deserialize path heals what it reads; and `TopExp_Explorer` counts
shared sub-shapes once per parent (a box "has" 24 edges) — counts use
`TopExp::MapShapes`.

**Next mission from this line of work:** kernel-history topological naming —
design agreed and written up in `docs/TOPO_NAMING_HISTORY_DESIGN.md`
(element maps from OCCT's own `Modified()/Generated()` history layered UNDER
`SignatureNaming`, zero persisted-format change, identity-based blend-edge
targeting). Its prerequisites (boolean normalization, S4 determinism) are
now in. Smaller follow-ups: residual attribution → red per-constraint
glyphs, then rank-based add-time conflict diagnosis; trim re-anchor for
arc/circle fragments beyond the point-weld rule.

### 1. Wire the backends that have no UI — ✅ COMPLETE (2026-08-29)

Every item in this mission is done: STEP interchange (§1b), Delete Face (§1c),
Replace Face (§1d) and the Command Search launcher (§1e). Mission 2 followed on
2026-08-30, arcs and ellipses included, so sketch profiles now reach the kernel
exactly.

That makes **mission 3 (blend polish) the top of the list** — but read its own
text before starting. Two of its three items buy nothing for a body with a
`brep`, and §2 is the argument for letting them die with the mesh path rather
than building them.

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
10 × 10 × 6 box with a Ø4 through-hole, 524.60 mm³ (B-rep-exact; the faceted mesh read 524.62 before 2026-09-02). Deleting the hole's wall
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

### 2. B-rep follow-through — DONE (2026-08-30)

The description this section carried was two-thirds stale, which is worth
recording as its own lesson: **polygonal profiles** and **extrude-into-target
boolean** were already analytic — the first since the port (`extrudeShape`
builds a `PolyWire` prism for any outer loop), the second wherever the target
body has a `brep` (`evalExtrude` composes the cut/fuse in OCCT). Reading the
doc would have had you rewrite two working paths. Testing first found the two
that were genuinely mesh-bound.

**Analytic holes.** `extrudeShape` took `isCircle` for the OUTER loop only;
every hole went through `PolyWire`. A 20×20 plate with a Ø8 hole came back
with **0 cylindrical faces and 70 planar** — 64 of them the faceted bore. It
looks round and is not: a fillet around the rim has 64 segments to chase, and
STEP exports 64 planes. The bridge now takes `holeCircles:` (3 doubles per
hole — cx, cy, r; **r ≤ 0 means "this one is a polyline"**, which is how one
array carries both kinds), `OCCTKernel.ExtrudeHole`/`CircleSpec` wrap it, and
`extrudeHoles(_:)` maps a `Profile`'s inner loops. Both `evalExtrude` brep
branches feed it.

**Multi-profile extrudes.** Both call sites guarded on `extras.isEmpty`, so
selecting a SECOND region and pulling silently produced a mesh-only body —
a cliff with no reason behind it, since a union of prisms is just a union of
prisms. `OCCTKernel.extrudeSolid(outer:holes:extras:…)` fuses them and applies
`unified()`, because touching regions leave the same coplanar seam Replace
Face hit (§1d).

Verified in `AnalyticHoleTests` (8), and falsified: with the circle branch
disabled, five of them fail with exactly the numbers above. `testAWasherIs
TwoCylinders` is the sharpest of them — a washer had an analytic outer wall
and a 64-facet bore, so the shape was half-exact and looked entirely round.

**Arcs — DONE 2026-08-30, and cheaper than this section predicted.** The
paragraph that used to sit here said `Profile` would have to carry per-segment
curve data, rippling through `ProfileDetector`, `KernelOps.extrude`,
area/centroid/contains and face signatures. That was the wrong shape of fix.
`loop` is left EXACTLY as it was — still the tessellated truth every mesh-side
consumer reads — and the exact boundary rides alongside it in
`Profile.segments`, which only the B-rep path consults. Nothing downstream of
the sketch changed representation, so no consumer had to be revisited.

Three details worth keeping:

- **An arc is stored as three points, not a centre and an angle pair.** The
  face traversal walks a chain in whichever direction the loop needs, and an
  orientation convention is precisely the thing that silently sign-flips when
  it does. `GC_MakeArcOfCircle(start, mid, end)` takes the points in traversal
  order and reconstructs the circle itself, so there is no winding flag to get
  backwards. The mid point is an interior SAMPLE from `arcPoints`, which is on
  the true arc by construction.
- **Only loops that contain an arc get segments.** A polygon is already exact
  as a polyline — OCCT builds the same wire either way — so filling this in
  for one would be a second description of identical geometry and a second
  thing to keep in step.
- **Every fallback is per-wire, not per-solid.** Bad segments fall back to the
  polyline for that boundary alone (`SegWire` returns a null wire), and a
  circle still wins over both.

`AnalyticArcTests` (11), falsified by forcing the bridge's arc branch off:
9 fail, a slot reporting 0 cylindrical faces and 6 planar instead of 2 and 4.
That run also caught a test of my own that was weaker than it looked —
`testReversedSketchOrderGivesTheSameSolid` compared the two solids only to
each OTHER, so it passed while both were faceted; it now pins both counts to 2.

**Consequence worth knowing before opening an old document**: a slot wall that
used to be ~20 planar facets is now one cylindrical face, so a `FaceRef` minted
against one of those facets resolves against a cylinder on the next rebuild.
This is the same swap the hole fix made (64 facets → 1 cylinder) and
`SignatureNaming` handles cylinders as first-class, but it IS a geometry change
to bodies that already exist.

**Ellipses — DONE 2026-08-30, and they closed the list.** `detectProfiles`
flattened `.ellipse` to 48 straight segments and emitted `.polygonal`, which
threw the semi-axes away at the very first step; the profile then reached OCCT
as a 48-sided prism, about 0.27% under the true area — small enough to look
right and wrong everywhere it matters.

An ellipse cannot use the arc side-channel, because three points determine a
circle and not an ellipse. So `CircleSpec` became **`ConicSpec`** — centre,
two semi-axes, rotation — and a circle is now the case where the semi-axes are
equal. One concept rather than two: to every caller these are the same thing,
"this whole loop is a curve OCCT can build exactly, so ignore the polyline".
`extrudeShape` lost `isCircle` / `circleCenter` / `circleRadius` in the swap
and takes one optional `outerConic` instead, which is why most call sites got
three arguments shorter.

Two traps, both encoded in tests:

- **`gp_Elips` demands its MAJOR radius first** and refuses major < minor,
  while a sketch's semi-axes are in no particular order — a tall ellipse is as
  ordinary as a wide one. The bridge picks the larger and turns the reference
  direction a quarter turn when that is the y semi-axis
  (`testATallEllipseIsBuiltAsReadilyAsAWideOne`).
- **Equal semi-axes must build a `gp_Circ`**, not a degenerate `gp_Elips` —
  and that is also what keeps a round hole reporting as a cylindrical face
  rather than a surface of extrusion.

Note for anyone reading face counts: an extruded ellipse is a surface of
LINEAR EXTRUSION, so `faceTypeCounts` reports it under `other`, not
`cylindrical`. Only a true cylinder is cylindrical.

`AnalyticEllipseTests` (10), falsified by emitting `.polygonal` again: 8 fail,
the faceted solid measuring 375.92 mm³ against the exact 376.99. That number
is also where the tolerance comes from — the render mesh is a tessellation of
the exact solid and sits ~0.04% under it, while a 48-gon sits ~0.27% under, so
the assertions use a tolerance BETWEEN the two. A tighter one would only be
measuring the tessellator. The same run caught
`testRotationIsCarriedThrough` passing while faceted (a rotated 48-gon has
nearly the same bounding box); it now pins the exact wall too.

**Profile geometry is now exact end to end**: circles, rects, polygons,
line/arc chains and ellipses all reach OCCT as the curves they were drawn as.
Splines never become profiles at all, so there is nothing left to convert
here — the next inexactness lives elsewhere.

### 3. Blend polish (E5) — COMPLETE 2026-08-30 (item 1 was already built)

**The ranking argument this section used to make was wrong, and it is worth
knowing why.** It said these items "only buy anything for brep-less bodies",
implying the mesh path was about to die. But `evalRevolve`, `evalSweep`,
`evalLoft`, `evalPattern` and `evalMirror` do not produce a `brep` at all —
checked one at a time, not inferred. A revolved body is one of the commonest
things a user makes, and every blend on one runs on the mesh path. The mesh
blend is load-bearing and will stay so until those five ops get OCCT paths of
their own (which is the better long-term fix, and a mission in its own right).

- ~~**Tangent-chain propagation**~~ — **ALREADY BUILT**, and was when this list
  was written. `EditorViewModel.handleBlendEdgeTap` expands a tap through
  `EdgeTopology.smoothChain` to the whole tangent-continuous chain and toggles
  it as a unit; `KernelOps.blendEdges` then sweeps a multi-segment chain as ONE
  mitred tool rather than piling up per-segment wedges. `KernelBlendTests`
  covers both halves. Nothing to do here.
- ~~**Concave edges**~~ — **DONE 2026-08-30**, see below.
- ~~**History edge re-pick**~~ — **DONE 2026-08-30**, see below.

Mission 3 is complete.

#### History edge re-pick — DONE (2026-08-30)

"Edit Edges" on a chamfer/fillet row re-enters `.pickingBlendEdges` with the
feature's existing edges already selected, and applying EDITS the node
(`session.editFeature`) instead of replacing the body and appending a second
blend on top of the first.

The one real difficulty is that a blend replaces its body IN PLACE. By the time
the user asks to edit the feature, the body under that `BodyID` already carries
the blend, so re-picking against it would offer the rounded rim rather than the
sharp edges the feature names, and the preview would blend an already-blended
body. `DocumentSession.inputBody(for:bodyID:)` recovers the input by replaying
a copy of the graph with `rollbackIndex` set to the node's own index. It feeds
that replay a LOCAL revision counter: the result is a transient preview source
and must not consume revisions the real document will hand out later.

Three traps, none of them visible to a geometry assertion:

- **`resetBlendState` must clear the edit state.** `commitBlend` branches on
  `blendEditingFeature`, so a CANCELLED edit that left it set would make the
  next fresh blend silently overwrite the edges of the last feature opened from
  the panel.
- **The tap handler must pick against the recovered body**, not the document's.
- **Deselecting every edge must preview the UN-blended body.** Falling through
  to a nil preview shows the document's copy, which still has the old blend on
  it, so clearing the selection would look like it did nothing.

Testing, and its limits, measured rather than assumed:

- `BlendEditEvalTests` (6) covers the MECHANISM as pure values — truncation
  recovers the sharp box, stored EdgeRefs resolve against it, two disjoint
  edges remove exactly twice one (proving each replay starts from the sharp
  box rather than compounding). It does NOT cover the wiring.
- `BlendEditUITests` (1) covers the wiring, and the assertion that matters is
  the ROW COUNT: two 1 mm fillets of one edge look much like one, so
  "edit versus append" is invisible to geometry and shows up only as a second
  History row. Falsified — forcing the append path fails it.
- **A gap worth knowing**: `BodyRef.producer` is never read anywhere (eval
  resolves bodies by `bodyID` alone), so nothing tests it and nothing can. It
  is provenance metadata only. Do not assume a wrong `producer` will surface.

Caution for whoever writes the next History UI test: `HistoryButton` TOGGLES.
Tapping it when the panel is already open closes it, and the row query then
returns zero — which reads exactly like the feature having been destroyed.

#### Concave edges — DONE (2026-08-30)

A concave blend FILLS the internal corner instead of cutting it away, so the
tool is unioned rather than subtracted. Concave edges were classified from the
start (`SelectableEdge.isConvex`) and then discarded twice — once in the tap
handler, once in replay — so an inside corner was not merely unsupported, it
was UNPICKABLE: the tap fell through to the nearest convex edge elsewhere on
the body, which reads as a mis-hit rather than a missing feature.

Three things to know:

- **One sign carries the whole difference.** The tangent test that orients the
  wedge (`dot(tA, nB) > 0`) is calibrated for convex edges and inverts for
  concave ones. Measured failure mode, by running the new tests against the old
  rule: the wedge lands entirely INSIDE the solid, so the union is a silent
  no-op — the blend does nothing and the volume does not move. It does not
  produce wrong geometry, it produces no geometry.
- **A unioned tool must not overshoot the edge ends.** A subtracted one
  deliberately does (the cut runs clean past the edge); the same overshoot on a
  union stands proud of the end faces as two small tabs.
- **Convex and concave edges are chained separately** in `blendEdges`. They are
  never continuations of one another even when they meet end to end, and a
  mixed chain would be swept as one solid and then applied one way for both.

`ConcaveBlendTests` (8) on an L-beam with exactly one inside corner. Note one
honest limit recorded in the file: `testFillingDoesNotGrowTheBoundingBox` does
NOT catch the sign error — under falsification the union is a no-op, so the box
is unchanged and that test passes. `testConcaveFilletFillsTheCorner` is what
fails. The box test guards the opposite mistake, a tool escaping the notch.

### 3b. Revolve / sweep / loft as B-rep — DONE (2026-08-30)

These three were the last ops producing MESH-ONLY bodies, and the cost did not
announce itself: a revolved body could not be exported to STEP at all, every
blend on one ran the mesh path (~170× slower than OCCT, and the site of the
over-radius crash), and a boolean against one went faceted. Pattern and mirror
were fixed first (they are placements, so a pattern copy just shares the
source's handle); these three needed real construction.

All three build on the SAME profile face an extrude does — `OS3DProfileFace`,
factored out of `extrudedShapeWithOuterLoop:` — so a circle revolved is a real
torus rather than 48 flat strips. Sharing that face is the point: a circle that
stayed round when extruded and went faceted when revolved would be exactly the
inconsistency this work exists to remove.

Three things to know before touching it:

- **The graph stores revolve angles in DEGREES, OCCT wants RADIANS.**
  `KernelOps.revolve` ends in `intersectWithWedge(solid, degrees:)`. Passing 360
  straight through does NOT fail loudly — a 360-radian revolve still closes into
  a full solid — so the mistake looks correct. The parameter is named
  `angleRadians` for that reason.
- **`RevolveAxis` is 2D in the SKETCH PLANE**, not a world axis; lift it through
  the plane basis before handing it to OCCT.
- **A loft section with HOLES has no ThruSections equivalent** (one wire per
  section), so those keep the mesh result rather than silently losing the inner
  loop. Pinned by a test.

**The brep is ASSIGNED, not adopted, and that is deliberate.** Adopting would
replace the render with OCCT's tessellation, which for a revolved circle is
49,928 triangles against the Euclid mesh's 4,608 — measured. See the naming
finding below for why that matters. Assigning still gets everything this work is
for: STEP export, analytic fillets, OCCT booleans. Same split the box primitive
already used.

`RevolveSweepLoftBrepTests` (6), falsified by returning nil from all three
builders: 5 fail, the survivor being the negative test that a holed loft STAYS
mesh-only.

#### Face enumeration was O(n²) — FIXED (2026-08-30)

`faceTable` took **~65 SECONDS** on a 4,608-triangle torus, so revolving a
circle was a minute-long hang on a completely ordinary operation. Found while
giving revolve a B-rep, but entirely pre-existing: the mesh path had always done
this. Now **96 ms**, a 680× improvement, with the face GROUPING unchanged.

Two compounding causes, and the first fix alone was not enough:

- `planarFace`, `smoothRegion` and `cylindricalFace` each rebuilt the whole
  edge→triangle map, while `enumerateFaces` calls them once per unclaimed
  triangle. Sharing one map: 65 s → **41 s**.
- `cylindricalFace` floods the entire SMOOTH COMPONENT before deciding whether a
  cylinder fits. A torus is one smooth component of 4,608 triangles that no
  cylinder fits, so the old code flooded all of them once per seed — 2,304 times
  over. The verdict cannot differ between seeds inside one component, so one
  refusal now settles it for the whole component: 41 s → **96 ms**.

**Why the grouping assertion in the test matters more than the timing one.**
Face enumeration feeds topological naming. Had this refactor changed WHICH
triangles group into a face, every stored `FaceRef` in every saved document
would resolve differently — a silent, unbounded regression that no timing test
would catch. `FaceEnumerationScalingTests` pins the torus entry count (2304),
the box (6 planar), and the cylinder (2 planar + 1 cylindrical) for that reason.

The per-seed entry points still build their own map when none is shared, so the
~30 external callers are unaffected.

#### Booleans ran BOTH kernels and threw one away — FIXED (2026-08-30)

Chased down from "three `DeleteFaceEvalTests` cases sit at ~14 s each". It was
never delete-face: the tell was `testEmptyFaceListIsRejected`, which asserts an
error and does no geometry, taking 6.8 s. The cost was in the shared FIXTURE.

`evalBoolean` ran the Euclid mesh CSG first and the OCCT boolean second — and
`adoptBRep` replaces render, edges AND euclid from OCCT's tessellation, so the
mesh result was computed in full and discarded whenever both operands were
analytic. Measured on a 10 mm box minus a Ø4 cylinder:

| stage | time |
|---|---|
| whole graph evaluate | 7028 ms |
| OCCT boolean | **1 ms** |
| tessellate | 10 ms |
| faceTable | 7 ms |
| **Euclid CSG subtract** | **4877 ms** |

Trying OCCT first and falling back only when it declines: **7028 ms → 74 ms**.
The body is byte-identical (648 triangles, 6 planar + 1 cylindrical).

This was never a test-only problem — every boolean on analytic bodies in the
app paid it, and booleans are core modelling. Knock-on effect on the suite:

**Full unit suite 100.6 s → 18.3 s.** The slowest `DeleteFaceEvalTests` case
went 14.19 s → 0.46 s. That is also the likeliest explanation for the
intermittent runner deaths recorded under gotcha 16 — those tests sat close
enough to the per-test timeout to trip it on a loaded machine.

`BooleanKernelChoiceTests` pins the geometry (exact volume and face counts),
the timing ceiling, and that a genuinely mesh-only operand still booleans
through Euclid.

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

### Agent exec endpoint + Shapr3D recipe extraction (2026-08-31)

`POST /v1/exec` (`openshape3d/Agent/AgentExec.swift`), the parameterized half
`/v1/command` could not provide: one request carries an operation AND its
numbers. Ops: `sketch.create`, `sketch.addEntities`, and
`feature.extrude/revolve/pattern/mirror/boolean`. Protocol reference is
`docs/AGENT_CONTROL.md`.

It goes to `DocumentCommand` + `FeatureKind`, NOT the interactive tool state
machine, so an exec'd model replays through the same graph as a hand-built one.
Profiles resolve by SEED POINT via `ProfileDetector` — callers never enumerate
loop entity ids. Parsing is pure and unit-tested (23 tests); only the main-actor
hop is in `AgentBridge`, per gotcha 1.

**Three traps this pass hit, all worth remembering:**

1. **`FeatureKind.revolve`'s `Expr` is in DEGREES.** `FeatureGraph` converts to
   radians once at the OCCT boundary (`angle.value * .pi / 180`). Converting on
   the way in as well gave a 6.28-DEGREE revolve that rendered as a completely
   plausible solid. Caught only because a Pappus hand-check disagreed by 60x.
   Cross-check a new solid's VOLUME against an independent estimate; "it looks
   right" does not discriminate here.
2. **A boolean adds no body** — it replaces its target in place. Judging success
   by "did a new body id appear" reports a working subtract as a no-op.
3. **`rebuildFrom` bumps `meshRevision` on nodes it did not semantically
   touch**, so revision-diffing cannot tell you a feature failed either. The
   reliable signal is `lastEvalErrors[node.id]`.

**Shapr3D `.shapr` is readable** — see the `shapr-file-format` memory. ZIP →
SQLite. Bodies are Parasolid XT (OCCT cannot read it, and no open converter
exists), but `SketchCurves.Data` is plain JSON and `HistoryTreeNodes` type 2 is
the feature graph, with type-3 literals decoding as `<uint32 tag><payload>`
where tag 3 + 8 bytes is a double in METRES. An extractor lives in the session
scratchpad (`shapr_extract.py`), not in the repo.

Of the 8 tutorial models, only 4 carry sketches + history (Frame, Block casting,
Motorcycle cover, 4 motorcycle wheel); Rod clamp / Piston / Piston rod are
frozen imported solids with no history at all, and Motorcycle ships as a
Parasolid TEXT `.x_t`. Block casting is unreachable regardless — 7 of its 27
steps are `MaterializeImportedBodies`.

**Rebuilt from its extracted recipe:** the 4-motorcycle-wheel revolve (34,775,356
mm3, vs a 36.4M straight-line Pappus estimate — correctly lower because the
profile's large arc bulges inward), then a 63.5 mm cutter, circular-patterned 5x
about the axle and subtracted. Still NOT done on that model: the recipe's Mirror
and second Boolean, and the smaller 12.7 mm bolt-hole circle.

**What exec still cannot do:** fillet, chamfer, shell and the face ops all take
`EdgeRef`/`FaceRef` — topological signatures, not numbers — so they need a way
to NAME an edge or face over the wire. That is a design question, not a
mechanical addition. `Align` has no `FeatureKind` at all.

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
