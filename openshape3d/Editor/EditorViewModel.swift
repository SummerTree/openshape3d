//
//  EditorViewModel.swift
//  openshape3d
//
//  The mode state machine bridging SwiftUI chrome, the geometry kernel, and
//  the Metal viewport. All mutations funnel through here; the viewport only
//  reports events.
//

import Foundation
import SwiftData
import Observation
import simd
import Euclid
import ImageIO

enum ViewportEvent {
    case tap(ray: Ray)
    case doubleTap(ray: Ray)
}

/// Camera operations the view model can request from the viewport.
@MainActor
protocol ViewportCameraControl: AnyObject {
    func fitScene()
    /// Animate to look head-on at a sketch plane.
    func moveCameraHeadOn(to plane: SketchPlane)
    /// Animate to a standard view (Views popover, spec §7.3).
    func animateToStandardView(_ view: StandardView)
    /// Switch between perspective and orthographic projection.
    func setProjection(orthographic: Bool)
    /// Animate to frame a world-space AABB (Items Manager "Zoom to").
    func fitTo(bounds: (min: SIMD3<Float>, max: SIMD3<Float>))
    /// World units per screen point at the camera target depth — converts
    /// screen-space pick tolerances into sketch-plane distances.
    var worldUnitsPerPoint: Double { get }
    /// Project a world-space point to viewport screen points (top-left origin),
    /// or nil when it is behind the camera. Used to place SwiftUI overlays such
    /// as dimension labels (plan §C2).
    func worldToScreenPoint(_ world: SIMD3<Double>) -> CGPoint?
}

@MainActor
@Observable
final class EditorViewModel {
    let session: DocumentSession
    var mode: EditorMode = .idle
    var selection: Set<BodyID> = []

    /// Multi-select chip (plan §B13, spec §8.1): while on, viewport taps
    /// toggle whole bodies in and out of `selection` instead of replacing
    /// it, and area selects add instead of replace. Boolean tool picking
    /// has its own always-additive tap flow and is unaffected.
    var selectionAdditive = false

    weak var cameraControl: (any ViewportCameraControl)?

    /// Bumped by the viewport coordinator whenever the camera moves; SwiftUI
    /// overlays that reproject world points (dimension labels, plan §C2) read
    /// it to re-run their layout as the camera orbits/animates.
    var cameraEpoch = 0

    init(project: Project, modelContext: ModelContext) {
        self.session = DocumentSession(project: project, modelContext: modelContext)
        loadAutoConstrainSettings()
    }

    // MARK: - Scene for the viewport

    /// Highlighted gizmo part during hover/drag (set by the coordinator).
    var gizmoHighlight: GizmoPart?

    /// User-facing error surfaced as an alert.
    var errorMessage: String?

    /// Set by the viewport coordinator: renders the current scene offscreen.
    var thumbnailProvider: (() -> Data?)?

    /// Set by the viewport coordinator: offscreen render with screenshot
    /// options (width, height, transparent background, show grid).
    var screenshotProvider: ((Int, Int, Bool, Bool) -> Data?)?

    /// All solid bodies, or nil (with a user-facing error) when empty.
    private func exportableBodies() -> [Body]? {
        let bodies = session.document.bodies
        guard !bodies.isEmpty else {
            errorMessage = "Nothing to export — the design has no solid bodies."
            return nil
        }
        return bodies
    }

    /// STL of the whole document, or nil when empty.
    func exportSTL() -> Data? {
        exportableBodies().map { STLExporter.binarySTL(bodies: $0) }
    }

    /// OBJ of the whole document, or nil when empty.
    func exportOBJ() -> Data? {
        exportableBodies().map { Data(OBJExporter.obj(bodies: $0).utf8) }
    }

    /// 3MF of the whole document, or nil when empty.
    func exportThreeMF() -> Data? {
        exportableBodies().map { ThreeMFExporter.threeMF(bodies: $0) }
    }

    /// GLB of the whole document, or nil when empty.
    func exportGLB() -> Data? {
        exportableBodies().map { GLBExporter.glb(bodies: $0) }
    }

    /// USDZ of the whole document (plan §B14); nil when the design is empty
    /// or ModelIO on this platform cannot write USDZ (the UI hides the
    /// entries via `USDZExporter.isSupported`, so this error is a fallback).
    func exportUSDZ() -> Data? {
        guard let bodies = exportableBodies() else { return nil }
        guard let data = USDZExporter.usdz(bodies: bodies) else {
            errorMessage = "Couldn't export USDZ on this device."
            return nil
        }
        return data
    }

    /// Per-body OBJ payloads for the "Separate File per Body" export option
    /// (plan §B14); nil (with a user-facing error) when the design is empty.
    func exportOBJPerBody() -> [(name: String, data: Data)]? {
        exportableBodies().map { bodies in
            bodies.map { ($0.name, Data(OBJExporter.obj(bodies: [$0]).utf8)) }
        }
    }

    /// Per-body GLB payloads, mirroring `exportOBJPerBody`.
    func exportGLBPerBody() -> [(name: String, data: Data)]? {
        exportableBodies().map { bodies in
            bodies.map { ($0.name, GLBExporter.glb(bodies: [$0])) }
        }
    }

    /// DXF of the active sketch while sketching, else of the ground-plane
    /// sketch (plan §B14, spec §12); nil (with a user-facing error) when
    /// neither has entities.
    func exportDXF() -> Data? {
        let sketch = activeSketch
            ?? session.document.sketches.first { $0.plane.isCoincident(with: .ground) }
        guard let sketch, !sketch.entities.isEmpty else {
            errorMessage = "Nothing to export — draw a sketch on the ground plane first."
            return nil
        }
        return Data(DXFKit.exportSketch(entities: sketch.entities, plane: sketch.plane).utf8)
    }

    /// DXF import (plan §B14, spec §12.1): parsed entities land in the
    /// ground-plane sketch — reused when one exists (unhiding it if an
    /// extrude auto-hid it), created otherwise — as ONE CompositeCommand so
    /// a single undo removes everything the import added.
    func importDXF(data: Data, fileName: String) {
        let entities = DXFKit.importDXF(data)
        guard !entities.isEmpty else {
            errorMessage = "Couldn't import “\(fileName)” — no supported DXF entities found."
            return
        }
        cancelTransientPicks()
        if case .sketching = mode { finishSketch() }
        var commands: [DocumentCommand] = []
        let sketch: Sketch
        if let existing = session.document.sketches.first(where: {
            $0.plane.isCoincident(with: .ground)
        }) {
            sketch = existing
            if existing.isHidden {
                commands.append(SetItemVisibilityCommand(
                    item: .sketch(existing.id), isHidden: false
                ))
            }
        } else {
            sketch = Sketch(name: session.document.uniqueSketchName(), plane: .ground)
            commands.append(AddSketchCommand(sketch: sketch))
        }
        commands.append(AddSketchEntitiesCommand(
            sketchID: sketch.id, entities: entities, title: "Import DXF"
        ))
        session.perform(CompositeCommand(title: "Import DXF", commands: commands))
        mode = .idle
        cameraControl?.moveCameraHeadOn(to: sketch.plane)
    }

    /// Screenshot PNG at the requested size, or nil (with a user-facing
    /// error) when the viewport is not ready.
    func captureScreenshot(
        width: Int, height: Int, transparentBackground: Bool, showGrid: Bool
    ) -> Data? {
        guard let data = screenshotProvider?(width, height, transparentBackground, showGrid) else {
            errorMessage = "Couldn't capture a screenshot — please try again."
            return nil
        }
        return data
    }

    /// STL import (spec §12.1): parsed mesh becomes a body named after the
    /// file, with its pivot at the mesh AABB center.
    func importSTL(data: Data, fileName: String) {
        let mesh: RenderMesh
        do {
            mesh = try STLImporter.importSTL(data)
        } catch {
            errorMessage = "Couldn't import “\(fileName)” — not a valid STL file."
            return
        }
        // Recenter local coordinates so the gizmo pivot sits at the AABB
        // center instead of wherever the file's origin happened to be.
        var recentered = mesh
        let aabb = mesh.localAABB
        let center = (aabb.min + aabb.max) * 0.5
        for i in recentered.positions.indices {
            recentered.positions[i] -= center
        }
        var transform = Transform3D.identity
        transform.translation = SIMD3<Double>(center)

        let stem = (fileName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Imported" : stem
        var document = session.document
        let body = Body(
            id: BodyID(),
            name: document.uniqueBodyName(base: base),
            transform: transform,
            primitive: nil,
            render: recentered,
            revision: document.nextRevision()
        )
        cancelTransientPicks()
        session.perform(AddBodyCommand(body: body, title: "Import \(body.name)"))
        selection = [body.id]
        mode = .idle
        cameraControl?.fitScene()
    }

    func saveThumbnail() {
        if let data = thumbnailProvider?() {
            session.project.thumbnail = data
        }
    }

    var scene: ViewportScene {
        _ = session.changeCount // establish observation dependency
        var drawables: [BodyDrawable] = []
        // During a face push/pull, the preview IS the modified source body, so
        // hide the original to avoid it poking through the preview.
        let facePreviewSource: BodyID? =
            (toolContext?.previewReplacesSource == true && toolContext?.preview != nil)
            ? toolContext?.sourceBody : nil

        // Isolate (spec §16.2): a transient override hides everything outside
        // the isolated set without touching persisted visibility.
        for body in session.document.bodies
        where !body.isHidden
            && body.id != facePreviewSource
            && (isolatedBodyIDs?.contains(body.id) ?? true) {
            var selectionState = SelectionStateNone.rawValue
            if selection.contains(body.id) {
                selectionState = SelectionStateSelected.rawValue
            }
            drawables.append(BodyDrawable(
                id: body.id,
                renderMesh: body.render,
                edges: body.edges,
                meshRevision: body.meshRevision,
                modelMatrix: body.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: selectionState,
                material: body.material.map {
                    BodyMaterial(
                        baseColor: SIMD4(
                            Float($0.baseColor.x), Float($0.baseColor.y),
                            Float($0.baseColor.z), Float($0.baseColor.w)
                        ),
                        metallic: Float($0.metallic),
                        roughness: Float($0.roughness)
                    )
                }
            ))
        }
        var scene = ViewportScene(bodies: drawables)

        // Tool preview (extrude/revolve): translucent accent body — except a
        // face push/pull preview replaces the source body, so it renders as a
        // solid selected body (the real edited result).
        if let preview = toolContext?.preview {
            let replacesSource = facePreviewSource != nil
            scene.bodies.append(BodyDrawable(
                id: preview.id,
                renderMesh: preview.render,
                edges: preview.edges,
                meshRevision: preview.meshRevision,
                modelMatrix: preview.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: replacesSource
                    ? SelectionStateSelected.rawValue : SelectionStatePreview.rawValue,
                isTranslucent: !replacesSource
            ))
        }

        // Selected-face highlight (Shapr3D: tap selects a face) — hidden once a
        // push/pull preview is showing, since the highlight sits at the
        // original face position while the preview body has already moved.
        if case .faceSelected(let bodyID) = mode,
           let context = toolContext,
           facePreviewSource == nil,
           let body = session.document.body(with: bodyID) {
            let matrix = body.transform.matrixFloat
            var triangles: [SIMD3<Float>] = []
            for t in context.faceTriangles where t < body.render.triangleCount {
                for k in 0..<3 {
                    let index = Int(body.render.indices[t * 3 + k])
                    let world = matrix * SIMD4(body.render.positions[index], 1)
                    triangles.append(SIMD3(world.x, world.y, world.z))
                }
            }
            if !triangles.isEmpty {
                scene.profileFills.append(SketchFillBatch(
                    triangles: triangles,
                    color: SIMD4(0.98, 0.55, 0.12, 0.35)
                ))
            }
        }

        // Pull arrow — "these arrows are the interface for creating an
        // extrude" (Shapr3D tutorial). Sits at the moving cap of the pull;
        // for revolve it lies along the plane tangent at the centroid.
        if let context = toolContext {
            let centroid = context.plane.toWorld(context.profile.centroid)
            switch context.kind {
            case .extrude(let distance):
                let n = context.plane.normal
                let tip = centroid + n * distance
                scene.pullArrow = PullArrowState(
                    origin: SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)),
                    direction: SIMD3(Float(n.x), Float(n.y), Float(n.z)),
                    isValid: context.isPendingValid
                )
            case .revolve:
                let t = context.plane.xAxis
                scene.pullArrow = PullArrowState(
                    origin: SIMD3(Float(centroid.x), Float(centroid.y), Float(centroid.z)),
                    direction: SIMD3(Float(t.x), Float(t.y), Float(t.z))
                )
            case .offsetPlane(let distance):
                let n = context.plane.normal
                let tip = centroid + n * distance
                scene.pullArrow = PullArrowState(
                    origin: SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)),
                    direction: SIMD3(Float(n.x), Float(n.y), Float(n.z))
                )
            case .sweep, .loft:
                break // no drag-editable parameter → no arrow
            }
        }

        if let origin = gizmoOrigin {
            scene.gizmo = GizmoState(origin: origin, scale: 1, highlighted: gizmoHighlight)
        }

        // Sketch overlay: committed entities dark, in-progress accent blue,
        // selected entities accent orange. The sketch BEING EDITED renders its
        // committed entities by definition state (plan §C4): GREEN when fully
        // defined, BLUE when under-defined.
        let committedColor = SIMD4<Float>(0.15, 0.17, 0.20, 1)
        let pendingColor = SIMD4<Float>(0.20, 0.48, 0.95, 1)
        let selectedColor = SIMD4<Float>(0.98, 0.55, 0.12, 1)
        let definedColor = SIMD4<Float>(0.20, 0.70, 0.35, 1)      // fully defined
        let underDefinedColor = SIMD4<Float>(0.20, 0.48, 0.95, 1) // under-defined
        // Hidden sketches are skipped — except the one being edited.
        let activeSketchID: SketchID? = {
            if case .sketching(let id, _) = mode { return id }
            return nil
        }()
        for sketch in session.document.sketches
        where !sketch.isHidden || sketch.id == activeSketchID {
            // Construction (reference) entities render dashed (spec §3.3).
            let construction = sketch.constructionEntityIDs
            let unselected = sketch.entities.filter { !selectedSketchEntityIDs.contains($0.id) }
            // Per-entity definition state, only for the sketch being edited.
            let states: [UUID: Bool]? = (sketch.id == activeSketchID)
                ? SketchSolverBridge.entityStates(sketch) : nil
            func committedColorFor(_ id: UUID) -> SIMD4<Float> {
                guard let states else { return committedColor }
                return (states[id] ?? false) ? definedColor : underDefinedColor
            }
            // Solid committed entities, grouped by state color.
            let regularUnselected = unselected.filter { !construction.contains($0.id) }
            for (color, group) in Dictionary(grouping: regularUnselected, by: { committedColorFor($0.id) }) {
                let segs = SketchTessellator.segments(for: group, on: sketch.plane)
                if !segs.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(segments: segs, color: color))
                }
            }
            // Dashed construction entities, grouped by state color.
            let constructionUnselected = unselected.filter { construction.contains($0.id) }
            for (color, group) in Dictionary(grouping: constructionUnselected, by: { committedColorFor($0.id) }) {
                let segs = SketchTessellator.dashedSegments(for: group, on: sketch.plane)
                if !segs.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(segments: segs, color: color))
                }
            }
            let selected = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
            let regularSelected = selected.filter { !construction.contains($0.id) }
            if !regularSelected.isEmpty {
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.segments(for: regularSelected, on: sketch.plane),
                    color: selectedColor
                ))
            }
            let constructionSelected = selected.filter { construction.contains($0.id) }
            if !constructionSelected.isEmpty {
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.dashedSegments(
                        for: constructionSelected, on: sketch.plane
                    ),
                    color: selectedColor
                ))
            }
            // Closed regions get a fill — the Shapr3D affordance that a
            // profile can be pulled into 3D.
            scene.profileFills.append(contentsOf: fillBatches(for: sketch))
        }
        if case .sketching(let activeID, _) = mode,
           let sketch = session.document.sketches.first(where: { $0.id == activeID }) {
            let pendings = [pendingEntity, pendingArcEntity].compactMap { $0 }
            if !pendings.isEmpty {
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.segments(for: pendings, on: sketch.plane),
                    color: pendingColor
                ))
            }
            // Selection gizmo (plan §B6, spec §1.10): move handle at the
            // selection centroid plus a rotate ring around it.
            if let centroid = sketchSelectionCentroid {
                scene.sketchLines.append(SketchLineBatch(
                    segments: sketchGizmoSegments(centroid: centroid, plane: sketch.plane),
                    color: selectedColor
                ))
            }
            // Live auto-constraint guides (plan §B): violet reference lines for
            // the relationships being inferred for the in-progress stroke.
            if !activeGuides.isEmpty {
                let guideColor = SIMD4<Float>(0.55, 0.30, 0.95, 1)
                var segs: [SIMD3<Float>] = []
                for guide in activeGuides {
                    let a = sketch.plane.toWorld(guide.a)
                    let b = sketch.plane.toWorld(guide.b)
                    segs.append(SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)))
                    segs.append(SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z)))
                }
                scene.sketchLines.append(SketchLineBatch(segments: segs, color: guideColor))
            }
        }

        // Pattern ghost preview (plan §B5): translucent body instances, or
        // accent-blue entity copies for sketch-profile patterns.
        if case .patterning = mode, let state = patternState {
            if let bodyID = state.bodyID,
               let body = session.document.body(with: bodyID) {
                for transform in patternTransforms(state).dropFirst() {
                    scene.bodies.append(BodyDrawable(
                        id: body.id,
                        renderMesh: body.render,
                        edges: body.edges,
                        meshRevision: body.meshRevision,
                        modelMatrix: Self.composedPatternTransform(
                            transform, base: body.transform
                        ).matrixFloat,
                        baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                        selectionState: SelectionStatePreview.rawValue,
                        isTranslucent: true
                    ))
                }
            } else if let sketchID = state.sketchID,
                      let sketch = session.document.sketches.first(where: { $0.id == sketchID }) {
                let entities = sketch.entities.filter { state.entityIDs.contains($0.id) }
                var ghosts: [SketchEntity] = []
                for transform in sketchPatternTransforms(state).dropFirst() {
                    for entity in entities {
                        ghosts.append(contentsOf: PatternKit.transformed(entity, by: transform))
                    }
                }
                if !ghosts.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(
                        segments: SketchTessellator.segments(for: ghosts, on: sketch.plane),
                        color: pendingColor
                    ))
                }
            }
        }

        // Construction planes: translucent bordered quads (spec §6.1).
        for plane in session.document.planes where !plane.isHidden {
            appendPlaneQuad(
                plane.plane, size: plane.size,
                fill: SIMD4(0.45, 0.58, 0.80, 0.16),
                border: SIMD4(0.45, 0.58, 0.80, 0.85),
                into: &scene
            )
        }
        // Pending offset plane: accent quad tracking the pull.
        if let context = toolContext, case .offsetPlane(let distance) = context.kind {
            let pending = offsetPlanePreview(context, distance: distance)
            appendPlaneQuad(
                pending.plane, size: pending.size,
                fill: SIMD4(0.98, 0.55, 0.12, 0.20),
                border: SIMD4(0.98, 0.55, 0.12, 0.9),
                into: &scene
            )
        }

        // Inserted reference images (plan §B10): textured quads, plus an
        // accent outline around the selected one.
        for image in session.document.images where !image.isHidden {
            let plane = image.plane
            let origin = SIMD3<Float>(
                Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
            )
            scene.imageQuads.append(ImageQuadDrawable(
                id: image.id.raw,
                origin: origin,
                xAxis: SIMD3(Float(plane.xAxis.x), Float(plane.xAxis.y), Float(plane.xAxis.z)),
                yAxis: SIMD3(Float(plane.yAxis.x), Float(plane.yAxis.y), Float(plane.yAxis.z)),
                width: Float(image.width),
                height: Float(image.height),
                opacity: Float(image.opacity),
                textureData: image.imageData
            ))
            if image.id == selectedImageID {
                let hw = image.width / 2
                let hh = image.height / 2
                let corners = [
                    SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh), SIMD2(-hw, hh),
                ].map { (corner: SIMD2<Double>) -> SIMD3<Float> in
                    let world = plane.toWorld(corner)
                    return SIMD3(Float(world.x), Float(world.y), Float(world.z))
                }
                scene.sketchLines.append(SketchLineBatch(
                    segments: [corners[0], corners[1], corners[1], corners[2],
                               corners[2], corners[3], corners[3], corners[0]],
                    color: SIMD4(0.98, 0.55, 0.12, 1)
                ))
            }
        }

        // Plane pickers while a sketch tool waits for its plane, while the
        // Split tool waits for a cutter plane, while Section View waits for
        // its plane, or while Insert Image waits for its target plane.
        switch mode {
        case .pickingSketchPlane, .pickingSplitCutter, .pickingSectionPlane, .pickingImagePlane:
            scene.planePickers = PlanePicking.worldTiles + constructionPlaneTiles
        default:
            break
        }

        // Display mode + Section View (spec §16, plan §B11/§B12).
        scene.displayMode = displayMode
        scene.showHiddenEdges = showHiddenEdges
        scene.groundShadow = groundShadowEnabled
        if let section = sectionState {
            let plane = section.plane
            let n = simd_normalize(section.basePlane.normal)
            let keep = section.flipped ? -n : n
            scene.sectionPlane = SectionPlaneState(
                point: SIMD3(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)),
                normal: SIMD3(Float(keep.x), Float(keep.y), Float(keep.z))
            )
            // The plane rectangle, nudged a hair to the kept side so its own
            // fill/border survive the clip test in the sketch shaders.
            var quadPlane = plane
            quadPlane.origin += keep * 1e-3
            appendPlaneQuad(
                quadPlane, size: section.size,
                fill: SIMD4(0.98, 0.55, 0.12, 0.10),
                border: SIMD4(0.98, 0.55, 0.12, 0.85),
                into: &scene
            )
            // Pull arrow moves the plane along its normal (offset-plane drag
            // pattern); an active profile tool keeps its own arrow.
            if toolContext == nil {
                scene.pullArrow = PullArrowState(
                    origin: SIMD3(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)),
                    direction: SIMD3(Float(n.x), Float(n.y), Float(n.z))
                )
            }
        }

        // Measure/Translate/Align picks: cross markers at each picked point
        // (+ the span line for a completed measure).
        let markerPoints: [SIMD3<Double>] = {
            switch mode {
            case .measuring: return measurePoints
            case .translating, .aligning: return transformPickPoints
            default: return []
            }
        }()
        if !markerPoints.isEmpty {
            var segments: [SIMD3<Float>] = []
            let r = Float(max(0.12, 8 * worldPerPoint))
            for p in markerPoints {
                let c = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                segments += [
                    c - SIMD3(r, 0, 0), c + SIMD3(r, 0, 0),
                    c - SIMD3(0, r, 0), c + SIMD3(0, r, 0),
                    c - SIMD3(0, 0, r), c + SIMD3(0, 0, r),
                ]
            }
            if measurePoints.count == 2 {
                let a = measurePoints[0]
                let b = measurePoints[1]
                segments += [
                    SIMD3(Float(a.x), Float(a.y), Float(a.z)),
                    SIMD3(Float(b.x), Float(b.y), Float(b.z)),
                ]
            }
            scene.sketchLines.append(SketchLineBatch(
                segments: segments,
                color: SIMD4(0.98, 0.55, 0.12, 1)
            ))
        }
        return scene
    }

    /// Translucent bordered quad for a plane (construction planes and the
    /// pending offset plane), drawn via the fill/line batches.
    private func appendPlaneQuad(
        _ plane: SketchPlane, size: Double,
        fill: SIMD4<Float>, border: SIMD4<Float>,
        into scene: inout ViewportScene
    ) {
        let h = size / 2
        let corners = [
            SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h),
        ].map { (corner: SIMD2<Double>) -> SIMD3<Float> in
            let world = plane.toWorld(corner)
            return SIMD3(Float(world.x), Float(world.y), Float(world.z))
        }
        scene.profileFills.append(SketchFillBatch(
            triangles: [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]],
            color: fill
        ))
        scene.sketchLines.append(SketchLineBatch(
            segments: [corners[0], corners[1], corners[1], corners[2],
                       corners[2], corners[3], corners[3], corners[0]],
            color: border
        ))
    }

    /// Tappable quads for the document's visible construction planes.
    private var constructionPlaneTiles: [PlanePickerTile] {
        session.document.planes.filter { !$0.isHidden }.map { plane in
            let h = plane.size / 2
            return PlanePickerTile(
                planeID: plane.id,
                plane: plane.plane,
                localMin: SIMD2(-h, -h),
                localMax: SIMD2(h, h),
                color: SIMD4(0.45, 0.58, 0.80, 0.30)
            )
        }
    }

    /// Gizmo attach point: a single selected body's pivot, or the shared
    /// centroid of pivots for multi-selections (plan §B13). Whole-body
    /// selections only — face selections use the pull arrow instead. A
    /// selected inserted image (plan §B10) attaches the gizmo at its center.
    var gizmoOrigin: SIMD3<Float>? {
        if let image = selectedImage {
            let center = image.plane.origin
            return SIMD3(Float(center.x), Float(center.y), Float(center.z))
        }
        switch mode {
        case .selected, .editingPrimitive:
            break
        default:
            return nil
        }
        var sum = SIMD3<Double>.zero
        var count = 0
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            sum += body.transform.translation
            count += 1
        }
        guard count > 0 else { return nil }
        let centroid = sum / Double(count)
        return SIMD3(Float(centroid.x), Float(centroid.y), Float(centroid.z))
    }

    // MARK: - Move drags (gizmo)

    private var moveBefore: [BodyID: Transform3D]?

    /// Copy badge (spec §5.1): when on, the next gizmo drag duplicates the
    /// selection and moves the copy. Resets after each drag.
    var copyOnDrag = false

    func beginMove() {
        // Selected inserted image (plan §B10): the gizmo drags it in-plane.
        if selectedImage != nil {
            axisEntryPart = nil
            scaleEntryActive = false
            if copyOnDrag {
                copyOnDrag = false
                duplicateSelectedImageForDrag()
            }
            beginImageInteraction()
            return
        }
        guard !selection.isEmpty else { return }
        axisEntryPart = nil
        scaleEntryActive = false
        if copyOnDrag {
            copyOnDrag = false
            duplicateSelectionForDrag()
        }
        var before = [BodyID: Transform3D]()
        for id in selection {
            if let body = session.document.body(with: id) {
                before[id] = body.transform
            }
        }
        moveBefore = before
    }

    /// Copy badge: clone each selected body in place (AddBodyCommand, new id,
    /// shared CoW buffers) and switch the selection so the drag moves the copy.
    private func duplicateSelectionForDrag() {
        var copies: Set<BodyID> = []
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            var clone = Body(
                id: BodyID(),
                name: session.document.uniqueBodyName(base: body.name),
                transform: body.transform,
                primitive: body.primitive,
                render: body.render,
                revision: body.meshRevision
            )
            clone.euclid = body.euclid
            session.perform(AddBodyCommand(body: clone, title: "Copy \(body.name)"))
            copies.insert(clone.id)
        }
        guard !copies.isEmpty else { return }
        selection = copies
        if copies.count == 1, let id = copies.first {
            mode = session.document.body(with: id)?.primitive != nil
                ? .editingPrimitive(id)
                : .selected(id)
        }
    }

    func updateMove(delta: SIMD3<Float>) {
        if imageInteractionBaseline != nil {
            updateImageMove(delta: delta)
            return
        }
        guard let moveBefore else { return }
        let worldDelta = SIMD3<Double>(Double(delta.x), Double(delta.y), Double(delta.z))
        session.preview { document in
            for (id, original) in moveBefore {
                if let index = document.bodyIndex(of: id) {
                    var transform = original
                    transform.translation += worldDelta
                    document.bodies[index].transform = transform
                }
            }
        }
    }

    /// Ring drag: rotate about the ring axis through each body's own pivot
    /// (quaternion delta pre-multiplied; translation unchanged). Snaps in
    /// 5° increments while dragging (spec §5.3).
    func updateRotation(part: GizmoPart, deltaRadians: Float) {
        guard let moveBefore, part.isRing else { return }
        let degrees = (Double(deltaRadians) * 180 / .pi / 5).rounded() * 5
        let axis = part.axisDirection
        let q = simd_quatd(
            angle: degrees * .pi / 180,
            axis: SIMD3(Double(axis.x), Double(axis.y), Double(axis.z))
        )
        session.preview { document in
            for (id, original) in moveBefore {
                if let index = document.bodyIndex(of: id) {
                    var transform = original
                    transform.rotation = simd_normalize(q * original.rotation)
                    document.bodies[index].transform = transform
                }
            }
        }
    }

    func endMove() {
        if imageInteractionBaseline != nil {
            endImageInteraction()
            return
        }
        guard let before = moveBefore else { return }
        moveBefore = nil
        var after = [BodyID: Transform3D]()
        var changed = false
        for (id, original) in before {
            if let body = session.document.body(with: id) {
                after[id] = body.transform
                if body.transform != original { changed = true }
            }
        }
        guard changed else { return }
        session.perform(TransformBodiesCommand(before: before, after: after))
    }

    // MARK: - Gizmo numeric entry (tap an arrow → exact axis distance)

    /// Arrow awaiting a typed distance (set by tapping, not dragging, a
    /// gizmo arrow; shows the distance field in NumericInputBar).
    var axisEntryPart: GizmoPart?

    func beginAxisDistanceEntry(_ part: GizmoPart) {
        guard part.isArrow, gizmoOrigin != nil else { return }
        scaleEntryActive = false
        axisEntryPart = part
    }

    func cancelAxisDistanceEntry() {
        axisEntryPart = nil
    }

    /// Move the selection by exactly `distance` along the tapped arrow's axis.
    func commitAxisMove(distance: Double) {
        guard let part = axisEntryPart else { return }
        axisEntryPart = nil
        guard abs(distance) > 1e-9 else { return }
        let a = part.axisDirection
        let axis = SIMD3(Double(a.x), Double(a.y), Double(a.z))
        // Selected image (plan §B10): exact in-plane move along the axis.
        if let image = selectedImage {
            let plane = image.plane
            let delta = axis * distance
            var after = image
            after.plane.origin = plane.origin
                + plane.xAxis * simd_dot(delta, plane.xAxis)
                + plane.yAxis * simd_dot(delta, plane.yAxis)
            commitImageEdit(after, title: "Move Image")
            return
        }
        var before = [BodyID: Transform3D]()
        var after = [BodyID: Transform3D]()
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            before[id] = body.transform
            var transform = body.transform
            transform.translation += axis * distance
            after[id] = transform
        }
        guard !after.isEmpty else { return }
        session.perform(TransformBodiesCommand(before: before, after: after))
        session.save()
    }

    // MARK: - Scale (uniform, about the body pivot — spec §5.4 v1)

    /// True while the palette's Scale tool shows its factor field.
    var scaleEntryActive = false

    /// Factor typed in the scale bar; an empty-grid tap commits it
    /// (spec §5.4 "commit by tapping empty grid").
    var scalePendingFactor: Double = 1

    /// Copy badge on the scale bar (spec §5.4): committing scales a
    /// duplicate, keeping the original.
    var scaleCopyOnCommit = false

    func beginScaleEntry() {
        guard !selection.isEmpty else { return }
        cancelTransientPicks()
        axisEntryPart = nil
        scalePendingFactor = 1
        scaleCopyOnCommit = false
        scaleEntryActive = true
    }

    func cancelScaleEntry() {
        scaleEntryActive = false
        scaleCopyOnCommit = false
    }

    /// Multiply each selected body's uniform scale by `factor`. Transform3D
    /// scales about the translation point, so this is scale-about-pivot.
    /// With the Copy badge on, scaled duplicates are added instead.
    func commitScale(factor: Double) {
        scaleEntryActive = false
        let copy = scaleCopyOnCommit
        scaleCopyOnCommit = false
        guard factor > 0.001 else {
            errorMessage = "Scale factor must be greater than 0.001."
            return
        }
        if copy {
            commitScaleCopy(factor: factor)
            return
        }
        guard abs(factor - 1) > 1e-9 else { return }
        var before = [BodyID: Transform3D]()
        var after = [BodyID: Transform3D]()
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            before[id] = body.transform
            var transform = body.transform
            transform.scale *= factor
            after[id] = transform
        }
        guard !after.isEmpty else { return }
        session.perform(TransformBodiesCommand(title: "Scale", before: before, after: after))
        session.save()
    }

    /// Copy badge: add scaled duplicates in one undo step (originals keep
    /// their size); the copies become the selection.
    private func commitScaleCopy(factor: Double) {
        var document = session.document // local: unique names + revisions
        var commands: [DocumentCommand] = []
        var ids: Set<BodyID> = []
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            var transform = body.transform
            transform.scale *= factor
            var clone = Body(
                id: BodyID(),
                name: document.uniqueBodyName(base: body.name),
                transform: transform,
                primitive: body.primitive,
                render: body.render,
                revision: document.nextRevision()
            )
            clone.euclid = body.euclid
            document.bodies.append(clone) // keeps the next name unique
            commands.append(AddBodyCommand(body: clone, title: "Scale Copy"))
            ids.insert(clone.id)
        }
        guard !commands.isEmpty else { return }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Scale Copy", commands: commands))
        selection = ids
        if ids.count == 1, let id = ids.first {
            mode = .selected(id)
        }
        session.save()
    }

    // MARK: - Rotate Around Axis (plan §B6, spec §5.3)

    struct RotateAxisState {
        /// World axis line; nil until picked (sketch line or world-axis
        /// button).
        var axisPoint: SIMD3<Double>?
        var axisDirection: SIMD3<Double>?
        var angleDegrees: Double = 0
        /// Transforms when the tool opened (preview baseline + undo `before`).
        var before: [BodyID: Transform3D]

        var hasAxis: Bool { axisPoint != nil && axisDirection != nil }
    }

    var rotateAxisState: RotateAxisState?
    /// Angle when the current scrub drag began (5°-snapped drags, spec §5.3).
    private var rotateDragStartDegrees: Double = 0

    func beginRotateAxisPick() {
        guard !selection.isEmpty else { return }
        cancelTransientPicks()
        cancelTool()
        axisEntryPart = nil
        scaleEntryActive = false
        var before = [BodyID: Transform3D]()
        for id in selection {
            if let body = session.document.body(with: id) {
                before[id] = body.transform
            }
        }
        guard !before.isEmpty else { return }
        rotateAxisState = RotateAxisState(before: before)
        mode = .rotatingAroundAxis
    }

    func cancelRotateAxis() {
        if let state = rotateAxisState {
            session.preview { document in
                for (id, original) in state.before {
                    if let index = document.bodyIndex(of: id) {
                        document.bodies[index].transform = original
                    }
                }
            }
        }
        rotateAxisState = nil
        if case .rotatingAroundAxis = mode {
            mode = .idle
        }
    }

    /// World-axis button in the pill: the axis runs through the origin.
    func setRotateWorldAxis(_ axis: PatternState.Axis) {
        guard var state = rotateAxisState else { return }
        state.axisPoint = .zero
        state.axisDirection = axis.direction
        rotateAxisState = state
        applyRotateAxisPreview()
    }

    func setRotateAngle(_ degrees: Double) {
        guard var state = rotateAxisState, state.hasAxis else { return }
        state.angleDegrees = degrees
        rotateAxisState = state
        applyRotateAxisPreview()
    }

    private func applyRotateAxisPreview() {
        guard let state = rotateAxisState,
              let point = state.axisPoint,
              let direction = state.axisDirection
        else { return }
        let radians: Double = state.angleDegrees * Double.pi / 180
        session.preview { document in
            for (id, original) in state.before {
                if let index = document.bodyIndex(of: id) {
                    document.bodies[index].transform = original.rotated(
                        byRadians: radians, aboutAxisThrough: point, direction: direction
                    )
                }
            }
        }
    }

    /// Drag while the axis is set scrubs the angle in 5° steps.
    func beginRotateAxisDrag() -> Bool {
        guard let state = rotateAxisState, state.hasAxis else { return false }
        rotateDragStartDegrees = state.angleDegrees
        return true
    }

    func updateRotateAxisDrag(screenDeltaWorld: Double) {
        guard rotateAxisState?.hasAxis == true else { return }
        let raw = rotateDragStartDegrees + screenDeltaWorld * Self.revolveDegreesPerWorldUnit
        setRotateAngle((raw / 5).rounded() * 5)
    }

    func commitRotateAxis() {
        guard let state = rotateAxisState,
              let point = state.axisPoint,
              let direction = state.axisDirection,
              abs(state.angleDegrees) > 1e-9
        else {
            cancelRotateAxis()
            return
        }
        let radians: Double = state.angleDegrees * Double.pi / 180
        var after = [BodyID: Transform3D]()
        for (id, original) in state.before {
            after[id] = original.rotated(
                byRadians: radians, aboutAxisThrough: point, direction: direction
            )
        }
        rotateAxisState = nil
        session.perform(TransformBodiesCommand(title: "Rotate", before: state.before, after: after))
        mode = .idle
        session.save()
    }

    /// Tap while rotating: with no axis yet, a sketch LINE sets it; with the
    /// axis set, tapping empty space commits (the shared grid convention).
    private func handleRotateAxisTap(ray: Ray) {
        guard let state = rotateAxisState else {
            mode = .idle
            return
        }
        if state.hasAxis {
            commitRotateAxis()
            return
        }
        guard let hit = nearestSketchLine(to: ray) else { return }
        let a = hit.plane.toWorld(hit.a)
        let direction = hit.plane.toWorld(hit.b) - a
        guard simd_length(direction) > 1e-9 else { return }
        var updated = state
        updated.axisPoint = a
        updated.axisDirection = simd_normalize(direction)
        rotateAxisState = updated
    }

    /// Nearest LINE entity under the ray across visible sketches.
    private func nearestSketchLine(
        to ray: Ray
    ) -> (a: SIMD2<Double>, b: SIMD2<Double>, plane: SketchPlane)? {
        let tolerance = max(0.4, 16 * worldPerPoint)
        var best: (a: SIMD2<Double>, b: SIMD2<Double>, plane: SketchPlane, distance: Double)?
        for sketch in session.document.sketches where !sketch.isHidden {
            guard let local = localPoint(of: ray, on: sketch.plane) else { continue }
            for entity in sketch.entities {
                guard case .line(_, let a, let b) = entity else { continue }
                let d = Self.distanceToSegment(local, a: a, b: b)
                if d <= tolerance, best == nil || d < best!.distance {
                    best = (a, b, sketch.plane, d)
                }
            }
        }
        return best.map { ($0.a, $0.b, $0.plane) }
    }

    // MARK: - Translate (spec §5.2) & Align (spec §5.5 v1)

    /// Source point picked so far for Translate/Align (marker + pill state).
    var transformPickPoints: [SIMD3<Double>] = []
    /// Body that moves in an Align (owner of the first tapped snap point).
    private var alignSourceBody: BodyID?

    func beginTranslatePick() {
        guard !selection.isEmpty else { return }
        cancelTransientPicks()
        cancelTool()
        axisEntryPart = nil
        scaleEntryActive = false
        transformPickPoints = []
        mode = .translating
    }

    func cancelTranslate() {
        transformPickPoints = []
        if case .translating = mode {
            mode = .idle
        }
    }

    func beginAlignPick() {
        guard session.document.bodies.count >= 2 else { return }
        cancelTransientPicks()
        cancelTool()
        axisEntryPart = nil
        scaleEntryActive = false
        transformPickPoints = []
        alignSourceBody = nil
        selection.removeAll()
        mode = .aligning
    }

    func cancelAlign() {
        transformPickPoints = []
        alignSourceBody = nil
        if case .aligning = mode {
            mode = .idle
        }
    }

    /// Cancel every transient pick/preview mode (rotate-around-axis preview,
    /// translate/align picks, pattern bar, split/boolean cutter picks). Each
    /// cancel is a no-op outside its own mode, so this is safe to call from
    /// any surface that takes over — palette tools, the Items panel, measure,
    /// sketching, import. Notably reverts the rotate preview, which mutates
    /// transforms outside the undo stack until committed.
    private func cancelTransientPicks() {
        cancelRotateAxis()
        cancelTranslate()
        cancelAlign()
        cancelPattern()
        cancelSplitCutterPick()
        cancelBooleanPicking()
        cancelSectionPlanePick()
        cancelImagePlanePick()
    }

    /// Translate: first tap picks the source snap point, second the
    /// destination; the selection shifts by the exact delta.
    private func handleTranslateTap(ray: Ray) {
        guard let point = translateSnapPoint(to: ray) else { return }
        if transformPickPoints.isEmpty {
            transformPickPoints = [point]
            return
        }
        let delta = point - transformPickPoints[0]
        transformPickPoints = []
        guard simd_length(delta) > 1e-9 else {
            mode = .idle
            return
        }
        var before = [BodyID: Transform3D]()
        var after = [BodyID: Transform3D]()
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            before[id] = body.transform
            var transform = body.transform
            transform.translation += delta
            after[id] = transform
        }
        guard !after.isEmpty else {
            mode = .idle
            return
        }
        session.perform(TransformBodiesCommand(title: "Translate", before: before, after: after))
        if selection.count == 1, let id = selection.first {
            mode = .selected(id)
        } else {
            mode = .idle
        }
        session.save()
    }

    /// Snap for Translate picks: notable points (vertices, sketch points)
    /// first, then the ground-plane grid.
    private func translateSnapPoint(to ray: Ray) -> SIMD3<Double>? {
        if let notable = nearestNotablePoint(to: ray) { return notable }
        guard let t = ray.intersect(planePoint: .zero, planeNormal: SIMD3(0, 1, 0)) else {
            return nil
        }
        let world = ray.point(at: t)
        let g = SnapEngine.gridSpacing
        return SIMD3(
            (Double(world.x) / g).rounded() * g,
            0,
            (Double(world.z) / g).rounded() * g
        )
    }

    /// Align: tap a snap point on the body that moves, then the destination
    /// point on another body; the first body translates so they coincide.
    private func handleAlignTap(ray: Ray) {
        if alignSourceBody == nil {
            guard let hit = nearestBodyVertex(to: ray) else { return }
            alignSourceBody = hit.bodyID
            transformPickPoints = [hit.point]
            return
        }
        guard let source = alignSourceBody,
              let anchor = transformPickPoints.first,
              let body = session.document.body(with: source)
        else {
            cancelAlign()
            return
        }
        guard let hit = nearestBodyVertex(to: ray, excluding: source) else { return }
        transformPickPoints = []
        alignSourceBody = nil
        let delta = hit.point - anchor
        guard simd_length(delta) > 1e-9 else {
            mode = .idle
            return
        }
        var transform = body.transform
        transform.translation += delta
        session.perform(TransformBodiesCommand(
            title: "Align", before: [source: body.transform], after: [source: transform]
        ))
        selection = [source]
        mode = .selected(source)
        session.save()
    }

    /// Nearest render vertex across visible bodies, with its owner
    /// (Align's purple snap points, v1).
    private func nearestBodyVertex(
        to ray: Ray, excluding: BodyID? = nil
    ) -> (point: SIMD3<Double>, bodyID: BodyID)? {
        let tolerance = max(0.5, 30 * worldPerPoint)
        var best: (point: SIMD3<Double>, bodyID: BodyID, distance: Double)?
        for body in session.document.bodies
        where !body.isHidden && body.id != excluding {
            for position in body.render.positions {
                let p = body.transform.applying(to: SIMD3<Double>(position))
                let pf = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                let t = simd_dot(pf - ray.origin, ray.direction)
                guard t > 0 else { continue }
                let d = Double(simd_length(pf - ray.point(at: t)))
                if d <= tolerance, best == nil || d < best!.distance {
                    best = (p, body.id, d)
                }
            }
        }
        return best.map { ($0.point, $0.bodyID) }
    }

    // MARK: - Mirror (spec §5.6, Keep Original always on for v1)

    /// Mirror planes offered by the palette: world planes plus any
    /// construction planes in the document.
    var mirrorPlaneOptions: [(label: String, plane: SketchPlane)] {
        var options: [(label: String, plane: SketchPlane)] = [
            ("XY Plane", .worldXY),
            ("YZ Plane", .worldYZ),
            ("Ground (ZX)", .ground),
        ]
        for (index, plane) in session.document.planes.enumerated() {
            options.append(("Plane \(index + 1)", plane.plane))
        }
        return options
    }

    /// Mirror every selected body across `plane` into new bodies (one undo
    /// step for multi-selections, plan §B13).
    func mirrorSelection(across plane: SketchPlane) {
        cancelTransientPicks()
        guard !selection.isEmpty else { return }
        let n = simd_normalize(plane.normal)
        var document = session.document // local: unique names as we go
        var commands: [DocumentCommand] = []
        var ids: Set<BodyID> = []
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            let world = body.euclidMesh().transformed(by: body.transform.euclid)
            let mirrored = KernelOps.mirror(mesh: world, across: plane)
            guard !mirrored.polygons.isEmpty else { continue }
            // Pivot of the copy: the original pivot reflected across the plane.
            let t = body.transform.translation
            let pivot = t - 2 * simd_dot(t - plane.origin, n) * n
            var transform = Transform3D.identity
            transform.translation = pivot
            let localMesh = mirrored.translated(by: Vector(-pivot.x, -pivot.y, -pivot.z))
            let copy = Body(
                name: document.uniqueBodyName(base: body.name),
                transform: transform,
                primitive: nil,
                euclidMesh: localMesh,
                revision: body.meshRevision
            )
            document.bodies.append(copy) // keeps the next name unique
            commands.append(AddBodyCommand(body: copy, title: "Mirror"))
            // Phase D: record a `.mirror` history node for a feature-owned source
            // so the reflected copy rebuilds associatively. Bundled into the same
            // command list (one CompositeCommand) so a single undo drops the copy
            // and its node together. Non-feature sources (import/seed) can't be
            // replayed, so they're mirrored geometry-only.
            if let owner = featureNode(owning: id) {
                let mirrorNode = FeatureNode(
                    name: "Mirror",
                    kind: .mirror(
                        body: BodyRef(producer: owner.id, bodyID: id),
                        plane: PlaneRef(source: .explicit(plane)),
                        keepOriginal: true
                    ),
                    outputBodyIDs: [copy.id]
                )
                commands.append(AppendFeatureCommand(node: mirrorNode))
            }
            ids.insert(copy.id)
        }
        guard !commands.isEmpty else {
            errorMessage = "Mirror produced no geometry."
            return
        }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Mirror", commands: commands))
        selection = ids
        updateModeForSelection()
        session.save()
    }

    // MARK: - Split Body (plan §B3, spec §4.9 v1: one plane or profile cutter)

    /// "Split" in the palette: the next tap picks the cutter — a world or
    /// construction plane tile, or a sketch profile fill.
    func beginSplitCutterPick() {
        guard selection.count == 1, let target = selection.first,
              session.document.body(with: target) != nil
        else { return }
        cancelTransientPicks()
        cancelTool()
        mode = .pickingSplitCutter(target: target)
    }

    func cancelSplitCutterPick() {
        if case .pickingSplitCutter = mode {
            mode = .idle
        }
    }

    /// Tap while the split pick is armed: plane tiles win over the body
    /// (cutter planes usually pass through it), then profile fills. Taps that
    /// miss every cutter keep the pick armed.
    private func handleSplitCutterTap(target: BodyID, ray: Ray) {
        guard let body = session.document.body(with: target) else {
            mode = .idle
            return
        }
        let world = body.euclidMesh().transformed(by: body.transform.euclid)
        let tiles = PlanePicking.worldTiles + constructionPlaneTiles
        if let hit = PlanePicking.pick(ray: ray, tiles: tiles) {
            let halves = KernelOps.split(body: world, byPlane: hit.tile.plane)
            performSplit(of: body, halves: (halves.kept, halves.other))
            return
        }
        if let fill = profileHit(ray: ray) {
            let halves = KernelOps.split(
                body: world, byProfile: fill.profile, holes: fill.holes, in: fill.plane
            )
            performSplit(of: body, halves: (halves.inside, halves.outside))
        }
    }

    /// Replace the body with the first half and add the second as a new body
    /// (one undo step — Keep Originals is what undo restores); both halves
    /// end up selected. Halves are named "<name> A" / "<name> B" so the Items
    /// Manager shows where they came from.
    private func performSplit(of body: Body, halves: (Euclid.Mesh, Euclid.Mesh)) {
        guard !halves.0.polygons.isEmpty, !halves.1.polygons.isEmpty else {
            errorMessage = "The cutter doesn't pass through the body — nothing to split."
            return
        }
        var document = session.document // local: unique name + revision
        // First half keeps the original pivot (like commitToolResult).
        let pivotA = body.transform.translation
        var transformA = Transform3D.identity
        transformA.translation = pivotA
        let first = Body(
            id: body.id,
            name: document.uniqueBodyName(base: "\(body.name) A"),
            transform: transformA,
            primitive: nil,
            euclidMesh: halves.0.translated(by: Vector(-pivotA.x, -pivotA.y, -pivotA.z)),
            revision: 0 // assigned by the command
        )
        // Second half pivots at its own bounds center.
        let boundsB = halves.1.bounds
        let pivotB = SIMD3(
            (boundsB.min.x + boundsB.max.x) / 2,
            (boundsB.min.y + boundsB.max.y) / 2,
            (boundsB.min.z + boundsB.max.z) / 2
        )
        var transformB = Transform3D.identity
        transformB.translation = pivotB
        let second = Body(
            name: document.uniqueBodyName(base: "\(body.name) B"),
            transform: transformB,
            primitive: nil,
            euclidMesh: halves.1.translated(by: Vector(-pivotB.x, -pivotB.y, -pivotB.z)),
            revision: document.nextRevision()
        )
        session.perform(CompositeCommand(title: "Split", commands: [
            ReplaceBodyCommand(title: "Split", before: body, after: first),
            AddBodyCommand(body: second, title: "Split"),
        ]))
        selection = [body.id, second.id]
        mode = .idle
        session.save()
    }

    // MARK: - Pattern (plan §B5, spec §5.7 bodies / §1.11 sketch profiles, v1)

    struct PatternState {
        enum Kind: String, CaseIterable {
            case linear = "Linear"
            case circular = "Circular"
        }

        enum Axis: String, CaseIterable {
            case x = "X"
            case y = "Y"
            case z = "Z"

            var direction: SIMD3<Double> {
                switch self {
                case .x: SIMD3(1, 0, 0)
                case .y: SIMD3(0, 1, 0)
                case .z: SIMD3(0, 0, 1)
                }
            }

            /// In-plane direction for sketch patterns (Z folds onto X).
            var sketchDirection: SIMD2<Double> {
                self == .y ? SIMD2(0, 1) : SIMD2(1, 0)
            }
        }

        var kind: Kind = .linear
        var axis: Axis = .x
        /// Total instances, original included.
        var count = 3
        /// Adjacent-center distance (linear).
        var spacing = 6.0
        /// First→last sweep in degrees (circular; 360 closes the ring).
        var totalAngle = 360.0
        /// Body being patterned; nil for a sketch-profile pattern.
        var bodyID: BodyID?
        /// Sketch-profile pattern (armed from extrude mode): source sketch
        /// plus the profile's entities.
        var sketchID: SketchID?
        var entityIDs: Set<UUID> = []

        var isSketchPattern: Bool { bodyID == nil }
    }

    var patternState: PatternState? {
        didSet { fitCameraToPatternGhosts() }
    }

    /// Keep every ghost instance in frame while the pattern bar is up —
    /// param changes can push instances far outside the current view.
    private func fitCameraToPatternGhosts() {
        guard case .patterning = mode, let state = patternState,
              let bodyID = state.bodyID,
              let body = session.document.body(with: bodyID)
        else { return }
        let aabb = body.render.localAABB
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = -lo
        for transform in patternTransforms(state) {
            let matrix = Self.composedPatternTransform(transform, base: body.transform).matrixFloat
            for i in 0..<8 {
                let corner = SIMD3<Float>(
                    (i & 1) == 0 ? aabb.min.x : aabb.max.x,
                    (i & 2) == 0 ? aabb.min.y : aabb.max.y,
                    (i & 4) == 0 ? aabb.min.z : aabb.max.z
                )
                let world = matrix * SIMD4(corner, 1)
                lo = simd_min(lo, SIMD3(world.x, world.y, world.z))
                hi = simd_max(hi, SIMD3(world.x, world.y, world.z))
            }
        }
        guard lo.x <= hi.x else { return }
        cameraControl?.fitTo(bounds: (lo, hi))
    }

    /// True when the palette Pattern action applies: one body selected, or a
    /// sketch profile armed in the extrude tool.
    var canBeginPattern: Bool {
        if selection.count == 1 { return true }
        if case .extruding = mode, let context = toolContext,
           case .extrude = context.kind, context.sketchID != nil {
            return true
        }
        return false
    }

    /// "Pattern" in the palette: opens the pattern bar for the selected body,
    /// or — while a profile fill is armed for extrude — for the profile's
    /// sketch entities (patterned in-plane, spec §1.11).
    func beginPattern() {
        cancelTransientPicks()
        if case .extruding = mode, let context = toolContext,
           case .extrude = context.kind, let sketchID = context.sketchID {
            var ids = context.profile.sourceEntityIDs
            for hole in context.holes {
                ids.formUnion(hole.sourceEntityIDs)
            }
            guard !ids.isEmpty else { return }
            cancelTool()
            var state = PatternState()
            state.sketchID = sketchID
            state.entityIDs = ids
            patternState = state
            mode = .patterning
            return
        }
        guard selection.count == 1, let id = selection.first,
              session.document.body(with: id) != nil
        else { return }
        cancelTool()
        var state = PatternState()
        state.bodyID = id
        patternState = state
        mode = .patterning
        fitCameraToPatternGhosts() // mode wasn't set yet during didSet
    }

    func cancelPattern() {
        patternState = nil
        if case .patterning = mode {
            mode = .idle
        }
    }

    /// 3D instance transforms for the current parameters; the first is always
    /// identity (the original). Circular patterns spin about the chosen world
    /// axis through the origin in v1.
    private func patternTransforms(_ state: PatternState) -> [Transform3D] {
        switch state.kind {
        case .linear:
            return PatternKit.linearTransforms(
                direction: state.axis.direction,
                spacing: state.spacing,
                count: max(1, state.count)
            )
        case .circular:
            return PatternKit.circularTransforms(
                center: .zero,
                axis: state.axis.direction,
                count: max(1, state.count),
                totalAngle: state.totalAngle * .pi / 180,
                rotateInstances: true
            )
        }
    }

    /// Sketch-space instance transforms (spec §1.11); circular patterns spin
    /// about the sketch-plane origin in v1.
    private func sketchPatternTransforms(_ state: PatternState) -> [SketchPatternTransform] {
        switch state.kind {
        case .linear:
            return PatternKit.linearSketchTransforms(
                direction: state.axis.sketchDirection,
                spacing: state.spacing,
                count: max(1, state.count)
            )
        case .circular:
            return PatternKit.circularSketchTransforms(
                center: .zero,
                count: max(1, state.count),
                totalAngle: state.totalAngle * .pi / 180,
                rotateInstances: true
            )
        }
    }

    /// Pattern transform composed onto a body transform:
    /// world = q.act(base(x)) + t, so rotation/translation pre-compose.
    nonisolated static func composedPatternTransform(
        _ pattern: Transform3D, base: Transform3D
    ) -> Transform3D {
        var result = base
        result.rotation = simd_normalize(pattern.rotation * base.rotation)
        result.translation = pattern.rotation.act(base.translation) + pattern.translation
        return result
    }

    /// Commit the armed pattern: one CompositeCommand adding count−1
    /// instances (bodies, or transformed sketch entities).
    func commitPattern() {
        guard case .patterning = mode, let state = patternState else { return }
        guard state.count >= 2 else {
            errorMessage = "Pattern needs a quantity of at least 2."
            return
        }
        if state.isSketchPattern {
            commitSketchPattern(state)
        } else {
            commitBodyPattern(state)
        }
    }

    private func commitBodyPattern(_ state: PatternState) {
        guard let bodyID = state.bodyID,
              let body = session.document.body(with: bodyID)
        else {
            cancelPattern()
            return
        }
        var document = session.document // local: unique names + revisions
        var commands: [DocumentCommand] = []
        var ids: Set<BodyID> = [body.id]
        // Ordered copy ids (instance 1..<count) so the recorded feature node's
        // outputBodyIDs line up with `evalPattern`, which emits copies at
        // outputBodyIDs[i-1] for transform i. Same ids are used for both the
        // AddBodyCommand geometry and the recorded node, so replay reuses them.
        var copyIDs: [BodyID] = []
        for transform in patternTransforms(state).dropFirst() {
            var copy = Body(
                id: BodyID(),
                name: document.uniqueBodyName(base: body.name),
                transform: Self.composedPatternTransform(transform, base: body.transform),
                primitive: body.primitive,
                render: body.render,
                revision: document.nextRevision()
            )
            copy.euclid = body.euclid
            document.bodies.append(copy) // keeps the next name unique
            commands.append(AddBodyCommand(body: copy, title: "Pattern"))
            ids.insert(copy.id)
            copyIDs.append(copy.id)
        }
        guard !commands.isEmpty else { return }
        // Phase D: record a `.pattern` history node when the SOURCE body is
        // feature-owned, so the copies rebuild associatively (and the panel can
        // edit count/spacing/angle). Bundled into the SAME CompositeCommand so a
        // single undo drops every copy + the node. A pattern of an imported /
        // copied body can't be replayed, so it stays geometry-only.
        if let owner = featureNode(owning: bodyID) {
            let patternNode = FeatureNode(
                name: "Pattern",
                kind: .pattern(
                    body: BodyRef(producer: owner.id, bodyID: bodyID),
                    spec: Self.patternSpec(from: state)
                ),
                outputBodyIDs: copyIDs
            )
            commands.append(AppendFeatureCommand(node: patternNode))
        }
        session.perform(CompositeCommand(title: "Pattern", commands: commands))
        patternState = nil
        selection = ids
        mode = .idle
        session.save()
    }

    private func commitSketchPattern(_ state: PatternState) {
        guard let sketchID = state.sketchID,
              let sketch = session.document.sketches.first(where: { $0.id == sketchID })
        else {
            cancelPattern()
            return
        }
        let entities = sketch.entities.filter { state.entityIDs.contains($0.id) }
        guard !entities.isEmpty else {
            cancelPattern()
            return
        }
        var commands: [DocumentCommand] = []
        for transform in sketchPatternTransforms(state).dropFirst() {
            for entity in entities {
                for copy in PatternKit.transformed(entity, by: transform) {
                    commands.append(AddSketchEntityCommand(sketchID: sketchID, entity: copy))
                }
            }
        }
        guard !commands.isEmpty else { return }
        session.perform(CompositeCommand(title: "Pattern", commands: commands))
        patternState = nil
        mode = .idle
        session.save()
    }

    // MARK: - Profile fills (cached per sketch content)

    private var fillCache: [SketchID: (
        entities: [SketchEntity], construction: Set<UUID>, batches: [SketchFillBatch]
    )] = [:]

    private func fillBatches(for sketch: Sketch) -> [SketchFillBatch] {
        if let cached = fillCache[sketch.id], cached.entities == sketch.entities,
           cached.construction == sketch.constructionEntityIDs {
            return cached.batches
        }
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        var batches: [SketchFillBatch] = []
        let fillColor = SIMD4<Float>(0.36, 0.58, 0.92, 0.28)
        for profile in profiles {
            let holes = ProfileDetector.holes(of: profile, among: profiles)
            let triangles = SketchTessellator.fillTriangles(
                for: profile, holes: holes, on: sketch.plane
            )
            if !triangles.isEmpty {
                batches.append(SketchFillBatch(triangles: triangles, color: fillColor))
            }
        }
        fillCache[sketch.id] = (sketch.entities, sketch.constructionEntityIDs, batches)
        return batches
    }

    // MARK: - Toolbar actions

    func deleteSelection() {
        if case .sketching = mode {
            // A selected constraint/dimension glyph deletes first (undoable).
            if let cid = selectedConstraintID {
                deleteConstraint(cid)
                return
            }
            if let did = selectedDimensionID {
                deleteDimension(did)
                return
            }
            guard !selectedSketchEntityIDs.isEmpty, let sketch = activeSketch else { return }
            session.perform(RemoveSketchEntitiesCommand(ids: selectedSketchEntityIDs, sketch: sketch))
            selectedSketchEntityIDs.removeAll()
            // Phase D: deleting sketch entities changes referenced profiles —
            // rebuild dependent features.
            session.rebuildForSketchChange(sketch.id)
            return
        }
        if let image = selectedImage {
            deleteImage(image.id)
            return
        }
        guard !selection.isEmpty else { return }
        // Revert any transient preview first (the rotate preview mutates
        // transforms outside undo) so the delete captures clean state.
        cancelTransientPicks()
        session.perform(DeleteBodiesCommand(ids: selection, document: session.document))
        selection.removeAll()
        mode = .idle
    }

    func undo() {
        session.undo()
        sanitizeAfterHistoryChange()
    }

    func redo() {
        session.redo()
        sanitizeAfterHistoryChange()
    }

    private func sanitizeAfterHistoryChange() {
        // Face/tool contexts reference geometry that may have changed.
        cancelTool()
        axisEntryPart = nil
        scaleEntryActive = false
        // Pending sketch state may reference entities that no longer exist.
        pendingArc = nil
        adjustingArcBulge = false
        clearChain()
        sketchEntityDrag = nil
        sketchGizmoDrag = nil
        let liveEntityIDs = Set(session.document.sketches.flatMap { $0.entities.map(\.id) })
        selectedSketchEntityIDs = selectedSketchEntityIDs.intersection(liveEntityIDs)
        selectedSketchPoints = selectedSketchPoints.filter { liveEntityIDs.contains($0.entityID) }
        // A selected constraint/dimension may have been undone away.
        let liveConstraintIDs = Set(session.document.sketches.flatMap { $0.constraints.map(\.id) })
        let liveDimensionIDs = Set(session.document.sketches.flatMap { $0.dimensions.map(\.id) })
        if let cid = selectedConstraintID, !liveConstraintIDs.contains(cid) { selectedConstraintID = nil }
        if let did = selectedDimensionID, !liveDimensionIDs.contains(did) { selectedDimensionID = nil }
        // Selection/mode may reference bodies that no longer exist.
        let liveIDs = Set(session.document.bodies.map(\.id))
        selection = selection.intersection(liveIDs)
        // The selected image (and any pending drag baseline) may be undone away.
        imageInteractionBaseline = nil
        imageInteractionPerformed = false
        if let imageID = selectedImageID, session.document.imageIndex(of: imageID) == nil {
            selectedImageID = nil
        }
        // Isolation over undone-away bodies would blank the scene — drop the
        // dead ids, and the whole override once nothing is left isolated.
        if let isolated = isolatedBodyIDs {
            let alive = isolated.intersection(liveIDs)
            isolatedBodyIDs = alive.isEmpty ? nil : alive
        }
        switch mode {
        case .editingPrimitive(let id) where !liveIDs.contains(id),
             .selected(let id) where !liveIDs.contains(id),
             .pickingSplitCutter(let id) where !liveIDs.contains(id):
            mode = .idle
        case .sketching(let id, _)
            where !session.document.sketches.contains(where: { $0.id == id }):
            mode = .idle
        case .patterning:
            // The pattern source (body or sketch) may have been undone away.
            let valid: Bool
            if let bodyID = patternState?.bodyID {
                valid = liveIDs.contains(bodyID)
            } else if let sketchID = patternState?.sketchID {
                valid = session.document.sketches.contains { $0.id == sketchID }
            } else {
                valid = false
            }
            if !valid {
                patternState = nil
                mode = .idle
            }
        case .rotatingAroundAxis:
            // The rotate baseline may reference undone bodies; drop the tool
            // (cancel restores transforms for bodies that still exist).
            cancelRotateAxis()
        case .translating:
            cancelTranslate()
        case .aligning:
            cancelAlign()
        default:
            break
        }
    }

    // MARK: - Viewport events

    func handle(_ event: ViewportEvent) {
        switch event {
        case .tap(let ray):
            handleTap(ray: ray)
        case .doubleTap(let ray):
            handleDoubleTap(ray: ray)
        }
    }

    func fitView() {
        cameraControl?.fitScene()
    }

    // MARK: - Views popover (standard views + projection, spec §7.3)

    /// Orthographic projection toggle state (mirrored to the camera).
    var orthographicEnabled = false

    /// True while sketching with the camera >10° off head-on; maintained by
    /// the viewport as the camera moves (shows the Look at Sketch button).
    var lookAtSketchAvailable = false

    func applyStandardView(_ view: StandardView) {
        cameraControl?.animateToStandardView(view)
    }

    func setOrthographic(_ enabled: Bool) {
        orthographicEnabled = enabled
        cameraControl?.setProjection(orthographic: enabled)
    }

    /// Re-aim the camera head-on at the active sketch plane.
    func lookAtSketch() {
        guard let plane = activeSketch?.plane else { return }
        cameraControl?.moveCameraHeadOn(to: plane)
    }

    // MARK: - Display modes & Isolate (spec §16.2/§16.4, plan §B12)

    /// Viewport shading mode; mirrored into the scene every rebuild. Not
    /// persisted — a reopened design starts Shaded, like Shapr3D.
    var displayMode: DisplayMode = .shaded

    /// Extra low-alpha edge pass with a reversed depth test (spec §16.4).
    var showHiddenEdges = false

    /// Ground blob shadows (plan §B15); mirrored into the scene every
    /// rebuild. Not persisted, like the display mode.
    var groundShadowEnabled = false

    // MARK: - Materials (plan §B15)

    /// Material sheet presentation flag (Material palette action).
    var showMaterialSheet = false

    /// The material the sheet opens on: the first selected body's, or the
    /// document default.
    var materialForSelection: BodyMaterialSpec {
        for body in session.document.bodies where selection.contains(body.id) {
            return body.material ?? .default
        }
        return .default
    }

    /// Material sheet Apply: one undo step over the whole selection.
    func applyMaterial(_ spec: BodyMaterialSpec) {
        guard !selection.isEmpty else { return }
        session.perform(SetMaterialCommand(
            bodyIDs: selection, material: spec.clamped, document: session.document
        ))
    }

    /// Isolate (spec §16.2): while non-nil, only these bodies render; exit
    /// restores everything. A transient view-model override — persisted
    /// per-item visibility (SetItemVisibility) is untouched.
    private(set) var isolatedBodyIDs: Set<BodyID>?

    var isIsolateActive: Bool { isolatedBodyIDs != nil }

    /// Hide everything except the current selection.
    func enterIsolate() {
        guard !selection.isEmpty else { return }
        isolatedBodyIDs = selection
    }

    func exitIsolate() {
        isolatedBodyIDs = nil
    }

    // MARK: - Section View (spec §16.1, plan §B11)

    /// Section plane: the picked plane plus a pull offset along its normal.
    /// Not persisted; Section Off restores the full model.
    struct SectionState: Equatable {
        var basePlane: SketchPlane
        /// Pull-arrow travel along the (unflipped) base-plane normal.
        var offset: Double = 0
        /// Flip badge: keep the other side instead.
        var flipped = false
        /// On-screen plane rectangle size (sized to the scene at pick time).
        var size: Double = 8

        /// The base plane shifted by the current offset.
        var plane: SketchPlane {
            var plane = basePlane
            plane.origin += simd_normalize(basePlane.normal) * offset
            return plane
        }
    }

    private(set) var sectionState: SectionState?
    /// Axis param where the section-arrow drag grabbed (nil = screen-space
    /// fallback), and the offset when it began — the offset-plane pattern.
    private var sectionDragAnchor: Float?
    private var sectionDragStartOffset: Double = 0

    /// "Section" in the Views menu: show the plane tiles; the next tap on a
    /// tile or a planar face becomes the section plane.
    func beginSectionPlanePick() {
        cancelTool()
        cancelTransientPicks()
        selection.removeAll()
        mode = .pickingSectionPlane
    }

    func cancelSectionPlanePick() {
        if case .pickingSectionPlane = mode {
            mode = .idle
        }
    }

    /// Flip badge: switch which side of the plane stays visible.
    func flipSection() {
        sectionState?.flipped.toggle()
    }

    /// Section off: restore the full model.
    func endSection() {
        sectionState = nil
        sectionDragAnchor = nil
        cancelSectionPlanePick()
    }

    /// Tap routing while Section View waits for its plane: a world or
    /// construction plane tile, or a planar body face (spec §16.1).
    private func handleSectionPlanePick(ray: Ray) {
        let tiles = PlanePicking.worldTiles + constructionPlaneTiles
        let tileHit = PlanePicking.pick(ray: ray, tiles: tiles)
        let bodyHit = HitTester.pickBody(ray: ray, in: scene)

        let picked: SketchPlane?
        if let tileHit, bodyHit == nil || tileHit.distance <= bodyHit!.distance + 1e-3 {
            picked = tileHit.tile.plane
        } else if let bodyHit {
            picked = worldFacePlane(bodyID: bodyHit.bodyID, triangleIndex: bodyHit.triangleIndex)
        } else {
            picked = nil
        }
        // Taps that miss keep the picker armed (Cancel dismisses it).
        guard let plane = picked else { return }

        // Rectangle sized to cover the model from wherever the plane sits.
        var size = 8.0
        if let bounds = scene.worldBounds {
            size = max(size, Double(simd_length(bounds.max - bounds.min)) * 1.4)
        }
        sectionState = SectionState(basePlane: plane, size: size)
        mode = .idle
    }

    /// A drag starting near the section pull arrow moves the plane along its
    /// normal; anywhere else orbits. Claim test mirrors the extrude anchor
    /// math with a screen-space tolerance around the arrow's axis.
    func beginSectionDrag(ray: Ray) -> Bool {
        guard let section = sectionState, toolContext == nil else { return false }
        let plane = section.plane
        let n = simd_normalize(section.basePlane.normal)
        let axisOrigin = SIMD3<Float>(
            Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
        )
        let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        // Head-on views have no stable axis anchor and the arrow points at
        // the camera — let the drag orbit instead.
        guard abs(simd_dot(ray.direction, axisDirection)) < 0.95,
              let param = LineMath.closestParamOnLine(
                  origin: axisOrigin, direction: axisDirection, to: ray
              )
        else { return false }
        let closest = axisOrigin + axisDirection * param
        let along = max(simd_dot(closest - ray.origin, ray.direction), 0)
        let gap = simd_length(ray.origin + ray.direction * along - closest)
        // Forgiving grab: within ~36pt of the axis, ~220pt of the origin.
        guard gap <= Float(36 * worldPerPoint),
              abs(param) <= Float(220 * worldPerPoint)
        else { return false }
        sectionDragAnchor = param
        sectionDragStartOffset = section.offset
        return true
    }

    func updateSectionDrag(ray: Ray, screenDeltaWorld: Double) {
        guard var section = sectionState else { return }
        let n = simd_normalize(section.basePlane.normal)
        let originAtStart = section.basePlane.origin + n * sectionDragStartOffset
        let axisOrigin = SIMD3<Float>(
            Float(originAtStart.x), Float(originAtStart.y), Float(originAtStart.z)
        )
        let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        let raw: Double
        if let anchor = sectionDragAnchor,
           let param = LineMath.closestParamOnLine(
               origin: axisOrigin, direction: axisDirection, to: ray
           ) {
            raw = sectionDragStartOffset + Double(param - anchor)
        } else {
            raw = sectionDragStartOffset + screenDeltaWorld
        }
        // Snap to 0.5 steps, like the extrude pull.
        let snapped = (raw / 0.5).rounded() * 0.5
        section.offset = abs(raw - snapped) < 0.15 ? snapped : raw
        sectionState = section
    }

    func endSectionDrag() {
        sectionDragAnchor = nil
    }

    private func handleTap(ray: Ray) {
        // Any viewport tap dismisses pending gizmo numeric entry.
        axisEntryPart = nil
        if scaleEntryActive {
            // Spec §5.4: tapping an empty grid area commits the pending
            // scale; tapping a body just dismisses the field.
            if HitTester.pickBody(ray: ray, in: scene) == nil {
                commitScale(factor: scalePendingFactor)
                return
            }
            scaleEntryActive = false
            scaleCopyOnCommit = false
        }
        switch mode {
        case .idle, .editingPrimitive, .selected, .faceSelected:
            selectFaceOrBody(ray: ray)
        case .extruding:
            // Tapping another fill adds its profile to the tool; anywhere
            // else — "select an empty area of the grid to complete the tool."
            if addProfileToExtrude(ray: ray) { return }
            commitTool()
        case .pickingRevolveAxis:
            pickRevolveAxis(ray: ray)
        case .pickingSweepPath:
            pickSweepPathEntity(ray: ray)
        case .pickingLoftProfiles:
            pickLoftProfile(ray: ray)
        case .pickingBooleanTool(let kind, let targetID):
            handleBooleanToolTap(kind: kind, targetID: targetID, ray: ray)
        case .pickingSplitCutter(let target):
            handleSplitCutterTap(target: target, ray: ray)
        case .patterning:
            break // parameters live in the pattern bar; Apply/Cancel there
        case .rotatingAroundAxis:
            handleRotateAxisTap(ray: ray)
        case .translating:
            handleTranslateTap(ray: ray)
        case .aligning:
            handleAlignTap(ray: ray)
        case .pickingSketchPlane(let tool):
            handlePlanePick(ray: ray, tool: tool)
        case .sketching(_, let tool):
            handleSketchTap(ray: ray, tool: tool)
        case .measuring:
            handleMeasureTap(ray: ray)
        case .pickingSectionPlane:
            handleSectionPlanePick(ray: ray)
        case .pickingImagePlane:
            handleImagePlanePick(ray: ray)
        }
    }

    /// Shapr3D: double-tap selects the whole body; on empty space, fit view.
    /// While sketching, double-tap selects the tapped entity's whole
    /// connected chain (spec §1.10, endpoint adjacency).
    private func handleDoubleTap(ray: Ray) {
        if case .sketching = mode {
            guard let sketch = activeSketch,
                  let raw = rawSketchPoint(from: ray),
                  let hit = SketchHitTester.nearestEntity(
                      to: raw, in: sketch.entities, tolerance: entityPickTolerance
                  )
            else { return }
            selectedSketchEntityIDs = ProfileDetector.connectedEntityIDs(
                from: hit.entity.id, in: sketch.entities
            )
            return
        }
        if let hit = HitTester.pickBody(ray: ray, in: scene) {
            cancelTool()
            selection = [hit.bodyID]
            if let body = session.document.body(with: hit.bodyID), body.primitive != nil {
                mode = .editingPrimitive(hit.bodyID)
            } else {
                mode = .selected(hit.bodyID)
            }
        } else {
            cameraControl?.fitScene()
        }
    }

    /// Shapr3D: a single tap on a body selects the planar face under it.
    private func selectFaceOrBody(ray: Ray) {
        let bodyHit = HitTester.pickBody(ray: ray, in: scene)

        // Multi-select chip (plan §B13, spec §8.1): additive taps toggle
        // whole bodies in and out of the selection; an empty tap keeps the
        // selection (Shift-click convention) instead of clearing it.
        if selectionAdditive {
            if let hit = bodyHit {
                toggleSelection(of: hit.bodyID)
            }
            return
        }

        if bodyHit == nil, case .faceSelected = mode, let context = toolContext,
           let distance = context.distance, abs(distance) > 1e-4 {
            // Spec §4.1/§18: tapping empty grid commits a nonzero face pull
            // (same rule as profile extrudes); a zero pull cancels below.
            commitTool()
            return
        }

        // Fills win over coincident (or farther) body faces, so a profile
        // sketched ON a face stays tappable for extrude.
        if let fill = profileHit(ray: ray),
           bodyHit == nil || fill.distance <= bodyHit!.distance * 1.001 + 1e-2 {
            selectedImageID = nil
            startExtrude(with: fill)
            return
        }

        // Inserted images (plan §B10): nearer than any body hit → select the
        // image (gizmo + image bar). Fills stay on top so tracing sketches
        // drawn OVER an image remain extrudable.
        if let imageHit = imageHit(ray: ray),
           bodyHit == nil || imageHit.distance < bodyHit!.distance {
            cancelTool()
            selection.removeAll()
            mode = .idle
            selectedImageID = imageHit.id
            return
        }
        selectedImageID = nil

        if let hit = bodyHit {
            cancelTool()
            selection = [hit.bodyID]
            guard let body = session.document.body(with: hit.bodyID) else {
                mode = .selected(hit.bodyID)
                return
            }

            // Curved side surface? A plain cylinder's wall push/pulls radially
            // (edits the diameter); other curved surfaces just select the body,
            // so a single tessellation facet can never be extruded into a tab.
            if let cyl = FaceTopology.cylindricalFace(in: body.render, seedTriangle: hit.triangleIndex) {
                if cyl.matchesWholeBody {
                    beginCylinderRadial(body: body, cylinder: cyl, hit: hit)
                } else {
                    mode = .selected(hit.bodyID) // curved but compound → whole body
                }
                return
            }

            let face = FaceTopology.planarFace(in: body.render, seedTriangle: hit.triangleIndex)
            guard let face else {
                // Curved or unrecognized region → whole body.
                mode = .selected(hit.bodyID)
                return
            }

            // Face basis → world space (uniform scale + rotation + translation).
            let transform = body.transform
            let originWorld = transform.applying(to: face.origin)
            let xWorld = transform.rotation.act(face.basisX)
            let yWorld = transform.rotation.act(face.basisY)
            let plane = SketchPlane(origin: originWorld, xAxis: xWorld, yAxis: yWorld)
            let scale = transform.scale
            let profile = Profile(
                loop: face.outline.map { $0 * scale },
                kind: .polygonal,
                sourceEntityIDs: []
            )
            let holes = face.holes.map {
                Profile(loop: $0.map { $0 * scale }, kind: .polygonal, sourceEntityIDs: [])
            }
            toolContext = ToolContext(
                profile: profile,
                holes: holes,
                plane: plane,
                sketchID: nil,
                sourceBody: body.id,
                faceTriangles: face.triangles,
                kind: .extrude(distance: 0)
            )
            mode = .faceSelected(body.id)
            return
        }

        // Tapping a construction plane starts (or continues) a sketch on it.
        if let hit = PlanePicking.pick(ray: ray, tiles: constructionPlaneTiles) {
            cancelTool()
            selection.removeAll()
            beginSketch(on: hit.tile.plane, tool: .line)
            return
        }

        cancelTool()
        selection.removeAll()
        mode = .idle
    }

    // MARK: - Multi-select & area select (plan §B13, spec §8.1–8.2)

    /// Additive tap/Shift-click: toggle a body's membership in the
    /// selection; the mode follows the resulting selection.
    func toggleSelection(of id: BodyID) {
        cancelTool()
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        updateModeForSelection(anchor: id)
    }

    /// Point `mode` at the current `selection` after a multi-select change:
    /// none → idle, a single primitive → its dimension editor, anything
    /// else → selected (the gizmo shows at the shared centroid).
    private func updateModeForSelection(anchor: BodyID? = nil) {
        guard !selection.isEmpty else {
            mode = .idle
            return
        }
        let id = anchor.flatMap { selection.contains($0) ? $0 : nil } ?? selection.first!
        if selection.count == 1, session.document.body(with: id)?.primitive != nil {
            mode = .editingPrimitive(id)
        } else {
            mode = .selected(id)
        }
    }

    /// Route a finished marquee drag through AreaSelect and apply the
    /// result: bodies land in `selection`, sketch entities in
    /// `selectedSketchEntityIDs`. Screen coordinates and the world→screen
    /// projection come from the viewport; drag direction picks window
    /// (left→right) vs crossing (right→left) semantics.
    func performAreaSelect(
        dragStart: SIMD2<Double>,
        dragEnd: SIMD2<Double>,
        filter: AreaSelect.Filter = .bodiesAndSketchEntities,
        project: (SIMD3<Float>) -> SIMD2<Double>?
    ) {
        // Only from the passive modes — active tools keep their taps/drags.
        switch mode {
        case .idle, .selected, .editingPrimitive, .faceSelected:
            break
        default:
            return
        }
        var candidates: [AreaSelectCandidate] = []
        for body in session.document.bodies {
            let matrix = body.transform.matrixFloat
            let points = body.render.positions.map { position -> SIMD3<Float> in
                let world = matrix * SIMD4(position, 1)
                return SIMD3(world.x, world.y, world.z)
            }
            candidates.append(AreaSelectCandidate(
                item: .body(body.id), points: points, isHidden: body.isHidden
            ))
        }
        if filter == .bodiesAndSketchEntities {
            for sketch in session.document.sketches {
                for entity in sketch.entities {
                    candidates.append(AreaSelectCandidate(
                        item: .sketchEntity(entity.id),
                        points: SketchTessellator.segments(for: [entity], on: sketch.plane),
                        isHidden: sketch.isHidden
                    ))
                }
            }
        }
        let items = AreaSelect.select(
            candidates: candidates,
            dragStart: dragStart,
            dragEnd: dragEnd,
            filter: filter,
            project: project
        )
        var bodies: Set<BodyID> = []
        var entities: Set<UUID> = []
        for item in items {
            switch item {
            case .body(let id):
                bodies.insert(id)
            case .sketchEntity(let id):
                entities.insert(id)
            }
        }
        cancelTool()
        if selectionAdditive {
            selection.formUnion(bodies)
            selectedSketchEntityIDs.formUnion(entities)
        } else {
            selection = bodies
            selectedSketchEntityIDs = entities
        }
        updateModeForSelection()
    }

    // MARK: - Select mode (plan §B13 UI, spec §8.2)

    /// Palette "Select" toggle: while on, one-finger viewport drags draw a
    /// marquee (window/crossing by drag direction) instead of orbiting, and
    /// taps toggle bodies additively (`selectionAdditive`).
    private(set) var selectModeActive = false

    /// Marquee filter chips (spec §8.2's B/F/E keys reduced to
    /// Bodies | Sketches for v1). At least one kind always stays on.
    private(set) var areaSelectIncludesBodies = true
    private(set) var areaSelectIncludesSketches = true

    var areaSelectFilter: AreaSelect.Filter {
        switch (areaSelectIncludesBodies, areaSelectIncludesSketches) {
        case (true, false): return .bodiesOnly
        case (false, true): return .sketchEntitiesOnly
        default: return .bodiesAndSketchEntities
        }
    }

    func toggleAreaSelectBodies() {
        guard !areaSelectIncludesBodies || areaSelectIncludesSketches else { return }
        areaSelectIncludesBodies.toggle()
    }

    func toggleAreaSelectSketches() {
        guard !areaSelectIncludesSketches || areaSelectIncludesBodies else { return }
        areaSelectIncludesSketches.toggle()
    }

    func toggleSelectMode() {
        if selectModeActive {
            exitSelectMode()
            return
        }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        selectModeActive = true
        selectionAdditive = true
    }

    func exitSelectMode() {
        selectModeActive = false
        selectionAdditive = false
        marqueeState = nil
    }

    /// Live marquee rectangle for the SwiftUI overlay; screen points in
    /// viewport coordinates. Drag direction picks the semantics and the
    /// standard visual cue: left→right window (solid border), right→left
    /// crossing (dashed).
    struct MarqueeState {
        var start: SIMD2<Double>
        var current: SIMD2<Double>
        var isWindow: Bool { current.x >= start.x }
    }

    private(set) var marqueeState: MarqueeState?

    /// Claim a one-finger drag as a marquee (select mode, passive modes
    /// only). Returning false lets the drag orbit the camera instead.
    func beginMarquee(at point: SIMD2<Double>) -> Bool {
        guard selectModeActive else { return false }
        switch mode {
        case .idle, .selected, .editingPrimitive, .faceSelected:
            break
        default:
            return false
        }
        marqueeState = MarqueeState(start: point, current: point)
        return true
    }

    func updateMarquee(to point: SIMD2<Double>) {
        marqueeState?.current = point
    }

    /// Finish the marquee: run AreaSelect over the current drawables with
    /// the chip filter. `project` is the renderer camera's world→screen map.
    func endMarquee(project: (SIMD3<Float>) -> SIMD2<Double>?) {
        guard let marquee = marqueeState else { return }
        marqueeState = nil
        performAreaSelect(
            dragStart: marquee.start,
            dragEnd: marquee.current,
            filter: areaSelectFilter,
            project: project
        )
    }

    // MARK: - Select Through (plan §B13, spec §8.3)

    struct SelectThroughCandidate: Identifiable {
        let id: BodyID
        let name: String
    }

    /// Long-press hit list (front→back); non-nil presents the popup menu.
    var selectThroughCandidates: [SelectThroughCandidate]?

    /// Long-press: list every body under the screen point through depth
    /// (`pickAllBodies`) so occluded bodies stay selectable. No-op while an
    /// active tool owns viewport input.
    func presentSelectThrough(ray: Ray) {
        switch mode {
        case .idle, .selected, .editingPrimitive, .faceSelected:
            break
        default:
            return
        }
        let candidates = HitTester.pickAllBodies(ray: ray, in: scene).compactMap { hit in
            session.document.body(with: hit.bodyID).map {
                SelectThroughCandidate(id: $0.id, name: $0.name)
            }
        }
        guard !candidates.isEmpty else { return }
        selectThroughCandidates = candidates
    }

    /// Popup choice: select that body (additively while in select mode).
    func chooseSelectThrough(_ id: BodyID) {
        selectThroughCandidates = nil
        guard session.document.body(with: id) != nil else { return }
        cancelTool()
        if selectionAdditive {
            selection.insert(id)
        } else {
            selection = [id]
        }
        updateModeForSelection(anchor: id)
    }

    // MARK: - Primitive dimension editing

    /// The primitive being edited, if the mode says so.
    var editingPrimitiveBody: Body? {
        guard case .editingPrimitive(let id) = mode else { return nil }
        return session.document.body(with: id)
    }

    func commitPrimitiveSpec(_ newSpec: PrimitiveSpec) {
        guard case .editingPrimitive(let id) = mode,
              let body = session.document.body(with: id),
              let currentSpec = body.primitive,
              currentSpec != newSpec
        else { return }
        let resize = ResizePrimitiveCommand(bodyID: id, beforeSpec: currentSpec, afterSpec: newSpec)

        // Phase D (Task C2): keep the owning primitive feature node in sync, or
        // create one so the box/cylinder/sphere becomes an editable history step.
        // `placement` is identity — the body's own transform carries its world
        // placement across rebuilds (rebuildFrom preserves it), so the replayed
        // (identity-transform, origin-local) primitive lands in the same spot.
        if let node = featureNode(owning: id), case .primitive = node.kind {
            let after = FeatureKind.primitive(spec: newSpec, placement: .identity)
            let edit = EditFeatureCommand(featureID: node.id, before: node.kind, after: after)
            session.perform(CompositeCommand(title: resize.title, commands: [resize, edit]))
        } else {
            let node = FeatureNode(
                name: newSpec.displayName,
                kind: .primitive(spec: newSpec, placement: .identity),
                outputBodyIDs: [id]
            )
            session.perform(CompositeCommand(
                title: resize.title, commands: [resize, AppendFeatureCommand(node: node)]))
        }
    }

    func finishEditing() {
        mode = .idle
        selection.removeAll()
    }

    // MARK: - Booleans

    /// True while a CSG operation runs off the main actor.
    var isComputingBoolean = false
    private nonisolated final class CancelToken: @unchecked Sendable {
        var isCancelled = false
    }
    private var booleanCancelToken: CancelToken?

    func armBoolean(_ kind: BooleanKind) {
        guard selection.count == 1, let target = selection.first else { return }
        cancelTransientPicks()
        cancelTool()
        mode = .pickingBooleanTool(kind, target: target)
    }

    func cancelBooleanPicking() {
        if case .pickingBooleanTool = mode {
            mode = .idle
        }
    }

    func handleBooleanToolTap(kind: BooleanKind, targetID: BodyID, ray: Ray) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene),
              hit.bodyID != targetID
        else { return }
        runBoolean(kind, targetID: targetID, toolID: hit.bodyID)
    }

    private func runBoolean(_ kind: BooleanKind, targetID: BodyID, toolID: BodyID) {
        guard let target = session.document.body(with: targetID),
              let toolIndex = session.document.bodyIndex(of: toolID)
        else { return }
        let tool = session.document.bodies[toolIndex]

        isComputingBoolean = true
        mode = .idle
        let token = CancelToken()
        booleanCancelToken = token

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Body? in
                let mesh = KernelOps.boolean(kind, target: target, tool: tool) {
                    token.isCancelled
                }
                guard !token.isCancelled, !mesh.polygons.isEmpty else { return nil }
                return Body(
                    id: target.id,
                    name: target.name,
                    transform: .identity,
                    primitive: nil,
                    euclidMesh: mesh,
                    revision: 0 // set by the command against the live document
                )
            }.value

            guard let self else { return }
            self.isComputingBoolean = false
            self.booleanCancelToken = nil
            guard let result, !token.isCancelled else {
                if !token.isCancelled {
                    self.errorMessage =
                        "The \(kind.rawValue) operation produced no geometry — the bodies may not overlap."
                }
                return
            }
            let boolean = BooleanCommand(
                kind: kind,
                targetBefore: target,
                toolIndex: toolIndex,
                toolBefore: tool,
                result: result
            )
            // Phase D (Task C2): record a `.boolean` feature node when BOTH the
            // target and tool are feature-produced, so replay can reconstruct
            // them before re-applying the CSG. If either is a non-feature body
            // (import/copy), skip — the node couldn't be faithfully replayed.
            if let node = self.booleanFeatureNode(kind: kind, target: target, tool: tool) {
                self.session.perform(CompositeCommand(
                    title: kind.rawValue.capitalized,
                    commands: [boolean, AppendFeatureCommand(node: node)]))
            } else {
                self.session.perform(boolean)
            }
            self.selection = [target.id]
            self.mode = .selected(target.id)
            self.session.save()
        }
    }

    func cancelBooleanComputation() {
        booleanCancelToken?.isCancelled = true
    }

    // MARK: - Profile tools (Extrude / Revolve)

    struct ToolContext {
        enum Kind {
            case extrude(distance: Double)
            /// Axis is a line in sketch-plane coordinates; angle in degrees.
            case revolve(axis: RevolveAxis, angle: Double)
            /// Offset construction plane pulled off a face along its normal.
            case offsetPlane(distance: Double)
            /// Sweep the profile along a world-space polyline spine (plan §B1).
            case sweep(spine: [SIMD3<Double>])
            /// Loft through `loftProfiles` in selection order (plan §B2).
            case loft
        }

        var profile: Profile
        var holes: [Profile]
        var plane: SketchPlane
        /// Sketch that produced the profile (nil for face extrudes).
        var sketchID: SketchID?
        /// The body whose face is being pushed/pulled (nil for sketch profiles).
        var sourceBody: BodyID?
        /// Face triangles for the selection highlight (face extrudes).
        var faceTriangles: [Int] = []
        /// Set when pushing/pulling a body's cylindrical side: distance is a
        /// RADIAL delta (grows/shrinks the radius), not an axial extrusion.
        var cylinderFace: FaceTopology.CylindricalFace?
        var kind: Kind
        /// Extra fills added while extruding (multi-profile: union of prisms).
        var extraProfiles: [(profile: Profile, holes: [Profile])] = []
        /// Entities already chained into the sweep path (tap order).
        var sweepPathEntityIDs: [UUID] = []
        /// Ordered loft sections (seeded with the armed profile; taps append).
        var loftProfiles: [(profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID)] = []
        /// Boolean badge: manual result override (auto = sample-point rules).
        var booleanOverride: BooleanOverride = .auto
        /// Symmetric sides: solid centered on the plane, total depth 2×.
        var symmetric = false
        /// False when committing now would fail (arrow renders red).
        var isPendingValid = true
        /// True while the preview should REPLACE the source body in the scene
        /// (face push/pull: the preview is the whole modified body, not an
        /// overlapping tool prism).
        var previewReplacesSource = false
        var previewRevision: UInt64 = 1
        var preview: Body?

        /// A push/pull of an existing body's planar face (vs. a fresh sketch
        /// extrude). These need a coincident-wall-safe truncation, not a
        /// same-cross-section boolean.
        var isFaceOperation: Bool { sourceBody != nil && !faceTriangles.isEmpty }
        var isCylinderRadial: Bool { cylinderFace != nil }

        var distance: Double? {
            switch kind {
            case .extrude(let distance), .offsetPlane(let distance):
                return distance
            case .revolve, .sweep, .loft:
                return nil
            }
        }

        var angle: Double? {
            if case .revolve(_, let angle) = kind { return angle }
            return nil
        }
    }

    var toolContext: ToolContext?
    private var extrudeDragAnchor: Float?
    /// Distance (extrude) or angle (revolve) when the drag began.
    private var toolDragStartValue: Double = 0
    /// Stable identity for the preview drawable so GPU buffers cache by revision.
    private let toolPreviewID = BodyID()

    /// The profile (with holes) under the ray, across all sketches, with the
    /// world-space hit distance (rays are unit-direction).
    private func profileHit(
        ray: Ray
    ) -> (profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID, distance: Float)? {
        var best: (profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID, distance: Float)?
        for sketch in session.document.sketches where !sketch.isHidden {
            let plane = sketch.plane
            let planePoint = SIMD3<Float>(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z))
            let n = plane.normal
            let planeNormal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
            guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else {
                continue
            }
            let world = ray.point(at: t)
            let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
            let candidates = ProfileDetector.profiles(at: local, in: sketch)
            guard let innermost = candidates.first else { continue }
            if best == nil || t < best!.distance {
                let all = ProfileDetector.detectProfiles(in: sketch)
                let holes = ProfileDetector.holes(of: innermost, among: all)
                best = (innermost, holes, plane, sketch.id, t)
            }
        }
        return best
    }

    /// Tap on a filled profile "jumps right into the Extrude command"
    /// (Shapr3D): opens the numeric extrude with a default pull.
    private func startExtrude(
        with hit: (profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID, distance: Float)
    ) {
        selection.removeAll()
        var context = ToolContext(
            profile: hit.profile,
            holes: hit.holes,
            plane: hit.plane,
            sketchID: hit.sketchID,
            kind: .extrude(distance: 2)
        )
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding
    }

    /// Drag starting on a filled profile pulls it into 3D directly
    /// (push/pull). Committing happens on release.
    func beginFillPull(ray: Ray) -> Bool {
        if case .measuring = mode { return false } // measure taps/drags never extrude
        // Split/pattern/transform picks never start an extrude; unclaimed
        // drags orbit (rotate-axis angle drags are claimed upstream).
        if case .pickingSplitCutter = mode { return false }
        if case .patterning = mode { return false }
        if case .rotatingAroundAxis = mode { return false }
        if case .translating = mode { return false }
        if case .aligning = mode { return false }
        if case .pickingSectionPlane = mode { return false }
        if case .pickingImagePlane = mode { return false }
        guard HitTester.pickBody(ray: ray, in: scene) == nil,
              let hit = profileHit(ray: ray)
        else { return false }

        selection.removeAll()
        var context = ToolContext(
            profile: hit.profile,
            holes: hit.holes,
            plane: hit.plane,
            sketchID: hit.sketchID,
            kind: .extrude(distance: 0)
        )
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding

        // Anchor the drag on the pull axis (profile centroid, plane normal).
        // Near head-on views (looking straight down the axis) have no stable
        // axis anchor — the screen-space fallback in updateToolDrag covers
        // that, so a nil anchor is fine.
        let centroid = hit.profile.centroid
        let world = hit.plane.toWorld(centroid)
        let n = hit.plane.normal
        let axisOrigin = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
        let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        if abs(simd_dot(ray.direction, axisDirection)) < 0.95 {
            extrudeDragAnchor = LineMath.closestParamOnLine(
                origin: axisOrigin, direction: axisDirection, to: ray
            )
        } else {
            extrudeDragAnchor = nil
        }
        toolDragStartValue = 0
        return true
    }

    /// Drag starting on the selected face pulls it (push/pull on bodies).
    func beginFacePull(ray: Ray) -> Bool {
        guard case .faceSelected(let bodyID) = mode,
              let context = toolContext,
              let hit = HitTester.pickBody(ray: ray, in: scene),
              hit.bodyID == bodyID,
              context.faceTriangles.contains(hit.triangleIndex)
        else { return false }
        return beginToolDrag(ray: ray)
    }

    private func rebuildToolPreview(_ context: inout ToolContext) {
        if case .offsetPlane = context.kind {
            // The pending plane renders as a quad, not a preview body.
            context.preview = nil
            context.isPendingValid = true
            return
        }
        let mesh: Euclid.Mesh
        switch context.kind {
        case .offsetPlane:
            return // handled above
        case .extrude(let distance):
            // Face push/pull: preview the whole modified body so the viewport
            // matches the committed result (no overlapping-prism z-fighting).
            if context.isFaceOperation {
                context.previewReplacesSource = true
                if abs(distance) <= 1e-4 {
                    context.preview = nil
                    context.isPendingValid = true
                    return
                }
                let modified = faceModifiedMesh(context, distance: distance)
                context.isPendingValid = !(modified?.polygons.isEmpty ?? true)
                guard let modified, !modified.polygons.isEmpty else {
                    context.preview = nil
                    return
                }
                context.previewRevision += 1
                context.preview = Body(
                    id: toolPreviewID,
                    name: "Tool Preview",
                    transform: .identity,
                    primitive: nil,
                    euclidMesh: modified,
                    revision: context.previewRevision
                )
                return
            }
            var solid = KernelOps.extrude(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                distance: distance,
                symmetric: context.symmetric
            )
            for extra in context.extraProfiles {
                solid = solid.union(KernelOps.extrude(
                    profile: extra.profile,
                    holes: extra.holes,
                    in: context.plane,
                    distance: distance,
                    symmetric: context.symmetric
                ))
            }
            mesh = solid
        case .revolve(let axis, let angle):
            mesh = KernelOps.revolve(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                axis: axis,
                angle: angle
            )
        case .sweep(let spine):
            mesh = KernelOps.sweep(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                alongPath: spine
            )
        case .loft:
            mesh = KernelOps.loft(
                profiles: context.loftProfiles.map { ($0.profile, $0.holes, $0.plane) }
            )
        }
        updatePendingValidity(&context, toolMesh: mesh)
        guard !mesh.polygons.isEmpty else {
            context.preview = nil
            return
        }
        context.previewRevision += 1
        context.preview = Body(
            id: toolPreviewID,
            name: "Tool Preview",
            transform: .identity,
            primitive: nil,
            euclidMesh: mesh,
            revision: context.previewRevision
        )
    }

    /// Operation-validity feedback (spec §18), throttled to preview rebuilds.
    /// Cheap: bounds prefilters; real CSG runs only when a wipeout cut or an
    /// empty intersection is plausible.
    private func updatePendingValidity(_ context: inout ToolContext, toolMesh: Euclid.Mesh) {
        context.isPendingValid = true
        guard case .extrude(let distance) = context.kind,
              abs(distance) > 1e-4,
              context.booleanOverride != .newBody,
              !toolMesh.polygons.isEmpty
        else { return }

        let toolBounds = toolMesh.bounds
        let n = context.plane.normal
        let sign: Double = distance >= 0 ? 1 : -1
        let sampleWorld = context.plane.toWorld(context.profile.centroid) + n * sign * 0.01
        let sample = Vector(sampleWorld.x, sampleWorld.y, sampleWorld.z)

        var intersectHasOverlap = false
        for target in booleanCandidates(for: context) {
            let bounds = Self.worldBounds(of: target)
            guard toolBounds.intersects(bounds) else { continue }
            switch context.booleanOverride {
            case .intersect:
                if !intersectHasOverlap {
                    let worldTarget = target.euclidMesh().transformed(by: target.transform.euclid)
                    intersectHasOverlap = !worldTarget.intersection(toolMesh).polygons.isEmpty
                }
            case .subtract, .auto:
                // Cut wipeout only possible when the tool encloses the body.
                let mayCut = context.booleanOverride == .subtract || bounds.intersects(sample)
                if mayCut, toolBounds.contains(bounds) {
                    let worldTarget = target.euclidMesh().transformed(by: target.transform.euclid)
                    if worldTarget.subtracting(toolMesh).polygons.isEmpty {
                        context.isPendingValid = false
                        return
                    }
                }
            case .union, .newBody:
                break
            }
        }
        if context.booleanOverride == .intersect {
            context.isPendingValid = intersectHasOverlap
        }
    }

    /// Bodies a tool commit could combine with: the pull's source body, or
    /// every body for sketch-profile tools.
    private func booleanCandidates(for context: ToolContext) -> [Body] {
        if let source = context.sourceBody {
            return session.document.body(with: source).map { [$0] } ?? []
        }
        return session.document.bodies
    }

    /// World-space AABB from the render mesh's local AABB (cheap — no Euclid
    /// mesh rebuild).
    private static func worldBounds(of body: Body) -> Euclid.Bounds {
        let aabb = body.render.localAABB
        var lo = SIMD3<Double>(.infinity, .infinity, .infinity)
        var hi = -lo
        for i in 0..<8 {
            let corner = SIMD3<Double>(
                Double((i & 1) == 0 ? aabb.min.x : aabb.max.x),
                Double((i & 2) == 0 ? aabb.min.y : aabb.max.y),
                Double((i & 4) == 0 ? aabb.min.z : aabb.max.z)
            )
            let world = body.transform.applying(to: corner)
            lo = simd_min(lo, world)
            hi = simd_max(hi, world)
        }
        return Euclid.Bounds(
            min: Vector(lo.x, lo.y, lo.z),
            max: Vector(hi.x, hi.y, hi.z)
        )
    }

    /// While extruding a sketch profile, tapping another fill in the same
    /// sketch adds it to the tool (multi-profile extrude).
    private func addProfileToExtrude(ray: Ray) -> Bool {
        guard var context = toolContext, case .extrude = context.kind,
              let sketchID = context.sketchID,
              let hit = profileHit(ray: ray),
              hit.sketchID == sketchID,
              !hit.profile.sourceEntityIDs.isEmpty
        else { return false }
        // Tapping an already-included fill falls through to commit.
        let ids = hit.profile.sourceEntityIDs
        guard context.profile.sourceEntityIDs != ids,
              !context.extraProfiles.contains(where: { $0.profile.sourceEntityIDs == ids })
        else { return false }
        context.extraProfiles.append((hit.profile, hit.holes))
        rebuildToolPreview(&context)
        toolContext = context
        return true
    }

    func setExtrudeDistance(_ distance: Double) {
        guard var context = toolContext, case .extrude = context.kind else { return }
        context.kind = .extrude(distance: distance)
        rebuildToolPreview(&context)
        toolContext = context
    }

    // MARK: - Extrude arrow value pill (Shapr3D on-arrow dimension)

    struct ExtrudeArrowLabel {
        var world: SIMD3<Double>   // arrow-tip world position
        var text: String           // "12.0 mm" or "⌀ 24.0 mm"
        var isDiameter: Bool
        var symmetric: Bool
    }

    /// True while the on-arrow value pill is being typed into.
    var editingExtrudeArrow = false

    /// The editable value pill riding the extrude/diameter arrow, or nil.
    var extrudeArrowLabel: ExtrudeArrowLabel? {
        guard let context = toolContext, case .extrude(let distance) = context.kind else { return nil }
        let centroid = context.plane.toWorld(context.profile.centroid)
        // Anchor the pill at the arrow's midpoint (Shapr3D centres it on the
        // line), nudged just off-axis so it doesn't overlap the shaft.
        let mid = centroid + context.plane.normal * (distance * 0.5)
        if let cyl = context.cylinderFace {
            let dia = 2 * (cyl.radius + distance / max(sourceScale(context), 1e-6))
            return ExtrudeArrowLabel(
                world: mid, text: String(format: "⌀ %.1f mm", dia),
                isDiameter: true, symmetric: false
            )
        }
        let shown = context.symmetric ? abs(distance) * 2 : abs(distance)
        return ExtrudeArrowLabel(
            world: mid, text: String(format: "%.1f mm", shown),
            isDiameter: false, symmetric: context.symmetric
        )
    }

    private func sourceScale(_ context: ToolContext) -> Double {
        context.sourceBody.flatMap { session.document.body(with: $0) }?.transform.scale ?? 1
    }

    func beginExtrudeArrowEdit() { editingExtrudeArrow = true }

    /// Commit a typed value from the on-arrow pill: set the distance/diameter
    /// (Enter commits the feature, matching the bottom bar).
    func commitExtrudeArrowEdit(_ text: String) {
        defer { editingExtrudeArrow = false }
        guard let value = ExpressionEvaluator.evaluate(text),
              let context = toolContext, case .extrude = context.kind
        else { return }
        if let cyl = context.cylinderFace {
            setExtrudeDistance(value / 2 - cyl.radius)
        } else {
            let signed = (context.distance ?? 0) < 0 ? -abs(value) : abs(value)
            setExtrudeDistance(context.symmetric ? signed / 2 : signed)
        }
        commitTool()
    }

    func cancelExtrudeArrowEdit() { editingExtrudeArrow = false }

    func setExtrudeSymmetric(_ symmetric: Bool) {
        guard var context = toolContext, case .extrude = context.kind,
              context.symmetric != symmetric
        else { return }
        context.symmetric = symmetric
        rebuildToolPreview(&context)
        toolContext = context
    }

    func setBooleanOverride(_ result: BooleanOverride) {
        guard var context = toolContext, context.booleanOverride != result else { return }
        context.booleanOverride = result
        // Validity depends on the pending result kind.
        rebuildToolPreview(&context)
        toolContext = context
    }

    func setRevolveAngle(_ angle: Double) {
        guard var context = toolContext, case .revolve(let axis, _) = context.kind else { return }
        context.kind = .revolve(axis: axis, angle: min(max(angle, 1), 360))
        rebuildToolPreview(&context)
        toolContext = context
    }

    /// Commits whichever profile tool is active (extrude or revolve).
    func commitTool() {
        guard let context = toolContext else {
            cancelTool()
            return
        }
        switch context.kind {
        case .extrude(let distance):
            commitExtrude(context, distance: distance)
        case .revolve(_, let angle):
            commitRevolve(context, angle: angle)
        case .offsetPlane(let distance):
            commitOffsetPlane(context, distance: distance)
        case .sweep(let spine):
            commitSweep(context, spine: spine)
        case .loft:
            commitLoft(context)
        }
    }

    // MARK: - Offset construction plane (spec §6.1, Offset)

    /// "Offset Plane" on a selected face: switch the pull to dragging a copy
    /// of the face plane along its normal.
    func beginOffsetPlane() {
        guard case .faceSelected = mode, var context = toolContext else { return }
        context.kind = .offsetPlane(distance: 2)
        context.preview = nil
        toolContext = context
    }

    func setOffsetPlaneDistance(_ distance: Double) {
        guard var context = toolContext, case .offsetPlane = context.kind else { return }
        context.kind = .offsetPlane(distance: distance)
        toolContext = context
    }

    /// The dragged plane: the face plane shifted along its normal, sized to
    /// cover the face outline with a margin.
    private func offsetPlanePreview(
        _ context: ToolContext, distance: Double
    ) -> (plane: SketchPlane, size: Double) {
        let n = simd_normalize(context.plane.normal)
        let centroid = context.profile.centroid
        let origin = context.plane.toWorld(centroid) + n * distance
        var radius = 1.0
        for p in context.profile.loop {
            radius = max(radius, simd_length(p - centroid))
        }
        return (
            SketchPlane(origin: origin, xAxis: context.plane.xAxis, yAxis: context.plane.yAxis),
            radius * 2.5
        )
    }

    private func commitOffsetPlane(_ context: ToolContext, distance: Double) {
        guard abs(distance) > 1e-4 else {
            cancelTool()
            return
        }
        let pending = offsetPlanePreview(context, distance: distance)
        session.perform(AddConstructionPlaneCommand(
            plane: ConstructionPlane(plane: pending.plane, size: pending.size)
        ))
        toolContext = nil
        selection.removeAll()
        mode = .idle
        session.save()
    }

    private func commitExtrude(_ context: ToolContext, distance: Double) {
        guard abs(distance) > 1e-4, let preview = context.preview else {
            cancelTool()
            return
        }

        // Face push/pull modifies its own body directly (coincident-wall-safe
        // truncation/extension), not via a same-cross-section boolean.
        if context.isFaceOperation, context.booleanOverride == .auto {
            commitFaceOperation(context, distance: distance)
            return
        }

        // Automatic boolean (Shapr3D Extrude): pulled away from a body →
        // union; pushed into a body → subtract; touching nothing → new body.
        let n = context.plane.normal
        let sign: Double = distance >= 0 ? 1 : -1
        let sampleWorld = context.plane.toWorld(context.profile.centroid) + n * sign * 0.01
        let sample = Vector(sampleWorld.x, sampleWorld.y, sampleWorld.z)

        commitToolResult(
            preview: preview,
            mergeTool: overlapExtrudeTool(context, distance: distance),
            sample: sample,
            title: "Extrude",
            context: context
        )
    }

    /// The source body's world mesh after a face push/pull. Robust against
    /// coincident walls (the failure mode of a same-cross-section boolean):
    /// - inward push (distance < 0) truncates via a half-space cut whose lateral
    ///   walls sit far outside the body, so only the new face plane cuts;
    /// - outward pull (distance > 0) unions a flush prism (union tolerates the
    ///   coincident side walls, merging them into one continuous wall).
    /// Returns nil when the source body is gone or the result is empty.
    /// Enter radial push/pull on a plain cylinder: the pull arrow points
    /// radially outward at the tap point, and dragging edits the radius.
    private func beginCylinderRadial(
        body: Body, cylinder cyl: FaceTopology.CylindricalFace, hit: PickHit
    ) {
        let transform = body.transform
        let worldAxisDir = simd_normalize(transform.rotation.act(cyl.axisDir))
        let worldAxisPoint = transform.applying(to: cyl.axisPoint)
        let hitWorld = SIMD3<Double>(Double(hit.worldPoint.x), Double(hit.worldPoint.y), Double(hit.worldPoint.z))
        let along = simd_dot(hitWorld - worldAxisPoint, worldAxisDir)
        let onAxis = worldAxisPoint + worldAxisDir * along
        var radialWorld = hitWorld - onAxis
        radialWorld = simd_length(radialWorld) < 1e-9 ? SIMD3(1, 0, 0) : simd_normalize(radialWorld)

        // Plane whose normal is the outward radial: pull arrow points outward.
        let xAxis = worldAxisDir
        var yAxis = simd_cross(radialWorld, worldAxisDir)
        yAxis = simd_length(yAxis) < 1e-9
            ? simd_normalize(simd_cross(radialWorld, SIMD3(0, 1, 0)))
            : simd_normalize(yAxis)
        var plane = SketchPlane(origin: hitWorld, xAxis: xAxis, yAxis: yAxis)
        if simd_dot(plane.normal, radialWorld) < 0 {
            plane = SketchPlane(origin: hitWorld, xAxis: xAxis, yAxis: -yAxis)
        }

        // A tiny profile centred at the plane origin anchors the pull arrow.
        let tiny: [SIMD2<Double>] = [
            SIMD2(-0.001, -0.001), SIMD2(0.001, -0.001),
            SIMD2(0.001, 0.001), SIMD2(-0.001, 0.001),
        ]
        toolContext = ToolContext(
            profile: Profile(loop: tiny, kind: .polygonal, sourceEntityIDs: []),
            holes: [],
            plane: plane,
            sketchID: nil,
            sourceBody: body.id,
            faceTriangles: cyl.triangles,
            cylinderFace: cyl,
            kind: .extrude(distance: 0)
        )
        mode = .faceSelected(body.id)
    }

    private func faceModifiedMesh(_ context: ToolContext, distance: Double) -> Euclid.Mesh? {
        guard let sourceID = context.sourceBody,
              let source = session.document.body(with: sourceID)
        else { return nil }

        // Cylindrical side push/pull: rebuild the whole cylinder at the new
        // radius (distance is the radial delta). Local params → world via the
        // body transform.
        if let cyl = context.cylinderFace {
            let newRadius = cyl.radius + distance / max(source.transform.scale, 1e-6)
            guard newRadius > 1e-3 else { return nil }
            let grown = KernelOps.cylinderAlongAxis(
                baseCenter: cyl.baseCenter,
                axisDir: cyl.axisDir,
                radius: newRadius,
                height: cyl.height,
                slices: 48
            )
            return grown.transformed(by: source.transform.euclid)
        }

        let worldBody = source.euclidMesh().transformed(by: source.transform.euclid)
        let n = context.plane.normal

        if distance < 0 {
            // Move the face plane into the body; keep the interior (−n) side.
            let cutOrigin = context.plane.origin + n * distance
            let cutPlane = SketchPlane(
                origin: cutOrigin, xAxis: context.plane.xAxis, yAxis: context.plane.yAxis
            )
            let truncated = SplitKit.split(mesh: worldBody, byPlane: cutPlane).other
            return truncated.polygons.isEmpty ? nil : truncated
        } else {
            let prism = KernelOps.extrude(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                distance: distance
            )
            guard !prism.polygons.isEmpty else { return nil }
            return worldBody.union(prism).makeWatertight()
        }
    }

    /// Slightly overlapped tool (union of all profile prisms) so coplanar
    /// seams merge cleanly. Delegates to `KernelOps.overlapExtrudeTool` so the
    /// live cut and the feature-graph replay share one implementation.
    private func overlapExtrudeTool(_ context: ToolContext, distance: Double) -> Euclid.Mesh {
        KernelOps.overlapExtrudeTool(
            profile: context.profile,
            holes: context.holes,
            extraProfiles: context.extraProfiles,
            in: context.plane,
            distance: distance,
            symmetric: context.symmetric
        )
    }

    /// Commit a face push/pull: replace the source body with its truncated or
    /// extended mesh, preserving the pivot (rotation/scale bake in).
    private func commitFaceOperation(_ context: ToolContext, distance: Double) {
        guard let sourceID = context.sourceBody,
              let source = session.document.body(with: sourceID),
              let modified = faceModifiedMesh(context, distance: distance),
              !modified.polygons.isEmpty
        else {
            errorMessage = distance < 0
                ? "The push removed the entire body."
                : "The pull produced no geometry."
            cancelTool()
            return
        }
        let pivot = source.transform.translation
        var transform = Transform3D.identity
        transform.translation = pivot
        let localMesh = modified.translated(by: Vector(-pivot.x, -pivot.y, -pivot.z))
        let after = Body(
            id: source.id,
            name: source.name,
            transform: transform,
            primitive: nil,
            euclidMesh: localMesh,
            revision: 0
        )
        let replace = ReplaceBodyCommand(title: "Push/Pull", before: source, after: after)

        // Phase D (Task C2): record a `.pushPull(.planarAxial)` feature node when
        // this is a PLANAR face op on a feature-produced body. The FaceRef pins
        // the pushed face by geometric signature so it follows the geometry after
        // an upstream edit. Cylinder-radial pulls (tranche 2) and face ops on
        // non-feature bodies are skipped (couldn't be faithfully replayed).
        if context.cylinderFace == nil,
           let owner = featureNode(owning: sourceID),
           let faceRef = pushPullFaceRef(context: context, source: source, creator: owner.id) {
            let node = FeatureNode(
                name: "Push/Pull",
                kind: .pushPull(
                    face: faceRef, distance: Expr(value: distance), mode: .planarAxial),
                outputBodyIDs: [sourceID])
            session.perform(CompositeCommand(
                title: "Push/Pull", commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        toolContext = nil
        mode = .selected(source.id)
        selection = [source.id]
        session.save()
    }

    private func commitRevolve(_ context: ToolContext, angle: Double) {
        guard angle >= 1, let preview = context.preview else {
            cancelTool()
            return
        }
        // The revolved solid has no push/pull direction: no subtract sample;
        // overlapping bodies merge by union, otherwise it's a new body.
        commitToolResult(
            preview: preview,
            mergeTool: preview.euclidMesh(),
            sample: nil,
            title: "Revolve",
            context: context
        )
    }

    /// Shared commit tail: honor the Boolean badge override, or scan candidate
    /// bodies for an automatic boolean (inside `sample` → subtract,
    /// overlapping → union), else add a new stand-alone body from the preview.
    private func commitToolResult(
        preview: Body,
        mergeTool: Euclid.Mesh,
        sample: Vector?,
        title: String,
        context: ToolContext
    ) {
        if context.booleanOverride == .newBody {
            addStandaloneToolBody(preview: preview, title: title, context: context)
            return
        }

        // Scan: which bodies does the tool touch, and does it push into any?
        var touched: [(target: Body, worldTarget: Euclid.Mesh, pushesIn: Bool)] = []
        for target in booleanCandidates(for: context) {
            let worldTarget = target.euclidMesh().transformed(by: target.transform.euclid)
            let pushesIn = sample.map { worldTarget.intersects($0) } ?? false
            let touches = pushesIn
                || context.sourceBody == target.id
                || !worldTarget.intersection(mergeTool).polygons.isEmpty
            if touches {
                touched.append((target, worldTarget, pushesIn))
            }
        }

        let kind: BooleanKind
        switch context.booleanOverride {
        case .auto:
            guard !touched.isEmpty else {
                addStandaloneToolBody(preview: preview, title: title, context: context)
                return
            }
            kind = touched.contains { $0.pushesIn } ? .subtract : .union
        case .union:
            guard !touched.isEmpty else {
                // Spec §4.1: a Union touching no body stays a separate body.
                addStandaloneToolBody(preview: preview, title: title, context: context)
                return
            }
            kind = .union
        case .subtract, .intersect:
            guard !touched.isEmpty else {
                // Keep the tool active so the user can adjust and retry.
                errorMessage = "The \(context.booleanOverride.rawValue.lowercased()) result is empty — the tool doesn't touch any body."
                return
            }
            kind = context.booleanOverride == .subtract ? .subtract : .intersect
        case .newBody:
            return // handled above
        }

        // Cut scope (spec §4.1): a subtract applies to EVERY intersected
        // body; union/intersect keep the first touched target.
        let targets = kind == .subtract ? touched : [touched[0]]
        var commands: [DocumentCommand] = []
        for entry in targets {
            let merged: Euclid.Mesh
            switch kind {
            case .union:
                merged = entry.worldTarget.union(mergeTool).makeWatertight()
            case .subtract:
                merged = entry.worldTarget.subtracting(mergeTool).makeWatertight()
            case .intersect:
                merged = entry.worldTarget.intersection(mergeTool).makeWatertight()
            }
            guard !merged.polygons.isEmpty else {
                errorMessage = kind == .intersect
                    ? "The intersection is empty — the bodies don't overlap."
                    : "The cut removed the entire body."
                cancelTool()
                return
            }

            // Preserve the pivot; rotation/scale bake into the mesh.
            let pivot = entry.target.transform.translation
            var transform = Transform3D.identity
            transform.translation = pivot
            let localMesh = merged.translated(by: Vector(-pivot.x, -pivot.y, -pivot.z))
            let after = Body(
                id: entry.target.id,
                name: entry.target.name,
                transform: transform,
                primitive: nil,
                euclidMesh: localMesh,
                revision: 0 // assigned by the command
            )
            commands.append(ReplaceBodyCommand(title: title, before: entry.target, after: after))
        }

        // Spec §11: sketches auto-hide once a tool consumes them, in the
        // same undo step.
        if let hide = consumedSketchHideCommand(context) {
            commands.append(hide)
        }
        // Phase D: record the tool's feature node (extrude in tranche 1;
        // revolve / sweep / loft in tranche 2) with the resolved boolean intent,
        // but only for a SINGLE feature-owned target — the evaluators apply one
        // boolean into one target, so a multi-body cut or a non-feature target
        // couldn't be faithfully replayed.
        if targets.count == 1,
           let targetOwner = featureNode(owning: targets[0].target.id),
           let node = toolFeatureNode(
               context: context,
               boolean: BooleanIntent(
                   op: kind.featureOp,
                   resolvedTargets: [BodyRef(
                       producer: targetOwner.id, bodyID: targets[0].target.id)]),
               outputBodyIDs: [targets[0].target.id]) {
            commands.append(AppendFeatureCommand(node: node))
        }
        if commands.count == 1 {
            session.perform(commands[0])
        } else {
            // Multi-body cut is one undo step.
            session.perform(CompositeCommand(title: title, commands: commands))
        }
        let selected = targets[0].target.id
        toolContext = nil
        mode = .selected(selected)
        selection = [selected]
        session.save()
    }

    /// New stand-alone body from the preview, pivot at the profile centroid.
    private func addStandaloneToolBody(preview: Body, title: String, context: ToolContext) {
        let centroidWorld = context.plane.toWorld(context.profile.centroid)
        var transform = Transform3D.identity
        transform.translation = centroidWorld
        let localMesh = preview.euclidMesh().translated(
            by: Vector(-centroidWorld.x, -centroidWorld.y, -centroidWorld.z)
        )

        let name = session.document.uniqueBodyName(base: title)
        let body = Body(
            name: name,
            transform: transform,
            primitive: nil,
            euclidMesh: localMesh,
            revision: preview.meshRevision
        )
        var commands: [DocumentCommand] = [AddBodyCommand(body: body, title: title)]
        if let hide = consumedSketchHideCommand(context) {
            commands.append(hide)
        }
        // Phase D: a new stand-alone tool body becomes a `.newBody` history node
        // — extrude in tranche 1, or revolve / sweep / loft in tranche 2.
        if let node = toolFeatureNode(
            context: context,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            outputBodyIDs: [body.id]) {
            commands.append(AppendFeatureCommand(node: node))
        }
        if commands.count == 1 {
            session.perform(commands[0])
        } else {
            session.perform(CompositeCommand(title: title, commands: commands))
        }
        toolContext = nil
        mode = .selected(body.id)
        selection = [body.id]
        session.save()
    }

    /// Hide-the-consumed-sketch command for a committing tool, or nil when the
    /// tool has no sketch (face pulls) or it is already hidden.
    private func consumedSketchHideCommand(_ context: ToolContext) -> DocumentCommand? {
        guard let sketchID = context.sketchID,
              let sketch = session.document.sketches.first(where: { $0.id == sketchID }),
              !sketch.isHidden
        else { return nil }
        return SetItemVisibilityCommand(item: .sketch(sketchID), isHidden: true)
    }

    func cancelTool() {
        toolContext = nil
        extrudeDragAnchor = nil
        switch mode {
        case .extruding, .faceSelected, .pickingRevolveAxis,
             .pickingSweepPath, .pickingLoftProfiles:
            mode = .idle
        default:
            break
        }
    }

    // MARK: - Revolve axis picking

    /// "Revolve" in the extrude bar: the next tap must land on a sketch line,
    /// which becomes the axis of revolution.
    func beginRevolveAxisPick() {
        guard case .extruding = mode, let context = toolContext,
              context.sketchID != nil
        else { return }
        mode = .pickingRevolveAxis
    }

    func cancelRevolveAxisPick() {
        if case .pickingRevolveAxis = mode {
            mode = .extruding
        }
    }

    private func pickRevolveAxis(ray: Ray) {
        guard let context = toolContext,
              let sketchID = context.sketchID,
              let sketch = session.document.sketches.first(where: { $0.id == sketchID })
        else {
            cancelTool()
            return
        }
        let plane = context.plane
        let planePoint = SIMD3<Float>(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z))
        let n = plane.normal
        let planeNormal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else { return }
        let world = ray.point(at: t)
        let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))

        // Nearest line entity within a forgiving tap tolerance; taps that miss
        // every line keep the picking mode armed. Construction lines are
        // preferred axis candidates (spec §3.3): any construction hit beats
        // any regular hit; ties within a class break by distance.
        let tolerance = SnapEngine.pointTolerance * 2
        var best: (a: SIMD2<Double>, b: SIMD2<Double>, distance: Double, isConstruction: Bool)?
        for entity in sketch.entities {
            guard case .line(let id, let a, let b) = entity else { continue }
            let d = Self.distanceToSegment(local, a: a, b: b)
            guard d <= tolerance else { continue }
            let isConstruction = sketch.isConstruction(id)
            let better: Bool = if let current = best {
                isConstruction != current.isConstruction
                    ? isConstruction
                    : d < current.distance
            } else {
                true
            }
            if better {
                best = (a, b, d, isConstruction)
            }
        }
        guard let line = best else { return }

        var candidate = context
        candidate.kind = .revolve(
            axis: RevolveAxis(point: line.a, direction: line.b - line.a),
            angle: 360
        )
        rebuildToolPreview(&candidate)
        guard candidate.preview != nil else {
            // Profile crosses (or collapses onto) the axis — Shapr3D errors too.
            errorMessage = "The profile crosses the axis line. Pick a line beside the profile."
            mode = .extruding
            return
        }
        toolContext = candidate
        mode = .extruding
    }

    static func distanceToSegment(
        _ p: SIMD2<Double>, a: SIMD2<Double>, b: SIMD2<Double>
    ) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-18 else { return simd_length(p - a) }
        let t = min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1)
        return simd_length(p - (a + ab * t))
    }

    // MARK: - Sweep path picking (plan §B1, spec §4.11)

    /// "Sweep" in the extrude bar: subsequent taps on open sketch entities
    /// (lines/arcs, any visible sketch) chain into the sweep spine.
    func beginSweepPathPick() {
        guard case .extruding = mode, let context = toolContext,
              context.sketchID != nil
        else { return }
        mode = .pickingSweepPath
    }

    /// Cancel returns to the plain extrude tool (like the revolve axis pick).
    func cancelSweepPathPick() {
        guard case .pickingSweepPath = mode else { return }
        guard var context = toolContext else {
            mode = .idle
            return
        }
        context.kind = .extrude(distance: 2)
        context.sweepPathEntityIDs = []
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding
    }

    /// Tap while picking the sweep path: the nearest open entity chains onto
    /// the spine; tapping empty space commits a nonempty path (extrude's rule).
    private func pickSweepPathEntity(ray: Ray) {
        guard var context = toolContext else {
            cancelTool()
            return
        }
        let tolerance = max(0.4, 16 * worldPerPoint)
        var best: (entity: SketchEntity, plane: SketchPlane, distance: Double)?
        for sketch in session.document.sketches where !sketch.isHidden {
            guard let local = localPoint(of: ray, on: sketch.plane) else { continue }
            for entity in sketch.entities {
                guard let points = Self.sweepPathPolyline(of: entity) else { continue }
                var distance = Double.infinity
                for i in 1..<points.count {
                    distance = min(
                        distance,
                        Self.distanceToSegment(local, a: points[i - 1], b: points[i])
                    )
                }
                if distance <= tolerance, best == nil || distance < best!.distance {
                    best = (entity, sketch.plane, distance)
                }
            }
        }
        guard let hit = best else {
            if case .sweep = context.kind { commitTool() }
            return
        }
        guard !context.sweepPathEntityIDs.contains(hit.entity.id),
              let localPolyline = Self.sweepPathPolyline(of: hit.entity)
        else { return }

        let segment = localPolyline.map { hit.plane.toWorld($0) }
        let spine: [SIMD3<Double>]
        if case .sweep(let existing) = context.kind, existing.count >= 2 {
            guard let joined = Self.chainedSpine(existing, adding: segment) else {
                errorMessage = "That segment doesn't connect to the end of the path."
                return
            }
            spine = joined
        } else {
            // First segment: start at the endpoint nearest the profile.
            let anchor = context.plane.toWorld(context.profile.centroid)
            spine = simd_length(segment.last! - anchor) < simd_length(segment.first! - anchor)
                ? segment.reversed()
                : segment
        }
        context.sweepPathEntityIDs.append(hit.entity.id)
        context.kind = .sweep(spine: spine)
        rebuildToolPreview(&context)
        toolContext = context
    }

    /// Plane-local polyline of an OPEN entity (lines/arcs); closed entities
    /// can't chain into a spine.
    nonisolated static func sweepPathPolyline(of entity: SketchEntity) -> [SIMD2<Double>]? {
        switch entity {
        case let .line(_, a, b):
            return [a, b]
        case let .arc(_, center, radius, startAngle, endAngle):
            let points = SketchEntity.arcPoints(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle,
                segmentsPerTurn: SketchTessellator.circleSegments
            )
            return points.count >= 2 ? points : nil
        case .rect, .circle, .ellipse, .polygon:
            return nil
        }
    }

    /// Append `segment` to `spine`, reversed so its nearer endpoint meets the
    /// spine's end; nil when neither endpoint is within `tolerance`. The
    /// junction point is dropped so tiny gaps close onto the spine end.
    nonisolated static func chainedSpine(
        _ spine: [SIMD3<Double>],
        adding segment: [SIMD3<Double>],
        tolerance: Double = 0.75
    ) -> [SIMD3<Double>]? {
        guard let end = spine.last, let first = segment.first, let last = segment.last
        else { return nil }
        let dFirst = simd_length(first - end)
        let dLast = simd_length(last - end)
        guard min(dFirst, dLast) <= tolerance else { return nil }
        let oriented: [SIMD3<Double>] = dLast < dFirst ? segment.reversed() : segment
        return spine + oriented.dropFirst()
    }

    /// Ray → plane-local point on an arbitrary plane.
    private func localPoint(of ray: Ray, on plane: SketchPlane) -> SIMD2<Double>? {
        let planePoint = SIMD3<Float>(
            Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
        )
        let n = plane.normal
        let planeNormal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else {
            return nil
        }
        let world = ray.point(at: t)
        return plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }

    private func commitSweep(_ context: ToolContext, spine: [SIMD3<Double>]) {
        guard spine.count >= 2, let preview = context.preview else {
            cancelTool()
            return
        }
        // Like revolve: no push/pull direction — union overlapping bodies,
        // otherwise a new body.
        commitToolResult(
            preview: preview,
            mergeTool: preview.euclidMesh(),
            sample: nil,
            title: "Sweep",
            context: context
        )
    }

    // MARK: - Loft (plan §B2, spec §4.5 profiles-only)

    /// "Loft" in the extrude bar: the armed profile becomes section 1; taps
    /// on more profile fills (any plane) append sections in tap order.
    func beginLoftProfilePick() {
        guard case .extruding = mode, var context = toolContext,
              let sketchID = context.sketchID
        else { return }
        context.loftProfiles = [(context.profile, context.holes, context.plane, sketchID)]
        context.kind = .loft
        rebuildToolPreview(&context)
        toolContext = context
        mode = .pickingLoftProfiles
    }

    /// Cancel returns to the plain extrude tool.
    func cancelLoftProfilePick() {
        guard case .pickingLoftProfiles = mode else { return }
        guard var context = toolContext else {
            mode = .idle
            return
        }
        context.kind = .extrude(distance: 2)
        context.loftProfiles = []
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding
    }

    /// Tap while picking loft sections: any profile fill appends a section.
    private func pickLoftProfile(ray: Ray) {
        guard var context = toolContext, case .loft = context.kind else {
            cancelTool()
            return
        }
        guard let hit = profileHit(ray: ray) else { return }
        // The same fill can't be a section twice.
        guard !context.loftProfiles.contains(where: {
            $0.sketchID == hit.sketchID
                && $0.profile.sourceEntityIDs == hit.profile.sourceEntityIDs
        }) else { return }
        context.loftProfiles.append((hit.profile, hit.holes, hit.plane, hit.sketchID))
        rebuildToolPreview(&context)
        toolContext = context
    }

    private func commitLoft(_ context: ToolContext) {
        guard context.loftProfiles.count >= 2 else {
            cancelTool()
            return
        }
        // Coplanar sections loft to a zero-thickness sheet — reject upfront
        // and keep the tool armed so another section can be added.
        let firstPlane = context.loftProfiles[0].plane
        guard context.loftProfiles.contains(where: {
            !$0.plane.isCoincident(with: firstPlane)
        }) else {
            errorMessage = "Loft sections must lie on different planes — add a profile on another plane or face."
            return
        }
        guard let preview = context.preview else {
            errorMessage = "The loft produced no geometry."
            cancelTool()
            return
        }
        commitToolResult(
            preview: preview,
            mergeTool: preview.euclidMesh(),
            sample: nil,
            title: "Loft",
            context: context
        )
    }

    // MARK: - Helix (plan §B16, spec §1.17 minimal: a helix drives a sweep)

    /// "Helix" in the extrude bar: sweep the armed profile along a generated
    /// helical spine (coiling up the sketch-plane normal, starting at the
    /// profile centroid) and commit immediately.
    func commitHelixSweep(radius: Double, pitch: Double, turns: Double) {
        guard var context = toolContext, case .extrude = context.kind else { return }
        guard radius > 1e-6, turns > 1e-3, abs(pitch) > 1e-9 else {
            errorMessage = "Helix needs a positive radius, pitch, and turns."
            return
        }
        // Center the coil so the spine STARTS at the profile centroid — the
        // profile rides the helix (Shapr3D: profile at the path start).
        let center = context.profile.centroid - SIMD2(radius, 0)
        let spine = HelixKit.path(
            radius: radius, pitch: pitch, turns: turns,
            center: center, in: context.plane
        )
        guard spine.count >= 2 else {
            errorMessage = "The helix parameters produced no path."
            return
        }
        context.kind = .sweep(spine: spine)
        context.sweepPathEntityIDs = []
        rebuildToolPreview(&context)
        guard context.preview != nil else {
            errorMessage = "The helix sweep produced no geometry."
            return
        }
        toolContext = context
        commitTool()
    }

    // MARK: - Tool drag (extrude: pull along the plane normal; revolve: angle)

    /// Degrees of revolve sweep per world unit of screen-space drag.
    private static let revolveDegreesPerWorldUnit: Double = 30

    func beginToolDrag(ray: Ray) -> Bool {
        guard let context = toolContext else { return false }
        switch context.kind {
        case .extrude(let distance), .offsetPlane(let distance):
            let centroid = context.profile.centroid
            let world = context.plane.toWorld(centroid)
            let n = context.plane.normal
            let axisOrigin = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
            let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
            if abs(simd_dot(ray.direction, axisDirection)) < 0.95 {
                extrudeDragAnchor = LineMath.closestParamOnLine(
                    origin: axisOrigin, direction: axisDirection, to: ray
                )
            } else {
                extrudeDragAnchor = nil // head-on: screen-space fallback
            }
            toolDragStartValue = distance
        case .revolve(_, let angle):
            extrudeDragAnchor = nil // angle drags are always screen-space
            toolDragStartValue = angle
        case .sweep, .loft:
            return false // no drag-editable parameter
        }
        return true
    }

    /// `screenDeltaWorld`: cumulative drag distance since `.began` converted
    /// to world units by the viewport (positive = screen-up). Used when the
    /// camera looks straight down the pull axis, and to scrub revolve angles.
    func updateToolDrag(ray: Ray, screenDeltaWorld: Double) {
        guard let context = toolContext else { return }
        switch context.kind {
        case .extrude, .offsetPlane:
            let raw: Double
            if let anchor = extrudeDragAnchor {
                let centroid = context.profile.centroid
                let world = context.plane.toWorld(centroid)
                let n = context.plane.normal
                let axisOrigin = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
                let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
                guard let param = LineMath.closestParamOnLine(
                    origin: axisOrigin, direction: axisDirection, to: ray
                ) else { return }
                raw = toolDragStartValue + Double(param - anchor)
            } else {
                raw = toolDragStartValue + screenDeltaWorld
            }
            // Snap to 0.5 steps, like the sketch grid.
            let snapped = (raw / 0.5).rounded() * 0.5
            let value = abs(raw - snapped) < 0.15 ? snapped : raw
            if case .offsetPlane = context.kind {
                setOffsetPlaneDistance(value)
            } else {
                setExtrudeDistance(value)
            }
        case .revolve:
            let raw = toolDragStartValue + screenDeltaWorld * Self.revolveDegreesPerWorldUnit
            // Snap to 15° stops (90, 180, …) with a small capture window.
            let snapped = (raw / 15).rounded() * 15
            setRevolveAngle(abs(raw - snapped) < 4 ? snapped : raw)
        case .sweep, .loft:
            break // no drag-editable parameter
        }
    }

    func endToolDrag() {
        // Shapr3D: releasing the drag keeps the dynamic preview so you can
        // refine the value; commit by tapping empty space or the tool button
        // ("select an empty area of the grid to complete the tool").
        extrudeDragAnchor = nil
    }

    // MARK: - Sketch mode

    /// In-progress entity during a sketch drag (rubber band).
    var pendingEntity: SketchEntity?
    private var sketchStrokeStart: SIMD2<Double>?

    // MARK: - Auto-constraint / inference (plan §B, spec §3, contract D)

    /// Live auto-constraint inference settings, persisted across launches via
    /// UserDefaults (saved on every mutation).
    var autoConstrainSettings = AutoConstraintSettings() {
        didSet { saveAutoConstrainSettings() }
    }

    /// Presents the auto-constrain settings panel (sheet).
    var showConstraintSettings = false

    /// Inference guides to render while the current stroke is drawn (violet
    /// reference lines). Cleared when the stroke ends/cancels.
    var activeGuides: [AutoConstraintEngine.Guide] = []

    /// Constraints inferred for the in-progress stroke; emitted (defensively,
    /// never over-constraining) when the stroke commits.
    private var pendingInferredConstraints: [AutoConstraintEngine.Inferred] = []

    private static let autoConstrainDefaultsKey = "autoConstrainSettings"

    private func saveAutoConstrainSettings() {
        if let data = try? JSONEncoder().encode(autoConstrainSettings) {
            UserDefaults.standard.set(data, forKey: Self.autoConstrainDefaultsKey)
        }
    }

    private func loadAutoConstrainSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.autoConstrainDefaultsKey),
              let decoded = try? JSONDecoder().decode(AutoConstraintSettings.self, from: data)
        else { return }
        autoConstrainSettings = decoded
    }

    /// A per-point DOF marker for the active sketch overlay (contract D): blue
    /// hollow = free, green = constrained, blue square = locked.
    struct SketchPointMarker: Identifiable, Sendable {
        var id: String
        var world: SIMD3<Float>
        var state: SketchPointState
    }

    /// Memoized `sketchPointMarkers`, keyed on the document revision and active
    /// sketch. `@ObservationIgnored` so writing it from the getter never itself
    /// triggers observation. Point states depend only on the sketch, never the
    /// camera — so an orbit/pan (which re-runs the overlay via `cameraEpoch`)
    /// hits this cache instead of re-solving.
    @ObservationIgnored
    private var pointMarkerCache: (changeCount: Int, sketchID: SketchID?, markers: [SketchPointMarker])?

    /// DOF markers for every point of the ACTIVE sketch (empty when not
    /// sketching or no active sketch). Reuses `SketchSolverBridge.pointStates`
    /// (a full solve + null-space eigen decomposition), memoized per document
    /// revision; the overlay reprojects each cached marker on camera moves.
    var sketchPointMarkers: [SketchPointMarker] {
        let cc = session.changeCount
        guard let sketch = activeSketch else {
            pointMarkerCache = nil
            return []
        }
        if let cache = pointMarkerCache, cache.changeCount == cc, cache.sketchID == sketch.id {
            return cache.markers
        }
        let states = SketchSolverBridge.pointStates(sketch)
        var out: [SketchPointMarker] = []
        out.reserveCapacity(states.count)
        for (key, state) in states {
            guard let local = localPoint(
                ConstraintRef(entityID: key.entityID, role: key.role), in: sketch
            ) else { continue }
            let w = sketch.plane.toWorld(local)
            out.append(SketchPointMarker(
                id: "\(key.entityID):\(key.role.rawValue)",
                world: SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)),
                state: state
            ))
        }
        pointMarkerCache = (cc, sketch.id, out)
        return out
    }

    // MARK: - Sketch element selection + drag-editing

    /// Selected entities of the active sketch (accent highlight; palette
    /// Delete removes them).
    var selectedSketchEntityIDs: Set<UUID> = []

    /// A selected model point (endpoint/center) on a sketch entity, addressed
    /// by the role the constraint solver understands (plan §C3).
    struct SketchPointSelection: Hashable, Sendable {
        var entityID: UUID
        var role: PointRole
    }

    /// Points tapped for constraints (endpoints/centers). Independent of
    /// `selectedSketchEntityIDs` so a mixed selection (e.g. a point + a line
    /// for Midpoint) is expressible.
    var selectedSketchPoints: Set<SketchPointSelection> = []

    /// The constraint glyph currently selected (tap-select in the overlay or the
    /// Items panel). Palette/keyboard Delete removes it. Mutually exclusive with
    /// `selectedDimensionID`.
    var selectedConstraintID: UUID?

    /// The dimension currently selected in the Items panel (for delete). The
    /// overlay label tap opens the numeric editor instead, so this is set from
    /// the Items list.
    var selectedDimensionID: UUID?

    /// A drag editing one entity: a control point (endpoint/center/handle)
    /// or the whole body (nil control = translate). The command is pushed on
    /// the first change and amend-coalesced for the rest of the drag.
    private struct SketchEntityDrag {
        var sketchID: SketchID
        var control: SketchHitTester.ControlKind?
        var before: SketchEntity
        /// Raw plane point where the drag grabbed the entity (translations).
        var grabPoint: SIMD2<Double>
        /// Pre-drag snapshot of ALL sketch entities. Used by the solve-on-edit
        /// path (plan §C1) as the fixed baseline every frame solves from — and
        /// as the command's undo `before`.
        var baseline: [SketchEntity]
        var pushed = false
    }
    private var sketchEntityDrag: SketchEntityDrag?

    /// Screen-space pick tolerances projected onto the sketch plane. Floors
    /// keep grabs forgiving when the head-on camera is zoomed far in/out.
    private var worldPerPoint: Double { cameraControl?.worldUnitsPerPoint ?? 0.01 }
    private var controlPointTolerance: Double {
        max(SnapEngine.pointTolerance * 1.2, 24 * worldPerPoint)
    }
    private var entityPickTolerance: Double {
        max(0.4, 16 * worldPerPoint)
    }

    // MARK: - Sketch Move/Rotate gizmo (plan §B6, spec §1.10)

    /// Copy chip while sketching (spec §1.10): the next gizmo drag
    /// moves/rotates duplicates of the selection. Resets after each drag.
    var sketchCopyOnDrag = false

    private enum SketchGizmoDragKind { case move, rotate }

    /// A drag on the sketch selection gizmo: the handle translates the
    /// selected entities, the ring rotates them about the centroid. One
    /// command per drag (perform once, then amend-coalesce).
    private struct SketchGizmoDrag {
        var kind: SketchGizmoDragKind
        var sketchID: SketchID
        /// Entities when the drag began (transform baseline).
        var originals: [SketchEntity]
        var pivot: SIMD2<Double>
        var grabPoint: SIMD2<Double>
        var pushed = false
    }
    private var sketchGizmoDrag: SketchGizmoDrag?

    /// Gizmo dimensions in plane units (floored for constant screen size).
    private var sketchGizmoHandleRadius: Double { max(0.4, 22 * worldPerPoint) }
    private var sketchGizmoRingRadius: Double { max(1.4, 64 * worldPerPoint) }
    private var sketchGizmoRingWidth: Double { max(0.35, 16 * worldPerPoint) }

    /// Centroid of the selected sketch entities (gizmo anchor), plane-local.
    var sketchSelectionCentroid: SIMD2<Double>? {
        guard let sketch = activeSketch else { return nil }
        let selected = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        let sum = selected.reduce(SIMD2<Double>.zero) { $0 + Self.entityCenter($1) }
        return sum / Double(selected.count)
    }

    nonisolated static func entityCenter(_ entity: SketchEntity) -> SIMD2<Double> {
        switch entity {
        case let .line(_, a, b): (a + b) / 2
        case let .rect(_, lo, hi): (lo + hi) / 2
        case let .circle(_, center, _), let .arc(_, center, _, _, _),
             let .ellipse(_, center, _, _, _), let .polygon(_, center, _, _, _):
            center
        }
    }

    /// Overlay line segments for the selection gizmo: a cross + diamond
    /// handle at the centroid and the surrounding rotate ring.
    private func sketchGizmoSegments(
        centroid: SIMD2<Double>, plane: SketchPlane
    ) -> [SIMD3<Float>] {
        func world(_ p: SIMD2<Double>) -> SIMD3<Float> {
            let w = plane.toWorld(p)
            return SIMD3(Float(w.x), Float(w.y), Float(w.z))
        }
        var segments: [SIMD3<Float>] = []
        let r = sketchGizmoHandleRadius
        segments += [
            world(centroid - SIMD2(r, 0)), world(centroid + SIMD2(r, 0)),
            world(centroid - SIMD2(0, r)), world(centroid + SIMD2(0, r)),
        ]
        let diamond = [SIMD2(r, 0.0), SIMD2(0.0, r), SIMD2(-r, 0.0), SIMD2(0.0, -r)]
        for i in 0..<4 {
            segments.append(world(centroid + diamond[i]))
            segments.append(world(centroid + diamond[(i + 1) % 4]))
        }
        let ring = sketchGizmoRingRadius
        let ringSegments = 48
        for i in 0..<ringSegments {
            let t0 = Double(i) / Double(ringSegments) * 2 * .pi
            let t1 = Double(i + 1) / Double(ringSegments) * 2 * .pi
            segments.append(world(centroid + SIMD2(cos(t0), sin(t0)) * ring))
            segments.append(world(centroid + SIMD2(cos(t1), sin(t1)) * ring))
        }
        return segments
    }

    /// A drag starting on the selection gizmo claims the stroke: the center
    /// handle translates, the ring rotates. Copy chip duplicates first.
    private func beginSketchGizmoDrag(at raw: SIMD2<Double>) -> Bool {
        guard case .sketching(let sketchID, _) = mode,
              !selectedSketchEntityIDs.isEmpty,
              let centroid = sketchSelectionCentroid,
              let sketch = activeSketch
        else { return false }
        let distance = simd_length(raw - centroid)
        let kind: SketchGizmoDragKind
        if distance <= sketchGizmoHandleRadius {
            kind = .move
        } else if abs(distance - sketchGizmoRingRadius) <= sketchGizmoRingWidth {
            kind = .rotate
        } else {
            return false
        }
        var entities = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        guard !entities.isEmpty else { return false }

        // Copy chip: duplicate first; the drag then moves the copies.
        if sketchCopyOnDrag {
            sketchCopyOnDrag = false
            entities = duplicateSketchEntities(entities, in: sketchID)
        }

        // Rotation decomposes rects into 4 lines once, up front, so every
        // later step maps entities one-to-one (amend-friendly commands).
        let containsRect = entities.contains {
            if case .rect = $0 { return true }
            return false
        }
        if kind == .rotate, containsRect {
            entities = decomposeSelectedRects(entities, in: sketchID)
        }

        sketchGizmoDrag = SketchGizmoDrag(
            kind: kind,
            sketchID: sketchID,
            originals: entities,
            pivot: centroid,
            grabPoint: raw
        )
        sketchStrokeStart = nil
        pendingEntity = nil
        return true
    }

    /// Clone `entities` with fresh IDs in one undo step; the copies become
    /// the selection and the drag baseline.
    private func duplicateSketchEntities(
        _ entities: [SketchEntity], in sketchID: SketchID
    ) -> [SketchEntity] {
        var copies: [SketchEntity] = []
        var commands: [DocumentCommand] = []
        for entity in entities {
            for copy in PatternKit.transformed(entity, by: .identity) {
                copies.append(copy)
                commands.append(AddSketchEntityCommand(sketchID: sketchID, entity: copy))
            }
        }
        guard !commands.isEmpty else { return entities }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Copy", commands: commands))
        selectedSketchEntityIDs = Set(copies.map(\.id))
        return copies
    }

    /// Replace each selected rect with its 4 edge lines (one undo step); the
    /// first line inherits the rect's ID, like SketchTransform.rotate.
    private func decomposeSelectedRects(
        _ entities: [SketchEntity], in sketchID: SketchID
    ) -> [SketchEntity] {
        guard let sketch = activeSketch else { return entities }
        var result: [SketchEntity] = []
        var commands: [DocumentCommand] = []
        for entity in entities {
            guard case let .rect(id, lo, hi) = entity else {
                result.append(entity)
                continue
            }
            let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
            var lines: [SketchEntity] = []
            for i in 0..<4 {
                lines.append(.line(
                    id: i == 0 ? id : UUID(),
                    a: corners[i], b: corners[(i + 1) % 4]
                ))
            }
            commands.append(RemoveSketchEntitiesCommand(ids: [id], sketch: sketch))
            for line in lines {
                commands.append(AddSketchEntityCommand(sketchID: sketchID, entity: line))
            }
            result.append(contentsOf: lines)
        }
        guard !commands.isEmpty else { return entities }
        session.perform(CompositeCommand(title: "Rotate", commands: commands))
        selectedSketchEntityIDs = Set(result.map(\.id))
        return result
    }

    private func updateSketchGizmoDrag(raw: SIMD2<Double>) {
        guard var drag = sketchGizmoDrag else { return }
        let after: [SketchEntity]
        switch drag.kind {
        case .move:
            // Grid-capture each axis, like single-entity translates.
            var delta = raw - drag.grabPoint
            let snapped = SIMD2(
                (delta.x / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing,
                (delta.y / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing
            )
            if abs(delta.x - snapped.x) < 0.15 { delta.x = snapped.x }
            if abs(delta.y - snapped.y) < 0.15 { delta.y = snapped.y }
            after = SketchTransform.translate(entities: drag.originals, by: delta)
        case .rotate:
            // 5° steps while dragging (matches the body rings).
            let anchorAngle = atan2(
                drag.grabPoint.y - drag.pivot.y, drag.grabPoint.x - drag.pivot.x
            )
            let currentAngle = atan2(raw.y - drag.pivot.y, raw.x - drag.pivot.x)
            let degrees = ((currentAngle - anchorAngle) * 180 / .pi / 5).rounded() * 5
            after = SketchTransform.rotate(
                entities: drag.originals, about: drag.pivot, angle: degrees * .pi / 180
            )
        }
        // Rects were pre-decomposed, so the mapping is always one-to-one.
        guard after.count == drag.originals.count else { return }
        guard after != drag.originals || drag.pushed else { return }
        let updates: [DocumentCommand] = zip(drag.originals, after).map {
            UpdateSketchEntityCommand(sketchID: drag.sketchID, before: $0.0, after: $0.1)
        }
        let command: DocumentCommand = updates.count == 1
            ? updates[0]
            : CompositeCommand(
                title: drag.kind == .move ? "Move" : "Rotate", commands: updates
            )
        if drag.pushed {
            session.amend(command)
        } else {
            session.perform(command)
            drag.pushed = true
            sketchGizmoDrag = drag
        }
    }

    /// Tap while sketching: Trim cuts the span under the tap; other tools
    /// toggle entity selection, or finalize/clear pending state on empty space.
    private func handleSketchTap(ray: Ray, tool: SketchTool) {
        if tool == .trim {
            performTrim(ray: ray)
            return
        }
        if tool == .text {
            clearChain()
            // Tap-to-place (spec §1.12): the tapped point anchors the text
            // dialog's glyph baseline.
            if let point = sketchPoint(from: ray) {
                textPlacement = point
            }
            return
        }
        if tool == .project {
            clearChain()
            projectTappedBody(ray: ray)
            return
        }
        if pendingSymbolID != nil {
            // Insert Symbol armed (plan §B16): the tap stamps an instance.
            clearChain()
            placePendingSymbol(ray: ray)
            return
        }
        clearChain() // a tap ends line chaining
        if pendingArc != nil {
            // Tap elsewhere finalizes the bulge-adjustable pending arc.
            commitPendingArc()
            return
        }
        guard let sketch = activeSketch, let raw = rawSketchPoint(from: ray) else { return }
        // Tapping geometry clears any constraint/dimension glyph selection.
        selectedConstraintID = nil
        selectedDimensionID = nil
        // A tap landing near a model point (endpoint/center) selects that POINT
        // for constraints (plan §C3); the tight point tolerance means the body
        // of a line/curve still selects the whole entity.
        if let pt = SketchHitTester.nearestPoint(
            to: raw, in: sketch.entities, tolerance: controlPointTolerance
        ) {
            let sel = SketchPointSelection(entityID: pt.entityID, role: pt.role)
            if selectedSketchPoints.contains(sel) {
                selectedSketchPoints.remove(sel)
            } else {
                selectedSketchPoints.insert(sel)
            }
            return
        }
        if let hit = SketchHitTester.nearestEntity(
            to: raw, in: sketch.entities, tolerance: entityPickTolerance
        ) {
            if selectedSketchEntityIDs.contains(hit.entity.id) {
                selectedSketchEntityIDs.remove(hit.entity.id)
            } else {
                selectedSketchEntityIDs.insert(hit.entity.id)
            }
        } else {
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints.removeAll()
        }
    }

    /// Trim (spec §1.14): delete the tapped span between the entity's nearest
    /// intersections with the other entities.
    private func performTrim(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let raw = rawSketchPoint(from: ray),
              let hit = SketchHitTester.nearestEntity(
                  to: raw, in: sketch.entities, tolerance: entityPickTolerance
              ),
              let fragments = SketchTrimmer.trim(entity: hit.entity, at: raw, in: sketch),
              let index = sketch.entities.firstIndex(where: { $0.id == hit.entity.id })
        else { return }
        selectedSketchEntityIDs.remove(hit.entity.id)
        session.perform(TrimCommand(
            sketchID: sketchID, index: index, removed: hit.entity, fragments: fragments
        ))
        // Phase D: trimming edits sketch geometry — rebuild dependent features.
        session.rebuildForSketchChange(sketchID)
    }

    /// A drag landing on an entity edits it instead of drawing: control
    /// points (endpoints/centers/handles) win, then the entity body
    /// (translate). Selects the grabbed entity.
    private func beginSketchEntityDrag(at raw: SIMD2<Double>, in sketch: Sketch) -> Bool {
        let control = SketchHitTester.nearestControlPoint(
            to: raw, in: sketch.entities, tolerance: controlPointTolerance
        )
        let body = control == nil ? SketchHitTester.nearestEntity(
            to: raw, in: sketch.entities, tolerance: entityPickTolerance
        ) : nil
        guard let entity = control?.entity ?? body?.entity else { return false }
        if !selectedSketchEntityIDs.contains(entity.id) {
            selectedSketchEntityIDs = [entity.id]
        }
        sketchEntityDrag = SketchEntityDrag(
            sketchID: sketch.id,
            control: control?.kind,
            before: entity,
            grabPoint: raw,
            baseline: sketch.entities
        )
        sketchStrokeStart = nil
        pendingEntity = nil
        return true
    }

    private func updateSketchEntityDrag(raw: SIMD2<Double>) {
        guard var drag = sketchEntityDrag, let sketch = activeSketch else { return }

        // Solve-on-edit (plan §C1): when the sketch carries constraints or
        // dimensions, route a control-point drag through the solver so
        // constrained geometry holds and under-constrained geometry follows.
        // Body translates keep the direct path (the solver pins a single
        // point, which would deform rather than translate a whole entity).
        if drag.control != nil,
           !(sketch.constraints.isEmpty && sketch.dimensions.isEmpty) {
            updateSolvedSketchEntityDrag(&drag, raw: raw, sketch: sketch)
            return
        }

        let after: SketchEntity
        if let control = drag.control {
            // Snap against the rest of the sketch (not the dragged entity —
            // its own points would pin the handle in place).
            let others = Sketch(
                plane: sketch.plane,
                entities: sketch.entities.filter { $0.id != drag.before.id }
            )
            let point = SnapEngine.snap(raw, in: others).point
            after = SketchHitTester.applying(control, at: point, to: drag.before)
        } else {
            // Body translate: grid-capture each axis, like the extrude drag.
            var delta = raw - drag.grabPoint
            let snapped = SIMD2(
                (delta.x / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing,
                (delta.y / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing
            )
            if abs(delta.x - snapped.x) < 0.15 { delta.x = snapped.x }
            if abs(delta.y - snapped.y) < 0.15 { delta.y = snapped.y }
            after = SketchHitTester.translated(drag.before, by: delta)
        }
        let current = sketch.entities.first { $0.id == drag.before.id }
        guard after != current else { return }
        let command = UpdateSketchEntityCommand(
            sketchID: drag.sketchID, before: drag.before, after: after
        )
        if drag.pushed {
            session.amend(command)
        } else {
            session.perform(command)
            drag.pushed = true
            sketchEntityDrag = drag
        }
    }

    /// Solve-on-edit drag frame (plan §C1): pull the grabbed control point
    /// toward the drag target through the constraint solver, then coalesce the
    /// whole solved sketch into ONE amendable `UpdateSketchEntitiesCommand`.
    /// Fully-defined (zero-DOF) geometry refuses to move — the solve is a
    /// no-op and the geometry springs back to its baseline.
    private func updateSolvedSketchEntityDrag(
        _ drag: inout SketchEntityDrag, raw: SIMD2<Double>, sketch: Sketch
    ) {
        // Target for the grabbed point: snap against the OTHER entities (its own
        // points would pin the handle in place), matching the direct path.
        let others = Sketch(
            plane: sketch.plane,
            entities: drag.baseline.filter { $0.id != drag.before.id }
        )
        let target = SnapEngine.snap(raw, in: others).point

        // Always solve from the fixed pre-drag baseline so the target is
        // absolute and the result is deterministic across frames.
        var baselineSketch = sketch
        baselineSketch.entities = drag.baseline
        let (solved, dof) = SketchSolverBridge.solve(
            baselineSketch, movingEntity: drag.before.id, dragTarget: target
        )

        // Rigid sketch: refuse to move (no-op / spring back to baseline).
        guard dof > 0 else { return }
        guard solved != drag.baseline || drag.pushed else { return }

        let command = UpdateSketchEntitiesCommand(
            sketchID: drag.sketchID, before: drag.baseline, after: solved
        )
        if drag.pushed {
            session.amend(command)
        } else {
            session.perform(command)
            drag.pushed = true
        }
        sketchEntityDrag = drag
    }

    /// Polygon tool: number of sides for the next placement (NumericInputBar).
    var polygonSides: Int = 6

    /// Arc awaiting bulge adjustment: the chord drag placed the endpoints, a
    /// follow-up drag on the arc's midpoint adjusts the sagitta. Committed on
    /// the next tool action / tap elsewhere.
    struct PendingArc {
        let id = UUID()
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var sagitta: Double
    }
    var pendingArc: PendingArc?
    private var adjustingArcBulge = false

    var pendingArcEntity: SketchEntity? {
        guard let arc = pendingArc else { return nil }
        return Self.arcEntity(id: arc.id, a: arc.a, b: arc.b, sagitta: arc.sagitta)
    }

    /// Line chaining: the endpoint of the last committed line; the next line
    /// stroke starting within snap tolerance pre-anchors exactly there.
    private var chainAnchor: SIMD2<Double>?
    /// First point of the chain — a stroke closing onto it ends the chain.
    private var chainStart: SIMD2<Double>?

    private func clearChain() {
        chainAnchor = nil
        chainStart = nil
    }

    /// The active sketch while in sketching mode.
    var activeSketch: Sketch? {
        guard case .sketching(let id, _) = mode else { return nil }
        return session.document.sketches.first { $0.id == id }
    }

    /// Definition state of the active sketch for the status chip (plan §C4):
    /// remaining structural DOF and whether the sketch is fully defined
    /// (0 DOF). `nil` when not sketching or the sketch has no geometry yet.
    var sketchDefinitionStatus: (dof: Int, fullyDefined: Bool)? {
        guard let sketch = activeSketch, !sketch.entities.isEmpty else { return nil }
        let (_, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)
        return (dof, dof == 0)
    }

    func startSketch(tool: SketchTool) {
        if case .sketching(let id, _) = mode {
            commitPendingArc()
            clearChain()
            mode = .sketching(id, tool: tool) // just switch tools
            return
        }
        cancelTransientPicks()
        selectedImageID = nil
        // Sketch-on-face: a selected planar face IS the sketch plane
        // (spec §2.3); read it before cancelTool clears the context.
        if case .faceSelected = mode, let plane = toolContext?.plane {
            cancelTool()
            selection.removeAll()
            beginSketch(on: plane, tool: tool)
            return
        }
        cancelTool()
        selection.removeAll()
        // No plane yet: show the origin plane tiles. Tapping one — or a
        // planar face, a construction plane, or the bare ground — starts
        // the sketch there.
        mode = .pickingSketchPlane(tool: tool)
    }

    func cancelPlanePicking() {
        if case .pickingSketchPlane = mode {
            mode = .idle
        }
    }

    /// Tap routing while the plane tiles are up.
    private func handlePlanePick(ray: Ray, tool: SketchTool) {
        let tiles = PlanePicking.worldTiles + constructionPlaneTiles
        let tileHit = PlanePicking.pick(ray: ray, tiles: tiles)
        let bodyHit = HitTester.pickBody(ray: ray, in: scene)

        if let tileHit, bodyHit == nil || tileHit.distance <= bodyHit!.distance + 1e-3 {
            beginSketch(on: tileHit.tile.plane, tool: tool)
            return
        }
        if let bodyHit, let plane = worldFacePlane(bodyID: bodyHit.bodyID, triangleIndex: bodyHit.triangleIndex) {
            beginSketch(on: plane, tool: tool)
            return
        }
        // Ground fallback: tapping the bare grid sketches on the ground plane.
        if ray.intersect(planePoint: .zero, planeNormal: SIMD3(0, 1, 0)) != nil {
            beginSketch(on: .ground, tool: tool)
            return
        }
        mode = .idle
    }

    /// A body's tapped planar face as a world-space sketch plane.
    private func worldFacePlane(bodyID: BodyID, triangleIndex: Int) -> SketchPlane? {
        guard let body = session.document.body(with: bodyID),
              let face = FaceTopology.planarFace(in: body.render, seedTriangle: triangleIndex)
        else { return nil }
        let transform = body.transform
        return SketchPlane(
            origin: transform.applying(to: face.origin),
            xAxis: transform.rotation.act(face.basisX),
            yAxis: transform.rotation.act(face.basisY)
        )
    }

    /// Find-or-create the sketch for a plane (same geometric plane → same
    /// sketch item, Shapr3D's rule) and enter sketching head-on.
    private func beginSketch(on plane: SketchPlane, tool: SketchTool) {
        let sketch: Sketch
        if let existing = session.document.sketches.first(where: {
            $0.plane.isCoincident(with: plane)
        }) {
            sketch = existing
            // Re-opening a sketch that an extrude auto-hid makes it visible
            // again, so its profiles stay tappable after Exit Sketching.
            if existing.isHidden {
                session.preview { doc in
                    if let i = doc.sketches.firstIndex(where: { $0.id == existing.id }) {
                        doc.sketches[i].isHidden = false
                    }
                }
            }
        } else {
            let created = Sketch(name: session.document.uniqueSketchName(), plane: plane)
            session.preview { $0.sketches.append(created) }
            sketch = created
        }
        mode = .sketching(sketch.id, tool: tool)
        cameraControl?.moveCameraHeadOn(to: sketch.plane)
    }

    func finishSketch() {
        commitPendingArc()
        clearChain()
        textPlacement = nil
        pendingSymbolID = nil
        pendingEntity = nil
        sketchStrokeStart = nil
        activeGuides = []
        pendingInferredConstraints = []
        adjustingArcBulge = false
        sketchEntityDrag = nil
        sketchGizmoDrag = nil
        sketchCopyOnDrag = false
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
        selectedConstraintID = nil
        selectedDimensionID = nil
        if case .sketching(let sketchID, _) = mode {
            // Phase D (belt-and-suspenders): rebuild dependent features on the
            // way out of the sketch, so any edit not caught at its own commit
            // boundary still propagates. No-op when nothing references it.
            session.rebuildForSketchChange(sketchID)
            mode = .idle
        }
        session.save()
    }

    /// Ray → unsnapped plane-local point, while sketching.
    private func rawSketchPoint(from ray: Ray) -> SIMD2<Double>? {
        guard let sketch = activeSketch else { return nil }
        let plane = sketch.plane
        let planePoint = SIMD3<Float>(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z))
        let normal = plane.normal
        let planeNormal = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
        guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else {
            return nil
        }
        let world = ray.point(at: t)
        return plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }

    /// Ray → snapped plane-local point, while sketching.
    private func sketchPoint(from ray: Ray) -> SIMD2<Double>? {
        guard let raw = rawSketchPoint(from: ray) else { return nil }
        return SnapEngine.snap(raw, in: activeSketch).point
    }

    func beginSketchStroke(ray: Ray) -> Bool {
        guard case .sketching(_, let tool) = mode,
              let raw = rawSketchPoint(from: ray)
        else { return false }
        sketchEntityDrag = nil
        if tool == .trim || tool == .text || tool == .project {
            return false // These tools work by taps; unclaimed drags orbit.
        }
        if pendingSymbolID != nil {
            return false // Insert Symbol places by taps; drags orbit.
        }

        // A drag starting on the pending arc's midpoint adjusts its bulge.
        if tool == .arc, let arc = pendingArc,
           simd_length(raw - Self.arcBulgePoint(of: arc)) <= SnapEngine.pointTolerance {
            adjustingArcBulge = true
            sketchStrokeStart = nil
            pendingEntity = nil
            return true
        }
        commitPendingArc()

        // Selection gizmo first: drags on the handle/ring transform the
        // selected entities instead of drawing or editing.
        if beginSketchGizmoDrag(at: raw) {
            return true
        }

        // Chain continuation stays a drawing gesture even though it starts
        // on the previous line's endpoint.
        let chainContinues = tool == .line && chainAnchor != nil
            && simd_length(raw - chainAnchor!) <= SnapEngine.pointTolerance

        // A drag starting on an entity edits it (select + move); only
        // strokes that start on empty space draw new geometry.
        if !chainContinues, let sketch = activeSketch,
           beginSketchEntityDrag(at: raw, in: sketch) {
            return true
        }

        var point = SnapEngine.snap(raw, in: activeSketch).point
        if tool == .line, let anchor = chainAnchor {
            if simd_length(raw - anchor) <= SnapEngine.pointTolerance {
                point = anchor // continue the chain exactly at the last endpoint
            } else {
                clearChain()
            }
        }
        sketchStrokeStart = point
        pendingEntity = nil
        return true
    }

    func updateSketchStroke(ray: Ray) {
        guard case .sketching(_, let tool) = mode else { return }
        if adjustingArcBulge {
            guard var arc = pendingArc, let raw = rawSketchPoint(from: ray) else { return }
            arc.sagitta = Self.clampedSagitta(Self.signedSagitta(of: raw, arc: arc), arc: arc)
            pendingArc = arc
            return
        }
        if sketchGizmoDrag != nil {
            guard let raw = rawSketchPoint(from: ray) else { return }
            updateSketchGizmoDrag(raw: raw)
            return
        }
        if sketchEntityDrag != nil {
            guard let raw = rawSketchPoint(from: ray) else { return }
            updateSketchEntityDrag(raw: raw)
            return
        }
        guard let start = sketchStrokeStart,
              var current = sketchPoint(from: ray)
        else { return }
        // Live auto-constraint inference (plan §B): snap the moving endpoint,
        // collect the guides to render, and stash the constraints to emit if
        // the stroke commits. `existing` = committed entities (the in-progress
        // entity is `pendingEntity`, not yet in the sketch).
        if autoConstrainSettings.enabled, let sketch = activeSketch {
            let result = AutoConstraintEngine.infer(
                tool: tool, anchor: start, current: current,
                existing: sketch.entities, settings: autoConstrainSettings
            )
            current = result.snappedPoint
            activeGuides = result.guides
            pendingInferredConstraints = result.constraints
        } else {
            activeGuides = []
            pendingInferredConstraints = []
        }
        pendingEntity = makeEntity(tool: tool, from: start, to: current)
    }

    func endSketchStroke(ray: Ray) {
        defer {
            pendingEntity = nil
            sketchStrokeStart = nil
            activeGuides = []
            pendingInferredConstraints = []
        }
        if adjustingArcBulge {
            adjustingArcBulge = false
            return
        }
        if sketchGizmoDrag != nil {
            sketchGizmoDrag = nil // commands already pushed/amended live
            return
        }
        if let drag = sketchEntityDrag {
            // Drop-to-weld (plan §B): releasing a control point onto a nearby
            // point adds an explicit coincident (its own undo step, guarded).
            maybeAddDragCoincident(drag)
            sketchEntityDrag = nil // move command already pushed/amended live
            // Phase D: an entity move reshapes any profile a feature reads —
            // rebuild dependent features at the drag-commit boundary (cheap when
            // nothing downstream references this sketch).
            session.rebuildForSketchChange(drag.sketchID)
            return
        }
        guard case .sketching(let sketchID, let tool) = mode,
              let start = sketchStrokeStart,
              let sketch = activeSketch
        else { return }
        var end = sketchPoint(from: ray) ?? start
        // Re-run inference at the release point so the committed geometry and
        // the emitted constraints stay consistent with the on-screen preview.
        if autoConstrainSettings.enabled {
            let result = AutoConstraintEngine.infer(
                tool: tool, anchor: start, current: end,
                existing: sketch.entities, settings: autoConstrainSettings
            )
            end = result.snappedPoint
            pendingInferredConstraints = result.constraints
        }
        guard let entity = makeEntity(tool: tool, from: start, to: end) else { return }
        if tool == .arc {
            // Held as pending so a follow-up drag can adjust the bulge.
            pendingArc = PendingArc(a: start, b: end, sagitta: Self.defaultSagitta(a: start, b: end))
            return
        }
        // Fold any auto-inferred constraints into the SAME undo step as the
        // entity add (plan §B); each survivor is checked so it never
        // over-constrains, then the accepted set is solved so geometry settles.
        let addEntity = AddSketchEntityCommand(sketchID: sketchID, entity: entity)
        let constraintCommands = inferredConstraintCommands(
            for: entity, sketchID: sketchID, in: sketch
        )
        if constraintCommands.isEmpty {
            session.perform(addEntity)
        } else {
            var commands: [DocumentCommand] = [addEntity]
            commands.append(contentsOf: constraintCommands)
            session.perform(CompositeCommand(title: "Draw", commands: commands))
        }
        if tool == .line {
            let first = chainStart ?? start
            if simd_length(end - first) <= 1e-9 {
                clearChain() // stroke closed onto the chain start
            } else {
                chainStart = first
                chainAnchor = end
            }
        }
    }

    /// Commits the pending arc (next tool action / tap elsewhere / exit).
    func commitPendingArc() {
        guard let arc = pendingArc else { return }
        pendingArc = nil
        adjustingArcBulge = false
        guard case .sketching(let sketchID, _) = mode,
              let entity = Self.arcEntity(id: arc.id, a: arc.a, b: arc.b, sagitta: arc.sagitta)
        else { return }
        session.perform(AddSketchEntityCommand(sketchID: sketchID, entity: entity))
    }

    // MARK: - Arc math (chord + sagitta → SketchEntity.arc)

    static func defaultSagitta(a: SIMD2<Double>, b: SIMD2<Double>) -> Double {
        simd_length(b - a) / 4
    }

    /// The point that drags the bulge: the arc midpoint (chord mid + sagitta
    /// along the chord's left normal).
    static func arcBulgePoint(of arc: PendingArc) -> SIMD2<Double> {
        let chord = arc.b - arc.a
        guard simd_length(chord) > 1e-9 else { return arc.a }
        let n = simd_normalize(SIMD2(-chord.y, chord.x))
        return (arc.a + arc.b) / 2 + n * arc.sagitta
    }

    /// Signed distance of `p` from the chord line (positive = left of a→b).
    static func signedSagitta(of p: SIMD2<Double>, arc: PendingArc) -> Double {
        let chord = arc.b - arc.a
        guard simd_length(chord) > 1e-9 else { return arc.sagitta }
        let n = simd_normalize(SIMD2(-chord.y, chord.x))
        return simd_dot(p - (arc.a + arc.b) / 2, n)
    }

    /// Keeps the sagitta away from zero so the arc never degenerates flat.
    static func clampedSagitta(_ s: Double, arc: PendingArc) -> Double {
        let minimum = max(simd_length(arc.b - arc.a) * 0.02, 1e-3)
        if abs(s) < minimum {
            return s < 0 ? -minimum : minimum
        }
        return s
    }

    /// Circular arc from endpoints + sagitta (perpendicular height of the arc
    /// midpoint over the chord midpoint; positive bulges left of a→b).
    static func arcEntity(
        id: UUID, a: SIMD2<Double>, b: SIMD2<Double>, sagitta: Double
    ) -> SketchEntity? {
        SketchHitTester.arcFromChord(id: id, a: a, b: b, sagitta: sagitta)
    }

    private func makeEntity(
        tool: SketchTool, from a: SIMD2<Double>, to b: SIMD2<Double>
    ) -> SketchEntity? {
        let minimum: Double = 1e-3
        switch tool {
        case .line:
            guard simd_length(b - a) > minimum else { return nil }
            return .line(id: UUID(), a: a, b: b)
        case .rect:
            guard abs(b.x - a.x) > minimum, abs(b.y - a.y) > minimum else { return nil }
            return .rect(
                id: UUID(),
                min: SIMD2(Swift.min(a.x, b.x), Swift.min(a.y, b.y)),
                max: SIMD2(Swift.max(a.x, b.x), Swift.max(a.y, b.y))
            )
        case .circle:
            let radius = simd_length(b - a)
            guard radius > minimum else { return nil }
            return .circle(id: UUID(), center: a, radius: radius)
        case .arc:
            return Self.arcEntity(
                id: UUID(), a: a, b: b, sagitta: Self.defaultSagitta(a: a, b: b)
            )
        case .ellipse:
            let radiusX = abs(b.x - a.x)
            let radiusY = abs(b.y - a.y)
            guard radiusX > minimum, radiusY > minimum else { return nil }
            return .ellipse(id: UUID(), center: a, radiusX: radiusX, radiusY: radiusY, rotation: 0)
        case .polygon:
            let delta = b - a
            let radius = simd_length(delta)
            guard radius > minimum else { return nil }
            return .polygon(
                id: UUID(), center: a, radius: radius,
                sides: max(3, polygonSides), rotation: atan2(delta.y, delta.x)
            )
        case .trim, .text, .project:
            return nil // These tools never rubber-band draw.
        }
    }

    // MARK: - Auto-constraint emission on commit (plan §B)

    /// Build the commands for the auto-inferred constraints of a freshly
    /// committed entity. Each candidate is accepted only if it does not
    /// over-constrain the sketch (residual guard, matching `applyConstraint`),
    /// then the accepted system is solved so under-defined geometry settles
    /// onto the inferred relationships. Returns `[]` when nothing survives.
    private func inferredConstraintCommands(
        for entity: SketchEntity, sketchID: SketchID, in sketch: Sketch
    ) -> [DocumentCommand] {
        guard !pendingInferredConstraints.isEmpty else { return [] }
        // Proposed sketch = committed sketch + the new entity; candidates are
        // added one at a time so each is validated against the accumulated set.
        var proposed = sketch
        proposed.entities.append(entity)
        var accepted: [SketchConstraint] = []
        for inferred in pendingInferredConstraints {
            let refs = inferredRefs(inferred, newEntityID: entity.id)
            guard !refs.isEmpty else { continue }
            let constraint = SketchConstraint(kind: inferred.kind, refs: refs)
            var trial = proposed
            trial.constraints.append(constraint)
            if SketchSolverBridge.residualNorm(trial) > Self.overConstraintTolerance {
                continue // would conflict — skip defensively
            }
            proposed = trial
            accepted.append(constraint)
        }
        guard !accepted.isEmpty else { return [] }
        var commands: [DocumentCommand] = accepted.map {
            AddSketchConstraintCommand(sketchID: sketchID, constraint: $0)
        }
        // Solve the accepted system so geometry settles; emit an update for
        // each moved entity (the new entity included — it is appended last).
        let (solved, _) = SketchSolverBridge.solve(proposed, movingEntity: nil, dragTarget: nil)
        for (before, after) in zip(proposed.entities, solved) where before != after {
            commands.append(UpdateSketchEntityCommand(
                sketchID: sketchID, before: before, after: after
            ))
        }
        return commands
    }

    /// Resolve an inferred relationship to concrete constraint refs: `selfRole`
    /// addresses the NEW entity; a non-nil target addresses an existing entity.
    /// A nil target is a pure axis constraint (horizontal / vertical).
    private func inferredRefs(
        _ inferred: AutoConstraintEngine.Inferred, newEntityID: UUID
    ) -> [ConstraintRef] {
        let selfRef = ConstraintRef(entityID: newEntityID, role: inferred.selfRole)
        if let targetID = inferred.targetEntityID {
            return [selfRef, ConstraintRef(entityID: targetID, role: inferred.targetRole ?? .whole)]
        }
        return [selfRef]
    }

    /// On releasing a control-point drag, weld it to a nearby point with an
    /// explicit coincident constraint (plan §B) — its own undo step, guarded
    /// against over-constraint, and skipped when already coincident.
    private func maybeAddDragCoincident(_ drag: SketchEntityDrag) {
        guard let control = drag.control,
              let role = Self.pointRole(for: control),
              case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let dragged = sketch.entities.first(where: { $0.id == drag.before.id }),
              let point = SketchHitTester.modelPoints(of: dragged)
                  .first(where: { $0.role == role })?.point
        else { return }
        // Nearest point on any OTHER entity, within snap tolerance.
        let others = sketch.entities.filter { $0.id != dragged.id }
        guard let hit = SketchHitTester.nearestPoint(
            to: point, in: others, tolerance: SnapEngine.pointTolerance
        ) else { return }
        let a = SketchPointSelection(entityID: dragged.id, role: role)
        let b = SketchPointSelection(entityID: hit.entityID, role: hit.role)
        // Skip if these two points are already welded by a coincident.
        if sketch.constraints.contains(where: { Self.isCoincidentBetween($0, a, b) }) { return }
        // Skip if they were already a shared joint BEFORE the drag — welded by
        // proximity (e.g. an existing rectangle corner) rather than an explicit
        // constraint. Drop-to-weld only links points the drag brought together
        // from genuinely separate locations, never a point to its own
        // already-coincident neighbour.
        if let bd = Self.baselinePoint(drag.baseline, a),
           let bh = Self.baselinePoint(drag.baseline, b) {
            let d = bd - bh
            if d.x * d.x + d.y * d.y < 1e-12 { return }
        }
        let constraint = SketchConstraint(kind: .coincident, refs: [
            ConstraintRef(entityID: a.entityID, role: a.role),
            ConstraintRef(entityID: b.entityID, role: b.role),
        ])
        var proposed = sketch
        proposed.constraints.append(constraint)
        if SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance { return }
        session.perform(AddSketchConstraintCommand(sketchID: sketchID, constraint: constraint))
        session.save()
    }

    /// The solver `PointRole` a draggable control point maps to, or nil for
    /// handles the solver treats as derived (rim / radius / arc endpoints /
    /// off-diagonal rect corners) that carry no coincident-addressable point.
    private static func pointRole(for control: SketchHitTester.ControlKind) -> PointRole? {
        switch control {
        case .lineStart: return .endpointA
        case .lineEnd: return .endpointB
        case .center: return .center
        case .rectCorner(0): return .endpointA
        case .rectCorner(2): return .endpointB
        default: return nil
        }
    }

    /// The plane-local coordinate of `sel` in a pre-drag baseline snapshot.
    private static func baselinePoint(
        _ baseline: [SketchEntity], _ sel: SketchPointSelection
    ) -> SIMD2<Double>? {
        guard let e = baseline.first(where: { $0.id == sel.entityID }) else { return nil }
        return SketchHitTester.modelPoints(of: e).first { $0.role == sel.role }?.point
    }

    /// True when `c` is a coincident constraint welding exactly points `a`↔`b`.
    private static func isCoincidentBetween(
        _ c: SketchConstraint, _ a: SketchPointSelection, _ b: SketchPointSelection
    ) -> Bool {
        guard c.kind == .coincident, c.refs.count == 2 else { return false }
        let refA = SketchPointSelection(entityID: c.refs[0].entityID, role: c.refs[0].role)
        let refB = SketchPointSelection(entityID: c.refs[1].entityID, role: c.refs[1].role)
        return (refA == a && refB == b) || (refA == b && refB == a)
    }

    // MARK: - Text tool (plan §B7, spec §1.12 v1)

    /// Plane-local baseline point for the pending text placement; non-nil
    /// presents the text dialog (set by a tap with the Text tool active).
    var textPlacement: SIMD2<Double>?

    /// Commit from the text dialog: glyph outlines as one undo step. The
    /// resulting closed loops are ordinary sketch entities, so their profiles
    /// fill and extrude like any other.
    func commitText(content: String, height: Double, fontName: String?) {
        guard case .sketching(let sketchID, _) = mode else {
            textPlacement = nil
            return
        }
        let origin = textPlacement ?? .zero
        textPlacement = nil
        let entities = TextSketch.glyphEntities(
            text: content, fontName: fontName, height: height, at: origin
        )
        guard !entities.isEmpty else {
            errorMessage = "No outlines for that text — try different content or a larger height."
            return
        }
        session.perform(CompositeCommand(
            title: "Text",
            commands: [AddSketchEntitiesCommand(
                sketchID: sketchID, entities: entities, title: "Text"
            )]
        ))
    }

    // MARK: - Project (plan §B8, spec §1.13 v1: unlinked body → sketch plane)

    /// Project-tool tap: flatten the tapped body's feature edges onto the
    /// active sketch plane as regular line entities (one undo step, so they
    /// participate in profiles for the CNC flat-layout workflow).
    private func projectTappedBody(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let hit = HitTester.pickBody(ray: ray, in: scene),
              let body = session.document.body(with: hit.bodyID)
        else { return }
        let entities = ProjectionKit.project(body: body, onto: sketch.plane)
        guard !entities.isEmpty else {
            errorMessage = "Nothing to project — the body has no edges to flatten onto this plane."
            return
        }
        session.perform(CompositeCommand(
            title: "Project",
            commands: [AddSketchEntitiesCommand(
                sketchID: sketchID, entities: entities, title: "Project"
            )]
        ))
    }

    // MARK: - Symbols (plan §B16, spec §1.16)

    /// Presents the Make Symbol name prompt (palette button; alert lives in
    /// EditorView).
    var showMakeSymbolPrompt = false

    /// Armed Insert Symbol: while non-nil, each sketch tap stamps an instance
    /// of this symbol at the tapped plane point until Done/Esc exits.
    var pendingSymbolID: SymbolID?

    var pendingSymbol: Symbol? {
        guard let id = pendingSymbolID else { return nil }
        return session.document.symbols.first { $0.id == id }
    }

    var canMakeSymbol: Bool {
        mode.isSketching && !selectedSketchEntityIDs.isEmpty
    }

    /// Capture the selected sketch entities as a named reusable symbol
    /// (SymbolKit normalizes them about their centroid; one undo step).
    func makeSymbol(named name: String) {
        guard let sketch = activeSketch else { return }
        let entities = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        guard !entities.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = SymbolKit.capture(
            name: trimmed.isEmpty ? session.document.uniqueSymbolName() : trimmed,
            entities: entities
        )
        session.perform(AddSymbolCommand(symbol: symbol))
    }

    /// Arm tap-to-place for the symbol (sketching only).
    func beginInsertSymbol(_ id: SymbolID) {
        guard mode.isSketching else { return }
        clearChain()
        pendingEntity = nil
        selectedSketchEntityIDs.removeAll()
        pendingSymbolID = id
    }

    func cancelInsertSymbol() {
        pendingSymbolID = nil
    }

    /// Armed tap: stamp one instance at the tapped (snapped) plane point —
    /// fresh IDs, one undoable command per placement.
    private func placePendingSymbol(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let symbol = pendingSymbol,
              let point = sketchPoint(from: ray)
        else { return }
        session.perform(AddSketchEntitiesCommand(
            sketchID: sketchID,
            entities: SymbolKit.instantiate(symbol, at: point),
            title: "Insert Symbol"
        ))
    }

    /// Items panel rename (no-ops on empty/unchanged names, like items).
    func renameSymbol(_ id: SymbolID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let command = RenameSymbolCommand(id: id, to: trimmed, document: session.document),
              command.before != trimmed
        else { return }
        session.perform(command)
    }

    /// Items panel delete (undoable; disarms a pending placement of it).
    func deleteSymbol(_ id: SymbolID) {
        if pendingSymbolID == id { pendingSymbolID = nil }
        guard let command = RemoveSymbolCommand(id: id, document: session.document) else { return }
        session.perform(command)
    }

    // MARK: - Sketch constraints (plan §C3, spec §3.2)

    /// Residual-norm ceiling above which a proposed constraint/dimension is
    /// treated as conflicting (over-constrained) and refused. Geometry is in
    /// millimetres, so an unsatisfiable residual is order-of-magnitude the
    /// geometry size; anything above this fine tolerance is a genuine conflict.
    nonisolated static let overConstraintTolerance = 1e-3

    /// Selected sketch entities of the given kind (helpers for the adaptive
    /// constraint menu). Lines feed direction constraints; circle/arc/polygon
    /// (entities the solver gives a radius variable) feed concentric/radius/
    /// tangent.
    private var selectedSketchEntities: [SketchEntity] {
        guard let sketch = activeSketch else { return [] }
        return sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
    }

    private var selectedLineEntities: [SketchEntity] {
        selectedSketchEntities.filter { if case .line = $0 { return true }; return false }
    }

    private var selectedRadiusEntities: [SketchEntity] {
        selectedSketchEntities.filter {
            switch $0 {
            case .circle, .arc, .polygon: return true
            default: return false
            }
        }
    }

    /// Adaptive enablement (Shapr3D rule, spec §3.2): a constraint is offered
    /// only when the current selection supports it.
    func canApplyConstraint(_ kind: SketchConstraintKind) -> Bool {
        guard mode.isSketching else { return false }
        let points = selectedSketchPoints.count
        let lines = selectedLineEntities.count
        let circles = selectedRadiusEntities.count
        switch kind {
        case .coincident:
            // Two points, or two lines that share an approximate corner.
            return points >= 2 || (lines == 2 && nearestEndpointPair(selectedLineEntities) != nil)
        case .horizontal, .vertical:
            return lines >= 1 || points == 2
        case .parallel, .perpendicular, .equalLength:
            return lines == 2
        case .equalRadius, .concentric:
            return circles == 2
        case .tangent:
            return lines == 1 && circles == 1
        case .midpoint:
            return points == 1 && lines == 1
        case .symmetric:
            return points == 2 && lines == 1
        case .fixed:
            return points >= 1 || !selectedSketchEntityIDs.isEmpty
        case .colinear:
            return lines == 2
        }
    }

    /// Apply `kind` to the current selection: build a `SketchConstraint` from
    /// the selected points/entities, append it, re-solve the sketch, and commit
    /// the constraint + any solver-moved geometry in ONE undoable command.
    func applyConstraint(_ kind: SketchConstraintKind) {
        guard canApplyConstraint(kind),
              case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let refs = constraintRefs(for: kind, in: sketch)
        else { return }

        let constraint = SketchConstraint(kind: kind, refs: refs)

        // Solve the sketch with the new constraint in place; the bridge welds
        // coincident points and pulls under-defined geometry to satisfy it.
        var proposed = sketch
        proposed.constraints.append(constraint)

        // Over-constraint guard (spec §2.2): if the added constraint makes the
        // system unsatisfiable (conflicting), refuse it — never corrupt the
        // sketch. `.fixed` (Lock) only pins existing positions, so it can never
        // conflict and is exempt.
        if kind != .fixed,
           SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance {
            errorMessage = "\(Self.constraintTitle(kind)) conflicts with the existing constraints — not added."
            return
        }

        let (solvedEntities, _) = SketchSolverBridge.solve(
            proposed, movingEntity: nil, dragTarget: nil
        )

        var commands: [DocumentCommand] = [
            AddSketchConstraintCommand(sketchID: sketchID, constraint: constraint)
        ]
        for (before, after) in zip(sketch.entities, solvedEntities) where before != after {
            commands.append(UpdateSketchEntityCommand(
                sketchID: sketchID, before: before, after: after
            ))
        }
        let title = Self.constraintTitle(kind)
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: title, commands: commands))
        // Phase D: a constraint can re-solve entity positions — rebuild
        // dependent features.
        session.rebuildForSketchChange(sketchID)
        session.save()
    }

    static func constraintTitle(_ kind: SketchConstraintKind) -> String {
        switch kind {
        case .coincident: "Coincident"
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        case .parallel: "Parallel"
        case .perpendicular: "Perpendicular"
        case .equalLength: "Equal Length"
        case .equalRadius: "Equal Radius"
        case .concentric: "Concentric"
        case .midpoint: "Midpoint"
        case .symmetric: "Symmetric"
        case .tangent: "Tangent"
        case .colinear: "Colinear"
        case .fixed: "Lock"
        }
    }

    /// Map the selection to the ref layout each constraint kind expects
    /// (documented in `SketchSolverBridge`). Returns nil when the selection
    /// does not form the operands for `kind`.
    private func constraintRefs(
        for kind: SketchConstraintKind, in sketch: Sketch
    ) -> [ConstraintRef]? {
        let pts = Array(selectedSketchPoints)
        let lines = selectedLineEntities
        let circles = selectedRadiusEntities
        func ref(_ p: SketchPointSelection) -> ConstraintRef {
            ConstraintRef(entityID: p.entityID, role: p.role)
        }
        func whole(_ e: SketchEntity) -> ConstraintRef {
            ConstraintRef(entityID: e.id, role: .whole)
        }
        switch kind {
        case .coincident:
            if pts.count >= 2 { return [ref(pts[0]), ref(pts[1])] }
            return nearestEndpointPair(lines)
        case .horizontal, .vertical:
            if let line = lines.first { return [whole(line)] }
            if pts.count == 2 { return [ref(pts[0]), ref(pts[1])] }
            return nil
        case .parallel, .perpendicular, .equalLength, .colinear:
            guard lines.count == 2 else { return nil }
            return [whole(lines[0]), whole(lines[1])]
        case .equalRadius, .concentric:
            guard circles.count == 2 else { return nil }
            return [
                ConstraintRef(entityID: circles[0].id, role: .center),
                ConstraintRef(entityID: circles[1].id, role: .center),
            ]
        case .tangent:
            guard let line = lines.first, let circle = circles.first else { return nil }
            return [whole(line), whole(circle)]
        case .midpoint:
            guard pts.count == 1, let line = lines.first else { return nil }
            return [ref(pts[0]), whole(line)]
        case .symmetric:
            guard pts.count == 2, let line = lines.first else { return nil }
            return [ref(pts[0]), ref(pts[1]), whole(line)]
        case .fixed:
            var refs = pts.map(ref)
            let pointed = Set(pts.map(\.entityID))
            for e in selectedSketchEntities where !pointed.contains(e.id) {
                refs.append(whole(e))
            }
            return refs.isEmpty ? nil : refs
        }
    }

    /// The closest endpoint pair between two lines, as coincident refs — lets
    /// Coincident weld a shared corner when whole lines are selected.
    private func nearestEndpointPair(_ lines: [SketchEntity]) -> [ConstraintRef]? {
        guard lines.count == 2,
              case let .line(id0, a0, b0) = lines[0],
              case let .line(id1, a1, b1) = lines[1]
        else { return nil }
        let candidates: [(PointRole, PointRole, Double)] = [
            (.endpointA, .endpointA, simd_distance(a0, a1)),
            (.endpointA, .endpointB, simd_distance(a0, b1)),
            (.endpointB, .endpointA, simd_distance(b0, a1)),
            (.endpointB, .endpointB, simd_distance(b0, b1)),
        ]
        guard let best = candidates.min(by: { $0.2 < $1.2 }) else { return nil }
        return [
            ConstraintRef(entityID: id0, role: best.0),
            ConstraintRef(entityID: id1, role: best.1),
        ]
    }

    // MARK: - Constraint glyphs + delete (plan §C3)

    /// A constraint's on-canvas glyph: a short code badge at the relationship's
    /// location. World-space anchor so the overlay reprojects each camera move;
    /// `slot` fans out glyphs that share an anchor so each stays tappable.
    struct SketchConstraintGlyph: Identifiable {
        let id: UUID           // the constraint's id
        let kind: SketchConstraintKind
        let code: String
        let worldAnchor: SIMD3<Double>
        let slot: Int
    }

    /// Compact badge text per constraint kind.
    static func constraintCode(_ kind: SketchConstraintKind) -> String {
        switch kind {
        case .coincident: "⌖"
        case .horizontal: "H"
        case .vertical: "V"
        case .parallel: "∥"
        case .perpendicular: "⊥"
        case .equalLength: "="
        case .equalRadius: "=R"
        case .concentric: "◎"
        case .midpoint: "M"
        case .symmetric: "⧓"
        case .tangent: "T"
        case .colinear: "L"
        case .fixed: "🔒"
        }
    }

    /// Local-plane anchor of a constraint: the average of its operands' points
    /// (whole-line operands contribute their midpoint via `localPoint`).
    private func constraintAnchorLocal(_ c: SketchConstraint, in sketch: Sketch) -> SIMD2<Double>? {
        var sum = SIMD2<Double>(0, 0)
        var n = 0
        for ref in c.refs {
            if let p = localPoint(ref, in: sketch) { sum += p; n += 1 }
        }
        guard n > 0 else { return nil }
        return sum / Double(n)
    }

    /// Constraint glyphs to render in the sketch overlay.
    var sketchConstraintGlyphs: [SketchConstraintGlyph] {
        _ = session.changeCount
        guard let sketch = activeSketch else { return [] }
        var out: [SketchConstraintGlyph] = []
        var slotAt: [String: Int] = [:] // stack glyphs sharing an anchor
        for c in sketch.constraints {
            guard let local = constraintAnchorLocal(c, in: sketch) else { continue }
            let key = "\((local.x * 100).rounded())-\((local.y * 100).rounded())"
            let slot = slotAt[key, default: 0]
            slotAt[key] = slot + 1
            out.append(SketchConstraintGlyph(
                id: c.id, kind: c.kind, code: Self.constraintCode(c.kind),
                worldAnchor: sketch.plane.toWorld(local), slot: slot
            ))
        }
        return out
    }

    /// True when a constraint or dimension glyph is selected (enables Delete).
    var hasSketchGlyphSelection: Bool {
        selectedConstraintID != nil || selectedDimensionID != nil
    }

    /// Tap-select a constraint glyph (clears geometry + dimension selection).
    func selectConstraint(_ id: UUID) {
        selectedConstraintID = (selectedConstraintID == id) ? nil : id
        selectedDimensionID = nil
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
    }

    /// Select a dimension (from the Items panel) for delete.
    func selectDimension(_ id: UUID) {
        selectedDimensionID = (selectedDimensionID == id) ? nil : id
        selectedConstraintID = nil
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
    }

    /// Remove a constraint (undoable) and re-solve the relaxed sketch so any
    /// geometry it was holding settles.
    func deleteConstraint(_ id: UUID) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let index = sketch.constraints.firstIndex(where: { $0.id == id }) else { return }
        let constraint = sketch.constraints[index]
        if selectedConstraintID == id { selectedConstraintID = nil }
        session.perform(RemoveSketchConstraintCommand(
            sketchID: sketchID, constraint: constraint, index: index
        ))
        session.save()
    }

    /// Delete the currently selected constraint glyph (contract D): palette /
    /// keyboard Delete route here. `deleteConstraint` clears the selection and
    /// re-solves the relaxed sketch.
    func deleteSelectedConstraint() {
        guard let id = selectedConstraintID else { return }
        deleteConstraint(id)
    }

    // MARK: - Sketch mirror (plan §B, contract D)

    /// The single selected `.line` that can serve as a mirror axis plus the
    /// other selected entities to reflect across it, or nil when the selection
    /// has no unambiguous axis (zero or ≥2 lines) or nothing to mirror.
    private var sketchMirrorAxisAndSources: (axis: UUID, sources: [UUID])? {
        guard mode.isSketching, let sketch = activeSketch else { return nil }
        let selected = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        let lines = selected.filter { if case .line = $0 { return true } else { return false } }
        guard lines.count == 1 else { return nil } // need exactly one axis line
        let axis = lines[0].id
        let sources = selected.map(\.id).filter { $0 != axis }
        guard !sources.isEmpty else { return nil }  // need something to mirror
        return (axis, sources)
    }

    /// True when the sketch selection has a single line axis and ≥1 other
    /// entity to mirror across it (contract D).
    var canMirrorSketchSelection: Bool { sketchMirrorAxisAndSources != nil }

    /// Mirror the selected entities across the single selected line, linking
    /// each original point to its mirror with a `.symmetric` constraint
    /// (contract D). One undoable `MirrorSketchEntitiesCommand`.
    func mirrorSketchSelection() {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let sel = sketchMirrorAxisAndSources,
              let command = MirrorSketchEntitiesCommand(
                  sketchID: sketchID, sourceEntityIDs: sel.sources,
                  axisEntityID: sel.axis, sketch: sketch
              )
        else { return }
        session.perform(command)
        session.save()
    }

    /// Remove a dimension (undoable).
    func deleteDimension(_ id: UUID) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let index = sketch.dimensions.firstIndex(where: { $0.id == id }) else { return }
        let dimension = sketch.dimensions[index]
        if selectedDimensionID == id { selectedDimensionID = nil }
        session.perform(RemoveSketchDimensionCommand(
            sketchID: sketchID, dimension: dimension, index: index
        ))
        session.save()
    }

    /// Items-panel rows for the active sketch's constraints.
    var activeSketchConstraintRows: [(id: UUID, code: String, title: String)] {
        _ = session.changeCount
        guard let sketch = activeSketch else { return [] }
        return sketch.constraints.map {
            (id: $0.id, code: Self.constraintCode($0.kind), title: Self.constraintTitle($0.kind))
        }
    }

    /// Items-panel rows for the active sketch's dimensions.
    var activeSketchDimensionRows: [(id: UUID, code: String, title: String)] {
        _ = session.changeCount
        guard let sketch = activeSketch else { return [] }
        return sketch.dimensions.map { d in
            let title: String
            switch d.kind {
            case .distance: title = "Distance " + String(format: "%.2f mm", d.value)
            case .radius: title = "Radius " + String(format: "%.2f mm", d.value)
            case .diameter: title = "Diameter " + String(format: "%.2f mm", d.value)
            case .angle: title = "Angle " + String(format: "%.1f°", d.value * 180 / .pi)
            }
            let code: String
            switch d.kind {
            case .distance: code = "↔"
            case .radius: code = "R"
            case .diameter: code = "⌀"
            case .angle: code = "∠"
            }
            return (id: d.id, code: code, title: title)
        }
    }

    // MARK: - Sketch dimensions (plan §C2, spec §2.2)

    /// A dimension label to draw in the sketch overlay: a driving dimension, or
    /// the live candidate for the current selection (`dimensionID == nil`).
    /// Positions are WORLD-space so the overlay reprojects them each camera move.
    struct SketchDimensionLabel: Identifiable {
        let id: String
        let dimensionID: UUID?
        let kind: DimensionKind
        let refs: [ConstraintRef]
        /// Display value (degrees for `.angle`, sketch units otherwise).
        let displayValue: Double
        let text: String
        let worldAnchor: SIMD3<Double>
        let worldStart: SIMD3<Double>
        let worldEnd: SIMD3<Double>
    }

    /// In-flight inline edit of a dimension field (the candidate or an existing
    /// dimension). Non-nil while the numeric field is open in the overlay.
    struct DimensionEdit: Equatable {
        var labelID: String
        var dimensionID: UUID?
        var kind: DimensionKind
        var refs: [ConstraintRef]
        var text: String
    }
    var editingDimension: DimensionEdit?

    /// Radius of a circular entity (circle/arc/polygon); nil otherwise.
    private static func entityRadius(_ e: SketchEntity) -> Double? {
        switch e {
        case let .circle(_, _, r), let .arc(_, _, r, _, _), let .polygon(_, _, r, _, _): return r
        default: return nil
        }
    }

    private func sketchEntity(_ id: UUID, in sketch: Sketch) -> SketchEntity? {
        sketch.entities.first { $0.id == id }
    }

    /// Plane-local position of a constraint ref's point on its entity.
    private func localPoint(_ ref: ConstraintRef, in sketch: Sketch) -> SIMD2<Double>? {
        guard let e = sketchEntity(ref.entityID, in: sketch) else { return nil }
        switch (e, ref.role) {
        case let (.line(_, a, _), .endpointA): return a
        case let (.line(_, _, b), .endpointB): return b
        case let (.rect(_, mn, _), .endpointA): return mn
        case let (.rect(_, _, mx), .endpointB): return mx
        case let (.line(_, a, b), .whole): return (a + b) / 2
        default:
            switch e {
            case let .circle(_, c, _), let .arc(_, c, _, _, _),
                 let .ellipse(_, c, _, _, _), let .polygon(_, c, _, _, _):
                return c
            default: return nil
            }
        }
    }

    private func lineEndpoints(_ id: UUID, in sketch: Sketch) -> (SIMD2<Double>, SIMD2<Double>)? {
        guard case let .line(_, a, b)? = sketchEntity(id, in: sketch) else { return nil }
        return (a, b)
    }

    /// Local-space geometry for a dimension: (label anchor, annotation line
    /// endpoints). Kind-specific; falls back to the anchor for degenerate refs.
    private func dimensionGeometry(
        kind: DimensionKind, refs: [ConstraintRef], in sketch: Sketch
    ) -> (anchor: SIMD2<Double>, start: SIMD2<Double>, end: SIMD2<Double>)? {
        switch kind {
        case .distance:
            guard refs.count == 2 else { return nil }
            // point-to-line if exactly one ref is a whole line.
            let wholes = refs.filter { $0.role == .whole }
            if wholes.count == 1, let lineRef = wholes.first,
               let pointRef = refs.first(where: { $0.role != .whole }),
               let p = localPoint(pointRef, in: sketch),
               let (la, lb) = lineEndpoints(lineRef.entityID, in: sketch) {
                let proj = closestPointOnSegment(p, la, lb)
                return (( p + proj) / 2, p, proj)
            }
            guard let a = localPoint(refs[0], in: sketch),
                  let b = localPoint(refs[1], in: sketch) else { return nil }
            return ((a + b) / 2, a, b)
        case .radius, .diameter:
            guard let ref = refs.first,
                  let e = sketchEntity(ref.entityID, in: sketch),
                  let r = Self.entityRadius(e),
                  let c = localPoint(ConstraintRef(entityID: ref.entityID, role: .center), in: sketch)
            else { return nil }
            let end = c + SIMD2(r, 0)
            return (c + SIMD2(r * 0.5, 0), c, end)
        case .angle:
            guard refs.count == 2,
                  let (a1, b1) = lineEndpoints(refs[0].entityID, in: sketch),
                  let (a2, b2) = lineEndpoints(refs[1].entityID, in: sketch) else { return nil }
            let anchor = (a1 + b1 + a2 + b2) / 4
            return (anchor, (a1 + b1) / 2, (a2 + b2) / 2)
        }
    }

    private func closestPointOnSegment(
        _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> SIMD2<Double> {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 1e-12 else { return a }
        let t = simd_dot(p - a, ab) / len2
        return a + ab * t
    }

    /// Measured value of a dimension in DISPLAY units (degrees for angle).
    private func measuredValue(kind: DimensionKind, refs: [ConstraintRef], in sketch: Sketch) -> Double? {
        switch kind {
        case .distance:
            guard let g = dimensionGeometry(kind: kind, refs: refs, in: sketch) else { return nil }
            return simd_distance(g.start, g.end)
        case .radius:
            guard let ref = refs.first, let e = sketchEntity(ref.entityID, in: sketch) else { return nil }
            return Self.entityRadius(e)
        case .diameter:
            guard let ref = refs.first, let e = sketchEntity(ref.entityID, in: sketch) else { return nil }
            return Self.entityRadius(e).map { $0 * 2 }
        case .angle:
            guard refs.count == 2,
                  let (a1, b1) = lineEndpoints(refs[0].entityID, in: sketch),
                  let (a2, b2) = lineEndpoints(refs[1].entityID, in: sketch) else { return nil }
            let d1 = b1 - a1, d2 = b2 - a2
            let n1 = simd_length(d1), n2 = simd_length(d2)
            guard n1 > 1e-9, n2 > 1e-9 else { return nil }
            let cosA = min(max(simd_dot(d1, d2) / (n1 * n2), -1), 1)
            return acos(cosA) * 180 / .pi
        }
    }

    /// The dimension the current selection would create (auto-shown as an
    /// editable candidate label; also what the palette Dimension action edits).
    private var dimensionCandidate: (kind: DimensionKind, refs: [ConstraintRef])? {
        guard mode.isSketching else { return nil }
        let lines = selectedLineEntities
        let radii = selectedRadiusEntities
        let pts = Array(selectedSketchPoints)
        func pRef(_ p: SketchPointSelection) -> ConstraintRef {
            ConstraintRef(entityID: p.entityID, role: p.role)
        }
        // Two lines → angle.
        if lines.count == 2, radii.isEmpty, pts.isEmpty {
            return (.angle, [ConstraintRef(entityID: lines[0].id, role: .whole),
                             ConstraintRef(entityID: lines[1].id, role: .whole)])
        }
        // Two points → distance.
        if pts.count == 2 {
            return (.distance, [pRef(pts[0]), pRef(pts[1])])
        }
        // One point + one line → point-to-line distance.
        if pts.count == 1, lines.count == 1 {
            return (.distance, [pRef(pts[0]), ConstraintRef(entityID: lines[0].id, role: .whole)])
        }
        // Single line → length.
        if lines.count == 1, radii.isEmpty, pts.isEmpty {
            let id = lines[0].id
            return (.distance, [ConstraintRef(entityID: id, role: .endpointA),
                                ConstraintRef(entityID: id, role: .endpointB)])
        }
        // Single circle/arc/polygon → radius.
        if radii.count == 1, lines.isEmpty, pts.isEmpty {
            return (.radius, [ConstraintRef(entityID: radii[0].id, role: .whole)])
        }
        return nil
    }

    /// True when the palette Dimension action can act on the selection.
    var canDimensionSelection: Bool { dimensionCandidate != nil }

    /// Number → clean editable string (drops trailing zeros).
    private static func dimensionFieldText(_ value: Double) -> String {
        if abs(value - value.rounded()) < 1e-6 {
            return String(Int(value.rounded()))
        }
        return String(format: "%g", (value * 1000).rounded() / 1000)
    }

    /// Dimension labels to render in the sketch overlay: existing driving
    /// dimensions plus the live selection candidate (if any and not already an
    /// existing dimension over the same refs).
    var sketchDimensionLabels: [SketchDimensionLabel] {
        _ = session.changeCount
        guard let sketch = activeSketch else { return [] }
        var labels: [SketchDimensionLabel] = []

        func makeLabel(id: String, dimensionID: UUID?, kind: DimensionKind,
                       refs: [ConstraintRef], value: Double) -> SketchDimensionLabel? {
            guard let g = dimensionGeometry(kind: kind, refs: refs, in: sketch) else { return nil }
            let unit: String
            switch kind {
            case .angle: unit = "°"
            default: unit = " mm"
            }
            let text = String(format: "%.2f", value) + unit
            return SketchDimensionLabel(
                id: id, dimensionID: dimensionID, kind: kind, refs: refs,
                displayValue: value, text: text,
                worldAnchor: sketch.plane.toWorld(g.anchor),
                worldStart: sketch.plane.toWorld(g.start),
                worldEnd: sketch.plane.toWorld(g.end)
            )
        }

        for d in sketch.dimensions {
            // Prefer the measured value so the label is a truthful readout of
            // the solved geometry (matches the driving value when satisfied).
            let stored = d.kind == .angle ? d.value * 180 / .pi : d.value
            let display = measuredValue(kind: d.kind, refs: d.refs, in: sketch) ?? stored
            if let label = makeLabel(id: d.id.uuidString, dimensionID: d.id,
                                     kind: d.kind, refs: d.refs, value: display) {
                labels.append(label)
            }
        }

        // Live candidate — skip if an existing dimension already covers the
        // same refs+kind (so we don't double-draw once it's committed).
        if let cand = dimensionCandidate {
            let refSet = Set(cand.refs.map { "\($0.entityID)-\($0.role.rawValue)" })
            let existing = sketch.dimensions.contains { d in
                d.kind == cand.kind &&
                Set(d.refs.map { "\($0.entityID)-\($0.role.rawValue)" }) == refSet
            }
            if !existing, let value = measuredValue(kind: cand.kind, refs: cand.refs, in: sketch),
               let label = makeLabel(id: "candidate", dimensionID: nil,
                                     kind: cand.kind, refs: cand.refs, value: value) {
                labels.append(label)
            }
        }
        return labels
    }

    /// Open the inline numeric field for a label (tap on a dimension label).
    func beginDimensionEdit(_ label: SketchDimensionLabel) {
        editingDimension = DimensionEdit(
            labelID: label.id,
            dimensionID: label.dimensionID,
            kind: label.kind,
            refs: label.refs,
            text: Self.dimensionFieldText(label.displayValue)
        )
    }

    /// Palette Dimension action: open the field for the selection candidate
    /// (creating a new driving dimension on commit).
    func beginDimensionForSelection() {
        guard let cand = dimensionCandidate, let sketch = activeSketch,
              let value = measuredValue(kind: cand.kind, refs: cand.refs, in: sketch) else { return }
        editingDimension = DimensionEdit(
            labelID: "candidate",
            dimensionID: nil,
            kind: cand.kind,
            refs: cand.refs,
            // `measuredValue` already returns degrees for `.angle`.
            text: Self.dimensionFieldText(value)
        )
    }

    func cancelDimensionEdit() {
        editingDimension = nil
    }

    /// Commit the inline field: evaluate the (possibly arithmetic) text, set the
    /// driving value, re-solve, and push one undoable command. On over-defined
    /// refusal the geometry can't reach the value; we still record it and warn.
    func commitDimensionEdit(_ rawText: String) {
        guard let edit = editingDimension,
              case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch else {
            editingDimension = nil
            return
        }
        editingDimension = nil
        // Phase D: evaluate against document variables so a dimension can read
        // e.g. "width/2"; store the raw text as the driving formula only when it
        // references a variable/function (a plain number keeps `formula: nil`).
        guard let parsed = ExpressionEvaluator.evaluate(rawText, variables: session.variableValues()) else {
            errorMessage = "Couldn't read \"\(rawText)\" as a number."
            return
        }
        let formula = ExpressionEvaluator.identifiers(in: rawText).isEmpty ? nil : rawText
        // Linear dims must be positive; angles within (0, 180)°.
        switch edit.kind {
        case .angle:
            guard parsed > 0, parsed < 180 else {
                errorMessage = "Angle must be between 0° and 180°."
                return
            }
        default:
            guard parsed > 0 else {
                errorMessage = "Dimension must be greater than zero."
                return
            }
        }
        let stored = edit.kind == .angle ? parsed * .pi / 180 : parsed

        var proposed = sketch
        var setup: DocumentCommand
        if let dimID = edit.dimensionID,
           let idx = proposed.dimensions.firstIndex(where: { $0.id == dimID }) {
            let before = proposed.dimensions[idx]
            var after = before
            after.value = stored
            after.formula = formula
            proposed.dimensions[idx] = after
            setup = UpdateSketchDimensionCommand(sketchID: sketchID, before: before, after: after)
        } else {
            let dim = SketchDimension(kind: edit.kind, refs: edit.refs, value: stored, formula: formula)
            proposed.dimensions.append(dim)
            setup = AddSketchDimensionCommand(sketchID: sketchID, dimension: dim)
        }

        // Over-constraint guard (spec §2.2): the solver refuses a dimension on
        // an already fully-solved region / one that conflicts with existing
        // dimensions. Don't apply — never corrupt the sketch.
        if SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance {
            errorMessage = "That value over-constrains the sketch — it conflicts with the existing dimensions."
            return
        }

        let (solvedEntities, _) = SketchSolverBridge.solve(
            proposed, movingEntity: nil, dragTarget: nil
        )
        var commands: [DocumentCommand] = [setup]
        for (before, after) in zip(sketch.entities, solvedEntities) where before != after {
            commands.append(UpdateSketchEntityCommand(
                sketchID: sketchID, before: before, after: after
            ))
        }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Dimension", commands: commands))
        // Phase D: a dimension re-solves entity positions — rebuild dependent
        // features.
        session.rebuildForSketchChange(sketchID)
        session.save()
    }

    // MARK: - Make Construction / Make Regular (plan §B9, spec §3.3)

    /// True when every selected sketch entity is construction geometry
    /// (palette toggle state; the next toggle then makes them regular).
    var selectionIsConstruction: Bool {
        guard let sketch = activeSketch, !selectedSketchEntityIDs.isEmpty else { return false }
        return selectedSketchEntityIDs.allSatisfy { sketch.isConstruction($0) }
    }

    /// Bulk toggle on the selection: mixed/regular → all construction;
    /// all-construction → all regular.
    func toggleConstructionOnSelection() {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              !selectedSketchEntityIDs.isEmpty
        else { return }
        session.perform(SetConstructionCommand(
            sketchID: sketchID,
            entityIDs: selectedSketchEntityIDs,
            isConstruction: !selectionIsConstruction,
            sketch: sketch
        ))
    }

    // MARK: - Measure tool (spec §16.3 v1: point-to-point)

    /// Notable points picked so far (0–2, world space). A third tap restarts.
    var measurePoints: [SIMD3<Double>] = []

    var measureResult: (distance: Double, deltas: SIMD3<Double>)? {
        guard measurePoints.count == 2 else { return nil }
        return MeasureKit.distance(a: measurePoints[0], b: measurePoints[1])
    }

    func toggleMeasure() {
        if case .measuring = mode {
            exitMeasure()
            return
        }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selection.removeAll()
        measurePoints.removeAll()
        mode = .measuring
    }

    func exitMeasure() {
        measurePoints.removeAll()
        if case .measuring = mode {
            mode = .idle
        }
    }

    private func handleMeasureTap(ray: Ray) {
        guard let point = nearestNotablePoint(to: ray) else { return }
        if measurePoints.count >= 2 {
            measurePoints.removeAll() // next tap restarts the measurement
        }
        measurePoints.append(point)
    }

    /// Nearest notable point to the pick ray within a screen-ish tolerance:
    /// sketch snap points (SnapEngine) plus body vertices (render positions).
    private func nearestNotablePoint(to ray: Ray) -> SIMD3<Double>? {
        let tolerance = max(0.5, 30 * worldPerPoint)
        var best: (point: SIMD3<Double>, distance: Double)?
        func consider(_ p: SIMD3<Double>) {
            let pf = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            let t = simd_dot(pf - ray.origin, ray.direction)
            guard t > 0 else { return } // behind the camera
            let d = Double(simd_length(pf - ray.point(at: t)))
            if d <= tolerance, best == nil || d < best!.distance {
                best = (p, d)
            }
        }
        for sketch in session.document.sketches where !sketch.isHidden {
            for local in SnapEngine.snapPoints(of: sketch) {
                consider(sketch.plane.toWorld(local))
            }
        }
        for body in session.document.bodies where !body.isHidden {
            for position in body.render.positions {
                consider(body.transform.applying(to: SIMD3<Double>(position)))
            }
        }
        return best?.point
    }

    // MARK: - Selection info bar (spec §16.3: selection info at screen bottom)

    struct MeasurementRow: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Measurements for the current selection, shown in the bottom info strip.
    var selectionMeasurements: [MeasurementRow] {
        _ = session.changeCount
        switch mode {
        case .faceSelected(let id):
            guard let body = session.document.body(with: id),
                  let context = toolContext
            else { return [] }
            let area = MeasureKit.faceArea(
                body.render, triangles: context.faceTriangles, scale: body.transform.scale
            )
            // Profile loop is already in world scale (built with scale applied).
            let perimeter = MeasureKit.perimeter(of: context.profile.loop)
            return [
                MeasurementRow(label: "Area", value: Self.formatted(area, unit: "mm²")),
                MeasurementRow(label: "Perimeter", value: Self.formatted(perimeter, unit: "mm")),
            ]
        case .selected(let id), .editingPrimitive(let id):
            if selection.count > 1 {
                // Multi-selection (plan §B13): count + combined world bounds.
                let bodies = selection.compactMap { session.document.body(with: $0) }
                guard let box = MeasureKit.boundingBox(bodies: bodies) else { return [] }
                let size = box.max - box.min
                return [
                    MeasurementRow(label: "Selected", value: "\(bodies.count) bodies"),
                    MeasurementRow(
                        label: "Bounds",
                        value: String(format: "%.2f × %.2f × %.2f mm", size.x, size.y, size.z)
                    ),
                ]
            }
            guard let body = session.document.body(with: id),
                  let box = MeasureKit.boundingBox(bodies: [body])
            else { return [] }
            let volume = MeasureKit.bodyVolume(body.render, scale: body.transform.scale)
            let size = box.max - box.min
            return [
                MeasurementRow(label: "Volume", value: Self.formatted(volume, unit: "mm³")),
                MeasurementRow(
                    label: "Bounds",
                    value: String(format: "%.2f × %.2f × %.2f mm", size.x, size.y, size.z)
                ),
            ]
        case .sketching:
            let entities = activeSketch?.entities.filter {
                selectedSketchEntityIDs.contains($0.id)
            } ?? []
            guard !entities.isEmpty else { return [] }
            let total = entities.reduce(0.0) { $0 + MeasureKit.length(of: $1) }
            var rows = [MeasurementRow(
                label: entities.count == 1 ? "Length" : "Total Length",
                value: Self.formatted(total, unit: "mm")
            )]
            if entities.count == 1, let radius = MeasureKit.radius(of: entities[0]) {
                rows.append(MeasurementRow(
                    label: "Radius", value: Self.formatted(radius, unit: "mm")
                ))
            }
            return rows
        default:
            return []
        }
    }

    static func formatted(_ value: Double, unit: String) -> String {
        String(format: "%.2f %@", value, unit)
    }

    // MARK: - Insert Image (plan §B10, spec §6.3)

    /// Selected inserted image; shows the gizmo + image bar while idle.
    var selectedImageID: InsertedImageID?

    /// Picked image bytes awaiting a plane tap (`.pickingImagePlane`).
    var pendingImageData: Data?

    /// New images size to this max dimension (mm), preserving aspect.
    nonisolated static let insertedImageMaxDimension = 50.0

    /// The selected image, while the editor is idle (other modes hide the
    /// image gizmo/bar without dropping the selection).
    var selectedImage: InsertedImage? {
        guard mode == .idle, let id = selectedImageID else { return nil }
        _ = session.changeCount
        return session.document.images.first { $0.id == id }
    }

    /// Arm the plane pick for freshly picked image bytes (Photos or Files).
    func beginInsertImage(data: Data) {
        cancelTransientPicks()
        cancelTool()
        if case .sketching = mode { finishSketch() }
        selection.removeAll()
        selectedImageID = nil
        pendingImageData = data
        mode = .pickingImagePlane
    }

    func cancelImagePlanePick() {
        pendingImageData = nil
        if case .pickingImagePlane = mode {
            mode = .idle
        }
    }

    /// Tap routing while the image plane tiles are up: a tile hosts the
    /// image; anywhere else defaults to the ground plane.
    private func handleImagePlanePick(ray: Ray) {
        guard let data = pendingImageData else {
            mode = .idle
            return
        }
        let tiles = PlanePicking.worldTiles + constructionPlaneTiles
        let plane = PlanePicking.pick(ray: ray, tiles: tiles)?.tile.plane ?? .ground
        pendingImageData = nil
        insertImage(data: data, on: plane)
    }

    /// Width × height (mm) for a picture of the given pixel size, scaled so
    /// the larger side is `maxDimension` with aspect preserved.
    nonisolated static func insertedImageSize(
        pixelWidth: Double, pixelHeight: Double,
        maxDimension: Double = EditorViewModel.insertedImageMaxDimension
    ) -> (width: Double, height: Double) {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return (maxDimension, maxDimension)
        }
        let scale = maxDimension / max(pixelWidth, pixelHeight)
        return (pixelWidth * scale, pixelHeight * scale)
    }

    /// Pixel size decoded from the encoded bytes (ImageIO), or nil when the
    /// bytes are not a decodable picture.
    nonisolated static func imagePixelSize(of data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return (width, height)
    }

    /// Place the picture on `plane` as an InsertedImage (~50 mm max
    /// dimension, aspect preserved) and select it.
    func insertImage(data: Data, on plane: SketchPlane) {
        guard let pixels = Self.imagePixelSize(of: data) else {
            mode = .idle
            errorMessage = "Couldn't read the selected image."
            return
        }
        let size = Self.insertedImageSize(pixelWidth: pixels.width, pixelHeight: pixels.height)
        let image = InsertedImage(
            name: session.document.uniqueImageName(),
            plane: plane,
            width: size.width,
            height: size.height,
            imageData: data
        )
        session.perform(AddImageCommand(image: image))
        session.save()
        selectedImageID = image.id
        mode = .idle
        cameraControl?.fitTo(bounds: Self.imageBounds(image))
    }

    /// World AABB of an image quad (zoom-to and post-insert framing).
    nonisolated static func imageBounds(
        _ image: InsertedImage
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let hw = image.width / 2
        let hh = image.height / 2
        let corners = [
            SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh), SIMD2(-hw, hh),
        ].map { image.plane.toWorld($0) }
        var lo = SIMD3<Float>(Float(corners[0].x), Float(corners[0].y), Float(corners[0].z))
        var hi = lo
        for corner in corners {
            let p = SIMD3<Float>(Float(corner.x), Float(corner.y), Float(corner.z))
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// Nearest visible image quad under the ray (tap routing).
    private func imageHit(ray: Ray) -> (id: InsertedImageID, distance: Float)? {
        var best: (id: InsertedImageID, distance: Float)?
        for image in session.document.images where !image.isHidden {
            let plane = image.plane
            let origin = SIMD3<Float>(
                Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
            )
            let n = plane.normal
            let normal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
            guard let t = ray.intersect(planePoint: origin, planeNormal: normal) else {
                continue
            }
            let world = ray.point(at: t)
            let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
            guard abs(local.x) <= image.width / 2, abs(local.y) <= image.height / 2 else {
                continue
            }
            if best == nil || t < best!.distance {
                best = (image.id, t)
            }
        }
        return best
    }

    // MARK: Image editing (gizmo drag, size, opacity — UpdateImageCommand)

    /// Image snapshot at the start of a coalesced interaction (gizmo drag or
    /// opacity-slider scrub); the whole interaction is one undo step.
    private var imageInteractionBaseline: InsertedImage?
    /// True once the interaction pushed its command (later edits amend it).
    private var imageInteractionPerformed = false

    func beginImageInteraction() {
        imageInteractionBaseline = selectedImage
        imageInteractionPerformed = false
    }

    func endImageInteraction() {
        guard imageInteractionBaseline != nil else { return }
        imageInteractionBaseline = nil
        imageInteractionPerformed = false
        session.save()
    }

    /// Route an edited snapshot through UpdateImageCommand: inside an
    /// interaction the first change performs and the rest amend-coalesce;
    /// outside (typed field edits) each change is its own undo step.
    private func commitImageEdit(_ after: InsertedImage, title: String) {
        if let baseline = imageInteractionBaseline {
            guard after != baseline else { return }
            let command = UpdateImageCommand(before: baseline, after: after, title: title)
            if imageInteractionPerformed {
                session.amend(command)
            } else {
                session.perform(command)
                imageInteractionPerformed = true
            }
        } else if let current = selectedImage, after != current {
            session.perform(UpdateImageCommand(before: current, after: after, title: title))
            session.save()
        }
    }

    /// Gizmo drag: translate in-plane by the world delta's in-plane component.
    private func updateImageMove(delta: SIMD3<Float>) {
        guard let baseline = imageInteractionBaseline else { return }
        let worldDelta = SIMD3<Double>(Double(delta.x), Double(delta.y), Double(delta.z))
        let plane = baseline.plane
        let du = simd_dot(worldDelta, plane.xAxis)
        let dv = simd_dot(worldDelta, plane.yAxis)
        var after = baseline
        after.plane.origin = plane.origin + plane.xAxis * du + plane.yAxis * dv
        commitImageEdit(after, title: "Move Image")
    }

    /// Copy badge on an image (spec §5.1 convention): the drag moves a clone.
    private func duplicateSelectedImageForDrag() {
        guard let image = selectedImage else { return }
        let clone = InsertedImage(
            name: session.document.uniqueImageName(),
            plane: image.plane,
            width: image.width,
            height: image.height,
            opacity: image.opacity,
            imageData: image.imageData
        )
        session.perform(AddImageCommand(image: clone))
        selectedImageID = clone.id
    }

    /// Opacity slider (0…1); wrap scrubs in begin/endImageInteraction.
    func setImageOpacity(_ value: Double) {
        guard var after = imageInteractionBaseline ?? selectedImage else { return }
        after.opacity = min(max(value, 0), 1)
        commitImageEdit(after, title: "Image Opacity")
    }

    /// Size field: rescale so the larger side is `value` mm, keeping aspect.
    func setImageMaxDimension(_ value: Double) {
        guard let current = selectedImage, value > 0.01 else { return }
        let size = Self.insertedImageSize(
            pixelWidth: current.width, pixelHeight: current.height, maxDimension: value
        )
        var after = current
        after.width = size.width
        after.height = size.height
        commitImageEdit(after, title: "Resize Image")
    }

    /// Row tap in the Items panel: select the image (idle-mode gizmo + bar).
    func selectImageItem(_ id: InsertedImageID) {
        guard session.document.imageIndex(of: id) != nil else { return }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selection.removeAll()
        selectedImageID = id
        mode = .idle
    }

    func setImageHidden(_ id: InsertedImageID, hidden: Bool) {
        session.perform(SetItemVisibilityCommand(imageID: id, isHidden: hidden))
    }

    func renameImage(_ id: InsertedImageID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = session.document.images.first(where: { $0.id == id })?.name,
              !trimmed.isEmpty, trimmed != current
        else { return }
        session.perform(RenameItemCommand(imageID: id, before: current, after: trimmed))
    }

    func deleteImage(_ id: InsertedImageID) {
        guard let command = RemoveImageCommand(id: id, document: session.document) else { return }
        endImageInteraction()
        session.perform(command)
        if selectedImageID == id {
            selectedImageID = nil
        }
        session.save()
    }

    func zoomToImage(_ id: InsertedImageID) {
        guard let image = session.document.images.first(where: { $0.id == id }) else { return }
        cameraControl?.fitTo(bounds: Self.imageBounds(image))
    }

    // MARK: - Items Manager (spec §11)

    /// Body row tap: select the body (primitive rows open dimension editing).
    func selectItemBody(_ id: BodyID) {
        guard let body = session.document.body(with: id) else { return }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selectedImageID = nil
        selection = [id]
        mode = body.primitive != nil ? .editingPrimitive(id) : .selected(id)
    }

    /// Sketch row tap: enter sketch mode on it (hidden sketches render while
    /// active).
    func openItemSketch(_ id: SketchID) {
        guard let sketch = session.document.sketches.first(where: { $0.id == id }) else { return }
        if case .sketching(let current, _) = mode, current == id { return }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selectedImageID = nil
        selection.removeAll()
        mode = .sketching(id, tool: .line)
        cameraControl?.moveCameraHeadOn(to: sketch.plane)
    }

    func setItemHidden(_ item: DocumentItemRef, hidden: Bool) {
        session.perform(SetItemVisibilityCommand(item: item, isHidden: hidden))
    }

    func renameItem(_ item: DocumentItemRef, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let current: String?
        switch item {
        case .body(let id):
            current = session.document.body(with: id)?.name
        case .sketch(let id):
            current = session.document.sketches.first { $0.id == id }?.name
        case .plane:
            current = nil // planes are unnamed in v1
        }
        guard let current, !trimmed.isEmpty, trimmed != current else { return }
        session.perform(RenameItemCommand(item: item, before: current, after: trimmed))
    }

    func deleteItem(_ item: DocumentItemRef) {
        switch item {
        case .body(let id):
            if toolContext?.sourceBody == id { cancelTool() }
            // Transient modes may reference the body (rotate preview baseline,
            // pattern source, split target) — revert them before deleting.
            if rotateAxisState != nil || patternState?.bodyID == id {
                cancelTransientPicks()
            }
            session.perform(DeleteBodiesCommand(ids: [id], document: session.document))
            selection.remove(id)
            switch mode {
            case .editingPrimitive(let selected) where selected == id,
                 .selected(let selected) where selected == id,
                 .faceSelected(let selected) where selected == id:
                mode = .idle
            case .pickingBooleanTool(_, let target) where target == id:
                mode = .idle
            case .pickingSplitCutter(let target) where target == id:
                mode = .idle
            default:
                break
            }
        case .sketch(let id):
            if toolContext?.sketchID == id { cancelTool() }
            if case .sketching(let active, _) = mode, active == id { finishSketch() }
            guard let command = DeleteSketchCommand(id: id, document: session.document) else { return }
            session.perform(command)
        case .plane(let id):
            guard let command = DeletePlaneCommand(id: id, document: session.document) else { return }
            session.perform(command)
        }
        session.save()
    }

    /// "Zoom to": fit the camera to the item's world AABB.
    func zoomToItem(_ item: DocumentItemRef) {
        guard let bounds = itemBounds(item) else { return }
        cameraControl?.fitTo(bounds: bounds)
    }

    private func itemBounds(_ item: DocumentItemRef) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var points: [SIMD3<Float>] = []
        switch item {
        case .body(let id):
            guard let body = session.document.body(with: id) else { return nil }
            let bounds = Self.worldBounds(of: body)
            return (
                SIMD3(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z)),
                SIMD3(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z))
            )
        case .sketch(let id):
            guard let sketch = session.document.sketches.first(where: { $0.id == id }) else {
                return nil
            }
            points = SketchTessellator.segments(for: sketch.entities, on: sketch.plane)
        case .plane(let id):
            guard let plane = session.document.planes.first(where: { $0.id == id }) else {
                return nil
            }
            let h = plane.size / 2
            points = [SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)].map {
                (corner: SIMD2<Double>) -> SIMD3<Float> in
                let world = plane.plane.toWorld(corner)
                return SIMD3(Float(world.x), Float(world.y), Float(world.z))
            }
        }
        guard var lo = points.first else { return nil }
        var hi = lo
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// 32×24 four-quadrant test PNG for the OS3D_DEBUG_SEED_IMAGE hook —
    /// generated bytes, decodable by ImageIO, tiny enough to inline.
    nonisolated static let debugSeedImagePNG = Data(base64Encoded: [
        "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAANElEQVR42mN4VqFBEtKoeEYSYhi1",
        "YNSCUQtGLSDCAo0tUSShDydsSEKjFoxaMGrBqAVEIABHmai9SdsP8AAAAABJRU5ErkJggg==",
    ].joined()) ?? Data()

    /// Debug hook (OS3D_DEBUG_SEED): seed and select a box so automated
    /// screenshots can exercise selection/gizmo states.
    func debugSeedIfRequested() {
        // OS3D_DEBUG_SEED_IMAGE (plan §B10 UI tests): seed a reference image
        // on the ground plane so the insert flow is testable without the
        // Photos/Files pickers. Left unselected — tests exercise tap-select.
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED_IMAGE"] != nil,
           session.document.images.isEmpty {
            insertImage(data: Self.debugSeedImagePNG, on: .ground)
            selectedImageID = nil
        }
        guard ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED"] != nil,
              session.document.bodies.isEmpty
        else { return }
        var document = session.document
        var body = Body(
            name: document.uniqueBodyName(base: "Box"),
            transform: .identity,
            primitive: .box(width: 4, depth: 4, height: 4),
            euclidMesh: .primitive(.box(width: 4, depth: 4, height: 4)),
            revision: document.nextRevision()
        )
        // Seeded screenshots carry the default material explicitly (plan
        // §B15) — value-identical to the legacy look.
        body.material = .default
        session.perform(AddBodyCommand(body: body))
        selection = [body.id]
        mode = .editingPrimitive(body.id)
    }

    // MARK: - Feature graph recording (Phase D, Task C2)

    /// The most recent feature node that produces `id` (last writer wins for a
    /// BodyID owned by several nodes, e.g. a boolean that modifies its target in
    /// place), or nil if `id` is a non-feature body (import / copy / seed).
    private func featureNode(owning id: BodyID) -> FeatureNode? {
        session.document.features.nodes.last { $0.outputBodyIDs.contains(id) }
    }

    /// A `ProfileRef` capturing the sketch loop (+ hole loops) so the extrude can
    /// re-detect the same region on rebuild; the centroid is the seed-point
    /// fallback when the entity ids don't uniquely match.
    private func profileRef(profile: Profile, holes: [Profile], sketchID: SketchID) -> ProfileRef {
        ProfileRef(
            sketchID: sketchID,
            entityIDs: Array(profile.sourceEntityIDs),
            holeEntityIDs: holes.map { Array($0.sourceEntityIDs) },
            seedPoint: profile.centroid
        )
    }

    /// Build an `.extrude` feature node from the committing tool context, or nil
    /// when this isn't a sketch-profile extrude (face push/pull, revolve, sweep,
    /// loft — the latter three are tranche-2 features).
    private func extrudeFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .extrude(let distance) = context.kind,
              let sketchID = context.sketchID,
              !context.isFaceOperation
        else { return nil }
        let outer = profileRef(profile: context.profile, holes: context.holes, sketchID: sketchID)
        let extras = context.extraProfiles.map {
            profileRef(profile: $0.profile, holes: $0.holes, sketchID: sketchID)
        }
        return FeatureNode(
            name: "Extrude",
            kind: .extrude(
                profile: outer,
                plane: PlaneRef(source: .sketch(sketchID)),
                distance: Expr(value: distance),
                symmetric: context.symmetric,
                boolean: boolean,
                extraProfiles: extras
            ),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Build the history node for the committing tool, dispatching on
    /// `context.kind`: extrude (tranche 1) OR revolve / sweep / loft (tranche 2).
    /// Returns nil when the operation isn't a recordable sketch feature (face
    /// push/pull, offset plane, or a builder's preconditions aren't met) — the
    /// caller then records no node rather than a broken one.
    private func toolFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        switch context.kind {
        case .extrude:
            return extrudeFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .revolve:
            return revolveFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .sweep:
            return sweepFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .loft:
            return loftFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .offsetPlane:
            return nil
        }
    }

    /// Build a `.revolve` feature node from the committing tool context. The
    /// axis is the `RevolveAxis` captured in `context.kind` (sketch-plane-local),
    /// recorded as an explicit axis so replay is deterministic; nil for a
    /// non-revolve context or a face operation with no sketch.
    private func revolveFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .revolve(let axis, let angle) = context.kind,
              let sketchID = context.sketchID
        else { return nil }
        let outer = profileRef(profile: context.profile, holes: context.holes, sketchID: sketchID)
        return FeatureNode(
            name: "Revolve",
            kind: .revolve(
                profile: outer,
                plane: PlaneRef(source: .sketch(sketchID)),
                axis: AxisRef(source: .explicit(axis)),
                angle: Expr(value: angle),
                boolean: boolean
            ),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Build a `.sweep` feature node: the armed profile swept along the world-
    /// space polyline spine captured in `context.kind`. Nil for a non-sweep
    /// context or one lacking a sketch.
    private func sweepFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .sweep(let spine) = context.kind,
              let sketchID = context.sketchID
        else { return nil }
        let outer = profileRef(profile: context.profile, holes: context.holes, sketchID: sketchID)
        return FeatureNode(
            name: "Sweep",
            kind: .sweep(
                profile: outer,
                plane: PlaneRef(source: .sketch(sketchID)),
                spine: spine.map { PointWrapper($0) },
                boolean: boolean
            ),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Build a `.loft` feature node from the ordered loft sections, each pinned
    /// to its own sketch profile. Nil unless the context is a loft with the ≥2
    /// sections the evaluator requires.
    private func loftFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .loft = context.kind, context.loftProfiles.count >= 2 else { return nil }
        let sections = context.loftProfiles.map {
            profileRef(profile: $0.profile, holes: $0.holes, sketchID: $0.sketchID)
        }
        return FeatureNode(
            name: "Loft",
            kind: .loft(sections: sections, boolean: boolean),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Translate the interactive `PatternState` into the persisted `PatternSpec`.
    /// `axis` is the world direction (linear) / rotation axis (circular);
    /// `count` is total instances incl. the original; `totalAngle` is stored in
    /// RADIANS (the state carries degrees); `rotateInstances` matches the live
    /// circular transform call (always true). Used both when recording a pattern
    /// commit and — via the panel edit API — when rebuilding a spec field-by-field.
    private static func patternSpec(from state: PatternState) -> PatternSpec {
        PatternSpec(
            kind: state.kind == .linear ? .linear : .circular,
            axis: state.axis.direction,
            count: state.count,
            spacing: state.spacing,
            totalAngle: state.totalAngle * .pi / 180,
            rotateInstances: true
        )
    }

    /// A `.boolean` node for an explicit target/tool CSG, or nil unless BOTH
    /// bodies are feature-produced (only then can replay reconstruct them).
    private func booleanFeatureNode(kind: BooleanKind, target: Body, tool: Body) -> FeatureNode? {
        guard let targetOwner = featureNode(owning: target.id),
              let toolOwner = featureNode(owning: tool.id)
        else { return nil }
        return FeatureNode(
            name: kind.rawValue.capitalized,
            kind: .boolean(
                kind: kind,
                target: BodyRef(producer: targetOwner.id, bodyID: target.id),
                tools: [BodyRef(producer: toolOwner.id, bodyID: tool.id)]
            ),
            outputBodyIDs: [target.id]
        )
    }

    /// A `FaceRef` pinning the pushed planar face by geometric signature, in the
    /// source body's LOCAL space (matching `SignatureNaming`, which resolves
    /// against `body.render`). Nil if the selected face isn't a recoverable
    /// planar patch.
    private func pushPullFaceRef(
        context: ToolContext, source: Body, creator: FeatureID
    ) -> FaceRef? {
        guard let seed = context.faceTriangles.first,
              let face = FaceTopology.planarFace(in: source.render, seedTriangle: seed)
        else { return nil }
        let n = SIMD3<Double>(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let centroid = face.origin
        var area = abs(Profile.signedArea(face.outline))
        for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
        let signature = FaceSignature(
            kind: .planar, normal: n, centroid: centroid,
            area: max(area, 0), planeOffset: simd_dot(n, centroid))
        // Role is only a resolve tiebreak; box faces get a precise role, others
        // fall back to derived (signature alone still resolves above threshold).
        let role: FaceRole
        if case .primitive(let spec, _)? = session.document.features.node(creator)?.kind,
           case .box = spec {
            role = .boxFace(Self.boxFace(for: n))
        } else {
            role = .derived(index: 0)
        }
        return FaceRef(
            body: BodyRef(producer: creator, bodyID: source.id),
            creator: creator, role: role, signature: signature)
    }

    /// The signed ±X/±Y/±Z box face a normal points most strongly along.
    private static func boxFace(for n: SIMD3<Double>) -> BoxFace {
        let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
        if ax >= ay && ax >= az { return n.x >= 0 ? .px : .nx }
        if ay >= az { return n.y >= 0 ? .py : .ny }
        return n.z >= 0 ? .pz : .nz
    }

    // MARK: - History panel API (Phase D, Task C2)

    /// One row in the History panel; a projection of a `FeatureNode` plus its
    /// most-recent evaluation error.
    struct FeatureRow: Identifiable {
        let id: FeatureID
        var name: String
        var kindLabel: String
        var suppressed: Bool
        var hasError: Bool
        var errorText: String?
        /// True when this node sits at/after the rollback marker, so it is not
        /// evaluated (its bodies are absent). The History panel dims these rows.
        var isRolledBack: Bool = false
        /// The node's `PatternSpec` when this is a `.pattern` row, else nil.
        /// The panel keys off this to show pattern-specific fields (count,
        /// spacing for linear, angle for circular). `angleDegrees` re-exposes
        /// `spec.totalAngle` (radians) in the panel's degree units.
        var patternSpec: PatternSpec?

        /// True when this row edits a linear/circular pattern.
        var isPattern: Bool { patternSpec != nil }
        /// Total instance count (incl. original), or nil for non-pattern rows.
        var patternCount: Int? { patternSpec?.count }
        /// Adjacent-center spacing (linear patterns), or nil otherwise.
        var patternSpacing: Double? { patternSpec?.spacing }
        /// First→last sweep in DEGREES (circular patterns), or nil otherwise.
        var patternAngleDegrees: Double? {
            patternSpec.map { $0.totalAngle * 180 / .pi }
        }
        /// True when the pattern is circular (angle field applies), false linear
        /// (spacing field applies); nil for non-pattern rows.
        var patternIsCircular: Bool? {
            patternSpec.map { $0.kind == .circular }
        }
    }

    // MARK: - Document variables (Phase D, Task B2 / spec §6.6)

    /// One row in the Variables panel: the variable's identity, editable
    /// name/expression, its resolved value, and any resolution error surfaced
    /// from `VariableTable.resolve`.
    struct VariableRow: Identifiable {
        let id: VariableID
        var name: String
        var expression: String
        var value: Double
        var hasError: Bool
        var errorText: String?
    }

    /// Whether the Variables panel is shown.
    var showVariablesPanel = false

    /// The ordered variable rows, derived from `document.variables` plus the
    /// per-variable errors from `VariableTable.resolve` (creation-order rule).
    var variableRows: [VariableRow] {
        _ = session.changeCount // re-derive when the document changes
        let errors = VariableTable.resolve(session.document.variables).errors
        return session.document.variables.map { v in
            let err = errors[v.id]
            return VariableRow(
                id: v.id,
                name: v.name,
                expression: v.expression,
                value: v.value,
                hasError: err != nil,
                errorText: err
            )
        }
    }

    /// Append a new document variable with a unique default name ("var1",
    /// "var2", …) and expression "0", then re-resolve + fan out to dependents.
    func addVariable() {
        let existing = Set(session.document.variables.map { $0.name })
        var index = existing.count + 1
        var name = "var\(index)"
        while existing.contains(name) {
            index += 1
            name = "var\(index)"
        }
        let variable = Variable(name: name, expression: "0", value: 0)
        session.perform(AddVariableCommand(variable: variable))
        session.variablesDidChange()
        session.save()
    }

    /// Edit a variable's name and/or expression. The name is validated via
    /// `VariableTable.isValidName`; an invalid name sets `errorMessage` and
    /// makes no change. On success re-resolves the table and rebuilds every
    /// dependent feature/sketch formula.
    func setVariable(_ id: VariableID, name: String, expression: String) {
        guard let before = session.document.variables.first(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard VariableTable.isValidName(trimmedName) else {
            errorMessage = "\"\(name)\" isn't a valid variable name."
            return
        }
        guard before.name != trimmedName || before.expression != expression else { return }
        var after = before
        after.name = trimmedName
        after.expression = expression
        session.perform(EditVariableCommand(before: before, after: after))
        session.variablesDidChange()
        session.save()
    }

    /// Remove a variable, preserving its creation-order index for undo, then
    /// re-resolve + rebuild dependents (formulas that referenced it error to 0).
    func deleteVariable(_ id: VariableID) {
        guard let index = session.document.variables.firstIndex(where: { $0.id == id }) else { return }
        let variable = session.document.variables[index]
        session.perform(RemoveVariableCommand(index: index, variable: variable))
        session.variablesDidChange()
        session.save()
    }

    /// Whether the History panel is shown beside the Items panel.
    var showHistoryPanel = false

    /// The ordered history rows, derived from the graph + last eval errors.
    var historyRows: [FeatureRow] {
        _ = session.changeCount // re-derive when the document changes
        let nodes = session.document.features.nodes
        let cut = session.document.features.rollbackIndex ?? nodes.count
        return nodes.enumerated().map { index, node in
            let error = session.lastEvalErrors[node.id]
            let patternSpec: PatternSpec?
            if case let .pattern(_, spec) = node.kind { patternSpec = spec } else { patternSpec = nil }
            return FeatureRow(
                id: node.id,
                name: node.name,
                kindLabel: Self.kindLabel(node.kind),
                suppressed: node.suppressed,
                hasError: error != nil,
                errorText: error.map(Self.errorText),
                isRolledBack: index >= cut,
                patternSpec: patternSpec
            )
        }
    }

    /// The graph's rollback marker: the number of leading (active) nodes, or
    /// nil when every node is active (latest state). Nodes at/after this index
    /// are rolled back — not evaluated, their bodies removed.
    var rollbackIndex: Int? { session.document.features.rollbackIndex }

    /// Roll the history back to just after `id`, so the target node still
    /// evaluates but everything after it is suppressed. Rolled-back nodes'
    /// bodies disappear, so clean up selection/mode the same way undo/redo do.
    func rollbackToFeature(_ id: FeatureID) {
        guard let idx = session.document.features.index(of: id) else { return }
        session.setRollback(idx + 1)
        sanitizeAfterHistoryChange()
        session.save()
    }

    /// Clear the rollback marker, returning the model to its latest state
    /// (all nodes active). Newly restored bodies don't invalidate selection,
    /// but sanitize anyway for symmetry/safety.
    func clearRollback() {
        session.setRollback(nil)
        sanitizeAfterHistoryChange()
        session.save()
    }

    /// Select the bodies a feature owns, reusing the normal body-selection state.
    func selectFeature(_ id: FeatureID) {
        guard let node = session.document.features.node(id) else { return }
        let ids = node.outputBodyIDs.filter { session.document.body(with: $0) != nil }
        guard !ids.isEmpty else { return }
        cancelTool()
        selection = Set(ids)
        if ids.count == 1, let first = ids.first {
            mode = .selected(first)
        }
    }

    /// Rename a history node (and its output bodies, so the Items panel stays in
    /// sync) in one undo step.
    func renameFeature(_ id: FeatureID, to newName: String) {
        guard let node = session.document.features.node(id), node.name != newName else { return }
        var commands: [DocumentCommand] = [
            RenameFeatureCommand(featureID: id, before: node.name, after: newName)
        ]
        for bodyID in node.outputBodyIDs {
            guard let body = session.document.body(with: bodyID) else { continue }
            commands.append(RenameItemCommand(item: .body(bodyID), before: body.name, after: newName))
        }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Rename", commands: commands))
        session.save()
    }

    /// Delete a history node and rebuild everything downstream in one undo step.
    func deleteFeature(_ id: FeatureID) {
        session.deleteFeature(id)
        selection = selection.filter { session.document.body(with: $0) != nil }
        session.save()
    }

    /// Suppress / un-suppress a history node and rebuild downstream.
    func setFeatureSuppressed(_ id: FeatureID, _ value: Bool) {
        session.setSuppressed(id, value)
        session.save()
    }

    /// Fit the camera to the world AABB of a feature's output bodies.
    func zoomToFeature(_ id: FeatureID) {
        guard let node = session.document.features.node(id) else { return }
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = -lo
        var found = false
        for bodyID in node.outputBodyIDs {
            guard let body = session.document.body(with: bodyID) else { continue }
            let bounds = Self.worldBounds(of: body)
            lo = simd_min(lo, SIMD3(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z)))
            hi = simd_max(hi, SIMD3(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z)))
            found = true
        }
        guard found else { return }
        cameraControl?.fitTo(bounds: (lo, hi))
    }

    /// Edit a feature's primary scalar (extrude/push-pull distance, revolve
    /// angle) and rebuild downstream via the session's `EditFeatureCommand` path.
    func editFeatureDistance(_ id: FeatureID, _ value: Double) {
        guard let node = session.document.features.node(id),
              let after = Self.kind(node.kind, replacingScalar: value)
        else { return }
        session.editFeature(id, to: after)
        session.save()
    }

    /// The same feature kind with its primary scalar replaced, or nil if it has
    /// none (primitive/boolean/etc. aren't distance-editable in the panel).
    private static func kind(_ kind: FeatureKind, replacingScalar value: Double) -> FeatureKind? {
        Self.kind(kind, replacingExpr: Expr(value: value))
    }

    /// The same feature kind with its primary scalar `Expr` (value + optional
    /// parametric `formula`) replaced, or nil if it has none. Phase D: lets a
    /// distance/angle carry a formula that re-evaluates when variables change.
    private static func kind(_ kind: FeatureKind, replacingExpr expr: Expr) -> FeatureKind? {
        switch kind {
        case let .extrude(profile, plane, _, symmetric, boolean, extras):
            return .extrude(
                profile: profile, plane: plane, distance: expr,
                symmetric: symmetric, boolean: boolean, extraProfiles: extras)
        case let .pushPull(face, _, mode):
            return .pushPull(face: face, distance: expr, mode: mode)
        case let .revolve(profile, plane, axis, _, boolean):
            return .revolve(
                profile: profile, plane: plane, axis: axis,
                angle: expr, boolean: boolean)
        default:
            return nil
        }
    }

    /// Edit a feature's primary scalar from RAW TEXT that may reference document
    /// variables / functions (Phase D). Evaluates against the current variable
    /// values; on parse failure sets `errorMessage` and makes no change. The
    /// `formula` is stored only when the text references an identifier
    /// (variable or function) — a plain number stores `formula: nil` so it
    /// never re-evaluates. The evaluated value is stored directly (no unit
    /// conversion), matching `editFeatureDistance`.
    func editFeatureExpr(_ id: FeatureID, text: String) {
        guard let node = session.document.features.node(id) else { return }
        guard let value = ExpressionEvaluator.evaluate(text, variables: session.variableValues()) else {
            errorMessage = "Couldn't read \"\(text)\" as a number."
            return
        }
        let formula = ExpressionEvaluator.identifiers(in: text).isEmpty ? nil : text
        guard let after = Self.kind(node.kind, replacingExpr: Expr(value: value, formula: formula)) else { return }
        session.editFeature(id, to: after)
        session.save()
    }

    /// The current `PatternSpec` of a `.pattern` node, or nil if `id` isn't a
    /// pattern (the three panel edit APIs all rebuild from this base spec).
    private func patternSpec(of id: FeatureID) -> PatternSpec? {
        guard let node = session.document.features.node(id),
              case let .pattern(_, spec) = node.kind else { return nil }
        return spec
    }

    /// History-panel edit: change a pattern's total instance count (incl. the
    /// original). Rebuilds the full spec with the one field changed and routes
    /// through `session.editPatternFeature`, which resizes the node's
    /// outputBodyIDs (grow/shrink) and rebuilds every downstream mesh in one
    /// undo step. No-op unless `id` is a pattern.
    func editPatternCount(_ id: FeatureID, _ count: Int) {
        guard var spec = patternSpec(of: id) else { return }
        let clamped = max(1, count)
        guard clamped != spec.count else { return }
        spec.count = clamped
        session.editPatternFeature(id, spec: spec)
        session.save()
    }

    /// History-panel edit: change a linear pattern's adjacent-center spacing.
    /// No-op unless `id` is a pattern.
    func editPatternSpacing(_ id: FeatureID, _ v: Double) {
        guard var spec = patternSpec(of: id) else { return }
        guard v != spec.spacing else { return }
        spec.spacing = v
        session.editPatternFeature(id, spec: spec)
        session.save()
    }

    /// History-panel edit: change a circular pattern's first→last sweep, given
    /// in DEGREES (converted to the radians the spec stores). No-op unless `id`
    /// is a pattern.
    func editPatternAngle(_ id: FeatureID, _ deg: Double) {
        guard var spec = patternSpec(of: id) else { return }
        let radians: Double = deg * Double.pi / 180
        guard radians != spec.totalAngle else { return }
        spec.totalAngle = radians
        session.editPatternFeature(id, spec: spec)
        session.save()
    }

    /// Short label for a feature kind (History panel row subtitle).
    private static func kindLabel(_ kind: FeatureKind) -> String {
        switch kind {
        case let .primitive(spec, _):
            return spec.displayName
        case let .extrude(_, _, distance, _, boolean, _):
            let verb: String
            switch boolean.op {
            case .subtract: verb = "Cut"
            case .union: verb = "Extrude +"
            case .intersect: verb = "Extrude ∩"
            case .newBody: verb = "Extrude"
            }
            return "\(verb) \(fmt(distance.value)) mm"
        case let .boolean(op, _, _):
            return op.rawValue.capitalized
        case let .pushPull(_, distance, _):
            return "Push/Pull \(fmt(distance.value)) mm"
        case let .revolve(_, _, _, angle, _):
            return "Revolve \(fmt(angle.value))°"
        case .sweep: return "Sweep"
        case .loft: return "Loft"
        case .transform: return "Move"
        case .mirror: return "Mirror"
        case let .pattern(_, spec): return "Pattern ×\(spec.count)"
        }
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%g", (v * 1000).rounded() / 1000)
    }

    private static func errorText(_ error: FeatureError) -> String {
        switch error {
        case let .brokenRef(message): return "Broken reference: \(message)"
        case .emptyGeometry: return "Empty geometry"
        case let .kernelFailure(message): return message
        }
    }
}

// MARK: - Boolean intent mapping (Phase D, Task C2)

nonisolated extension BooleanKind {
    /// The parametric `BooleanIntent` op corresponding to this kernel boolean.
    var featureOp: BooleanIntent.Op {
        switch self {
        case .union: .union
        case .subtract: .subtract
        case .intersect: .intersect
        }
    }
}
