# Import QA run qa1

Commit `8eec625a` · 32 cases · 29 PASS · 3 FAIL · gates from TEST_PLAN.md §3 (volume ≤ max(0.001, 1e-5·V) mm³, bounds and centroid ≤ 0.01 mm, symmetric difference ≤ 1e-05, surface distance ≤ 0.01 mm sampled).

| Case | Status | Solids exp/act | Volume expected | Volume app | |err| mm³ | Bounds err mm | Centroid err mm | Sym. diff ratio | Surface dist mm | Analytic | Valid | Import s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M01_block | PASS | 1/1 | 12000.0000 | 12000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.05 |
| M01_block | PASS | 1/1 | 12000.0000 | 12000.0000 | 0.000000 | 0.00000 | — | — | — | 0/1 | NO | 0.00 |
| M02_four_hole_plate | PASS | 1/1 | 31095.2213 | 31095.2213 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.05 |
| M02_four_hole_plate | PASS | 1/1 | 31095.2213 | 31096.0649 | 0.843604 | 0.00000 | — | — | — | 0/1 | NO | 0.01 |
| M02_plate_sketch | FAIL | —/— | — | — | — | — | — | — | — | —/— | — | 0.01 |
| M03_open_tray | PASS | 1/1 | 13632.0000 | 13632.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M03_open_tray | PASS | 1/1 | 13632.0000 | 13632.0000 | 0.000000 | 0.00000 | — | — | — | 0/1 | NO | 0.00 |
| M04_revolved_washer | PASS | 1/1 | 4046.3713 | 4046.3713 | 0.000000 | 0.00296 | 0 | 0 | 0.00000 | 1/1 | yes | 0.03 |
| M04_revolved_washer | PASS | 1/1 | 4046.3713 | 4042.9564 | 3.414980 | 0.00978 | — | — | — | 0/1 | NO | 0.01 |
| M05_L_bracket | PASS | 1/1 | 22560.0000 | 22560.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M05_L_bracket | PASS | 1/1 | 22560.0000 | 22560.0000 | 0.000000 | 0.00000 | — | — | — | 0/1 | NO | 0.00 |
| M06_boolean_inputs | PASS | 2/2 | 16000.0000 | 16000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 2/2 | yes | 0.01 |
| M06_intersect | PASS | 1/1 | 4000.0000 | 4000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M06_subtract | PASS | 1/1 | 4000.0000 | 4000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M06_union | PASS | 1/1 | 12000.0000 | 12000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M07_single_edge_chamfer | PASS | 1/1 | 980.0000 | 980.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M07_single_edge_fillet | PASS | 1/1 | 991.4159 | 991.4159 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M07_single_edge_fillet | PASS | 1/1 | 991.4159 | 991.3866 | 0.029286 | 0.00000 | — | — | — | 0/1 | NO | 0.00 |
| M08_straight_sweep | PASS | 1/1 | 1413.7167 | 1413.7167 | 0.000000 | 0.00059 | 0 | 0 | 0.00000 | 1/1 | yes | 0.01 |
| M09_conical_loft | PASS | 1/1 | 17132.1519 | 17132.1519 | 0.000000 | 0.00296 | 0 | 0 | 0.00000 | 1/1 | yes | 0.05 |
| M10_split_halves | PASS | 2/2 | 12000.0000 | 12000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 2/2 | yes | 0.01 |
| M11_six_pin_pattern | PASS | 6/6 | 753.9822 | 753.9822 | 0.000000 | 0.00040 | 0 | 0 | 0.00000 | 6/6 | yes | 0.07 |
| M12_replace_face_result | PASS | 1/1 | 8000.0000 | 8000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M12_replace_face_start | PASS | 1/1 | 6000.0000 | 6000.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M13_thin_frame | PASS | 1/1 | 152.0000 | 152.0000 | 0.000000 | 0.00000 | 0 | 0 | 0 | 1/1 | yes | 0.01 |
| M14_asymmetric_tag | PASS | 1/1 | 3149.7345 | 3149.7345 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.02 |
| M14_placed_tag | PASS | 1/1 | 3149.7345 | 3149.7345 | 0.000000 | 0.00000 | 0 | 0 | 0.00000 | 1/1 | yes | 0.02 |
| M15_curve_coupon | FAIL | —/— | — | — | — | — | — | — | — | —/— | — | 0.00 |
| NEGATIVE_not_step | PASS | —/— | — | — | — | — | — | — | — | —/— | — | 0.00 |
| NEGATIVE_open_triangle | FAIL | —/— | — | — | — | — | — | — | — | —/— | — | 0.05 |
| NEGATIVE_truncated | PASS | —/— | — | — | — | — | — | — | — | —/— | — | 0.00 |
| NEGATIVE_truncated_binary | PASS | —/— | — | — | — | — | — | — | — | —/— | — | 0.00 |

## Failures

### M02_plate_sketch — M02_plate_sketch.dxf
- **DXF lines imported**: expected 4
- **DXF circles imported**: expected 4
- **DXF outline_mm imported**: expected [80, 50]
- **DXF circle_radius_mm imported**: expected 3
- **DXF centers_mm imported**: expected [[10, 10], [10, 40], [70, 10], [70, 40]]
- repro: `os3d_exec` {"op": "document.import", "args": {"path": "/Users/jclaan/projects/open-source-projects/openshape3d-project/openshape3d/docs/qa/shapr3d-parity/fixtures/M02_plate_sketch.dxf"}}

### M15_curve_coupon — M15_curve_coupon.dxf
- **DXF ellipse imported**: expected {"center": [0, 0], "semiaxes": [10, 5]}
- repro: `os3d_exec` {"op": "document.import", "args": {"path": "/Users/jclaan/projects/open-source-projects/openshape3d-project/openshape3d/docs/qa/shapr3d-parity/fixtures/M15_curve_coupon.dxf"}}

### NEGATIVE_open_triangle — NEGATIVE_open_triangle.stl
- **refused (no silent success)**: reply: {"analytic": 0, "bodies": [{"bounds": [[0, 0, 0], [10, 10, 0]], "brep": false, "hidden": false, "id": "0D1FD6C5-5028-4BF1-BEC1-E6823F31842C", "name": "NEGATIVE_open_triangle", "volumeMM3": 0}], "bodyIDs": ["0D1FD6C5-5028-4BF1-BEC1-E6823F31842C"], "canRedo": false, "canUndo": true, "commandSearchActi
- **design untouched**: bodies now 1
- repro: `os3d_exec` {"op": "document.import", "args": {"path": "/Users/jclaan/projects/open-source-projects/openshape3d-project/openshape3d/docs/qa/shapr3d-parity/fixtures/NEGATIVE_open_triangle.stl", "units": "mm"}}


## Timing and memory

| Case | Import s | Check s | Export s | Inspect s | RSS before MB | RSS after MB |
|---|---|---|---|---|---|---|
| M01_block | 0.05 | 0.01 | 0.01 | 0.03 | 296.9000 | 309.4000 |
| M01_block | 0.00 | 0.00 | — | — | 309.4000 | 309.7000 |
| M02_four_hole_plate | 0.05 | 0.01 | 0.00 | 0.15 | 309.7000 | 325.5000 |
| M02_four_hole_plate | 0.01 | 0.00 | — | — | 325.5000 | 326.0000 |
| M02_plate_sketch | 0.01 | — | — | — | 326.0000 | 326.4000 |
| M03_open_tray | 0.01 | 0.01 | 0.00 | 0.04 | 326.4000 | 327.5000 |
| M03_open_tray | 0.00 | 0.00 | — | — | 327.5000 | 327.5000 |
| M04_revolved_washer | 0.03 | 0.01 | 0.00 | 0.07 | 327.5000 | 329.7000 |
| M04_revolved_washer | 0.01 | 0.00 | — | — | 329.7000 | 329.7000 |
| M05_L_bracket | 0.01 | 0.01 | 0.00 | 0.04 | 329.6000 | 330.3000 |
| M05_L_bracket | 0.00 | 0.00 | — | — | 330.3000 | 330.3000 |
| M06_boolean_inputs | 0.01 | 0.01 | 0.01 | 0.04 | 330.2000 | 331.0000 |
| M06_intersect | 0.01 | 0.01 | 0.00 | 0.02 | 330.9000 | 331.5000 |
| M06_subtract | 0.01 | 0.01 | 0.00 | 0.03 | 331.4000 | 331.6000 |
| M06_union | 0.01 | 0.01 | 0.00 | 0.04 | 331.6000 | 332.1000 |
| M07_single_edge_chamfer | 0.01 | 0.01 | 0.00 | 0.03 | 332.0000 | 332.4000 |
| M07_single_edge_fillet | 0.01 | 0.01 | 0.01 | 0.04 | 332.3000 | 334.2000 |
| M07_single_edge_fillet | 0.00 | 0.00 | — | — | 334.1000 | 334.6000 |
| M08_straight_sweep | 0.01 | 0.01 | 0.00 | 0.03 | 334.5000 | 336.1000 |
| M09_conical_loft | 0.05 | 0.01 | 0.00 | 0.09 | 336.0000 | 345.7000 |
| M10_split_halves | 0.01 | 0.01 | 0.00 | 0.03 | 345.7000 | 346.4000 |
| M11_six_pin_pattern | 0.07 | 0.01 | 0.00 | 0.12 | 346.4000 | 352.8000 |
| M12_replace_face_result | 0.01 | 0.01 | 0.00 | 0.03 | 352.5000 | 352.9000 |
| M12_replace_face_start | 0.01 | 0.01 | 0.00 | 0.03 | 352.8000 | 353.0000 |
| M13_thin_frame | 0.01 | 0.01 | 0.00 | 0.04 | 353.0000 | 353.2000 |
| M14_asymmetric_tag | 0.02 | 0.01 | 0.00 | 0.04 | 353.2000 | 353.8000 |
| M14_placed_tag | 0.02 | 0.01 | 0.00 | 0.05 | 353.8000 | 354.2000 |
| M15_curve_coupon | 0.00 | — | — | — | 354.1000 | 354.1000 |
| NEGATIVE_not_step | 0.00 | — | — | — | — | 354.2000 |
| NEGATIVE_open_triangle | 0.05 | — | — | — | — | 360.3000 |
| NEGATIVE_truncated | 0.00 | — | — | — | — | 360.3000 |
| NEGATIVE_truncated_binary | 0.00 | — | — | — | — | 360.3000 |
