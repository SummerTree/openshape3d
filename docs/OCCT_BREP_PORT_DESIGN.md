# OCCT B-rep Port — Concrete Scope ("the big one")

Companion to `IMPLEMENTATION_PLAN.md` (Phase E — B-rep kernel tier) and the
`STATUS_AND_NEXT_STEPS.md` "F — OpenCASCADE B-rep port" mission. This doc turns
that high-level intent into an ordered, buildable plan with a make-or-break
spike first.

## Why (the motivating bug)

Euclid is a **polygon-mesh** CSG kernel: it has no analytic surfaces. A sketched
circle is tessellated to a fixed segment count *before* any solid exists
(`ProfileDetector.circleSegments = 48`), so "extrude a circle" produces a
48-sided prism, not a cylinder. Fillet/chamfer/shell then operate on those
facets, so curved-wall results look and behave wrong. There is no mesh-side fix;
the representation itself must become exact. That is a B-rep kernel — Parasolid
(commercial) or **OpenCASCADE / OCCT (LGPL)**.

## Goal / non-goals

- **Goal:** OCCT becomes the source of truth for solids behind the existing
  `KernelOps` facade. Solids carry an exact B-rep; a cylinder is ONE cylindrical
  face; fillets roll on true surfaces. Euclid stays as render/preview + fallback.
- **Non-goals (this port):** STEP/IGES, drawings/HLR, shape healing, variable-
  radius/G2 blends, Wrap/Emboss. Those ride later on the same seam.

## Architecture: dual-kernel seam

The whole port lives behind two conversions we already have Euclid versions of:

```
FeatureGraph.evaluate ──► KernelOps.<op>(...) ──► <solid> ──► RenderMesh (GPU)
                                     ▲                              ▲
                          today: Euclid.Mesh            today: EuclidBridge.renderMesh
                          port:  OCCT TopoDS_Shape       port:  OCCTBridge.renderMesh
```

Concrete touch points (all already isolated):

- **`Body`** (`Kernel/GeometryTypes.swift:116`) — today holds `render: RenderMesh`,
  `edges`, optional `euclid: Euclid.Mesh?`. Add an opaque `brep: BRepHandle?`
  (retained wrapper around a `TopoDS_Shape`). `render`/`edges`/topology derive
  from `brep` when present, else from `euclid` (unchanged path).
- **`KernelOps`** (`Kernel/KernelOps.swift`, ~15 static ops: `extrude`, `revolve`,
  `boolean`, `blendEdges`/`chamferEdge`/`filletEdge`, `pushPullPlanarFace`,
  `mirror`, plus `ShellKit.shell`, `SweepLoftKit.sweep/loft`). Each gets an OCCT
  implementation. Migrate op-by-op; un-ported ops keep calling Euclid.
- **`EuclidBridge`** (`Kernel/EuclidBridge.swift`) — add a sibling `OCCTBridge`
  with `renderMesh(from: TopoDS_Shape)` (via `BRepMesh_IncrementalMesh`) and
  edge extraction from real B-rep edges (better than the current
  `FeatureEdgeExtractor` triangle-crease heuristic).
- **`TopoNaming`** (`Model/TopoNaming.swift`) — today reverse-engineers a
  `CylindricalFace` from triangle soup. With B-rep it reads face type directly
  (`BRepAdaptor_Surface` → plane/cylinder/cone/sphere), so topological naming
  gets *more* robust, not less. Signatures stay compatible.
- **Persistence** (`Model/PersistenceModels.swift`, `ProjectArchive.swift`) —
  stores the `RenderMesh` blob today. B-rep bodies additionally need a serialized
  shape (OCCT BinTools/BRep). Keep RenderMesh for fast load + fallback; treat the
  B-rep blob as authoritative when present. Migration = load old docs as
  Euclid-only bodies (no B-rep), which still render.

Feature-graph re-evaluation stays value-based (`FeatureGraph.evaluate` rebuilds
from features). `BRepHandle` is a reference type wrapping a C++ object, so
`Body` stays `Sendable` only through a carefully-audited `@unchecked` wrapper;
kernel calls remain `nonisolated` and off the main actor.

## Milestone 0 — THE SPIKE ✅ PROVEN (2026-07-22)

**Result: viable.** OCCT 7.8.1 cross-compiled for iOS (device arm64 + simulator
arm64), the Obj-C++ shim links against it, and it runs correctly on the
simulator:

```
OCCT version: 7.8.1
box: tris=12 verts=24 vol=1000.000000        (exact volume, meshes fine)
extruded circle: planar=2 cylindrical=1 other=0   ← the proof: ONE analytic
                                                     cylindrical wall, not 48 facets
=== SPIKE SUCCEEDED (0 failures) ===
```

Kill-criteria outcomes:
- **iOS build viability:** ✅ 18 toolkits built per slice via cmake + leetal
  ios-cmake toolchain. cmake 4.4 needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`
  (OCCT 7.8.1 still declares `cmake_minimum_required(VERSION 3.1)`).
- **Binary size:** ⚠️ acceptable. Merged static lib is ~74 MB/arch *unstripped*,
  but the linker dead-strips: the spike executable pulled only **8.6 MB** from
  it. The shipped app grows by roughly the code it references, not 74 MB. Still,
  strip + measure the real delta in Milestone 1.
- **License (LGPL):** headless modeling build, dynamically-dead-stripped static
  link. Provide the build recipe + object archives so users can relink → LGPL
  §6 satisfied. (Formalize the LGPL notice + relink path before shipping.)
- **Deliverables produced:** `scripts/build_occt_ios.sh` (reproducible build),
  `ThirdParty/OCCT.xcframework` (gitignored, 2-slice), `OCCTKit/
  OCCTBridge.{h,mm}` (narrow facade), `OCCTKit/OCCTSpikeMain.mm`
  + `scripts/run_occt_spike.sh` (repeatable acceptance check).

**Remaining M0 integration (next):** promote the standalone harness into a real
Xcode target + in-suite XCTest (the pbxproj wiring: add the shim to an `OCCTKit`
static-lib or the test target, link the xcframework, header search paths, a
bridging header). Deferred from the spike on purpose — the standalone sim run
already proves link+run; the pbxproj surgery belongs with Milestone 1 so it
lands behind the `OS3D_BREP` flag in one reviewable step.

### Original spike plan (for reference)

Everything below depends on being able to build and link OCCT for iOS. Prove it
in isolation before touching app code. Acceptance = a single unit test that
round-trips a box with zero app changes beyond the new target/deps.

1. **Build OCCT.xcframework for iOS** (device arm64 + simulator arm64/x86_64).
   OCCT has no first-class iOS build; options, cheapest first:
   - CMake cross-compile with an iOS toolchain file, minimal module subset
     (`TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKTopAlgo TKPrim TKBO
     TKFillet TKOffset TKMesh`), static libs → assemble `.xcframework`.
   - Fallback: an existing community iOS OCCT build script/formula as a
     starting point (verify LGPL compliance — dynamic link or provide relink
     object files/build scripts).
   Deliverable: `ThirdParty/OCCT.xcframework` + a checked-in, reproducible build
   script (`scripts/build_occt_ios.sh`). **Do not** hand-place a binary with no
   recipe.
2. **Interop shim.** New static-lib target `OCCTKit` (Obj-C++ `.mm`) exposing a
   *narrow C/Obj-C* surface — NOT raw OCCT headers to Swift. C++ is already
   enabled (`CLANG_CXX_LANGUAGE_STANDARD = gnu++20`) and a bridging header
   already exists (`ShaderTypes.h`), so this is additive. Prefer an Obj-C++
   facade over Swift/C++ interop (OCCT's template-heavy headers are hostile to
   direct interop).
3. **Round-trip test:** `BRepPrimAPI_MakeBox(10,10,10)` → `BRepMesh_
   IncrementalMesh` → vertices/indices → assert triangle count > 0, closed,
   volume ≈ 1000. Then extrude a **circle** and assert exactly ONE cylindrical
   face via `BRepAdaptor_Surface` — the direct proof the motivating bug is gone
   at the kernel level.

**Risks surfaced by the spike (kill-criteria if unresolvable):** binary size
(OCCT static can add 30–80 MB/arch — measure; strip unused modules), iOS build
viability, LGPL dynamic-link/relink obligations, App Store bitcode/arch rules.
If the spike can't produce a linkable, size-acceptable xcframework, stop and
reconsider (e.g. server-side kernel) before investing in op migration.

## Milestone 1 — OCCT wired into the app ✅ (2026-07-22); extrude/boolean port next

**Wiring DONE and verified in-suite** (499 unit tests green, incl. 3 new OCCT
tests). OCCT is now a linked dependency of the app target, reachable from Swift:

- **Sources** live in the app's synchronized group so they compile into the app:
  `openshape3d/Kernel/OCCT/OCCTBridge.{h,mm}` (Obj-C++ facade) and
  `OCCTKernel.swift` (Swift-native wrapper — the only thing feature code calls;
  the Obj-C surface never leaks). The standalone `OCCTKit/OCCTSpikeMain.mm`
  (has a `main()`) stays OUT of the app target.
- **Bridging header:** a NEW `openshape3d/openshape3d-Bridging-Header.h` imports
  both `Shaders/ShaderTypes.h` and `Kernel/OCCT/OCCTBridge.h`. Critical: the old
  bridging header WAS `ShaderTypes.h`, which is `#include`d by `Shaders.metal`
  too — adding Foundation/OCCT into it would break Metal. The new header keeps
  them separate; Metal still includes `ShaderTypes.h` directly.
- **pbxproj:** `OCCT.xcframework` added as a file ref + linked in the app
  Frameworks phase; `HEADER_SEARCH_PATHS` points at both slices' `Headers`
  (arch-independent, either resolves); `SWIFT_OBJC_BRIDGING_HEADER` → the new
  header. Verified with `plutil -lint`.
- **Tests:** `openshape3dTests/OCCTKernelTests.swift` (`@testable import` reaches
  `OCCTKernel`; symbols resolve via the app test-host) — links/version, box
  volume, and extruded-circle = 1 analytic cylinder.

**STEP/IGES deferred (deliberate).** Enabling `DataExchange`+`ApplicationFramework`
~doubles the static lib (18→47 toolkits, ~74→~140 MB/arch — measured). It's not
on the critical path and rides the same seam, so it's a build-flag flip in
`build_occt_ios.sh` + a couple of bridge methods whenever an import/export
feature needs it. The STEP-enabled build IS proven to compile for iOS.

**Caveat:** the app target's `SUPPORTED_PLATFORMS` includes `macosx`/`xros`, but
the xcframework has only `ios-arm64` + `ios-arm64-simulator` slices. iOS
device/simulator builds work; macOS/visionOS builds would need those slices
added to `build_occt_ios.sh` (or the OCCT link gated per-SDK). The dev workflow
is the iOS simulator, so this is a documented follow-up, not a blocker.

### Circle extrude renders as a true cylinder ✅ (2026-07-22)

First user-visible B-rep win, **confirmed on-device**: extruding a circle now
displays a smooth analytic cylinder (round wall, clean circular rims) instead of
the 48-gon prism with hard facet bands.

- `OCCTBridge.cylinderRenderMeshWithCenterX:…` builds a true `BRepPrimAPI_
  MakeCylinder`, meshes it with a fine angular deflection, and emits **smooth
  per-vertex normals evaluated from the analytic surface** (`BRepAdaptor_Surface`
  D1 → dU×dV) — that's what removes the shading bands.
- `OCCTKernel.cylinderRenderMesh(...)` maps the plane-local mesh to world via the
  sketch-plane basis (matching `KernelOps.extrude`'s placement).
- `FeatureGraph.evalExtrude` swaps in this render mesh for the pure circle case
  (no holes/extras) behind `OCCTKernel.renderCircleExtrudesWithOCCT`. **Euclid
  still owns CSG/volume** — only the display mesh changed, so booleans and the
  full suite are unaffected (499 tests green).
- Proof: `OCCTKernelTests.testCylinderRenderMeshIsFinelyTessellatedAndSmooth`
  (>150 verts, radial normals spanning >40 directions) + a live screenshot via
  the `OS3D_DEBUG_SEED_CYLINDER` hook.

### B-rep source of truth: extrude + boolean stay round ✅ (2026-07-22)

**Booleans of cylinders now render round**, confirmed on-device (a cylinder minus
an offset cylinder → smooth outer wall + smooth concave cut). The pieces:

- `Body.brep: BRepHandle?` — a `@unchecked Sendable` wrapper owning an
  `OCCTShape` (world-space `TopoDS_Shape`), freed on release. Transient (not
  persisted).
- `OCCTBridge` grew a B-rep surface: `extrudedShapeWithOuterLoop:…` (analytic
  circle or polygonal prism, world-transformed via the plane basis with
  `gp_Trsf.SetValues`), `booleanOfShape:withShape:op:`
  (`BRepAlgoAPI_Fuse`/`Cut`/`Common`), and `renderMeshFromShape:` (shared smooth
  tessellator `TessellateShape`).
- `FeatureGraph.evalExtrude` builds `body.brep` for the circle case;
  `evalBoolean` composes `priorBrep ⊕ tool.brep` with the matching OCCT op and
  renders the result smooth. **Euclid still computes the CSG mesh** (volume,
  tests, downstream ops), so the 500-test suite is untouched.

**Deliberately scoped to circle-derived bodies** so polygonal profiles keep the
exact Euclid path (no perturbation of existing coverage). Demo hook:
`SIMCTL_CHILD_OS3D_DEBUG_SEED_BOOLEAN=1`.

### Primitives are analytic too ✅ (2026-07-22)

`evalPrimitive` now builds an OCCT solid for box/cylinder/sphere
(`primitiveShapeOfKind:`), matching Euclid's placement conventions EXACTLY (base
on y=0, cylinder axis +Y, sphere centred at (0,r,0)) so the B-rep and the CSG
mesh coincide. Consequences:

- A **mixed** boolean — e.g. cylinder primitive − box primitive — now composes
  analytically and renders round (verified on-device:
  `SIMCTL_CHILD_OS3D_DEBUG_SEED_PRIMBOOL=1`).
- Cylinder/sphere primitives also take the smooth OCCT render mesh; a **box
  keeps the Euclid render** (identical look, so no reason to perturb coverage).
- Suite still 500 green.

### B-rep persistence ✅ (2026-07-22)

`Body.brep` was transient, and bodies are restored from the persisted mesh blob
(the graph only re-evaluates on edits) — so after a reload a body *looked* right
(the smooth render mesh persists) but was Euclid-only, meaning a later boolean or
fillet would silently fall back to faceted.

`OCCTBridge` now serializes/deserializes via `BRepTools::Write/Read`, and
`PersistedBody` carries an optional externally-stored `brepData`. Both directions
degrade safely — a nil or unreadable blob (pre-OCCT store, or one written by an
incompatible OCCT build) leaves the body Euclid-only with its persisted render
mesh, exactly as before. No migration needed; same shape as the `materialData`
addition. Covered by a pure-value round-trip test (`DocumentSession` is
deliberately not unit-tested — SwiftData-in-XCTest gotcha).

**Not yet persisted:** the `.os3d` project archive (`ProjectArchive.BodyRecord`)
doesn't carry the blob, so export/import still drops to Euclid-only.

Remaining for a full port: general (polygonal/arc/ellipse) profiles as B-rep
source, analytic circular holes, the extrude-into-target boolean path, the
archive format, and fillet/shell on B-rep. Those are the next milestones (M2/M3).

**Still ahead — the remaining geometry-op port (behind `OS3D_BREP`):** port `KernelOps.extrude` (use
`BRepPrimAPI_MakePrism` on a `BRepBuilderAPI_MakeFace` from analytic
`Geom_Circle`/edges — NOT the 48-gon loop) and `KernelOps.boolean`
(`BRepAlgoAPI_Fuse/Cut/Common`). Wire `Body.brep`, `OCCTBridge.renderMesh`, and a
feature-flag (`OS3D_BREP=1`) so the two kernels can be A/B compared. Acceptance:
extrude a circle → render shows a smooth cylinder at high tessellation, topo
reports one side face, boolean of two cylinders is watertight.

## Milestone 2 — Fillet/Chamfer (the payoff)

`BRepFilletAPI_MakeFillet` / `MakeChamfer`, driven by the existing selection +
tangent-chain UI from the mesh blend work (Phase E). Interaction rules already
specified (spec §4.3): tangent auto-propagation, one radius per feature,
cross-body refusal, drag validity (max-radius feedback). Accept documented gaps:
variable-radius and G2 are partial in OCCT.

## Milestone 3 — Shell / Offset-face, then Revolve/Sweep/Loft

`BRepOffsetAPI_MakeThickSolid` (shell incl. whole-body), offset-face on curved
faces; then migrate `revolve`, `SweepLoftKit`. Retire Euclid ops as each lands;
keep Euclid as the preview-speed fallback-of-the-fallback.

## Sequencing & first PR boundary

- **PR 1 = Milestone 0 only** (xcframework + OCCTKit shim + round-trip test).
  Nothing in the app depends on it yet; it's revertible and de-risks everything.
- Then one PR per op family behind `OS3D_BREP`, flipping the default to B-rep
  once Milestones 1–2 are green across the existing geometry test suite.

## Open decisions (need a call before Milestone 1)

- Interop: Obj-C++ facade (recommended) vs enabling Swift/C++ interop.
- Binary size budget / whether to gate B-rep behind a download.
- Persistence: dual-store (RenderMesh + BRep blob) vs BRep-only with lazy mesh.
