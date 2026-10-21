# OpenShape3D: adversarial CAD test plan

## Developer handoff · revision 1.0 · September 2, 2026

**Purpose:** prove that a user can create, revise, save, exchange, and continue editing useful CAD models through the app's normal interface, with outcomes comparable to Shapr3D. A plausible image is insufficient: the solid, dimensions, history, selection, and exported file must agree.

**Review baseline:** repository commit `23693fd404e8c7714ae8ed783ff29e04bcac0c6b`. This document is a proposed acceptance suite, not a report that OpenShape3D or Shapr3D passed it. Repository observations are source inspection; Shapr3D behavior is documented unless a future run attaches an observation. No comparative app sessions were executed while preparing this plan.

**Deliverables:** this editable plan; 20 analytic STEP fixtures; six STL companions; two sketch DXFs; isolated negative import fixtures; expected geometry and checksums; and an execution log template. Original fixture geometry was checked with OCCT 7.8.1 before and after STEP serialization. These fixtures are mathematical references, not Shapr3D exports. The developer must capture Shapr3D baselines as described below.

**Start here:** run M01, M02, M03, M07, M12, and M14 through the entire lifecycle on iPad; repeat M01/M02/M14 on iPhone and Mac. Then run the history attacks, corrupt-import cases, and official bracket exercise. Do not postpone save/reopen or STEP checks until the end of the project.

### Reading map

1. Scope, platform comparison, and current risks.
2. Repeatable execution pattern and reference-model custody.
3. Numeric, geometric, and behavioral acceptance rules.
4. Original model recipes M01–M16.
5. External reference exercises R01–R03.
6. Adversarial cases across sketching, modeling, history, files, and devices.
7. Performance, automation, defect reporting, and release gates.
8. Sources and fixture inventory.

<!-- PAGEBREAK -->

## 1. Scope and the definition of parity

Shapr3D's official platform list includes iPadOS and macOS, alongside Windows and visionOS; it does not list iPhone/iOS. Use Shapr3D on iPad/Mac to establish the modeling reference. Evaluate OpenShape3D on iPhone against the same mathematical result and equivalent user intent, with its own touch ergonomics criteria. Do not report an iPhone-to-iPhone Shapr3D comparison. [S01]

Parity has four separate scores: **geometry**, **workflow**, **editability**, and **file durability**. A model that imports correctly but cannot be rebuilt from a blank project passes only the applicable import checks. A mesh that looks round but lost its analytic cylindrical surface fails analytic CAD acceptance. A different number of clicks can pass geometry while failing a specific workflow requirement.

### Scope levels

| Level | Required outcomes | Reporting rule |
|---|---|---|
| Core release | Sketch, constraints, exact solids, basic blends, shell, transforms, history, native persistence, STEP, STL, DXF | All designated core tests are release gates |
| Shapr3D workflow parity | Selection-driven tools, automatic booleans, editable operands/options, linked references, tool variants | Missing behavior is a recorded parity gap |
| Extended product parity | G2/chordal blends, guided lofts, advanced construction, drawings, visualization, assemblies, collaboration | Track explicitly; do not imply parity from core results |
| OpenShape3D extension | iPhone modeling, symbols, app-specific archive and automation behavior | Apply the app's stated contract and mathematical checks |

Shapr3D has plan-dependent import/export availability; STEP baseline capture requires an account/plan that permits STEP export. A subscription restriction is an environment blocker, not an OpenShape3D defect. Check the current file-format matrix before a run. Native `.shapr` history and STEP geometry are different artifacts. Do not expect STEP to carry editable sketch constraints or the original feature sequence. [S02, S03]

### Repository risks that should determine test order

The project documents iPhone/iPad and Mac Catalyst support. Source inspection finds an OCCT B-rep path alongside mesh geometry. `STEPKit` skips bodies lacking a B-rep and bakes body transforms into exports. Its skipped-body list must be visible to the user. `ParityWalkthroughUITests` explicitly uses light assertions and screenshots; `GeometryOracleTests` adds analytic volume assertions. Neither alone proves the complete user journey. These are implementation observations at the pinned commit, not newly reproduced bugs.

- **Wrong solid, convincing display:** render mesh, measurement, exported solid, and operation operands disagree.
- **Silent analytic loss:** a successful-looking operation produces a mesh-only body and later STEP export omits it.
- **Wrong face after a change:** a face/edge reference resolves to a nearby or symmetric feature after a cut, transform, reorder, or reopen.
- **Incorrect transaction:** cancel, failed solve, undo, or an asynchronous preview leaves some state mutated.
- **Unusable small-screen flow:** the numeric field, selected face, or confirmation control is hidden behind the keyboard or another panel.

Prioritize these risks over cosmetic differences. Use the existing parity specification as a requirement map, but resolve stale status prose against the build actually under test.

### Required device and input matrix

| Row | OpenShape3D environment | Reference and focus |
|---|---|---|
| D1 | Oldest supported physical iPhone, portrait, finger input | Shapr3D iPad geometry baseline; keyboard, hit targets, memory |
| D2 | Current large iPhone, portrait and landscape | Same baseline; orientation changes during a tool |
| D3 | Oldest supported physical iPad, Pencil + touch | Same-device Shapr3D where compatible; precision and performance |
| D4 | Current iPad, Pencil; then keyboard/trackpad | Direct Shapr3D comparison; multitasking and input switching |
| D5 | Apple Silicon Mac, actual Catalyst build, mouse | Native Shapr3D Mac; exact entry, shortcuts, file dialogs |
| D6 | Mac trackpad; small and large window sizes | Navigation, scrolling, focus, resize during editing |

Record exact hardware, RAM where available, OS build, app build, reference version, input hardware, display scale, locale, and power/thermal state. Test the oldest and newest OS versions the release actually supports. Do not invent minimum OS requirements from this plan. Simulators support regression testing but cannot sign off Pencil behavior, physical-device memory pressure, thermals, or sustained rendering performance. Intel Mac is required only if the shipped binary supports it; otherwise record the platform exclusion.

<!-- PAGEBREAK -->

## 2. One execution pattern for every model

### P: baseline, build, change, recover, exchange

1. **P0 — Prepare.** Create a disposable project with a unique run ID. Use millimeters, degrees, orthographic reference views, and the coordinate convention below. Record snapping, automatic constraints, navigation preset, and export settings. Disable debug seeds and storage resets during genuine workflow and persistence runs.
2. **P1 — Capture the reference.** Build the recipe in Shapr3D on iPad or Mac using the stated dimensions and operation order. Save `.shapr`, export STEP where permitted, and record numeric measurements plus top/front/right/isometric screenshots. For an ambiguous option, record the control label and actual observed result. Have a second reviewer confirm the recipe and measurements before freezing this baseline.
3. **P2 — Rebuild in OpenShape3D.** Start blank and use the visible UI. Do not import the expected final fixture to claim a modeling pass. Type final dimensions; freehand placement is only an initial approximation. Capture a checkpoint after each numbered recipe step.
4. **P3 — Validate the first result.** Check the dimensions, expected body count, analytic feature types, volume, and required topology. Export STEP and inspect it independently as described in section 3. Compare the same world-space placement.
5. **P4 — Revise intent.** Apply the recipe's specified dimension or operand change. Verify the downstream result. Return the parameter to its initial value and check the original result. Run the designated invalid-input variant from a saved checkpoint.
6. **P5 — Recover.** Undo the last operation, redo it, and compare geometry plus feature parameters. Cancel a preview and compare with the pre-preview checkpoint. A continuous drag should create the app's documented single edit transaction; repeated tool commits must remain individually undoable.
7. **P6 — Persist.** Save, close the project, reopen, quit/relaunch, and reopen again. Confirm geometry, visibility, names, materials, constraints, variables, and history references. Make another edit after reopening. Persistent undo history is not assumed unless the product promises it.
8. **P7 — Exchange.** Export STEP and STL with recorded settings; export DXF where the recipe contains sketches. Import into a fresh project and an independent reader. Check units, placement, counts, dimensions, validity, and further editing. Preserve the original native project for history tests.
9. **P8 — Record.** Fill the execution log for each model/device/variant. Attach source and output files, metrics, screenshots, timing, and defect IDs. Rerun the exact failure after a fix, plus the adjacent geometry and lifecycle cases.

**Checkpoint filenames:** `<run>/<app>/<model>/<checkpoint>.<extension>`, for example `20260902-D3-build123/openshape/M02/P6-reopened.step`. A screenshot is supporting evidence; a CAD file and measurable expected result are the primary evidence for geometry.

### Coordinate convention

All original recipes use a right-handed frame: X is width, Y is depth, Z is height; XY is the base sketch plane. Units are mm, mm², mm³, and degrees. Boxes use lower-corner coordinates, not centered primitive coordinates. The app's internal primitive axes may differ: explicitly map the displayed world axes before testing. Never reinterpret a supplied fixture's axes to make an incorrect transform pass.

For external samples preserve source units and placement, recording any explicit conversion. Compare in a fixed world frame first. A separate rigidly aligned comparison can diagnose shape equivalence, but it cannot excuse an export that moved, rotated, mirrored, or scaled a part.

### Baseline custody

Keep separate `reference-original`, `reference-shapr`, and `actual-openshape` directories. Record the source URL, retrieval date, filename, format/schema, byte size, SHA-256, units, license/usage notice, tool/version used to open it, expected metrics, and reviewer's name. Freeze a baseline only after it is independently reviewed. Replacing a failing reference with the latest app output is prohibited.

The bundled fixtures are original synthetic geometry generated directly through OCCT public APIs. They bypass OpenShape3D's UI and feature graph but share its kernel family. Analytic formulas provide an independent check for these simple shapes; Shapr3D's separately captured results provide a different-kernel comparison. FreeCAD is useful for external inspection, but because it also uses OCCT it is not a fully independent kernel oracle.

<!-- PAGEBREAK -->

## 3. Pass/fail rules that detect a convincing wrong model

### Numeric gates

These are proposed QA acceptance thresholds, not Shapr3D specifications or manufacturing tolerances. Freeze them before testing. For the 2–100 mm reference parts, apply all relevant gates; one matching number cannot compensate for a failed geometry check.

| Quantity | Core gate | How to measure |
|---|---|---|
| Typed lengths, radii, hole locations | Error ≤ 0.01 mm | Exact B-rep interrogation or independent CAD measurement |
| Angle | Error ≤ 0.01° | Face normals, axes, or constrained sketch geometry |
| B-rep volume | Error ≤ max(0.001 mm³, 0.00001 × reference volume) | Exact mass properties; no tessellated volume shortcut |
| Body/solid count | Exact expected count | Enumerate solids, including hidden and disconnected pieces |
| Bounding box/centroid | Each coordinate error ≤ 0.01 mm | Geometry bounds without display-mesh inflation |
| Analytic feature | Correct surface/curve class and dimensions | Cylinder/cone/plane and circular edge interrogation |
| STEP round trip | Same gates as above | Reopened STEP, not the in-memory pre-export body |
| STL/mesh round trip | Dimensions ≤ 0.05 mm; volume error ≤ 0.1% | Watertight, consistently oriented mesh at sufficient resolution |

For stress scales below 1 mm or above 1 m, define the supported envelope and scale-appropriate tolerances in the run record before executing. Do not use a 0.01 mm tolerance to certify a 0.001 mm feature. Out-of-envelope inputs still require bounded execution and a recoverable, truthful result.

Analytic topology can be split differently by different kernels. Require a cylindrical bore to remain analytically cylindrical, but do not fail equivalent solids solely for different face counts, seam positions, face IDs, triangle counts, or STEP byte ordering. For a simple untouched primitive, exact face counts are useful diagnostics. The `occt_validation.csv` counts describe the supplied files, not a universal Shapr3D topology contract.

### Independent comparison procedure

1. Open the exported STEP in Shapr3D and a separate inspection process such as FreeCAD or a standalone OCCT reader. Record import warnings and the imported solid count. STEP syntax analysis with NIST's analyzer is an additional file check; it does not prove geometric validity. [S03, S20]
2. Run B-rep validity checks, including closed shells, face/wire validity, and no unintended disconnected material. Inspect mass properties, precise bounds, centroid, and analytic feature dimensions. OCCT supplies `BRepCheck_Analyzer` and `BRepGProp` for these checks. Use the API for the kernel version actually linked by the build. [S21, S22]
3. Compare solid occupancy in both directions: reference minus actual, and actual minus reference. Evaluate the volumes of both differences; proposed normalized symmetric-difference gate is `(V(ref−actual)+V(actual−ref))/max(Vref,Vactual) ≤ 0.00001`, with absolute residual volume ≤ the volume gate for tiny references. Boolean failure means comparison is inconclusive; it is never a zero-error result.
4. Check local shape as well as volume: bidirectional surface distance ≤ 0.01 mm on these references. Prefer a geometric distance evaluator with a documented error bound. If only tessellated sampling is available, refine until results converge, report its deflection, and label the metric an estimate. Sparse vertex sampling is not a certified maximum distance.
5. Inspect sections through holes and pockets. Check wall thickness, bore center/axis, fillet/chamfer size, and feature identity. Compare controlled orthographic silhouettes for gross missing/inverted material. Screen pixels alone cannot pass or fail exact B-rep accuracy.

The supplied fixture log proves only generator validity, expected volume, and STEP round-trip checks; it does not claim the full difference/distance procedure above has run against either app. Surface area is an optional corroborating measure: use a reviewed baseline and the same integration method, rather than a guessed universal threshold.

### Transaction and failure gates

Every operation must either commit a valid result with the intended parameters and complete metadata, or report failure and preserve the last committed document. Compare a semantic snapshot of geometry, body identities, feature operands, constraints, and variables. Raw file hashes are unsuitable for semantic equality when timestamps or serialization order change.

No crash, uncancellable hang, silent wrong-body edit, silent unit conversion, missing committed work, or unannounced partial export is acceptable. On an invalid operation the app may reject, preview an error, or require a correction; it must not substitute a different operation and label it success. A Shapr3D failure is evidence about that reference build, not permission to corrupt a model.

Use statuses **PASS**, **FAIL**, **BLOCKED**, **NOT RUN**, **GAP**, and **N/A**. A missing core feature is **FAIL** for the core release gate and also a parity gap. A declared extended feature is **GAP** until delivered. N/A requires a specific reason, owner, and scope decision. Track coverage with missing/gap cases in the denominator; do not inflate parity by excluding them.

<!-- PAGEBREAK -->

## 4. Original model recipes

All M-series recipes are original tests. Their dimensions and expected values are defined here; linked Shapr3D pages explain the relevant tools. Follow P0–P8 for every core model. **Normal UI construction and import/edit are separate runs.** The supplied final STEP files are for comparison and import testing, not shortcuts in the construction run.

### M01 — Dimensioned block and symmetric extrusion

**Priority:** core, P0. **Time budget:** 15 minutes plus lifecycle. **Reference:** `M01_block.step`. **Tools:** rectangle, dimensions, extrusion, direct face movement. [S04, S05]

1. On XY, draw a rectangle with corners (0,0), (40,0), (40,30), (0,30). Anchor the origin; set width 40 and depth 30. Confirm the rectangle retains orthogonality when resized.
2. Extrude toward +Z by 10 as a new body. Rename it `M01 Block`. Check the first solid before any other operation.
3. Edit extrusion height to 15. Check the new dimensions. Restore 10, then push/pull the top planar face by +5 and compare the resulting geometry with the history-edited version.
4. In a fresh branch, use the original rectangle and a symmetric extrusion with **total thickness 10**, spanning Z = −5 to +5. Record whether the UI asks for half-length or total length. Enter the value that gives these bounds; compare the labels and semantics separately.

**Expected:** initial volume 12,000; bounds (0,0,0) to (40,30,10); centroid (20,15,5); one solid and six plane faces before direct editing. Height 15 gives volume 18,000 and centroid Z = 7.5. The symmetric variant has volume 12,000 and centroid Z = 0. Changing displayed units to inches gives 1.57480315 × 1.18110236 × 0.39370079 in without resizing geometry.

**Attack:** type 0 and then a negative distance; cancel a drag; rotate while entering a value. Zero must not create a zero-thickness solid. Negative distances must follow explicit direction semantics. An accepted signed −10 new-body extrusion from XY should occupy Z = −10 to 0.

**Inspect after reopen/export:** face direction, height, body count, and actual placement. A “10” symmetric label is not sufficient evidence of the intended total thickness.

### M02 — Four-hole mounting plate

**Priority:** core, P0. **Time budget:** 25 minutes plus lifecycle. **Reference:** `M02_four_hole_plate.step`. **Tools:** constrained circles, nested profiles, through cuts. [S04, S05]

1. Sketch an 80 × 50 rectangle at XY origin. Add circles of diameter 6 centered at (10,10), (70,10), (10,40), and (70,40). Dimension their locations. Use equal-radius constraints where available.
2. Select only the plate material region and extrude +8. Check all four circles become through holes, with no plug bodies. Save checkpoint A.
3. In a second project, extrude the plain plate first, sketch the four circles on Z = 8, and subtract through all. Compare with A.
4. Edit the shared hole diameter from 6 to 8. All four holes must change; restore 6. Increase plate thickness to 12: a genuine Through All feature must still cut through; a fixed-distance feature is judged by its explicitly fixed extent.

**Expected:** one solid; outer bounds (0,0,0) to (80,50,8); volume `32000 − 288π` = 31,095.221316; centroid (40,25,4). Four analytically cylindrical bores of radius 3. With diameter 8, volume `32000 − 512π` = 30,391.504561. At thickness 12 and original holes, volume `48000 − 432π` = 46,642.831974.

**Attack:** reverse circle creation order; add an overlapping duplicate circle; drag one hole almost onto the outer edge; select all five regions accidentally. Require truthful profile selection and explicit body/boolean results. Save a narrow-ligament variant as a separate stress case; do not silently repair it into the original geometry.

**Inspect:** section through both hole rows, residual end caps, bore analytic types, persistent equal constraints, and all four hole centers after STEP import.

### M03 — Open-top enclosure and shell

**Priority:** core, P0. **Time budget:** 20 minutes plus lifecycle. **Reference:** `M03_open_tray.step`. **Tools:** shell, section, measurement. [S06]

1. Create a box from (0,0,0) with size 60 × 40 × 25. Select only its top face Z = 25.
2. Shell inward with thickness 2, removing the top. Keep the original exterior dimensions. Check an open cavity before editing anything else.
3. Change thickness to 3 in history; restore 2. On a separate duplicate, construct the same cavity by subtracting a 56 × 36 rectangular prism beginning at (2,2,2) and extending above the top. Compare the solids.
4. Section at X = 30 and Y = 20. Measure the base and every side wall. Exit Section and verify the model itself was not cut.

**Expected:** one connected, valid solid; open top; exterior bounds unchanged; inner cavity X = 2..58, Y = 2..38, Z = 2..25. Volume `60×40×25 − 56×36×23` = 13,632. Thickness 3 gives `60000 − 54×34×22` = 19,608. Do not apply the formula for a fully closed six-wall shell.

**Attack:** request thickness 0, −2, 19.9, 20, and 21 using an explicitly inward operation; also try removing the bottom face in a duplicate. Negative semantics must be explicit. A collapsed cavity or impossible result must not be accepted as the original open tray. For near-limit valid variants compare geometry with the actual Shapr3D result.

**Inspect:** base present, top absent, no interior floating faces, no reversed wall normals, same shell face after reopen. The fixture was built with a cavity subtraction to provide a second construction route; the UI test must exercise Shell.

### M04 — Revolved washer

**Priority:** core, P0. **Time budget:** 20 minutes plus lifecycle. **Reference:** `M04_revolved_washer.step`. **Tools:** construction axis, revolve. [S07]

1. On the XZ plane, sketch a rectangle spanning radial X = 8..15 and Z = 0..8; Y = 0. Use the Z axis as the revolve axis.
2. Revolve 360° as a new body. Confirm the center is an open bore, not a capped cylinder.
3. Change angle to 180°. Confirm a half washer with two radial end faces. Restore 360°. Separately create an annular XY profile of outer radius 15 and inner radius 8 and extrude 8; compare the full solids.
4. Change inner radius from 8 to 10; restore it. Repeat axis selection using an explicitly constructed line coincident with world Z.

**Expected:** full volume `π(15²−8²)×8` = `1288π` = 4,046.371338; bounds (−15,−15,0) to (15,15,8); centroid (0,0,4). Outer and inner walls remain cylindrical. The 180° volume is `644π` = 2,023.185669. Inner radius 10 gives `1000π` = 3,141.592654.

**Attack:** move the sketch until it crosses the axis, select a zero-length/invalid axis, enter 0°, and reverse rotation direction. Record valid signed-angle behavior. Invalid self-overlap must yield a recoverable error with the previous solid intact.

**Inspect:** 360° seam is not an artificial gap; bore remains editable after STEP import; axis and inner-radius changes update the intended feature.

### M05 — L bracket built in two ways

**Priority:** core, P0. **Time budget:** 25 minutes plus lifecycle. **Reference:** `M05_L_bracket.step`. **Tools:** face sketch, union, profile editing. [S05, S08]

1. Make a base from (0,0,0), size 60 × 40 × 6.
2. On its top face, create a rectangle X = 0..6, Y = 0..40. Extrude +34 with Union selected. The final upright reaches Z = 40. Confirm one solid.
3. In a fresh project, sketch the L outline on XZ: (0,0), (60,0), (60,6), (6,6), (6,40), (0,40). Extrude 40 in +Y. Compare with the first model.
4. Increase upright total height from 40 to 50 by editing the +34 extrusion to +44. Restore. On another duplicate, make the upright as New Body and then explicitly Union it with the base.

**Expected:** volume `60×40×6 + 6×40×34` = 22,560; bounds (0,0,0) to (60,40,40); one connected solid. At total height 50, volume 24,960. The coincident joint must not leave duplicate internal material or a second body after union.

**Attack:** hide the base before selecting the upright; add an unrelated nearby body; reverse target/tool selection; attempt union when the upright is raised to leave a 0.01 mm gap. A disconnected result must not be mislabeled as one connected solid.

**Inspect:** the concave inside corner and joint are continuous; keep-originals behavior matches the selected option; STEP preserves the exact L profile. Blends belong in a separate branch so the analytic volume remains a usable gate.

### M06 — Boolean truth table

**Priority:** core, P0. **Time budget:** 20 minutes plus lifecycle. **References:** `M06_boolean_inputs.step`, `M06_union.step`, `M06_subtract.step`, `M06_intersect.step`. [S08]

1. Create A with bounds (0,0,0)..(20,20,20). Create B with bounds (10,0,0)..(30,20,20). Name them before selecting operands. Save the input project.
2. In three independent branches, run Union, A minus B, and Intersect. Turn keep-originals off for the result-only checks.
3. Reload the input project and run B minus A. Then repeat each operation with the relevant keep-originals option enabled, recording all retained operands and result bodies.
4. Move B to X = 20 (face contact), 20.01 (gap), and 19.99 (thin overlap) in separate branches. Capture Shapr3D behavior for each boundary condition.

**Expected:** each input volume 8,000. Their sum is 16,000 although occupied union volume is 12,000. Union bounds X = 0..30, volume 12,000. A minus B bounds X = 0..10, volume 4,000. Intersection bounds X = 10..20, volume 4,000. B minus A bounds X = 20..30, volume 4,000. All have Y/Z = 0..20.

**Attack:** select A twice; attempt A minus A; select hidden B; cancel during computation; immediately launch a second operation. Identical subtraction may legitimately produce empty material or a rejected result, but must not masquerade as an unchanged successful subtraction. Keep-originals settings must not create unexplained duplicates.

**Inspect:** no sliver solids, no stale operand, correct target after selection order changes, and no incomplete commit after cancellation. Equal volumes for subtraction and intersection make position checks essential.

### M07 — Single-edge fillet and chamfer calibration

**Priority:** core, P0. **Time budget:** 25 minutes plus lifecycle. **References:** `M07_single_edge_fillet.step`, `M07_single_edge_chamfer.step`. [S09]

1. Create a 10 × 10 × 10 cube with minimum corner at the origin. Select the vertical edge at X = 0, Y = 0, Z = 0..10. Record a close-up of the selected edge.
2. Apply a circular radius-2 fillet to that edge only, with no extra edge-chain selection. Save and measure it.
3. Reload the unmodified cube. Apply an equal-distance chamfer of 2 to the same edge. Check that 2 means face setback, not diagonal bevel width.
4. Edit fillet radius to 1, then 3, then back to 2. Undo/redo the edit. Repeat edge selection after rotating the cube and after STEP import.

**Expected:** fillet volume `1000 − 10×(4−π)` = `960+10π` = 991.415927. Radius 1 gives `990+2.5π` = 997.853982; radius 3 gives `910+22.5π` = 980.685835. Chamfer volume `1000−(2×2/2)×10` = 980. Outer bounds remain (0,0,0)..(10,10,10). The fillet is circular and tangent to the adjoining planar walls; its geometry must not merely resemble a bevel.

**Attack:** select a cylindrical seam, a tangent-only edge, multiple meeting edges, and a radius larger than the cube. Each supported case needs valid output; unsupported/invalid edges need clear feedback and unchanged committed geometry. Do not require identical maximum radii across kernels for complex blends.

**Inspect:** only the intended corner changes; no leak, triangular missing face, hidden duplicate solid, or mesh fallback after the blend. G2/chordal/setback variants are separate parity tests, not substitutes for this circular calibration.

### M08 — Sweep with exact straight-path baseline

**Priority:** core, P1. **Time budget:** 25 minutes plus lifecycle. **Reference:** `M08_straight_sweep.step`. [S10]

1. Draw a radius-3 circle on XY centered at (0,0,0). Draw a separate path along world Z from (0,0,0) to (0,0,50), using a vertical sketch plane.
2. Sweep the circular region along the path as a new body. Compare against the supplied straight cylinder. The construction run must use Sweep.
3. Edit path length to 70, then restore 50. Reverse path selection order and verify the same occupied volume.
4. In an extended branch, replace the line with a tangent quarter-circle path of centerline radius 20 in XZ. Begin at the origin with tangent +Z and end at (20,0,20); its center is (20,0,0). Keep the radius-3 profile normal to the path at the start.

**Expected:** straight volume `9π×50` = `450π` = 1,413.716694; bounds (−3,−3,0)..(3,3,50); one solid. At length 70, volume `630π` = 1,979.203372. For a constant circular section carried normally along the non-self-intersecting quarter circle, volume = section area × path length = `90π²` = 888.264396. The curved branch is recipe-only; no curved fixture is bundled.

**Attack:** disconnected path segments, a sharp corner, a path missing the profile, reverse direction, and bend radius less than profile radius. Establish the valid reference behavior separately; an invalid sweep must not leave a partial tube or claim an analytic cylinder for a faceted approximation.

**Inspect:** both ends capped, no section twist affecting geometry, path edits persist, and the imported body accepts a small circular rim fillet.

### M09 — Two-section loft and tapered solid

**Priority:** core, P1. **Time budget:** 25 minutes plus lifecycle. **Reference:** `M09_conical_loft.step`. [S11]

1. Create parallel XY sketch planes at Z = 0 and Z = 40. Draw centered circles of radius 15 on the first and radius 8 on the second.
2. Loft in that order with default straight two-section interpolation and no guide curves or end-tangency overrides. Verify the radius at the midpoint by a section.
3. Move the second plane to Z = 60 through its parameter; restore 40. Change the second radius to 10; restore 8.
4. In a separate branch, add a centered intermediate circular profile at Z = 20, radius 11.5. Compare geometry to the straight taper, then deliberately use radius 18 to create a different bulged loft and capture its Shapr3D baseline.

**Expected:** the straight taper has volume `(40π/3)×(15²+15×8+8²)` = 17,132.151938; bounds (−15,−15,0)..(15,15,40); midpoint radius 11.5. One solid, no twist or open caps. At height 60, volume 25,698.227906. The fixture uses an exact conical primitive as the mathematical target; accept an equivalent spline representation only if the geometric accuracy gate passes and the required downstream operations remain available. Record analytic conical preservation separately.

**Attack:** select sections out of order, two coplanar sections, open profiles, and a guide that misses one section. For the optional guided variant, make a guide intersect every section, then break one intersection by 0.1 mm. Require coherent diagnostics and unchanged prior geometry on failure.

**Inspect:** section radii, end locations, no loft fold-over, saved profile ordering, and no mistaken substitution of a straight extrusion.

### M10 — Split, keep originals, and recombine

**Priority:** core, P1. **Time budget:** 20 minutes plus lifecycle. **Reference:** `M10_split_halves.step`. [S12]

1. Rebuild M01. Create a YZ construction plane at X = 20.
2. Split the body with that plane, without retaining an additional original. Rename the left and right results. Hide each in turn to verify two real solids.
3. Move the split plane to X = 15 through the feature's parameter, if supported; check both new volumes. Restore 20. Repeat with Keep Originals enabled in a fresh branch.
4. Union the two result halves and compare to M01. Undo the union, then undo and redo the split.

**Expected:** at X = 20, two solids of volume 6,000 each, total 12,000. Bounds are X = 0..20 and 20..40, with Y = 0..30, Z = 0..10. At X = 15, volumes are 4,500 and 7,500. No gap or overlap is introduced. Recombined geometry equals the initial block; face partitioning may differ.

**Attack:** split with a plane outside the body, exactly coincident with a boundary face, or through a hole in M02. Do not create empty named bodies. Changing or deleting the construction plane must update or visibly invalidate dependencies, never silently use the wrong plane.

**Inspect:** exact result count including hidden bodies; stable result identity on reopen; no double counting of a retained original in the result-only volume check.

### M11 — Patterned pins and asymmetric orientation

**Priority:** core, P1. **Time budget:** 25 minutes plus lifecycle. **Reference:** `M11_six_pin_pattern.step`. [S13]

1. Create a radius-2, height-10 pin centered at (20,0) on XY. Circular-pattern the body around world Z with six total instances evenly spaced over 360°, including the seed.
2. Count bodies and measure their centers. Edit the count to eight with the same full-circle extent; restore six.
3. In a new project, make four total pins in a linear pattern along X with center-to-center spacing 10, beginning at (0,0). Compare total-extent and spacing modes if both are offered.
4. Repeat the circular operation with the asymmetric tag from M14 positioned off-axis. Compare rotated-instance and uniform-orientation options against their explicit settings. Cylinders cannot reveal an orientation bug.

**Expected:** six separate pin solids; each volume `40π`, total `240π` = 753.982237. Centers `(20cos(k×60°),20sin(k×60°),5)` for k = 0..5. There is no extra coincident seventh pin at 360°. Eight pins total `320π` = 1,005.309649. Linear centers at X = 0,10,20,30; first-to-last span 30; four bodies total `160π`.

**Attack:** counts 0, 1, 2, 1.5, and 1,000; zero or negative spacing; partial angle 180°. Record count conventions before comparing. Body instances must not unexpectedly move when the seed is edited unless the product explicitly creates a linked pattern/history dependency.

**Inspect:** count, coordinates, orientation, copy names, undo as a complete operation, and selected-instance identity after reopening.

### M12 — Replace face and remove a hole

**Priority:** core, P0. **Time budget:** 25 minutes plus lifecycle. **References:** `M12_replace_face_start.step`, `M12_replace_face_result.step`. [S14]

1. Create a low block X = 0..20, Y = 0..20, Z = 0..5, and a high block X = 20..40, Y = 0..20, Z = 0..10. Union them. Save the stepped solid.
2. Select only the low top face at Z = 5 as the replacement target; select the high top plane Z = 10 as the destination surface. Apply Replace Face.
3. Undo and redo. Reload the stepped checkpoint, rotate the view to the opposite side, and repeat selection. Inspect that the selected faces, rather than their neighbors, are highlighted.
4. For a separate Delete Face/defeature case, start with M14's unplaced tag. Remove/heal its cylindrical hole face using the supported delete-face operation. Confirm a solid rectangular tag remains.

**Expected:** stepped volume 6,000; replaced result 8,000 and bounds (0,0,0)..(40,20,10). The low area fills upward; the high side must not shrink. Removing the M14 through hole restores volume from `3200−16π` to 3,200 without deleting the whole tag. A supported heal operation must close the material correctly.

**Attack:** reverse target/destination, choose an orthogonal face, hide the destination body, and delete an exterior face that cannot be healed into a valid solid. Compare supported direction options to Shapr3D. Invalid targets require feedback and rollback, not an arbitrary nearest-face match.

**Inspect:** source and destination references after history recomputation, no mesh-only fallback, and no stale highlight used as a different operation's operand.

### M13 — Thin frame, offsets, and precision

**Priority:** core, P1. **Time budget:** 20 minutes plus lifecycle. **Reference:** `M13_thin_frame.step`. [S15]

1. Draw an outer 20 × 20 rectangle from (0,0) on XY. Offset the closed loop inward by 1, producing an inner rectangle X/Y = 1..19. Select the frame region and extrude +2.
2. Check each wall is 1 thick. In a second project, create a 20 × 20 × 2 plate and cut an 18 × 18 through opening at (1,1); compare the results.
3. Change offset to 0.5, then 0.1, then restore 1. Type each value, rather than relying on drag resolution.
4. In a stress branch, translate the frame by 100,000 mm in X and repeat picking/measurement/export. Keep a local-origin control. This is a coordinate-precision test, not a declaration of supported design-space limits.

**Expected:** base volume `(400−324)×2` = 152; bounds (0,0,0)..(20,20,2); one solid and one through opening. At wall 0.5: volume 78. At wall 0.1: volume 15.92. Translation preserves volume and wall thickness, moving the bounds exactly.

**Attack:** inward offsets 9.9, 10, and 10.1; disconnected chain selection; a very short extra edge; an offset near another loop. Do not accept inverted or duplicate loops as the same frame. At a collapsed opening, require explicit topology/result handling.

**Inspect:** tiny walls survive selection, history updates, and STEP; screen tessellation must not change the exact thickness.

### M14 — Asymmetric part, transforms, and export placement

**Priority:** core, P0. **Time budget:** 20 minutes plus lifecycle. **References:** `M14_asymmetric_tag.step`, `M14_placed_tag.step`. [S16]

1. Create a 40 × 20 × 4 tag at the origin. Cut a diameter-4 through hole at (7,6). The asymmetric hole makes orientation observable.
2. Rotate the whole body +90° around world Z at the origin. Then translate by (100,−50,25). Record operation order and pivot.
3. Export STEP, reopen in a new project, and inspect its world coordinates. In a separate branch, mirror the original through the YZ plane and check the hole moves to X = −7.
4. Uniform-scale a duplicate of the original by 2 about the origin. Restore the initial unscaled body for the main lifecycle.

**Expected:** original volume `3200−16π` = 3,149.734518. Placed bounds (80,−50,25)..(100,−10,29); hole axis passes through X = 94, Y = −43, Z = 25..29. Rotation and translation preserve volume. A 2× uniform scale produces 8× volume, dimensions 80 × 40 × 8, hole diameter 8, center (14,12). Reflection preserves occupied volume magnitude and valid orientation.

**Attack:** move only a face while intending a whole-body transform; move the pivot; toggle Copy repeatedly; export hidden and selected-only subsets; use Undo while a preview is pending. Detect the exported body returning to its local origin or being transformed twice.

**Inspect:** off-center hole position, world bounds, mirror handedness, normals, body count, and every exported instance. A symmetric cube would miss several of these errors.

### M15 — Text, curves, projection, and 2D interchange

**Priority:** core for supported tools, P1; linked/advanced variants are parity cases. **Time budget:** 35 minutes. **References:** `M02_plate_sketch.dxf` and `M15_curve_coupon.dxf` are import inputs; no final solid fixture. [S17, S18]

1. Create a 60 × 30 × 3 plaque at the origin. Place text `B8O` at height 10 on the top face, with a recorded font/version, and extrude +1 with Union. Position the text completely inside the plaque. Inspect every character counter, especially B and 8.
2. Rebuild a separate curve coupon: an ellipse centered at (0,0), semiaxes 10 and 5, extruded 3. Its exact volume is `150π` = 471.238898. Add an independently saved circle/arc/line sketch from the supplied DXF.
3. Project the circular edges of M02 onto a parallel plane. For an explicitly linked projection, change a source-hole diameter and confirm its projection updates; for explicitly unlinked geometry, confirm it remains independent. Record whether the app offers both modes.
4. Export the dimensioned M02 sketch as DXF; import into fresh OpenShape3D and Shapr3D projects. Verify the 80 × 50 outline, four diameter-6 circles, closed loops, and units. Do not expect sketch constraints or text annotations to round-trip through plain geometry DXF. [S02]

**Expected:** text counters remain open and stroke regions become valid material; no accidental filled B/8/O holes. Exact text volume is font-dependent: capture a reviewed Shapr3D baseline using the same font and placement rather than inventing a value. The ellipse keeps its dimensions and smooth geometry. The DXF import test is separate from native sketch creation.

**Attack:** missing font, empty string, multiline/Unicode text, self-intersecting spline, open arc, nearly closed endpoints, image opacity zero, missing image source after reopen. Unsupported content must produce a specific recoverable result, not silently drop geometry.

### M16 — Parametric enclosure change campaign

**Priority:** core, P0 for supported history; missing required links are explicit gaps. **Time budget:** 45–60 minutes. **Reference:** recipe plus reviewed Shapr3D native/STEP checkpoints; no bundled final fixture. [S19, S23]

1. Build M03 using variables `W=60`, `D=40`, `H=25`, `T=2` where supported. Use a centered base rectangle so left/right walls move symmetrically when W changes; record the coordinate shift relative to M03's lower-corner convention.
2. Add four through holes of diameter 3 in the bottom, centered 8 from adjacent outside edges. At W=60 and D=40 their XY coordinates in a centered frame are (−22,−12), (22,−12), (−22,12), (22,12). They cut through the 2 mm base, not the side walls.
3. Anchor the hole locations with dimensions/expressions from the intended outer edges. Rename features clearly: Base, Shell, HoleSketch, BottomHoles. Save after each. Keep decorative blends out of the numeric branch.
4. Run the sequence W: 60→80→60; H: 25→35→25; T: 2→3→2; hole diameter: 3→4→3. Perform each change from the original saved checkpoint first, then run the entire sequence cumulatively. Compare every checkpoint with Shapr3D and its formula.

**Expected:** `V = W×D×H − (W−2T)(D−2T)(H−T) − 4π(d/2)²T`. Initial V = `13632−18π` = 13,575.451332. Hole centers remain 8 from the intended exterior edges after resizing; shell thickness and opening remain correct. Returning all parameters restores original geometry and references. Formula use assumes holes lie completely in the cavity floor and do not intersect walls.

**Attack:** suppress Shell, restore it, insert a feature before BottomHoles, delete one referenced face, reorder a dependent step before its parent, and remove a variable. A missing reference must identify the failing feature and preserve recoverable history. It must never cut an unrelated wall because that wall has a similar index or position.

**Inspect:** semantic feature references, persistent expressions, failed-feature indicators after reopen, undo/redo of parameter edits, and the final exported holes. This is the main campaign for failures that primitive tests miss.

<!-- PAGEBREAK -->

## 5. External models and Shapr3D workflow exercises

The external samples below add real modeling complexity and independent provenance. The official tutorial pages visibly offer a “Try it yourself” download area; the downloadable payloads were not retrieved or validated for this handoff. Record the actual filename, access requirements, and checksum when obtaining them. If the asset is `.shapr`, open it in Shapr3D and export STEP for geometry inspection; do not assume OpenShape3D can import native Shapr3D history. Keep vendor files separate from the bundled original fixtures.

### R01 — Official Shapr3D bracket mount

**Source and download landing page:** [Bracket Mount: Modeling Basics in Shapr3D](https://support.shapr3d.com/hc/en-us/articles/12470669638300-Bracket-Mount-Modeling-Basics-in-Shapr3D). **Priority:** core workflow acceptance, P0. Allow 60–90 minutes for a documented first run.

Follow the official exercise and capture these checkpoints: base with holes; rounded base and column; opening in the column; bracket arm and union; final detail cuts and blends; history-driven revision. The tutorial includes a 30 × 40 construction rectangle, diameter-6 base holes, a 5-thick base, and a 50-high column extrusion. Its final history exercise changes the construction width to 40 and column extrusion to 60. Verify all other values in the current video rather than inferring them from a screenshot. [S24]

For the test, first capture native and STEP checkpoints in Shapr3D, then rebuild through OpenShape3D's UI. Log the first unavailable or incorrect action, tool state, selected geometry, and exact parameter. Resume from a duplicate only to investigate later features; the original end-to-end run remains failed/blocked. Compare final solid count, holes, wall dimensions, placement, and geometric difference against the reviewed reference. This exercise is distinct from original model M05.

### R02 — Official pan handle, guided by section geometry

**Source and download landing page:** [Pan Handle Design with Loft, Sweep, and Subtract](https://support.shapr3d.com/hc/en-us/articles/12470725468444-Pan-Handle-Design-with-Loft-Sweep-and-Subtract). **Priority:** extended workflow parity, P1. Allow 90–120 minutes.

This exercise combines construction geometry, multiple handle cross-sections, a lofted transition, a subtractive opening, later shape edits, blends, and material studies. Capture geometry before styling, after the main loft, after the opening, and after history changes. The tutorial demonstrates G1/G2 transition control; record an explicit gap if the app lacks the corresponding option. [S25]

Freeze the source file and current tutorial version, then build the same profiles and settings in each app. Compare section contours at several recorded stations as well as total volume and end locations. Run one history edit that changes a profile dimension and another that moves the opening. Do not impose an invented analytic volume on the organic shape. A coarse visual match or a substituted simple loft does not pass the unavailable continuity feature. Material appearance is a separate visual score and does not affect geometric acceptance.

### R03 — NIST STEP interoperability corpus

**Source and download landing page:** [NIST CAD models and STEP test files](https://www.nist.gov/ctl/smart-connected-systems-division/smart-connected-manufacturing-systems-group/mbe-pmi-0). **Priority:** core STEP robustness, P1; unsupported metadata remains an explicit scope item.

Select geometry-only AP203 examples from FTC-06 and FTC-07, then one CTC-01 file and matching AP242 variants available in the linked archive. Record the exact selected file and producing CAD system; a case name alone does not identify a unique payload. The NIST catalog includes geometry-only definitions and PMI-rich STEP variants. STC/FTC/CTC are interoperability test artifacts, not instructions for manufacturing these parts. [S26]

Open each selected file in Shapr3D and the independent inspection tool; freeze observed body count, units, bounds, volume, and named feature dimensions. Import into OpenShape3D, isolate each body, perform a supported direct edit on a duplicate, export, and compare. Use a small/simple sample before the more complex one. Do not invent reference measurements from catalog thumbnails. Evaluate geometry independently of PMI/assembly hierarchy; unsupported metadata must not cause missing solids or a crash. NIST's analyzer adds syntax and entity diagnostics; its documented Windows/Excel requirements should be considered when assigning the tooling task. [S20]

<!-- PAGEBREAK -->

## 6. Adversarial case library

Each ID below is a separate executable case. Unless labeled otherwise, cases are **P1**, apply to advertised/core functionality, use the named M-series checkpoint as their setup, and require the section 3 rollback/geometry gates. Capture the exact action sequence and repeat a failed case twice from a clean checkpoint. Do not reuse a damaged test document for unrelated cases.

Run invalid files and resource-pressure experiments only in disposable test projects. Stop generated-size escalation at the team's declared resource cap. These are deliberate failure inputs; their filenames include `NEGATIVE` so they cannot be mistaken for valid reference models.

### Sketches, constraints, and numeric entry

- **SK-01 · P0 · Closure:** Draw M01's rectangle as four lines, leaving a 0.01 mm final gap with snapping off. Attempt extrusion, then explicitly constrain the endpoints coincident and retry. The open wire must not become an unexplained solid; the closed version must match M01.
- **SK-02 · P0 · Nested regions:** Add concentric circles of radius 3 and 6 inside a 20 × 20 rectangle. Test the frame, annulus, and center as separately selected regions. Record body count and holes for each selection; unselected regions must not become material.
- **SK-03 · Duplicate/self-crossing input:** Duplicate one rectangle edge exactly; in another branch draw a bow-tie polygon. Attempt profile creation. Require deterministic region handling or clear rejection, with no crash, unbounded solver loop, or misleading filled region that extrudes a different shape.
- **SK-04 · P0 · Conflicting dimensions:** Fully constrain M01, then add a second incompatible width of 41 without removing width 40. Require conflict feedback or an explicit replacement action. Geometry must not settle at an unexplained compromise such as 40.5. Undo restores the prior constraint state.
- **SK-05 · Constraint families:** On a fresh sketch create horizontal/vertical lines, two equal circles, concentric circles, a tangent line/circle, a perpendicular pair, and two segments symmetric about a construction axis. Apply each named relation separately; perturb a free handle and measure the defining relation. Test collinear, parallel, midpoint, and coincident similarly.
- **SK-06 · Degrees of freedom:** Start with one unconstrained circle. Constrain center to the origin and then radius. Check freedom reduces appropriately and a fully constrained object cannot drift under drag. Unlock/remove one constraint and verify only the newly permitted motion is allowed. Do not assert solver-internal DOF counts for redundant constructions.
- **SK-07 · Trim lifecycle:** Trim one side of a dimensioned rectangle where an intersecting line splits it; delete a constrained circle; undo both. No orphan constraint references, invisible locks, duplicated dimensions, or crashes. Restored entities recover their intended constraints and editable handles.
- **SK-08 · Snapping priority:** Draw near a grid intersection, endpoint, midpoint, and circle center at three zoom levels. Record the snap indicator before release. The committed point must match the advertised target; switching off grid snapping must not switch off explicitly enabled geometric snaps.
- **SK-09 · P0 · Arithmetic and units:** Enter `25.4/2`, then a documented equivalent inch expression in a length field. Expect 12.7 mm for the first. Change display units and re-enter an equivalent length. Verify geometry is not scaled twice. Explicitly record unsupported unit-expression syntax as a gap.
- **SK-10 · Bad expressions:** Submit empty text, `1/0`, a malformed expression, a very large exponent, and a negative radius. Reject nonfinite or invalid values without changing the previous parameter. In a comma-decimal locale, test documented decimal parsing and ensure `1,5` is not silently read as 15.
- **SK-11 · Construction/plane identity:** Convert M01's diagonal to construction geometry and back; create the same rectangle on XY, YZ, and XZ, extruding normal to each. Construction lines must not split material regions. The chosen plane and axes must remain correct after exiting/re-entering sketch mode and reopening.
- **SK-12 · Sketch variants:** On a fresh sketch test center/diagonal rectangle, three-point/center arc, polygon side count 3/6/12, ellipse axes, and both supported spline modes. Edit defining handles and dimensions. Unsupported variants are recorded individually; a visible tool option that creates a different entity is a failure.

### Solid creation, booleans, and direct editing

- **SO-01 · P0 · Auto boolean:** In M05, pull a profile away from its contacting face, push a profile into a solid, and extrude a disconnected profile. Capture the automatically selected action before commit. Compare with current Shapr3D and verify explicit New Body/Union/Subtract overrides produce the stated geometry. [S05]
- **SO-02 · P0 · Extent semantics:** In M02, create one cut with Through All and another with fixed distance 8. Increase thickness to 12. Only the Through All cut must automatically traverse the new thickness. For To Object, move its target face and verify the chosen reference remains the target.
- **SO-03 · Start, sides, and draft:** From a 20 × 10 XY rectangle, test start offset 5, total symmetric thickness 10, and a documented 5° taper with a stated direction. Capture settings and inspect bounds/sections. Missing draft/start/extent options are individual parity gaps; numeric fallback workarounds do not pass those options.
- **SO-04 · Contact boundary sweep:** Use M06 with B's X-min at 19.9, 19.99, 20, 20.01, and 20.1. Run all three booleans on independent copies. Require correct occupancy for positive overlaps and documented handling of empty/disconnected results, without sliver material or unbounded retries.
- **SO-05 · P0 · Blend order:** On M05, fillet the inside vertical/long joint edge at a conservative radius 1; then chamfer an unrelated outer edge by 0.5. Reverse order in another branch. Compare each valid result with its own reference; neither sequence may silently drop the earlier feature.
- **SO-06 · Curved-face offset:** Start with M04. Offset its outer cylindrical face radially outward by 1, leaving the bore unchanged, using explicit offset-distance semantics. Expected radii 16/8, height 8, volume `1536π`. Then offset the bore radius from 8 to 9 in a separate branch and inspect the sign and affected face set. [S36]
- **SO-07 · Multiple openings in shell:** On a 30 × 20 × 10 box remove top and bottom and shell inward by 2, if supported. The rectangular tube volume is `(600−26×16)×10` = 1,840. Require two open ends. Unsupported multi-face shell is a gap, not a pass for a one-face tray.
- **SO-08 · Sweep discontinuity:** Use M08 with two path segments separated by 0.1 mm, then join their endpoints explicitly. Compare failure/recovery and final shape. A disconnected path must not quietly sweep only the first segment while reporting the complete operation successful.
- **SO-09 · Loft ordering:** Add M09's middle profile, select bottom/top/middle, and compare with the explicit bottom/middle/top order. Check connection points and any guide intersection diagnostics. A failed loft must leave profiles and the previous body editable.
- **SO-10 · Revolve boundaries:** On M04 test 1°, 180°, 359.9°, and 360°, plus 0°. For valid sweeps volume scales by angle/360. Inspect near-full seam overlap and end caps. Test height/pitch settings only if the tool exposes them, recording their exact meaning separately from pure revolve.
- **SO-11 · P0 · Imported solid editability:** Import M02 STEP and apply a 0.5 chamfer to one bore rim; change a planar thickness by +2; export again. Verify analytic bores, valid solid, and changed dimensions. A rendered mesh masquerading as an editable imported solid fails.
- **SO-12 · Wrap/emboss and helix:** On a radius-15 cylinder, apply a small text emboss of depth 0.5 if exposed; on a separate case build a helix with radius 10, pitch 5, two turns, and radius-0.5 section. Capture a current Shapr3D equivalent workflow and reference geometry. Missing options are extended gaps; failed previews must roll back fully.

### History, variables, and persistent references

- **HI-01 · P0 · Upstream width change:** In M16 change W to 80 and back to 60 after all features exist. Check shell, hole centers, volume, and feature operands at both states. No downstream operation may attach to a different wall or hole because an index changed.
- **HI-02 · P0 · Topology changes:** On M02 add a fifth hole near (40,25), then remove it through its source sketch. Keep a downstream chamfer on the original corner hole. Verify that chamfer remains on the intended original hole through recomputation and reopening.
- **HI-03 · Parent deletion:** Delete M16's HoleSketch while BottomHoles depends on it. Require an explicit dependency decision or visible broken-feature state. Undo restores the connection. A successful-looking model with silently frozen or misattached dependent geometry fails.
- **HI-04 · Suppress and restore:** Suppress M16 Shell, then unsuppress. Record downstream feature status and geometry at both stages. No permanently lost hole reference after restoration. Suppression, visibility, and deletion must not be confused. [S19]
- **HI-05 · Reorder/breakpoint:** Attempt to move BottomHoles before its sketch/parent; insert a breakpoint before Shell, change W, then restore the full timeline. Invalid ordering must be prevented or diagnosed. Future geometry cannot remain selectable as if it already exists before the breakpoint.
- **HI-06 · P0 · Undo branch:** Perform three edits on M14, undo two, and make a different new edit. Redo must not resurrect the discarded branch or double-transform the body. Compare all parameters and geometry, not only the visible Undo button title.
- **HI-07 · Variable rename/cycle:** In M16 rename W and update its references. Then try a missing variable, a direct self-reference, and a two-variable cycle. Require bounded evaluation and clear errors; previous valid values must remain recoverable without force-quitting.
- **HI-08 · Operand editing:** Change the selected edge for M07's existing blend and change the profile/axis for M04's existing revolve using history where exposed. Verify the new operand and old parameter are both respected. Lack of operand editing is recorded separately from scalar parameter editing.
- **HI-09 · Independent identity:** Duplicate M14, rename both copies differently, hide one, and edit the other. Save/reopen. Verify document/body IDs and selected state do not alias, while explicit linked history relationships retain their advertised behavior.
- **HI-10 · P0 · Reopen broken history:** Create a deliberately broken dependency in a disposable M16 copy, save, quit, and reopen. The failure indicator must survive, point to the relevant feature, and allow repair or undo-equivalent recovery from a saved checkpoint. Reopening must not silently certify stale cached geometry as a valid recomputation.

### CAD files, mesh files, and archive boundaries

- **IO-01 · P0 · STEP full lifecycle:** Export every analytic M01–M14 result, import in a fresh app process and independent reader, and run section 3 checks. Inspect STEP's actual schema and units. A successful file-picker dismissal or nonzero file size is not a pass.
- **IO-02 · P0 · Placement:** Export M14's rotated/translated tag and M11's patterned pins. Compare absolute bounds, off-center feature locations, and all instance positions. Catch unbaked transforms, double transforms, and copied instances stacked at the origin.
- **IO-03 · Units:** Create an equivalent one-inch cube in a reference CAD tool and export a genuine unit-declared STEP. Import beside a 25.4 mm cube. Verify equal bounds and volume 16,387.064 mm³. Do not manufacture an “inch STEP” by changing only a header string without converting its coordinate representation.
- **IO-04 · P0 · Mixed analytic and mesh:** Import the supplied M01 STL and M04 STEP into the same project, name both, and export STEP. If mesh-only bodies are skipped, the app must identify omissions clearly; the file must contain the analytic washer at the right location. Test mesh-only export refusal separately.
- **IO-05 · Export scope:** With three named bodies, one hidden and one selected, test each offered selection/visibility/export-scope option. Independently count exported solids and check names/materials only where the format and product promise them. The UI must make scope discoverable before data is assumed complete.
- **IO-06 · P0 · Malformed STEP:** Import `NEGATIVE_truncated.step` and `NEGATIVE_not_step.step` into an existing M01 project. Require a recoverable error or explicitly reported partial recovery; never silent success. The preexisting document remains unchanged and still exports correctly.
- **IO-07 · P0 · Malformed STL:** Import `NEGATIVE_truncated_binary.stl` and `NEGATIVE_open_triangle.stl`. The former must fail cleanly. An intentionally open mesh may be rejected or kept as an explicitly open/reference mesh; it must not be falsely reported as a valid closed solid with meaningful solid volume.
- **IO-08 · STL precision/units:** Export M04 with coarse and fine mesh settings, if offered. Compare hole diameter, dimensions, triangle orientation, watertightness, and volume under the mesh gate. STL has no standardized intrinsic unit declaration; record the import unit choice and verify dimensions. [S27]
- **IO-09 · DXF entities:** Import both supplied DXFs, verify endpoint/circle/arc/ellipse coordinates, and extrude closed regions only. Test unsupported spline/polyline/text/layer content with separately sourced fixtures. Record omitted entity types explicitly; plain sketch DXF need not preserve constraints. [S02]
- **IO-10 · P0 · Save failure:** Export to a test file-provider location made unavailable or read-only, and cancel the destination picker. Require accurate failure/cancel feedback, no fake success indicator, and an intact native project. Re-enable the destination and retry without restarting the modeling session.
- **IO-11 · Archive validation:** On copies of a native archive test truncation, an unsupported future schema version, duplicate body IDs, and a missing geometry payload using an isolated fixture generator. Require validation before mutation. Malformed archive paths must not write outside the chosen import staging area. Never mutate real project stores.
- **IO-12 · Names and repeated transfer:** Export a project with spaces, Unicode, very long names, and two same-named bodies. Import the same model twice intentionally and verify two explicit sets of objects. Also cancel/retry import once: cancellation must not leave a hidden first set that duplicates on retry.

### Selection, navigation, touch, and desktop behavior

- **UI-01 · P0 · Face versus body:** On M12, single-select a low top face and invoke a face tool; separately select the whole body and move it. Verify the highlight and operation target agree. Repeat via Pencil, finger, mouse, and Items panel where supported. [S28]
- **UI-02 · P0 · Occluded selection:** Put M14 behind M01. Attempt selection normally, with Select Through/overlap choice, and with X-Ray/hidden edges. Only an explicitly chosen occluded object may be edited. Hiding an object must not leave its invisible face as an accidental target.
- **UI-03 · Window/crossing selection:** Place two separate pins, one fully inside the marquee and one touching its boundary. Compare left-to-right and right-to-left selection plus body/sketch filters. Verify the selection count and affected objects on Delete, then undo. [S28]
- **UI-04 · Multi-selection persistence:** Select four M02 bore rims with the platform's multi-select gesture/key, orbit, and add/remove one edge. Selection must not unexpectedly collapse to one or include a back-face rim. Check the resulting blend targets before commit.
- **UI-05 · Gesture arbitration:** While sketching with Pencil, pan/zoom with fingers; while pulling a face, orbit and then continue the tool. Navigation must not draw an extra segment, change extrusion unintentionally, or commit a preview. Repeat with rapid alternation of mouse/trackpad and keyboard.
- **UI-06 · P0 · Phone keyboard:** On the smallest iPhone open M02, select a hole dimension, show the keyboard, type 6, rotate the device, and confirm. The value, unit label, selected feature, and confirm/cancel path remain usable; no offscreen control is required to finish.
- **UI-07 · Panels and window size:** Open Items, History, and a numeric tool; resize the Mac window and use iPad multitasking. Toolbars cannot overlap active input or permanently cover the selected geometry. Close/reopen panels and confirm focus returns to the intended field.
- **UI-08 · Views/section:** Capture M14 in Top, Front, Right, and Isometric, then toggle orthographic/perspective and Section. Axis labels and handedness must agree with the asymmetric hole. Section, Isolate, and display modes must not mutate saved solid geometry. [S29]
- **UI-09 · P0 · Tool exit:** During M07's valid and invalid previews, use Done, empty-space completion if offered, Escape, Cancel, and tool switching in separate runs. Record each supported exit convention. Only explicit commit paths change the document; an invalid preview cannot be saved as a successful operation.
- **UI-10 · Desktop focus/shortcuts:** In an active dimension field use copy/paste, Return, Escape, Undo, and Delete; then repeat with canvas focus. Text-edit shortcuts and modeling shortcuts must target the right context. Opening a system file dialog must not dispatch keystrokes to a hidden modeling tool. [S30]
- **UI-11 · Accessibility:** On D1/D3/D5 test system text scaling, contrast, VoiceOver labels/focus for essential numeric/confirm controls, and keyboard-only access to core dialogs. Selection/error state must not depend on color alone. Record limitations of nonvisual 3D manipulation separately from inaccessible basic controls.
- **UI-12 · Repeated precision pick:** Select M13's inner wall or edge 20 times at normal working zoom, alternating orbit and selection. Record wrong-target rate and correction actions. Repeat with the small M07 fillet edge. Every committed edit must affect the highlighted target; larger touch targets must not sacrifice target accuracy.

### Persistence, cancellation, and interruptions

- **PE-01 · P0 · Cold reopen:** Run M16 through save, gallery return, project reopen, app quit/relaunch, and another edit. Compare exact geometry and semantic metadata. Use persistence-safe launch settings; a test that resets the store cannot validate persistence.
- **PE-02 · P0 · Background during edit:** On a physical iPhone/iPad background the app while M07 has an uncommitted preview, then return. Require one coherent state: restored pending tool or canceled preview according to product behavior; no half-committed geometry or unintended duplicate history step.
- **PE-03 · P0 · Kill after acknowledged save:** Save an M14 edit and wait for the app's actual completion acknowledgement, then terminate/relaunch. The acknowledged edit must exist. If autosave has no visible completion signal, use instrumented completion evidence; do not invent a safe delay.
- **PE-04 · Save interruption:** In a disposable project terminate during a controlled save fault-injection point. On reopen, expect either the last complete revision or the new complete revision plus truthful recovery feedback. A hybrid file, missing unrelated bodies, or unrecoverable archive fails.
- **PE-05 · P0 · Cancel long operation:** Start a large M11 pattern or complex boolean, cancel, then open M01 and perform a valid edit. Cancellation leaves the prior geometry intact and the app usable. Record cancellation latency; a cosmetic cancel button with continued later mutation fails.
- **PE-06 · Stale asynchronous result:** Start operation A, cancel it, then complete operation B on the same document. Wait longer than A's original completion time. A must not overwrite B or append an unexpected history step. Repeat after switching to a different project.
- **PE-07 · Low storage:** Use a controlled storage-failure test environment for save/export. Require a recoverable message, no overwrite of the last valid project, and successful retry when capacity is restored. Do not fill the user's real drive to run this case.
- **PE-08 · Offline work:** With all needed files stored locally, disable network and build/reopen/export M01. Local modeling must follow the app's declared offline contract. A failed cloud file provider request must not disable unrelated local editing. Shapr3D documents offline modeling separately from network-dependent services. [S31]
- **PE-09 · Migration:** Open a frozen native fixture from each supported earlier app/schema version; save a migrated copy and reopen. Check bodies, constraints, variables, B-reps, and warnings. Preserve the original fixture. Unsupported future versions fail safely with a specific message.
- **PE-10 · Repeated sessions:** Perform 20 open/edit/save/close cycles on a duplicate M16, alternating two projects. Check no model cross-contamination, thumbnail/selection mismatch, accumulating duplicate entities, or steadily rising retained memory after returning to a stable idle state.

### Presentation, measurement, and app-specific functionality

- **PV-01 · P0 · Measurement truth:** Measure M01/M02/M04 in the app and in independent B-rep inspection. Verify mm/mm²/mm³ labels and rounding, plus actual versus displayed precision. Selecting a face reports that face's area, not the whole body's surface area.
- **PV-02 · Point distance:** On M01 measure from (0,0,0) to (40,30,10). Expect distance `sqrt(2600)` = 50.990195 and absolute component differences 40,30,10. Repeat after M14-like placement and check the tool's declared world/local-axis convention.
- **PV-03 · Visibility and isolation:** Hide one of M11's pins, isolate another, save/reopen, then restore visibility. Model data is preserved and only the intended objects are selectable. Export visibility scope follows its explicit option, not accidental viewport state.
- **PV-04 · Materials and images:** Assign two distinct materials to separate bodies, undo/redo, save/reopen, and export a color-supporting format. Insert a PNG reference, adjust scale/opacity, and reopen after moving the source file. Geometry volume cannot change with material or image display settings.
- **PV-05 · Symbols and sketch copies:** Capture an original sketch symbol, stamp twice, rename it, edit one instance, and undo. Verify the app's stated linked/independent-instance behavior and persistence. This is an OpenShape3D-specific contract, not assumed Shapr3D equivalence.
- **PV-06 · 3D delivery previews:** Export available OBJ/3MF/GLB/USDZ variants from M14 and reopen with a compatible viewer. Check orientation, units/scale, body completeness, and colors where supported. Verify phone/tablet AR scale against a known 40 mm dimension; Mac 3D preview is evaluated separately from device AR.

### Extended parity and declared scope gaps

- **EX-01 · Advanced blends:** On a duplicate M07/M05 test two-distance chamfer, chordal fillet, G2 continuity, tangent propagation, and corner options only where advertised. Capture a separate Shapr3D reference for every option. Do not apply the circular radius volume formula to non-circular blends. [S09]
- **EX-02 · Guided/periodic loft:** Extend R02 with explicit guide curves and documented end continuity. Verify every guide intersects each required section; break one intentionally. Missing guided/periodic modes remain individual gaps even if a default loft renders a similar shape. [S11]
- **EX-03 · Construction variants:** Construct planes at offset 10, angle 30°, through three noncollinear points, midplane between parallel faces, and normal to a curve. Test axis from two points and cylindrical geometry. Verify defining relationships survive edits; collinear/ambiguous input must be rejected. [S32]
- **EX-04 · Transform variants:** On M14 test point-to-point Translate, Rotate Around Axis at 17.5°, Align to a matching face/axis, mirror about an offset plane, and nonuniform scale if exposed. Check pivot, handedness, and intended dimensions. Record each unavailable option rather than a single vague transform gap. [S16]
- **EX-05 · Assembly handling:** Import a small multi-body STEP with repeated instances and hierarchy from the reviewed external corpus. Verify body placements and duplicates. Distinguish a geometric multi-body import from assembly constraints/mates; do not promise mechanical motion merely because bodies share a file. [S03]
- **EX-06 · 2D drawings:** If drawings are in release scope, generate front/top/right and section views of M02/M03, dimension hole centers and thickness, edit the model, and verify drawing updates and exported scale. Otherwise report drawings as an explicit product-parity gap; sketch DXF alone does not pass this feature. [S33]
- **EX-07 · Visualization:** If advanced rendering is in scope, compare material assignment, environment, camera, and image export with a frozen reference setup. Evaluate missing visualization capabilities separately from exact geometry; no expectation of pixel-identical renderers is implied. [S34]
- **EX-08 · Sharing/sync:** If collaborative cloud projects are in scope, use dedicated test accounts to edit a copied project offline on two devices, reconnect, and verify conflict handling, versions, and permissions. Otherwise record sync/collaboration as out of core scope. No production sharing or message sending is part of executing this plan. [S35]

<!-- PAGEBREAK -->

## 7. Performance and resource tests

Correctness gates remain active at every load. Performance figures below are proposed starting budgets for small mechanical parts, not measured results or official Shapr3D claims. The team should approve per-device budgets after the first controlled baseline and preserve those budgets through the release cycle.

### Reproducible workloads

| Load | Construction | Required check |
|---|---|---|
| L1 · small | M02 plate and native history | Complete lifecycle, selection, camera, basic edits |
| L2 · medium | 10 × 10 separate M02 copies on a 100 × 70 grid | 100 solids; exact translations; volume sum 100 × M02 |
| L3 · large | 20 × 25 M02 copies on the same grid | 500 solids; bounded opening, isolation, export/cancel |
| L4 · deep history | M16 with 100 sequential small parameter/transform edits | Recompute early parameter, undo/redo, save/reopen |

For L4, keep an exact parameter ledger and final transform matrix; inverse edit pairs should return to the known original. Record whether the implementation stores or coalesces each edit. For sketch stress use 100, then 500, then 1,000 documented entities with a known constraint layout; for mesh stress use measured 100k and 1M triangle files within device resource limits. No stress file is bundled at those sizes; generate them under a declared resource cap and freeze their hashes.

### Measurement protocol and initial budgets

- Run a release build without debugger and without screenshot capture during timing. Record the same machine/input/power state for both apps. Allow five warmups, then collect 30 samples for median, p95, and maximum; report the cold-open measurement separately.
- Measure interaction from input to visible acknowledgement, and modeling from commit to usable final geometry. Proposed L1 budgets: selection/input acknowledgement p95 ≤ 100 ms; common edits p95 ≤ 2 s; sustained orbit/drag rendering ≥ 30 fps. Measure frame times with platform tools rather than inferring them from a compressed recording.
- Proposed L2 opening/export p95 ≤ 10 s with clear progress for longer work. A cancel action should visibly acknowledge within 250 ms and leave the document usable within 2 s for supported cancellable operations. Record exceptions where the kernel cannot interrupt immediately; a stale result must still never commit after cancellation.
- For L3/L4, establish explicit per-device budgets after one reference run. Report completion time, peak memory, timeout/cancel outcome, and geometric correctness. Never call a truncated/omitted model a performance success.
- Compare memory after five warm cycles with memory after twenty cycles at the same idle point. Investigate growth exceeding both 10% and 50 MB, or any continuing upward trend. Cache warming is not automatically a leak; retain traces to explain the difference. Any physical-device termination due to memory pressure during a core workload is a release failure for that supported configuration.
- Compare Shapr3D timings only on matched physical hardware and equivalent operations. A slower result identifies a performance gap; its severity is based on the frozen user-facing budget. Do not use different kernels or an old device to excuse a failed correctness gate.

### Exploratory adversarial sessions

After the deterministic suite, schedule two 60-minute sessions per release: one new-user build of R01 and one experienced-modeler session on M16/R02. Randomize reasonable order, selections, views, and cancel/undo actions, but record a seed and action log when using automation. Convert every reproducible defect into a minimized deterministic case. Keep exploratory findings separate from deterministic pass-rate claims.

## 8. Automation that complements manual CAD work

### Existing test seams and what to add

Source inspection at the pinned commit identified the following useful starting points. Test presence is not evidence that the corresponding release build passes.

| Risk | Existing suites/files to start from | Required added evidence |
|---|---|---|
| Wrong geometry | `GeometryOracleTests`, `OCCTKernelTests`, `BooleanTests` | Match named M-series formulas, bounds, counts, and analytic features |
| Blends and shell | `BlendStressTests`, `OCCTFilletDiagnosticsTests`, `KernelShellTests` | Invalid operation rollback; exact M07/M03 outputs |
| Reference identity | `SignatureNamingTests`, `FeatureRefsTests`, `FeatureGraphEvalTests` | M16 upstream edits plus persistence and wrong-face assertions |
| STEP and placement | `STEPKitTests`, `TransformedBrepTests`, `InterchangeFormatTests` | Independent reader output and world-space M14 checks |
| Sketch solver | `ConstraintLifecycleTests`, `ConstraintResidualTests`, `VariablesTests` | Conflict rollback, unit entry, deletion, and downstream updates |
| UI flow | `ParityWalkthroughUITests`, `FaceFlowUITests`, `SketchFlowUITests` | Geometry/parameter assertions at checkpoints, beyond screenshots |
| Persistent projects | `ProjectArchiveTests`, `PersistedFeatureTests`, gallery/UI suites | Cold launch, older schemas, fault-injected atomic saves |

Keep geometry unit tests as pure values. The repository's workflow notes warn against creating `DocumentSession`/SwiftData `ModelContainer` in unit tests and specify `-parallel-testing-enabled NO` for these test runs. Use the editor's normal command boundary for integration tests, then verify kernel result, document metadata, and undo transaction together.

### Four test layers

1. **Kernel:** analytic fixtures, invalid argument handling, topology validation, and serialization. These tests can isolate geometry failures quickly.
2. **Document/feature graph:** replay commands, recompute upstream changes, inspect stable references, compare snapshots before/after failure, and verify undo/redo. A kernel test cannot prove a UI command selected the right face.
3. **Visible UI:** build from blank with actual selection and numeric entry, inspect labels and tool state, and collect geometry checkpoints. Prefer accessibility identifiers and state waits to fragile pixel coordinates and sleeps. Use camera-normalized geometry selection only where necessary.
4. **External exchange/physical devices:** independently inspect exported solids and run Pencil/touch, save interruptions, memory, and real file-provider flows. API/agent-control shortcuts can seed a specialized import test, but cannot substitute for the blank-project user workflow.

### Useful mathematical regression properties

- Rigid transform preserves volume and distances; its inverse returns geometry and placement to the original.
- Uniform scale s multiplies lengths by s, areas by s², and volumes by |s|³. Mirror preserves unsigned occupied volume and valid shell orientation.
- For simple valid overlap, `V(A∪B)+V(A∩B)=V(A)+V(B)` and `V(A−B)=V(A)−V(A∩B)`. Validate solids before applying these identities.
- Split volumes sum to the original and recombination occupies the original material; no hidden retained original is included in the sum.
- The same body built by different routes agrees geometrically: M02 nested-profile versus cut; M03 shell versus cavity subtraction; M04 revolve versus annular extrusion; M05 L-profile versus union.
- Save/load and STEP round-trip preserve geometry within their stated gates. Native save/load additionally preserves the model's declared editable relationships; STEP does not promise native history.

### Suggested test commands

Choose a current installed simulator with `xcrun simctl list devices available`; do not reuse an outdated hard-coded device ID from an old report. Run from the repository root, replacing `TEST_SIMULATOR_ID` with that test device's actual ID:

```sh
xcodebuild test -scheme openshape3d \
  -destination 'platform=iOS Simulator,id=TEST_SIMULATOR_ID' \
  -parallel-testing-enabled NO \
  -only-testing:openshape3dTests/GeometryOracleTests \
  -only-testing:openshape3dTests/STEPKitTests \
  -resultBundlePath /tmp/openshape-qa-core.xcresult
```

```sh
xcodebuild test -scheme openshape3d \
  -destination 'platform=iOS Simulator,id=TEST_SIMULATOR_ID' \
  -parallel-testing-enabled NO \
  -only-testing:openshape3dUITests/ParityWalkthroughUITests \
  -resultBundlePath /tmp/openshape-qa-ui.xcresult
```

Use a new result-bundle path each run. Do not run `OS3D_RESET_STORE` or equivalent fresh-state hooks in persistence tests. These commands are developer instructions; they were not executed as part of document preparation. The fixture generator's separate checks do not constitute an app test run.

<!-- PAGEBREAK -->

## 9. Execution, defect reporting, and release decisions

### First campaign sequence

**Days 1–2:** freeze the build/device matrix; capture and review M01–M07 and M14 Shapr3D baselines; verify supplied fixtures; establish save completion evidence and geometry extraction. Assign a CAD-literate reviewer, QA owner, and engineering triage owner. One person may hold more than one role.

**Days 3–5:** complete all original model construction and lifecycle runs on D3 and D5; run D1/D2 phone-critical cases; implement the smallest missing geometry assertions. Triage crashes, data loss, wrong-face operations, and wrong exports immediately.

**Days 6–8:** run M16/history attacks, external references, corrupt files, migration, cancellation, and physical-device stress. Complete D4/D6 input and window variants. Capture missing feature gaps explicitly.

**Days 9–10:** rerun fixed cases, adjacent model/lifecycle coverage, and a clean release-candidate smoke on all supported device/input rows. Produce a signoff report with unresolved defects and exclusions. This is a suggested schedule for planning; actual duration depends on baseline availability, team size, and failures found.

### Cadence

Every relevant change: run the smallest affected analytic/document test and a UI reproduction of the defect. Before merging modeling, persistence, or interchange changes: run the core model subset and required existing suites. Nightly: all analytic and feature-graph tests, generated input cases, and targeted UI lifecycle runs. Before a release: full designated core suite, physical-device matrix, external imports, and exploratory sessions. A stable pass must not rely on repeated blind reruns that hide flakiness.

### Severity is impact; priority is execution order

| Severity | Example | Release handling |
|---|---|---|
| S0 · critical | Lost committed work, wrong-part export without notice, reproducible crash on ordinary modeling | Stop release; preserve reproduction files immediately |
| S1 · major | Wrong geometry/units, wrong face edited, core workflow unavailable, failed save recovery | Must fix for core release |
| S2 · moderate | Recoverable workflow defect, essential action needs a documented workaround | Explicit owner and dated disposition; cannot waive wrong core geometry |
| S3 · minor | Cosmetic/UI mismatch with no effect on modeling correctness or access | Track and prioritize separately |

P0 cases execute first because they protect critical workflows; P1 covers broader required behavior. Extended parity gaps can be scheduled, but no report may label those missing features as equivalent to Shapr3D.

### Required defect record

Use `RESULTS_TEMPLATE.md` for run evidence and `results_template.json` for machine-readable capture. For each defect include:

1. Case/model/checkpoint, severity, priority, reproducibility count, app commit/build, exact device/OS/input, Shapr3D version/plan, and locale.
2. Minimal starting native file plus fixture checksum and source URL. Include all steps needed from that file; preserve the original full model separately.
3. Expected geometry and actual measurements with units; selected face/edge/body identity and screenshots immediately before the operation; exact error text if present.
4. Screen recording with touches/pointer where possible, native file after failure, exported STEP/STL, logs/crash trace, and independent comparison output.
5. Whether cancel, undo, reopen, retry, or a different construction route recovers; whether any committed work is lost; suspected layer without claiming an unproven cause.
6. Fix reference, regression case, clean rerun evidence, reviewer, and remaining affected platform variants.

**Illustrative expected-result field, not an observed bug:** “M14 placed tag: bounds must be (80,−50,25)..(100,−10,29), bore axis X=94, Y=−43; STEP must match these absolute coordinates.” Actual output stays blank until the test is run.

### Release gates

- All designated core M-series and adversarial cases executed on the required platform/input coverage, with no unresolved S0/S1 defect and no unexplained comparison result. Required cases marked BLOCKED, NOT RUN, or missing core functionality do not count as passing.
- Every core model is valid after creation, specified revision, undo/redo, native reopen, and required exchange. A passing imported fixture cannot stand in for a failed blank-project build.
- No silent omitted bodies, scale errors, stale-result commits, wrong-face edits, or native data loss. All invalid-input cases preserve the prior committed document and remain usable.
- Performance meets the frozen budgets on supported physical devices. Two consecutive clean release-candidate smoke runs are required; record any flaky failure rather than deleting it from the result set.
- Every deferred S2/S3 issue and extended gap has an owner, scope decision, and user-facing consequence documented. The product owner signs the actual scoped release claim, not a blanket “Shapr3D parity” label.

Report **completed core cases / required core cases**, plus pass/fail counts for geometry, workflow, editability, and durability. Publish feature-gap coverage and device coverage separately. A single average score can hide a catastrophic export failure.

<!-- PAGEBREAK -->

## 10. Fixture pack and provenance

### What is included

The `fixtures` directory contains 20 STEP files representing M01–M14 and selected checkpoints, six STL companions for mesh import/export comparison, two DXF sketch inputs, and four intentionally invalid/open import inputs. `fixture_manifest.json` records hashes and expected outcomes. `occt_validation.csv` is the raw generation/STEP round-trip measurement log. M15/M16 final models and external R-series samples require the documented construction or source download.

| STEP group | Supplied files/checkpoints | Geometry role |
|---|---|---|
| M01–M05 | Block, four-hole plate, open tray, washer, L bracket | Exact simple dimensions and volume |
| M06 | Two inputs; union; subtraction; intersection | Operand order, counts, and placement |
| M07 | Single-edge circular fillet; equal-distance chamfer | Exact dress-up volume and local geometry |
| M08–M09 | Straight cylinder; conical taper | Mathematical targets for Sweep and Loft |
| M10–M11 | Two split halves; six patterned pins | Separate solids and precise placement |
| M12 | Stepped input; replaced-face result | Detect incorrect target/destination |
| M13–M14 | Thin frame; original tag; placed tag | Thin features and transform/export truth |

STL companions are unitless mesh files with intended coordinates in mm. Their tessellation is a comparison input, not an analytic solid reference. DXF files explicitly set insertion units to mm; verify the receiving app respects or requests those units. Negative files are deliberately small and safe to inspect; they are never valid benchmark outputs.

The original generator uses direct OCCT operations and validates each solid before export, then reads STEP back and checks validity, expected aggregate volume, and expected number of solids. Several fixtures intentionally use a different construction method from the app exercise: M03 cavity cut versus Shell; M04 concentric cylinders versus Revolve; M08 cylinder versus Sweep; M09 cone versus Loft. This makes UI/feature regressions harder to hide, while the independent formula remains the primary exact oracle.

The generator uses the repository's OCCT 7.8.1 library. Its standalone Mac Catalyst command-line host bypasses library global teardown after explicitly closing output files; this is documented in the generator source. It does not change app code. Rebuild instructions are in `tools/README.md`. Do not treat tool generation as independent evidence of the app's kernel robustness or a Shapr3D result.

### Reference capture still required

No `.shapr` baseline or external NIST/tutorial binary is bundled. The developer must obtain these from the linked sources, choose exact versions/files, review their measurements, and freeze them before differential testing. Baseline capture is a named test task; until completed, cross-app parity for those cases is NOT RUN. The supplied original mathematical fixtures are immediately usable for file import and geometric comparison.

## 11. Source register

Official pages were checked during preparation on September 2, 2026 (local date). Links are live documentation and may change. Record the actual reference app/version and retrieval date when running tests. The test recipes, numeric gates, resource budgets, and release criteria are proposed for this project; they are not vendor guarantees. Source IDs beside a case identify the relevant documented tool or workflow.

### Platforms, constraints, and modeling

- **S01 — Compatible devices:** https://www.shapr3d.com/compatible-devices — authoritative platform/device scope; use iPad/Mac as the comparison environments.
- **S02 — Supported file types:** https://support.shapr3d.com/hc/en-us/articles/7874523890076-Supported-file-types — import/export formats, plan restrictions, and DXF limitations.
- **S03 — Import:** https://support.shapr3d.com/hc/en-us/articles/7874501645724-Import — imported history behavior and STEP hierarchy handling.
- **S04 — Constraints overview:** https://support.shapr3d.com/hc/en-us/articles/7873983670044-Constraints-overview — sketch relationships and selection-aware constraints.
- **S05 — Extrude:** https://support.shapr3d.com/hc/en-us/articles/7874453786908-Extrude — automatic booleans, sides, extents, starts, and draft options.
- **S06 — Shell:** https://support.shapr3d.com/hc/en-us/articles/7874427098268-Shell — face removal and wall-thickness editing.
- **S07 — Revolve:** https://support.shapr3d.com/hc/en-us/articles/7874456570268-Revolve — axis-based creation and angle/history settings.
- **S08 — Boolean operations:** https://support.shapr3d.com/hc/en-us/articles/10565066254108-Boolean-operations — union/subtract/intersection concepts and operand retention.
- **S09 — Chamfer/Fillet:** https://support.shapr3d.com/hc/en-us/articles/7874402399900-Chamfer-Fillet — circular/chordal, continuity, and corner distinctions.
- **S10 — Sweep:** https://support.shapr3d.com/hc/en-us/articles/7874456833948-Sweep — profile/path modeling workflow.
- **S11 — Loft:** https://support.shapr3d.com/hc/en-us/articles/7874427572508-Loft — ordered sections, guide intersections, and optional periodicity.
- **S12 — Split Body:** https://support.shapr3d.com/hc/en-us/articles/7874462683036-Split-Body — splitting references and keeping originals.
- **S13 — Pattern (3D):** https://support.shapr3d.com/hc/en-us/articles/7874397541532-Pattern-3D — linear/circular body patterns and count/spacing options.
- **S14 — Replace Face:** https://support.shapr3d.com/hc/en-us/articles/7874457242268-Replace-Face — target/destination selection and history. Delete-face healing is a separate captured behavior, not inferred from this page.
- **S15 — Offset Edge (Sketch):** https://support.shapr3d.com/hc/en-us/articles/7874298998172-Offset-Edge-Sketch — sketch offsets and chain selection.
- **S16 — Transform menu:** https://support.shapr3d.com/hc/en-us/sections/7768328803228 — links to move, scale, translate, axis rotation, align, and mirror.
- **S17 — Text:** https://support.shapr3d.com/hc/en-us/articles/7874366069788-Text — text as sketch geometry and editing.
- **S18 — Project:** https://support.shapr3d.com/hc/en-us/articles/7874464667676-Project — projected sketches/edges and linked-projection options.
- **S19 — History:** https://support.shapr3d.com/hc/en-us/articles/11567903089180-History — feature cards, breakpoints, suppression, and editing.

### Independent inspection and reference exercises

- **S20 — NIST STEP File Analyzer and Viewer:** https://www.nist.gov/services-resources/software/step-file-analyzer-and-viewer — STEP syntax/entity analysis, sample data, and system requirements; not a complete geometric equivalence checker.
- **S21 — OCCT BRepCheck_Analyzer:** https://occt3d.com/dev/doc/refman/html/class_b_rep_check___analyzer.html — shape validity checks; use version-matched headers for implementation.
- **S22 — OCCT BRepGProp:** https://occt3d.com/dev/doc/refman/html/class_b_rep_g_prop.html — geometric mass properties; use the exact shape rather than rendering triangles for B-rep metrics.
- **S23 — Variables and expressions:** https://support.shapr3d.com/hc/en-us/articles/18320182069916-Variables-and-expressions — variable references, expression entry, naming, and units.
- **S24 — Bracket mount tutorial/sample:** https://support.shapr3d.com/hc/en-us/articles/12470669638300-Bracket-Mount-Modeling-Basics-in-Shapr3D — R01 workflow and “Try it yourself” asset entry.
- **S25 — Pan handle tutorial/sample:** https://support.shapr3d.com/hc/en-us/articles/12470725468444-Pan-Handle-Design-with-Loft-Sweep-and-Subtract — R02 workflow and sample entry.
- **S26 — NIST CAD model/STEP corpus:** https://www.nist.gov/ctl/smart-connected-systems-division/smart-connected-manufacturing-systems-group/mbe-pmi-0 — R03 FTC/STC/CTC source definitions and file archives.

### Files, devices, and extended coverage

- **S27 — STL units:** https://support.shapr3d.com/hc/en-us/articles/7874502103068-STL-units — matching unit assumptions across mesh export/import.
- **S28 — Selecting geometry:** https://support.shapr3d.com/hc/en-us/articles/7770768736924-Selecting-geometry — selection types, filters, and area selection.
- **S29 — Section View:** https://support.shapr3d.com/hc/en-us/articles/7873938030492-Section-View — inspecting model interiors using a clipping plane.
- **S30 — Keyboard shortcuts, gestures, and hotkeys:** https://support.shapr3d.com/hc/en-us/articles/7873906073884-Keyboard-shortcuts-gestures-and-hotkeys — platform-specific controls; freeze chosen navigation settings.
- **S31 — Requirements and specifications:** https://support.shapr3d.com/hc/en-us/articles/7859723710108-Shapr3D-requirements-and-specifications — offline modeling versus network services.
- **S32 — Construct menu:** https://support.shapr3d.com/hc/en-us/sections/27721924446492 — construction plane/axis documentation entry point.
- **S33 — 2D Drawings:** https://support.shapr3d.com/hc/en-us/articles/7874466328348-2D-Drawings — drawing views and documentation workflows.
- **S34 — Visualization:** https://support.shapr3d.com/hc/en-us/articles/7874459464092-Visualization — material and presentation functionality.
- **S35 — Shapr3D Sync:** https://support.shapr3d.com/hc/en-us/articles/7873833167132-Shapr3D-Sync — project availability and synchronization behavior.
- **S36 — Offset Face:** https://support.shapr3d.com/hc/en-us/articles/7874400678428-Offset-Face — direct planar/curved face offsets and distance-type distinctions.
- **S37 — Export:** https://support.shapr3d.com/hc/en-us/articles/7874524196764-Export — export scope, units, formats, and resolution options.
- **S38 — Shapr3D manual index:** https://support.shapr3d.com/hc/en-us/articles/9760033847964-Shapr3D-Manual — recovery entry point if a specific article URL changes.

### Repository evidence at the pinned commit

Read `docs/STATUS_AND_NEXT_STEPS.md` for platform/test workflow and current caveats; `docs/MODELING_PARITY_GOALS.md` and `docs/SHAPR3D_PARITY_SPEC.md` for scope; `docs/FREECAD_PLAYBOOK.md` for hardening rationale; `openshape3d/Kernel/STEPKit.swift` for export omissions/placement; `openshape3dTests/GeometryOracleTests.swift` for exact-volume tests; and `openshape3dUITests/ParityWalkthroughUITests.swift` for the screenshot-oriented walkthrough. Revalidate this mapping when the build changes. Paths are repository-relative so the handoff remains portable.
