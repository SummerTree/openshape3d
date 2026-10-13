//
//  SectionCapKit.swift
//  openshape3d
//
//  Section View caps (spec §16.1): where the section plane cuts a body, the
//  cut is drawn as a solid face instead of leaving the body open. The body's
//  triangle mesh is sliced by the plane, the crossing segments are chained
//  into loops, the loops are nested into regions (outer boundary + holes)
//  and the regions triangulated.
//
//  The same regions drive interference highlighting: two bodies whose caps
//  overlap occupy the same space, so both caps turn red. Touching bodies
//  (a shared face) do not overlap and stay their own colors.
//

import Foundation
import simd

nonisolated enum SectionCapKit {

    /// A filled area of the cut, in the plane's 2D coordinates.
    struct Region: Equatable, Sendable {
        var outer: [SIMD2<Double>]
        var holes: [[SIMD2<Double>]]
        /// A point strictly inside the region (the centroid of its largest
        /// triangle), used to test whether another cap covers it.
        var interiorPoint: SIMD2<Double>
    }

    struct Cap: Sendable {
        var regions: [Region] = []
        /// Triangle list, world space, 3 vertices per triangle.
        var triangles: [SIMD3<Float>] = []
        /// Outline segment pairs, world space.
        var outline: [SIMD3<Float>] = []
        /// Total cut area (outer areas minus hole areas), mm².
        var area: Double = 0
        /// Chains that did not close (an open or non-manifold mesh); they
        /// are outlined but not filled.
        var openChains: Int = 0

        var isEmpty: Bool { regions.isEmpty && outline.isEmpty }
    }

    /// The cut of a body's mesh by `plane`. `matrix` places the body-local
    /// `positions` in the world.
    static func cap(
        positions: [SIMD3<Float>], indices: [UInt32],
        matrix: simd_double4x4, plane: SketchPlane
    ) -> Cap {
        let normal = simd_normalize(plane.normal)
        guard positions.count >= 3, indices.count >= 3, simd_length(normal) > 0.5 else { return Cap() }

        // Welded vertex ids: render meshes repeat a vertex per face (split
        // normals) with bit-identical positions, so the crossing on a shared
        // edge must be keyed by position, not by index.
        var weld: [SIMD3<UInt32>: Int] = [:]
        var canonical = [Int](repeating: 0, count: positions.count)
        var world: [SIMD3<Double>] = []
        var side: [Double] = []
        for (i, p) in positions.enumerated() {
            let q = p + SIMD3<Float>(repeating: 0) // -0 → +0
            let key = SIMD3(q.x.bitPattern, q.y.bitPattern, q.z.bitPattern)
            if let id = weld[key] {
                canonical[i] = id
                continue
            }
            let w4 = matrix * SIMD4<Double>(SIMD3<Double>(q), 1)
            let w = SIMD3(w4.x, w4.y, w4.z)
            canonical[i] = world.count
            weld[key] = world.count
            world.append(w)
            side.append(simd_dot(w - plane.origin, normal))
        }

        // A vertex exactly on the plane counts as the kept side, so every
        // crossing triangle has exactly two crossing edges.
        func above(_ v: Int) -> Bool { side[v] >= 0 }

        struct EdgeKey: Hashable { let a: Int, b: Int }
        var points: [EdgeKey: SIMD3<Double>] = [:]
        var adjacency: [EdgeKey: [EdgeKey]] = [:]
        func crossing(_ u: Int, _ v: Int) -> EdgeKey {
            let key = EdgeKey(a: min(u, v), b: max(u, v))
            if points[key] == nil {
                let da = side[key.a], db = side[key.b]
                let t = da / (da - db)
                points[key] = world[key.a] + (world[key.b] - world[key.a]) * t
            }
            return key
        }

        var t = 0
        while t + 2 < indices.count {
            let v = [canonical[Int(indices[t])], canonical[Int(indices[t + 1])], canonical[Int(indices[t + 2])]]
            t += 3
            if v[0] == v[1] || v[1] == v[2] || v[0] == v[2] { continue }
            var ends: [EdgeKey] = []
            for k in 0..<3 {
                let a = v[k], b = v[(k + 1) % 3]
                if above(a) != above(b) { ends.append(crossing(a, b)) }
            }
            guard ends.count == 2 else { continue }
            adjacency[ends[0], default: []].append(ends[1])
            adjacency[ends[1], default: []].append(ends[0])
        }
        guard !adjacency.isEmpty else { return Cap() }

        // Chain the segments into loops.
        var cap = Cap()
        var visited = Set<EdgeKey>()
        var loops: [[SIMD2<Double>]] = []
        func f(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(p) }
        // Deterministic walk order (dictionary order is not).
        let starts = adjacency.keys.sorted { $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b }
        for start in starts where !visited.contains(start) {
            var chain = [start]
            visited.insert(start)
            var previous: EdgeKey?
            var current = start
            var closed = false
            while true {
                let next = adjacency[current, default: []].first { $0 != previous && !visited.contains($0) }
                if let next {
                    chain.append(next)
                    visited.insert(next)
                    previous = current
                    current = next
                    continue
                }
                closed = chain.count >= 3 && adjacency[current, default: []].contains(start)
                break
            }
            let world3 = chain.compactMap { points[$0] }
            for i in 0..<(world3.count - 1) {
                cap.outline.append(f(world3[i]))
                cap.outline.append(f(world3[i + 1]))
            }
            if closed, let first = world3.first, let last = world3.last {
                cap.outline.append(f(last))
                cap.outline.append(f(first))
                loops.append(world3.map(plane.toLocal))
            } else {
                cap.openChains += 1
            }
        }

        cap.regions = regions(from: loops)
        for region in cap.regions {
            cap.area += abs(Profile.signedArea(region.outer))
                - region.holes.reduce(0) { $0 + abs(Profile.signedArea($1)) }
            let tri = PolygonTriangulator.triangulate(outer: region.outer, holes: region.holes)
            for index in tri.triangles {
                cap.triangles.append(f(plane.toWorld(tri.vertices[index])))
            }
        }
        return cap
    }

    /// Nest closed loops by containment: a loop inside an even number of
    /// others is an outer boundary, inside an odd number a hole of the
    /// smallest outer that contains it.
    static func regions(from loops: [[SIMD2<Double>]]) -> [Region] {
        let usable = loops.filter { $0.count >= 3 && abs(Profile.signedArea($0)) > 1e-12 }
        let areas = usable.map { abs(Profile.signedArea($0)) }
        var containers: [[Int]] = Array(repeating: [], count: usable.count)
        for i in usable.indices {
            let probe = usable[i][0]
            for j in usable.indices where j != i && areas[j] > areas[i] {
                if contains(usable[j], probe) { containers[i].append(j) }
            }
        }
        var regions: [Int: (outer: [SIMD2<Double>], holes: [[SIMD2<Double>]])] = [:]
        for i in usable.indices where containers[i].count % 2 == 0 {
            regions[i] = (usable[i], [])
        }
        for i in usable.indices where containers[i].count % 2 == 1 {
            // The parent outer is the containing loop one level up.
            let parent = containers[i]
                .filter { containers[$0].count == containers[i].count - 1 }
                .min { areas[$0] < areas[$1] }
            if let parent { regions[parent]?.holes.append(usable[i]) }
        }
        return regions.keys.sorted().compactMap { key in
            guard let r = regions[key] else { return nil }
            return Region(outer: r.outer, holes: r.holes,
                          interiorPoint: interiorPoint(outer: r.outer, holes: r.holes))
        }
    }

    /// True when two cuts overlap with positive area — bodies occupying the
    /// same space. Shared boundaries alone (touching bodies) do not count.
    static func overlaps(_ a: [Region], _ b: [Region]) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let boxA = bounds(a), boxB = bounds(b)
        guard boxA.min.x < boxB.max.x, boxB.min.x < boxA.max.x,
              boxA.min.y < boxB.max.y, boxB.min.y < boxA.max.y else { return false }
        // One cut wholly inside the other (or identical): an interior sample
        // of one lies inside the other.
        if a.contains(where: { inside(b, $0.interiorPoint) }) { return true }
        if b.contains(where: { inside(a, $0.interiorPoint) }) { return true }
        // Partial overlap: boundaries cross properly somewhere.
        let edgesA = edges(a), edgesB = edges(b)
        for (p, q) in edgesA {
            let lo = simd_min(p, q), hi = simd_max(p, q)
            for (r, s) in edgesB {
                if max(r.x, s.x) < lo.x || min(r.x, s.x) > hi.x
                    || max(r.y, s.y) < lo.y || min(r.y, s.y) > hi.y { continue }
                if properlyCross(p, q, r, s) { return true }
            }
        }
        return false
    }

    /// Indices of the caps that overlap any other cap.
    static func interfering(_ caps: [[Region]]) -> Set<Int> {
        var hits = Set<Int>()
        for i in caps.indices {
            for j in caps.indices where j > i {
                if overlaps(caps[i], caps[j]) {
                    hits.insert(i)
                    hits.insert(j)
                }
            }
        }
        return hits
    }

    /// The fill color of the `index`-th body's cut when the body still has
    /// the default color: distinct muted hues, so neighboring parts read
    /// apart (custom-colored bodies keep their own color).
    static func defaultColor(index: Int) -> SIMD4<Float> {
        let palette: [SIMD3<Float>] = [
            SIMD3(0.36, 0.56, 0.86), SIMD3(0.90, 0.62, 0.30), SIMD3(0.42, 0.72, 0.50),
            SIMD3(0.70, 0.50, 0.80), SIMD3(0.88, 0.80, 0.36), SIMD3(0.36, 0.74, 0.78),
            SIMD3(0.86, 0.52, 0.62), SIMD3(0.58, 0.62, 0.40),
        ]
        return SIMD4(palette[((index % palette.count) + palette.count) % palette.count], 1)
    }

    /// Interference red.
    static let interferenceColor = SIMD4<Float>(0.90, 0.16, 0.14, 1)

    // MARK: - Helpers

    private static func contains(_ loop: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = loop.count - 1
        for i in 0..<loop.count {
            let a = loop[i], b = loop[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func inside(_ regions: [Region], _ p: SIMD2<Double>) -> Bool {
        regions.contains { region in
            contains(region.outer, p) && !region.holes.contains { contains($0, p) }
        }
    }

    private static func interiorPoint(outer: [SIMD2<Double>], holes: [[SIMD2<Double>]]) -> SIMD2<Double> {
        let tri = PolygonTriangulator.triangulate(outer: outer, holes: holes)
        var best = outer[0], bestArea = -1.0
        var i = 0
        while i + 2 < tri.triangles.count {
            let a = tri.vertices[tri.triangles[i]], b = tri.vertices[tri.triangles[i + 1]]
            let c = tri.vertices[tri.triangles[i + 2]]
            let ab: SIMD2<Double> = b - a
            let ac: SIMD2<Double> = c - a
            let area = abs(ab.x * ac.y - ab.y * ac.x)
            if area > bestArea {
                bestArea = area
                let sum: SIMD2<Double> = a + b + c
                best = sum / 3
            }
            i += 3
        }
        return best
    }

    private static func bounds(_ regions: [Region]) -> (min: SIMD2<Double>, max: SIMD2<Double>) {
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for r in regions {
            for p in r.outer {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        return (lo, hi)
    }

    private static func edges(_ regions: [Region]) -> [(SIMD2<Double>, SIMD2<Double>)] {
        var out: [(SIMD2<Double>, SIMD2<Double>)] = []
        for r in regions {
            for loop in [r.outer] + r.holes {
                for i in loop.indices { out.append((loop[i], loop[(i + 1) % loop.count])) }
            }
        }
        return out
    }

    /// Segments pq and rs cross at a single point interior to both (no
    /// touching, no collinear overlap).
    private static func properlyCross(
        _ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>, _ s: SIMD2<Double>
    ) -> Bool {
        func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let scale = max(simd_length(q - p), simd_length(s - r), 1e-9)
        let eps = 1e-9 * scale * scale
        let d1 = orient(r, s, p), d2 = orient(r, s, q)
        let d3 = orient(p, q, r), d4 = orient(p, q, s)
        return ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps))
            && ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps))
    }
}
