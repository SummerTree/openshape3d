//
//  Camera.swift
//  openshape3d
//
//  Turntable camera (stable Y-up, the CAD convention): orbit azimuth/elevation
//  around a target, dolly by distance, pan moves the target in the view plane.
//

import Foundation
import simd

nonisolated struct TurntableCamera: Sendable, Equatable {
    var target: SIMD3<Float> = .zero
    var distance: Float = 12
    var azimuth: Float = .pi / 5      // radians around +Y, 0 looks down -Z
    var elevation: Float = .pi / 7    // radians above the ground plane
    var fovY: Float = 40 * .pi / 180

    static let elevationLimit: Float = 89 * .pi / 180

    var position: SIMD3<Float> {
        let ce = cos(elevation)
        let offset = SIMD3(
            ce * sin(azimuth),
            sin(elevation),
            ce * cos(azimuth)
        ) * distance
        return target + offset
    }

    var viewMatrix: simd_float4x4 {
        Matrices.lookAt(eye: position, target: target, up: SIMD3(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        // Near/far scaled to distance keeps depth precision sane whether the
        // model is 5mm or 5m.
        let near = max(0.01, distance * 0.01)
        let far = max(100, distance * 40)
        return Matrices.perspective(fovYRadians: fovY, aspect: aspect, near: near, far: far)
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        projectionMatrix(aspect: aspect) * viewMatrix
    }

    // MARK: - Navigation

    mutating func orbit(deltaPixels: CGSize, viewportSize: CGSize) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let sensitivity: Float = 2 * .pi / Float(min(viewportSize.width, viewportSize.height))
        azimuth -= Float(deltaPixels.width) * sensitivity
        elevation += Float(deltaPixels.height) * sensitivity
        elevation = min(max(elevation, -Self.elevationLimit), Self.elevationLimit)
    }

    mutating func pan(deltaPixels: CGSize, viewportSize: CGSize) {
        guard viewportSize.height > 0 else { return }
        // World-units-per-pixel at the target depth.
        let worldPerPixel = 2 * distance * tan(fovY * 0.5) / Float(viewportSize.height)
        let view = viewMatrix
        // View matrix rows give camera basis vectors in world space.
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        target -= right * Float(deltaPixels.width) * worldPerPixel
        target += up * Float(deltaPixels.height) * worldPerPixel
    }

    mutating func zoom(scale: Float) {
        guard scale > 0 else { return }
        distance = min(max(distance / scale, 0.05), 2000)
    }

    /// Ray through a screen point (points, UIKit top-left origin).
    func ray(through point: CGPoint, viewportSize: CGSize) -> Ray {
        let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
        let ndcX = Float(point.x / viewportSize.width) * 2 - 1
        let ndcY = 1 - Float(point.y / viewportSize.height) * 2
        let inverseVP = simd_inverse(viewProjection(aspect: aspect))
        let nearPoint = inverseVP * SIMD4(ndcX, ndcY, 0, 1)
        let farPoint = inverseVP * SIMD4(ndcX, ndcY, 1, 1)
        let near3 = SIMD3(nearPoint.x, nearPoint.y, nearPoint.z) / nearPoint.w
        let far3 = SIMD3(farPoint.x, farPoint.y, farPoint.z) / farPoint.w
        return Ray(origin: near3, direction: simd_normalize(far3 - near3))
    }

    /// Frame the given world-space AABB, keeping the current orientation.
    mutating func fit(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) {
        let center = (boundsMin + boundsMax) * 0.5
        let radius = max(simd_length(boundsMax - boundsMin) * 0.5, 0.5)
        target = center
        distance = radius / tan(fovY * 0.5) * 1.35
    }
}
