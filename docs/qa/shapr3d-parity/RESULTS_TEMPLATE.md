# CAD test execution record

Copy this template per case/device/variant. All fields start unmeasured; no case in this pack is an app PASS by default.

## Run identity

| Field | Value |
|---|---|
| Run ID / date / tester | |
| Case ID / model / checkpoint / variant | |
| OpenShape3D commit and build | |
| Shapr3D version and export-capable plan | |
| Device / RAM / OS build / input hardware | |
| Locale / units / navigation / snapping | |
| Reference filename / source URL / SHA-256 | |
| Status: PASS / FAIL / BLOCKED / NOT RUN / GAP / N/A | NOT RUN |
| Scope / priority / defect severity | |

## Lifecycle

| Checkpoint | Geometry | Workflow | Editability | Durability | Evidence |
|---|---|---|---|---|---|
| P1 reviewed Shapr3D baseline | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| P2 blank-project construction | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| P3 initial numeric/geometry check | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| P4 parameter/operand change | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| P5 cancel / undo / redo | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| P6 save / close / cold reopen / further edit | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |
| P7 STEP / STL / applicable DXF round trip | NOT RUN | NOT RUN | NOT RUN | NOT RUN | |

## Numeric evidence

| Metric | Expected | Actual | Tolerance | Method / tool / version | Pass? |
|---|---|---|---|---|---|
| Solid count | | | Exact | | |
| Volume mm3 | | | | | |
| Bounds minimum XYZ mm | | | | | |
| Bounds maximum XYZ mm | | | | | |
| Centroid XYZ mm | | | | | |
| Critical lengths / radii / hole locations | | | | | |
| Validity / closed shells | Valid | | Exact | | |
| Analytic feature classes | | | | | |
| Bidirectional residual volume mm3 | | | | | |
| Surface-distance bound or estimate mm | | | | | |
| Timing / peak memory / file size | | | | | |

## Failure or gap

Starting file and exact reproduction steps:

Expected result:

Actual result and exact error:

Reproductions / attempts:

Affected platforms and input variants:

Recovery through cancel / undo / reopen / retry:

Evidence: before and after native files; STEP/STL; screen recording; target highlight; measurements; crash log; source and output checksums.

Defect ID / owner / severity / intended fix:

Regression test / fix commit / clean retest / reviewer:

If N/A or deferred: scope rationale, approving owner, date, and user impact:
