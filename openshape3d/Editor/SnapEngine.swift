//
//  SnapEngine.swift
//  openshape3d
//
//  Sketch-space snapping: existing endpoints/centers first, then the grid.
//

import Foundation
import simd

/// What a snap latched onto. Shapr3D names the snap on screen while you draw
/// ("Endpoint", "Midpoint", …), which is how you know the point you are about
/// to commit is the one you meant rather than a near miss.
nonisolated enum SnapKind: String, Sendable, Equatable, CaseIterable {
    case endpoint, midpoint, center, grid, free

    /// User-facing name, or nil for snaps not worth announcing — the grid is
    /// always on, so labelling it would just add noise to every stroke.
    var label: String? {
        switch self {
        case .endpoint: "Endpoint"
        case .midpoint: "Midpoint"
        case .center: "Center"
        case .grid, .free: nil
        }
    }
}

nonisolated struct SnapResult {
    var point: SIMD2<Double>
    var kind: SnapKind

    /// True when the point came from existing geometry rather than the grid.
    var snappedToPoint: Bool {
        switch kind {
        case .endpoint, .midpoint, .center: true
        case .grid, .free: false
        }
    }
}

/// One snappable point on existing geometry, with what it is.
nonisolated struct SnapCandidate {
    var point: SIMD2<Double>
    var kind: SnapKind
}

nonisolated enum SnapEngine {
    static let gridSpacing: Double = 0.5
    static let pointTolerance: Double = 0.35

    /// Ranking when several candidates are in range. An endpoint is a harder
    /// commitment than a midpoint, and both beat a centre, so a tie near a
    /// corner resolves the way the user expects instead of by float noise.
    private static func priority(_ kind: SnapKind) -> Int {
        switch kind {
        case .endpoint: 3
        case .midpoint: 2
        case .center: 1
        case .grid, .free: 0
        }
    }

    static func snap(_ p: SIMD2<Double>, in sketch: Sketch?) -> SnapResult {
        // 1. Existing sketch points win.
        if let sketch {
            var best: (candidate: SnapCandidate, distance: Double)?
            for candidate in snapCandidates(of: sketch) {
                let d = simd_length(candidate.point - p)
                guard d <= pointTolerance else { continue }
                if let current = best {
                    let better = priority(candidate.kind) > priority(current.candidate.kind)
                        || (priority(candidate.kind) == priority(current.candidate.kind)
                            && d < current.distance)
                    if !better { continue }
                }
                best = (candidate, d)
            }
            if let best {
                return SnapResult(point: best.candidate.point, kind: best.candidate.kind)
            }
        }
        // 2. Grid.
        let snapped = SIMD2(
            (p.x / gridSpacing).rounded() * gridSpacing,
            (p.y / gridSpacing).rounded() * gridSpacing
        )
        return SnapResult(point: snapped, kind: .grid)
    }

    /// Every snappable point, untyped — kept for callers that only need
    /// positions (hit-testing, tests).
    static func snapPoints(of sketch: Sketch) -> [SIMD2<Double>] {
        snapCandidates(of: sketch).map(\.point)
    }

    /// Every snappable point with what it is.
    static func snapCandidates(of sketch: Sketch) -> [SnapCandidate] {
        var out: [SnapCandidate] = []
        func add(_ p: SIMD2<Double>, _ kind: SnapKind) {
            out.append(SnapCandidate(point: p, kind: kind))
        }
        for entity in sketch.entities {
            switch entity {
            case let .line(_, a, b):
                add(a, .endpoint)
                add(b, .endpoint)
                add((a + b) / 2, .midpoint)
            case let .rect(_, lo, hi):
                let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
                for corner in corners { add(corner, .endpoint) }
                // Edge midpoints: Shapr3D snaps to them, and centring geometry
                // on a face is the common reason to reach for one.
                for i in 0..<corners.count {
                    add((corners[i] + corners[(i + 1) % corners.count]) / 2, .midpoint)
                }
                add((lo + hi) / 2, .center)
            case let .circle(_, center, _):
                add(center, .center)
            case let .arc(_, center, radius, startAngle, endAngle):
                add(center, .center)
                add(SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle), .endpoint)
                add(SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle), .endpoint)
                let mid = startAngle + SketchEntity.arcSweep(
                    startAngle: startAngle, endAngle: endAngle) / 2
                add(SketchEntity.arcPoint(center: center, radius: radius, angle: mid), .midpoint)
            case let .ellipse(_, center, _, _, _):
                add(center, .center)
            case let .polygon(_, center, radius, sides, rotation):
                add(center, .center)
                for vertex in SketchEntity.polygonPoints(
                    center: center, radius: radius, sides: sides, rotation: rotation
                ) { add(vertex, .endpoint) }
            case let .spline(_, splinePoints, _):
                // Snap to the FIT points the user placed, not the tessellation —
                // those are the notable points of a spline (spec §2.7).
                for point in splinePoints { add(point, .endpoint) }
            }
        }
        return out
    }
}
