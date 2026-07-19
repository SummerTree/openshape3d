//
//  ViewportGestureController.swift
//  openshape3d
//
//  Owns all viewport gesture recognizers and routes them. Navigation rules
//  (Shapr3D conventions):
//  - Two-finger pan and pinch ALWAYS navigate, in every mode.
//  - One-finger (finger, not Pencil) drag: mode-dependent; orbit by default.
//  - Pencil never orbits — it draws (sketch mode) or precision-selects.
//    Pencil drags reach the delegate (sketch strokes, pulls); if unclaimed
//    they do nothing rather than falling back to orbit.
//

import Foundation
import UIKit
import MetalKit

@MainActor
protocol ViewportGestureDelegate: AnyObject {
    func gestureTapped(at point: CGPoint)
    func gestureDoubleTapped(at point: CGPoint)
    /// Offered the one-finger drag at `.began`. Return true to claim it
    /// (gizmo drag, sketch stroke); false lets the camera orbit.
    func gestureDragBegan(at point: CGPoint) -> Bool
    func gestureDragChanged(at point: CGPoint)
    func gestureDragEnded(at point: CGPoint)
}

final class ViewportGestureController: NSObject {
    weak var view: MTKView?
    weak var renderer: Renderer?
    weak var delegate: ViewportGestureDelegate?

    /// Fired whenever a navigation gesture moved the camera (orbit/pan/zoom).
    var cameraChanged: (() -> Void)?

    private var lastPanLocation: CGPoint = .zero
    private var lastTwoFingerLocation: CGPoint = .zero
    private weak var orbitRecognizer: UIPanGestureRecognizer?
    /// Set in shouldReceive: the one-finger drag is being driven by the Pencil.
    private var orbitTouchIsPencil = false

    func attach(to view: MTKView, renderer: Renderer) {
        self.view = view
        self.renderer = renderer

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        orbit.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        orbit.delegate = self
        orbitRecognizer = orbit
        view.addGestureRecognizer(orbit)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        view.addGestureRecognizer(twoFingerPan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
    }

    private func redraw() {
        view?.setNeedsDisplay()
    }

    // MARK: - Handlers

    private var dragClaimed = false

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        guard let view, let renderer else { return }
        let location = gesture.location(in: view)
        switch gesture.state {
        case .began:
            lastPanLocation = location
            dragClaimed = delegate?.gestureDragBegan(at: location) ?? false
        case .changed:
            if dragClaimed {
                delegate?.gestureDragChanged(at: location)
                redraw()
            } else if orbitTouchIsPencil {
                // Pencil never orbits (spec §7.1) — unclaimed pencil drags
                // are dropped instead of moving the camera.
            } else {
                let delta = CGSize(
                    width: location.x - lastPanLocation.x,
                    height: location.y - lastPanLocation.y
                )
                lastPanLocation = location
                renderer.camera.orbit(deltaPixels: delta, viewportSize: view.bounds.size)
                redraw()
                cameraChanged?()
            }
        case .ended, .cancelled, .failed:
            if dragClaimed {
                delegate?.gestureDragEnded(at: location)
                dragClaimed = false
                redraw()
            }
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view, let renderer else { return }
        let location = gesture.location(in: view)
        switch gesture.state {
        case .began:
            lastTwoFingerLocation = location
        case .changed:
            let delta = CGSize(
                width: location.x - lastTwoFingerLocation.x,
                height: location.y - lastTwoFingerLocation.y
            )
            lastTwoFingerLocation = location
            renderer.camera.pan(deltaPixels: delta, viewportSize: view.bounds.size)
            redraw()
            cameraChanged?()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let renderer else { return }
        switch gesture.state {
        case .changed:
            renderer.camera.zoom(scale: Float(gesture.scale))
            gesture.scale = 1
            redraw()
            cameraChanged?()
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view else { return }
        delegate?.gestureTapped(at: gesture.location(in: view))
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let view else { return }
        delegate?.gestureDoubleTapped(at: gesture.location(in: view))
    }
}

extension ViewportGestureController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Two-finger pan and pinch combine into a single pan+zoom feel.
        // (The one-finger orbit recognizer never runs simultaneously: it is
        // single-touch, so the pinch cannot coexist with it.)
        (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === orbitRecognizer {
            orbitTouchIsPencil = touch.type == .pencil
        }
        return true
    }
}
