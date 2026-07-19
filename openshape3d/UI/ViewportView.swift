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

    func gestureTapped(at point: CGPoint) {
        // Orientation cube first: taps on it never reach the model.
        if let renderer, let view,
           let pose = OrientationCube.hitPose(
               at: point, camera: renderer.camera, viewSize: view.bounds.size
           ) {
            cameraAnimator?.animate(to: pose, duration: 0.4)
            return
        }
        guard let ray = ray(at: point) else { return }
        // Tapping (not dragging) a gizmo arrow opens exact-distance entry.
        if let part = gizmoPart(under: ray), part.isArrow {
            viewModel.beginAxisDistanceEntry(part)
            sceneDidChange()
            return
        }
        viewModel.handle(.tap(ray: ray))
    }

    private func gizmoPart(under ray: Ray) -> GizmoPart? {
        guard let renderer, let origin = viewModel.gizmoOrigin else { return nil }
        let gizmo = GizmoState(
            origin: origin,
            scale: renderer.gizmoScale(origin: origin),
            highlighted: nil
        )
        return GizmoGeometry.hitTest(ray: ray, gizmo: gizmo)
    }

    func gestureDoubleTapped(at point: CGPoint) {
        guard let ray = ray(at: point) else { return }
        viewModel.handle(.doubleTap(ray: ray))
    }

    func gestureDragBegan(at point: CGPoint) -> Bool {
        guard let ray = ray(at: point) else { return false }
        dragStartPoint = point
        pullActive = false

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

        // Choosing a sketch plane: taps pick, drags orbit.
        if case .pickingSketchPlane = viewModel.mode {
            return false
        }

        // Face selected: dragging the face pushes/pulls it.
        if case .faceSelected = viewModel.mode {
            pullActive = viewModel.beginFacePull(ray: ray)
            if pullActive { return true }
            // Fall through — drags off the face orbit.
        }

        // Offer the drag to the gizmo when a body is selected.
        if let renderer, let origin = viewModel.gizmoOrigin {
            let gizmo = GizmoState(
                origin: origin,
                scale: renderer.gizmoScale(origin: origin),
                highlighted: nil
            )
            if let part = GizmoGeometry.hitTest(ray: ray, gizmo: gizmo),
               let session = GizmoDragSession(part: part, gizmo: gizmo, ray: ray) {
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
        guard let ray = ray(at: point) else { return }
        if viewModel.mode.isSketching {
            viewModel.updateSketchStroke(ray: ray)
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
        if viewModel.mode.isSketching, let ray = ray(at: point) {
            viewModel.endSketchStroke(ray: ray)
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
            available = offAngleDegrees(to: plane) > 10
        } else {
            available = false
        }
        if viewModel.lookAtSketchAvailable != available {
            viewModel.lookAtSketchAvailable = available
        }
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
