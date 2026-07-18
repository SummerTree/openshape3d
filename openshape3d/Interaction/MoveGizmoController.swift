//
//  MoveGizmoController.swift
//  openshape3d
//
//  Move gizmo interaction: analytic hit-testing of axis arrows and plane
//  handles (in gizmo-local space), and drag math that turns rays into
//  translation deltas.
//

import Foundation
import simd

nonisolated enum GizmoPart: CaseIterable, Equatable {
    case xAxis, yAxis, zAxis
    case xyPlane, yzPlane, zxPlane

    var axisDirection: SIMD3<Float> {
        switch self {
        case .xAxis: SIMD3(1, 0, 0)
        case .yAxis: SIMD3(0, 1, 0)
        case .zAxis: SIMD3(0, 0, 1)
        case .yzPlane: SIMD3(1, 0, 0)
        case .zxPlane: SIMD3(0, 1, 0)
        case .xyPlane: SIMD3(0, 0, 1)
        }
    }

    var isPlane: Bool {
        switch self {
        case .xyPlane, .yzPlane, .zxPlane: true
        default: false
        }
    }
}

/// Gizmo state rendered by the viewport and hit by drags.
nonisolated struct GizmoState: Equatable {
    var origin: SIMD3<Float>
    /// World-units-per-gizmo-unit, chosen for constant on-screen size.
    var scale: Float
    var highlighted: GizmoPart?
}

nonisolated enum GizmoGeometry {
    /// Hit radius around an axis arrow, in gizmo units (inflated for touch).
    static let axisHitRadius: Float = 0.14
    static let axisLength: Float = 1.0
    /// Plane handles span [planeMin, planeMax]² on their plane.
    static let planeMin: Float = 0.18
    static let planeMax: Float = 0.48

    /// Nearest gizmo part hit by the ray, if any. Ray and state in world space.
    static func hitTest(ray: Ray, gizmo: GizmoState) -> GizmoPart? {
        // Work in gizmo space: unit scale, origin at zero.
        let localOrigin = (ray.origin - gizmo.origin) / gizmo.scale
        let localRay = Ray(origin: localOrigin, direction: ray.direction)

        var best: (part: GizmoPart, t: Float)?

        // Plane handles first — they sit inside the arrows and are easier to
        // hit accidentally with the capsule test otherwise.
        for part in GizmoPart.allCases where part.isPlane {
            let normal = part.axisDirection
            if let t = localRay.intersect(planePoint: .zero, planeNormal: normal) {
                let p = localRay.point(at: t)
                let coords = planeCoordinates(of: p, normal: part)
                if coords.x >= planeMin, coords.x <= planeMax,
                   coords.y >= planeMin, coords.y <= planeMax {
                    if best == nil || t < best!.t {
                        best = (part, t)
                    }
                }
            }
        }

        for part in [GizmoPart.xAxis, .yAxis, .zAxis] {
            if let t = distanceAlongRayToAxisCapsule(ray: localRay, axis: part.axisDirection) {
                if best == nil || t < best!.t {
                    best = (part, t)
                }
            }
        }
        return best?.part
    }

    private static func planeCoordinates(of p: SIMD3<Float>, normal part: GizmoPart) -> SIMD2<Float> {
        switch part {
        case .xyPlane: SIMD2(p.x, p.y)
        case .yzPlane: SIMD2(p.y, p.z)
        case .zxPlane: SIMD2(p.z, p.x)
        default: .zero
        }
    }

    /// Ray-vs-capsule around the axis segment [0, axisLength].
    private static func distanceAlongRayToAxisCapsule(ray: Ray, axis: SIMD3<Float>) -> Float? {
        // Closest points between the ray and the axis line.
        let w0 = ray.origin
        let a = simd_dot(ray.direction, ray.direction)
        let b = simd_dot(ray.direction, axis)
        let c = simd_dot(axis, axis)
        let d = simd_dot(ray.direction, w0)
        let e = simd_dot(axis, w0)
        let denom = a * c - b * b
        guard abs(denom) > 1e-9 else { return nil }
        var tRay = (b * e - c * d) / denom
        var tAxis = (a * e - b * d) / denom
        tAxis = min(max(tAxis, 0), axisLength)
        // Re-project for the clamped axis point.
        tRay = simd_dot(axis * tAxis - w0, ray.direction) / a
        guard tRay > 0 else { return nil }
        let separation = simd_length(w0 + ray.direction * tRay - axis * tAxis)
        return separation <= axisHitRadius ? tRay : nil
    }
}

/// One in-flight gizmo drag: anchors on begin, yields world-space translation
/// deltas as the ray moves.
nonisolated struct GizmoDragSession {
    let part: GizmoPart
    let startOrigin: SIMD3<Float>
    private let anchor: SIMD3<Float>

    init?(part: GizmoPart, gizmo: GizmoState, ray: Ray) {
        self.part = part
        self.startOrigin = gizmo.origin
        guard let anchor = Self.constrainedPoint(part: part, origin: gizmo.origin, ray: ray) else {
            return nil
        }
        self.anchor = anchor
    }

    func translationDelta(for ray: Ray) -> SIMD3<Float>? {
        guard let current = Self.constrainedPoint(part: part, origin: startOrigin, ray: ray) else {
            return nil
        }
        return current - anchor
    }

    /// Point on the drag constraint (axis line or plane) nearest to the ray.
    private static func constrainedPoint(
        part: GizmoPart, origin: SIMD3<Float>, ray: Ray
    ) -> SIMD3<Float>? {
        if part.isPlane {
            guard let t = ray.intersect(planePoint: origin, planeNormal: part.axisDirection) else {
                return nil
            }
            return ray.point(at: t)
        }
        // Closest point on the axis line to the ray.
        let axis = part.axisDirection
        let w0 = ray.origin - origin
        let a = simd_dot(ray.direction, ray.direction)
        let b = simd_dot(ray.direction, axis)
        let c = simd_dot(axis, axis)
        let d = simd_dot(ray.direction, w0)
        let e = simd_dot(axis, w0)
        let denom = a * c - b * b
        guard abs(denom) > 1e-6 else { return nil } // ray parallel to axis
        let tAxis = (a * e - b * d) / denom
        return origin + axis * tAxis
    }
}
