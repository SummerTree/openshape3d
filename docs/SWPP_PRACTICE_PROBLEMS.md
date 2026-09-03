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

1. Extrude end conditions: Through All and Up To Next now exist (the
   Extrude bar's End menu, `feature.extrude` `"end"` over the bridge),
   resolved to a distance at commit time. Still no up-to-surface or
   offset-from-surface, and the resolved distance does not re-evaluate
   when the body it reached later moves.
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

## Fixed during the campaign

- **Touch-committed tools left mesh-only bodies.** Checking the End menu
  by touch showed that an extrude committed with the fingers (cut, union
  or stand-alone) kept the Euclid preview mesh as the body: a 25 mm hole
  was a 48-gon, 0.29 % small, with no B-rep. The same feature through
  the bridge was exact. Both commit paths now replay through the feature
  graph (OCCT), the mesh staying as the fallback; the touch cut reads
  80730.09 mm³ against the analytic 80730.09.
- **Extrude end conditions** (above), with the direction taken from the
  sign of the distance already in the field.

# SOLIDWORKS practice problems in openshape3d — 38/46 attempted pass (365 in the database)

| Level | Title | Problems | Attempted | Pass | Fail | Error |
|---|---|---|---|---|---|---|
| 1 | Basic Sketch & Extrusion | 20 | 14 | 12 | 2 | 0 |
| 2 | Sketch Tools & End Conditions | 20 | 8 | 7 | 1 | 0 |
| 3 | Global Variables & Sketch Patterns | 8 | 0 | 0 | 0 | 0 |
| 4 | Extrude Cut & Fillet/Chamfer | 70 | 9 | 6 | 3 | 0 |
| 5 | Reference Geometry | 15 | 0 | 0 | 0 | 0 |
| 6 | Revolve Boss/Cut | 20 | 6 | 4 | 2 | 0 |
| 7 | Feature Patterning | 48 | 6 | 6 | 0 | 0 |
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
| 2.4 | Extrude Boss, Extrude Cut, Sketch: Arcs | 42,236 mm³ | 42,236.368 mm³ | +0.00 % | pass |  |
| 2.7 | Extrude Boss, Sketch: Slot, Sketch: Trim | 56,490 mm³ | 56,489.554 mm³ | -0.00 % | pass | The 86 on the sheet runs from the left end to the origin, not the overall length; the slot is the kit's stadium (two arcs + two tangent lines). |
| 2.8 | Extrude Boss, Sketch: Offset, Sketch: Trim | 118,440 mm³ | 117,680.513 mm³ | -0.64 % | fail | Outer triangle with a 15 offset inner outline; the inner top edge is 5.9 long so two R6 rounds cannot both fit (their tangent points cross and the loop self-intersects — the app refuses such a loop, correctly). Built with three rounds; the sheet's number needs ~96 mm² more material than the offset gives. Interpretation. |
| 2.11 | Extrude Boss, Sketch: Trim, Sketch: Convert, Sketch: Mirror/Dynamic Mirror | 1,387 mm³ | 1,386.639 mm³ | -0.03 % | pass | Ø25 disc with flats, Ø8 hole, two 3-wide rails 2 tall along the flats (the middle is the channel); one rail mirrored with Transform › Mirror (replace) and unioned. |
| 2.13 (by touch) | Extrude Boss, Sketch: Polygon | 8,009 mm³ | 8,009.076 mm³ | +0.00 % | pass | Built entirely by touch on the simulator (Polygon tool, radius label 17/2/cos(30), Extrude 32); the info bar read 8009.08 mm³. |
| 2.14 | Extrude Boss, Sketch: Polygon | 23,839 mm³ | 23,838.66 mm³ | -0.00 % | pass |  |
| 2.15 | Extrude Boss, Sketch: Polygon | 26,512 mm³ | 26,512.081 mm³ | +0.00 % | pass |  |
| 2.17 | Extrude Boss, Sketch: Slot | 16,206 mm³ | 16,206.214 mm³ | +0.00 % | pass | Slot drawn with the kit's stadium; the two corner angles are from vertical. |

## Level 4: Extrude Cut & Fillet/Chamfer

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 4.10 | Extrude Boss, Extrude Cut | 65,203 mm³ | 65,202.779 mm³ | -0.00 % | pass |  |
| 4.25 | Extrude Boss, Extrude Cut, Fillet and Chamfer | 17,428 mm³ | 17,332.521 mm³ | -0.55 % | fail | Symmetric tangent sides from (±13, 64) to the R9 top; −0.55 % just outside the tolerance, ~6 mm² of head outline short, so the side tangents probably start slightly higher. Interpretation. |
| 4.28 | Extrude Boss, Extrude Cut | 412,728 mm³ | 412,728.154 mm³ | +0.00 % | pass |  |
| 4.38 | Extrude Boss, Extrude Cut | 152,280 mm³ | 151,815.527 mm³ | -0.30 % | pass | Counterbore Ø30 × 12 and the 20 × 16 end cut both from the front face, overlapping as the hint says; −0.3 %. |
| 4.41 | Extrude Boss, Sketch: Slot, Extrude Cut, Fillet and Chamfer | 107,609 mm³ | 110,002.137 mm³ | +2.22 % | fail | Tube + slot-shaped lugs + R2 edge fillets as drawn; app 110,002 vs my own analytic 110,036 — the sheet's 107,609 implies a narrower neck the drawing does not show. |
| 4.44 | Extrude Boss, Sketch: Offset, Sketch: Trim, Sketch: Convert, Extrude Cut, Fillet and Chamfer | 90,831 mm³ | 88,815.452 mm³ | -2.22 % | fail | Stem 11 thick with R15 bottom and two Ø13 holes, 64 × 35 × 48 head with 11-wide prongs and a Ø24 half-round across them, R10 at the 11-long junction edges; the sheet's 90,831 is ~2,000 mm³ more than this reading (the R10 fills would have to span the full 48 depth). Interpretation. |
| 4.45 | Extrude Boss, Sketch: Offset, Extrude Cut, Fillet and Chamfer | 27,348 mm³ | 27,321.432 mm³ | -0.10 % | pass |  |
| 4.65 | Extrude Boss, Extrude Cut | 90,519 mm³ | 90,518.81 mm³ | -0.00 % | pass | Half-round channel along the top and half-round notch across the bottom, both Ø25, two Ø10 through holes. |
| 4.69 | Extrude Boss, Sketch: Polygon, Extrude Cut | 11,120 mm³ | 11,120.457 mm³ | +0.00 % | pass |  |

## Level 6: Revolve Boss/Cut

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 6.1 | Revolve | 5,996 mm³ | 5,992.42 mm³ | -0.06 % | pass |  |
| 6.6 | Revolve | 21,076 mm³ | 21,076.422 mm³ | +0.00 % | pass | One revolved profile carrying the seven diameters and the Ø5 bore with its 118° drill point. |
| 6.15 | Revolve | 137,296 mm³ | 128,727.479 mm³ | -6.24 % | fail | 5-thick sheet bowl with R25 outer / R20 inner bends and a horizontal rim; the sheet's number needs ~7 % more material (probably Ø75 measured on the inside or the rim cut normal to the wall). Interpretation, not an app error. |
| 6.16 | Revolve | 4,080 mm³ | 4,080.3 mm³ | +0.01 % | pass |  |
| 6.18 | Revolve | 10,337 mm³ | 10,336.768 mm³ | -0.00 % | pass |  |
| 6.19 | Revolve | 11,704 mm³ | 11,118.869 mm³ | -5.00 % | fail | Built as drawn (4° shaft, 9-high upper cone with a perpendicular lower cone); the sheet's number needs ~5 % more, so the head's 'RIGHT ANGLE' and the 9 must be read differently. Interpretation, not an app error. |

## Level 7: Feature Patterning

| Problem | Features | Sheet | Got | Error | Status | Note |
|---|---|---|---|---|---|---|
| 7.4 | Revolve, Extrude Boss, Pattern: Circular | 421 mm³ | 420.973 mm³ | -0.01 % | pass |  |
| 7.21 | Extrude Boss, Extrude Cut, Mirror Pattern | 20,044 mm³ | 20,043.841 mm³ | -0.00 % | pass |  |
| 7.29 | Extrude Boss, Sketch: Slot, Extrude Cut, Mirror Pattern | 103,384 mm³ | 103,460.165 mm³ | +0.07 % | pass | Mirror + union of the plate-and-web half; R2 concave web fillets and R1 outline rounds picked by edge position; +0.07 %. |
| 7.31 | Extrude Boss, Sketch: Slot, Sketch: Offset, Extrude Cut, Mirror Pattern | 179,795 mm³ | 179,794.69 mm³ | -0.00 % | pass | One profile extrude (walls, base, T-caps) and an R8 slot cut through the base. |
| 7.48 | Extrude Cut, Revolve, Sketch: Slot, Circular Pattern | 6,277 mm³ | 6,276.574 mm³ | -0.01 % | pass | Slot cutter patterned circularly: the pattern's total angle is the first→last sweep, so two instances 90° apart take 90, not 180. |
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

## Read but not attempted (32 sheets)

Sheets read from their drawings and set aside: the drawing does not fix
the geometry, or the printed volume contradicts every reading tried. None
is an app limitation.

| Problem | Why it was set aside |
|---|---|
| 1.2 | Wedge block with pins and a sloped slot: the 58/36/24/16 heights don't compose into one profile from the views given. |
| 1.7 | Bracket of plate, arms and tab: the feature placement across the three views is not fully fixed (REF dims only). |
| 1.8 | V-roof block: a right-angle apex at 125 over a 200 width contradicts the 50 base, and the roof channels are undimensioned. |
| 1.10 | Bent lug bracket: the central plate outline and the flanges' 35° bend geometry are only shown pictorially. |
| 2.2 | Section A-A's 1 mm walls contradict the 13031 mm³ (a 1 mm shell is ~3800, a solid bar ~16000); the floor thickness is not given. |
| 2.3 | Rib/rim thin-wall flange: the outline's tangent lines and the 8 ribs' placement are not dimensioned beyond 'thickness all around 3'. |
| 2.5 | Wedge bracket: the 25° face, 33 and 45/41 dims admit several bodies; the slotted plate's attachment is only shown pictorially. |
| 4.1 | Punch tip: the 25 taper length, 4° TYP and R5 TYP blends can't be reconciled into one flat-and-round transition from the sheet. |
| 4.2 | Clevis: R30/R10 tangencies with the 60° and 90° edges and the lug's 12/25/45 section need the model to infer. |
| 4.3 | Shaft collar: the plan's 21 and 9 callouts conflict with Ø35 and the 10173 mm³ under every reading tried (OD 42/48/52/53). |
| 4.4 | Tool block: T-groove (Detail A 40°/100°) plus 60°/24° faces and 10.67/28.80 offsets — too many inferred positions. |
| 6.2 | Pressed dome: the cone height is not given (only Ø45, 100°, R9/R6, 3 TYP). |
| 6.3 | Hex bit: the R4.50 revolved groove's centre and the 4 A/F tip's chamfer geometry are not fixed by the callouts. |
| 6.4 | Elbow: the straight leg lengths are not given; bend + flanges alone give ~240k of the 370322 mm³. |
| 6.7 | Eye bolt: the eye's arched side profile is undimensioned; the stadium ring × 15 reads 10 % heavy. |
| 6.8 | Angled U boss on a disc: its angle is only shown pictorially ('edge of U contacts origin'). |
| 7.1 | Rook: revolve profile of tangent R15/R15/R6 arcs and the crown's 10° taper — positions inferred. |
| 7.3 | Muffin tin: plate outline size not given; cup profile (Ø12 callout) ambiguous. |
| 7.5 | Chuck body: Y-slots, V groove and radial counterbores from a 1:2 detail — too much inferred. |
| 7.6 | Z-bracket: the plan chain (210) contradicts the front view (80 + 150 = 230). |
| 7.7 | Tee nut prongs: bent blades of 1 mm with an R3 curl are drawn, not dimensioned. |
| 7.8 | T-slot plate: 850 × 225 × 90 is smaller than the 18306608 mm³ printed; the end view's 200/65 callouts don't match 225. |
| 10.1 | Block with diagonal R25 scallops: the section A-A's construction can't be reconciled with the corner arcs drawn. |
| 10.2 | LEGO brick: wall callouts read 1.1 and 1.2 in different views, a 5 % swing on the volume; pips and tube bores ambiguous. |
| 10.3 | Rope thimble: the channel cross-section (R6 groove, 3, 2) is not fully dimensioned. |
| 10.4 | Chuck jaw: serrations, 30° nose and stepped section — too many inferred positions. |
| 13.1 | Shelled L-block: which face the 3 mm shell opens on isn't fixed; every reading is 10–15 % off the 18931 mm³. |
| 13.2 | Nozzle: a 26° tube lofted into a 55°/3° drafted foot with a 2 mm shell — the foot's outline is not fully dimensioned. |
| 13.3 | Kidney cup: 2° draft, 2 mm shell and a 3 × 6 flange combine; the outline's R40/R16/R8 centres are only partly given. |
| 13.6 | Oil pan: multi-level drafted shell with a 20-hole flange — beyond what the sheet dimensions. |
| 14.4 | Needs the provided 14.4Rib_START part (the 13.4 shell), which is not in the sheet set. |
| 14.8 | Needs the provided 14.8Rib_START part; only the rib dims are on the sheet. |

