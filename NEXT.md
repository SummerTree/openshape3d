# NEXT — handoff for the new machine (written 2026-08-31)

Snapshot of where things stand after the FreeCAD-hardening merge
([PR #22](https://github.com/laanlabs/openshape3d/pull/22), merge `a3e415f`)
and exactly what to pick up next. The living authority is still
`docs/STATUS_AND_NEXT_STEPS.md` (§4 mission 0 records what just landed);
this file is the short version plus the machine-move checklist.

## 1. New-machine setup checklist

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
- The full **UI suite has not run** since the hardening landed (only the
  6 blend UI tests, all green). Kick off the ~44 min suite once and check
  the four health signals listed at the top of STATUS §"test baseline".

## 3. The next mission: kernel-history topological naming

The biggest remaining user pain ("editing an earlier feature breaks later
ones"). The design is agreed and written: **`docs/TOPO_NAMING_HISTORY_DESIGN.md`**
— element maps built from OCCT's own `Modified()/Generated()/IsDeleted()`
history, layered UNDER `SignatureNaming` (never replacing it), zero
persisted-format change, and identity-based blend-edge targeting as the
payoff. Its prerequisites already landed in PR #22 (boolean result
normalization; deterministic face basis R4-N1; kind veto R4-N4).
Sequencing S/M/L per step is in the doc; start with step 1 (bridge history
exposure + per-triangle face-index channel), which changes no behavior.

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
