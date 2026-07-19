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
}

@MainActor
@Observable
final class EditorViewModel {
    let session: DocumentSession
    var mode: EditorMode = .idle
    var selection: Set<BodyID> = []

    weak var cameraControl: (any ViewportCameraControl)?

    init(project: Project, modelContext: ModelContext) {
        self.session = DocumentSession(project: project, modelContext: modelContext)
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
        for body in session.document.bodies where !body.isHidden {
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
                selectionState: selectionState
            ))
        }
        var scene = ViewportScene(bodies: drawables)

        // Tool preview (extrude/revolve): translucent accent body.
        if let preview = toolContext?.preview {
            scene.bodies.append(BodyDrawable(
                id: preview.id,
                renderMesh: preview.render,
                edges: preview.edges,
                meshRevision: preview.meshRevision,
                modelMatrix: preview.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: SelectionStatePreview.rawValue,
                isTranslucent: true
            ))
        }

        // Selected-face highlight (Shapr3D: tap selects a face).
        if case .faceSelected(let bodyID) = mode,
           let context = toolContext,
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
        // selected entities accent orange.
        let committedColor = SIMD4<Float>(0.15, 0.17, 0.20, 1)
        let pendingColor = SIMD4<Float>(0.20, 0.48, 0.95, 1)
        let selectedColor = SIMD4<Float>(0.98, 0.55, 0.12, 1)
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
            let batch = SketchLineBatch(
                segments: SketchTessellator.segments(
                    for: unselected.filter { !construction.contains($0.id) }, on: sketch.plane
                ),
                color: committedColor
            )
            if !batch.segments.isEmpty {
                scene.sketchLines.append(batch)
            }
            let constructionUnselected = unselected.filter { construction.contains($0.id) }
            if !constructionUnselected.isEmpty {
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.dashedSegments(
                        for: constructionUnselected, on: sketch.plane
                    ),
                    color: committedColor
                ))
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

        // Plane pickers while a sketch tool waits for its plane, or while the
        // Split tool waits for a cutter plane.
        switch mode {
        case .pickingSketchPlane, .pickingSplitCutter:
            scene.planePickers = PlanePicking.worldTiles + constructionPlaneTiles
        default:
            break
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

    /// Gizmo attach point: the selected body's pivot. Whole-body selections
    /// only — face selections use the pull arrow instead.
    var gizmoOrigin: SIMD3<Float>? {
        switch mode {
        case .selected, .editingPrimitive:
            break
        default:
            return nil
        }
        guard selection.count == 1, let id = selection.first,
              let body = session.document.body(with: id)
        else { return nil }
        let t = body.transform.translation
        return SIMD3(Float(t.x), Float(t.y), Float(t.z))
    }

    // MARK: - Move drags (gizmo)

    private var moveBefore: [BodyID: Transform3D]?

    /// Copy badge (spec §5.1): when on, the next gizmo drag duplicates the
    /// selection and moves the copy. Resets after each drag.
    var copyOnDrag = false

    func beginMove() {
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

    /// Mirror the selected body across `plane` into a new body.
    func mirrorSelection(across plane: SketchPlane) {
        cancelTransientPicks()
        guard selection.count == 1, let id = selection.first,
              let body = session.document.body(with: id)
        else { return }
        let world = body.euclidMesh().transformed(by: body.transform.euclid)
        let mirrored = KernelOps.mirror(mesh: world, across: plane)
        guard !mirrored.polygons.isEmpty else {
            errorMessage = "Mirror produced no geometry."
            return
        }
        // Pivot of the copy: the original pivot reflected across the plane.
        let n = simd_normalize(plane.normal)
        let t = body.transform.translation
        let pivot = t - 2 * simd_dot(t - plane.origin, n) * n
        var transform = Transform3D.identity
        transform.translation = pivot
        let localMesh = mirrored.translated(by: Vector(-pivot.x, -pivot.y, -pivot.z))
        let copy = Body(
            name: session.document.uniqueBodyName(base: body.name),
            transform: transform,
            primitive: nil,
            euclidMesh: localMesh,
            revision: body.meshRevision
        )
        session.perform(AddBodyCommand(body: copy, title: "Mirror"))
        selection = [copy.id]
        mode = .selected(copy.id)
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

    var patternState: PatternState?

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
        }
        guard !commands.isEmpty else { return }
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
            guard !selectedSketchEntityIDs.isEmpty, let sketch = activeSketch else { return }
            session.perform(RemoveSketchEntitiesCommand(ids: selectedSketchEntityIDs, sketch: sketch))
            selectedSketchEntityIDs.removeAll()
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
        // Selection/mode may reference bodies that no longer exist.
        let liveIDs = Set(session.document.bodies.map(\.id))
        selection = selection.intersection(liveIDs)
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
            startExtrude(with: fill)
            return
        }

        if let hit = bodyHit {
            cancelTool()
            selection = [hit.bodyID]
            let face = session.document.body(with: hit.bodyID).flatMap {
                FaceTopology.planarFace(in: $0.render, seedTriangle: hit.triangleIndex)
            }
            guard let body = session.document.body(with: hit.bodyID), let face else {
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
        session.perform(ResizePrimitiveCommand(bodyID: id, beforeSpec: currentSpec, afterSpec: newSpec))
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
            self.session.perform(BooleanCommand(
                kind: kind,
                targetBefore: target,
                toolIndex: toolIndex,
                toolBefore: tool,
                result: result
            ))
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
        var previewRevision: UInt64 = 1
        var preview: Body?

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

    /// Slightly overlapped tool (union of all profile prisms) so coplanar
    /// seams merge cleanly.
    private func overlapExtrudeTool(_ context: ToolContext, distance: Double) -> Euclid.Mesh {
        let n = context.plane.normal
        let sign: Double = distance >= 0 ? 1 : -1
        func tool(_ profile: Profile, _ holes: [Profile]) -> Euclid.Mesh {
            if context.symmetric {
                // Symmetric solids straddle the plane: pad both sides.
                return KernelOps.extrude(
                    profile: profile,
                    holes: holes,
                    in: context.plane,
                    distance: distance + sign * 0.001,
                    symmetric: true
                )
            }
            return KernelOps.extrude(
                profile: profile,
                holes: holes,
                in: context.plane,
                distance: distance + sign * 0.002
            ).translated(by: Vector(-n.x * sign * 0.001, -n.y * sign * 0.001, -n.z * sign * 0.001))
        }
        var solid = tool(context.profile, context.holes)
        for extra in context.extraProfiles {
            solid = solid.union(tool(extra.profile, extra.holes))
        }
        return solid
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
        if let hide = consumedSketchHideCommand(context) {
            session.perform(CompositeCommand(
                title: title,
                commands: [AddBodyCommand(body: body, title: title), hide]
            ))
        } else {
            session.perform(AddBodyCommand(body: body, title: title))
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

    // MARK: - Sketch element selection + drag-editing

    /// Selected entities of the active sketch (accent highlight; palette
    /// Delete removes them).
    var selectedSketchEntityIDs: Set<UUID> = []

    /// A drag editing one entity: a control point (endpoint/center/handle)
    /// or the whole body (nil control = translate). The command is pushed on
    /// the first change and amend-coalesced for the rest of the drag.
    private struct SketchEntityDrag {
        var sketchID: SketchID
        var control: SketchHitTester.ControlKind?
        var before: SketchEntity
        /// Raw plane point where the drag grabbed the entity (translations).
        var grabPoint: SIMD2<Double>
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
        clearChain() // a tap ends line chaining
        if pendingArc != nil {
            // Tap elsewhere finalizes the bulge-adjustable pending arc.
            commitPendingArc()
            return
        }
        guard let sketch = activeSketch, let raw = rawSketchPoint(from: ray) else { return }
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
            grabPoint: raw
        )
        sketchStrokeStart = nil
        pendingEntity = nil
        return true
    }

    private func updateSketchEntityDrag(raw: SIMD2<Double>) {
        guard var drag = sketchEntityDrag, let sketch = activeSketch else { return }
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

    func startSketch(tool: SketchTool) {
        if case .sketching(let id, _) = mode {
            commitPendingArc()
            clearChain()
            mode = .sketching(id, tool: tool) // just switch tools
            return
        }
        cancelTransientPicks()
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
        pendingEntity = nil
        sketchStrokeStart = nil
        adjustingArcBulge = false
        sketchEntityDrag = nil
        sketchGizmoDrag = nil
        sketchCopyOnDrag = false
        selectedSketchEntityIDs.removeAll()
        if case .sketching = mode {
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
              let current = sketchPoint(from: ray)
        else { return }
        pendingEntity = makeEntity(tool: tool, from: start, to: current)
    }

    func endSketchStroke(ray: Ray) {
        defer {
            pendingEntity = nil
            sketchStrokeStart = nil
        }
        if adjustingArcBulge {
            adjustingArcBulge = false
            return
        }
        if sketchGizmoDrag != nil {
            sketchGizmoDrag = nil // commands already pushed/amended live
            return
        }
        if sketchEntityDrag != nil {
            sketchEntityDrag = nil // command already pushed/amended live
            return
        }
        guard case .sketching(let sketchID, let tool) = mode,
              let start = sketchStrokeStart
        else { return }
        let end = sketchPoint(from: ray) ?? start
        guard let entity = makeEntity(tool: tool, from: start, to: end) else { return }
        if tool == .arc {
            // Held as pending so a follow-up drag can adjust the bulge.
            pendingArc = PendingArc(a: start, b: end, sagitta: Self.defaultSagitta(a: start, b: end))
            return
        }
        session.perform(AddSketchEntityCommand(sketchID: sketchID, entity: entity))
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

    // MARK: - Items Manager (spec §11)

    /// Body row tap: select the body (primitive rows open dimension editing).
    func selectItemBody(_ id: BodyID) {
        guard let body = session.document.body(with: id) else { return }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
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

    /// Debug hook (OS3D_DEBUG_SEED): seed and select a box so automated
    /// screenshots can exercise selection/gizmo states.
    func debugSeedIfRequested() {
        guard ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED"] != nil,
              session.document.bodies.isEmpty
        else { return }
        var document = session.document
        let body = Body(
            name: document.uniqueBodyName(base: "Box"),
            transform: .identity,
            primitive: .box(width: 4, depth: 4, height: 4),
            euclidMesh: .primitive(.box(width: 4, depth: 4, height: 4)),
            revision: document.nextRevision()
        )
        session.perform(AddBodyCommand(body: body))
        selection = [body.id]
        mode = .editingPrimitive(body.id)
    }
}
