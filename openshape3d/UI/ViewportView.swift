//
//  ViewportView.swift
//  openshape3d
//
//  SwiftUI wrapper for the Metal viewport. On-demand rendering: the view is
//  paused and redraws on setNeedsDisplay (gestures + scene updates).
//

import SwiftUI
import MetalKit

struct ViewportView: UIViewRepresentable {
    let viewModel: EditorViewModel

    func makeCoordinator() -> ViewportCoordinator {
        ViewportCoordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.sceneDidChange()
    }
}

@MainActor
final class ViewportCoordinator: NSObject, ViewportGestureDelegate, ViewportCameraControl {
    let viewModel: EditorViewModel
    private(set) var renderer: Renderer?
    private let gestures = ViewportGestureController()
    private weak var view: MTKView?
    private var cameraAnimator: CameraAnimator?

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.cameraControl = self
    }

    func attach(to view: MTKView) {
        guard let context = RenderContext() else {
            assertionFailure("Metal is unavailable")
            return
        }
        context.configure(view: view)
        let renderer = Renderer(context: context)
        renderer.scene = viewModel.scene
        view.delegate = renderer
        self.renderer = renderer
        self.view = view
        cameraAnimator = CameraAnimator(renderer: renderer, view: view)
        gestures.attach(to: view, renderer: renderer)
        gestures.delegate = self

        // Keep the Look-at-Sketch affordance in sync with camera motion
        // (gestures and animated flights both move the camera).
        gestures.cameraChanged = { [weak self] in self?.cameraDidMove() }
        cameraAnimator?.cameraChanged = { [weak self] in self?.cameraDidMove() }
        renderer.camera.projection = viewModel.orthographicEnabled
            ? .orthographic
            : .perspective(fovY: TurntableCamera.defaultFovY)

        // Strong capture on purpose: the coordinator can be torn down before
        // the parent view's onDisappear, but the renderer stays usable for
        // offscreen thumbnail capture as long as the view model lives.
        viewModel.thumbnailProvider = { renderer.makeThumbnailPNG() }
        viewModel.screenshotProvider = { width, height, transparent, showGrid in
            renderer.makeThumbnailPNG(
                width: width,
                height: height,
                transparentBackground: transparent,
                showGrid: showGrid
            )
        }

        if let bounds = renderer.scene.worldBounds {
            renderer.camera.fit(boundsMin: bounds.min, boundsMax: bounds.max)
        }

        // Re-publish the camera whenever the viewport is laid out or resized.
        // The MTKView starts at .zero and is sized afterwards, so every SwiftUI
        // overlay that projects world points evaluates once against an EMPTY
        // viewport and would stay stale — silently drawing nothing — until the
        // user happened to move the camera. This also covers rotation and
        // split-view resizes.
        renderer.viewportSizeChanged = { [weak self] in self?.cameraDidMove() }
        cameraDidMove()
    }

    func sceneDidChange() {
        renderer?.scene = viewModel.scene
        view?.setNeedsDisplay()
    }

    private func ray(at point: CGPoint) -> Ray? {
        guard let renderer, let view else { return nil }
        return renderer.camera.ray(through: point, viewportSize: view.bounds.size)
    }

    // MARK: - ViewportGestureDelegate

    private var gizmoDrag: GizmoDragSession?
    private var dragStartPoint: CGPoint = .zero

    /// World units per screen point at the camera target depth — converts
    /// screen drags for the head-on pull fallback and sketch pick tolerances
    /// (ViewportCameraControl.worldUnitsPerPoint).
    var worldUnitsPerPoint: Double { worldPerPoint }

    private var worldPerPoint: Double {
        guard let renderer, let view, view.bounds.height > 0 else { return 0.01 }
        let camera = renderer.camera
        return Double(2 * camera.distance * tan(camera.fovY * 0.5))
            / Double(view.bounds.height)
    }

    private var pullActive = false
    /// A drag scrubbing the Rotate-Around-Axis angle (5° steps).
    private var rotateAxisDragActive = false
    /// A drag moving the section plane along its normal (spec §16.1).
    private var sectionDragActive = false
    /// A drag scrubbing the chamfer/fillet size on the edge arrow (spec §4.3).
    private var blendDragActive = false
    /// A drag on the orientation cube orbiting the camera (spec §7.2): the
    /// universal orbit control, live in every mode.
    private var cubeOrbitActive = false
    private var lastCubeDragPoint: CGPoint = .zero

    func gestureTapped(at point: CGPoint) {
        // Orientation cube first: taps on it never reach the model.
        if let renderer, let view,
           let pose = OrientationCube.hitPose(
               at: point, camera: renderer.camera, viewSize: view.bounds.size
           ) {
            cameraAnimator?.animate(to: pose, duration: 0.4)
            return
        }
        // Tapping (not dragging) a gizmo arrow opens exact-distance entry.
        if let part = gizmoPart(at: point), part.isArrow {
            viewModel.beginAxisDistanceEntry(part)
            sceneDidChange()
            return
        }
        guard let ray = ray(at: point) else { return }
        viewModel.handle(.tap(ray: ray))
    }

    /// Project a gizmo-local offset to screen (local → world → screen), the
    /// same mapping `MoveGizmoOverlay` draws with. nil when no gizmo is up.
    private func gizmoProjector() -> ((SIMD3<Float>) -> CGPoint?)? {
        guard let renderer, let origin = viewModel.gizmoOrigin else { return nil }
        let scale = renderer.gizmoScale(origin: origin)
        return { [weak self] local in
            let world = origin + local * scale
            return self?.worldToScreenPoint(
                SIMD3(Double(world.x), Double(world.y), Double(world.z)))
        }
    }

    /// The gizmo handle under a screen tap — hit-tested against the SAME 2D
    /// anchors the overlay draws, so the flat handle a user sees is the target
    /// they grab (the old 3D-mesh capsule test no longer matched the visual).
    private func gizmoPart(at point: CGPoint) -> GizmoPart? {
        guard let project = gizmoProjector() else { return nil }
        return GizmoScreenLayout.hitTest(at: point, project: project)
    }

    func gestureDoubleTapped(at point: CGPoint) {
        guard let ray = ray(at: point) else { return }
        viewModel.handle(.doubleTap(ray: ray))
    }

    /// A one-finger drag drawing the select-mode marquee (plan §B13).
    private var marqueeActive = false

    /// Screen offset (points) of the drawn SF Symbol handle off the projected
    /// cap, and the touch radius around it. MUST match `ExtrudeGizmoOverlay`'s
    /// `float` so the grab region sits exactly under the symbol the user sees.
    static let pullHandleScreenOffset: CGFloat = 30
    private static let pullHandleTouchRadius: CGFloat = 46

    /// True when the screen `point` lands within a touch-friendly radius of the
    /// drawn pull-arrow handle. The handle is a SwiftUI SF Symbol overlay at a
    /// fixed screen offset off the projected cap, so the grab test is done in
    /// screen space (not a world ray) to line up exactly with what's visible.
    private func hitsPullArrowScreen(point: CGPoint, arrow: PullArrowState) -> Bool {
        let o = SIMD3<Double>(Double(arrow.origin.x), Double(arrow.origin.y), Double(arrow.origin.z))
        guard let p0 = worldToScreenPoint(o) else { return false }
        let d = simd_normalize(SIMD3<Double>(Double(arrow.direction.x),
                                             Double(arrow.direction.y),
                                             Double(arrow.direction.z)))
        let p1 = worldToScreenPoint(o + d)
        var ux: CGFloat = 0, uy: CGFloat = -1
        if let p1 {
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 0.5 { ux = dx / len; uy = dy / len }
        }
        let handle = CGPoint(x: p0.x + ux * Self.pullHandleScreenOffset,
                             y: p0.y + uy * Self.pullHandleScreenOffset)
        return hypot(point.x - handle.x, point.y - handle.y) <= Self.pullHandleTouchRadius
    }

    /// World-mm drag component along the blend arrow's on-screen direction —
    /// positive when dragging the way the arrow points (into the body).
    private func blendDragDelta(to point: CGPoint) -> Double {
        guard let arrow = viewModel.scene.pullArrow else { return 0 }
        let o = SIMD3<Double>(Double(arrow.origin.x), Double(arrow.origin.y), Double(arrow.origin.z))
        guard let p0 = worldToScreenPoint(o) else { return 0 }
        let d = simd_normalize(SIMD3<Double>(Double(arrow.direction.x),
                                             Double(arrow.direction.y),
                                             Double(arrow.direction.z)))
        var ux: CGFloat = 0, uy: CGFloat = -1
        if let p1 = worldToScreenPoint(o + d) {
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 0.5 { ux = dx / len; uy = dy / len }
        }
        let dx = point.x - dragStartPoint.x
        let dy = point.y - dragStartPoint.y
        return Double(dx * ux + dy * uy) * worldPerPoint
    }

    func gestureDragBegan(at point: CGPoint) -> Bool {
        dragStartPoint = point
        pullActive = false

        // Orientation cube = universal orbit control (spec §7.2): a drag that
        // STARTS on the cube orbits the camera in EVERY mode, so the user can
        // always reorient even when a tool owns the rest of the viewport. (A
        // tap on the cube still snaps to that standard view — taps and drags
        // are separate gestures.)
        if let view, OrientationCube.rect(in: view.bounds.size).contains(point) {
            cubeOrbitActive = true
            lastCubeDragPoint = point
            return true
        }

        guard let ray = ray(at: point) else { return false }

        // Select mode: one-finger drags draw the marquee (spec §8.2).
        if viewModel.beginMarquee(at: SIMD2(Double(point.x), Double(point.y))) {
            marqueeActive = true
            return true
        }

        // Sketch mode: one-finger drags draw.
        if viewModel.mode.isSketching {
            return viewModel.beginSketchStroke(ray: ray)
        }

        // Extruding: drags adjust the pull distance / revolve angle.
        if case .extruding = viewModel.mode {
            pullActive = viewModel.beginToolDrag(ray: ray)
            return pullActive
        }

        // Waiting for an axis tap: don't let a stray drag start a new pull.
        if case .pickingRevolveAxis = viewModel.mode {
            return false
        }

        // Waiting for sweep-path / loft-section taps: stray drags orbit.
        if case .pickingSweepPath = viewModel.mode {
            return false
        }
        if case .pickingLoftProfiles = viewModel.mode {
            return false
        }

        // Rotate Around Axis: once the axis is set, drags scrub the angle;
        // before that (and for Translate/Align picks) drags orbit.
        if case .rotatingAroundAxis = viewModel.mode {
            rotateAxisDragActive = viewModel.beginRotateAxisDrag()
            return rotateAxisDragActive
        }
        if case .translating = viewModel.mode {
            return false
        }
        if case .aligning = viewModel.mode {
            return false
        }

        // Choosing a sketch plane: taps pick, drags orbit.
        if case .pickingSketchPlane = viewModel.mode {
            return false
        }

        // Choosing a section plane: taps pick, drags orbit.
        if case .pickingSectionPlane = viewModel.mode {
            return false
        }

        // Section View active: a drag starting on the pull arrow moves the
        // plane along its normal (offset-plane pattern); elsewhere orbits.
        if viewModel.beginSectionDrag(ray: ray) {
            sectionDragActive = true
            return true
        }

        // Chamfer/Fillet pick: grabbing the edge arrow scrubs the blend size
        // (drag into the body = bigger, Shapr3D §4.3); anywhere else orbits.
        if case .pickingBlendEdges = viewModel.mode {
            if let arrow = viewModel.scene.pullArrow,
               hitsPullArrowScreen(point: point, arrow: arrow),
               viewModel.beginBlendDrag() {
                blendDragActive = true
                return true
            }
            return false
        }

        // Shell pick: taps toggle open faces, drags orbit.
        if case .pickingShellFaces = viewModel.mode {
            return false
        }

        // Face selected: ONLY grabbing the pull-arrow handle pushes/pulls the
        // face (Shapr3D). A drag anywhere else — including on the face itself —
        // orbits, so the face never moves by accident.
        if case .faceSelected = viewModel.mode {
            if let arrow = viewModel.scene.pullArrow,
               hitsPullArrowScreen(point: point, arrow: arrow),
               viewModel.beginToolDrag(ray: ray) {
                pullActive = true
                return true
            }
            return false   // drags off the arrow orbit; the face stays put
        }

        // Offer the drag to the gizmo when a body is selected. The part is
        // picked in SCREEN space (matching the 2D overlay); the drag math then
        // runs in 3D from that part.
        if let renderer, let origin = viewModel.gizmoOrigin,
           let part = gizmoPart(at: point) {
            let gizmo = GizmoState(
                origin: origin,
                scale: renderer.gizmoScale(origin: origin),
                highlighted: nil
            )
            if let session = GizmoDragSession(part: part, gizmo: gizmo, ray: ray) {
                gizmoDrag = session
                viewModel.gizmoHighlight = part
                viewModel.beginMove()
                return true
            }
        }

        // Shapr3D push/pull: a drag starting on a filled profile extrudes it.
        pullActive = viewModel.beginFillPull(ray: ray)
        return pullActive
    }

    func gestureDragChanged(at point: CGPoint) {
        if cubeOrbitActive {
            guard let renderer, let view else { return }
            let delta = CGSize(
                width: point.x - lastCubeDragPoint.x,
                height: point.y - lastCubeDragPoint.y
            )
            lastCubeDragPoint = point
            renderer.camera.orbit(deltaPixels: delta, viewportSize: view.bounds.size)
            cameraDidMove()
            view.setNeedsDisplay()
            return
        }
        if marqueeActive {
            // The marquee overlay is SwiftUI state — no Metal redraw needed.
            viewModel.updateMarquee(to: SIMD2(Double(point.x), Double(point.y)))
            return
        }
        guard let ray = ray(at: point) else { return }
        if viewModel.mode.isSketching {
            viewModel.updateSketchStroke(ray: ray)
            sceneDidChange()
            return
        }
        if rotateAxisDragActive {
            let screenDelta = Double(dragStartPoint.y - point.y) * worldPerPoint
            viewModel.updateRotateAxisDrag(screenDeltaWorld: screenDelta)
            sceneDidChange()
            return
        }
        if sectionDragActive {
            let screenDelta = Double(dragStartPoint.y - point.y) * worldPerPoint
            viewModel.updateSectionDrag(ray: ray, screenDeltaWorld: screenDelta)
            sceneDidChange()
            return
        }
        if blendDragActive {
            viewModel.updateBlendDrag(delta: blendDragDelta(to: point))
            sceneDidChange()
            return
        }
        if pullActive {
            let screenDelta = Double(dragStartPoint.y - point.y) * worldPerPoint
            viewModel.updateToolDrag(ray: ray, screenDeltaWorld: screenDelta)
            sceneDidChange()
            return
        }
        guard let session = gizmoDrag else { return }
        if session.part.isRing {
            if let angle = session.rotationDelta(for: ray) {
                viewModel.updateRotation(part: session.part, deltaRadians: angle)
                sceneDidChange()
            }
            return
        }
        guard let delta = session.translationDelta(for: ray) else { return }
        viewModel.updateMove(delta: delta)
        sceneDidChange()
    }

    func gestureDragEnded(at point: CGPoint) {
        if cubeOrbitActive {
            cubeOrbitActive = false
            return
        }
        if marqueeActive {
            marqueeActive = false
            viewModel.updateMarquee(to: SIMD2(Double(point.x), Double(point.y)))
            viewModel.endMarquee { [weak self] world in
                self?.worldToScreen(world)
            }
            sceneDidChange()
            return
        }
        if viewModel.mode.isSketching, let ray = ray(at: point) {
            viewModel.endSketchStroke(ray: ray)
            sceneDidChange()
            return
        }
        if rotateAxisDragActive {
            // Angle already applied live; commit happens via Apply/empty tap.
            rotateAxisDragActive = false
            sceneDidChange()
            return
        }
        if sectionDragActive {
            sectionDragActive = false
            viewModel.endSectionDrag()
            sceneDidChange()
            return
        }
        if blendDragActive {
            blendDragActive = false
            viewModel.endBlendDrag()
            sceneDidChange()
            return
        }
        if pullActive {
            pullActive = false
            viewModel.endToolDrag()
            sceneDidChange()
            return
        }
        gizmoDrag = nil
        viewModel.gizmoHighlight = nil
        viewModel.endMove()
        sceneDidChange()
    }

    /// Long-press → Select Through popup (plan §B13, spec §8.3).
    func gestureLongPressed(at point: CGPoint) {
        guard let ray = ray(at: point) else { return }
        viewModel.presentSelectThrough(ray: ray)
    }

    /// World→screen projection for AreaSelect membership tests; nil for
    /// points behind the camera. Matches the renderer camera exactly (same
    /// view/projection matrices, ortho included — clip.w stays 1 there).
    private func worldToScreen(_ world: SIMD3<Float>) -> SIMD2<Double>? {
        guard let renderer, let view else { return nil }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let camera = renderer.camera
        let viewPoint = camera.viewMatrix * SIMD4(world, 1)
        guard viewPoint.z < 0 else { return nil } // behind the camera
        let aspect = Float(size.width / size.height)
        let clip = camera.projectionMatrix(aspect: aspect) * viewPoint
        guard clip.w > 1e-9 else { return nil }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        return SIMD2(
            (Double(ndc.x) + 1) / 2 * Double(size.width),
            (1 - Double(ndc.y)) / 2 * Double(size.height)
        )
    }

    // MARK: - ViewportCameraControl

    func fitScene() {
        guard let renderer else { return }
        var target = renderer.camera
        if let bounds = renderer.scene.worldBounds {
            target.fit(boundsMin: bounds.min, boundsMax: bounds.max)
        } else {
            target = TurntableCamera()
        }
        cameraAnimator?.animate(to: target)
    }

    func fitTo(bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        guard let renderer else { return }
        var target = renderer.camera
        target.fit(boundsMin: bounds.min, boundsMax: bounds.max)
        cameraAnimator?.animate(to: target)
    }

    func animateToStandardView(_ standard: StandardView) {
        guard let renderer else { return }
        cameraAnimator?.animate(to: standard.applied(to: renderer.camera), duration: 0.4)
    }

    func setProjection(orthographic: Bool) {
        guard let renderer else { return }
        renderer.camera.projection = orthographic
            ? .orthographic
            : .perspective(fovY: TurntableCamera.defaultFovY)
        view?.setNeedsDisplay()
    }

    /// Degrees between the camera eye-line and the plane normal (either side).
    private func offAngleDegrees(to plane: SketchPlane) -> Double {
        guard let renderer else { return 0 }
        let camera = renderer.camera
        let eyeOffset = camera.position - camera.target
        guard simd_length(eyeOffset) > 1e-6 else { return 0 }
        let eye = simd_normalize(eyeOffset)
        let n = plane.normal
        let normal = simd_normalize(SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z)))
        let alignment = min(abs(simd_dot(eye, normal)), 1)
        return Double(acos(alignment)) * 180 / .pi
    }

    /// Show Look-at-Sketch while sketching with the camera >10° off head-on.
    private func cameraDidMove() {
        let available: Bool
        if let plane = viewModel.activeSketch?.plane {
            available = offAngleDegrees(to: plane) > EditorViewModel.lookAtSketchThresholdDegrees
        } else {
            available = false
        }
        if viewModel.lookAtSketchAvailable != available {
            viewModel.lookAtSketchAvailable = available
        }
        // Let SwiftUI overlays that reproject world points (dimension labels,
        // plan §C2) re-run their layout as the camera moves.
        viewModel.cameraEpoch &+= 1
    }

    /// Degrees between the camera eye-line and `plane`'s normal — 0 head-on,
    /// 90 edge-on. Used by sketch entry to decide whether the current view is
    /// usable to draw in, and by the Look at Sketch button's visibility.
    func offAxisDegrees(to plane: SketchPlane) -> Double {
        offAngleDegrees(to: plane)
    }

    func orientationCubeLabels() -> [OrientationCube.FaceLabel] {
        guard let renderer, let view else { return [] }
        return OrientationCube.faceLabels(
            camera: renderer.camera, viewSize: view.bounds.size)
    }

    /// World→screen projection for SwiftUI overlays (dimension labels).
    /// Mirrors the private `worldToScreen`, taking Double world coordinates.
    func worldToScreenPoint(_ world: SIMD3<Double>) -> CGPoint? {
        guard let p = worldToScreen(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
        else { return nil }
        return CGPoint(x: p.x, y: p.y)
    }

    func gizmoWorldScale(at origin: SIMD3<Float>) -> Float {
        renderer?.gizmoScale(origin: origin) ?? 1
    }

    func moveCameraHeadOn(to plane: SketchPlane) {
        guard let renderer else { return }
        var target = renderer.camera
        let origin = plane.origin
        let originF = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))
        let n = plane.normal
        var normal = simd_normalize(SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z)))
        // Keep the camera on its current side of the plane.
        if simd_dot(normal, renderer.camera.position - originF) < 0 {
            normal = -normal
        }
        // Turntable angles that put the eye along the plane normal; vertical
        // planes clamp at the elevation limit (top/bottom-down views).
        target.elevation = min(
            max(asin(min(max(normal.y, -1), 1)), -TurntableCamera.elevationLimit),
            TurntableCamera.elevationLimit
        )
        target.azimuth = (abs(normal.x) + abs(normal.z)) > 1e-5 ? atan2(normal.x, normal.z) : 0
        target.target = originF
        target.distance = max(renderer.camera.distance, 14)
        cameraAnimator?.animate(to: target, duration: 0.4)
    }
}
