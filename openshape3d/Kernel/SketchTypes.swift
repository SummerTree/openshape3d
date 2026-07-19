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
    /// Circular arc swept counterclockwise from `startAngle` to `endAngle`
    /// (radians; sweep normalized into [0, 2π)).
    case arc(id: UUID, center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double)
    /// Axis-aligned radii rotated by `rotation` (radians) about `center`.
    case ellipse(id: UUID, center: SIMD2<Double>, radiusX: Double, radiusY: Double, rotation: Double)
    /// Regular n-gon: `sides` vertices on the circumscribed circle of `radius`,
    /// first vertex at angle `rotation`.
    case polygon(id: UUID, center: SIMD2<Double>, radius: Double, sides: Int, rotation: Double)

    var id: UUID {
        switch self {
        case let .line(id, _, _), let .rect(id, _, _), let .circle(id, _, _),
             let .arc(id, _, _, _, _), let .ellipse(id, _, _, _, _),
             let .polygon(id, _, _, _, _):
            id
        }
    }
}

// MARK: - Shared point generation (tessellation + snapping)

nonisolated extension SketchEntity {
    /// CCW sweep from `startAngle` to `endAngle`, normalized into [0, 2π).
    static func arcSweep(startAngle: Double, endAngle: Double) -> Double {
        var sweep = (endAngle - startAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep < 0 { sweep += 2 * .pi }
        return sweep
    }

    static func arcPoint(center: SIMD2<Double>, radius: Double, angle: Double) -> SIMD2<Double> {
        center + SIMD2(cos(angle), sin(angle)) * radius
    }

    /// Polyline along the arc, both endpoints included; density is
    /// `segmentsPerTurn` scaled by the swept fraction of a full turn.
    /// Empty for degenerate arcs (zero sweep or radius).
    static func arcPoints(
        center: SIMD2<Double>, radius: Double,
        startAngle: Double, endAngle: Double,
        segmentsPerTurn: Int
    ) -> [SIMD2<Double>] {
        let sweep = arcSweep(startAngle: startAngle, endAngle: endAngle)
        guard sweep > 1e-9, radius > 1e-9 else { return [] }
        let count = max(2, Int((Double(segmentsPerTurn) * sweep / (2 * .pi)).rounded(.up)))
        return (0...count).map { i in
            arcPoint(center: center, radius: radius, angle: startAngle + sweep * Double(i) / Double(count))
        }
    }

    /// Closed CCW loop (first point not repeated at the end).
    static func ellipsePoints(
        center: SIMD2<Double>, radiusX: Double, radiusY: Double,
        rotation: Double, segments: Int
    ) -> [SIMD2<Double>] {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        return (0..<segments).map { i in
            let t = Double(i) / Double(segments) * 2 * .pi
            let local = SIMD2(cos(t) * radiusX, sin(t) * radiusY)
            return center + SIMD2(local.x * cosR - local.y * sinR, local.x * sinR + local.y * cosR)
        }
    }

    /// Vertices of the regular n-gon, CCW (first point not repeated).
    static func polygonPoints(
        center: SIMD2<Double>, radius: Double, sides: Int, rotation: Double
    ) -> [SIMD2<Double>] {
        guard sides >= 3 else { return [] }
        return (0..<sides).map { i in
            let angle = rotation + Double(i) / Double(sides) * 2 * .pi
            return center + SIMD2(cos(angle), sin(angle)) * radius
        }
    }
}

nonisolated struct Sketch: Identifiable, Codable, Equatable, Sendable {
    let id: SketchID
    var name: String
    var plane: SketchPlane
    var entities: [SketchEntity]
    /// Items Manager visibility (spec §11); sketches auto-hide once an
    /// extrude/revolve consumes them.
    var isHidden: Bool

    init(
        id: SketchID = SketchID(),
        name: String = "Sketch",
        plane: SketchPlane,
        entities: [SketchEntity] = [],
        isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.plane = plane
        self.entities = entities
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, plane, entities, isHidden
    }

    /// `name`/`isHidden` are optional on decode so pre-A8 documents load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SketchID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Sketch"
        plane = try container.decode(SketchPlane.self, forKey: .plane)
        entities = try container.decode([SketchEntity].self, forKey: .entities)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}
