# NEXT — handoff for the new machine (written 2026-08-31)

Snapshot of where things stand after the FreeCAD-hardening merge
([PR #22](https://github.com/laanlabs/openshape3d/pull/22), merge `a3e415f`)
and exactly what to pick up next. The living authority is still
`docs/STATUS_AND_NEXT_STEPS.md` (§4 mission 0 records what just landed);
this file is the short version plus the machine-move checklist.

## 1. New-machine setup checklist — DONE on this machine (2026-08-31)

All four steps below were completed: LFS libs verified real, unit suite green
(**1034 tests, ~18 s** — 21 above the handoff count, from the debug-tooling
tranche the same day, see §2b), FreeCAD re-cloned to
`~/projects/reference/FreeCAD`, and the UDID problem solved for good —
`scripts/run_sim.sh` and the drive skill now resolve the simulator BY NAME.
Two machine quirks worth knowing, both now handled in the scripts:
`xcode-select` points at CommandLineTools here, so every `xcodebuild`/`xcrun`
needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the real fix
is `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`); and
port 8787 is occupied by an unrelated local service, so launch the agent
bridge with `SIMCTL_CHILD_OS3D_AGENT_PORT=8899`.

1. `git lfs install` **before** cloning — `ThirdParty/OCCT.xcframework`'s
   static libs come through LFS (headers are plain files). No OCCT rebuild
   is needed; the README's "not checked in" note predates the LFS setup.
2. Xcode 26+, then run the unit suite to prove the toolchain:
   ```
   xcodebuild test -project openshape3d.xcodeproj -scheme openshape3d \
     -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
     -parallel-testing-enabled NO -only-testing:openshape3dTests
   ```
   Expected: **990+ tests, 0 failures, ~18 s.** (`-parallel-testing-enabled NO`
   always; one simulator, one xcodebuild at a time.)
3. Re-clone the FreeCAD reference (it lives OUTSIDE the repo and does not
   travel with it):
   ```
   git clone --depth 1 --branch 1.0.2 https://github.com/FreeCAD/FreeCAD.git ~/projects/reference/FreeCAD
   git -C ~/projects/reference/FreeCAD fetch --depth 1 origin main:refs/remotes/origin/main
   ```
   Licensing rules for using it are at the top of `docs/FREECAD_PLAYBOOK.md`
   (LGPL → MIT: patterns only, never code).
4. Simulator UDIDs are machine-specific — the UDID baked into
   `.claude/skills/drive-openshape3d` and old notes (`69DB84F4-…`) will be
   wrong here. `xcrun simctl list devices | grep "iPad Pro 13"` for the new
   one; destination-by-name in xcodebuild commands works unchanged.

## 2. In flight — do first

- Both big branches are merged (PR #22 hardening, PR #23 agent-exec) and
  the combined `main` was verified on 2026-08-31: **1013 unit tests,
  0 failures, ~18.6 s**, with `docs/STATUS_AND_NEXT_STEPS.md` carrying
  both new sections. Nothing to re-check there.
- ~~The full **UI suite has not run** since the hardening landed~~ — **RAN
  2026-09-01** covering the debug tranche + topo-naming 1–5a + exec identity
  ops: 104 executed, one long-run flake (clean in isolation), 2
  idle-timeouts, 46m19s. Measurement + reading in STATUS §"test baseline".

## 2b. Debug-tooling tranche — LANDED 2026-08-31 (this machine's first work)

The tutorial-model thread (§4b) kept surfacing kernel bugs that each cost a
hand-built repro, so the FreeCAD mining focus shifted to its DEBUGGING
machinery first. Landed: geometry health report (`GET /v1/check`, FreeCAD's
Check Geometry re-derived), automatic failing-op capture bundles +
`POST /v1/capture` + `scripts/fetch_captures.sh`, replay harness with
committed regression fixtures, and per-feature `evalErrors` in `/v1/state`.
Playbook rows D1–D3; workflow doc **`docs/KERNEL_DEBUG_TOOLING.md`**; STATUS
§4 mission 0c is the record. When the tutorial-model thread resumes, run
`/v1/check?bop=1` the moment a rebuild looks wrong, and promote any capture
bundle a failure leaves behind.

## 3. The next mission: kernel-history topological naming

The biggest remaining user pain ("editing an earlier feature breaks later
ones"). The design is agreed and written: **`docs/TOPO_NAMING_HISTORY_DESIGN.md`**
— element maps built from OCCT's own `Modified()/Generated()/IsDeleted()`
history, layered UNDER `SignatureNaming` (never replacing it), zero
persisted-format change, and identity-based blend-edge targeting as the
payoff. Its prerequisites already landed in PR #22 (boolean result
normalization; deterministic face basis R4-N1; kind veto R4-N4).
Sequencing S/M/L per step is in the doc. **Steps 1–5a landed 2026-08-31**
(eleven commits, e1506cd…5730e5e — 5a made blends/shell/deleteFace REPORT
history instead of erasing names: cut → blend → cut keeps identities intact
and a fillet face is named for its crease). What's left of the mission:
**5b opportunistic ref upgrade** (legacy refs gain names during rebuilds —
touches undo/persistence, design it against DocumentSession's command flow
before coding), revolve/sweep/loft naming, and replace-face composition.
**Fillet/chamfer/shell over /v1/exec LANDED** with `GET /v1/edges|/v1/faces`
discovery — the Motorcycle-cover tutorial rebuild (§4b) is now unblocked;
deleteFace/replaceFace over exec are a mechanical follow-on.
Earlier progress detail below is HISTORY:

**Steps 1–4 landed 2026-08-31**
(nine commits, e1506cd…edd0300): face channel, boolean + extrude ancestry,
ElementName + creation-op naming, boolean name composition
(inherit/split-mint/section), name-first FaceRef resolution with the
ambiguity margin, and identity-addressed blends (EdgeRef.faceNames +
blend-by-edge-index — the "rebuild broke my fillet" fix, pinned by a test
where a drifted signature rebinds to the wrong hole without the name and
the right one with it). Old documents load unchanged; legacy refs resolve
exactly as before. Remaining: step 5 (opportunistic ref upgrade so old refs
gain names during rebuilds; modifier-op history so blends/shells stop
erasing downstream names) and revolve/sweep/loft naming (blocked on their
assign-vs-adopt render split). Also still open: wiring fillet/shell over
/v1/exec, which the edge-name vocabulary now makes expressible (§4b).

## 4. Smaller follow-ups, in rough priority order

1. **Sketch conflict diagnosis, stage 2** — residual attribution: record
   residual-row → constraint/dimension UUID provenance in
   `SketchSolverBridge.buildSystem`, surface RED glyphs on the conflicting
   constraints in `SketchConstraintOverlay` (the chip from PR #22 says
   *that* there's a conflict; this says *which*). Then stage 3: rank-based
   add-time diagnosis à la planegcs `diagnose()` (re-implemented, not
   ported), so "refused: over-constrained" can name the two clashing
   dimensions. Refs: `src/Mod/Sketcher/App/planegcs/GCS.cpp` in the
   reference checkout.
2. **Residual normalization** in `Constraints.swift` — the solver-gate
   tolerance (1e-3) compares mixed-unit residuals; normalize so the gate
   is scale-honest (noted as a fast-follow in playbook S1).
3. **Trim re-anchor for curved fragments** — the PR #22 rule re-anchors by
   point-weld and single-fragment `.whole` transfer; extend to arc/circle
   fragment cases (`TrimCommand` in `openshape3d/Model/Commands.swift`).
4. **UI-suite geometry assertions (review R3-D)** — no UI test asserts a
   geometry value; `SelectionInfoBar` exposes exact Volume/Bounds/Area
   strings as the hook. Also promote `docs/occt-fuzz-harness.swift.txt`
   into a real target.
5. **Pre-existing review backlog** (unchanged by PR #22, listed in
   `docs/ARCHITECTURE_REVIEW_2026-08-25.md` / STATUS §4.5): off-main
   eval/preview service (S1), scene caching + GPU buffer pooling (S2),
   `ToolLifecycle` registry refactor (S3); Phase-D deferred items
   (transform-as-a-feature, sketch patterns, EdgeRef dimensioning…).
6. **Modeling parity** — `docs/MODELING_PARITY_GOALS.md` §5 sequencing:
   G7 tutorial walls → G8 editable history operands → G9 tool variants,
   with G5 sketch completeness (splines!) in parallel. Note that doc's
   §2/G1/G2 are stale (chamfer/shell are OCCT now, not mesh).

## 4b. The Shapr3D tutorial-model thread (paused, 2026-08-31)

Goal as posed: import the tutorial models and rebuild them through the app's
own UI, as a real workout for the modeling stack. Where it got to:

- **`.shapr` is decoded.** ZIP -> SQLite. Bodies are Parasolid XT and stay
  unreadable (OCCT cannot read Parasolid, no open converter exists), but
  sketches are plain JSON and `HistoryTreeNodes` type 2 is the feature graph.
  `scripts/shapr_extract.py` dumps a model to a recipe; its docstring holds the
  format notes and the Google Drive ids for all eight models (PR #25).
- **`scripts/rebuild_wheel.py`** rebuilds "4 motorcycle wheel" through
  `/v1/exec` and is a manual regression for that endpoint — it documents the
  expected volumes and why each is right.
- **Triage: only 4 of the 8 models are reachable at all.** Frame, Block casting,
  Motorcycle cover, 4 motorcycle wheel carry sketches + history. Rod clamp /
  Piston / Piston rod are frozen imported solids (one body, zero sketches);
  Motorcycle ships as a Parasolid TEXT `.x_t`. Block casting is unreachable
  anyway — 7 of its 27 steps are `MaterializeImportedBodies`.
- **What blocks the rest:** the Motorcycle cover needs Fillet and Shell, and
  `/v1/exec` cannot express those. They take `EdgeRef`/`FaceRef` — topological
  signatures, not numbers — so exec needs a way to NAME an edge or face over
  the wire. That is the same identity problem §3 is about, so it is probably
  cheaper AFTER the topological-naming mission, not before. The wheel itself is
  also not 1:1 yet: its Mirror, second Boolean and 12.7 mm bolt holes are undone.

## 5. What PR #22 changed (so new work builds on it, not around it)

- Kernel ops return typed failures: prefer `OCCTKernel.filletResult/
  chamferResult/shellResult/booleanResult/removingFacesResult` in new code;
  the optional variants are compatibility shims.
- Pick tolerances: always `OCCTKernel.matchTolerance(for:)` — never a
  fraction of the body's AABB.
- Boolean results are already unwrapped/unified/validated; a
  body-splitting cut reports `solidCount > 1`.
- Sketch writeback is gated: check `SketchSolverBridge.solveOutcome`'s
  `structuralResidual` before writing solved geometry anywhere new.
- Every mined-from-FreeCAD pattern must get a row in
  `docs/FREECAD_PLAYBOOK.md` (pattern | ref | classification | change |
  defect | test) — keep the ledger honest.

Delete this file once §2 and §3 are underway; STATUS stays the authority.
