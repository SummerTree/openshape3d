# Test-pack preparation and validation

Revision 1.0. Repository inspected at commit `23693fd404e8c7714ae8ed783ff29e04bcac0c6b`. This record describes validation of the handoff and its original reference assets. Comparative application results remain **NOT RUN**.

## STEP references: 20 passed

The original generator used the repository's OCCT 7.8.1 public APIs to construct each reference without calling OpenShape3D's UI, commands, or feature graph. It checked shape validity, mathematical aggregate volume, and solid count, wrote AP214 STEP, then read that STEP back and repeated those checks. All 20 files passed. The generation check used volume error at most `max(0.000001 mm³, 0.000000001 × expected volume)`; the broader application acceptance gates are defined separately in the test plan.

`fixtures/occt_validation.csv` records the actual round-trip measurements, bounds, counts, and surface categories. `fixture_manifest.json` records the intended measurements and SHA-256 checksums. All 32 distributed fixture files matched their recorded sizes and checksums in the final packaging check.

Several construction routes differ from the app exercise: cavity subtraction for the Shell tray, concentric cylinders for the revolved washer, a cylinder for the straight Sweep target, and a cone for the Loft target. Their formulas provide independent mathematical checks. The generator and app share the OCCT kernel family, so these results do not establish independent kernel agreement or Shapr3D parity.

The standalone Catalyst command-line generator exits after explicitly closing its outputs to avoid a global library teardown crash in that host. This behavior is documented in `tools/README.md` and the source. All geometry checks and STEP transfers finish before that exit. The application was not modified.

## STL companions: six passed

Checks covered binary record length, nondegenerate triangles, positive signed volume, bounding coordinates, and closed, consistently oriented edge incidence. Shared vertices were matched at five decimal places in the intended millimeter coordinate system. Each welded edge had exactly two incident triangles with opposite directions. This is a mesh integrity check; it does not prove arbitrary meshes are free of self-intersection.

| File | Triangles | Absolute volume error versus analytic target | Maximum bounding-coordinate error |
|---|---:|---:|---:|
| M01_block.stl | 12 | 0% | 0 mm |
| M02_four_hole_plate.stl | 1,372 | 0.002713% | 0 mm |
| M03_open_tray.stl | 28 | 0% | 0 mm |
| M04_revolved_washer.stl | 684 | 0.084396% | 0.009779 mm |
| M05_L_bracket.stl | 24 | 0% | 0 mm |
| M07_single_edge_fillet.stl | 96 | 0.002954% | < 0.000001 mm |

All six meet the plan's proposed mesh gates of 0.1% volume error and 0.05 mm dimensional error for these fixtures. STL stores no intrinsic units; import them as millimeters. A mesh passing these checks is still not an analytic B-rep reference.

## Document and handoff checks

- The final Word document rendered to 44 pages. Every final page was visually reviewed for clipping, overlaps, table layout, model previews, and legibility.
- The rendered document contains all 101 cataloged IDs: 16 original model recipes, three external exercises, and 82 adversarial cases.
- The Word document contains 38 distinct external HTTPS source links. Official source pages were checked during preparation; they remain live documents whose contents may change.
- The results template starts with NOT RUN status and empty actual measurements. It contains no fabricated app results.
- The six model illustrations were rendered from the supplied original mesh geometry. They are not screenshots from either application.

## Work required when executing the plan

OpenShape3D and Shapr3D were not launched to execute these cases during document preparation. No comparative workflow, persistence, device, performance, export, or release pass is claimed. The listed Xcode test commands were not executed.

The two DXF inputs were authored from explicit geometry and insertion units; receiving-application import and entity preservation remain to be tested. The four NEGATIVE files are deliberately malformed or open and must never be treated as valid benchmark output.

No Shapr3D native baseline or external tutorial/NIST binary is bundled. Obtain the selected source assets from the plan's links, record the exact version, filename, and checksum, and review the reference measurements before comparison. M15/M16 final native models, curved/advanced variants, old-schema projects, and large stress files require the construction or capture steps in the plan.

The first developer run should follow the README and sections 1–3 of the test plan, then record actual evidence in a copy of the results template.
