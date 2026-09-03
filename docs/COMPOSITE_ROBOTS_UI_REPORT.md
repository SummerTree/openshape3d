# Two TraceParts composite robots, rebuilt through the openshape3d UI

*2026-09-03. Source for the published report page; renders live in the
session scratchpad and the documents on the iPad simulator ("Untitled 20"
ROKAE, "Untitled 21" Lebai).*

## What was asked

Recreate two TraceParts catalogue entries in openshape3d using the app's
UI, and report how well that works:

- **ROKAE (Beijing) Technology, Composite robot CMR-ST600-CR12-C**
  (TraceParts 90-10052023-035374): a differential-drive AGV chassis with
  an xMate CR12 collaborative arm on top.
- **Shanghai Lebai Robotics, LM3 UP Composite Robot** (TraceParts
  27-05704395-097513): a YUNJI UP mobile base carrying the Lebai LM3 arm.

## What the sources give

TraceParts' 3D viewer and STEP download sit behind a sign-in, which this
session cannot perform, so no CAD geometry was available. What is public:

| Item | ROKAE CMR-ST600-CR12-C | Lebai LM3 UP |
|---|---|---|
| Catalogue image | 456 × 340 px, three-quarter view | 460 × 340 px, front view |
| Chassis envelope | **950 × 630 × 768 mm** (TraceParts spec table) | **535 × 450 × 1200 mm** standby (lebai.ltd) |
| Chassis mass / payload | 210 kg / 500 kg | not published |
| Arm | xMate CR12: **1,434 mm reach**, 41 kg (ROKAE datasheet 2026-08) | LM3: **638 mm reach**, 9.5 kg, mount ≈160 cm² |
| Link lengths, joint offsets | not published | not published |

Everything in bold is reproduced exactly. Everything else (link split,
joint diameters, the pose, panel details, tier heights of the Lebai base)
is proportioned from the catalogue image and stated as such below.

## How it was built

Each robot's chassis block was drawn **by touch** on the iPad simulator:
Sketch › Rect drag, the rectangle's width and height typed as dimensions,
Modify › Extrude with a typed symmetric distance, and the History row's
distance field to correct the per-side value. The recipe script
(`scripts/rebuild_composite_robots.py`) then adopts that body by its
bounding box, centres it with Transform › Move, and continues with the
same palette operations through the agent bridge, checking every
primitive's B-rep volume against its analytic value (0.5 %), every union
for growth, and every body with `/v1/check`.

### ROKAE, 58 features, 2 bodies, 0 invalid B-reps

| Step | Palette tools | Result |
|---|---|---|
| Deck (by touch) | Sketch › Rect, Dimension ×2, Extrude, History edit, Transform › Move | 950 × 630 × 230, volume 137,655,000 mm³ exact |
| Deck rounds | Fillet ×2 | R60 verticals (analytic exact), R15 top loop |
| Lidar notches + pucks | Rect, Extrude › Subtract, Circle, Extrude, Union | two 130 mm corner notches, Ø64 × 70 pucks |
| Drive wheels | Circle on the front plane, Extrude, Union | two Ø160 × 50 |
| Cabinet | Rect, Extrude, Fillet, Chamfer | 880 × 560 × 498, R70 corners, 12 mm rim |
| Door seams, e-stop, handles | Rect/Circle on the front face, Extrude › Subtract, Fillet, Union | 4 mm grooves, Ø60/Ø40 e-stop with R6 dome |
| Chassis union | Union | one body, **950 × 630 × 768 exact**, 377,277,044 mm³ |
| Arm base, shoulder, upper arm, elbow, forearm, wrist 1/2, flange | Circle, Extrude, Fillet, Transform › Rotate, Union ×8 | one body, 20,756,895 mm³, elbow-up pose, top at 1,515 mm |

### Lebai, 50 features, 2 bodies, 0 invalid B-reps

| Step | Palette tools | Result |
|---|---|---|
| Lower chassis (by touch) | Sketch › Rect, Dimension ×2, Extrude, Transform › Move | 535 × 450 × 350, volume 84,262,500 mm³ exact |
| Chassis rounds, lidar slot, wheels | Fillet ×2, Rect on the front face, Extrude › Subtract, Circle, Extrude, Union | R80/R40, 300 × 35 slot, two Ø120 × 40 |
| Mid cabinet | Rect, Extrude with 4° draft, Fillet | 460 × 380 × 260 tapering upward |
| Top slab, plinth, e-stop | Rect/Circle, Extrude, Fillet, Union | 420 × 340 × 80, Ø130 plinth, Ø50/Ø32 e-stop |
| Chassis union | Union | one body, **535 × 450 footprint exact**, 752 tall |
| LM3 arm + gripper | Circle, Extrude, Fillet, Transform › Rotate, Rect ×3, Union ×11 | one body, 4,477,049 mm³; standby height 1,173 vs 1,200 (−2.3 %) |

## How faithful the copies are

| Aspect | Verdict |
|---|---|
| Chassis footprints and the ROKAE chassis height | exact to the mm (checked against the datasheet numbers) |
| Arm reach | exact (a2 + a3 + wrist = the published reach) |
| Link split, joint diameters, pose | generic six-axis proportions and a pose read from the image; no public drawing to check against |
| Lebai tier heights, panel details, e-stop and sensor placement | ±10 mm, read from a 460-px image |
| Wheels, castors, cable ports, logos, colours | omitted or simplified; the Material tool exists but was not driven |
| Articulation | none; each robot is two rigid bodies (chassis, arm) in one pose. The app has no assembly joints |

With the STEP files (a TraceParts account is all that is needed), the
app's STEP import would make the comparison exact instead of proportional.

## What the UI could and could not do

Every operation the recipes use is a palette tool: Rect, Circle,
Dimension, Extrude (with draft and symmetric), Fillet, Chamfer, Subtract,
Union, Move, Rotate, and the History panel's inline edits. Five things
were app errors, found by the touch pass and fixed the same day
(`docs/STATUS_AND_NEXT_STEPS.md` gotchas 34–38):

1. A Rect-tool rectangle could not be dimensioned at all. Rect width and
   height are now driving dimensions with their own labels.
2. Every in-place feature (fillet, chamfer, shell, face edits) dropped a
   moved body's placement, so a fillet after Move snapped the body back.
3. The agent's edge and face listings reported local coordinates while
   the body bounds were world; they agree now.
4. The extrude bar's Distance field commits its stale value on a button
   tap and takes no arithmetic; Return is what commits. Documented; the
   field still differs from the dimension and History fields.
5. Zoom to Fit ignores sketches, so a 950 mm rectangle on an empty
   document stays off-screen. Documented, not yet changed.

Not app errors, but worth knowing before posing an arm by hand: the undo
stack holds 50 steps; and OCCT refuses two joint layouts a person will
naturally draw (a link ending on the plane through its housing's axis,
and a link as wide as its housing is long). Starting each link 10 mm past
the axis and keeping housings a few mm larger than their links joins
every time.

## Verification

- Unit suite 1250/1250 green after the fixes (two new regressions:
  `testRectWidthAndHeightDimensionsDriveItsCorners`,
  `testFilletAfterAMoveKeepsThePlacement`).
- Script runs end at `RESULT: ALL PASS` for both robots; `/v1/check`
  reports 0 invalid of 2 bodies in each document.
