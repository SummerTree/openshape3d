//
//  ProfileDetector.swift
//  openshape3d
//
//  Finds closed profiles in a sketch: circles/rects/ellipses/polygons directly,
//  and simple closed loops walked from line segments and arc chains (degree-2
//  nodes only in v1 — branching arrangements are a v2 problem). Nested profiles
//  are reported so the caller can treat them as holes.
//

import Foundation
import simd

nonisolated struct Profile: Identifiable {
    enum Kind {
        case polygonal
        case circle(center: SIMD2<Double>, radius: Double)
    }

    let id = UUID()
    /// Closed CCW polygon in plane-local coordinates (circles tessellated).
    var loop: [SIMD2<Double>]
    var kind: Kind
    var sourceEntityIDs: Set<UUID>

    /// Signed area (positive for CCW).
    var area: Double {
        Profile.signedArea(loop)
    }

    var centroid: SIMD2<Double> {
        guard !loop.isEmpty else { return .zero }
        return loop.reduce(SIMD2<Double>.zero, +) / Double(loop.count)
    }

    func contains(_ p: SIMD2<Double>) -> Bool {
        // Ray casting.
        var inside = false
        var j = loop.count - 1
        for i in 0..<loop.count {
            let a = loop[i]
            let b = loop[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func signedArea(_ loop: [SIMD2<Double>]) -> Double {
        var sum = 0.0
        var j = loop.count - 1
        for i in 0..<loop.count {
            sum += (loop[j].x * loop[i].y) - (loop[i].x * loop[j].y)
            j = i
        }
        return sum / 2
    }
}

nonisolated enum ProfileDetector {
    static let circleSegments = 48
    private static let quantum: Double = 1e-6

    static func detectProfiles(in sketch: Sketch) -> [Profile] {
        var profiles: [Profile] = []

        // Circles are always closed profiles.
        for entity in sketch.entities {
            if case let .circle(id, center, radius) = entity, radius > 1e-6 {
                let loop = (0..<circleSegments).map { i -> SIMD2<Double> in
                    let angle = Double(i) / Double(circleSegments) * 2 * .pi
                    return center + SIMD2(cos(angle), sin(angle)) * radius
                }
                profiles.append(Profile(
                    loop: loop, // CCW by construction
                    kind: .circle(center: center, radius: radius),
                    sourceEntityIDs: [id]
                ))
            }
        }

        // Rects are closed by definition; emit directly (CCW).
        for entity in sketch.entities {
            if case let .rect(id, lo, hi) = entity {
                let loop = [
                    lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y),
                ]
                profiles.append(Profile(loop: loop, kind: .polygonal, sourceEntityIDs: [id]))
            }
        }

        // Ellipses and polygons are closed profiles too (loops CCW by construction).
        for entity in sketch.entities {
            switch entity {
            case let .ellipse(id, center, radiusX, radiusY, rotation)
                where radiusX > 1e-6 && radiusY > 1e-6:
                let loop = SketchEntity.ellipsePoints(
                    center: center, radiusX: radiusX, radiusY: radiusY,
                    rotation: rotation, segments: circleSegments
                )
                profiles.append(Profile(loop: loop, kind: .polygonal, sourceEntityIDs: [id]))
            case let .polygon(id, center, radius, sides, rotation)
                where radius > 1e-6 && sides >= 3:
                let loop = SketchEntity.polygonPoints(
                    center: center, radius: radius, sides: sides, rotation: rotation
                )
                profiles.append(Profile(loop: loop, kind: .polygonal, sourceEntityIDs: [id]))
            default:
                break
            }
        }

        // Walk loops from line segments and arc chains.
        profiles.append(contentsOf: lineLoops(in: sketch))
        return profiles
    }

    /// Profiles fully containing `point`, smallest area first (innermost region).
    static func profiles(at point: SIMD2<Double>, in sketch: Sketch) -> [Profile] {
        detectProfiles(in: sketch)
            .filter { $0.contains(point) }
            .sorted { abs($0.area) < abs($1.area) }
    }

    /// Profiles from `all` strictly nested inside `outer` (used as holes).
    static func holes(of outer: Profile, among all: [Profile]) -> [Profile] {
        all.filter { candidate in
            candidate.id != outer.id
                && abs(candidate.area) < abs(outer.area)
                && outer.contains(candidate.centroid)
        }
    }

    // MARK: - Loop walking over line segments

    private struct NodeKey: Hashable {
        let x, y: Int64
        init(_ p: SIMD2<Double>) {
            x = Int64((p.x / ProfileDetector.quantum).rounded())
            y = Int64((p.y / ProfileDetector.quantum).rounded())
        }
    }

    private static func lineLoops(in sketch: Sketch) -> [Profile] {
        // A chain is one entity exploded to a polyline. Only its two ENDPOINTS
        // enter the node graph — tessellated interior points (arcs) are never
        // junction candidates; they are spliced into the loop when walked.
        struct Chain {
            let entityID: UUID
            let points: [SIMD2<Double>]
        }

        var chains: [Chain] = []
        for entity in sketch.entities {
            switch entity {
            case let .line(id, a, b) where simd_length(b - a) > 1e-9:
                chains.append(Chain(entityID: id, points: [a, b]))
            case let .arc(id, center, radius, startAngle, endAngle):
                let points = SketchEntity.arcPoints(
                    center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle,
                    segmentsPerTurn: circleSegments
                )
                if points.count >= 2 {
                    chains.append(Chain(entityID: id, points: points))
                }
            default:
                break
            }
        }
        guard chains.count >= 2 else { return [] }

        // Node table over chain endpoints only.
        var adjacency: [NodeKey: [(chain: Int, forward: Bool, other: NodeKey)]] = [:]
        for (index, chain) in chains.enumerated() {
            let ka = NodeKey(chain.points.first!)
            let kb = NodeKey(chain.points.last!)
            guard ka != kb else { continue }
            adjacency[ka, default: []].append((index, true, kb))
            adjacency[kb, default: []].append((index, false, ka))
        }

        var used = Set<Int>()
        var profiles: [Profile] = []

        for startIndex in chains.indices where !used.contains(startIndex) {
            let startKey = NodeKey(chains[startIndex].points[0])
            var loopChains: [Int] = []
            var loopPoints: [SIMD2<Double>] = []
            var current = startKey
            var closed = false

            // Follow the chain; abandon at junctions (degree != 2) or dead ends.
            while true {
                guard let neighbors = adjacency[current], neighbors.count == 2 || current == startKey else {
                    break
                }
                guard let next = neighbors.first(where: { !used.contains($0.chain) && !loopChains.contains($0.chain) }) else {
                    break
                }
                loopChains.append(next.chain)
                let points = chains[next.chain].points
                if next.forward {
                    loopPoints.append(contentsOf: points.dropLast())
                } else {
                    loopPoints.append(contentsOf: points.reversed().dropLast())
                }
                current = next.other
                if current == startKey {
                    closed = true
                    break
                }
                guard adjacency[current]?.count == 2 else { break }
                if loopChains.count > chains.count { break }
            }

            // Two chains can close a region (arc + line); pure line pairs are
            // rejected by the zero-area guard.
            guard closed, loopChains.count >= 2, loopPoints.count >= 3 else { continue }
            var loop = loopPoints
            guard abs(Profile.signedArea(loop)) > 1e-9 else { continue }

            // Orient CCW.
            if Profile.signedArea(loop) < 0 {
                loop.reverse()
            }
            guard !isSelfIntersecting(loop) else { continue }

            used.formUnion(loopChains)
            profiles.append(Profile(
                loop: loop,
                kind: .polygonal,
                sourceEntityIDs: Set(loopChains.map { chains[$0].entityID })
            ))
        }
        return profiles
    }

    private static func isSelfIntersecting(_ loop: [SIMD2<Double>]) -> Bool {
        let n = loop.count
        guard n > 3 else { return false }
        for i in 0..<n {
            let a1 = loop[i]
            let a2 = loop[(i + 1) % n]
            for j in (i + 1)..<n {
                // Skip adjacent segments (shared endpoints).
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                let b1 = loop[j]
                let b2 = loop[(j + 1) % n]
                if segmentsIntersect(a1, a2, b1, b2) {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ p1: SIMD2<Double>, _ p2: SIMD2<Double>,
        _ p3: SIMD2<Double>, _ p4: SIMD2<Double>
    ) -> Bool {
        func orientation(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
