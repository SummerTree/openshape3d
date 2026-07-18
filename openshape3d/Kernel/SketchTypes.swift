//
//  SketchTypes.swift
//  openshape3d
//
//  2D sketching data. Entities live in plane-local coordinates (Double);
//  SketchPlane maps between plane space and world space.
//

import Foundation
import simd

nonisolated struct SketchPlane: Codable, Equatable, Sendable {
    var origin: SIMD3<Double>
    var xAxis: SIMD3<Double>
    var yAxis: SIMD3<Double>

    var normal: SIMD3<Double> { simd_cross(xAxis, yAxis) }

    /// Ground plane (XZ, Y up): sketch X → world X, sketch Y → world -Z so the
    /// sketch reads right-handed when viewed from +Y (top-down).
    static let ground = SketchPlane(
        origin: .zero,
        xAxis: SIMD3(1, 0, 0),
        yAxis: SIMD3(0, 0, -1)
    )

    static func offsetGround(y: Double) -> SketchPlane {
        SketchPlane(origin: SIMD3(0, y, 0), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1))
    }

    func toWorld(_ p: SIMD2<Double>) -> SIMD3<Double> {
        origin + xAxis * p.x + yAxis * p.y
    }

    func toLocal(_ world: SIMD3<Double>) -> SIMD2<Double> {
        let delta = world - origin
        return SIMD2(simd_dot(delta, xAxis), simd_dot(delta, yAxis))
    }
}

nonisolated enum SketchEntity: Identifiable, Codable, Equatable, Sendable {
    case line(id: UUID, a: SIMD2<Double>, b: SIMD2<Double>)
    case rect(id: UUID, min: SIMD2<Double>, max: SIMD2<Double>)
    case circle(id: UUID, center: SIMD2<Double>, radius: Double)

    var id: UUID {
        switch self {
        case let .line(id, _, _), let .rect(id, _, _), let .circle(id, _, _):
            id
        }
    }
}

nonisolated struct Sketch: Identifiable, Codable, Equatable, Sendable {
    let id: SketchID
    var plane: SketchPlane
    var entities: [SketchEntity]

    init(id: SketchID = SketchID(), plane: SketchPlane, entities: [SketchEntity] = []) {
        self.id = id
        self.plane = plane
        self.entities = entities
    }
}
