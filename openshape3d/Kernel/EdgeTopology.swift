//
//  EdgeTopology.swift
//  openshape3d
//
//  Enumerates SELECTABLE straight edges from a triangle mesh, retaining the
//  two adjacent face normals and endpoints that a chamfer/fillet needs. This is
//  the richer sibling of `FeatureEdgeExtractor` (which throws adjacency away and
//  returns bare segments for display). Crease edges that are collinear, share an
//  endpoint, and border the SAME pair of faces are merged into one maximal
//  straight edge, so a box edge subdivided by an upstream boolean still reads as
//  a single pickable edge.
//
//  All geometry is in the mesh's LOCAL space (the same space `RenderMesh`
//  positions live in); callers transform by the body matrix for world picking.
//

import Foundation
import simd

/// One pickable straight edge: two endpoints plus the outward normals of the
/// two faces it borders. `isConvex` is true when the solid fills the wedge
/// between the faces (an external edge) — only convex edges chamfer/fillet by
/// material removal in the mesh kernel.
nonisolated struct SelectableEdge: Equatable, Sendable {
    var start: SIMD3<Float>
    var end: SIMD3<Float>
    var normalA: SIMD3<Float>
    var normalB: SIMD3<Float>
    var isConvex: Bool

    var midpoint: SIMD3<Float> { (start + end) / 2 }
    var length: Float { simd_length(end - start) }
    var direction: SIMD3<Float> {
        let d = end - start
        let l = simd_length(d)
        return l > 1e-9 ? d / l : SIMD3<Float>(0, 0, 1)
    }
}

nonisolated enum EdgeTopology {
    /// Position welding quantum (matches FeatureEdgeExtractor).
    private static let quantum: Float = 1e-5

    private struct PositionKey: Hashable {
        let x, y, z: Int32
        init(_ p: SIMD3<Float>) {
            let inv = 1 / EdgeTopology.quantum
            // Clamped: a raw Int32(_: Float) traps past ±21 m or on NaN.
            x = MeshQuantize.key(p.x, inverseQuantum: inv)
            y = MeshQuantize.key(p.y, inverseQuantum: inv)
            z = MeshQuantize.key(p.z, inverseQuantum: inv)
        }
    }

    private struct EdgeKey: Hashable {
        let a, b: Int
        init(_ i: Int, _ j: Int) { if i < j { a = i; b = j } else { a = j; b = i } }
    }

    /// A crease edge with resolved geometry before merging.
    private struct RawEdge {
        var a: Int          // topo vertex id
        var b: Int          // topo vertex id
        var normalA: SIMD3<Float>
        var normalB: SIMD3<Float>
    }

    static func selectableEdges(
        from mesh: RenderMesh,
        angleThresholdDegrees: Float = 20
    ) -> [SelectableEdge] {
        guard mesh.triangleCount > 0 else { return [] }

        // 1. Weld positions into topological vertex ids.
        var topoID = [Int](repeating: 0, count: mesh.positions.count)
        var lookup = [PositionKey: Int]()
        var topoPositions = [SIMD3<Float>]()
        for (i, p) in mesh.positions.enumerated() {
            let key = PositionKey(p)
            if let existing = lookup[key] {
                topoID[i] = existing
            } else {
                let id = topoPositions.count
                lookup[key] = id
                topoPositions.append(p)
                topoID[i] = id
            }
        }

        // 2. Map each undirected topo edge → its adjacent face normals.
        var edgeFaces = [EdgeKey: [SIMD3<Float>]]()
        var triangle = 0
        while triangle < mesh.triangleCount {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            triangle += 1
            let p0 = mesh.positions[i0], p1 = mesh.positions[i1], p2 = mesh.positions[i2]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let area = simd_length(cross)
            guard area > 1e-12 else { continue }
            let normal = cross / area
            let t0 = topoID[i0], t1 = topoID[i1], t2 = topoID[i2]
            guard t0 != t1, t1 != t2, t2 != t0 else { continue }
            edgeFaces[EdgeKey(t0, t1), default: []].append(normal)
            edgeFaces[EdgeKey(t1, t2), default: []].append(normal)
            edgeFaces[EdgeKey(t2, t0), default: []].append(normal)
        }

        // 3. Keep manifold crease edges (exactly 2 faces meeting past the
        //    threshold). Boundary / non-manifold edges aren't chamfer-able.
        let cosThreshold = cos(angleThresholdDegrees * .pi / 180)
        var raw = [RawEdge]()
        for (edge, normals) in edgeFaces where normals.count == 2 {
            if simd_dot(normals[0], normals[1]) < cosThreshold {
                raw.append(RawEdge(a: edge.a, b: edge.b, normalA: normals[0], normalB: normals[1]))
            }
        }

        // 4. Merge collinear, connected, same-face-pair crease edges into
        //    maximal straight edges.
        let merged = mergeCollinear(raw, positions: topoPositions)

        // 5. Finalize: classify convexity.
        return merged.map { edge in
            let start = topoPositions[edge.a]
            let end = topoPositions[edge.b]
            return SelectableEdge(
                start: start,
                end: end,
                normalA: edge.normalA,
                normalB: edge.normalB,
                isConvex: isConvexEdge(
                    start: start, end: end,
                    normalA: edge.normalA, normalB: edge.normalB,
                    positions: topoPositions)
            )
        }
    }

    // MARK: - Merging

    /// Group raw crease edges by (line, face-pair) and stitch touching /
    /// overlapping collinear segments into one edge spanning the extremes.
    private static func mergeCollinear(
        _ raw: [RawEdge], positions: [SIMD3<Float>]
    ) -> [RawEdge] {
        // Bucket by a quantized line key + sorted normal-pair key. The key is
        // STRUCTURAL (every quantized component compared), not a scalar hash —
        // XOR-folded hashes collide for antipodal segments (negating the inputs
        // can preserve the fold), which used to weld opposite sides of a
        // cylinder rim into bogus diameter-length "edges".
        struct QVec: Hashable, Comparable {
            let x, y, z: Int32
            static func < (l: QVec, r: QVec) -> Bool {
                (l.x, l.y, l.z) < (r.x, r.y, r.z)
            }
        }
        func q(_ v: Float, _ s: Float) -> Int32 { MeshQuantize.key(v, inverseQuantum: s) }
        func qv(_ v: SIMD3<Float>, _ s: Float) -> QVec {
            QVec(x: q(v.x, s), y: q(v.y, s), z: q(v.z, s))
        }
        struct BucketKey: Hashable { let line: QVec; let dir: QVec; let na: QVec; let nb: QVec }

        var buckets = [BucketKey: [RawEdge]]()
        for e in raw {
            let pa = positions[e.a], pb = positions[e.b]
            var d = pb - pa
            let len = simd_length(d)
            guard len > 1e-9 else { continue }
            d /= len
            // Canonical direction (flip so the dominant component is positive).
            var cd = d
            let ax = abs(cd.x), ay = abs(cd.y), az = abs(cd.z)
            let dominant: Float = ax >= ay && ax >= az ? cd.x : (ay >= az ? cd.y : cd.z)
            if dominant < 0 { cd = -cd }
            // Line anchor: point on the line closest to origin, quantized.
            let anchor = pa - cd * simd_dot(pa, cd)
            // Face-pair key (order-independent).
            let n0 = qv(e.normalA, 1e3), n1 = qv(e.normalB, 1e3)
            let key = BucketKey(line: qv(anchor, 1e4), dir: qv(cd, 1e3),
                                na: min(n0, n1), nb: max(n0, n1))
            buckets[key, default: []].append(e)
        }

        var result = [RawEdge]()
        for (_, group) in buckets {
            // Project every endpoint onto the shared direction and take the
            // extreme vertices as the merged span. (A single bucket is one line
            // and one face pair, so this is a valid straight edge.)
            let first = group[0]
            var d = positions[first.b] - positions[first.a]
            let l = simd_length(d)
            guard l > 1e-9 else { result.append(first); continue }
            d /= l
            var minProj = Float.greatestFiniteMagnitude, maxProj = -Float.greatestFiniteMagnitude
            var minV = first.a, maxV = first.b
            for e in group {
                for v in [e.a, e.b] {
                    let t = simd_dot(positions[v], d)
                    if t < minProj { minProj = t; minV = v }
                    if t > maxProj { maxProj = t; maxV = v }
                }
            }
            result.append(RawEdge(a: minV, b: maxV,
                                  normalA: first.normalA, normalB: first.normalB))
        }
        return result
    }

    // MARK: - Smooth chains

    /// Expand `seed` to the maximal tangent-continuous chain of edges it belongs
    /// to. A tessellated curved rim (cylinder top, rounded slot) is many short
    /// straight segments, each bordering a DIFFERENT side facet, so
    /// `mergeCollinear` can never join them; walking endpoint-to-endpoint while
    /// both the edge direction and the adjacent-face normals turn less than
    /// `maxTurnDegrees` per step recovers the whole rim. A genuinely sharp
    /// corner (box edges meet at 90°) fails the turn test, so straight feature
    /// edges stay individually selectable.
    static func smoothChain(
        containing seed: SelectableEdge,
        in edges: [SelectableEdge],
        maxTurnDegrees: Float = 35
    ) -> [SelectableEdge] {
        guard let seedIndex = edges.firstIndex(where: {
            simd_length($0.midpoint - seed.midpoint) < 1e-4
        }) else { return [seed] }
        let cosTurn = cos(maxTurnDegrees * .pi / 180)

        var byEndpoint = [PositionKey: [Int]]()
        for (i, e) in edges.enumerated() {
            byEndpoint[PositionKey(e.start), default: []].append(i)
            byEndpoint[PositionKey(e.end), default: []].append(i)
        }

        // Two segments continue each other when the edge direction stays within
        // the turn threshold AND their face pairs match up side-for-side (the
        // cap normal tracks the cap, the wall normal tracks the wall).
        func continues(_ a: SelectableEdge, _ b: SelectableEdge) -> Bool {
            guard abs(simd_dot(a.direction, b.direction)) >= cosTurn else { return false }
            let direct = min(simd_dot(a.normalA, b.normalA), simd_dot(a.normalB, b.normalB))
            let swapped = min(simd_dot(a.normalA, b.normalB), simd_dot(a.normalB, b.normalA))
            return max(direct, swapped) >= cosTurn
        }

        var visited: Set<Int> = [seedIndex]
        var queue = [seedIndex]
        while let i = queue.popLast() {
            let e = edges[i]
            for key in [PositionKey(e.start), PositionKey(e.end)] {
                for j in byEndpoint[key] ?? [] where !visited.contains(j) {
                    if continues(e, edges[j]) {
                        visited.insert(j)
                        queue.append(j)
                    }
                }
            }
        }
        return visited.sorted().map { edges[$0] }
    }

    // MARK: - Signature / resolution

    /// Fingerprint a pickable edge for persistence (Double model space).
    static func signature(of edge: SelectableEdge) -> EdgeSignature {
        func d(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
        return EdgeSignature(
            midpoint: d(edge.midpoint),
            direction: d(edge.direction),
            length: Double(edge.length),
            normalA: d(edge.normalA),
            normalB: d(edge.normalB))
    }

    /// Re-find the edge a persisted `EdgeSignature` names among a rebuilt body's
    /// `edges`. The adjacent-face-normal PAIR dominates (an edge is "the crease
    /// between these two faces"); direction, midpoint and length break ties. The
    /// `sizeScale` normalizes midpoint distance so the threshold is scale-free.
    static func resolve(
        _ sig: EdgeSignature,
        in edges: [SelectableEdge],
        sizeScale: Double,
        threshold: Double = 0.55
    ) -> SelectableEdge? {
        func f(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        let refDir = f(sig.direction)
        let refNA = f(sig.normalA), refNB = f(sig.normalB)
        let refMid = f(sig.midpoint)
        let scale = Float(max(sizeScale, 1e-3))

        var best: SelectableEdge?
        var bestScore: Float = -1
        for e in edges {
            // Normal-pair alignment (either pairing).
            let direct = (simd_dot(refNA, e.normalA) + simd_dot(refNB, e.normalB)) / 2
            let swapped = (simd_dot(refNA, e.normalB) + simd_dot(refNB, e.normalA)) / 2
            let normalScore = max(direct, swapped)                     // [-1, 1]
            let dirScore = abs(simd_dot(refDir, e.direction))          // [0, 1], undirected
            let midDist = simd_length(refMid - e.midpoint) / scale
            let midScore = max(0, 1 - midDist)                         // [0, 1]
            let lenScore = 1 - min(1, abs(Float(sig.length) - e.length) / scale)

            let score = 0.5 * normalScore + 0.2 * dirScore
                + 0.2 * midScore + 0.1 * lenScore
            if score > bestScore { bestScore = score; best = e }
        }
        return bestScore >= Float(threshold) ? best : nil
    }

    // MARK: - Convexity

    /// A crease edge is convex when the solid material fills the wedge between
    /// the two faces. Probe a point just inside from the edge midpoint along the
    /// inward bisector `-(nA+nB)`; if that point is inside the mesh's local AABB
    /// interior AND the faces "open outward", the edge is convex. We use the
    /// normal geometry directly: for a convex edge the outward normals splay
    /// apart, so the midpoint pushed OUT along `+(nA+nB)` leaves the solid.
    private static func isConvexEdge(
        start: SIMD3<Float>, end: SIMD3<Float>,
        normalA: SIMD3<Float>, normalB: SIMD3<Float>,
        positions: [SIMD3<Float>]
    ) -> Bool {
        // Tangents into each face, perpendicular to the edge.
        let e = simd_normalize(end - start)
        var tA = simd_cross(normalA, e)
        var tB = simd_cross(normalB, e)
        let lA = simd_length(tA), lB = simd_length(tB)
        guard lA > 1e-6, lB > 1e-6 else { return false }
        tA /= lA; tB /= lB
        // Orient each tangent to point INTO its face, away from the other face:
        // moving into face A should go below face B's outward plane.
        if simd_dot(tA, normalB) > 0 { tA = -tA }
        if simd_dot(tB, normalA) > 0 { tB = -tB }
        // For a convex edge the two into-face tangents point apart while the
        // outward normals also splay; the signed test that distinguishes convex
        // from concave is whether the corner apex sits OUTSIDE the solid, i.e.
        // the outward bisector points away from the mesh centroid.
        let centroid = positions.reduce(SIMD3<Float>(repeating: 0), +)
            / Float(max(positions.count, 1))
        let mid = (start + end) / 2
        let outwardBisector = normalA + normalB
        return simd_dot(outwardBisector, mid - centroid) > 0
    }
}
