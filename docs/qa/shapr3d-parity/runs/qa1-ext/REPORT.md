# Import QA run qa1-ext

Commit `8eec625a` · 32 cases · 29 PASS · 3 FAIL · gates from TEST_PLAN.md §3 (volume ≤ max(0.001, 1e-5·V) mm³, bounds and centroid ≤ 0.01 mm, symmetric difference ≤ 1e-05, surface distance ≤ 0.01 mm sampled).

| Case | Status | Solids exp/act | Volume expected | Volume app | |err| mm³ | Bounds err mm | Centroid err mm | Sym. diff ratio | Surface dist mm | Analytic | Valid | Import s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| EXT_Schenkel | PASS | 1/1 | 121134.0994 | 121134.1159 | 0.016466 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 1.59 |
| EXT_as1-ac-214 | PASS | 18/18 | 765931.7462 | 765931.7462 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 18/18 | yes | 0.40 |
| EXT_as1-ac-214_small | PASS | 5/5 | 104939.9561 | 104939.9561 | 0.000032 | 0.00000 | 0.00000 | 0 | 0.00000 | 5/5 | yes | 0.84 |
| EXT_geometry_out | PASS | —/— | — | — | — | — | — | — | — | —/— | — | 0.00 |
| EXT_0603_SMD | PASS | 1/1 | 0.3835 | 0.3835 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.12 |
| EXT_0805_SMD | PASS | 1/1 | 1.8768 | 1.8768 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.30 |
| EXT_1206_SMD | PASS | 1/1 | 5.0126 | 5.0126 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.30 |
| EXT_1210_SMD | PASS | 1/1 | 19.4072 | 19.4072 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.02 |
| EXT_1812_SMD | PASS | 1/1 | 22.8654 | 22.8654 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.29 |
| EXT_2225_SMD | PASS | 1/1 | 50.9976 | 50.9976 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.10 |
| EXT_2512_SMD | PASS | 1/1 | 30.2751 | 30.2751 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.32 |
| EXT_CAP_50SGV_8_10 | PASS | 1/1 | 560.2296 | 560.2296 | 0.000001 | 0.00077 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.60 |
| EXT_EPL22_6_16 | PASS | 1/1 | 1339.8229 | 1339.8229 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.07 |
| EXT_I22_2_5_16 | PASS | 1/1 | 802.0853 | 802.0853 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.06 |
| EXT_I22_2_5_16withEPL22_6_16 | PASS | 2/2 | 2141.9082 | 2141.9082 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 2/2 | yes | 0.11 |
| EXT_MSOP_10 | PASS | 1/1 | 9.3518 | 9.3518 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.17 |
| EXT_RLF_12545 | PASS | 3/3 | 718.9772 | 718.9772 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 3/3 | yes | 0.06 |
| EXT_RLF_7030 | PASS | 1/1 | 146.6143 | 146.6143 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.08 |
| EXT_SMB_DO_214AA | PASS | 1/1 | 34.7183 | 34.7183 | 0.000000 | 0.00188 | 0 | 0 | 0.00000 | 1/1 | yes | 0.05 |
| EXT_SMC_DO_214AB | PASS | 1/1 | 91.0930 | 91.0930 | 0.000000 | 0.00188 | 0 | 0 | 0.00000 | 1/1 | yes | 0.05 |
| EXT_SOD_323 | FAIL | 0/1 | 0 | 1.2911 | 1.291147 | 0.00000 | 0 | — | — | 1/1 | yes | 0.07 |
| EXT_SOD_523 | PASS | 1/1 | 0.7928 | 0.7928 | 0.000000 | 0.00000 | 0.00000 | 0 | 0 | 1/1 | yes | 0.02 |
| EXT_SOT23 | FAIL | 0/1 | 0 | 2.8850 | 2.884993 | 0.00043 | 0 | — | — | 1/1 | yes | 0.25 |
| EXT_SOT404 | FAIL | 4/4 | 455.3892 | 7.2588 | 448.130456 | 9.08109 | 6.69802 | 0 | 11.03754 | 4/4 | yes | 0.07 |
| EXT_SOT428_DPAK | PASS | 1/1 | 93.1555 | 93.1555 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.07 |
| EXT_SOT_323_3 | PASS | 1/1 | 2.2343 | 2.2343 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.04 |
| EXT_SOT_96 | PASS | 1/1 | 25.8773 | 25.8773 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.19 |
| EXT_TCMT1107_4 | PASS | 1/1 | 21.9684 | 21.9684 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.08 |
| EXT_TSM_103_01_L_DV_A | PASS | 1/1 | 103.5080 | 103.5080 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.41 |
| EXT_TSM_104_01_L_DV_A | PASS | 1/1 | 134.7128 | 134.7128 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.49 |
| EXT_TSS0P_8 | PASS | 1/1 | 13.5084 | 13.5084 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.13 |
| EXT_VC0603_SMD | PASS | 1/1 | 0.3835 | 0.3835 | 0.000000 | 0.00000 | 0.00000 | 0 | 0.00000 | 1/1 | yes | 0.11 |

## Failures

### EXT_SOD_323 — SOD_323.stp
- **solid count**: expected 0, got 1
- **volume**: expected 0.000000, got 1.291147, |err| 1.29115, gate 0.001
- (advisory) **no self-intersections (BOP)**: [{'status': 'selfIntersect', 'subshape': 'Edge317', 'type': 'Edge'}, {'status': 'selfIntersect', 'subshape': 'Face4', 'type': 'Face'}, {'status': 'selfIntersect', 'subshape': 'Vertex295', 'type': 'Ver
- repro: `os3d_exec` {"op": "document.import", "args": {"path": "/Users/jclaan/projects/reference/FreeCAD/src/Mod/Idf/Idflibs/SOD_323.stp"}}

### EXT_SOT23 — SOT23.stp
- **solid count**: expected 0, got 1
- **volume**: expected 0.000000, got 2.884993, |err| 2.88499, gate 0.001
- (advisory) **no self-intersections (BOP)**: [{'status': 'selfIntersect', 'subshape': 'Vertex130', 'type': 'Vertex'}, {'status': 'selfIntersect', 'subshape': 'Vertex144', 'type': 'Vertex'}, {'status': 'selfIntersect', 'subshape': 'Vertex86', 'ty
- repro: `os3d_exec` {"op": "document.import", "args": {"path": "/Users/jclaan/projects/reference/FreeCAD/src/Mod/Idf/Idflibs/SOT23.stp"}}

### EXT_SOT404 — SOT404.stp
- **volume**: expected 455.389211, got 7.258755, |err| 448.13, gate 0.00455389
- **bounds**: max coordinate error 9.08109 mm, gate 0.01
- (advisory) **face classes match reference (diagnostic)**: app planar/cyl/other 57/1/0, reference 74/1/0
- **round-trip volume**: error -448.13 mm3, gate 0.00455389
- **round-trip centroid**: max coordinate error 6.69802 mm
- **round-trip bounds**: max error 9.08099 mm
- **surface distance (sampled estimate)**: max 11.0375 mm over [466, 552] samples at 0.02 deflection
- repro: `os3d_exec` {"op": "document.import", "args": {"path": "/Users/jclaan/projects/reference/FreeCAD/src/Mod/Idf/Idflibs/SOT404.stp"}}


## Advisory findings (not gates)

- EXT_Schenkel: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge359', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face58', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': 
- EXT_as1-ac-214_small: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge1', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face1', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Ed
- EXT_CAP_50SGV_8_10: no self-intersections (BOP) — [{'status': 'c0Continuity', 'subshape': 'Edge62', 'type': 'Edge'}, {'status': 'c0Continuity', 'subshape': 'Edge63', 'type': 'Edge'}, {'status': 'c0Continuity', 'subshape': 'Edge64', 'type': 'Edge'}, {
- EXT_EPL22_6_16: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge55', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_I22_2_5_16: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge55', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_I22_2_5_16withEPL22_6_16: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge27', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face11', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_RLF_7030: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge5', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face61', 'type': 'Face'}]
- EXT_SMB_DO_214AA: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge69', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face18', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_SMC_DO_214AB: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge61', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '
- EXT_SOD_323: no self-intersections (BOP) — [{'status': 'selfIntersect', 'subshape': 'Edge317', 'type': 'Edge'}, {'status': 'selfIntersect', 'subshape': 'Face4', 'type': 'Face'}, {'status': 'selfIntersect', 'subshape': 'Vertex295', 'type': 'Ver
- EXT_SOT23: no self-intersections (BOP) — [{'status': 'selfIntersect', 'subshape': 'Vertex130', 'type': 'Vertex'}, {'status': 'selfIntersect', 'subshape': 'Vertex144', 'type': 'Vertex'}, {'status': 'selfIntersect', 'subshape': 'Vertex86', 'ty
- EXT_SOT404: face classes match reference (diagnostic) — app planar/cyl/other 57/1/0, reference 74/1/0
- EXT_SOT_96: no self-intersections (BOP) — [{'status': 'invalidCurveOnSurface', 'subshape': 'Edge94', 'type': 'Edge'}, {'status': 'invalidCurveOnSurface', 'subshape': 'Face15', 'type': 'Face'}, {'status': 'invalidCurveOnSurface', 'subshape': '

## Timing and memory

| Case | Import s | Check s | Export s | Inspect s | RSS before MB | RSS after MB |
|---|---|---|---|---|---|---|
| EXT_Schenkel | 1.59 | 0.69 | 0.10 | 11.25 | 353.2000 | 560.5000 |
| EXT_as1-ac-214 | 0.40 | 0.17 | 0.05 | 1.77 | 560.5000 | 545.3000 |
| EXT_as1-ac-214_small | 0.84 | 0.18 | 0.02 | 1.56 | 543.5000 | 559.4000 |
| EXT_geometry_out | 0.00 | — | — | — | — | 559.8000 |
| EXT_0603_SMD | 0.12 | 0.76 | 0.02 | 14.34 | 559.8000 | 603.2000 |
| EXT_0805_SMD | 0.30 | 0.69 | 0.02 | 14.08 | 603.2000 | 595.2000 |
| EXT_1206_SMD | 0.30 | 0.77 | 0.02 | 13.97 | 595.2000 | 632.2000 |
| EXT_1210_SMD | 0.02 | 0.01 | 0.01 | 0.05 | 632.2000 | 626.4000 |
| EXT_1812_SMD | 0.29 | 0.64 | 0.02 | 14.96 | 626.3000 | 630.1000 |
| EXT_2225_SMD | 0.10 | 0.25 | 0.01 | 4.76 | 630.1000 | 631.8000 |
| EXT_2512_SMD | 0.32 | 0.64 | 0.03 | 20.48 | 631.8000 | 636.8000 |
| EXT_CAP_50SGV_8_10 | 0.60 | 0.33 | 0.01 | 9.59 | 636.8000 | 644.2000 |
| EXT_EPL22_6_16 | 0.07 | 0.06 | 0.01 | 0.40 | 644.2000 | 636.4000 |
| EXT_I22_2_5_16 | 0.06 | 0.06 | 0.01 | 0.39 | 636.4000 | 635.8000 |
| EXT_I22_2_5_16withEPL22_6_16 | 0.11 | 0.18 | 0.02 | 0.84 | 635.9000 | 636.1000 |
| EXT_MSOP_10 | 0.17 | 0.18 | 0.02 | 2.56 | 636.1000 | 638.9000 |
| EXT_RLF_12545 | 0.06 | 0.14 | 0.01 | 1.18 | 638.5000 | 653.2000 |
| EXT_RLF_7030 | 0.08 | 0.23 | 0.01 | 3.22 | 653.2000 | 662.7000 |
| EXT_SMB_DO_214AA | 0.05 | 0.06 | 0.01 | 0.39 | 662.7000 | 662.8000 |
| EXT_SMC_DO_214AB | 0.05 | 0.06 | 0.01 | 0.39 | 662.8000 | 663.7000 |
| EXT_SOD_323 | 0.07 | 0.47 | 0.02 | 0.11 | 663.7000 | 818.6000 |
| EXT_SOD_523 | 0.02 | 0.02 | 0.01 | 0.12 | 818.6000 | 818.8000 |
| EXT_SOT23 | 0.25 | 1.26 | 0.02 | 0.13 | 818.7000 | 828.9000 |
| EXT_SOT404 | 0.07 | 0.05 | 0.01 | 0.27 | 828.9000 | 829.0000 |
| EXT_SOT428_DPAK | 0.07 | 0.07 | 0.01 | 0.55 | 829.0000 | 829.9000 |
| EXT_SOT_323_3 | 0.04 | 0.05 | 0.01 | 0.49 | 829.9000 | 828.5000 |
| EXT_SOT_96 | 0.19 | 0.66 | 0.03 | 3.62 | 828.5000 | 668.5000 |
| EXT_TCMT1107_4 | 0.08 | 0.08 | 0.01 | 0.90 | 668.5000 | 671.6000 |
| EXT_TSM_103_01_L_DV_A | 0.41 | 0.50 | 0.07 | 7.40 | 671.6000 | 725.6000 |
| EXT_TSM_104_01_L_DV_A | 0.49 | 0.61 | 0.09 | 10.47 | 725.6000 | 773.0000 |
| EXT_TSS0P_8 | 0.13 | 0.16 | 0.02 | 1.82 | 761.1000 | 753.5000 |
| EXT_VC0603_SMD | 0.11 | 0.76 | 0.02 | 14.20 | 753.4000 | 797.5000 |
