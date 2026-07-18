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
    case doubleTap
}

/// Camera operations the view model can request from the viewport.
@MainActor
protocol ViewportCameraControl: AnyObject {
    func fitScene()
    /// Animate to look head-on at a sketch plane.
    func moveCameraHeadOn(to plane: SketchPlane)
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

    /// STL of the whole document, or nil when empty.
    func exportSTL() -> Data? {
        let bodies = session.document.bodies
        guard !bodies.isEmpty else {
            errorMessage = "Nothing to export — the design has no solid bodies."
            return nil
        }
        return STLExporter.binarySTL(bodies: bodies)
    }

    func saveThumbnail() {
        if let data = thumbnailProvider?() {
            session.project.thumbnail = data
        }
    }

    var scene: ViewportScene {
        _ = session.changeCount // establish observation dependency
        var drawables: [BodyDrawable] = []
        for body in session.document.bodies {
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

        // Extrude preview: translucent accent body.
        if case .extruding = mode, let preview = extrudeContext?.preview {
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

        if let origin = gizmoOrigin {
            scene.gizmo = GizmoState(origin: origin, scale: 1, highlighted: gizmoHighlight)
        }

        // Sketch overlay: committed entities dark, in-progress accent blue.
        let committedColor = SIMD4<Float>(0.15, 0.17, 0.20, 1)
        let pendingColor = SIMD4<Float>(0.20, 0.48, 0.95, 1)
        for sketch in session.document.sketches {
            let batch = SketchLineBatch(
                segments: SketchTessellator.segments(for: sketch.entities, on: sketch.plane),
                color: committedColor
            )
            if !batch.segments.isEmpty {
                scene.sketchLines.append(batch)
            }
            // Closed regions get a fill — the Shapr3D affordance that a
            // profile can be pulled into 3D.
            scene.profileFills.append(contentsOf: fillBatches(for: sketch))
        }
        if case .sketching(let activeID, _) = mode,
           let sketch = session.document.sketches.first(where: { $0.id == activeID }),
           let pending = pendingEntity {
            scene.sketchLines.append(SketchLineBatch(
                segments: SketchTessellator.segments(for: [pending], on: sketch.plane),
                color: pendingColor
            ))
        }
        return scene
    }

    /// Gizmo attach point: the selected body's pivot.
    var gizmoOrigin: SIMD3<Float>? {
        guard selection.count == 1, let id = selection.first,
              let body = session.document.body(with: id)
        else { return nil }
        let t = body.transform.translation
        return SIMD3(Float(t.x), Float(t.y), Float(t.z))
    }

    // MARK: - Move drags (gizmo)

    private var moveBefore: [BodyID: Transform3D]?

    func beginMove() {
        guard !selection.isEmpty else { return }
        var before = [BodyID: Transform3D]()
        for id in selection {
            if let body = session.document.body(with: id) {
                before[id] = body.transform
            }
        }
        moveBefore = before
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

    // MARK: - Profile fills (cached per sketch content)

    private var fillCache: [SketchID: (entities: [SketchEntity], batches: [SketchFillBatch])] = [:]

    private func fillBatches(for sketch: Sketch) -> [SketchFillBatch] {
        if let cached = fillCache[sketch.id], cached.entities == sketch.entities {
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
        fillCache[sketch.id] = (sketch.entities, batches)
        return batches
    }

    // MARK: - Toolbar actions

    func deleteSelection() {
        guard !selection.isEmpty else { return }
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
        // Selection/mode may reference bodies that no longer exist.
        let liveIDs = Set(session.document.bodies.map(\.id))
        selection = selection.intersection(liveIDs)
        switch mode {
        case .editingPrimitive(let id) where !liveIDs.contains(id),
             .selected(let id) where !liveIDs.contains(id):
            mode = .idle
        default:
            break
        }
    }

    // MARK: - Viewport events

    func handle(_ event: ViewportEvent) {
        switch event {
        case .tap(let ray):
            handleTap(ray: ray)
        case .doubleTap:
            cameraControl?.fitScene()
        }
    }

    private func handleTap(ray: Ray) {
        switch mode {
        case .idle, .editingPrimitive, .selected:
            selectBody(ray: ray)
        case .extruding:
            commitExtrude()
        case .pickingBooleanTool(let kind, let targetID):
            handleBooleanToolTap(kind: kind, targetID: targetID, ray: ray)
        default:
            break
        }
    }

    private func selectBody(ray: Ray) {
        if let hit = HitTester.pickBody(ray: ray, in: scene) {
            selection = [hit.bodyID]
            if let body = session.document.body(with: hit.bodyID), body.primitive != nil {
                mode = .editingPrimitive(hit.bodyID)
            } else {
                mode = .selected(hit.bodyID)
            }
        } else if tryStartExtrude(ray: ray) {
            // Tapped inside a closed sketch profile → extrude it.
        } else {
            selection.removeAll()
            mode = .idle
        }
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

    // MARK: - Extrude

    struct ExtrudeContext {
        var profile: Profile
        var holes: [Profile]
        var plane: SketchPlane
        var sketchID: SketchID
        var distance: Double
        var previewRevision: UInt64 = 1
        var preview: Body?
    }

    var extrudeContext: ExtrudeContext?
    private var extrudeDragAnchor: Float?
    private var extrudeDragStartDistance: Double = 0
    /// True when the extrude came from a direct pull on a filled profile —
    /// Shapr3D push/pull semantics: releasing the drag commits the body.
    private var commitExtrudeOnRelease = false
    /// Stable identity for the preview drawable so GPU buffers cache by revision.
    private let extrudePreviewID = BodyID()

    /// The profile (with holes) under the ray, across all sketches.
    private func profileHit(
        ray: Ray
    ) -> (profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID)? {
        for sketch in session.document.sketches {
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
            let all = ProfileDetector.detectProfiles(in: sketch)
            let holes = ProfileDetector.holes(of: innermost, among: all)
            return (innermost, holes, plane, sketch.id)
        }
        return nil
    }

    /// Tap on a filled profile "jumps right into the Extrude command"
    /// (Shapr3D): opens the numeric extrude with a default pull.
    private func tryStartExtrude(ray: Ray) -> Bool {
        guard let hit = profileHit(ray: ray) else { return false }
        selection.removeAll()
        var context = ExtrudeContext(
            profile: hit.profile,
            holes: hit.holes,
            plane: hit.plane,
            sketchID: hit.sketchID,
            distance: 2
        )
        rebuildExtrudePreview(&context)
        extrudeContext = context
        mode = .extruding
        return true
    }

    /// Drag starting on a filled profile pulls it into 3D directly
    /// (push/pull). Committing happens on release.
    func beginFillPull(ray: Ray) -> Bool {
        guard HitTester.pickBody(ray: ray, in: scene) == nil,
              let hit = profileHit(ray: ray)
        else { return false }

        selection.removeAll()
        var context = ExtrudeContext(
            profile: hit.profile,
            holes: hit.holes,
            plane: hit.plane,
            sketchID: hit.sketchID,
            distance: 0
        )
        rebuildExtrudePreview(&context)
        extrudeContext = context
        mode = .extruding

        // Anchor the drag on the pull axis (profile centroid, plane normal).
        // Near head-on views (looking straight down the axis) have no stable
        // axis anchor — the screen-space fallback in updateExtrudeDrag covers
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
        extrudeDragStartDistance = 0
        commitExtrudeOnRelease = true
        return true
    }

    private func rebuildExtrudePreview(_ context: inout ExtrudeContext) {
        let mesh = KernelOps.extrude(
            profile: context.profile,
            holes: context.holes,
            in: context.plane,
            distance: context.distance
        )
        guard !mesh.polygons.isEmpty else {
            context.preview = nil
            return
        }
        context.previewRevision += 1
        context.preview = Body(
            id: extrudePreviewID,
            name: "Extrude Preview",
            transform: .identity,
            primitive: nil,
            euclidMesh: mesh,
            revision: context.previewRevision
        )
    }

    func setExtrudeDistance(_ distance: Double) {
        guard var context = extrudeContext else { return }
        context.distance = distance
        rebuildExtrudePreview(&context)
        extrudeContext = context
    }

    func commitExtrude() {
        guard let context = extrudeContext,
              abs(context.distance) > 1e-4,
              let preview = context.preview
        else {
            cancelExtrude()
            return
        }
        // Re-center the pivot at the profile centroid so the move gizmo
        // appears on the body rather than at the world origin.
        let centroidWorld = context.plane.toWorld(context.profile.centroid)
        var transform = Transform3D.identity
        transform.translation = centroidWorld
        let localMesh = preview.euclidMesh().translated(
            by: Vector(-centroidWorld.x, -centroidWorld.y, -centroidWorld.z)
        )

        let name = session.document.uniqueBodyName(base: "Extrude")
        let body = Body(
            name: name,
            transform: transform,
            primitive: nil,
            euclidMesh: localMesh,
            revision: preview.meshRevision
        )
        session.perform(AddBodyCommand(body: body, title: "Extrude"))
        extrudeContext = nil
        mode = .selected(body.id)
        selection = [body.id]
        session.save()
    }

    func cancelExtrude() {
        extrudeContext = nil
        if case .extruding = mode {
            mode = .idle
        }
    }

    // MARK: - Extrude drag (pull along the plane normal)

    func beginExtrudeDrag(ray: Ray) -> Bool {
        guard let context = extrudeContext else { return false }
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
        extrudeDragStartDistance = context.distance
        return true
    }

    /// `screenDeltaWorld`: cumulative drag distance since `.began` converted
    /// to world units by the viewport (positive = screen-up). Used when the
    /// camera looks straight down the pull axis.
    func updateExtrudeDrag(ray: Ray, screenDeltaWorld: Double) {
        guard let context = extrudeContext else { return }
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
            raw = extrudeDragStartDistance + Double(param - anchor)
        } else {
            raw = extrudeDragStartDistance + screenDeltaWorld
        }
        // Snap to 0.5 steps, like the sketch grid.
        let snapped = (raw / 0.5).rounded() * 0.5
        setExtrudeDistance(abs(raw - snapped) < 0.15 ? snapped : raw)
    }

    func endExtrudeDrag() {
        extrudeDragAnchor = nil
        if commitExtrudeOnRelease {
            commitExtrudeOnRelease = false
            // Push/pull: releasing the drag creates the body. A negligible
            // pull cancels instead of leaving a zero-thickness solid.
            if let context = extrudeContext, abs(context.distance) > 0.05 {
                commitExtrude()
            } else {
                cancelExtrude()
            }
        }
    }

    // MARK: - Sketch mode

    /// In-progress entity during a sketch drag (rubber band).
    var pendingEntity: SketchEntity?
    private var sketchStrokeStart: SIMD2<Double>?

    /// The active sketch while in sketching mode.
    var activeSketch: Sketch? {
        guard case .sketching(let id, _) = mode else { return nil }
        return session.document.sketches.first { $0.id == id }
    }

    func startSketch(tool: SketchTool) {
        selection.removeAll()
        if case .sketching(let id, _) = mode {
            mode = .sketching(id, tool: tool) // just switch tools
            return
        }
        // One working sketch on the ground plane per session for v1; reuse if
        // the document already has one there.
        let sketch: Sketch
        if let existing = session.document.sketches.first(where: { $0.plane == .ground }) {
            sketch = existing
        } else {
            let created = Sketch(plane: .ground)
            session.preview { $0.sketches.append(created) }
            sketch = created
        }
        mode = .sketching(sketch.id, tool: tool)
        cameraControl?.moveCameraHeadOn(to: sketch.plane)
    }

    func finishSketch() {
        pendingEntity = nil
        sketchStrokeStart = nil
        if case .sketching = mode {
            mode = .idle
        }
        session.save()
    }

    /// Ray → snapped plane-local point, while sketching.
    private func sketchPoint(from ray: Ray) -> SIMD2<Double>? {
        guard let sketch = activeSketch else { return nil }
        let plane = sketch.plane
        let planePoint = SIMD3<Float>(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z))
        let normal = plane.normal
        let planeNormal = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
        guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else {
            return nil
        }
        let world = ray.point(at: t)
        let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
        return SnapEngine.snap(local, in: sketch).point
    }

    func beginSketchStroke(ray: Ray) -> Bool {
        guard case .sketching = mode, let point = sketchPoint(from: ray) else { return false }
        sketchStrokeStart = point
        pendingEntity = nil
        return true
    }

    func updateSketchStroke(ray: Ray) {
        guard case .sketching(_, let tool) = mode,
              let start = sketchStrokeStart,
              let current = sketchPoint(from: ray)
        else { return }
        pendingEntity = makeEntity(tool: tool, from: start, to: current)
    }

    func endSketchStroke(ray: Ray) {
        defer {
            pendingEntity = nil
            sketchStrokeStart = nil
        }
        guard case .sketching(let sketchID, let tool) = mode,
              let start = sketchStrokeStart
        else { return }
        let end = sketchPoint(from: ray) ?? start
        guard let entity = makeEntity(tool: tool, from: start, to: end) else { return }
        session.perform(AddSketchEntityCommand(sketchID: sketchID, entity: entity))
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
        }
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
