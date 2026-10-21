# Import QA run qa6-iges

Commit `26451d7b` · 4 cases · 4 PASS · 0 FAIL · gates from TEST_PLAN.md §3 (volume ≤ max(0.001, 1e-5·V) mm³, bounds and centroid ≤ 0.01 mm, symmetric difference ≤ 1e-05, surface distance ≤ 0.01 mm sampled).

| Case | Status | Solids exp/act | Volume expected | Volume app | |err| mm³ | Bounds err mm | Centroid err mm | Sym. diff ratio | Surface dist mm | Analytic | Valid | Import s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| EXT_SOT404 | PASS | 4/4 | 7.2588 | 7.2588 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 5/4 | yes | 0.07 |
| EXT_SOD_323 | PASS | 1/1 | 1.0694 | 1.0694 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 2/1 | yes | 0.09 |
| EXT_SOT23 | PASS | 1/1 | 3.5528 | 3.5528 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.40 |
| EXT_RLF_12545 | PASS | 3/3 | 718.9772 | 718.9772 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 3/3 | yes | 0.06 |

## Advisory findings (not gates)

- EXT_SOT404: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge1', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face1', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Ed
- EXT_SOD_323: no self-intersections (BOP) — [{'status': 'selfIntersect', 'subshape': 'Edge69', 'type': 'Edge'}, {'status': 'selfIntersect', 'subshape': 'Face18', 'type': 'Face'}, {'status': 'selfIntersect', 'subshape': 'Edge86', 'type': 'Edge'}

## Timing and memory

| Case | Import s | Check s | Export s | Inspect s | RSS before MB | RSS after MB |
|---|---|---|---|---|---|---|
| EXT_SOT404 | 0.07 | 0.54 | 0.02 | 3.38 | 375.5000 | 493.8000 |
| EXT_SOD_323 | 0.09 | 0.41 | 0.01 | 1.87 | 493.8000 | 591.4000 |
| EXT_SOT23 | 0.40 | 1.05 | 0.14 | 8.53 | 591.4000 | 616.5000 |
| EXT_RLF_12545 | 0.06 | 0.32 | 0.01 | 3.26 | 616.5000 | 619.3000 |
