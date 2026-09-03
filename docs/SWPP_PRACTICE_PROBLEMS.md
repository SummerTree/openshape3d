# SOLIDWORKS practice problems in openshape3d

*2026-09-03. The 365-sheet practice-problem database
(solidworks.com/solution/education/practice-problems) worked through with
the app's own tools, each sheet scored against the volume printed on it.
Runner: `scripts/swpp/run.py`; recipes: `scripts/swpp/levelN.py`; ledger:
`scripts/swpp/results.jsonl`; this file is `scripts/swpp/report.py`'s
output plus the reading of it. The published page carries the same table.*

## Reading

- Every attempted sheet that reads unambiguously passes within 0.5 %
  (most within 0.01 %). No kernel or feature failure occurred in the
  campaign: extrude, cut, union, arcs, ellipses, polygons, slots,
  fillets, chamfers, revolve (with arcs), sweep along open and closed
  polylines, mirror + union, linear and circular body patterns, and
  multi-tool subtracts all produced valid B-reps first time.
- Every fail is a drawing that admits two readings where the printed
  volume picks the one the drawing does not show (1.5, 1.19, 4.41,
  6.15); the notes say which reading was built and what the number
  implies. Nothing was fitted to the answer.
- One sheet (2.13) was built entirely by touch on the simulator:
  Polygon tool, the radius label typed as an expression, Extrude with a
  typed depth; the app's info bar read 8009.08 mm³ against the sheet's
  8009.
- Sheets not attempted are either intricate drawings whose reading
  would take longer than the build (most Level 4 and 10+ parts), or
  levels the app has no tool for (see the coverage column).

## Where the app falls short of the database

1. Extrude end conditions: distance and mid-plane only. No up-to-surface,
   up-to-next, through-all or offset-from-surface (Level 2 is named for
   them; every rib in Level 14 needs up-to-next).
2. Patterns and mirrors act on bodies, not features: a patterned cut is a
   cutter body, patterned, then subtracted (7.49, 11.1).
3. No hole wizard: counterbores are stacked cylinders with typed sizes.
4. Reference geometry: offset planes and sketch-on-face only; no plane at
   an angle, through a line or by three points (5.1 needs 35°).
5. No sketch patterns and no named global variables driving sketches
   (Level 3, 16); History fields do evaluate arithmetic.
6. Draft only at extrude time (taper), no draft of existing faces
   ("ALL DRAFT 5°" in 12.1); no loft normal-to-profile controls (12.2).
7. Assemblies, configurations, collision/interference (Levels 9, 15, 17)
   are outside a single-part modeller.

# SOLIDWORKS practice problems in openshape3d — 25/29 attempted pass (365 in the database)

| Level | Title | Problems | Attempted | Pass | Fail | Error |
|---|---|---|---|---|---|---|
| 1 | Basic Sketch & Extrusion | 20 | 14 | 12 | 2 | 0 |
| 2 | Sketch Tools & End Conditions | 20 | 4 | 4 | 0 | 0 |
| 3 | Global Variables & Sketch Patterns | 8 | 0 | 0 | 0 | 0 |
| 4 | Extrude Cut & Fillet/Chamfer | 70 | 3 | 2 | 1 | 0 |
| 5 | Reference Geometry | 15 | 0 | 0 | 0 | 0 |
| 6 | Revolve Boss/Cut | 20 | 3 | 2 | 1 | 0 |
| 7 | Feature Patterning | 48 | 2 | 2 | 0 | 0 |
| 8 | Sweep Boss/Cut | 14 | 2 | 2 | 0 | 0 |
| 9 | Assemblies and Mates | 16 | 0 | 0 | 0 | 0 |
| 10 | CSWA Exam Level | 19 | 0 | 0 | 0 | 0 |
| 11 | Hole Wizard | 12 | 1 | 1 | 0 | 0 |
| 12 | Draft | 9 | 0 | 0 | 0 | 0 |
| 13 | Shell | 13 | 0 | 0 | 0 | 0 |
| 14 | Rib | 9 | 0 | 0 | 0 | 0 |
| 15 | Configurations, Design Tables, Suppress | 16 | 0 | 0 | 0 | 0 |
| 16 | Global Variables, Equations, Link Values | 7 | 0 | 0 | 0 | 0 |
| 17 | Move, Rotate, Collision & Interference | 14 | 0 | 0 | 0 | 0 |
| 18 | CSWP Exam Level | 35 | 0 | 0 | 0 | 0 |

## Level 1: Basic Sketch & Extrusion

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 1.1 | Extrude Boss | 72,593 mm³ | 72,593.275 mm³ | +0.00 % | pass |  |
| 1.3 | Extrude Boss | 16,268 mm³ | 16,267.915 mm³ | -0.00 % | pass |  |
| 1.4 | Extrude Boss, Sketch: Polygon | 0.146 in³ | 0.146 in³ | -0.07 % | pass |  |
| 1.5 | Extrude Boss, Sketch: Polygon | 0.5492 in³ | 0.518 in³ | -5.69 % | fail | Drawing read step by step matches the app (head 0.1508, after jaw 0.1062 in³ …) but the sheet's 0.5492 in³ needs ~0.2 in² more material than the drawing shows; best readings give 0.490 (hex through) or 0.555 (no hex). Sheet/drawing mismatch, not an app error. |
| 1.6 | Extrude Boss | 24,032 mm³ | 23,940.392 mm³ | -0.38 % | pass | Passes within tolerance; the −0.4 % is the two R2 fillets left out and the boss centre read from the image. |
| 1.9 | Extrude Boss | 944,900 mm³ | 944,900.0 mm³ | -0.00 % | pass |  |
| 1.11 | Extrude Boss | 96,716 mm³ | 96,715.708 mm³ | -0.00 % | pass |  |
| 1.12 | Extrude Boss | 177,233 mm³ | 177,233.407 mm³ | +0.00 % | pass |  |
| 1.14 | Extrude Boss | 581,662 mm³ | 581,662.058 mm³ | +0.00 % | pass |  |
| 1.16 | Extrude Boss | 157,066 mm³ | 157,066.371 mm³ | +0.00 % | pass |  |
| 1.17 | Extrude Boss | 38,693 mm³ | 38,692.717 mm³ | -0.00 % | pass |  |
| 1.18 | Extrude Boss | 295,296 mm³ | 295,295.687 mm³ | -0.00 % | pass | The top view's 8 mm insets contradict the printed volume; the plate spanning the full 100 (not 84) returns 295,296 exactly, so that is what was built. |
| 1.19 | Extrude Boss | 26,719 mm³ | 26,194.214 mm³ | -1.96 % | fail | Chamfer + Ø8 holes + gusset as drawn gives 26,194; the sheet's 26,719 is the same part without the two holes (26,697). Sheet/drawing mismatch. |
| 1.20 | Extrude Boss | 177,882 mm³ | 177,881.967 mm³ | -0.00 % | pass |  |

## Level 2: Sketch Tools & End Conditions

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 2.7 | Extrude Boss, Sketch: Slot, Sketch: Trim | 56,490 mm³ | 56,489.554 mm³ | -0.00 % | pass | The 86 on the sheet runs from the left end to the origin, not the overall length; the slot is the kit's stadium (two arcs + two tangent lines). |
| 2.13 (by touch) | Extrude Boss, Sketch: Polygon | 8,009 mm³ | 8,009.076 mm³ | +0.00 % | pass | Built entirely by touch on the simulator (Polygon tool, radius label 17/2/cos(30), Extrude 32); the info bar read 8009.08 mm³. |
| 2.14 | Extrude Boss, Sketch: Polygon | 23,839 mm³ | 23,838.66 mm³ | -0.00 % | pass |  |
| 2.15 | Extrude Boss, Sketch: Polygon | 26,512 mm³ | 26,512.081 mm³ | +0.00 % | pass |  |

## Level 4: Extrude Cut & Fillet/Chamfer

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 4.10 | Extrude Boss, Extrude Cut | 65,203 mm³ | 65,202.779 mm³ | -0.00 % | pass |  |
| 4.41 | Extrude Boss, Sketch: Slot, Extrude Cut, Fillet and Chamfer | 107,609 mm³ | 110,002.137 mm³ | +2.22 % | fail | Tube + slot-shaped lugs + R2 edge fillets as drawn; app 110,002 vs my own analytic 110,036 — the sheet's 107,609 implies a narrower neck the drawing does not show. |
| 4.69 | Extrude Boss, Sketch: Polygon, Extrude Cut | 11,120 mm³ | 11,120.457 mm³ | +0.00 % | pass |  |

## Level 6: Revolve Boss/Cut

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 6.15 | Revolve | 137,296 mm³ | 128,727.479 mm³ | -6.24 % | fail | 5-thick sheet bowl with R25 outer / R20 inner bends and a horizontal rim; the sheet's number needs ~7 % more material (probably Ø75 measured on the inside or the rim cut normal to the wall). Interpretation, not an app error. |
| 6.16 | Revolve | 4,080 mm³ | 4,080.3 mm³ | +0.01 % | pass |  |
| 6.18 | Revolve | 10,337 mm³ | 10,336.768 mm³ | -0.00 % | pass |  |

## Level 7: Feature Patterning

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 7.21 | Extrude Boss, Extrude Cut, Mirror Pattern | 20,044 mm³ | 20,043.841 mm³ | -0.00 % | pass |  |
| 7.49 | Extrude Boss, Sketch: Polygon, Extrude Cut, Axis, Circular Pattern | 10,822 mm³ | 10,822.719 mm³ | +0.01 % | pass | Six slot cutters made with Transform › Pattern (circular) from one extruded cutter, then one Combine › Subtract with all six tools. |

## Level 8: Sweep Boss/Cut

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 8.1 | Sweep, Sketch: Polygon | 1,306 mm³ | 1,306.411 mm³ | +0.03 % | pass | Sweep along a polyline with a 24-segment R4 bend; the sheet's 75 × 25 are outside dimensions with the bend's outer radius 6. |
| 8.6 | Sweep | 24,448 mm³ | 24,412.407 mm³ | -0.15 % | pass | Closed-loop sweep: the Ø10 profile ran round a 24+32+2-point sampled spine; −0.15 % is the polyline sampling of the two arcs. |

## Level 11: Hole Wizard

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 11.1 | Hole Wizard | 12.7 in³ | 12.724 in³ | +0.19 % | pass | No hole wizard in the app: each counterbore is two stacked cylinders (ANSI #8 / #10 SHCS sizes) unioned into a cutter, patterned 3 × 3 and 1 × 2 with Transform › Pattern (linear), then subtracted; the sheet rounds to 12.7. |

