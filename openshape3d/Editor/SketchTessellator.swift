//
//  SketchTessellator.swift
//  openshape3d
//
//  Turns sketch entities (plane-local 2D) into world-space line segments for
//  the viewport overlay.
//

import Foundation
import simd
import Euclid

nonisolated enum SketchTessellator {
    static let circleSegments = 64

    /// Triangulated fill for a closed profile (holes cut out), as world-space
    /// triangles for the viewport overlay. This is the Shapr3D "fill color"
    /// affordance showing a region can be pulled into 3D.
    static func fillTriangles(
        for profile: Profile,
        holes: [Profile],
        on plane: SketchPlane
    ) -> [SIMD3<Float>] {
        var paths = [KernelOps.closedPath(for: profile)]
        paths.append(contentsOf: holes.map { KernelOps.closedPath(for: $0) })
        let mesh = Euclid.Mesh.fill(paths).triangulate()
        let transform = KernelOps.planeToWorld(plane)

        var out: [SIMD3<Float>] = []
        for polygon in mesh.polygons {
            // fill() creates front and back faces; keep the front (+z) only.
            guard polygon.plane.normal.z > 0 else { continue }
            for vertex in polygon.vertices {
                let world = vertex.position.transformed(by: transform)
                out.append(SIMD3(Float(world.x), Float(world.y), Float(world.z)))
            }
        }
        return out
    }

    static func segments(for entities: [SketchEntity], on plane: SketchPlane) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                appendSegment(a, b, plane, &out)
            case let .rect(_, lo, hi):
                let c0 = lo
                let c1 = SIMD2(hi.x, lo.y)
                let c2 = hi
                let c3 = SIMD2(lo.x, hi.y)
                appendSegment(c0, c1, plane, &out)
                appendSegment(c1, c2, plane, &out)
                appendSegment(c2, c3, plane, &out)
                appendSegment(c3, c0, plane, &out)
            case let .circle(_, center, radius):
                var previous = center + SIMD2(radius, 0)
                for i in 1...circleSegments {
                    let angle = Double(i) / Double(circleSegments) * 2 * .pi
                    let point = center + SIMD2(cos(angle), sin(angle)) * radius
                    appendSegment(previous, point, plane, &out)
                    previous = point
                }
            case let .arc(_, center, radius, startAngle, endAngle):
                let points = SketchEntity.arcPoints(
                    center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle,
                    segmentsPerTurn: circleSegments
                )
                appendPolyline(points, closed: false, plane, &out)
            case let .ellipse(_, center, radiusX, radiusY, rotation):
                let points = SketchEntity.ellipsePoints(
                    center: center, radiusX: radiusX, radiusY: radiusY,
                    rotation: rotation, segments: circleSegments
                )
                appendPolyline(points, closed: true, plane, &out)
            case let .polygon(_, center, radius, sides, rotation):
                let points = SketchEntity.polygonPoints(
                    center: center, radius: radius, sides: sides, rotation: rotation
                )
                appendPolyline(points, closed: true, plane, &out)
            }
        }
        return out
    }

    private static func appendPolyline(
        _ points: [SIMD2<Double>], closed: Bool,
        _ plane: SketchPlane, _ out: inout [SIMD3<Float>]
    ) {
        guard points.count >= 2 else { return }
        for i in 1..<points.count {
            appendSegment(points[i - 1], points[i], plane, &out)
        }
        if closed {
            appendSegment(points[points.count - 1], points[0], plane, &out)
        }
    }

    private static func appendSegment(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>,
        _ plane: SketchPlane, _ out: inout [SIMD3<Float>]
    ) {
        let wa = plane.toWorld(a)
        let wb = plane.toWorld(b)
        out.append(SIMD3(Float(wa.x), Float(wa.y), Float(wa.z)))
        out.append(SIMD3(Float(wb.x), Float(wb.y), Float(wb.z)))
    }
}
