//
//  SnapEngine.swift
//  openshape3d
//
//  Sketch-space snapping: existing endpoints/centers first, then the grid.
//

import Foundation
import simd

nonisolated struct SnapResult {
    var point: SIMD2<Double>
    var snappedToPoint: Bool
}

nonisolated enum SnapEngine {
    static let gridSpacing: Double = 0.5
    static let pointTolerance: Double = 0.35

    static func snap(_ p: SIMD2<Double>, in sketch: Sketch?) -> SnapResult {
        // 1. Existing sketch points win.
        if let sketch {
            var best: (point: SIMD2<Double>, distance: Double)?
            for candidate in snapPoints(of: sketch) {
                let d = simd_length(candidate - p)
                if d <= pointTolerance, best == nil || d < best!.distance {
                    best = (candidate, d)
                }
            }
            if let best {
                return SnapResult(point: best.point, snappedToPoint: true)
            }
        }
        // 2. Grid.
        let snapped = SIMD2(
            (p.x / gridSpacing).rounded() * gridSpacing,
            (p.y / gridSpacing).rounded() * gridSpacing
        )
        return SnapResult(point: snapped, snappedToPoint: false)
    }

    static func snapPoints(of sketch: Sketch) -> [SIMD2<Double>] {
        var points: [SIMD2<Double>] = []
        for entity in sketch.entities {
            switch entity {
            case let .line(_, a, b):
                points.append(a)
                points.append(b)
            case let .rect(_, lo, hi):
                points.append(lo)
                points.append(hi)
                points.append(SIMD2(lo.x, hi.y))
                points.append(SIMD2(hi.x, lo.y))
            case let .circle(_, center, _):
                points.append(center)
            }
        }
        return points
    }
}
