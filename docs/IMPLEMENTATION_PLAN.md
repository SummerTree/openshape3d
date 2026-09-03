# Implementation Plan — Maximizing the reference app Parity

Companion to `PARITY_SPEC.md`. Phases are ordered by (1) what the
current Euclid mesh kernel can honestly deliver, (2) prominence in the reference app's
own tutorials/manual (what users hit in the first hour), and (3) dependency
order — the constraint solver and history engine each unlock a whole tier of
features and must land before the features that ride on them.

**Architecture rule that makes all of this tractable:** every geometry
operation goes through the `KernelOps` facade, every mutation through a
`DocumentCommand`, and the viewport never mutates the model
(`EditorViewModel` is the single state machine). Each phase below extends
those three seams rather than adding new ones.

---

## Phase A — Next tranche (mesh-kernel feasible, highest tutorial prominence)

Everything in this phase is `[mesh-kernel OK]`, needs no solver/history/B-rep,
and appears in the first two the reference app tutorial series ("Solid modeling
basics", "3D modeling fundamentals"). Ordering within the phase is the
suggested build order; A1–A3 unblock A4–A6.

### A1. Sketch planes: world planes, offset planes, sketch-on-face

The single biggest workflow unlock — every tutorial starts with "select a
plane or a face, then sketch". `SketchPlane` already supports arbitrary
origin/basis; only the ground plane is ever created today
(`EditorViewModel.startSketch` hardcodes `.ground`).

- Replace `startSketch(tool:)`'s ground-plane branch with a
  `pendingSketchPlane: SketchPlane?` chosen before/at sketch entry:
  - **World-plane pickers:** when Sketch is tapped with no plane, render three
    small plane rectangles at the origin (add a `planePickers` array to
    `ViewportScene`; draw in `GizmoRenderer`'s overlay pass). Tap → build the
    XY/YZ/ZX `SketchPlane`, animate head-on via the existing
    `ViewportCameraControl.moveCameraHeadOn(to:)`.
  - **Sketch-on-face:** in `selectFaceOrBody`, we already compute a full face
    basis (`FaceTopology.planarFace` → origin/basisX/basisY → `SketchPlane`)
    for the extrude context. Add "Sketch" to the face-selected UI; reuse that
    exact plane, offset by the body transform (code already exists in the
    face-pull path).
  - **Offset construction plane:** new `ConstructionPlane` value in
    `DesignDocument` (id, `SketchPlane`, display size) + `AddConstructionPlaneCommand`;
    creation UI = select world plane/face → "Offset Plane" → drag arrow or type
    distance (reuse the pull-arrow + `NumericInputBar` pattern from Extrude).
- Sketch bookkeeping: `startSketch` finds-or-creates a `Sketch` whose `plane`
  matches (same rule the reference app uses: continuing on the same plane immediately
  edits the same sketch item).
- Persistence: `ConstructionPlane` is Codable → new `PersistedPlane` SwiftData
  model beside `PersistedSketch`.
- Remaining plane types (Midplane, Through Edge at Angle, Parallel to Face at
  Point, Perpendicular to Edge, 3 Points, Along Spline, Mirrored — spec §6.1,
  each with an editable Size) and the five construction-axis tools (Cylinder/
  Cone, Through 2 Points, Through 2 Planes, Along Edge, Perpendicular to Face
  at Point — spec §6.2, with Length param) follow in Phase B; their per-type
  history params (Face/Point #1–3/Edge/Angle/Length) arrive with Phase D.

### A2. Sketch tool breadth: Arc, Ellipse, Polygon, rectangle types, polyline chaining

- Extend `SketchEntity` with:
  `arc(id:center:radius:startAngle:endAngle:)`,
  `ellipse(id:center:majorAxis:minorRadiusRatio:)` (or center + two radii +
  rotation), `polygon(id:center:radius:sides:rotation:)`; keep `rect` but add
  `rotation` + a `kind` (center/diagonal/threePoint) so anchor semantics match
  the spec. Codable additions are backward-compatible with persisted sketches.
- `SketchTessellator.segments(for:on:)`: tessellate arcs/ellipses/polygons to
  polylines (reuse `ProfileDetector.circleSegments` density).
- `ProfileDetector`: treat arc entities as polyline chains whose endpoints
  participate in `lineLoops` node-walking (tessellated interior points are
  never junction nodes); ellipses/polygons emit closed loops directly like
  circles/rects today.
- Arc interaction (touch-first, per spec): drag places the two endpoints,
  second drag on the pending arc adjusts bulge; or three-tap flow
  (end, end, bulge) matching the desktop click-click-drag-click.
- Line tool: keep drag-to-draw, add chain continuation — after `endSketchStroke`,
  if the release point is not a closure, keep a `chainAnchor` so the next
  stroke pre-anchors at the previous endpoint; auto-finish the chain when a
  stroke snaps onto the chain's first point (close the loop, clear anchor).
- `SnapEngine`: add line midpoints, arc endpoints/centers, and entity–entity
  intersection points to `snapPoints(of:)` (notable-points spec §2.7).
- Apple Pencil: the one-finger drag recognizer accepts `.direct` touches only
  (`ViewportGestureController` line 42), so the Pencil currently cannot draw
  at all — it can only tap. Allow `.pencil` on the sketch-drag path (keep
  pencil-never-orbits per spec §7.1) — prerequisite for the Line/Arc
  automatic pen mode (spec §1.2).

### A3. Sketch element selection, drag-editing, Delete, Trim

Prerequisite for every "edit the sketch" tutorial moment.

- New mode payload: `case sketchSelecting(SketchID, selected: Set<UUID>)` or a
  `selectedEntityIDs` set alongside `.sketching`. Hit-test entities by
  distance-to-segment in plane space (new `SketchHitTester` in `Interaction/`).
- Drag endpoints/entities: `UpdateSketchEntityCommand` (before/after entity
  snapshots) with `session.amend` coalescing during the drag — same pattern as
  `TransformBodiesCommand` + `preview`.
- Delete: `RemoveSketchEntitiesCommand`; hook the existing palette Delete
  button when in sketch mode.
- **Trim:** compute intersections among tessellated entities, split the tapped
  entity at the two intersections bounding the tap parameter, delete that
  span (lines split exactly; arcs split by angle). One `TrimCommand` =
  replace-entity-with-fragments. This also fixes the current limitation that
  loops only close on exact shared endpoints.

### A4. Revolve

The #2 modeling tool in every tutorial (bottles, shafts, caps).

- `KernelOps.revolve(profile:holes:in:axis:angle:) -> Euclid.Mesh`:
  map the profile into a `Euclid.Path` in a plane containing the axis, use
  `Euclid.Mesh.lathe(_:slices:)` for 360°; for partial angles build the wedge
  manually (rotate profile copies by angle steps and stitch, or lathe ∩ wedge
  solid). Validate profile does not cross the axis (the reference app errors there too).
- Interaction: select a profile fill + tap a line entity (the axis; also allow
  world axes). Reuse `ExtrudeContext` shape: a `RevolveContext` with angle
  instead of distance, same preview-body pipeline
  (`rebuildExtrudePreview` generalizes to `rebuildToolPreview`).
- Automatic booleans on commit: reuse the candidate-scan in `commitExtrude`
  (factor it into `commitToolResult(mesh:sourceBody:)`).
- UI: "Revolve" appears in the palette when profile+axis are selected
  (first real adaptive-menu behavior), numeric angle field in
  `NumericInputBar` (default 360).

### A5. Extrude completion: boolean badge, symmetric, multi-profile

- **Boolean badge:** add `booleanOverride: BooleanKind?/newBody` to
  `ExtrudeContext`; a small segmented badge near the pull arrow (SwiftUI
  overlay positioned by projecting the arrow tip — add a
  `screenAnchor(for:)` helper on the coordinator). `commitExtrude` honors the
  override instead of the sample-point test; adds the missing manual
  **Intersect** and **New Body** results.
- **Symmetric sides:** `sides: .oneSided | .symmetric` in the context;
  `KernelOps.extrude` gains a `symmetric:` flag (center the solid on the
  plane instead of one-sided shift — it already computes the offset).
- **Multi-profile:** allow tapping additional fills while in `.extruding`;
  context holds `[Profile]`; union the per-profile solids before the boolean.
- **Cut scope:** when a cut intersects multiple bodies, apply to all
  intersected bodies (current code stops at the first candidate) and surface
  a per-body include/exclude list in the extrude bar — the mesh-level
  equivalent of the reference app's "Subtract From" scope.
- **Commit convention:** profile extrudes commit on ANY tap while face pulls
  cancel on empty tap (committing via the extrude bar's button, the distance
  field's onSubmit, or the Done pill). Unify on the spec's rule — tapping
  empty grid commits both (spec §4.1/§18).
- **Symmetric per-side semantics:** entering 60 mm symmetric yields 120 mm
  total (spec §4.1); Union target-list behavior (empty selection must not
  silently fail to merge) and drag-arrow-onto-face To Object attachment ride
  the extents work.
- **Operation-validity feedback (cross-cutting, spec §18):** while dragging,
  render the pull arrow BLUE when the pending result is valid and RED when
  the boolean/extrude would fail, plus a top-of-screen failure banner —
  seed the pattern here so Shell/Fillet (Phase E) inherit it.

### A6. Transform: rotation, scale, Copy badge, numeric gizmo entry

- `GizmoPart`: add `xRotation, yRotation, zRotation` ring parts;
  `GizmoGeometry.hitTest` gains ring capsule tests; `GizmoRenderer` draws the
  arcs (it already draws arrows + plane tiles).
- `GizmoDragSession`: add `rotationDelta(for:)` (project ray onto the ring
  plane, atan2 against the anchor). `EditorViewModel.updateMove` generalizes
  to `updateTransform(delta:)` mutating rotation via quaternion multiply;
  `TransformBodiesCommand` already round-trips full `Transform3D`.
- **Copy badge:** a toggle chip near the gizmo; when on, `beginMove` first
  performs `AddBodyCommand` with a cloned body (new `BodyID`, copied mesh —
  cheap, buffers are CoW) and drags the clone. Matches the tutorial "Copy →
  move up 1, down 1 to duplicate in place".
- **Numeric entry:** tapping an arrow (not dragging) opens the distance field
  in `NumericInputBar` for that axis; commit applies the exact delta.
- **Scale tool:** UI for the existing `Transform3D.scale` (uniform first),
  center defaulting to the body pivot; the spec's full shape (Uniform |
  Non-uniform Type menu, Copy badge, empty-grid commit — §5.4) lands with
  Phase B item 6.
- **Mirror (body):** `KernelOps.mirror(body:acrossPlane:)` = reflect mesh
  (negate across plane basis, flip winding) → `AddBodyCommand`/
  `ReplaceBodyCommand` with Keep Originals toggle. Selecting a construction
  plane (A1) surfaces Mirror — matches the tutorial flow.
- **Gizmo hover highlight:** add a `UIHoverGestureRecognizer`/pointer
  interaction that sets `gizmoHighlight` pre-drag — today the highlight is
  drag-feedback only (set at drag-begin, cleared at drag-end).

### A7. Orientation Cube, standard views, orthographic toggle

- New overlay: screen-corner cube rendered with its own tiny pass in
  `Renderer` (reuse gizmo pipeline), hit-test 6 faces + 8 corners + 12 edges
  in `HitTester`-style code; taps animate `TurntableCamera` azimuth/elevation
  through the existing `CameraAnimator`; double-tap = default view; drag on
  the cube = orbit.
- Standard views list (Top/Bottom/Front/Back/Right/Left + isometric reset) in
  a small Views popover; head-on view of a face plane already exists
  (`moveCameraHeadOn`).
- Orthographic: add `fovY → 0` support via an orthographic projection branch
  in `TurntableCamera.projectionMatrix` + a Views-panel FOV slider; "Normal
  to Sketch" button appears while sketching if the camera has been orbited.

### A8. Items Manager (v1)

- Add `isHidden: Bool` to `Body` and `Sketch` (+ persistence fields);
  `EditorViewModel.scene` skips hidden bodies/sketches; extrude auto-hides
  the consumed sketch (set `isHidden` in `commitExtrude` — the spec's
  "sketches auto-hide after being used").
- SwiftUI sidebar sheet/panel listing bodies, sketches, planes with type
  icons: eye toggle (`SetItemVisibilityCommand`), rename (inline text field →
  `RenameItemCommand`), delete, tap-to-select (drives `selection`), "Zoom to"
  (fit camera to that body's AABB — `Camera.fit` already exists).
- Folders deferred to Phase B (needs item-tree model).

### A9. Measure (v1) + selection info bar

- Bottom info strip on selection: face area (sum triangle areas ×
  `transform.scale²`), body volume (signed tetrahedron sum), edge length,
  bounding box; radius/diameter for circular sketch entities.
- Point-to-point mode: tap two notable points (A2's expanded `SnapEngine`
  points + body vertices from `FeatureEdges`), show distance + X/Y/Z deltas.
- Pinned measurements deferred until the annotation renderer exists.

### A10. Import STL, export OBJ/3MF, screenshot

- `STLImporter` in `Kernel/` (binary + ASCII) → `RenderMesh` via
  `EuclidBridge` weld path → `Body` (mesh body semantics: booleans already
  work since everything is a mesh here). Export unit option (mm default) on
  both import and export per the STL-units spec.
- `OBJExporter` (trivial from `RenderMesh`), `3MFExporter` (zip + XML —
  3D-print parity; the reference app preselects 3MF for printing), "save each body
  separately" toggle.
- Screenshot tool: the offscreen thumbnail path
  (`EditorViewModel.thumbnailProvider` → renderer offscreen capture) already
  renders the scene; add resolution options + transparent background +
  grid/edge toggles.

**Phase A exit criteria:** the reference app "Solid Modeling basics" tutorial
(sketch on plane → revolve → subtract → offset-edge wall → through-hole cut)
is reproducible except for constraints/dimensions and Offset Edge, and the
water-bottle "3D modeling fundamentals" flow works minus loft rails.

---

## Phase B — Mesh-kernel depth (remaining geometry that needs no solver/history/B-rep)

1. **Sweep** — `Euclid.Mesh.extrude(_:along:)` with the profile path mapped to
   the spine start; Mitre/Round corners, twist/scale along path as custom
   sweep math in `KernelOps.sweep`. Path = chained sketch entities or feature
   edges.
2. **Loft (profiles-only)** — `Euclid.Mesh.loft` over ordered profiles;
   planar body FACES accepted as profiles too (spec §4.5 — extract the face
   loop via `FaceTopology`); selection-order UI; Periodic/guide-curves and
   the draggable end continuity/bulge handles deferred (guides approximated
   in B2.5 by inserting intermediate interpolated sections; exact guide
   interpolation and G1/G2 end tangency are B-rep-tier).
3. **Split Body** — cutter construction: plane → big thin box half-space CSG
   (two subtracts to yield both halves); sketch profile → through-extruded
   cutter; own-face/other-face → face plane. Keep Originals toggle; multiple
   simultaneous cutters.
4. **Offset Edge (sketch + 3D single/chain)** — 2D polyline/arc offsetting
   with self-intersection cleanup; 3D variant creates the auto-sketch on the
   face plane (A1 machinery). Loop-arrow disambiguation per spec.
5. **Pattern (sketch + body, linear/circular)** — static instance generation
   with the full badge UI (Total/Spacing, Quantity, Uniform/Rotated, signed
   directions, center-node snapping). The 3D Linear pattern is a REAL pattern
   along one, two, or three axes (spec §5.7 — not Move+Copy repeats), incl.
   dragging the center handle onto a sketch line to pattern along an
   arbitrary direction; patterned bodies auto-group into an Items Manager
   folder (A8) with instances listed/selectable under the feature, and a
   pattern folder is usable as a one-click Subtract tool set. Scope rule per
   spec §4/§5.7: bodies and sketches only — no feature patterns, no swept
   cuts; the "pattern the tool bodies, then Subtract" workaround is the
   supported path. Also accepts SKETCH PROFILES patterned
   in 3D (spec §5.7), whole-pattern drag semantics, and first-instance
   snapping per spec §1.11 (constrain the FIRST copy, never the last).
   Instances are plain entities/bodies grouped under one command; live
   "pattern constraint" re-editing arrives with Phase C/D.
6. **Sketch Move/Rotate + Copy** (gizmo on sketch selections, connected-group
   double-tap via `ProfileDetector` adjacency), **Translate** (point-to-point
   snap move over grid/edges/vertices, with Copy — spec §5.2),
   **Rotate Around Axis** (select → Next → axis/line/edge → gizmo, 5° drag
   snaps with typed fine angles, Copy badge — spec §5.3), **Align**
   (purple snap-point dot-onto-dot mating, post-mate gizmo + Flip badge,
   likely-position snapping, cylindrical auto-collinear centering — spec
   §5.5), **Scale** completion (Uniform/Non-uniform modes, Copy badge,
   empty-grid commit — spec §5.4).
7. **Text tool** — Core Text `CGPath` glyph outlines → sketch line/arc/spline
   polylines on the target plane; dialog (content/font/height/alignment) →
   gizmo placement → profiles extrudable like any sketch.
8. **Project (unlinked sketch projection)** — flatten selected
   entities/edges/silhouettes onto a target plane along its normal; body →
   outline via mesh silhouette; re-running with the SAME target appends into
   the existing projection sketch, an unassigned target auto-binds to the
   next clicked candidate, and individual projected edges are deletable
   (spec §1.13); enables the CNC flat-layout workflow.
9. **Make Construction / Make Regular** — `isConstruction` flag on
   `SketchEntity`; dashed rendering in `SketchTessellator`; excluded from
   `ProfileDetector` loops; revolve-axis picking prefers construction lines.
10. **Insert Image** — textured quad item with opacity/scale/rotate gizmo,
    Items-Manager opacity; splitting-tool + tracing use cases.
11. **Section View** — clip-plane uniform in `Shaders.metal` (discard beyond
    plane) + stencil-based caps with per-body section colors (randomized
    colors only for bodies on the default body color, per spec §16.1); plane
    gizmo drag/rotate/flip; Section Only + 2D section options; interference
    highlighting — interpenetrating bodies render RED while sectioned so
    scrubbing the plane doubles as a collision check (spec §16.1).
12. **Display Modes** — Wireframe / X-Ray (alpha pass) / Shaded / Visualized
    variants in `PipelineStore`; Show Edges + Show Hidden Edges (edge pass
    with reversed depth test); Isolate mode (per-item hidden override set).
13. **Selection system** — area select with window/crossing semantics +
    B/F/E filters; overlapping-candidates popup; Select Through (ray
    `pickBody` returning all hits sorted by t); Shift multi-select; keyboard
    hotkeys + a Command Search palette (pure UI over a command registry),
    incl. the Space view shortcuts (hover-face zoom, sketch perpendicular
    view), Backspace last-point removal while drawing, and the Dashboard
    shortcut set (spec §8.4); plus the §18 numeric-input conventions — Tab
    cycling to the next dimension field mid-creation, running-total entry
    summing successive values, unit suffixes/mixed units typed directly
    ("25.4*5", "1/20 m + (1/3) cm"), pop-up calculator on dimension boxes.
14. **Export/import breadth** — GLB + USDZ (ModelIO/RealityKit → also gives
    Quick Look **AR preview** on iPad), DXF/SVG sketch export, PNG/JPEG
    image export with the screenshot options, DXF import (entities → sketch),
    per-format options sheet (units, hidden items, per-item files).
15. **Visualization space (v1)** — PBR pipeline (image-based lighting,
    roughness/metalness materials, environment presets, ground shadow),
    material assignment per body/face (face regions from `FaceTopology`,
    with a "multiple materials selected" indicator when a body carries
    face-level overrides), emission materials with light-bloom glow,
    transparent-background environment option (spec §14),
    camera DoF post-pass, Capture tool. Material *library* starts small and
    grows; decals/custom-GLB-materials later.
16. **Symbol & Helix sketch objects** — Symbol: a grouped collection of
    sketch elements holding their relative shape, placed/reused as a unit
    (spec §1.16; rigid-under-constraint-edits arrives with Phase C). Helix:
    a tessellated helical 3D curve entity, primarily a Sweep path
    (spec §1.17).

---

## Phase C — Constraint solver tier

**Dependency:** a 2D variational solver. The reference app uses Siemens **D-Cubed 2D
DCM** — commercial, not an option. Open-source fallback (see "Out of reach"
table): **planegcs** (FreeCAD's solver, LGPL, C++ — clean to wrap in a Swift
package the way Euclid is wrapped today) or a purpose-built
sketch-scope solver. Plan assumes planegcs behind a new
`ConstraintSolver` facade in `Kernel/`.

Unlocked features, in build order:

1. Constraint data model on `Sketch` (constraints reference entity IDs +
   point roles) and solve-on-edit: dragging a point becomes "add a transient
   target + solve" so under-constrained geometry follows the drag naturally.
2. Dimensions: length/radius/diameter/angle labels; PAIRWISE distance
   dimensions between any two elements/points (spec §2.2); label edit = set
   driving parameter + resolve; Distance Type (absolute/horizontal/vertical);
   inline arithmetic in fields; solver-refusal feedback on over-constraint;
   label mechanics per spec §2.2 — draggable dimension-text position (Enter
   pins), double-click reopens the input, diameter→radius auto-conversion
   when a circle is trimmed to an arc, secondary-point rule (second-selected
   point moves), and the origin/axis restriction (no dimensions/constraints
   to origin or axes; support the locked construction-crosshair workaround).
3. The 11 constraint types + constraints menu (adaptive enable/disable per
   selection, Shift+letter shortcuts, drag-and-drop coincident/midpoint,
   icon glyphs with delete); Horizontal/Vertical accepts POINT PAIRS as well
   as lines (spec §3.2).
4. Sketch states: DOF analysis from the solver → GREEN/BLUE rendering,
   filled-center connected points, solid-blue locked points.
5. Auto-constraining + guidelines: violet guide lines/points during drawing —
   incl. Equal, Symmetric, Tangent, and Parallel relation guides (spec §2.6);
   drawing along a guide records the corresponding constraint; Constraint
   Settings (auto-constrain toggle, visibility toggles, anchored-entity rule).
6. Pattern constraint (live pattern re-edit; instance edits propagate),
   spline tangency/G1-G2-by-collinearity behavior, symmetry-linked Mirror
   for sketches.

---

## Phase D — History engine tier (parametric modeling)

**Dependency:** replace the linear `UndoStack` snapshot model with a feature
graph: each `DocumentCommand` becomes a **feature node** carrying its
parameters and input references (profile IDs, face references, planes,
variables), and `DesignDocument` becomes the *evaluation result* of replaying
the graph. Persistent topological references on a mesh kernel are the hard
part — mitigate with stable face tags propagated through `KernelOps`
operations (Euclid polygons carry no IDs, so tag via per-polygon material/ID
side tables in `EuclidBridge`/`FaceTopology`).

Unlocked features:

1. History sidebar: step cards with editable parameters, downstream rebuild,
   live preview while dragging a parameter; EVERY mutation — including body
   deletion — records as a suppressible step (spec §10.1). Recording
   semantics per spec §10.1: sketch edits are NOT recorded as steps while
   direct edits ARE appended; editing an existing step leaves no new record
   (in-place parametric edit); deleting a body from Items adds a Delete
   step, while deleting the originating step is the "correct" cleanup.
   Error/repair UX: error badge (exclamation) + "Fix" action highlighting
   stale references in yellow, reference-loss errors on originating-step
   deletion, and the documented repair flows (remove missing face from a
   selection, re-project + re-reference, re-select the original face).
2. Reorder (drag), Suppress/Unsuppress with downstream error surfacing,
   Insert Breakpoint (replay-to-step + insert-at-point, with a DRAGGABLE
   breakpoint bar to scrub the rebuild point up/down the tree — spec §10.1),
   Duplicate, Rename,
   Zoom To, selection-filtered history, Merge History (flatten with
   keep/delete sketches & variables).
3. Variables & expressions (typed variables, fx labels, rename, expression
   fields on every feature/dimension parameter, Add > Variable) — full
   grammar per spec §6.6: naming rules (alphanumerics + underscore, no
   leading digit, ≤100 chars, no leading double underscore), the built-in
   function library (sqrt/sign/floor/ceil/round/abs/mod/min/max/avg, trig +
   inverses + arctan2, pi(), radians()) at 1e-8 evaluation tolerance,
   cross-unit conversion with unit-TYPE checking (intermediate area/volume
   OK, final result single-dimension), feet/inch notation with its parser
   pitfalls, the "Name = Value" panel that stays open, and the
   creation-order rule (reference previously created variables only).
4. Sketch↔body associativity: editing a sketch re-evaluates dependent
   features; sketches attached to construction planes/faces follow them;
   linked Project projections; Insert Project with history merge; editable
   boolean membership / extrusion profile / chamfer edge lists after the
   fact.
5. Gizmo Link badge (linked vs unlinked copies) with the spec §5.1
   propagation semantics — linked copies inherit edits made BEFORE the copy
   step but not after; unlinked "Unlinked Copy" entries are movable anywhere
   in the timeline, accept direct edits, never update, and deleting the
   entry removes the bodies — plus history-recorded
   Move/Rotate steps with editable target-body lists.

---

## Phase E — B-rep kernel tier

**Dependency:** exact boundary representation. Parasolid is commercial-only;
the open fallback is **OpenCASCADE (OCCT, LGPL)** compiled for iOS behind the
existing `KernelOps` facade (the README's stated plan: "a kernel facade that
a stronger kernel could replace later"). Strategy: dual-kernel — OCCT becomes
the source of truth for solids; Euclid remains the fast preview/render path
(OCCT meshes into `RenderMesh` via the same `EuclidBridge` seam).

Unlocked features (rough order):

1. Robust booleans + watertight guarantees on imported geometry.
2. **Chamfer/Fillet** (BRepFilletAPI): Auto/2-distance chamfers, radius +
   chordal fillets, VARIABLE-radius fillets (multiple radii along one edge,
   spec §4.3 — partial in OCCT, accept the gap), G1 (G2 via advanced fillets
   is partial in OCCT — accept the gap), rolling-ball corners, tangent-edge
   propagation. Interaction rules per spec §4.3: selection auto-propagates
   along tangent-connected chains, one radius per fillet feature (separate
   features for different radii), cross-body edges refuse to fillet (Union
   first), secondary-smaller-than-primary rule, additive edit-mode
   selection; drag feedback reveals the max possible radius with "try
   adding more edges" recovery (spec §18 validity layer).
3. **Shell** (BRepOffsetAPI_MakeThickSolid) incl. whole-body mode (entire
   body selected, no face → hollow with no opening) and the red/blue
   drag-validity feedback with failure banner over the bounded valid
   thickness range (spec §4.4), **Offset Face** on curved faces
   with adjacent-face extension/trimming, Radius/Diameter + Total distance
   types.
4. **Replace Face**, **Delete Face with automatic healing** (feature removal
   via OCCT defeaturing/RemoveFeatures; leftover sheet/surface bodies become
   a first-class body type per the spec §4 body-types intro), **Wrap &
   Emboss** (surface mapping), edge projections that split target faces,
   Loft guide curves + G1/G2 continuity with draggable end-tangent handles,
   helical sweeps with exact threads.
5. **STEP + IGES import/export** (OCCT DataExchange, AP203/214/242), shape
   healing (OCCT ShapeHealing ≈ the HOOPS/Bodyshop healing options),
   tessellation-quality settings.
6. Drawings (2D) hidden-line removal via OCCT HLR → production-quality
   dimensioned drawings (a mesh-based drawings v1 can ship earlier in
   Phase B/D with silhouette HLR if prioritized) — incl. multi-body/
   subassembly sheets, the alternate entry points, point-to-point dimension
   orientation badge, and multi-view centerlines (spec §15).

---

## Phase F — Platform & services tier

1. **Settings surface** — units (mm/cm/m/in/ft + formats), theme, interface
   side, navigation options, tessellation quality, anti-aliasing
   (off/2x/4x MSAA), default spline point type, Apple Pencil pressure
   preferences, Undo/Redo button position, tutorial mode. Peripherals:
   SpaceMouse (3Dconnexion SDK; settings under Views) and Wacom pen input
   (spec §7.5).
2. **Sync** — CloudKit-backed project sync (offline-first, per-project
   Local/Synced/Cloud-only states, Download Now / Remove Download);
   project Versions as periodic snapshots with Restore-as-Latest.
3. **Sharing** — a native-archive equivalent of our document (already have a
   compact "OS3D" mesh blob format — wrap document + sketches + thumbnail);
   share links require a service: self-hosted web viewer (three.js/model-viewer
   with GLB) for Published-Versions-style review, with optional link
   PASSWORD protection (spec §13.4); comments need accounts —
   scope to "static share link" first.
4. **AR** — USDZ Quick Look (from Phase B exporter) covers in-app AR preview;
   AR-from-link rides the web viewer (model-viewer has AR modes).
5. **Drawings space** (if not landed in Phase E), **Visualization polish**
   (decals, custom GLB materials, environments settings), screenshot/capture
   parity.
6. Teams/Spaces/commenting/Vision Pro: out of scope for an open-source client
   without a funded backend; design the document format so a community server
   could add them. Subscription plan gating (Basic/Pro/Enterprise limits) is
   deliberately NOT implemented — all features stay ungated (spec §13 note).

---

## Permanently out of reach without commercial components

| the reference app component | Why it's closed | Open-source fallback (and the honest gap) |
|---|---|---|
| **Parasolid kernel** (exact B-rep modeling, robust booleans, fillets/shell/offset quality) | Siemens license, per-seat royalty; no OSS distribution possible | **OpenCASCADE (LGPL)** behind `KernelOps`. Gap: boolean robustness on dirty geometry, advanced blends (G2/variable-radius, Y-blends, overflow control), performance. Euclid mesh CSG remains the fallback-of-the-fallback for preview speed. |
| **D-Cubed 2D DCM** (constraint solver) | Siemens license | **planegcs** (FreeCAD, LGPL) wrapped as a Swift package; or SolveSpace's solver (GPLv3 — license-incompatible with our MIT app unless isolated/relicensed; prefer planegcs). Gap: solve speed on large sketches, diagnosis quality (which constraint conflicts), drag stability. |
| **X_T / X_B (Parasolid format) import/export** | Proprietary format tied to Parasolid | None viable. Fallback: STEP AP242 as the exact-geometry interchange; document "use STEP" where the reference app docs say X_T. |
| **SLDPRT/SLDASM, CATIA, NX, Creo, Solid Edge, JT import** | Requires HOOPS Exchange / Datakit / vendor SDK licenses | No practical OSS readers with usable coverage. Fallback: instruct users to export STEP/IGES from the source CAD (the reference app docs themselves recommend Parasolid/STEP export for SolidWorks assemblies). JT: the ISO spec exists but OSS tooling is effectively absent. |
| **HOOPS + Parasolid Bodyshop healing** (import repair options) | Commercial | OCCT ShapeHealing (fix small edges, sewing, tolerance repair). Gap: success rate on pathological files. |
| **DWG** read/write | Format controlled by Autodesk; robust libs (ODA) are commercial; libredwg is GPLv3 | Support **DXF** both ways (fully documented, MIT-friendly parsers); mark DWG unsupported. |
| **the reference app Cloud** (Sync service, Spaces, Published Versions viewer, comments, link permissions) | First-party service | CloudKit for personal sync (free with Apple account, no server to run); optional self-hosted GLB web viewer for share links. Gap: teams, permissions, comments, cross-platform accounts. |
| **Generative Render** (AI enhancement) | First-party hosted model | External image-model API hook (user-supplied key) or omit. |
| **Vision Pro immersive review (Enterprise)** | Service-bound + Enterprise licensing | A local visionOS volumetric viewer of USDZ exports is feasible; the collaborative session part is service-bound. |
| **100+ material library** (content, not code) | Licensed asset library | Build a small original PBR set + accept community/CC0 materials (ambientCG etc.); support custom GLB material import (Phase F). |

---

## Dependency graph (summary)

```
Phase A (mesh tools, planes, revolve, transform, items, views, IO)
   │
   ├─► Phase B (sweep/loft/split/pattern/offset-edge/text/project/
   │            section/display/selection/visualization-v1)
   │
   ├─► Phase C (constraint solver: planegcs) ──► constraints, dimensions,
   │            states, guides, pattern-constraint, sketch mirror links
   │
   ├─► Phase D (history engine) ──► history sidebar, reorder/suppress/
   │            breakpoints, variables, associativity, linked copies
   │
   └─► Phase E (OpenCASCADE B-rep) ──► fillet/chamfer, shell, offset-face,
                replace-face, wrap&emboss, STEP/IGES, exact loft/sweep,
                drawings HLR
Phase F (platform/services) is parallel to C–E after A/B.
```

C and D are independent of each other but both multiply in value once both
exist (fully-parametric sketches driving history rebuilds). E can start any
time; its features should land behind the `KernelOps` facade so A/B code
doesn't churn.
