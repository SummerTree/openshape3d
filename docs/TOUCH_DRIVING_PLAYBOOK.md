# Building a part BY TOUCH on the iPad simulator — playbook

Written 2026-09-04 while building SOLIDWORKS practice sheets 1.1 and 4.38
entirely through the palette on the iPad Pro 13" simulator (the
`mcp__Claude_Code_iOS_Simulator__control` tool: tap / touch_path /
touch2_path / text). Every coordinate below was verified that day on that
device in portrait. Companion: `docs/AGENT_CONTROL.md` (the bridge you
verify with) and `scripts/swpp/touch_record.py` (how a touch build is scored).

## Coordinates

Tap space is 1032 × 1376 pt. `xcrun simctl io <UDID> screenshot f.png` is
2064 × 2752 px, so **pt = px / 2**. The tool's own screenshot is 1500 × 2000:
pt = px × 0.688. Always pass `udid`.

Palette, body mode: Sketch (46,423) → flyout Line (108,421) Rect (156,421)
Circle (204,421) Arc (252,421) Ellipse (300,421) Polygon (348,421).
Modify (46,485) → flyout row at y ≈ 480 (it follows the palette's vertical
centring, 473–485): Extrude (108) Revolve (156) Sweep (204) Loft (252)
Helix (300) Chamfer (348) Fillet (396) Shell (443) Replace Face (498) Delete
Face (558). Transform (46,550), Combine (46,612), Select (45,860), Delete
(45,927). Toolbar: Undo (427,54), Zoom to Fit (537,54), Views menu (593,54),
History (647,54), Items panel (773,54).

Sketch mode palette: Line (46,277) Rect (46,341) Circle (46,405) Arc
(46,469) Ellipse (46,533) Polygon (46,597) … Delete (45,1087). Header:
Exit Sketching is at (603,118) under "Sketching on plane", (686,118) under
"Sketching on ground plane"; Look at Sketch (539,118) when the camera is
off-axis. Read the header from a screenshot before tapping.

Extrude bar: Distance (218,1273) — tap, type `*0+28` (the field opens with
the old value and the caret at its end; `*0+` makes any prefix vanish), End
menu (294,1273), Symmetric (378,1273); Result row Auto (124,1317) New Body
(205,1317) Union (286,1317) Subtract (367,1317) Intersect (448,1317);
Cancel (866,1273), **Extrude (950,1273)** applies the typed text. Positive
distance = along the sketch plane's normal (a face sketch's normal points
OUT of the body; the origin front plane's is +z).

Blend bar (Fillet/Chamfer): value field (531,1317) — **tap its right edge
(558,1317)** so the caret lands after the old value, type `*0+9`, Apply
(717,1317), Cancel (640,1317). The field applies live since 2026-09-04.

## Aiming

Use the bridge, not pixels: `GET /v1/project?points=x,y,z;x,y,z` returns
the viewport point of any world point in the current camera, so a face tap,
an edge pick (`/v1/edges` midpoints) or a sketch point can be aimed exactly.
Set the camera with `POST /v1/command {"id":"view.front"}` etc. (the same
as the orientation cube), wait 0.8 s, then `view.fit`. `GET /v1/sketches`
dumps every sketch's plane and entities in sketch (u, v) mm — the truth
behind a drawn profile.

## Sketching rules that cost a screenshot each to learn

- Grid snap is a fixed **0.5 mm in the sketch's local frame**; existing
  points, face corners and face edges within 0.35 mm win over the grid.
- Dimension edits grow about the CENTRE, so a dragged rectangle with an
  odd number of half-mm steps ends with corners at .25 positions. Use a
  typed-width rectangle as a SCALE reference, never as a position one.
- A face sketch's plane origin is the face centroid (arbitrary fraction),
  its axes rotated: read `/v1/sketches` and convert. World-exact half-mm
  positions are reachable only to within that fraction (0.02 mm here).
- **Origin plane picker tiles are 2 × 2 mm** at the origin: tapping "the
  grid" picks a plane only when zoomed in near the origin. To re-enter an
  existing plane sketch: arm a sketch tool, `view.front`, tap the blue tile
  (screenshot it), then pinch out. A sketch tool tap on a plane coincident
  with an existing sketch CONTINUES that sketch.
- A hidden (consumed) sketch cannot be tapped for Extrude: show it from
  the Items panel (773,54) → its eye icon.
- Drawing with the Circle/Rect tool: the touch-down point is the anchor.
  Starting a drag ON an existing entity (within the pick tolerance, several
  mm at part zoom) EDITS it instead; a selected entity's gizmo ring (~66 pt
  around it) rotates. Deselect (tap empty), and start new geometry well
  away from existing entities — draw a concentric circle 30 mm off and drag
  it onto the centre by its gizmo handle (the move delta snaps to the grid).
- Line tool: tap the vertices; a tap within 1.2 mm of the start closes the
  loop. Auto-constraints are added and SOLVED per segment.
- Calibrate a screen→sketch mapping from a probe: two Line taps far apart,
  read both snapped endpoints from `/v1/sketches`, delete the probe. The
  snap adds ±0.25 mm per endpoint, so at 5 pt/mm expect ±0.4 % scale —
  good enough for a profile ≤ 100 mm; beyond that, dimension the sketch.

## Scoring

`OS3D_PORT=… python3 scripts/swpp/touch_record.py <id> <sheet volume>
--features "…" --note "…"` reads every visible body's B-rep volume, runs
`/v1/check`, and appends a `mode: touch` row to `scripts/swpp/results.jsonl`
that `report.py` marks "(by touch)".
