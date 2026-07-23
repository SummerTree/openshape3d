# Shapr3D Parity Specification

**openshape3d** — feature-for-feature product spec derived from the Shapr3D Help
Center (manual + tutorial corpus, extracted 2026-07-18), with an honest status
audit against the current source tree.

> **Status audit refreshed 2026-07-22.** The original audit was written at v0.5
> (post-Phase C tranche 1) and went stale once Phase D/E/F landed: §4.3
> Chamfer/Fillet, §4.4 Shell, §6.6 Variables, §10.1 History sidebar and §3.1
> Constraint Settings were all still marked ❌ despite shipping (each now has
> unit + UI test coverage). Those five are corrected below. When you add a
> feature, update its Status line here in the same change — a stale audit is
> worse than no audit, because it causes work to be redone.
>
> Ordered roadmap with acceptance criteria: `MODELING_PARITY_GOALS.md`.
> Kernel split (OCCT vs Euclid): `OCCT_BREP_PORT_DESIGN.md`.

## Legend

**Status**

- ✅ **implemented** — behavior exists and matches the spec in substance.
- 🟡 **partial** — a real subset exists; the "missing" note lists the gap.
- ❌ **not implemented** — nothing of the behavior exists in the app.

**Feasibility** (what the feature needs beyond what we have)

- `[mesh-kernel OK]` — achievable with the current Euclid mesh-CSG kernel plus
  app/renderer/UI code. No commercial component required.
- `[needs constraint solver]` — requires a 2D geometric constraint solver
  (Shapr3D uses Siemens D-Cubed; open fallback: planegcs / SolveSpace solver).
- `[needs history engine]` — requires a parametric feature graph with
  re-evaluation (feature tree, dependency tracking, rebuild).
- `[needs B-rep kernel]` — requires exact boundary representation
  (Shapr3D uses Siemens Parasolid; open fallback: OpenCASCADE).
- `[platform/service]` — cloud, account, collaboration, or OS-integration
  work; no geometry involved.

Status verified against: `openshape3d/Kernel/` (`KernelOps`, `ProfileDetector`,
`FaceTopology`, `SketchTypes`, `SketchPlanes`, `MeasureKit`, `SweepLoftKit`,
`SplitKit`, `PatternKit`, `TextSketch`, `ProjectionKit`, `SketchTransform`,
`SketchOffset`, `ExpressionEvaluator`, `STLExporter`,
`STLImporter`, `OBJExporter`, `ThreeMFExporter`, `EuclidBridge`),
`Kernel/ConstraintSolver/` (`Solver`, `Constraints`, `SketchConstraintTypes`,
`SketchSolverBridge`, `LinearAlgebra`), `Editor/`
(`EditorViewModel`, `EditorMode`, `SnapEngine`, `SketchTessellator`), `Model/`
(`Commands`, `DocumentSession`, `UndoStack`, `PersistenceModels`),
`Interaction/` (`HitTester`, `MoveGizmoController`, `ViewportGestureController`,
`PlanePicking`, `SketchHitTester`, `SketchTrimmer`), `Rendering/` (`Renderer`,
`Camera`, `CameraAnimator`, `GizmoRenderer`, `OrientationCube`), `UI/`
(`EditorView`, `ToolPaletteView`, `NumericInputBar`, `ItemsPanelView`,
`SelectionInfoBar`, `SketchConstraintOverlay`, `SketchDimensionOverlay`,
`ProjectGalleryView`).

---

# 1. Sketch menu

Shapr3D top-level structure: sketches are 2D, drawn on a sketch plane or planar
body face; they define profiles for Extrude, Revolve, Loft, Sweep. Closed
sketches are extrudable/revolvable regions; open sketches serve sweeps, guide
rails, and projected curves. Item colors: GREEN = fully defined, BLUE =
under-defined.

**Sketch-entry conventions:** opening or creating a sketch auto-activates the
**Line** tool with a tip banner (documented repeatedly across the corpus).
Sketch tools are STICKY — they stay active after each placement; drop the
active tool via Escape or right-click, re-enter it via its hotkey.

### 1.1 Line

**Spec:** Desktop: click to add an endpoint, drag, click the next endpoint;
click-chains build a connected polyline by default. Escape cancels/exits the
active endpoint; Backspace removes the last-placed point (finishing the
chain once none remain); Enter sets the final endpoint and finishes. Auto-finish when
the last endpoint closes onto the initial endpoint. Right-click stops the
current chain; a second right-click drops the tool. Typing a number + Enter
mid-draw assigns a locked length dimension to the segment. Touch/pen: draw like
on paper, lift the pen to finish; start from a previous endpoint to chain.
Snapping to an axis while placing creates a Coincident constraint to that
axis — this drawing-time auto-constraint is the ONLY way to tie geometry to
the axes, because the origin/axes cannot be referenced by dimensions or
constraints afterwards (see §2.2's origin/axis restriction).
History params per sketch step: Plane (Edit…/Select…), Projection.
**Status:** 🟡 partial — drag-defined segments with chain continuation: after
a stroke, the next stroke starting on the previous endpoint pre-anchors there
(`chainAnchor`), and a stroke that closes onto the chain's first point
finishes the chain (`EditorViewModel.beginSketchStroke/endSketchStroke`,
`SketchEntity.line`), with endpoint/midpoint + grid snap (`SnapEngine`).
Missing: tap-tap polyline chaining, Escape/Enter semantics, numeric length
entry mid-draw, auto-constraints, dimension labels.
**Feasibility:** core [mesh-kernel OK]; locked dimensions [needs constraint solver]

### 1.2 Line/Arc — Automatic mode (pen)

**Spec:** Pen-only. Starting to draw on a defined sketch plane auto-enters
sketch mode and auto-detects whether a stroke is a line or an arc; WIGGLE the
pen mid-stroke to switch between arc and line. Override via the "Line Type"
menu below Line/Arc: Automatic (default) | Line | Arc.
**Status:** 🟡 partial — `StrokeClassifier` implements the detection and the
`LineType` (Automatic | Line | Arc) override. Automatic reads a stroke as an
arc only when it bows past 2% of its chord AND a Kåsa circle fit explains the
samples clearly better than the straight chord does, so ordinary hand tremor
and a 3°-of-a-huge-circle stroke both stay lines. Fitted arcs recover the
drawn radius and centre and are stored CCW, so a clockwise stroke becomes the
same arc walked the other way rather than a 270° one. **Wiggling mid-stroke
toggles the result** (spec §1.2): the scribble is detected from repeated
sharp direction reversals over segments short relative to the stroke, its own
samples are excluded from the fit so the geometry is not dragged with it, and
a straight stroke toggled to an arc gets a visible tenth-of-chord default bow
(there is no fitted curvature to use) that the §1.3 bulge drag can then
adjust. Both thresholds are relative to the chord, so classification does not
change with zoom. The Pencil-exclusion fix stands
(`ViewportGestureController.attach` accepts `.pencil`). Covered by
`StrokeClassifierTests`. **Missing:** the Line Type menu UI and wiring the
classifier into the live stroke preview.
**Feasibility:** [mesh-kernel OK] — confirmed, this is all app code.

### 1.3 Arc

**Spec:** Desktop: click-drag two endpoints, drag to adjust bulge, click to
finalize; Escape finishes; "Exit Sketching" leaves sketch mode. Touch: Line/Arc
with Line Type = Arc, draw with pen, complete by tapping outside the sketch.
Hotkey A. Arc angle can be dimensioned (e.g. 90° = quarter arc); radius
dimensionable.
**Status:** 🟡 partial — touch-first arc: drag places the chord endpoints,
then a drag on the pending arc adjusts the bulge; committed on the next tool
action / tap elsewhere (`SketchEntity.arc`, `EditorViewModel.PendingArc`).
Arcs tessellate into profiles whose endpoints chain with lines
(`SketchTessellator`, `ProfileDetector`); arc endpoints/centers are snap
points. Missing: desktop click-click-drag-click flow, angle/radius
dimensions, hotkey.
**Feasibility:** [mesh-kernel OK]

### 1.4 Spline (Fit / Control)

**Spec:** Two types, chosen under Sketch > Spline. **Fit Point**: curve passes
through each marked point; draw segment then click to add pass-through points;
Escape/Backspace finishes; move points by dragging after exiting; per-point
tangent handles adjust curvature; add point via right-click > "New Spline
Point" (desktop) or long-tap on curve (touch); remove via select + Delete.
**Control Point**: points are vertices of a guiding control polygon; drag the
control points, not the curve. Break/Join badge on a selected spline point
breaks or joins splines there. Spline points can be toggled sharp/smooth;
collinear control points produce tangency (1 collinear point = G1, 2 = G2).
Hotkey I. Splines never have midpoints or center points. Segment-insertion
workflow: make an existing spline point sharp, Disconnect it, drag open a
gap, draw the new segment into the gap, then re-smooth the junction points.
**Status:** 🟡 partial — the **fit spline** ships as a first-class
`SketchEntity.spline(points:closed:)`, integrated across the whole sketch
pipeline: centripetal Catmull–Rom tessellation (interpolates every control
point; will not cusp on unevenly-spaced input), rendering, hit-testing,
snapping to fit points, translate/rotate/scale, mirror, pattern, symbols,
length measurement, DXF export (as a POLYLINE — the R12 subset has no SPLINE
entity), profile chaining through an open spline's ends, and **use as a sweep
spine** (§4.11). Open splines expose their endpoints to the solver and
auto-constrainer so they weld to neighbouring geometry. Covered by
`SplineTests`.
**Missing:** the DRAWING tool + UI (placing/dragging fit points, the
Fit/Control mode switch), control-point (non-interpolating) splines, interior
points as solver variables, tangent constraints at the ends, and spline trim/
offset (both would have to re-fit the curve).
**Feasibility:** drawing/editing [mesh-kernel OK]; tangent constraints
[needs constraint solver]

### 1.5 Rectangle (Center / Diagonal / Three-point)

**Spec:** Type menu below "Rectangle". **Center**: first point is center AND
anchor (anchor marked with an X); drag outward. **Diagonal**: two opposite
corners, drag the diagonal from the anchor. **Three-point**: baseline first
(click, move, click), then height perpendicular to it; remaining sides
auto-created. Hotkey R. Numeric entry before placing fixes dimensions.
**Status:** 🟡 partial — Diagonal only, as a drag from corner to corner
(`SketchEntity.rect(min:max:)` — axis-aligned only). Trimming a rect now
explodes it into its four lines first (`SketchTrimmer`), so sides become
individually editable after a trim. Missing: Center and Three-point types,
anchor-point X-mark, rotated rectangles, numeric entry.
**Feasibility:** [mesh-kernel OK]

### 1.6 Circle

**Spec:** Click center, click diameter (desktop) or drag from center (touch).
Typing a value before placing the second point sets the dimension exactly.
Label shows RADIUS or DIAMETER per the "Circular Annotations" setting. Hotkey C.
**Status:** 🟡 partial — center + drag-radius implemented
(`SketchEntity.circle`); center is a snap point. Missing: numeric entry while
drawing, dimension label on selection, Circular Annotations setting.
**Feasibility:** [mesh-kernel OK]

### 1.7 Ellipse

**Spec:** Click to place center/point, draw first axis, click to fix its
diameter, move perpendicular for the second axis, click to finish. Numeric
major/minor entry supported. Major and minor radii dimensionable.
**Status:** 🟡 partial — drag-drawn ellipse entity (center + two radii +
rotation, `SketchEntity.ellipse`), tessellated into closed profiles;
center is a snap point. Missing: two-axis click flow, numeric major/minor
entry, dimensions.
**Feasibility:** [mesh-kernel OK]

### 1.8 Polygon

**Spec:** Closed profile with N EQUAL sides; type menu offers Triangle,
Pentagon, Hexagon, Octagon. Click center, move to define radius, click outer
vertex. Numeric radius before placing. After placement two labels appear:
sides-count and radius — the sides label is only available immediately after
creation (disappears once anything else is selected). Hotkey G.
**Status:** 🟡 partial — center + drag-radius regular N-gon
(`SketchEntity.polygon`); the side count is set in the numeric bar
(`polygonSides`, default 6); vertices are snap points; closed profiles
detected. Missing: type menu (Triangle/Pentagon/Hexagon/Octagon), numeric
radius before placing, post-creation sides/radius labels.
**Feasibility:** [mesh-kernel OK]

### 1.9 Offset Edge (sketch mode)

**Spec:** Creates sketch elements offset from existing elements by a distance.
Type menu: Single (one edge) | Chain (connected chain/loop). Select element,
use gizmo to set offset direction + distance. If the selected item is shared by
multiple loops, an arrow shows per loop — pick the arrow of the loop to offset.
Finish with "Exit Sketching". Hotkey O. Used constantly in tutorials for wall
thickness (e.g. offset outer edge 1 mm and cut).
**Status:** 🟡 partial — kernel only: `SketchOffset` offsets closed
primitives (circle/arc/rect/polygon) and connected line chains/loops with
degenerate-collapse cleanup, unit-tested; no palette tool, gizmo, or
loop-arrow disambiguation UI yet.
**Feasibility:** [mesh-kernel OK] (polyline/arc offsetting is 2D geometry)

### 1.10 Move/Rotate (sketch mode)

**Spec:** Moves/rotates sketch elements with the gizmo (arrows + center tiles,
dimension labels for precise movement). Double-click/double-tap selects a whole
connected group. Copy badge (turns BLUE when active) moves/rotates a duplicate.
Complete by selecting empty grid area. Direct manipulation without the tool:
elements/edges/points can simply be dragged. With the default view, dragging
the gizmo center tiles moves a sketch along/between planes.
**Status:** 🟡 partial — direct manipulation (drag edits an entity, control
points win, one coalesced `UpdateSketchEntityCommand` per drag) PLUS the
selection gizmo: a move handle + rotate ring at the selection centroid
(`sketchGizmoSegments`, `beginSketchGizmoDrag`, `SketchTransform`), a Copy
chip that turns blue and drags duplicates (`sketchCopyOnDrag`), and
double-tap selecting the connected chain via endpoint adjacency
(`ProfileDetector.connectedEntityIDs`). Missing: dimension labels on the
gizmo, between-plane moves via center tiles.
**Feasibility:** [mesh-kernel OK]; copy-that-loses-constraints details
[needs constraint solver]

### 1.11 Pattern (sketch — Linear / Circular)

**Spec:** Evenly-spaced copies of selected sketch elements. **Linear**: drag a
gizmo arrow for direction 1 (live preview of last + intermediate copies);
badges: Pattern Definition = Total distance (center-to-center first→last) |
Spacing distance (adjacent centers), Quantity; second arrow makes a 2-axis
grid, each direction with signed distance and its own quantity. **Circular**:
draggable center point (snaps to geometry centers, repositionable anytime);
drag rotation arrow — a thick half-arc + signed numeric readout visualizes the
total angle, snapping to 360° near full turn; badges: Total angle | Spacing
angle, Quantity, Orientation = Uniform (copies keep orientation) | Rotated
(rotate about center; type NOT changeable after creation). A pattern icon at
the center point (or hover any instance) re-opens editing. Instances cannot be
individually deleted while the pattern constraint exists; selecting the pattern
icon and pressing Delete "applies" the pattern, making instances unique.
Dimension fields and Quantity accept variables and expressions. Auto-creates a
sketch pattern constraint linking all instances. Interaction edge cases:
dragging ANY instance point moves the whole pattern; snapping the first
instance's center to the origin or construction geometry adds a Coincident
constraint and — once a dimension is added — turns the pattern GREEN with
pattern-rotation as the sole remaining DOF (lockable via an angled
construction line). Documented failure mode: constraining the LAST copy
breaks the pattern when Quantity shrinks below it — constrain the first copy
instead.
**Status:** 🟡 partial — static copies: with a profile armed for extrude,
the palette Pattern patterns the profile's entities in-plane — Linear
(X/Y direction + spacing) or Circular about the sketch origin (total
angle, rotated instances) — with accent-blue ghost previews and one
CompositeCommand of `AddSketchEntityCommand`s (`PatternKit`,
`commitSketchPattern`). Missing: gizmo-driven direction/center dragging,
Total-distance definition, 2-axis grids, the live pattern constraint,
re-editing, variables.
**Feasibility:** static copies [mesh-kernel OK]; live pattern constraint &
re-editing [needs constraint solver] + [needs history engine]

### 1.12 Text

**Spec:** Adds text as sketch PROFILES on a default plane, planar face, or
construction plane. Entry: Sketch > Text (view normal to plane), or pre-select
face/plane then "Add Text" in the adaptive menu. Dialog: Content, Font
(all fonts installed on the device), Height, Alignment → Continue → position
with gizmo → Done. After Continue the POSITION stays fully editable — drag,
X/Y pad values, rotation, and a relocatable reference point for precise
placement — while the string and size are immutable. After completion text is
editable only as sketch elements.
Fonts with discontinuous sections may need cleanup before solid use.
**Status:** 🟡 partial — Text in the sketch palette: tap a baseline point on
the active sketch plane → dialog (Content, Height, curated Font list) →
glyph outlines land as polygon/line sketch entities in one undo step
(`TextSketch` via Core Text, `commitText`); the resulting closed loops fill
and extrude like any profile. Missing: alignment option, the full
installed-font list, post-Continue gizmo repositioning (position is fixed
at the tapped point), pre-selected face entry.
**Feasibility:** [mesh-kernel OK] (Core Text glyph outlines → sketch profiles)

### 1.13 Project — Sketches (sketch mode; also Tools > Project)

**Spec:** Projects sketches, edges, faces, or entire bodies onto another face
or sketch plane. Projection Type: Edges (new body edges) | Sketches (new sketch
items). Selection flow: pick items to project (blue badges; tap badge to
change/cancel) → pick target surface (PURPLE, live preview) → Done. Sketch
projections have a "Linked sketch" option: linked previews in MAGENTA and
auto-updates with the source; unlinked is a static editable copy. Planar
targets accept edge and sketch projections; non-planar targets accept edge
projections only. Edge projections split the target surface into regions and
follow the source parametrically. A sketch positioned mid-body projects both
ways (forward + backward vectors) and slices through both sides. Merge
mechanics: re-running Project with a new selection and the SAME target
appends the items into the existing projection sketch; if no target is
assigned yet, the next clicked candidate face/plane is auto-assigned as the
target; individual projected edges can be deleted from the resulting sketch.
Drag-and-drop shortcut: select a sketch region and drag-drop it onto a
displayed construction plane to project that region's outline onto the plane.
Projected sketch entities render PURPLE/VIOLET and are LOCKED in place
(cannot be dragged); projections from a hidden source sketch stay live.
Hotkey P.
**Status:** 🟡 partial — the unlinked CNC-flat-layout core: Project in the
sketch palette, then tap a visible body — its feature edges flatten onto
the active sketch plane as regular, editable line entities in one undo
step (`ProjectionKit.project`, `projectTappedBody`); re-running on the
same sketch appends, and projected entities delete like any others.
Missing: sketch/edge-selection sources, silhouette outlines, linked
(magenta, auto-updating) projections, purple/locked rendering, non-planar
targets, drag-and-drop shortcut.
**Feasibility:** unlinked planar sketch projection [mesh-kernel OK]; linked
projections [needs history engine]; edge projections that split faces
[needs B-rep kernel]

### 1.14 Trim

**Spec:** Removes sketch segments between two intersections or within a
boundary. In a sketch: Sketch > Trim, tap/click each unwanted segment — it is
removed immediately. Complete by tapping empty grid area or Escape. Hotkey T.
Supports the "overbuild then trim" workflow (draw lines past intersections,
trim the excess).
**Status:** ✅ implemented — Trim tool in the sketch palette: tapping an
entity removes the span between its nearest intersections with the other
entities (lines split exactly, arcs/circles by angle, circles trim to arcs,
rects explode into lines, uncrossed entities are removed whole); one
undoable `TrimCommand` per tap (`SketchTrimmer`, `performTrim`). The
"overbuild then trim" workflow works. Keyboard (hotkey T / Escape) rides the
app-wide §8.4 gap.
**Feasibility:** [mesh-kernel OK]

### 1.15 Delete (sketch)

**Spec:** Select sketch element(s) within a sketch, then Delete. Finish with
Escape or "Exit sketching".
**Status:** ✅ implemented — tap toggles entity selection while sketching;
the palette Delete removes the selection as one undoable
`RemoveSketchEntitiesCommand`; "Exit Sketching" finishes. (Escape rides the
§8.4 keyboard gap.)
**Feasibility:** [mesh-kernel OK]

### 1.16 Symbol

**Spec:** A special sketch object: a collection of sketch elements holding
their relative shape, placed and reused as a unit.
**Status:** 🟡 partial — palette "Symbol" captures the selected sketch
entities as a named symbol (name prompt; entities are normalized about the
group centroid, `SymbolKit.capture`), and "Insert" lists the document's
symbols — choosing one arms tap-to-place, each tap stamping one transformed
instance into the sketch as a single undoable command
(`SymbolKit.instantiate` → `AddSketchEntitiesCommand`). Symbols persist and
list/rename/delete in the
Items Manager. Missing: rotate/scale during placement, editing a symbol
definition after capture, rigid instances under constraint edits (no
solver).
**Feasibility:** [mesh-kernel OK] (grouping/instancing is app code); keeping
instances rigid under constraint edits [needs constraint solver]

### 1.17 Helix

**Spec:** Listed among the sketch primitives (Line, Arc, Circle, Ellipse,
Polygon, Rectangle, Spline, Helix): a helical 3D curve, usable e.g. as a
Sweep path. (Helical SOLIDS come from Revolve's Elevation param, §4.10.)
**Status:** 🟡 partial — not a sketch entity, but the primary use case
works: "Helix" in the extrude bar sweeps the armed profile along a
generated helical spine (radius/pitch/turns dialog, coiling up the
sketch-plane normal from the profile centroid; `HelixKit.path`,
`commitHelixSweep`). Missing: a persistent helix curve entity reusable as
a generic sweep path.
**Feasibility:** [mesh-kernel OK] (tessellated helix polyline)

---

# 2. Sketch controls

### 2.1 Sketch states & degrees of freedom

**Spec:** Each sketch item has exactly three DOF: rotation, horizontal,
vertical movement. Fully-defined = GREEN (zero DOF; changes only when a
constraint/dimension is edited); under-defined = BLUE (≥1 DOF). Point states:
fully-defined point GREEN (anchor), under-defined BLUE. Connected points take
the color of the connected item with the GREATER freedom. Connected-point
kinds: Coincident (point rides a line/curve or its extension), Midpoint (stays
at line center as length changes), point-to-point (move together). Dragging
geometry is the DOF test: a fully constrained sketch does not move when
dragged. Points that are connected render with a FILLED CENTER; locked points
render SOLID BLUE.
**Status:** 🟡 partial (Phase C tranche 1) — the solver derives the sketch's
degrees of freedom from the null space of the numeric constraint Jacobian
(`SketchSolverBridge.entityStates` / the `dof` returned by `solve`), and the
sketch pill shows a state chip: **green "Fully defined"** at 0 DOF, **blue
"Under-defined — N DOF"** otherwise (`SketchStateChip`). Dragging IS the DOF
test — a fully-constrained sketch springs back (drag routed through the solver,
`updateSolvedSketchEntityDrag`), and under-defined geometry follows the drag
live. Missing: the per-POINT color states (filled-center connected points,
solid-blue locked points) — state is currently surfaced at the sketch level,
not per point.
**Feasibility:** [needs constraint solver] — solver shipped.

### 2.2 Editing sketch dimensions

**Spec:** Every sketch element has a dimension label. Click item → click label
→ type (or click again for numpad). Simple math accepted in the field
(12+34, 50/2). Touch: tap label → numpad/calculator → check mark. Types:
length, diameter, radius, angle. Length Distance Type badge next to the label:
Absolute | Horizontal | Vertical projection. Diameter needs Circular
Annotation = "Radius and Diameter"; radius applies to circles/arcs/ellipses
(major/minor). PAIRWISE dimensions: select TWO sketch elements/points/edges
and add a linear distance dimension between them (canonical uses:
line-to-centerline distance, edge-to-edge and point-to-point gaps). Angle
between any two lines/arcs/splines (connected or not): select both, enter
value. Label mechanics: the dimension TEXT position is draggable and Enter
pins it; double-clicking a line reopens its dimension input; trimming a full
circle to an arc auto-converts its diameter dimension to a radius dimension.
Secondary point rule: when dimensioning between two points, the
SECOND-selected point is the one that moves (this rule operates beyond the
Anchored Sketch Entity setting). Origin/axis restriction: dimensions and
constraints CANNOT reference the sketch origin or the grid axes as operands —
the documented workaround is a LOCKED construction-line crosshair drawn over
the origin, which then serves as the reference (Layout sketch technique).
Fully-defined dimensions stay visible/editable
outside sketch mode when visibility is on. The solver refuses a dimension on an
already fully-solved region.
**Status:** 🟡 partial (Phase C tranche 1) — **driving dimensions** exist for
length, radius, diameter, and angle. Selecting geometry surfaces an editable
candidate label in the sketch overlay (`SketchDimensionOverlay`); tapping opens
an inline numeric field that accepts **inline arithmetic** (`25.4/2`, via
`ExpressionEvaluator`) and, on commit, sets the driving value and re-solves so
the geometry is driven to it (verified end-to-end by `DimensionUITests`).
Pairwise point-to-point and point-to-line distances are supported, as is angle
between two lines. Dimensions list under **Constraints** in the Items panel and
Delete removes them (undoable). The **solver refuses** a value that
over-constrains / conflicts with the existing dimensions (residual-norm check,
non-blocking message — not applied). Missing: the Distance-Type badge
(absolute/horizontal/vertical projection), diameter Circular-Annotation
setting, draggable dimension-TEXT position, double-click-to-reopen, the
diameter→radius auto-convert on trim, the secondary-point move rule, the
origin/axis operand restriction + locked-crosshair workaround, and visibility
outside sketch mode. (Tool-parameter numeric editing — extrude distance,
revolve angle, offset-plane distance, axis moves, scale factor, polygon sides,
legacy primitive W/D/H — remains as before; see §18.)
**Feasibility:** [needs constraint solver] — solver shipped (label UI is app code)

### 2.3 Using sketch planes

**Spec:** A sketch plane must be defined before sketching. Ways in: select
Sketch → THREE plane rectangles appear at the origin (XY/XZ/YZ; grid
auto-follows the hovered plane; clicking rotates the camera orthographic
head-on); tap/double-tap a planar face or construction plane; hover + Space
bar with a tool active; via Orientation Cube or Views. Snap references when a
body intersects the sketch plane: face center, edge midpoint, edge endpoint,
and MAGENTA cross-sketch intersection points. Starting a line from a
body/plane intersection point automatically creates a coincidence to those
elements, so the sketch FOLLOWS body changes — e.g. editing a Shell thickness
moves the sketch with it ("Sketch with design history"). "Normal to Sketch" button
restores the head-on view after orbiting mid-sketch. Each sketch is an item in
the Items Manager and a step in History; continuing on the same plane
immediately after edits the same sketch item, otherwise a new item is created.
**Status:** 🟡 partial — the plane-definition mechanisms exist: selecting a
sketch tool with no plane shows the THREE world-plane tiles at the origin
("Choose a sketch plane", `PlanePicking.worldTiles` rendered by
`GizmoRenderer`); tapping a tile, a planar body face, a construction plane,
or the bare ground starts the sketch there with a head-on camera animation
(`handlePlanePick`, `moveCameraHeadOn` for arbitrary planes); a selected
face also offers "Sketch" directly (`startSketch` reads the face plane).
Same-plane sketches are reused as one sketch item (Shapr3D's rule), and
re-opening an auto-hidden sketch makes it visible again (`beginSketch`).
Missing: hover grid-follow, Space-bar entry, body-intersection snap points
and the associative intersection coincidence, Normal to Sketch button.
**Feasibility:** [mesh-kernel OK]

### 2.4 Changing a sketch plane / moving sketches

**Spec:** In sketch mode, Move/Rotate lets you drag the gizmo center tiles to
translate a sketch along/between planes (set default view first via
double-tapping the Orientation Cube). Selecting a sketch outside sketch mode
shows the transform gizmo auto-aligned to the sketch's orientation; the Copy
toggle produces sketch copies.
**Status:** 🟡 partial — a sketch can be RE-HOSTED on another plane:
`ChangeSketchPlaneCommand` + `EditorViewModel.changeSketchPlane(of:to:)`
(one undo step) with `availableSketchPlanes(for:)` listing the ground plane
plus every construction plane, excluding the current one. Entity coordinates
are plane-local so the drawing keeps its shape and simply lands on the new
plane, and dependent features rebuild — an extrude follows the sketch.
Covered by `ChangeSketchPlaneTests`.
**Missing:** the UI entry point for it, sketches being selectable as objects
outside sketch mode, the auto-aligned transform gizmo, dragging a sketch
between planes, and the Copy toggle.
**Feasibility:** [mesh-kernel OK]

### 2.5 Sketch pattern constraint

**Spec:** Auto-created by the Pattern tool (never manually). Edits to one
instance propagate to all. Re-select any member sketch to re-activate the
pattern badges and adjust definition/distance/quantity. Delete via the badge +
"Delete Constraints": permanently breaks the link, instances become individual.
**Status:** 🟡 partial — the pattern LINK ships (`SketchPatternLink` on the
sketch + `SketchPatternKit`): instances stay slaved to their seed, so editing
the seed (position, radius, …) regenerates every copy, and instance IDs are
preserved so selections/references survive. Any member resolves back to its
link (`link(owning:)`), which is what re-activates the pattern on re-select.
`unlink` implements "Delete Constraints" — the copies remain as individual
entities and simply stop following. Links persist, and pre-§2.5 documents
still load. Covered by `SketchPatternLinkTests`.
**Missing:** the badge UI for adjusting definition/distance/quantity, and
wiring the Pattern tool to create the link automatically (it still emits
unlinked copies).
**Feasibility:** [mesh-kernel OK] — regeneration is deterministic, so this did
NOT need the solver.

### 2.6 Snapping options & guides

**Spec:** Snaps/Guides popover toggles: Grid; Sketch Guidelines (VIOLET
extension lines — horizontal, vertical, along a previous line, perpendicular
to it, and also Equal, Symmetric, Tangent, and Parallel relations; guideline
intersections snappable; drawing along a guide auto-adds the
matching constraint); Sketch Guidepoints (endpoints, midpoints, arc centers,
profile centers); 3D Guidepoints (body vertices, edges, edge midpoints, face
centers, hole centers); Distant Edges (out-of-plane reference geometry
projected into the sketch plane in orthogonal views). Guideline memory:
dragging a point over an element "memorizes" it and projects its guide;
releasing on the guide creates a Coincident constraint to the element's
(possibly extended) path — hovering later shows a DASHED VIOLET guide. Hovering
an arc yields a curved guideline (its full circle). Show settings: guide-point
visibility and Snapping Hints (text next to pointer, e.g. "endpoint",
"midpoint", "sketch center"). Snap points are suggestions only.
**Status:** 🟡 partial — `SnapEngine` snaps to sketch endpoints, line
midpoints, rect corners, circle/ellipse/arc centers, arc endpoints, and
polygon vertices (0.35 tolerance), then to a fixed 0.5 grid. Missing:
guidelines, entity–entity intersection points, 3D guide points, distant
edges, hints UI, enable/disable toggles, dynamic grid resolution.
**Feasibility:** snapping [mesh-kernel OK]; guide-created constraints
[needs constraint solver]

### 2.7 Notable points

**Spec:** Endpoints (linear/arc/spline elements and body edges; faces inherit
their bounding edges' points), midpoints (linear elements/edges), center points
(arcs, circular edges, rectangular faces, cylindrical/conical faces),
intersection points (two linear elements). Splines never have midpoints or
center points. Used for measurement, constraints, alignment; visibility via
Snap To settings.
**Status:** 🟡 partial — endpoints, line midpoints, rect corners, arc
endpoints, circle/ellipse/arc centers, and polygon vertices in sketch space
(`SnapEngine.snapPoints`); Measure's point-to-point mode also offers body
vertices. Missing: intersection points, face/edge-derived points as general
snap targets.
**Feasibility:** [mesh-kernel OK]

---

# 3. Constraints menu

**Menu behavior spec:** The constraints menu sits opposite the Sketch menu,
auto-opens in sketch mode, and adapts — only constraints valid for the current
selection are enabled. Apply: pick plane → select element(s) → pick constraint.
Every constraint has a Shift+letter shortcut shown beside its name when a
keyboard is attached. Drag-and-drop creation: point onto point = connected;
point onto line/curve = Coincident; point onto a line's midpoint (midpoint
shown PURPLE) = Midpoint. Constraint icons render in the modeling space
(governed by Constraint Settings); selecting an icon lets you delete it;
selecting an element highlights its constraints and vice versa.

**Status (menu + all constraint types):** 🟡 partial (Phase C tranche 1) — a
pure-Swift `ConstraintSolver` (Levenberg–Marquardt, numeric Jacobian) backs an
adaptive **Constrain** menu that enables only the constraints valid for the
current selection (`canApplyConstraint`) and applies each relation plus any
solver-moved geometry as ONE undoable step (`applyConstraint`). Applied
constraints render as tap-selectable on-canvas glyphs and list under
**Constraints** in the Items panel (Delete removes either, undoable, re-solves).
An over-constraining pick is refused with a non-blocking message rather than
corrupting the sketch. Missing (menu-level): the auto-open behavior, Shift+letter
shortcuts, drag-and-drop creation, the PURPLE midpoint hint, and the
element↔constraint highlight linking. Per-constraint status in §3.2.
**Feasibility:** [needs constraint solver] — solver shipped; the remaining
menu-behavior gaps are app code.

### 3.1 Constraint Settings

**Spec:** In the constraints menu: **Auto-constraining** toggle (OFF: only
connected endpoints/midpoints auto-created; ON: additionally Horizontal/
Vertical, Perpendicular, Tangent on arcs at endpoints, Coincident while
drawing). **Always Show Constraints** (icons for selected elements of the
active sketch), **Always Show Dimensions** (all locked dimensions shown).
**Anchored Sketch Entity**: First Selected | Last Selected — which entity stays
fixed when a constraint is applied (existing constraints override).
**Status:** 🟡 partial (Phase C). `ConstraintSettingsView` ships a constraint
settings surface, and the solver honours the auto-constrain toggles.
**Missing:** the full per-constraint-type enable/disable matrix Shapr3D
exposes. **Feasibility:** [mesh-kernel OK] (solver already ships)

### 3.2 The constraint set

Each: select the listed operands on the same plane → pick the constraint.

| Constraint | Operands & behavior | Shortcut | Status |
|---|---|---|---|
| Parallel | 2+ lines; constant direction | Shift+A | 🟡 |
| Perpendicular | 2 lines, 90°; need not touch — guide curves shown when apart | Shift+P | 🟡 |
| Tangent | line+curve or curve+curve; single-point touch; guide curves when separated | Shift+T | 🟡 |
| Coincident | endpoint + endpoint/line/curve/edge; also by dragging; filled-center point rendering | Shift+N | 🟡 |
| Midpoint | endpoint + line center, tracks length changes; drag onto purple midpoint | Shift+M | 🟡 |
| Concentric | arcs/circles share center | Shift+C | ✅ |
| Horizontal/Vertical | line(s) align to sketch axes (each line goes to the NEAREST axis) — or TWO POINTS, aligning the pair horizontally/vertically; auto-created when auto-constraining is on | Shift+V | 🟡 |
| Equal | equal length (lines) / equal radius (arcs, circles) | Shift+E | ✅ |
| Symmetry | two similar elements mirrored; then select a line or edge as the axis | Shift+S | 🟡 |
| Disconnect | breaks connected points; deletes Coincident/Midpoint on the point | — | ❌ |
| Lock/Unlock | fixes an element/point in place; locked points render solid blue | Shift+L | 🟡 |

**Status:** 🟡 implemented (Phase C tranche 1) — the pure-Swift
`ConstraintSolver` (Levenberg–Marquardt, numeric Jacobian) lowers each of the
above (except Disconnect) from an **adaptive Constrain menu** that
enables/disables entries per selection (`canApplyConstraint`), applying the
relation + any solver-moved geometry as ONE undoable step
(`EditorViewModel.applyConstraint`). Coincident welds endpoints (point-to-point
or nearest-corner of two lines); Horizontal/Vertical accept a line OR a point
pair; Lock pins points via the solver's fixed set. Applied constraints render
as **on-canvas glyphs** (tap-selects, Delete removes — undoable, re-solves) and
list under **Constraints** in the Items panel. An over-constraining pick is
**refused** with a non-blocking message (residual-norm conflict check) rather
than corrupting the sketch. Missing: Shift+letter shortcuts, drag-to-create
coincident/midpoint, the violet guide curves for separated operands, the
filled-center / solid-blue POINT rendering (see §2.1), auto-constrain, and
Disconnect.
**Feasibility:** [needs constraint solver] — solver shipped.

### 3.3 Make Construction / Make Regular

**Spec:** Converts sketch elements to construction (reference) geometry,
rendered DASHED; excluded from closed-profile fill/region detection. Uses:
revolve axis, symmetry axis, alignment scaffolding, references. Reverse via
"Make Regular". Construction geometry survives only the native format — X_T/
STEP/IGES exports skip all sketch elements. Bulk toggle of many lines at once.
**Status:** ✅ implemented — palette "Construct" bulk-toggles the selected
sketch entities (mixed/regular → all construction, all-construction → all
regular; one undoable `SetConstructionCommand`); construction entities
render dashed (`SketchTessellator.dashedSegments`), are excluded from
`ProfileDetector` fills, and are the PREFERRED candidates when picking a
revolve axis. Persisted per sketch with backward-compatible decoding.
**Feasibility:** [mesh-kernel OK] (a flag on `SketchEntity` + `ProfileDetector`
exclusion + dashed rendering — no solver needed)

---

# 4. Tools menu

**Body types (glossary):** Shapr3D distinguishes **Regular bodies**
(watertight B-rep solids), **Sheet/Surface bodies** (zero-thickness surfaces
that do not enclose volume — produced e.g. as leftovers of face deletion and
cleaned up by deleting the leftover surfaces, §4.16), **Mesh bodies**
(triangle meshes, mostly imported), and **Wireframe bodies** (curves only).
openshape3d currently models a single body kind — a triangle mesh treated as
a solid — and none of the other types.

**Documented scope limits:** Shapr3D supports NO swept cuts and NO feature
patterns — Pattern operates on BODIES and SKETCHES only. The documented
workaround for both gaps is the same: "pattern the tool bodies, then
Subtract" (Quick concepts pt 2; Bodies and patterns pt 1).

### 4.1 Extrude

**Spec:** Creates 3D geometry by push/pulling a face or closed sketch profile
linearly; optional draft angle tapers side faces. Workflow: Tools > Extrude →
select face(s)/profile(s) → drag gizmo arrow or type distance → optional
Boolean badge override → optional draft angle → Done (adaptive invocation:
finish by tapping empty grid). Tap on a filled profile jumps straight into
Extrude. **Automatic Boolean rules:** New Body when the result touches
nothing; Union when a face of an existing body is the source, or a profile
connected to a body is pulled away; Subtract when pushed into an existing
solid; Intersect is never automatic (Boolean badge only). Only planar
faces/profiles can be extruded. History params: Profile; Sides = One-Sided |
Symmetric; Extent = Distance | To Object (pick target face, supports "Select
Through" and an end offset) | Through All (Flip Direction); Draft Angle; Start
= From Profile | Offset (start/end offsets) | From Plane. The history card
also exposes the boolean Result, the list of bodies affected by a cut
("Subtract From" scope — bodies can be excluded), and profiles can be
added/re-picked later. Behaviors: the Union result exposes an explicit
"Union with selected bodies" TARGET list — a Union result with NO body
selected silently fails to merge (Action camera pt 3); Symmetric extent uses
per-side HALF-values (entering 60 mm yields 120 mm total — Configurable
Rack); a drag-box while the tool is active selects only fully ENCLOSED
sketch regions; dragging the extrude arrow ONTO a face attaches the distance
associatively (To Object by direct manipulation — Bracket Mount). Documented
pitfall: new sketch-pattern instances are NOT auto-included in an existing
extrusion — the profile list must be re-edited per instance (Pipe Flange
pt 1). Hotkey E.
**Status:** 🟡 partial — the core loop is real: tap a fill → Extrude mode with
numeric input; drag pull with live preview + pull arrow; nested profiles
become holes (`ProfileDetector.holes`); automatic boolean
union/subtract/new-body with coplanar-seam overlap handling
(`commitTool`); face push/pull re-extrudes planar faces
(`FaceTopology.planarFace` → `beginFacePull`). Phase A additions: **Boolean
badge** (Auto | New Body | Union | Subtract | Intersect segmented control in
the extrude bar, `BooleanOverride`); **Symmetric** sides (per-side distance,
2× total, centered on the plane); **multi-profile** — additional fills
tapped while extruding union into one solid (`extraProfiles`); validity
feedback — the pull arrow renders RED when the pending result would fail
(`isPendingValid`, spec §18); and the commit convention is unified — tapping
empty grid commits a nonzero face pull too (`selectFaceOrBody`). A cut
applies to EVERY intersected body (`commitTool`), and a Union override
touching nothing stays a separate body. Missing: draft angle, extents
(To Object / Through All), Start options, the per-body include/exclude
"Subtract From" UI list, history card.
**Feasibility:** [mesh-kernel OK] (draft + extents included); parametric
history card [needs history engine]

### 4.2 Offset Face

**Spec:** Offsets faces/bodies to adjust thickness; tangent faces are
automatically included. Works on planar AND non-planar faces (cylindrical hole
resize by push/pull is the canonical demo), modifying the body by
extending/trimming adjacent faces without new geometry. Distance Types (single
flat face only): Radius/Diameter (circular faces; full circle = symmetric
diameter change), Total (offset face + opposite face to a total thickness),
Offset (default; only option for multi-select). Documented quirk: switching
a history step's Distance Type from Radius/Diameter to Offset re-applies the
stored radius/diameter value as the offset distance ("may give unexpected
results"). Workflow: select face(s) → gizmo or numeric → Done / tap empty
grid.
**Status:** 🟡 partial (generous — there is no Offset Face TOOL; the credited
behavior is literally the same code path as §4.1's face push/pull
(`selectFaceOrBody` → `FaceTopology.planarFace` → `beginFacePull` →
`commitExtrude`), so one implemented behavior is counted under two of the
Tools-menu 🟡 entries in the summary table). The flat-face equivalence holds
only when the adjacent faces are PERPENDICULAR to the pulled face:
`commitExtrude` unions/subtracts a straight prism built from the face
outline, which diverges from a true face offset (which extends/trims slanted
neighbors) on any non-prismatic surround. Missing: non-planar faces
(cylinder/cone/sphere),
tangent-face propagation, adjacent-face trimming (we add/cut a prism instead
of extending neighbors), Radius/Diameter and Total distance types,
multi-face offset.
**Feasibility:** planar subset [mesh-kernel OK]; true offset with adjacent-face
extension/trimming and curved faces [needs B-rep kernel]

### 4.3 Chamfer/Fillet

**Spec:** One tool: drag edge arrows INTO the body = chamfer, AWAY = fillet.
Chamfer types: Auto (equal setback; 45° on a right edge) and 2-distance.
Fillet default: circular cross-section, G1 tangent; FIXED radius (a single
arc) or VARIABLE radius (multiple arcs with different radii along the edge);
Radius or Chordal (chord width) sizing; 3+ edges meeting → Corner = Rolling
Ball (default) | Setback. Interaction rules: selection auto-propagates along
tangent-connected edge chains (filleting 2 edges of a chain rounds the WHOLE
chain); all edges in one fillet feature share a SINGLE radius — different
radii require separate fillet features; cross-body restriction — an edge
between two separate bodies fillets only one body, Union first (Dock cleat
pt 1); secondary fillets crossing a primary must be SMALLER than the primary
or the corners break (Primary and secondary fillets); edit-mode edge
selection is additive WITHOUT Shift.
Settings: Continuity G1 | G2 (G2 exposes a Curvature value), Profile slider
(-1 flat … 1 sharp, Magnitude label; non-default loses the radial dimension),
Overflow = Auto | Cliff | Smooth | Notch, Include Tangent Edges toggle,
Y-Shaped Blend toggle. Existing fillets are editable by selecting the face
(Edit) or from History (including adding more edges to one step). Hotkey F.
Zebra analysis recommended for continuity checks.
**Status:** 🟡 partial (Phase E tranches 1–3). Mesh-domain chamfer AND fillet
ship: multi-edge selection, live preview rendered in place of the source body,
drag-to-size arrow with red/blue validity, and `FeatureKind.chamfer/.fillet`
nodes so the blend is parametric and re-editable. Covered by
`KernelBlendTests`, `FeatureBlendEvalTests`, `BlendUITests`.
**Missing:** tangent-chain auto-propagation, concave edges (material-removal
only), best-effort corners where 3+ blended edges meet, one body per feature,
variable-radius/G2, and a prismatic quarter-round cross-section rather than a
true rolling ball.
**Feasibility:** [needs B-rep kernel] for the missing items — `BRepFilletAPI`
is goal G1 in `MODELING_PARITY_GOALS.md`. NOTE: a blend currently drops the
`Body.brep`, so filleting an analytic cylinder reverts it to a faceted mesh.

### 4.4 Shell

**Spec:** Hollows a solid to a uniform wall thickness by removing selected
face(s): select face(s) to remove → gizmo/numeric wall thickness → Done.
Whole-body mode: selecting the ENTIRE body (from the Items list, no face)
cores it out hollow with NO opening (Reverse Engineering an STL). Live
validity feedback: while dragging, the thickness arrow renders BLUE while
the result is valid and turns RED — with a top-of-screen "operation failed
because the resulting body wouldn't be valid" warning — outside the bounded
valid thickness range (Troubleshoot geometric errors). History params:
Target face, Thickness. Order matters with fillets (fillet
before shell → inside follows the fillet). Hotkey H.
**Status:** 🟡 partial (Phase E tranche 4). Hollow-a-body ships: tap faces to
open them, whole-body mode when no face is picked, thickness drag with
validity feedback, and a parametric `FeatureKind.shell` node. Covered by
`KernelShellTests`, `FeatureShellEvalTests`, `ShellUITests`.
**Missing:** correctness on CURVED walls (the mesh approach insets a planar
face outline, which is exact only for prismatic bodies), Offset Face on curved
faces, and Radius/Diameter + Total-distance thickness types.
**Feasibility:** [needs B-rep kernel] for the general case —
`BRepOffsetAPI_MakeThickSolid` is goal G2 in `MODELING_PARITY_GOALS.md`.

### 4.5 Loft

**Spec:** Interpolates a body through cross-section profiles — 2D body FACES
and/or closed sketches on separate planes (e.g. lofting between two faces of
revolved bodies); selected in connection order when >2 — with optional guide
curves that must intersect every cross-section, draggable Connection Points
(twist/alignment control), and Periodic Loft (blends first/last). Start/End
tangent continuity and bulge are adjustable via draggable on-screen handles
at each end. History
params: Profiles, Periodic on/off, Guides, Start/End Tangent Continuity =
None | G1 | G2 with Magnitude values. Curve-network workflow: rail splines
coincident to profile intersection points; editing rails/profiles live-updates
the loft.
**Status:** 🟡 partial — profiles-only loft: with a profile armed for
extrude, "Loft" seeds it as section 1 and taps on more profile fills (any
sketch plane) append sections in tap order, with a live translucent
preview and section counts in the pill/bar; commit lofts through the
sections (holes carried per section, `SweepLoftKit.loft`) and runs the
shared automatic-boolean pipeline; coplanar-only section sets are rejected
with guidance. Missing: body FACES as sections, guide curves, Periodic,
tangent continuity/bulge handles, live updates.
**Feasibility:** profiles-only loft [mesh-kernel OK] (Euclid `Mesh.loft`);
guide curves/continuity/periodic [needs B-rep kernel] for exactness; live
updates [needs history engine]

### 4.6 Union

**Spec:** Merges overlapping bodies. Select bodies → optional Keep Originals →
Done. In History the LAST selected body becomes Target, the rest Tools; the
step's Type dropdown can switch Union | Subtract | Intersect; Keep Target /
Keep Tool toggles. Keep Originals Off absorbs originals; On keeps them and adds
the merged result as a new body. Hotkey Cmd+U.
**Status:** 🟡 partial — two-body union via palette arm-then-tap flow
(`armBoolean` → `pickingBooleanTool` → `runBoolean`; async, cancellable,
watertight-healed in `KernelOps.boolean`). Missing: multi-body selection,
Keep Originals, target/tool badges, history card with type switching, no
overlap validation UX beyond an error alert.
**Feasibility:** [mesh-kernel OK]

### 4.7 Subtract

**Spec:** Removes the volume of tool bodies from target bodies (≥2 overlapping
bodies). Targets highlight PURPLE with a "+" badge, tools BLUE with a "−"
badge; tapping a badge toggles the body's role. Keep Originals options: All |
Modified Bodies | Removed Bodies | None — also editable later in History.
Hotkey Cmd+B. Subtract can fail ("operation failed"); a different overlapping
tool body is the documented fallback. Disjoint-result naming: a Subtract that
produces disjoint regions yields star-suffixed sibling bodies ("Body 2" and
"Body 2*"); mirrored/patterned copies likewise get suffixed names (Measure
precise volume; Mirror and union bodies).
**Status:** 🟡 partial — two-body subtract works (same pipeline as Union);
first selection is target, second tap is tool. Missing: role badges/ swapping,
multi-select, all four Keep Originals modes (originals are always consumed),
history editing.
**Feasibility:** [mesh-kernel OK]

### 4.8 Intersect

**Spec:** New body from the shared volume of overlapping bodies; same
badge/role UX as Subtract; Keep Originals Off (default) keeps only the result.
Hotkey Cmd+I.
**Status:** 🟡 partial — two-body intersect works via the same flow; same gaps
as Subtract.
**Feasibility:** [mesh-kernel OK]

### 4.9 Split Body

**Spec:** Divides a solid into parts WITHOUT removing material. Select bodies
to split (blue + badge) → select splitting tools: construction plane, grid
plane, sketch profile, another body's face or coplanar edges, an image, or one
of the body's OWN faces. Tools are projected through the bodies (no contact
needed); multiple tools cut simultaneously; connected same-plane sketches merge
into one splitting surface. Keep Originals toggle. History params: Bodies to
Split, Split With, Keep Originals.
**Status:** 🟡 partial — one body, one cutter: palette "Split" on a selected
body arms a cutter pick (world/construction plane tiles shown); tapping a
plane tile splits by half-space CSG, tapping a sketch profile fill splits
by a through-extruded cutter (`SplitKit`); the two halves land as
"<name> A" / "<name> B" in ONE undo step (Replace + Add composite — undo
is the Keep Originals path), both selected. Missing: multiple bodies,
multiple simultaneous cutters, own-face/other-face and image cutters,
Keep Originals toggle.
**Feasibility:** [mesh-kernel OK] (plane/extruded-profile splitting via CSG
with half-spaces/cutter solids; curved-face splitting tools are harder but
possible with thickened cutters)

### 4.10 Revolve

**Spec:** Axially symmetric solids by rotating a profile (closed sketch or
face) around an axis (grid axis, construction axis, sketch line, or linear
edge). Default 360°, any angle (numeric field supports calculator input, e.g.
360×4 for multi-turn); nonzero Height/Elevation makes helical bodies (springs,
threads — every 360° = one revolution; too little vertical travel yields a
self-intersecting-body error). Same automatic Boolean rules as Extrude;
Boolean badge for overrides. Selection flow: profile + Shift-click axis →
Revolve in adaptive menu. History params: Profile, Axis, Angle, Elevation.
Hotkey V.
**Status:** 🟡 partial — select a profile fill → "Revolve" in the extrude
bar → pick a sketch line or world axis (`pickingRevolveAxis` mode) → drag or
type the angle (default 360°, partial wedges stitched manually,
`KernelOps.revolve`); commits through the same automatic-boolean pipeline
and Boolean badge as Extrude; profiles crossing the axis are rejected.
Missing: linear-edge/construction axes, Shift-click selection flow, helical
Elevation, history params.
**Feasibility:** full + partial revolve [mesh-kernel OK] (Euclid `Mesh.lathe` +
wedge intersect); helical revolve [mesh-kernel OK] (swept mesh construction)

### 4.11 Sweep

**Spec:** Extends a profile (closed sketch or face) along a path/spine (sketch
elements or body edges) for pipes, cables, handles, rails. Best practice:
profile positioned at the path start; sharp path corners can self-intersect —
fillet the path. Path selection: double-clicking a sketch line selects the
whole tangent-connected chain as the path (Custom glassware); single clicks
add path segments one by one. A "self intersect" failure is also fixed by
adding constrained guide/mid lines to the path sketch (Water bucket).
Adaptive tip: select profile AND all spines before invoking.
History params: Profile, Path, Profile Position = Auto | Path intersection |
Closest point | Closest endpoint; Orientation = Normal to path | Parallel to
profile; Twist (angle along path); Scale (size along path); Corner type =
Mitre | Round. Hotkey W.
**Status:** 🟡 partial — with a profile armed for extrude, "Sweep" arms a
path pick: single taps chain open sketch lines/arcs (across sketches/
planes) into the spine — the first segment auto-orients toward the
profile, later segments must join the spine end — with a live preview and
segment counts in the pill/bar; commit sweeps the profile (holes included)
along the spine (`SweepLoftKit.sweep`) through the automatic-boolean
pipeline; empty-space tap commits like extrude. Missing: body edges as
paths, double-tap whole-chain path selection, Profile Position /
Orientation / Twist / Scale / Corner params.
**Feasibility:** [mesh-kernel OK] (Euclid `Mesh.extrude(along:)`; twist/scale/
corner options are mesh-sweep math)

### 4.12 Replace Face

**Spec:** Extends or trims selected face(s) to match another face. Faces to
replace highlight blue, replacing face purple; badge tap swaps roles; Flip
Alignment toggle extends to the other side. Works on complex non-planar faces
(imported or native).
**Status:** ❌ not implemented.
**Feasibility:** [needs B-rep kernel]

### 4.13 Offset Edge (3D)

**Spec:** From a 3D body: choose Single | Chain, select edge(s), gizmo sets
offset direction and distance; output is sketch geometry in an auto-created
sketch on the relevant plane/face. History param: Plane.
**Status:** 🟡 partial — `EdgeOffsetKit` implements the geometry for
planar-face edges, both selection modes: **Chain** offsets the face's whole
outer boundary as a closed, mitred loop; **Single** offsets just the tapped
segments as open polylines (a pick snaps to the nearest boundary segment, and
picks are emitted in outline order so adjacent ones stay connected). Sign
follows the sketch tool — positive grows outward on a CCW outline, negative
inward — and an offset that consumes the face reports failure instead of
emitting a flipped loop. The output is hosted on the face's OWN plane
(`EdgeOffsetKit.plane(of:)`), so it lands back on the face it came from.
Covered by `EdgeOffsetTests`.
**Missing:** the tool entry point and drag gizmo, auto-creating the sketch to
receive the output, the history node with its Plane param, and offsets of
edges on curved surfaces.
**Feasibility:** [mesh-kernel OK] for planar-face edges — confirmed;
curved-surface edge offsets [needs B-rep kernel]

### 4.14 Project (Tools)

**Spec:** See 1.13 — same tool, 3D entry point. Additional 3D uses: project a
body → 2D outline symbol; face → engraving; edges → reference distances; merge
same-plane sketches into one; project onto non-planar faces (edges only);
edge projections split the target surface (per-region materials, embossing).
**Status:** ❌ not implemented.
**Feasibility:** as 1.13

### 4.15 Wrap & Emboss

**Spec:** Maps 2D sketch profiles onto cylindrical or conical faces preserving
surface-area dimensions (no stretch — unlike Project's linear cast). Select
profiles → select a SINGLE cylindrical/conical target face → gizmo position +
depth → Done. History params: Items to Wrap, Face to Wrap Onto, Emboss depth
(positive raised / negative engraved), Rotation (about own center), Center
(alignment origin on the target).
**Status:** 🟡 partial — `WrapKit` implements the mapping and the emboss
solid. The no-stretch property holds exactly: profile x is treated as ARC
LENGTH and y as axial distance, so a 40 mm-wide profile is 40 mm of surface at
r = 8, 20 or 100 (unlike Project's linear cast), and a full circumference of
profile closes back on its own start. Rotation and Center (alignment origin)
are honoured, and a picked `CylindricalFace` converts straight into a target.
`embossSolid` returns a closed mesh to fuse (positive depth = raised) or
subtract (negative = engraved); its volume matches the analytic wrapped-slab
value A·|d|·(1 + d/2r) — signed, since a raised slab's outer face is longer
than its base while an engraved one's inner face is shorter — to within 1%,
and fusing a boss onto a real cylinder body adds exactly that much.
The solid is built in angular BANDS: a single triangulation would chord
straight through the cylinder wherever a facet spans a wide angle and quietly
lose volume, so each band is clipped, triangulated and lifted separately, with
no wall on the interior cuts so the bands tile into one manifold.
Covered by `WrapEmbossTests`.
**Missing:** the tool UI (profile/face selection, position + depth gizmo), the
history node, and conical targets — the mapping generalises but is not
written.
**Feasibility:** [mesh-kernel OK] for cylinders — confirmed; the band
construction is what makes the mesh approximation stable.

### 4.16 Delete Face (direct modeling)

**Spec:** Select a face — or a Shift-selected chain of faces — and press
Delete: the feature (hole, pocket, boss) is removed and the surrounding
surfaces HEAL automatically to re-close the body. Canonical uses: removing
holes/pockets when adjusting components; simplifying molds ("Lampshade
positive mold") and dies. Companion workflow: Offset Face a redundant
feature to nothing, then delete the leftover surfaces. Deletions that cannot
heal leave sheet/surface bodies (see the §4 body-types intro).
**Status:** 🟡 partial — the healing engine ships as a feature-graph node,
`.deleteFace(body:faces:)`, evaluated through OCCT's `BRepAlgoAPI_Defeaturing`
(`evalDeleteFace`). Persisted `FaceRef`s re-resolve against the input body on
every rebuild — including CYLINDRICAL faces, so deleting a hole's wall is one
tap — and the surrounding surfaces extend to re-close the solid (a Ø4 hole
deleted from a 10 mm box heals back to exactly six planar faces and its full
1000 mm³). Failures are reported, never swallowed: an unresolvable face, an
empty selection, or a set of neighbours that cannot close errors the node and
leaves the body untouched. Covered by `DeleteFaceEvalTests`.
**Missing:** the tap-a-face-then-Delete gesture in the viewport, Shift-chain
face selection, and the sheet/surface-body fallback for deletions that cannot
heal (today those simply error).
**Feasibility:** [needs B-rep kernel] — confirmed; this is B-rep-only on
purpose, since healing means EXTENDING adjacent surfaces and a mesh has no
surfaces to extend.

---

# 5. Transform menu

### 5.1 Move/Rotate (gizmo)

**Spec:** The gizmo has: a **center** (rotation center + orientation control;
draggable; SNAPS to axes, faces, edges, sketch profiles, construction geometry
to re-anchor — e.g. drop it on a circle to rotate about that circle's axis);
**arrows** (linear + rotational; drag = dynamic move, click/select = numeric
entry via the dimension label); **tiles** (planar 2-axis drag); **dimension
labels** (hover/tap to type exact values); **Copy badge** (each drag while
active creates a copy; stays on for multiple copies; a 0-net move duplicates
in place); **Link badge** (off = copy is unlinked from History, recorded as
"Unlinked Copy"). Copy propagation semantics: LINKED copies inherit edits
made BEFORE the copy step in history but not after; UNLINKED copies are
free-floating "Unlinked Copy" entries movable anywhere in the timeline,
accept direct edits, never update from the source, and deleting the entry
removes the bodies (Quick concepts pt 3; Loft/Sweep concept tutorial; Action
camera pt 1). Auto-orientation option aligns gizmo axes to selected
geometry — availability rule: it appears ONLY when the tool is invoked from
the Transform menu, NOT when implicitly activated by selecting a body. The
gizmo also auto-centers on circular faces (the rotate widget lands on the
circle center — Floor fan), which is distinct from manual center
re-anchoring. Moves/rotations are recorded as history steps whose target-body
list can be edited later. Hotkey M. Model-aware dimension labels show total body
dimensions during direct face pulls, not just deltas.
**Status:** 🟡 partial — full translate + rotate gizmo: XYZ arrows,
XY/YZ/ZX plane tiles, and X/Y/Z ROTATION RINGS with axis/plane/ring-
constrained drag math (`GizmoPart` ring cases, `GizmoDragSession.
rotationDelta`, quaternion-multiplying `updateTransform`); tapping an arrow
(not dragging) opens exact-distance entry in the numeric bar
(`beginAxisDistanceEntry` → "Move X/Y/Z" field); the **Copy badge** chip
duplicates the selection in place before the next drag (`copyOnDrag`,
`AddBodyCommand` clones); undoable via `TransformBodiesCommand`. Highlight
is drag-time only (no hover recognizer). Missing: center
re-anchoring/snapping, dimension labels during drag, Link badge,
auto-orientation, model-aware totals.
**Feasibility:** [mesh-kernel OK]; history integration [needs history engine]

### 5.2 Translate

**Spec:** Point-to-point precise move: shift sketches, sketch profiles, and
bodies from one specific point to another; start and end points snap to grid
points, edges, and vertices. Copy option duplicates instead of moving.
History params: Target Bodies/Faces/Edges, Start Point, End Point, Copy
toggle. Hotkey N.
**Status:** 🟡 partial — bodies only: palette "Translate" on a selection,
then two taps — source snap point, destination snap point (body vertices
and sketch notable points first, ground-grid intersections as fallback;
hidden items excluded; cross markers at picks) — and the selection shifts
by the exact delta as one undoable step titled "Translate". Escape/Cancel
in the pill exits. Missing: sketch/profile targets, Copy option.
**Feasibility:** [mesh-kernel OK]

### 5.3 Rotate Around Axis

**Spec:** Rotate sketches/closed sketches/faces/bodies around a selected axis
(line + face selection surfaces the tool in the adaptive menu). Workflow:
select items → Next → select the axis (construction axis, sketch line, or
linear edge) → drag the rotation gizmo or type an angle → Done. Dragging
snaps in 5-DEGREE increments; finer values (e.g. 1.5°) are typed into the
numeric field. Copy badge rotates a duplicate. History params: Targets,
Axis, Angle (numeric), Copy.
**Status:** 🟡 partial — bodies only: palette "Rotate" on a selection, then
tap a sketch line or an X/Y/Z pill button for the axis; drags scrub the
angle in 5° steps with a live preview, the numeric field takes exact fine
angles, Apply/empty-tap commits one `TransformBodiesCommand` titled
"Rotate" (cancel restores the pre-tool transforms). Missing: construction
axes and linear body edges as axes, the on-axis rotation gizmo, Copy
badge.
**Feasibility:** [mesh-kernel OK]

### 5.4 Scale

**Spec:** Proportionally resizes sketches, faces, edges, bodies. Type menu —
two modes: **Uniform** (single center-point handle; the scale CENTER is
movable, e.g. to the origin, before dragging) | **Non-uniform** (gizmo at the
center with per-axis handles; also reachable as "Scale - Non-uniform" via
Command Search). Copy badge (BLUE when active) scales a duplicate. Commit by
tapping empty grid. Face/edge scaling semantics: uniform Scale on a swept
body's END face tapers the cross-section along the sweep (Organic Chair).
Used to calibrate imported reference images against a dimensioned line.
History params: Scale X/Y/Z, Uniform toggle, Copy. Hotkey S.
**Status:** 🟡 partial — uniform scale only: palette "Scale" on a selection
opens a factor field; committing multiplies each selected body's uniform
scale about its pivot, undoably (`beginScaleEntry`/`commitScale` →
`TransformBodiesCommand` titled "Scale"); the Copy badge (blue when
active) scales duplicates instead, and tapping empty grid commits the
pending factor per spec. Missing: drag handles, movable scale center,
Non-uniform mode, face/edge scaling.
**Feasibility:** [mesh-kernel OK]

### 5.5 Align

**Spec:** Positions parts together by mating snap points. Valid selections:
planar/spherical/conical faces, sketches, construction planes/axes, circular
edges and circular sketches, linear sketch elements/edges; two faces from
different bodies surface Align in the adaptive menu. PURPLE snap points
appear on valid geometry — drag a dot onto another dot to mate. After
mating, the gizmo adjusts the result (rotate about the mate center, linear
move, planar move); a Flip badge rotates 180°. Snap-to-likely-positions
while dragging: aligned vertices, collinear edges, coplanar arcs (with a
"coplanar arcs" snapping hint), coplanar faces, parallel edges. Selecting
two cylindrical faces auto-centers them COLLINEARLY (Parametric Clamp). The
relation is static — no persistent mates (Shapr3D has no native
assemblies). History param: Target Body.
**Status:** 🟡 partial — vertex-onto-vertex mating: palette "Align" (needs
≥2 bodies), tap a snap point on the body to move, then a point on another
VISIBLE body (hidden bodies never pick); the first body translates so the
points coincide, one undo step titled "Align". Missing: purple snap-point
rendering on faces/edges/centers, post-mate gizmo + Flip badge,
likely-position snapping, cylindrical auto-collinear centering.
**Feasibility:** [mesh-kernel OK]

### 5.6 Mirror

**Spec:** Mirrors any sketch, face selection, or body across a mirror plane
(construction plane, world plane, or planar face). Selecting a construction
plane surfaces Mirror; then select the items. Badge UX: selected items
highlight BLUE with a Mirror badge; the mirror plane highlights PURPLE with
a target badge; tapping a badge toggles the role. Keep Originals supported;
mirrored FACES create the feature symmetrically without redoing sketches;
mirrored sketches gain symmetry constraints (moving one side updates the
other); a mirrored construction plane follows its original. Mirrored body
halves remain two SEPARATE bodies with a visible seam until Union (Bodies
and patterns pt 2); mirrored copies get suffixed names (§4.7). History
params: Target Bodies/Faces, Plane, Keep Originals toggle.
**Status:** 🟡 partial — body mirror: palette "Mirror" on a selected body
lists the world planes plus any construction planes; picking one reflects
the mesh across it (winding flipped, `KernelOps.mirror`) and adds the
result as a new body, keeping the original (Keep Originals always on,
`mirrorSelection`). Missing: sketch and face-selection mirror, blue/purple
role badges, Keep Originals toggle, constraint-linked sketch symmetry.
**Feasibility:** body/sketch mirror [mesh-kernel OK]; constraint-linked sketch
mirror [needs constraint solver]; face-feature mirror [needs B-rep kernel]

### 5.7 Pattern (3D — bodies & sketch profiles)

**Spec:** **Linear**: a real linear pattern of bodies/sketch profiles along
one, two, or THREE axes; per-direction Total Distance | Spacing Distance and
Quantity badges; drag the center handle onto a sketch line to pattern along
that arbitrary direction (Staircase). History params: Definition dropdown,
Quantity, Distance. **Circular**: pattern of bodies about a movable center
node (snaps to geometry centers; handles rotate/pattern about any axis
through the node); angle (e.g. 360°) + count; per-instance Uniform |
Rotated. Patterned bodies are auto-grouped into an Items Manager FOLDER;
instances are listed/selectable under the pattern feature, and a body can
later be pulled out of the pattern group; a pattern result folder works as a
one-click Subtract TOOL set (Floor fan). Scope rule: Pattern operates on
bodies and sketches only — there are NO feature patterns (see the §4 scope
limits; workaround: pattern the tool bodies, then Subtract). SKETCH PROFILES
can also be patterned in 3D — doing so auto-creates the sketch pattern
constraint (§2.5) linking the instances. Patterned copies get suffixed
names (§4.7).
**Status:** 🟡 partial — static instances: palette "Pattern" on a selected
body opens the pattern bar (Linear: X/Y/Z axis + spacing; Circular: axis
+ total angle + count, instances rotated) with translucent ghost
previews; Apply adds count−1 copies as ONE CompositeCommand ("Pattern" in
undo) with suffixed names (Box 2, Box 3, …), all instances selected.
Sketch profiles pattern in-plane per §1.11. Missing: 2-/3-axis linear
grids, Total-distance definition, draggable direction/center handles onto
sketch lines, movable circular center, Uniform orientation, Items Manager
pattern FOLDER grouping and folder-as-Subtract-tool, live re-editing.
**Feasibility:** static instances [mesh-kernel OK]; editable pattern group
[needs history engine]

---

# 6. Insert / Construct menus

### 6.1 Construction plane

**Spec:** Add > Construction Plane — the corpus documents SEVEN plane tools:
**Offset** (select any flat input — plane, face, sketch → Next → drag/type
offset → Done); **Midplane** (select two faces/planes → plane centered
between them; used constantly in the DFM tutorials); **Perpendicular to Edge
(at point)** (select edge → select reference point along it — position
draggable/not critical); **Through Edge at Angle** ("Along edge at angle":
select an edge/line plus a reference face/plane, set the angle — the
angled-plane workhorse of the robotic-arm and frame tutorials); **Parallel
to Face at Point** (plane through a picked point, parallel to the selected
face); **3 Points** ("Add Plane - 3 Points" via Command Search); **Along a
spline** (offered when a spline is selected — plane rides the curve "like a
roller coaster", placed at e.g. the midpoint for Sweep profiles); plus
**Mirrored** across a world plane (follows the original). Every plane type
has an editable **Size** parameter; per-type History params: Face,
Point #1–3, Edge, Angle (plus Offset distance where applicable). Plane
icons can be visually scaled down. Sketches attached to a plane follow it
parametrically (offset edit moves plane + sketch).
**Status:** 🟡 partial — the **Offset** tool only: with a face selected,
"Offset Plane" pulls a construction plane off it along the normal (drag the
arrow or type the distance, extrude-style preview); committed as an
undoable `AddConstructionPlaneCommand`, persisted (`PersistedPlane`),
rendered as a tile, usable as a sketch plane and a mirror plane. Missing:
the other six plane tools (Midplane, Perpendicular to Edge, Through Edge at
Angle, Parallel to Face at Point, 3 Points, Along Spline, Mirrored), the
Size parameter, construction axes (§6.2), parametric following.
**Feasibility:** planes themselves [mesh-kernel OK]; parametric following
[needs history engine]

### 6.2 Construction axis

**Spec:** Add Axis — the corpus documents FIVE axis tools: **Axis of
Cylinder/Cone** (select a cylindrical/conical face → axis through its
center); **Axis Through 2 Points**; **Axis Through 2 Planes** (intersection
line of two planes/planar faces); **Axis Along Edge**; **Axis Perpendicular
to Face at Point**. All parametrically adjustable later; History param:
Length (plus the defining references). Adaptive "Add Axis" shortcut: with a
valid selection the adaptive menu offers Add Axis directly, skipping menu
steps. Axes serve Revolve, patterns, and transforms.
**Status:** 🟡 partial — the GEOMETRY for all five axis tools ships in
`ConstructionAxisKit` (through-2-points, along-edge, perpendicular-to-face,
2-plane intersection, and axis-of-revolution recovered from face samples by a
least-squares fit), with degenerate selections refused rather than producing
NaNs. Covered by `ConstructionAxisTests`.
**Missing:** the document entity, the Add Axis tool/adaptive menu entry, the
History Length parameter, rendering, and using an axis as the operand for
Revolve / circular pattern / rotate.
**Feasibility:** [mesh-kernel OK] — remaining work is app/UI, not geometry.

### 6.3 Insert Image (reference images)

**Spec:** Insert > Image (File menu desktop / More menu iPad / Dashboard
import; iPad can capture with camera): place, then gizmo to scale/move/rotate;
Opacity slider (also editable later from the Items Manager percentage) for
tracing; align to a plane; calibrate scale against a dimensioned sketch line
using Move + Scale with a re-anchored center. Formats: PNG, JPG, single-page
PDF, TIFF, BMP, ICO, RAW, GIF (static). Images can also be splitting tools for
Split Body.
**Status:** 🟡 partial — toolbar Import → "Image from Photos…" / "Image from
Files…" (PNG/JPEG): the picked picture arms a plane pick (world/construction
tiles; anywhere else defaults to ground) and lands as a textured quad sized
to ~50 mm max dimension with aspect preserved (`InsertedImage`, persisted).
Tapping the quad selects it: move gizmo plus an image bar with an Opacity
slider, size field (aspect-preserving), Done and Delete; images list in the
Items Manager with rename/visibility/delete and full undo
(`Add/Update/RemoveImageCommand`). Missing: rotation on the plane, camera
capture, PDF/TIFF/BMP/ICO/RAW/GIF, calibrate-against-dimension flow, and
images as Split Body cutters.
**Feasibility:** [mesh-kernel OK] (textured quad + renderer work)

### 6.4 Insert File (import into project)

**Spec:** Insert > File: imports a supported CAD/mesh file into the current
project; reposition with Move/Rotate or Translate afterwards. Non-native
formats arrive as one "Import" history step (with an editable settings control);
STEP preserves assembly hierarchy as nested folders.
**Status:** 🟡 partial — importing into the open project ships via the
toolbar Import menu (STEP, OBJ, STL, DXF, reference images — see §12.1); an
imported body lands as a normal body and can be repositioned with
Move/Rotate like any other. Missing: the Insert > File entry point itself,
the single editable "Import" history step with its settings control, and
STEP assembly hierarchy as nested folders.
**Feasibility:** STL/OBJ/3MF [mesh-kernel OK]; STEP/IGES [needs B-rep kernel];
see §12.

### 6.5 Insert Project

**Spec:** Insert > Project imports another Shapr3D project from the Dashboard
into the current one INCLUDING its full history — its feature steps appear
individually in History and stay editable (used to insert a motor reference
model in the Wall Clock tutorial).
**Status:** 🟡 partial — `ProjectMergeKit.insert` merges another document
into the open one WITH its history: the guest's feature nodes are appended, so
they appear individually in History, still evaluate, and stay editable (a test
edits an inserted step and watches the inserted geometry rebuild). Every
identity — feature, body, sketch, construction plane, sketch entity — is
re-minted and every reference rewritten in step, including sketch constraints,
dimensions and §2.5 pattern links; inserting a project INTO ITSELF produces
two independent copies rather than cross-wiring the history, which is the
silent-corruption case two template-derived projects would otherwise hit. A
translation offsets the incoming geometry so it does not land inside the host,
and a clashing variable name keeps the HOST's value (its formulas depend on
it) and is reported via `droppedVariableNames` rather than swallowed. The
host's rollback marker extends so inserted steps do not arrive rolled back.
Covered by `ProjectMergeTests`.
**Missing:** the Insert > Project UI and Dashboard picker, and nesting the
inserted steps under their own History folder.
**Feasibility:** geometry merge [mesh-kernel OK]; history merge — confirmed
possible on the existing feature graph, no new engine needed.

### 6.6 Variables & expressions

**Spec:** Create from a dimension label ("X+" icon → "Create Length 1 = 40"),
from Add > Variable (Number type for quantities), or Shift+Cmd+V. The
Insert > Variables panel flow: enter rows as "Name = Value"; the panel STAYS
OPEN for adding several in a row. Naming rules: alphanumerics + underscore
only, no leading digit, max 100 characters, no leading double underscore.
Variables are typed (length/angle/number) and only compatible types appear
in a field's picker; listed in the History panel; right-click to rename;
changing a value updates every consumer; creation-order rule: a variable can
only reference PREVIOUSLY created variables. Labels show the variable name
when selected and "fx 40" when not. Expressions in any dimension field
reference variables ("Cap Height / 2", "Pattern Length - Circle Diameter +
(Circle Diameter/2)"); results recompute on variable change; expressions can
be copied/pasted between fields. Built-in function library: sqrt, sign,
floor, ceil, round, abs, mod, min, max, avg, sin/cos/tan/cotan/sec/cosec +
their inverses + arctan2, pi(), radians(); evaluation uses the Parasolid
1e-8 tolerance. Unit handling: cross-unit conversion within a type works
(5mm + 2cm → 25mm); mixing unit TYPES (e.g. length + angle) errors;
intermediate area/volume results are allowed but the FINAL result must be a
single dimension. Feet/inch symbol notation is accepted with documented
parser pitfalls: 1/2" mis-parses as 1/(2 in); 1' 1/2" errors. Feature
dimensions (Extrude distance, Fillet radius, Shell thickness,
pattern Total/Spacing/Quantity) all accept variables.
**Status:** ✅ implemented (Phase D). Named variables with expression formulas
(`ExpressionEvaluator`), consumed by feature parameters via `Expr`; editing a
variable rebuilds every dependent feature in one undo step. Covered by
`ExpressionEvaluatorTests`, `VariablesTests`, `VariableFanoutTests`,
`PersistedVariableTests`.
**Missing:** driving SKETCH dimensions from variables (feature parameters only
today).

---

# 7. Navigation & views

### 7.1 Camera navigation (touch/pen)

**Spec:** iPad: one-finger drag on the grid orbits; two-finger pan moves the
camera; pinch zooms; with 2-Finger Rotation enabled a two-finger twist rotates
the view. Pencil never orbits — it draws/selects. Double-tap a face with a
finger = zoom to face; double-tap the Orientation Cube = reset view. Camera
never locks up mid-tool. Desktop mappings + Navigation Presets (Shapr3D
Default/Classic + Alias/CATIA/NX/Blender/Plasticity/Fusion 360/OnShape/Rhino/
SketchUp/SolidWorks emulations).
**Status:** 🟡 partial — two-finger pan and pinch zoom are implemented and
never blocked; one-finger orbit works from empty grid but IS claimed by
active tools — sketch-mode drags draw, extrude/face-pull drags pull, gizmo
drags transform, and drags starting over a filled profile begin a pull
(`ViewportGestureController.handleOrbit`'s `.began` branch offers the drag
to the `ViewportView.gestureDragBegan` delegate first and falls back to
orbit only when no tool claims it). Mid-sketch orbit: tapping the ACTIVE
sketch tool deselects it (`deselectSketchTool`, `tool: nil`), after which
empty-space drags orbit and "Look at Sketch" restores head-on. That
mirrors Shapr3D's own
convention, so the level stands (`TurntableCamera.orbit/pan/zoom`);
double-tap empty space fits the scene. The Apple Pencil now draws sketch
strokes (`.pencil` accepted on the one-finger recognizer, with
pencil-touch tracking for arbitration). Missing: 2-finger twist rotation,
zoom-to-face on double-tap (double-tap on a body selects it instead —
deliberate choice), presets, scroll/modifier desktop mappings.
**Feasibility:** [mesh-kernel OK]

### 7.2 Orientation Cube

**Spec:** Live view-orientation cube with X/Y/Z labels; 6 faces + 8 corners +
12 edges are clickable — face click enters the 2D planar view (rotation arrows
appear above the cube to spin the plane in 90° steps), corner/edge click goes
to that orthographic view. Drag the cube to rotate freely; double-click/tap
resets to default view. Right-click menu: Default View, Top View, Zoom to Fit.
**Status:** 🟡 partial — a live axis-tinted cube renders in the top-trailing
corner in its own overlay pass (`OrientationCube` + `OrientationCubeRenderer`
reusing the gizmo pipeline); tapping a face or corner animates the camera to
that view (`hitPose` → `CameraAnimator`); cube taps never reach the model.
Drag-to-orbit on the cube works as a UNIVERSAL orbit control (`ViewportView.
gestureDragBegan` claims any drag starting in `OrientationCube.rect` before any
mode-specific handling, so the camera can be freely orbited in EVERY mode —
sketch/extrude/face-pull/gizmo — even when a tool owns the main viewport). A
tap still snaps to the view; only the drag orbits. Missing: edge hits, X/Y/Z
labels, double-tap reset, the 2D-planar-view rotation arrows, context menu.
**Feasibility:** [mesh-kernel OK]

### 7.3 Views & Appearance panel

**Spec:** **Views tab:** Default View; standard views Top/Bottom/Front/Back/
Right/Left + Nearest Ortho View; up to 8 Saved Views (hover empty slot to
Save; right-click Update/Delete); Grid Position = XY | YZ | ZX plane;
SpaceMouse Settings entry when a 3Dconnexion device is present (§7.5).
**Appearance tab:** Animate Camera toggle; 2-Finger Rotation; Field-of-view
slider 0° (orthographic) … 90° (perspective); Show Hidden Edges; Show Pinned
Measurements; Shaders = Shaded | Visualized; Surface Analysis = Zebra
(G0/G1/G2, Direction H/V) | Curvature Map (Scale). View shortcuts Cmd+1…7.
Desktop View-menu extras: Rotate View (fixed-angle camera increments),
Collapse All, Show Properties Sidebar, Enter Full Screen, and a "keep
horizon level" navigation toggle (Staircase tutorial).
**Status:** 🟡 partial — a Views toolbar menu offers the six standard views
(Top/Bottom/Front/Back/Right/Left) plus Isometric (`StandardView`,
`applyStandardView`, animated through `CameraAnimator`) and an
**Orthographic** projection toggle (`CameraProjection.orthographic` branch
in `TurntableCamera.projectionMatrix`); the same menu hosts the Display
shader submenu + Show Hidden Edges (§16.4), Ground Shadow (§14), Isolate
(§16.2), and Section (§16.1) entries. Missing: saved views, Nearest Ortho
View, grid-position setting, the FOV slider (toggle only), 2-finger
rotation option, surface analysis, view shortcuts.
**Feasibility:** [mesh-kernel OK]

### 7.4 Grid & units

**Spec:** Grid fills the design space; its resolution changes dynamically with
zoom; the Units (#) button shows current grid resolution and sets unit
(mm/cm/m/in/ft), Lock Grid toggle, inch/degree format (architectural or
decimal feet-inches; decimal or fractional degrees).
**Status:** 🟡 partial — procedural anti-aliased ground grid rendered
(`Renderer` + `Shaders.metal`); implicit fixed units (1 unit = 1 mm at STL
export). Missing: zoom-adaptive resolution display, units UI, unit
conversions, grid lock, grid on other planes.
**Feasibility:** [mesh-kernel OK]

### 7.5 Peripherals: SpaceMouse & Wacom

**Spec:** 3Dconnexion SpaceMouse devices drive 3D navigation, configured via
SpaceMouse Settings under the Views menu; Wacom pen displays/tablets act as
pen input on desktop (pen draws/selects, touch/mouse navigates — same split
as Apple Pencil).
**Status:** ❌ not implemented — no external-controller or tablet input path.
**Feasibility:** [platform/service] (3Dconnexion/Wacom SDK + OS integration)

---

# 8. Selection & gestures

### 8.1 Core selection

**Spec:** Single tap selects the sub-element under the pointer (face, edge,
sketch element); tapping a body selects the planar face under the finger;
double-tap/double-click selects the whole body/connected group. Selected items
stay visible (highlighted through occluders). Deselect: tap empty space /
Escape / Cmd+. . Shift+click multi-selects (macOS Selection Extension setting
can invert this). Selecting a sketch element from 3D jumps straight into
editing that sketch without rotating the camera.
**Status:** 🟡 partial — tap = planar face selection with orange highlight
(`selectFaceOrBody` + `FaceTopology`), fallback to whole body on curved
regions; double-tap = whole body; tap empty = deselect; sketch elements are
tap-selectable while in sketch mode (`selectedSketchEntityIDs`). Missing:
edge selection, multi-select, highlight-through-occluders,
jump-into-sketch-on-tap from 3D.
**Feasibility:** [mesh-kernel OK]

### 8.2 Area (box) selection + filters

**Spec:** Drag a box: left-to-right selects only items COMPLETELY inside
(window); right-to-left selects everything TOUCHED (crossing). While the box is
active, Tab cycles selection filters, or keys B (bodies) / F (faces) /
E (edges); after a drag-select Tab reveals a slider to limit the selection.
Long-tap then drag = area select on touch.
**Status:** 🟡 partial — a palette Select mode: one-finger drags draw the
marquee (camera orbit is suspended), left→right = window (solid rect, fully
inside only), right→left = crossing (dashed rect, touched selects) —
`AreaSelect` implements the membership rules over projected mesh vertices /
tessellated sketch points, skipping hidden items. The status pill carries
Bodies/Sketches filter chips; the resulting multi-selection shows a count +
combined-bounds info bar, palette Delete removes it in one command. Missing:
faces/edges filters (B/F/E), Tab filter cycling, the post-drag limit slider,
and long-tap-drag entry without the mode.
**Feasibility:** [mesh-kernel OK]

### 8.3 Overlapping-item disambiguation & Select Through

**Spec:** When multiple candidates overlap under the cursor, a pop-up lists
them by name (hover highlights orange, parent sketch gets a thicker blue
outline). "Select Through This Point" (context menu or Cmd+Shift+S) lists
everything under the screen point through depth — faces, bodies, sketch
profiles — for occluded selection; Shift + select-through adds to selection.
**Status:** 🟡 partial — long-press in the viewport opens a "Select Through"
popup listing every body under the point sorted by depth
(`HitTester.pickAllBodies`); choosing one by name selects it and dismisses.
Missing: faces/sketch profiles in the list, hover highlighting, additive
Shift + select-through, Cmd+Shift+S.
**Feasibility:** [mesh-kernel OK]

### 8.4 Keyboard shortcuts, hotkeys, Command Search

**Spec:** Sketch hotkeys A/C/G/I/L/O/R/T; modeling E/F/H/M/N/P/S/V/W; boolean
Cmd+U/B/I; constraints Shift+letter; Undo Cmd+Z, Redo Shift+Cmd+Z; Select all
Cmd+A; view Cmd+1…7; three-finger swipe left/right = Undo/Redo on iPad; Single
Key Action setting = Hotkeys | Command Search; customizable shortcuts;
cheat-sheet via Help or long-press Cmd. **Space bar:** hover a face + Space
= zoom to that face; with a sketch selected, Space rotates the camera to the
sketch's perpendicular (head-on orthographic) view. **Dashboard shortcuts:**
New Project; Import into the CURRENT project (Shift+Cmd+I) vs Import as a
NEW project (Opt+Cmd+I) as distinct commands; folder navigation (Cmd+[ /
Cmd+], Up/Down, expand/collapse); Copy/Paste projects (Cmd+C/V); Rename,
Duplicate, Delete. **Command Search:** X or Cmd+F opens a
fuzzy launcher ("p3" → "Add Plane - 3 Points", "snu" → "Scale - Non-uniform");
arrows cycle, Enter runs, recents shown when empty; pre-selection scopes
results.
**Status:** ❌ not implemented — no keyboard handling, no command search.
(Undo/Redo exist as toolbar buttons only.)
**Feasibility:** [mesh-kernel OK]

---

# 9. Adaptive UI & tool access

### 9.1 Adaptive (selection-based) menu

**Spec:** Pre-select elements → the adaptive menu recommends valid tools,
updating as the selection grows. Canonical mappings: face → Offset Face;
sketch profile → Extrude; body → Move/Rotate (gizmo appears immediately);
sketch line/curve → Sketch mode; line+face → Rotate Around Axis; profile+axis
→ Revolve; two faces of different bodies → Align / Replace Face. "More"
reveals additional valid tools. Many tools commit without Done: tap an empty
area of the grid.
**Status:** 🟡 partial (borderline — kept only for the wired conventions,
which are the same behaviors already counted under §4.1, §5.1, and §8.1): no
suggestion menu or "More" overflow exists anywhere, and the item's core
deliverable — a menu recommending valid tools — is 0% present. The credited
conventions: selecting a profile fill jumps into Extrude, a selected body
immediately shows the move gizmo, tapping the grid commits a profile extrude
(face pulls invert this — see §4.1). The only genuinely selection-adaptive
UI is the contextual `NumericInputBar`, the mode-dependent status pill
(`EditorView`), and selection-conditional button disabling in
`ToolPaletteView`. Missing: the actual suggestion menu, the More overflow,
every unimplemented tool mapping.
**Feasibility:** [mesh-kernel OK]

### 9.2 Main menu, modes area, context menus

**Spec:** Left main menu: Search, Sketch, Insert, Construct, Transform, Tools
(icons; labels per setting; interface side swappable Left/Right for
left-handed use). Modes cluster (bottom-left): Section View, Isolate, Measure
toggles adapting to selection. Right-click context menus everywhere (Isolate,
Zoom to Selection, Reveal in Items, Select Through, sketch-tool options).
Desktop menu bar File/Edit/View/Help (+ Sketch/Add/Transform/Tools on macOS).
Top bar: back, project name + sync, undo/redo, Share, More (Import/Export/
Settings).
**Status:** 🟡 partial — a floating left palette exists with Sketch
(Line/Rect/Circle/Arc/Ellipse/Polygon/Trim), Combine (booleans), Transform
(Scale/Mirror), and Edit (Measure/Delete) sections (`ToolPaletteView`), plus
a top status pill for mode prompts and a navigation toolbar
(undo/redo/fit/Views/Items/Import/Export). Missing: the real menu taxonomy,
modes cluster, context menus, command search, Share/More menus.
**Feasibility:** [mesh-kernel OK]

---

# 10. Design History & parametrics

### 10.1 History sidebar (feature tree)

**Spec:** Every edit records a step; each step is an expandable card exposing
its parameters (Extrude distance, Fillet radius, boolean Type, target/tool
lists, Subtract-From scope…) editable retroactively — the whole downstream
history rebuilds automatically, live-previewing while dragging (spline drag →
loft updates). Steps can be REORDERED by dragging (order matters — moving a
fillet before a shell changes the wall; bad orders produce per-step errors).
Step menu: Insert Breakpoint (temporarily disables everything after; features
added while active are inserted at that point; removing rebuilds — and the
breakpoint bar is DRAGGABLE up/down the history tree to scrub the rebuild
point: "drag the breakpoint back down to replay"), Suppress/
Unsuppress (removes from evaluation; downstream refs may error), Zoom To,
Rename, Duplicate, Delete. Deleting a BODY is itself a recorded step in the
feature tree (suppressible/deletable like any other). Selecting a body
filters History to related steps;
Isolate filters likewise. History > Merge flattens all steps (options: keep/
delete sketches, keep/delete variables; irreversible after quitting). With the
sidebar closed the app behaves as a pure direct-modeling tool, but steps still
record in the background.

**Recording semantics:** sketch edits are NOT recorded as history steps,
while direct edits ARE appended; editing an existing step's parameters
leaves no new record (in-place parametric edit). Deleting a body from Items
adds a Delete step, whereas deleting the originating STEP from History is
the "correct" cleanup — which can itself trigger reference-loss errors
downstream (Quick concepts pt 3; Design History and importing).

**Error & repair UX:** a failing step shows an error badge (exclamation
mark) with a "Fix" action that highlights the stale references in YELLOW;
messages like "invalid selection — profile missing two references" name the
loss; deleting an originating step raises reference-loss errors in dependent
steps. Documented repair flows: remove the missing face from a Face Offset
selection; re-project a lost face, then re-reference the extrusion profile;
re-select the original face to fix a broken Shell (Action camera pts 2–3;
Floor fan).
**Status:** ✅ implemented (Phase D). A real parametric feature graph
(`FeatureGraph`/`FeatureNode`) with a History sidebar: editable parameters that
rebuild everything downstream, topological naming so a `FaceRef`/`EdgeRef`
re-resolves against rebuilt geometry, rollback marker, drag-reorder, suppress/
un-suppress, and per-node error badges. Covered by `FeatureGraphEvalTests`,
`HistoryPanelUITests`, `HistoryReorderUITests`.
**Missing:** feature grouping/folders, and renaming a node from the sidebar.

### 10.2 Direct modeling with model-aware dimensions

**Spec:** Faces are directly draggable without naming a tool; faces (or
Shift-selected face chains) can be deleted outright with automatic healing
(§4.16); dimension labels
show model-based totals (full cylinder height, wall thickness) so exact values
can be typed; sketches stay connected to bodies (editing a sketch dimension
updates the derived body); each direct edit records as a history step (users
delete them and edit the source feature instead, to keep history clean).
**Status:** 🟡 partial — direct face push/pull with automatic booleans works
(the flagship v0.2 feature); a numeric distance field exists during the pull.
Missing: model-aware total dimensions, sketch↔body connectivity (bodies are
baked meshes; source sketches don't drive them), history recording as
editable steps.
**Feasibility:** face push/pull [mesh-kernel OK]; connectivity
[needs history engine]

### 10.3 Undo/Redo

**Spec:** Full-length undo/redo queue for all actions; Cmd+Z / Shift+Cmd+Z;
three-finger swipes on iPad; Edit-menu + toolbar buttons.
**Status:** 🟡 partial — command-based undo/redo covers most operations
(add/delete/transform/boolean/extrude/sketch-entity/primitive) with
selection sanitization after history jumps
(`EditorViewModel.undo/redo/sanitizeAfterHistoryChange`). Three gaps against
"full-length … for all actions": (1) `UndoStack` caps history at 50 commands
and silently drops the oldest (`limit = 50`; `removeFirst` on overflow) —
not full-length; (2) creating the sketch container bypasses the command
stack (`EditorViewModel.beginSketch` appends the `Sketch` via the
non-undoable `session.preview` path), so undo can remove sketch entities but
never the sketch itself; (3) sanitization resets only
`.editingPrimitive`/`.selected` when their body is gone —
`.pickingBooleanTool` survives undo with a dead target ID (recoverable only
via Cancel). Gesture/keyboard bindings missing (buttons only) — noted under
§8.4.
**Feasibility:** [mesh-kernel OK]

---

# 11. Items Manager

**Spec:** Sidebar listing every item — Body, Sketch, Construction plane/axis,
Mesh, Image, Folder — with type icons; adjustable width; filter dropdown by
type; row selection feeds the adaptive menu; Ctrl/Cmd+click and Shift+click
multi-select. Per-row: Visibility eye toggle (sketches auto-hide after an
extrude consumes them; folder eye toggles all children), Rename (right-click /
tap-and-hold), Zoom To, Delete. Image rows expose an opacity percentage.
Folders: create from selection (button bottom-left), drag-and-drop to
organize, nested folders. "Reveal in Items" from the modeling space highlights
the item's row. Three-dots menu: Show Hidden Items, Invert All Item
Visibility. Names are shared with History (rename in one place updates both).
**Status:** 🟡 partial — an Items panel (toolbar "Items" button,
`ItemsPanelView`) lists bodies, sketches, construction planes, **images**,
and **symbols** with type icons; per row: visibility eye
(`SetItemVisibilityCommand`), inline rename (`RenameItemCommand`), delete,
tap-to-select, and Zoom To (camera fit to the item's AABB). DELIBERATE
deviation: consumed sketches are NOT auto-hidden on extrude (read as the
sketch vanishing — hide manually via the eye); re-opening a hidden sketch
for editing still un-hides it. `isHidden` persists. Missing: folders, filter dropdown,
multi-select, per-row image opacity percentage (opacity edits live in the
image bar), Reveal in Items, Show Hidden Items / Invert Visibility menu,
shared names with History (no history engine).
**Feasibility:** [mesh-kernel OK]

---

# 12. Import / Export

### 12.1 Import

**Spec:** Formats — 2D: DWG, DXF (lines, polylines, beziers, arcs, circles/
ellipses, polygons; annotations/layers/colors dropped). 3D: X_T/X_B
(Parasolid), STEP, IGES, STL (reference only), SHAPR, SLDPRT, SLDASM
(+ Enterprise: NX, CATIA, Creo, Solid Edge, JT). Images: PNG/JPG/PDF(1 page)/
TIFF/BMP/ICO/RAW/GIF. Limits: 1 km³ design space. Import Preferences (STEP/
IGES/CATIA/SolidWorks/Solid Edge): Simplify Geometry, Advanced Healing
(Parasolid Bodyshop), Healing (HOOPS), Accurate Edge Computation, Sewing,
Import Planar Curves as Sketches. .shapr imports keep editable per-feature
history; all other formats arrive as a single Import history step. STEP
assembly hierarchy → nested folders. Mesh rules: booleans work only on closed
mesh bodies; any boolean involving a mesh yields a mesh.
**Status:** 🟡 partial. **STEP import now ships** (`OCCTKernel.readSTEP`,
OCCT DataExchange) — each solid in the file becomes a body carrying its
analytic B-rep, so imported geometry is exact rather than tessellated. Also
toolbar Import menu: **OBJ** (`OBJImporter` — the read half of `OBJExporter`,
so an export/edit-elsewhere/re-import round trip returns the same volume and
bounds; `o`/`g` groups import as separate bodies, polygon faces fan-
triangulate, and `v/vt/vn`, `v//vn`, and negative indices all parse, with
normals recomputed from winding rather than trusted), STL (binary or ASCII, parsed
and welded into a solid mesh body — `STLImporter` → `EuclidBridge` weld path
→ `AddBodyCommand`; imported bodies boolean like any native body since
everything is a mesh here), DXF (R12/R2000-common subset — LINE, CIRCLE,
ARC, LW/POLYLINE — landing in a ground-plane sketch as one undo step,
`DXFKit.importDXF`), and reference images (PNG/JPEG via Photos or
Files, §6.3). Missing: every other format, unit options UI, import
preferences, assembly folders.
**Feasibility:** STL/OBJ/3MF/DXF [mesh-kernel OK]; STEP/IGES
[needs B-rep kernel] (OpenCASCADE); X_T/X_B, SLDPRT/SLDASM, CATIA/NX/Creo/
Solid Edge/JT — commercial-licensed formats, see IMPLEMENTATION_PLAN;
images [mesh-kernel OK]

### 12.2 Export

**Spec:** Formats — 3D: SHAPR, X_T/X_B, STEP (AP203/AP214/AP242, ASCII/
binary), IGES, 3MF, STL, OBJ (with colors), GLB, USDZ; 2D: DWG, DXF, SVG,
PDF, JPEG, PNG; Slicer (by Prusa) hand-off (EasyPrint browser / PrusaSlicer
desktop; Resolution Low/High/Custom, Include Mesh Bodies default ON, Include
Hidden Items default OFF, file name). Export options: file name, format
sub-options, Include Dimensions / Hidden Items / Mesh Bodies / Hidden
Sketches / Vertex Colors, Compress Geometries/Textures, Resolution with custom
deviation + angle tolerances, Save Each First-Level Item Separately (ZIP),
Save Each Sketch Plane Separately (ZIP), Units (mm/cm/m/in/ft — STL is
unitless so the unit is declared at export). Favorite formats (star) persist;
batch export multiple formats; isolated parts exportable in any type except
.shapr. Screenshot tool: grid on/off, transparency, body edges, item chooser,
resolution Actual/Double/FullHD/4K/8K, remembers settings, clipboard shortcut.
**Status:** 🟡 partial. **STEP (AP214) export now ships** via OCCT
DataExchange (`OCCTKernel.writeSTEP`) — unlike every mesh format below it
carries the EXACT B-rep, so analytic surfaces survive into other CAD
(`OCCTKernelTests.testSTEPRoundTripPreservesAnalyticTopology` round-trips a
filleted cylinder with its cylindrical/torus/planar faces intact). Mesh
formats, toolbar Export menu (1 unit = 1 mm): STL (binary,
`STLExporter`), OBJ (`OBJExporter`), 3MF (`ThreeMFExporter`, zip + XML),
**GLB** (`GLBExporter`, glTF 2.0 binary, one node/mesh per body), **USDZ**
via ModelIO where the platform can write it (`USDZExporter`; the menu entry
is hidden elsewhere, never faked), and **DXF** of the active/ground sketch
(`DXFKit`, R12 ASCII). OBJ and GLB open an options sheet with a "Separate
File per Body" split (per-item files). Plus a **PNG screenshot** entry with
an options sheet: resolution multiplier, transparent background, and grid
on/off (offscreen renderer capture). Missing: SHAPR/X_T/STEP/IGES, DWG/SVG/
PDF, unit options, hidden-item filtering, vertex colors, favorites/batch,
slicer hand-off.
**Feasibility:** OBJ/3MF/GLB/USDZ/PNG [mesh-kernel OK]; STEP/IGES
[needs B-rep kernel]; X_T/X_B commercial; DWG via licensed libs (DXF/SVG
[mesh-kernel OK])

---

# 13. Projects, Sync & Collaboration

### 13.1 Dashboard & project management

**Spec:** Dashboard = default screen: team switcher (subscription type,
settings, logout), Invite Members, live project search, Recents (+ What's
New), Shared with Me, Published Versions page (copy/open/unpublish links),
Drafts (personal, device-sync only), Spaces (team-shared areas with folders),
Learn hub. Project tiles: thumbnail, title, last-edited-by, storage-state
icon. Context menu: Open, Rename, Duplicate, Manage storage, Show Versions,
Export, Delete (cloud-wide, unrecoverable), Quick Export to Favorite Formats
(batch), Save as .shapr. Folders with drag-and-drop, breadcrumbs, sort by
name/date. One-person-at-a-time editing guidance.
**Status:** 🟡 partial — a project gallery exists: grid of cards with rendered
thumbnails, create, open, rename (alert), duplicate (with bodies/sketches/
thumbnail), delete (`ProjectGalleryView`, SwiftData persistence, debounced
autosave in `DocumentSession`). Missing: search, sort, folders, recents,
teams/spaces/drafts, storage states, everything cloud.
**Feasibility:** local features [mesh-kernel OK]; teams/spaces
[platform/service]

### 13.2 Shapr3D Sync / cloud backup

**Spec:** Projects sync to the account across devices; per-project storage
states Local only | Synced | Cloud only; Download Now / Remove Download;
offline-first everywhere; deletion propagates to all devices.
Platform/account constraints: account SIGNUP is required before use; a
3-DEVICE limit auto-logs-out the device with the oldest login; explicit
online-required actions — download, update, Sync, in-app web links,
import/export to external cloud services — versus modeling, which works
fully offline.
**Status:** ❌ not implemented (local SwiftData only).
**Feasibility:** [platform/service] (CloudKit fallback)

### 13.3 Project Versions

**Spec:** Auto-tracked versions per project; browse with metadata (version #,
"Copy of", edited-by, created, synced, client); "Restore as Latest".
**Status:** ❌ not implemented.
**Feasibility:** [platform/service] (local snapshots feasible without cloud)

### 13.4 Sharing & Published Versions

**Spec:** Share dialog: move to Space, copy link, invite emails as
commenter/viewer. Published Versions: browser-viewable 3D/2D snapshot links
(no install), audience control (anyone/invited/team; Viewer|Commenter),
optional PASSWORD protection on shared Webviewer links (Quad Bike; Rhino
workflow), Include Visualization Materials / 2D Drawings toggles, anchored
comments, PDF download for drawings, Publish Changes / Unpublish, requires
Sync.
**Status:** ❌ not implemented.
**Feasibility:** [platform/service]

### 13.5 Augmented Reality & Vision Pro

**Spec:** iPad in-app AR (Visualization AR button or USDZ export "Preview in
Augmented Reality"): camera placement, move/scale gestures, Object tab,
shutter capture to gallery. Published-Version links open in AR on phones (QR
hand-off from desktop). Third-party via USDZ (Quick Look) or 3MF (no
materials). Vision Pro immersive review is Enterprise-only.
**Status:** 🟡 partial — "AR Preview" in the Export menu writes a temp USDZ
and presents it in QuickLook's AR viewer (`ARQuickLookView`), on platforms
where ModelIO can write USDZ (entry hidden elsewhere). Missing: in-app AR
placement/capture UI, shared-link AR, Vision Pro.
**Feasibility:** USDZ + QuickLook AR [mesh-kernel OK] (ModelIO/RealityKit);
shared-link AR [platform/service]

**Note — subscription plan gating (deliberate scope cut):** Shapr3D gates
behavior by plan: Basic is limited to 2 projects and export to
low-resolution STL/3MF only; Pro unlocks custom mesh export tolerance;
advanced import formats (NX/CATIA/Creo/Solid Edge/JT) and Vision Pro review
are Enterprise-only. openshape3d implements NO plan gating — every
implemented feature is unconditionally available — so gated limits are
recorded here only to explain corpus workflows, not as product logic to
clone. (Stated explicitly so the omission reads as a decision, not an
oversight.)

---

# 14. Visualization

**Spec:** A separate space (Project Sidebar > Visualization, Tools >
Visualize, or adaptive menu) with real-time rendering. **Materials:** 100+
library entries, category dropdown + instant search, drag-and-drop onto body
or apply to face/body selection, Used Materials list, reset-to-default
(right-click / swipe-left), properties per material: Transmission, IOR, Scale,
Roughness, Auto Match to Body (orientation-aware mapping) vs XYZ-fixed,
Rotate X/Y/Z, color (hex input, Pick Face Color eyedropper, swatches,
Default Body Color), Opacity (modeling-space transparency instead via Utility
materials). Emission materials produce a light-bloom GLOW (Floor fan button
icons). Materials apply per body or per FACE; a body carrying face-level
overrides shows a "multiple materials selected" indicator. **Decals:** import images, drag to place; Scale/Rotate/Opacity/
Wrap adjacent faces/Cylindrical projection. **Custom materials:** import .GLB
(materials only, geometry ignored; per-project, synced, not cross-project).
**Environment:** library + Light Rotation, Sun Elevation, Light Intensity,
Ground Plane (Snap to Model | XY Plane), background color incl. a
TRANSPARENT-background option. **Camera:** focus
point (right-click Set as Focus Point / tap; tap outside removes), Field of
View, Aperture, Blur Intensity (depth of field). **Sharing:** Capture tool
(clean high-res image, no grid/UI), textured USDZ export, AR button,
Generative Render (AI enhancement of a capture; prompt → Generate → Save;
plan-gated, daily limit, requires Sync).
**Status:** 🟡 partial (visualization-lite, no separate space) — a palette
Material button on the selected body/multi-selection opens a Material sheet:
a small preset library (Steel, Aluminum, Brass, Plastic Matte/Gloss, Rubber,
Wood) plus a custom color picker and metallic/roughness sliders, applied per
body as one undoable `SetMaterialCommand` and persisted
(`BodyMaterialSpec`); the renderer blends the metallic/roughness factors
into its Blinn-Phong shading, and a Views-menu **Ground Shadow** toggle
draws cheap planar blob shadows. Missing: a real PBR/IBL pipeline,
environments, per-FACE materials, decals, emission/glow, DoF, Capture,
material search/library breadth, Generative Render.
**Feasibility:** PBR space, materials, decals, environments, DoF, capture
[mesh-kernel OK] (pure Metal renderer work); the material *library content*
itself is an asset-sourcing problem; Generative Render [platform/service]

---

# 15. Drawings (2D)

**Spec:** Project Sidebar > Drawings > Create Drawing → select body → Drawing
Preferences (title, sheet size portrait/landscape, ISO/ANSI, view-to-sheet
scale, "Include 4 Views" = front base + left/top/isometric projections) →
sheet generated. Multi-body/subassembly drawings: select MULTIPLE bodies to
draw them together. Alternate entry points: File > New Drawing; double-click
a part in the sidebar > Create Drawing. Views: Base (7 orientations + custom projection angle,
choose bodies), Projection (auto-aligned to base; move together), Section
(place a section line on reference points; drag the arrow to place the view),
Detail (draw a circle around an area → magnified view; own scale/hidden-line
settings). Title block layouts: Simple, Empty Sheet, Border Only, Horizontal,
Vertical, Block, Block with Table; fields auto-fill and are editable.
Dimensions: adaptive auto-dimension on select; Line Length, Point-to-Point,
Point-to-Line, Line-to-Line, Arc Angle, 3-Point Angle, Line-to-Line Angle,
Radius, Diameter, Min-Max Distance; Point-to-Point dimensions carry an
ORIENTATION badge (horizontal | vertical | absolute) with re-placement;
snap-equal placement increments; editor
badge for Prefix/Suffix text and Tolerances (Symmetrical, Deviation, Limits,
Basic); precision via Properties. Geometries: Centerlines (2-Point, 2-Line,
3-Point Circular, 3-Point) — centerlines can SPAN multiple aligned views —
Center Mark, Intersection Mark. Notes (leader or
free, 1200 chars), images. Per-sheet properties: projection angle first/third,
units/precision/decimal separator, line widths per class. Hidden-line toggle
per view; Cmd+R updates the drawing from the model.
**Status:** ❌ not implemented.
**Feasibility:** [mesh-kernel OK] for a first version (orthographic
projection + silhouette/hidden-line from meshes; associativity with the model
[needs history engine]; production-grade HLR quality benefits from a B-rep
kernel)

---

# 16. Modes (Section View, Isolate, Measure) & Display

### 16.1 Section View

**Spec:** Cuts the model along a selected plane/planar face (select plane then
toggle, or toggle then select). Gizmo on the plane: drag arrows deeper/
shallower, rotate handles to tilt, Flip badge switches the visible side.
Options: 2D Section View (cross-section + background edges, orthographic;
"Normal to Section" button realigns), Section Only (hide the rest).
Cross-sections render with fill patterns and per-body colors — the
randomized section fill colors apply only to bodies still using the DEFAULT
body color (custom-colored bodies keep their own color). While sectioned:
sketch on the datum plane, measure internal features, select/edit inside —
with the documented caveat that moving/adjusting the section plane prevents
further sketching on the updated cut. Interference highlighting:
overlapping/interpenetrating bodies render RED while sectioned, and
scrubbing the plane across the model serves as a collision-verification
pass — the red disappears once clearance is achieved (Interference
analysis; Wall Clock pt 2). Saved Views can store a section.
**Status:** 🟡 partial — Views → Section arms a plane pick (world +
construction plane tiles); the chosen plane clips the lit, edge, fill, and
sketch-line shaders (`SectionPlaneState` → per-fragment discard), with a
drag arrow to move the plane along its normal and Flip / Section Off
badges (also mirrored in the Views menu). Cut faces are left OPEN (no cap
fills), interior back faces render shaded. Missing: caps with per-body
section colors, rotate/tilt handles, 2D Section View, Section Only,
interference highlighting, sketch-on-datum while sectioned, Saved Views.
**Feasibility:** [mesh-kernel OK] (clip plane + cap rendering in the Metal
renderer)

### 16.2 Isolate

**Spec:** Select item(s) → Isolate hides everything else; toggle off to
restore. Also filters History to the isolated items.
**Status:** 🟡 partial — Views → Isolate hides everything but the current
selection (per-item hidden override, no document mutation); Exit Isolate
restores the previous visibility. Missing: History filtering (no history
engine).
**Feasibility:** [mesh-kernel OK]

### 16.3 Measure

**Spec:** Measure mode opens a movable panel; selection info also shows at the
screen bottom without the mode. Data by selection: length (sum), area (sum),
volume (sum), radius/diameter (arc/circle/sphere/cone/cylinder), angle,
perpendicular angle, minimum distance, central distance (center of gravity for
bodies), parallel distance (incl. radial difference of concentric items),
X/Y/Z per-axis distances. Types: Object Measurements, Point-to-Point (notable
points; placed points movable), 3-Point Angle; optional X/Y/Z deltas; Pin to
Always Show keeps measurements as in-model annotations (appearance toggle);
hover a panel row to highlight the referenced geometry. Shift-click two faces
for a quick face-to-face distance.
**Status:** 🟡 partial — a selection info bar shows without any mode
(`SelectionInfoBar` + `MeasureKit`): face area, body volume
(signed-tetrahedron sum) + bounding box, sketch-entity length and
radius/diameter; and a palette Measure mode measures point-to-point
distance with X/Y/Z deltas over notable points (sketch snap points + body
vertices, cross markers + span line rendered in the overlay). Missing: the
movable panel, angle/min-distance/central-distance types, pinned
measurements, row-hover highlighting.
**Feasibility:** [mesh-kernel OK]

### 16.4 Display Modes

**Spec:** Toolbar menu; active shader labeled. Shaders: Wireframe, X-Ray
(semi-transparent), Shaded (default), Visualized (enhanced edges/silhouettes +
shadows). Surface Analysis: Zebra (continuity, Direction H/V, Scale),
Curvature Map (color gradient, Scale). Options: Show Edges, Show Hidden Edges
(see and select occluded edges).
**Status:** 🟡 partial — a Views → Display submenu (labeled with the active
shader) switches between **Shaded** (lit fill + feature edges, the
default), **Shaded (No Edges)**, **Wireframe** (feature edges over a
depth-only prepass so hidden lines stay hidden), and **X-Ray** (translucent
fill, depth-read/no-write), plus a **Show Hidden Edges** toggle (extra
low-alpha edge pass with a reversed depth test — occluded edges render
faintly). Bodies stay selectable in every mode. Missing: Visualized mode,
Zebra/Curvature surface analysis.
**Feasibility:** [mesh-kernel OK]

---

# 17. Settings / Preferences

**Spec:** Account (email, logout, subscription); General: Language (11
localizations), Theme System/Light/Dark, menu-label display, accent color,
Interface Left/Right (iPad), Single Key Action, keyboard-shortcut
customization, Undo/Redo Button Position, Circular Annotations Always Radius
| Radius and Diameter; Sketching: default Spline point type (Fit | Control),
Apple Pencil pressure preferences;
Import: advanced-preferences prompt toggle; Graphics: rendering quality,
Anti-Aliasing (Disabled | 2x | 4x MSAA),
tessellation quality Very High/High/Low (affects display + export meshes);
Navigation: presets, 2-Finger Rotation, zoom direction, start screen
(SpaceMouse settings live under Views — §7.5); Tutorial
mode (show touches/keys); Sync status + manual sync; About (version, terms,
usage-data opt-out); Account deletion. Units: mm/cm/m/in/ft; angle decimal or
fractional.
**Status:** ❌ not implemented — no settings surface at all.
**Feasibility:** app-local settings [mesh-kernel OK]; account/sync sections
[platform/service]

---

# 18. Numeric input & gizmo conventions (cross-cutting)

**Spec:** Any parameter label opens an input field (hover-and-type on
desktop; tap → numpad/calculator with check mark on touch — dimension boxes
open a pop-up calculator UI). Inline arithmetic
with + − × ÷ evaluates on Enter ("10+5" → 15; "x4" multiplies an angle);
period as decimal separator (comma errors). The input field also works as a
RUNNING-TOTAL calculator, summing successive entries (Staircase). Unit
suffixes and mixed units can be typed directly in fields ("25.4*5",
"1/20 m + (1/3) cm"). Tab cycles to the NEXT dimension field mid-creation
(rectangle width → Tab → height; pattern spacing → Tab → quantity). Gizmo
dimension labels accept the same input. Tool commit convention: tap empty
grid area = Done for adaptive-invoked tools.

**Operation-validity feedback (cross-cutting):** while dragging, tool arrows
render BLUE when the result is valid and turn RED when invalid, with a
top-of-screen failure banner ("the operation failed because the resulting
body wouldn't be valid"); a fillet drag stops at — and thereby reveals — the
maximum possible radius; failed fillets suggest "try adding more edges" as
the recovery (Primary and secondary fillets). Applies across Shell, Fillet,
Offset Face, and the boolean tools.
**Status:** 🟡 partial — numeric fields exist for extrude distance, revolve
angle, offset-plane distance, exact gizmo-arrow moves ("Move X/Y/Z"), scale
factor, and polygon side count (`NumericInputBar`); the primitive W/D/H
fields remain DEAD UI outside the `OS3D_DEBUG_SEED` hook. The
commit-on-empty-tap convention is unified: tapping empty grid commits both
profile extrudes and nonzero face pulls (§4.1). The validity-feedback layer
is seeded: the pull arrow renders RED when the pending extrude/revolve
result would fail (`ToolContext.isPendingValid` → `GizmoRenderer`), with
failures surfaced via an error alert (not yet a top banner). Missing:
calculator/expression parsing, numpad UI, hover-to-type, Tab cycling,
running totals, unit suffixes, labels on gizmo arrows and sketch elements.
**Feasibility:** [mesh-kernel OK]

---

# Status summary

| Area | ✅ | 🟡 | ❌ |
|---|---|---|---|
| Sketch menu (17) | 2 (Trim, Delete) | 13 (Line, Arc, Rectangle, Circle, Ellipse, Polygon, Offset Edge, Move/Rotate, Pattern, Text, Project, Symbol, Helix) | 2 (auto pen mode, Spline) |
| Sketch controls (7) | 0 | 3 (planes, snapping, notable points) | 4 |
| Constraints (14: menu, settings, 11 types, make-construction) | 1 (Make Construction) | 0 | 13 |
| Tools menu (16) | 0 | 9 (Extrude, Offset Face, Loft, Union, Subtract, Intersect, Split, Revolve, Sweep) | 7 |
| Transform (7) | 0 | 7 (all: gizmo, Translate, Rotate Around Axis, Scale, Align, Mirror, Pattern) | 0 |
| Insert/Construct (6) | 0 | 2 (Offset construction plane, Insert Image) | 4 |
| Navigation & views (5) | 0 | 4 (camera, Orientation Cube, views panel, grid) | 1 (peripherals) |
| Selection & gestures (4) | 0 | 3 (core selection, area select, Select Through) | 1 (keyboard/Command Search) |
| Adaptive UI (2) | 0 | 2 | 0 |
| History & parametrics (3) | 0 | 2 (direct modeling, Undo/Redo) | 1 |
| Items Manager (1) | 0 | 1 | 0 |
| Import/Export (2) | 0 | 2 (STL/DXF/image import; STL/OBJ/3MF/GLB/USDZ/DXF/PNG export) | 0 |
| Projects/Sync/Collab (5) | 0 | 2 (local gallery, AR Quick Look preview) | 3 |
| Visualization (1) | 0 | 1 (materials-lite, ground shadow) | 0 |
| Drawings (1) | 0 | 0 | 1 |
| Modes & display (4) | 0 | 4 (Section, Isolate, Measure, display modes) | 0 |
| Settings (1) | 0 | 0 | 1 |
| Numeric input (1) | 0 | 1 | 0 |
| **Total (97)** | **3** | **56** | **38** |

(Counting caveats: §4.2's 🟡 rides the same code path as §4.1 — one behavior
counted under two Tools-menu entries; §9.1 remains a borderline partial,
flagged in its status note.)

The center of gravity of the gap: (a) the constraint solver, (b) the history
engine, (c) B-rep-only surface operations (fillet/chamfer/shell/offset-face/
replace-face), and (d) the remaining breadth: splines, construction axes,
keyboard shortcuts + Command Search, drawings, settings, and the
sync/sharing services. See `IMPLEMENTATION_PLAN.md` for sequencing.
