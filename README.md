# openshape3d

An open-source, Shapr3D-inspired direct-modeling CAD app for iPad and iPhone,
built with SwiftUI, a **custom Metal renderer**, and the MIT-licensed
[Euclid](https://github.com/nicklockwood/Euclid) geometry library.

![Platform](https://img.shields.io/badge/platform-iPadOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)

## Features (v0.1)

- **Sketch → Extrude** — the signature CAD loop: draw lines, rectangles, and
  circles on the ground plane (with grid + endpoint snapping), tap a closed
  profile, and pull it into a solid. Nested profiles become holes.
- **Primitives** — place boxes, cylinders, and spheres with editable
  dimensions.
- **Booleans** — union, subtract, and intersect bodies (computed off the main
  thread, cancellable).
- **Direct manipulation** — tap to select, move with a full XYZ arrow +
  plane-handle gizmo, Shapr3D-style navigation (one finger orbits, two fingers
  pan, pinch zooms — camera never locks up, even mid-tool).
- **Undo/redo** — command-based history for every operation.
- **Projects** — a gallery of designs persisted with SwiftData, including
  rendered thumbnails.
- **STL export** — binary STL of the whole design (1 unit = 1 mm), ready for
  slicing.

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

- Sketch on body faces and offset planes
- Arcs, splines, fillets/chamfers
- Rotate/scale gizmos
- Apple Pencil–specific input (draw with Pencil, orbit with finger) and hover
- Fat-line edge rendering, dark mode viewport theme
- STEP/OBJ export, STL import
- Assembly-style grouping, materials

## License

MIT. Not affiliated with or endorsed by Shapr3D.
