# Import QA run qa3-ext

Commit `8eec625a` · 32 cases · 31 PASS · 1 FAIL · gates from TEST_PLAN.md §3 (volume ≤ max(0.001, 1e-5·V) mm³, bounds and centroid ≤ 0.01 mm, symmetric difference ≤ 1e-05, surface distance ≤ 0.01 mm sampled).

| Case | Status | Solids exp/act | Volume expected | Volume app | |err| mm³ | Bounds err mm | Centroid err mm | Sym. diff ratio | Surface dist mm | Analytic | Valid | Import s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| EXT_0603_SMD | PASS | 1/1 | 0.3835 | 0.3835 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.11 |
| EXT_0805_SMD | PASS | 1/1 | 1.8768 | 1.8768 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.30 |
| EXT_1206_SMD | PASS | 1/1 | 5.0126 | 5.0126 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.31 |
| EXT_1210_SMD | PASS | 1/1 | 19.4072 | 19.4072 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.02 |
| EXT_1812_SMD | PASS | 1/1 | 22.8654 | 22.8654 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.30 |
| EXT_2225_SMD | PASS | 1/1 | 50.9976 | 50.9976 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.13 |
| EXT_2512_SMD | PASS | 1/1 | 30.2751 | 30.2751 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.39 |
| EXT_CAP_50SGV_8_10 | PASS | 1/1 | 560.2296 | 560.2296 | 0.000001 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.61 |
| EXT_EPL22_6_16 | PASS | 1/1 | 1339.8229 | 1339.8229 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.06 |
| EXT_I22_2_5_16 | PASS | 1/1 | 802.0853 | 802.0853 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.06 |
| EXT_I22_2_5_16withEPL22_6_16 | PASS | 2/2 | 2141.9082 | 2141.9082 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 2/2 | yes | 0.10 |
| EXT_MSOP_10 | PASS | 1/1 | 9.3518 | 9.3518 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.17 |
| EXT_RLF_12545 | PASS | 3/3 | 718.9772 | 718.9772 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 3/3 | yes | 0.05 |
| EXT_RLF_7030 | PASS | 1/1 | 146.6143 | 146.6143 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.07 |
| EXT_SMB_DO_214AA | PASS | 1/1 | 34.7183 | 34.7183 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.05 |
| EXT_SMC_DO_214AB | PASS | 1/1 | 91.0930 | 91.0930 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.05 |
| EXT_SOD_323 | FAIL | 1/1 | 1.0694 | 1.0694 | 0.000000 | 0.46057 | 0.00000 | 0 | 0.52405 | 1/1 | yes | 0.08 |
| EXT_SOD_523 | PASS | 1/1 | 0.7928 | 0.7928 | 0.000000 | 0.00000 | 0.00000 | 0 | 0 | 1/1 | yes | 0.03 |
| EXT_SOT23 | PASS | 1/1 | 3.5528 | 3.5528 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.40 |
| EXT_SOT404 | PASS | 4/4 | 7.2588 | 7.2588 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 5/4 | yes | 0.08 |
| EXT_SOT428_DPAK | PASS | 1/1 | 93.1555 | 93.1555 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.07 |
| EXT_SOT_323_3 | PASS | 1/1 | 2.2343 | 2.2343 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.04 |
| EXT_SOT_96 | PASS | 1/1 | 25.8773 | 25.8773 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.22 |
| EXT_TCMT1107_4 | PASS | 1/1 | 21.9684 | 21.9684 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.07 |
| EXT_TSM_103_01_L_DV_A | PASS | 1/1 | 103.5080 | 103.5080 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.40 |
| EXT_TSM_104_01_L_DV_A | PASS | 1/1 | 134.7128 | 134.7128 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.47 |
| EXT_TSS0P_8 | PASS | 1/1 | 13.5084 | 13.5084 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.14 |
| EXT_VC0603_SMD | PASS | 1/1 | 0.3835 | 0.3835 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.12 |
| EXT_Schenkel | PASS | 1/1 | 121134.0994 | 121134.1159 | 0.016466 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 1.67 |
| EXT_as1-ac-214 | PASS | 18/18 | 765931.7462 | 765931.7462 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 18/18 | yes | 0.39 |
| EXT_as1-ac-214_small | PASS | 5/5 | 104939.9561 | 104939.9561 | 0.000032 | 0.00000 | 0.00000 | 0 | 0.00000 | 5/5 | yes | 0.90 |
| EXT_geometry_out | PASS | —/— | — | — | — | — | — | — | — | —/— | — | 0.00 |

## Failures

### EXT_SOD_323 — SOD_323.stp
- **sheet bodies**: expected 1, got 0
- **bounds**: max coordinate error 0.460574 mm, gate 0.01
- **round-trip bounds**: max error 0.460574 mm
- **surface distance (sampled estimate)**: max 0.52405 mm over [126, 355] samples at 0.02 deflection
- repro: `os3d_exec` {"op": "document.import", "args": {"path": "/Users/jclaan/projects/reference/FreeCAD/src/Mod/Idf/Idflibs/SOD_323.stp"}}


## Advisory findings (not gates)

- EXT_CAP_50SGV_8_10: no self-intersections (BOP) — [{'status': 'c0Continuity', 'subshape': 'Edge62', 'type': 'Edge'}, {'status': 'c0Continuity', 'subshape': 'Edge63', 'type': 'Edge'}, {'status': 'c0Continuity', 'subshape': 'Edge64', 'type': 'Edge'}, {
- EXT_EPL22_6_16: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge55', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_I22_2_5_16: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge55', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_I22_2_5_16withEPL22_6_16: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge27', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face11', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_RLF_7030: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge5', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face61', 'type': 'Face'}]
- EXT_SMB_DO_214AA: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge69', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face18', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_SMC_DO_214AB: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge61', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_SOT_96: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge94', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_Schenkel: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge359', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face58', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': 
- EXT_as1-ac-214_small: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge1', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face1', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Ed

## Timing and memory

| Case | Import s | Check s | Export s | Inspect s | RSS before MB | RSS after MB |
|---|---|---|---|---|---|---|
| EXT_0603_SMD | 0.11 | 0.77 | 0.03 | 5.89 | 358.7000 | 518.2000 |
| EXT_0805_SMD | 0.30 | 0.69 | 0.03 | 5.43 | 518.0000 | 553.0000 |
| EXT_1206_SMD | 0.31 | 0.77 | 0.03 | 5.63 | 553.0000 | 576.8000 |
| EXT_1210_SMD | 0.02 | 0.01 | 0.00 | 0.04 | 576.8000 | 571.8000 |
| EXT_1812_SMD | 0.30 | 0.64 | 0.03 | 4.45 | 571.7000 | 583.2000 |
| EXT_2225_SMD | 0.13 | 0.24 | 0.04 | 1.71 | 583.2000 | 580.8000 |
| EXT_2512_SMD | 0.39 | 0.63 | 0.11 | 5.00 | 580.8000 | 587.2000 |
| EXT_CAP_50SGV_8_10 | 0.61 | 0.31 | 0.04 | 4.24 | 587.2000 | 597.6000 |
| EXT_EPL22_6_16 | 0.06 | 0.05 | 0.01 | 0.26 | 597.7000 | 589.4000 |
| EXT_I22_2_5_16 | 0.06 | 0.05 | 0.01 | 0.26 | 589.2000 | 589.8000 |
| EXT_I22_2_5_16withEPL22_6_16 | 0.10 | 0.18 | 0.01 | 0.83 | 589.7000 | 589.9000 |
| EXT_MSOP_10 | 0.17 | 0.17 | 0.02 | 1.22 | 589.9000 | 593.4000 |
| EXT_RLF_12545 | 0.05 | 0.14 | 0.01 | 1.14 | 593.4000 | 606.2000 |
| EXT_RLF_7030 | 0.07 | 0.23 | 0.01 | 1.77 | 606.2000 | 616.2000 |
| EXT_SMB_DO_214AA | 0.05 | 0.06 | 0.01 | 0.26 | 616.2000 | 616.3000 |
| EXT_SMC_DO_214AB | 0.05 | 0.06 | 0.01 | 0.26 | 616.3000 | 616.3000 |
| EXT_SOD_323 | 0.08 | 0.18 | 0.01 | 1.66 | 616.3000 | 620.1000 |
| EXT_SOD_523 | 0.03 | 0.03 | 0.01 | 0.08 | 620.1000 | 620.1000 |
| EXT_SOT23 | 0.40 | 1.18 | 0.14 | 7.78 | 620.0000 | 631.0000 |
| EXT_SOT404 | 0.08 | 0.06 | 0.02 | 0.33 | 631.0000 | 629.8000 |
| EXT_SOT428_DPAK | 0.07 | 0.07 | 0.01 | 0.35 | 629.8000 | 630.0000 |
| EXT_SOT_323_3 | 0.04 | 0.05 | 0.01 | 0.30 | 630.0000 | 630.1000 |
| EXT_SOT_96 | 0.22 | 0.60 | 0.04 | 2.43 | 630.1000 | 632.0000 |
| EXT_TCMT1107_4 | 0.07 | 0.08 | 0.01 | 0.49 | 632.0000 | 631.8000 |
| EXT_TSM_103_01_L_DV_A | 0.40 | 0.49 | 0.07 | 3.21 | 631.8000 | 645.5000 |
| EXT_TSM_104_01_L_DV_A | 0.47 | 0.58 | 0.08 | 4.24 | 645.5000 | 652.0000 |
| EXT_TSS0P_8 | 0.14 | 0.15 | 0.02 | 0.91 | 651.8000 | 649.2000 |
| EXT_VC0603_SMD | 0.12 | 0.75 | 0.03 | 5.56 | 649.2000 | 667.0000 |
| EXT_Schenkel | 1.67 | 0.69 | 0.22 | 5.24 | 667.0000 | 735.2000 |
| EXT_as1-ac-214 | 0.39 | 0.17 | 0.04 | 1.76 | 735.2000 | 716.5000 |
| EXT_as1-ac-214_small | 0.90 | 0.18 | 0.09 | 1.52 | 716.5000 | 724.7000 |
| EXT_geometry_out | 0.00 | — | — | — | — | 725.0000 |
