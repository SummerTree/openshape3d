# openshape3d

An open-source, Shapr3D-inspired direct-modeling CAD app for iPad and iPhone,
built with SwiftUI, a **custom Metal renderer**, and the MIT-licensed
[Euclid](https://github.com/nicklockwood/Euclid) geometry library.

![Platform](https://img.shields.io/badge/platform-iPadOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)

## Features (v0.3)

- **Sketch planes** — pick a world plane (XY/YZ/ZX tiles at the origin), tap
  any planar body face to sketch on it, or pull an **offset construction
  plane** off a face (drag the arrow or type the distance; persisted).
  Re-entering the same plane continues the same sketch item, and the camera
  animates head-on — Shapr3D's rules.
- **Sketch tools** — Line (with chain continuation and close-the-loop),
  Rectangle, Circle, **Arc** (drag the chord, then drag the arc to adjust the
  bulge), **Ellipse**, and **Polygon** (side count in the numeric bar), with
  endpoint/midpoint/center/vertex + grid snapping. The Apple Pencil draws.
- **Sketch editing** — tap entities to select, drag endpoints/handles or the
  entity body to edit (one coalesced undo step per drag), Delete, and
  **Trim**: tap a segment to remove the span between its nearest
  intersections (circles trim to arcs, rectangles explode into lines).
- **Sketch → Extrude, the Shapr3D way** — tap a fill for numeric extrude or
  pull it directly with a live preview; nested profiles become holes;
  additional fills join a multi-profile extrude. **Boolean badge**
  (Auto | New Body | Union | Subtract | Intersect), **Symmetric** sides
  (per-side distance, 2× total), and validity feedback — the pull arrow
  turns red when the pending result would fail. Tapping empty space commits.
- **Revolve** — select a profile fill, tap "Revolve", pick a sketch line or
  world axis, drag or type the angle (default 360°, partial wedges
  supported); commits through the same automatic-boolean pipeline.
- **Face push/pull with automatic booleans** — tap a body to select the
  planar face under your finger (double-tap selects the whole body). Drag
  the face to extrude it: pulling away adds material (union), pushing into
  the body cuts (subtract) — exactly Shapr3D's automatic boolean rules.
- **Booleans** — explicit union, subtract, and intersect between bodies
  (computed off the main thread, cancellable).
- **Transform** — move gizmo with XYZ arrows, plane tiles, and **rotation
  rings**; tap an arrow to type an exact distance; **Copy badge** duplicates
  the selection on the next drag; uniform **Scale** by factor; **Mirror**
  a body across a world or construction plane.
- **Views** — orientation cube in the corner (tap a face or corner to snap
  the view), Views menu with the six standard views + isometric, and an
  **orthographic** projection toggle. Shapr3D-style navigation (one finger
  orbits, two fingers pan, pinch zooms — camera never locks up, even
  mid-tool).
- **Items panel** — bodies, sketches, and construction planes with type
  icons, visibility eye, inline rename, delete, tap-to-select, and Zoom To;
  extruding auto-hides the consumed sketch.
- **Measure** — a selection info bar (face area, body volume, bounding box,
  sketch-entity length/radius) plus a two-point distance mode with X/Y/Z
  deltas over sketch and body snap points.
- **Import/Export** — STL import (binary + ASCII, welded into a solid mesh
  body that booleans like any other); STL, OBJ, and 3MF export; **PNG
  screenshot** with resolution, transparent-background, and grid options.
- **Undo/redo** — command-based history for every operation.
- **Projects** — a gallery of designs persisted with SwiftData, including
  rendered thumbnails.

## Architecture

```
Kernel/       Geometry: Euclid bridge, profiles, extrude, booleans, STL,
              feature-edge extraction. Pure Swift, Double precision, fully
              unit-tested, nonisolated (runs off the main actor).
Model/        DesignDocument (value type), undoable commands, SwiftData
              persistence with a compact binary mesh format ("OS3D").
Rendering/    Custom Metal renderer: MTKView (on-demand drawing), Blinn-Phong
              "CAD look" shading, procedural anti-aliased grid, feature edges
              with vertex-shader depth bias, MSAA 4x, gizmo overlay pass,
              turntable camera + animator, offscreen thumbnail capture.
Interaction/  Gesture arbitration, CPU ray-cast picking (AABB + Möller–
              Trumbore), gizmo drag math.
Editor/       EditorViewModel — the mode state machine tying UI, kernel, and
              viewport together. The viewport never mutates the model.
UI/           SwiftUI chrome: gallery, tool palette, numeric input, overlays.
Shaders/      Single Shaders.metal + ShaderTypes.h shared with Swift via
              bridging header (one source of truth for uniform layouts).
```

Rendering conventions: kernel/model math is `Double`, GPU buffers are
`Float32`. Meshes are welded by (position, normal) so hard edges survive;
feature edges come from a 20° dihedral-angle threshold.

## Why these choices?

Shapr3D itself pairs a licensed Siemens Parasolid kernel with a proprietary
Metal renderer. Parasolid isn't an option for an open-source app, so —
like Shapr3D's own v1, which shipped on the open-source OpenCascade kernel —
openshape3d uses an open geometry library (Euclid, mesh-CSG based) behind a
kernel facade (`KernelOps`) that a stronger kernel could replace later.

## Building

Open `openshape3d.xcodeproj` in Xcode 26+ and run the `openshape3d` scheme on
an iPad (or iPhone) simulator or device. The Euclid package resolves
automatically.

Tests: `⌘U`, or

```sh
xcodebuild test -project openshape3d.xcodeproj -scheme openshape3d \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

Unit tests cover the geometry kernel (bridge/weld, blob serialization,
profiles, extrusion conventions, booleans, STL layout); XCUITests drive the
real flows (place → edit → move → sketch → extrude → subtract).

## Roadmap

- Sweep, loft, split body, patterns, offset edge, text (Phase B)
- Splines, constraints and dimensions (2D solver — Phase C)
- Parametric history sidebar with editable steps (Phase D)
- Fillets/chamfers, shell, STEP/IGES via a B-rep kernel (Phase E)
- Section view, display modes, area select, keyboard shortcuts
- Fat-line edge rendering, dark mode viewport theme
- GLB/USDZ export, DXF import/export
- Assembly-style grouping, materials

See `docs/SHAPR3D_PARITY_SPEC.md` for the feature-by-feature status audit and
`docs/IMPLEMENTATION_PLAN.md` for phase sequencing.

## License

MIT. Not affiliated with or endorsed by Shapr3D.
