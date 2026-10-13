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
    case endpoint, midpoint, center, edge, grid, free

    /// User-facing name, or nil for snaps not worth announcing — the grid is
    /// too frequent to label on every stroke.
    var label: String? {
        switch self {
        case .endpoint: "Endpoint"
        case .midpoint: "Midpoint"
        case .center: "Center"
        case .edge: "Edge"
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
        case .endpoint, .midpoint, .center, .edge: true
        case .grid, .free: false
        }
    }
}

/// One snappable point on existing geometry, with what it is.
nonisolated struct SnapCandidate {
    var point: SIMD2<Double>
    var kind: SnapKind
}

/// Acquisition preferences, independent of whether inferred constraints are stored.
nonisolated struct SnapOptions: Equatable, Sendable {
    var grid = true
    var sketchGuidepoints = true
    var faceGuidepoints = true
    /// Snap to the edges of bodies away from the sketch plane, projected
    /// onto it (Shapr3D's "Distant Edges").
    var distantEdges = true
}

/// Body edges off the sketch plane, projected onto it: their corners, the
/// midpoints of straight runs, the centers of closed curves (a hole's rim
/// projects to its circle) and the straight runs themselves.
nonisolated struct DistantSnapGeometry: Equatable, Sendable {
    var corners: [SIMD2<Double>] = []
    var midpoints: [SIMD2<Double>] = []
    var centers: [SIMD2<Double>] = []
    var runs: [(SIMD2<Double>, SIMD2<Double>)] = []

    static let empty = DistantSnapGeometry()

    var isEmpty: Bool { corners.isEmpty && centers.isEmpty && runs.isEmpty }

    static func == (lhs: DistantSnapGeometry, rhs: DistantSnapGeometry) -> Bool {
        lhs.corners == rhs.corners && lhs.midpoints == rhs.midpoints && lhs.centers == rhs.centers
            && lhs.runs.count == rhs.runs.count
            && zip(lhs.runs, rhs.runs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// Chain world-space edge segments (pairs) into polylines, split them at
    /// sharp turns, and project onto `plane`. Tessellated curves stay one
    /// polyline, so a circle offers its center rather than dozens of
    /// facet corners.
    static func build(segments: [SIMD3<Double>], plane: SketchPlane,
                      cornerAngleDegrees: Double = 25) -> DistantSnapGeometry {
        var geometry = DistantSnapGeometry()
        guard segments.count >= 2 else { return geometry }
        // Weld endpoints.
        var ids: [SIMD3<Int64>: Int] = [:]
        var points: [SIMD3<Double>] = []
        func id(_ p: SIMD3<Double>) -> Int {
            let key = SIMD3(MeshQuantize.key64(p.x, inverseQuantum: 1e5),
                            MeshQuantize.key64(p.y, inverseQuantum: 1e5),
                            MeshQuantize.key64(p.z, inverseQuantum: 1e5))
            if let existing = ids[key] { return existing }
            ids[key] = points.count
            points.append(p)
            return points.count - 1
        }
        var adjacency: [Int: [Int]] = [:]
        var edges = Set<SIMD2<Int>>()
        var i = 0
        while i + 1 < segments.count {
            let a = id(segments[i]), b = id(segments[i + 1])
            i += 2
            guard a != b, edges.insert(SIMD2(min(a, b), max(a, b))).inserted else { continue }
            adjacency[a, default: []].append(b)
            adjacency[b, default: []].append(a)
        }
        // Walk polylines: from every non-degree-2 vertex first, then the
        // remaining closed loops.
        var used = Set<SIMD2<Int>>()
        func key(_ a: Int, _ b: Int) -> SIMD2<Int> { SIMD2(min(a, b), max(a, b)) }
        var chains: [(points: [Int], closed: Bool)] = []
        func walk(from start: Int, via next: Int) -> [Int] {
            var chain = [start, next]
            used.insert(key(start, next))
            var previous = start, current = next
            while adjacency[current, default: []].count == 2 {
                guard let step = adjacency[current]!.first(where: { $0 != previous && !used.contains(key(current, $0)) })
                else { break }
                used.insert(key(current, step))
                chain.append(step)
                previous = current
                current = step
            }
            return chain
        }
        let order = adjacency.keys.sorted()
        for v in order where adjacency[v]!.count != 2 {
            for n in adjacency[v]! where !used.contains(key(v, n)) {
                chains.append((walk(from: v, via: n), false))
            }
        }
        for v in order {
            for n in adjacency[v]! where !used.contains(key(v, n)) {
                var chain = walk(from: v, via: n)
                let closed = chain.count > 3 && chain.last == chain.first
                if closed { chain.removeLast() }
                chains.append((chain, closed))
            }
        }

        let cosCorner = cos(cornerAngleDegrees * .pi / 180)
        var cornerKeys = Set<SIMD2<Int64>>()
        func addCorner(_ p: SIMD2<Double>) {
            let k = SIMD2(MeshQuantize.key64(p.x, inverseQuantum: 1e4), MeshQuantize.key64(p.y, inverseQuantum: 1e4))
            if cornerKeys.insert(k).inserted { geometry.corners.append(p) }
        }
        for chain in chains {
            let world = chain.points.map { points[$0] }
            let n = world.count
            guard n >= 2 else { continue }
            // Sharp turns split a chain into pieces; a smooth closed chain
            // (a circle, a rounded slot) is one curve with a center.
            var sharp: [Int] = []
            for k in 0..<n {
                let hasPrev = chain.closed || k > 0, hasNext = chain.closed || k < n - 1
                guard hasPrev, hasNext else { sharp.append(k); continue }
                let a = world[(k - 1 + n) % n], b = world[k], c = world[(k + 1) % n]
                let u = b - a, v = c - b
                let lu = simd_length(u), lv = simd_length(v)
                if lu < 1e-9 || lv < 1e-9 || simd_dot(u, v) / (lu * lv) < cosCorner { sharp.append(k) }
            }
            if chain.closed && sharp.isEmpty {
                let centroid = world.reduce(SIMD3<Double>.zero, +) / Double(n)
                geometry.centers.append(plane.toLocal(centroid))
                continue
            }
            for k in sharp { addCorner(plane.toLocal(world[k])) }
            // Straight runs between consecutive sharp vertices.
            let stops = chain.closed ? sharp + [sharp[0] + n] : sharp
            for s in 0..<(stops.count - 1) {
                let from = stops[s], to = stops[s + 1]
                let a3 = world[from % n], b3 = world[to % n]
                // Straight only if every vertex between lies on the chord.
                let chord = b3 - a3
                let len = simd_length(chord)
                guard len > 1e-9 else { continue }
                var straight = true
                if to - from > 1 {
                    for m in (from + 1)..<to {
                        let p = world[m % n]
                        let off = simd_length(simd_cross(p - a3, chord)) / len
                        if off > max(1e-4, len * 1e-3) { straight = false; break }
                    }
                }
                guard straight else { continue }
                let a = plane.toLocal(a3), b = plane.toLocal(b3)
                guard simd_distance(a, b) > 1e-6 else { continue } // seen end-on: just a corner
                geometry.runs.append((a, b))
                geometry.midpoints.append((a + b) / 2)
            }
        }
        return geometry
    }
}

nonisolated enum SnapEngine {
    static let gridSpacing: Double = 0.5
    static let pointTolerance: Double = 0.35

    /// Viewport acquisition is screen-relative; the legacy default remains for
    /// geometry-only callers without a camera. This is a UI-point radius, not
    /// simulator screenshot pixels or model millimetres.
    static func screenPointTolerance(worldUnitsPerPoint: Double) -> Double {
        max(1e-9, worldUnitsPerPoint * 12)
    }

    /// Ranking when several candidates are in range. An endpoint is a harder
    /// commitment than a midpoint, and both beat a centre, so a tie near a
    /// corner resolves the way the user expects instead of by float noise.
    private static func priority(_ kind: SnapKind) -> Int {
        switch kind {
        case .endpoint: 4
        case .midpoint: 3
        case .center: 2
        // Sliding along an edge is the weakest commitment — any named point on
        // that edge should win a tie, or you could never land exactly on a
        // corner while tracing the boundary.
        case .edge: 1
        case .grid, .free: 0
        }
    }

    /// `faceLoops` are the boundary loops (outer + holes) of the solid face the
    /// sketch plane lies on, in sketch 2D coordinates. Sketching on a blank face
    /// otherwise has NOTHING to snap to but the grid, which is why a rectangle
    /// drawn on a face lands wherever the finger happened to be — off the edge,
    /// off centre. These give the face's own corners, edge midpoints, centre and
    /// edges the same status as existing sketch geometry.
    static func snap(
        _ p: SIMD2<Double>, in sketch: Sketch?, faceLoops: [[SIMD2<Double>]] = [],
        distant: DistantSnapGeometry = .empty,
        options: SnapOptions = .init(), tolerance: Double = pointTolerance
    ) -> SnapResult {
        var best: (candidate: SnapCandidate, distance: Double)?
        func consider(_ candidate: SnapCandidate) {
            let d = simd_length(candidate.point - p)
            guard d <= tolerance else { return }
            if let current = best {
                let better = priority(candidate.kind) > priority(current.candidate.kind)
                    || (priority(candidate.kind) == priority(current.candidate.kind)
                        && d < current.distance)
                if !better { return }
            }
            best = (candidate, d)
        }

        // 1. Existing sketch points and the underlying face compete together, so
        //    a face corner isn't shadowed by a farther sketch endpoint.
        if options.sketchGuidepoints, let sketch {
            for candidate in snapCandidates(of: sketch) { consider(candidate) }
        }
        if options.faceGuidepoints {
            for candidate in faceSnapCandidates(loops: faceLoops, near: p, grid: options.grid) {
                consider(candidate)
            }
        }
        if options.distantEdges {
            for candidate in distantSnapCandidates(distant, near: p, grid: options.grid) {
                consider(candidate)
            }
        }
        if let best {
            return SnapResult(point: best.candidate.point, kind: best.candidate.kind)
        }

        guard options.grid else { return SnapResult(point: p, kind: .free) }

        // 2. Grid.
        let snapped = SIMD2(
            (p.x / gridSpacing).rounded() * gridSpacing,
            (p.y / gridSpacing).rounded() * gridSpacing
        )
        return SnapResult(point: snapped, kind: .grid)
    }

    /// Snappable points from the face's boundary: every corner, every edge
    /// midpoint, the centre of each loop, plus the closest point ON each edge
    /// (so you can slide along a boundary and stay exactly on it).
    static func faceSnapCandidates(
        loops: [[SIMD2<Double>]], near p: SIMD2<Double>, grid: Bool = true
    ) -> [SnapCandidate] {
        var out: [SnapCandidate] = []
        for loop in loops where loop.count >= 2 {
            var sum = SIMD2<Double>.zero
            for corner in loop {
                out.append(SnapCandidate(point: corner, kind: .endpoint))
                sum += corner
            }
            // Loop centre — the point you want when centring a cut on a face.
            if loop.count >= 3 {
                out.append(SnapCandidate(point: sum / Double(loop.count), kind: .center))
            }
            for i in 0..<loop.count {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                out.append(SnapCandidate(point: (a + b) / 2, kind: .midpoint))
                if let onEdge = closestPointOnSegment(p, a, b) {
                    out.append(SnapCandidate(point: grid ? gridAlongEdge(onEdge, a, b) : onEdge, kind: .edge))
                }
            }
        }
        return out
    }

    /// Snappable points from projected distant edges.
    static func distantSnapCandidates(
        _ geometry: DistantSnapGeometry, near p: SIMD2<Double>, grid: Bool = true
    ) -> [SnapCandidate] {
        var out = geometry.corners.map { SnapCandidate(point: $0, kind: .endpoint) }
        out += geometry.midpoints.map { SnapCandidate(point: $0, kind: .midpoint) }
        out += geometry.centers.map { SnapCandidate(point: $0, kind: .center) }
        for (a, b) in geometry.runs {
            if let onEdge = closestPointOnSegment(p, a, b) {
                out.append(SnapCandidate(point: grid ? gridAlongEdge(onEdge, a, b) : onEdge, kind: .edge))
            }
        }
        return out
    }

    /// The edge point moved to a grid step measured from the NEARER corner.
    /// A raw projection kept whatever along-edge coordinate the finger had
    /// (10.025 mm, not 10), so a rectangle ended on a face edge came out
    /// 0.25 % oversize while every other corner sat on the 0.5 mm grid. On a
    /// face whose corners are themselves off-grid this still gives whole
    /// steps from the corner, which is the dimension the user is after.
    static func gridAlongEdge(
        _ onEdge: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> SIMD2<Double> {
        let ab = b - a
        let length = simd_length(ab)
        guard length > 1e-9 else { return onEdge }
        let dir = ab / length
        let s = min(max(simd_dot(onEdge - a, dir), 0), length)
        let snapped: Double
        if s <= length / 2 {
            snapped = (s / gridSpacing).rounded() * gridSpacing
        } else {
            snapped = length - ((length - s) / gridSpacing).rounded() * gridSpacing
        }
        return a + dir * min(max(snapped, 0), length)
    }

    /// Closest point to `p` on segment a→b, or nil if the segment is degenerate.
    private static func closestPointOnSegment(
        _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> SIMD2<Double>? {
        let ab = b - a
        let len2 = simd_dot(ab, ab)
        guard len2 > 1e-12 else { return nil }
        let t = min(max(simd_dot(p - a, ab) / len2, 0), 1)
        return a + ab * t
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
