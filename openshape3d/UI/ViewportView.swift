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

        // Strong capture on purpose: the coordinator can be torn down before
        // the parent view's onDisappear, but the renderer stays usable for
        // offscreen thumbnail capture as long as the view model lives.
        viewModel.thumbnailProvider = { renderer.makeThumbnailPNG() }

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
    /// screen drags for the head-on pull fallback.
    private var worldPerPoint: Double {
        guard let renderer, let view, view.bounds.height > 0 else { return 0.01 }
        let camera = renderer.camera
        return Double(2 * camera.distance * tan(camera.fovY * 0.5))
            / Double(view.bounds.height)
    }

    func gestureTapped(at point: CGPoint) {
        guard let ray = ray(at: point) else { return }
        viewModel.handle(.tap(ray: ray))
    }

    func gestureDoubleTapped(at point: CGPoint) {
        viewModel.handle(.doubleTap)
    }

    func gestureDragBegan(at point: CGPoint) -> Bool {
        guard let ray = ray(at: point) else { return false }
        dragStartPoint = point

        // Sketch mode: one-finger drags draw.
        if viewModel.mode.isSketching {
            return viewModel.beginSketchStroke(ray: ray)
        }

        // Extruding: drags pull the profile along the plane normal.
        if case .extruding = viewModel.mode {
            return viewModel.beginExtrudeDrag(ray: ray)
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
        return viewModel.beginFillPull(ray: ray)
    }

    func gestureDragChanged(at point: CGPoint) {
        guard let ray = ray(at: point) else { return }
        if viewModel.mode.isSketching {
            viewModel.updateSketchStroke(ray: ray)
            sceneDidChange()
            return
        }
        if case .extruding = viewModel.mode {
            let screenDelta = Double(dragStartPoint.y - point.y) * worldPerPoint
            viewModel.updateExtrudeDrag(ray: ray, screenDeltaWorld: screenDelta)
            sceneDidChange()
            return
        }
        guard let session = gizmoDrag,
              let delta = session.translationDelta(for: ray)
        else { return }
        viewModel.updateMove(delta: delta)
        sceneDidChange()
    }

    func gestureDragEnded(at point: CGPoint) {
        if viewModel.mode.isSketching, let ray = ray(at: point) {
            viewModel.endSketchStroke(ray: ray)
            sceneDidChange()
            return
        }
        if case .extruding = viewModel.mode {
            viewModel.endExtrudeDrag()
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

    func moveCameraHeadOn(to plane: SketchPlane) {
        guard let renderer else { return }
        var target = renderer.camera
        // Ground plane head-on = top-down: elevation to the clamp limit,
        // azimuth to zero for a canonical orientation.
        target.elevation = TurntableCamera.elevationLimit
        target.azimuth = 0
        let origin = plane.origin
        target.target = SIMD3(Float(origin.x), Float(origin.y), Float(origin.z))
        target.distance = max(renderer.camera.distance, 14)
        cameraAnimator?.animate(to: target, duration: 0.4)
    }
}
