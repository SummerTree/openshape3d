# OpenShape3D sketch parity — engineering handoff

Updated: 2026-09-19

## Executive status

- Acceptance inventory: **33 passed / 0 failed / 22 incomplete / 1 device-blocked = 56**.
- The 22 incomplete cases comprise **11 partial core cases** and **11 explicitly deferred cases**.
- The full final regression recorded in the status register is green: **1,613/1,613 unit tests** (1 skipped) and **185/185 executed UI tests** (4 skipped), with zero failures.
- PR #29's sketch-parity work was prepared for review. Subsequent iPad-feedback PRs #30 and #31 were merged to `main`; PR #32 covers the re-derived centred-gizmo UI flow.
- The old development IPA from revision `05be744` is obsolete and must not be used as evidence for the current source tree.
- This milestone is not full CAD parity. Passed rows are finite recipes; exclusions and deferred scope remain tracked.

## Authoritative sources

Read these before changing status or resuming acceptance work:

1. `docs/SKETCH_PARITY_OPEN_STATUS.md` — authoritative unfinished-work register and latest evidence.
2. `docs/SKETCH_PARITY_ACCEPTANCE_MATRIX.md` — all 56 acceptance rows.
3. `docs/PARITY_CONTINUATION.md` — operational chronology and latest checkpoints.
4. `docs/SKETCH_PARITY_DEVICE_AB.md` — physical iPad comparison procedure.
5. `docs/testing/sketch-parity-branch-regression-2026-09-13.md` — final branch-wide regression receipt.
6. `docs/testing/ipad-feedback-2026-09-14.md` — recent physical-device findings and fixes.

`SKETCH_PARITY_OPEN_STATUS.md` must be reconciled at every meaningful checkpoint. Do not infer closure from automated tests alone.

## Current completed foundation

- Core line, rectangle, three-point rectangle, circle, arc, annotation, constraint, Trim, save/reopen, selection-state and downstream sketch-to-solid finite recipes have substantial paired coverage.
- Constraint families, Disconnect, Trim/reference handling, dimension types, annotation on/off states, line chaining, numeric entry, keyboard routing and persistence received focused regression and live verification.
- Branch-wide final regression was green before review.
- Recent iPad fixes include:
  - constant on-screen plane-picker tile sizing;
  - rotation-ring numeric keypad and lit handle;
  - typed gizmo Copy behavior;
  - centred transform gizmo and pivot-reposition mode;
  - moving load-time feature-graph badge replay off the initial document-open path.

## Remaining partial core cases

The precise evidence and closure recipe for each row is in `SKETCH_PARITY_OPEN_STATUS.md`.

- **QA-01 Plane selection:** native curved/planar-face observation and any remaining publication reconciliation.
- **QA-02 Entry method:** hover + Space needs physical pointer/device proof.
- **QA-03 Camera angle:** orientation-cube and gesture-orbit behavior remain incomplete.
- **QA-19 Snap categories:** guidepoint combinations remain open.
- **QA-20 Snap zoom:** full zoom/grid matrix remains open.
- **QA-21 Snap feedback:** live pointer-hover delivery remains unproven.
- **QA-24 Multi-selection:** native edge-only selection state, circular-edge radius readout and remaining mixed-selection breadth.
- **QA-29 Badge layout:** device zoom verification remains.
- **QA-40 Keypad transitions:** physical pan/gesture behavior while the keypad is open.
- **QA-45 Move/Rotate/Copy:** reconcile any remaining compact/device and mixed-selection variants listed in the register.
- **QA-53 Layout/accessibility:** retain device-level portrait/landscape, handedness and large-text checks where simulator proof is insufficient.

## Explicitly deferred cases

These are unfinished by design and must not be described as passed:

- QA-14 Ellipse dimensions
- QA-16 Spline
- QA-17 Text sketch
- QA-22 3D references
- QA-28 Dimension selection matrix
- QA-31 Comprehensive unit conversion
- QA-32 Comprehensive expressions/variables
- QA-42 Trim curves (ellipse/spline breadth)
- QA-44 Offset completeness
- QA-46/47 advanced transform/pattern breadth as listed in the matrix
- QA-50/56 advanced downstream Sweep/Loft breadth beyond the finite smoke recipe

Use the acceptance matrix as the final authority if row numbering or grouping differs from this summary.

## Device gate

The physical-device case remains open even though an eligible iPad has previously been connected.

Required steps:

1. Build/archive the exact current candidate revision.
2. Export and inspect a newly signed development IPA; record revision, size, SHA-256, platform, minimum OS, signature and provisioning profile.
3. Reconfirm device connection and provisioning eligibility at installation time.
4. Install and launch that exact build on the iPad.
5. Capture after-fix document-open timings; the earlier device measured about 130 ms load plus 5.7 s badge replay before the replay was moved off-path.
6. Run the 15–20 minute A/B checklist against Shapr3D, emphasizing Pencil/touch hit targets, hover/snap feedback, palm rejection, pinch/pan/orbit, keyboard delivery, keypad obstruction, rotation, handedness and portrait/landscape layouts.
7. Fix findings, repeat affected tests, regenerate the artifact if source changes, and update the status register.

Do not use the immutable `05be744` IPA for this gate; it predates many fixes.

## Known scope exceptions and caveats

- Polygon side count is capped at 10,000 in OpenShape3D. Native Shapr3D has no observed cap and becomes extremely slow; Jason accepted the clone ceiling as a deliberate guard.
- Hover + Space, pointer-hover feedback, physical hardware-keyboard delivery and several gestures cannot be proven by simulator automation alone.
- Variable-linked and multiple-driver dimension-type variants remain unverified.
- System-file-picker import was not proven by the controlled gallery/import diagnostic.
- Some finite passes intentionally exclude advanced ellipse, spline, text, offset, unit, expression and downstream CAD breadth.
- Geometry-only success is insufficient where visual behavior is in scope; labels, leaders, handles, highlights, badges, editors and selection lifecycle require paired evidence.

## Repository and workflow notes

- Preserve unrelated local changes. At handoff time `openshape3d.xcodeproj/project.pbxproj` was modified on `main`; determine ownership before editing or committing it.
- Use one owner for simulator/Xcode/desktop automation at a time.
- Keep exact test results separate. Never add counts from separate runs and present them as one clean gate.
- Preserve failed/invalid fixture attempts in receipts, clearly excluded from passing evidence.
- Update the acceptance matrix, open-status register, receipts and publication evidence together when closing a row.
- Do not merge, release, install or publish externally merely because tests are green; follow the explicit approval and device workflow.

## Recommended next sequence

1. Reconcile current `main`, PR #32 and the modified project file; identify the exact candidate revision.
2. Run the relevant targeted gates, then a clean full serial regression on that revision.
3. Produce and install a fresh signed iPad build.
4. Measure the fixed open path and run the physical A/B checklist.
5. Close device-only portions of QA-02/03/19/20/21/24/29/40/45/53 where evidence supports it.
6. Update `SKETCH_PARITY_OPEN_STATUS.md`, the acceptance matrix and this handoff.
7. Decide separately whether to tackle the 11 deferred cases or declare the bounded core-sketch milestone complete with explicit exclusions.

## Definition of a valid closure

A case closes only when its bounded recipe has:

- implementation or an explicit no-change conclusion;
- a clean relevant regression on the exact source revision;
- paired live native/clone evidence when required;
- Undo/Redo and save/reopen proof where applicable;
- verified publication without predecessor loss or duplicate evidence;
- acceptance-matrix and open-status updates in the same checkpoint.

