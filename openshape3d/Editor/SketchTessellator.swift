//
//  SketchTessellator.swift
//  openshape3d
//
//  Turns sketch entities (plane-local 2D) into world-space line segments for
//  the viewport overlay.
//

import Foundation
import simd

nonisolated enum SketchTessellator {
    static let circleSegments = 64

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
            }
        }
        return out
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
