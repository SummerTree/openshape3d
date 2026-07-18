//
//  FaceTopology.swift
//  openshape3d
//
//  Planar-face extraction from triangle meshes: flood-fill coplanar connected
//  triangles from a picked seed, and recover the face's boundary loops so the
//  face can be re-extruded (Shapr3D's push/pull on faces — planar faces only).
//

import Foundation
import simd

/// A planar face of a body, in body-local coordinates.
nonisolated struct PlanarFace {
    /// Triangle indices (into the body's RenderMesh) forming the face.
    var triangles: [Int]
    /// Unit face normal (local space).
    var normal: SIMD3<Float>
    /// Plane basis in local space; normal = basisX × basisY.
    var origin: SIMD3<Double>
    var basisX: SIMD3<Double>
    var basisY: SIMD3<Double>
    /// Outer boundary in basis coordinates, CCW.
    var outline: [SIMD2<Double>]
    /// Inner boundaries (holes) in basis coordinates.
    var holes: [[SIMD2<Double>]]
}

nonisolated enum FaceTopology {
    private static let normalTolerance: Float = 0.9995   // ~1.8°
    private static let planeTolerance: Float = 1e-3
    private static let weldQuantum: Float = 1e-5

    private struct PositionKey: Hashable {
        let x, y, z: Int32
        init(_ p: SIMD3<Float>) {
            let inv = 1 / FaceTopology.weldQuantum
            x = Int32((p.x * inv).rounded())
            y = Int32((p.y * inv).rounded())
            z = Int32((p.z * inv).rounded())
        }
    }

    private struct EdgeKey: Hashable {
        let a, b: PositionKey
        init(_ p: SIMD3<Float>, _ q: SIMD3<Float>) {
            let kp = PositionKey(p)
            let kq = PositionKey(q)
            // Order-independent
            if kp.x < kq.x || (kp.x == kq.x && (kp.y < kq.y || (kp.y == kq.y && kp.z <= kq.z))) {
                a = kp; b = kq
            } else {
                a = kq; b = kp
            }
        }
    }

    /// Drop collinear midpoints (CSG healing inserts them along straight
    /// edges) so outlines stay minimal.
    private static func simplifyCollinear(_ loop: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard loop.count > 3 else { return loop }
        var result: [SIMD2<Double>] = []
        let n = loop.count
        for i in 0..<n {
            let prev = loop[(i + n - 1) % n]
            let point = loop[i]
            let next = loop[(i + 1) % n]
            let a = point - prev
            let b = next - point
            let cross = a.x * b.y - a.y * b.x
            let lengths = simd_length(a) * simd_length(b)
            if lengths < 1e-12 || abs(cross) / lengths > 1e-6 {
                result.append(point)
            }
        }
        return result.count >= 3 ? result : loop
    }

    /// Extract the planar face containing `seedTriangle`, or nil when the
    /// surface there isn't planar (curved regions can't be push/pulled).
    static func planarFace(in mesh: RenderMesh, seedTriangle: Int) -> PlanarFace? {
        guard seedTriangle >= 0, seedTriangle < mesh.triangleCount else { return nil }

        func triangleVertices(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            (
                mesh.positions[Int(mesh.indices[t * 3])],
                mesh.positions[Int(mesh.indices[t * 3 + 1])],
                mesh.positions[Int(mesh.indices[t * 3 + 2])]
            )
        }

        func triangleNormal(_ t: Int) -> SIMD3<Float>? {
            let (a, b, c) = triangleVertices(t)
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            return length > 1e-12 ? cross / length : nil
        }

        guard let seedNormal = triangleNormal(seedTriangle) else { return nil }
        let (s0, _, _) = triangleVertices(seedTriangle)
        let planeOffset = simd_dot(seedNormal, s0)

        func isCoplanar(_ t: Int) -> Bool {
            guard let n = triangleNormal(t), simd_dot(n, seedNormal) > normalTolerance else {
                return false
            }
            let (a, b, c) = triangleVertices(t)
            return abs(simd_dot(seedNormal, a) - planeOffset) < planeTolerance
                && abs(simd_dot(seedNormal, b) - planeOffset) < planeTolerance
                && abs(simd_dot(seedNormal, c) - planeOffset) < planeTolerance
        }

        // Edge → triangles adjacency (welded positions).
        var edgeTriangles = [EdgeKey: [Int]]()
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = triangleVertices(t)
            edgeTriangles[EdgeKey(a, b), default: []].append(t)
            edgeTriangles[EdgeKey(b, c), default: []].append(t)
            edgeTriangles[EdgeKey(c, a), default: []].append(t)
        }

        // Flood fill coplanar connected triangles.
        var faceTriangles = Set<Int>()
        var queue = [seedTriangle]
        while let t = queue.popLast() {
            guard !faceTriangles.contains(t), isCoplanar(t) else { continue }
            faceTriangles.insert(t)
            let (a, b, c) = triangleVertices(t)
            for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                for neighbor in edgeTriangles[edge] ?? [] where !faceTriangles.contains(neighbor) {
                    queue.append(neighbor)
                }
            }
        }
        guard !faceTriangles.isEmpty else { return nil }

        // Boundary edges: appear in exactly one face triangle (directed order
        // preserved from the triangle winding so loops come out oriented).
        struct DirectedEdge {
            let from: PositionKey
            let to: PositionKey
            let fromPos: SIMD3<Float>
            let toPos: SIMD3<Float>
        }
        var boundaryCount = [EdgeKey: Int]()
        for t in faceTriangles {
            let (a, b, c) = triangleVertices(t)
            for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                boundaryCount[edge, default: 0] += 1
            }
        }
        var directed = [PositionKey: DirectedEdge]()
        for t in faceTriangles {
            let (a, b, c) = triangleVertices(t)
            for (p, q) in [(a, b), (b, c), (c, a)] where boundaryCount[EdgeKey(p, q)] == 1 {
                let edge = DirectedEdge(
                    from: PositionKey(p), to: PositionKey(q), fromPos: p, toPos: q
                )
                directed[edge.from] = edge
            }
        }

        // Chain directed boundary edges into loops.
        var loops3D: [[SIMD3<Float>]] = []
        var visited = Set<PositionKey>()
        for (start, _) in directed where !visited.contains(start) {
            var loop: [SIMD3<Float>] = []
            var currentKey = start
            var steps = 0
            while let edge = directed[currentKey], !visited.contains(currentKey) {
                visited.insert(currentKey)
                loop.append(edge.fromPos)
                currentKey = edge.to
                steps += 1
                if steps > directed.count + 1 { break }
            }
            if loop.count >= 3, currentKey == start {
                loops3D.append(loop)
            }
        }
        guard !loops3D.isEmpty else { return nil }

        // Face basis: origin at loop centroid, X along the first edge.
        let normalD = SIMD3<Double>(Double(seedNormal.x), Double(seedNormal.y), Double(seedNormal.z))
        let firstLoop = loops3D[0]
        var centroid = SIMD3<Double>.zero
        for p in firstLoop {
            centroid += SIMD3(Double(p.x), Double(p.y), Double(p.z))
        }
        centroid /= Double(firstLoop.count)

        var edgeDir = SIMD3<Double>(1, 0, 0)
        if firstLoop.count >= 2 {
            let a = firstLoop[0]
            let b = firstLoop[1]
            let d = SIMD3<Double>(Double(b.x - a.x), Double(b.y - a.y), Double(b.z - a.z))
            if simd_length(d) > 1e-9 {
                edgeDir = simd_normalize(d)
            }
        }
        // Orthonormalize against the normal.
        var basisX = edgeDir - normalD * simd_dot(edgeDir, normalD)
        if simd_length(basisX) < 1e-9 {
            basisX = abs(normalD.y) < 0.9
                ? simd_normalize(simd_cross(SIMD3(0, 1, 0), normalD))
                : simd_normalize(simd_cross(SIMD3(1, 0, 0), normalD))
        } else {
            basisX = simd_normalize(basisX)
        }
        let basisY = simd_cross(normalD, basisX)

        func project(_ loop: [SIMD3<Float>]) -> [SIMD2<Double>] {
            let projected = loop.map { p -> SIMD2<Double> in
                let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - centroid
                return SIMD2(simd_dot(d, basisX), simd_dot(d, basisY))
            }
            return simplifyCollinear(projected)
        }

        // Largest |area| loop is the outer boundary; orient CCW, holes too.
        var projected = loops3D.map(project)
        projected.sort { abs(Profile.signedArea($0)) > abs(Profile.signedArea($1)) }
        var outer = projected[0]
        if Profile.signedArea(outer) < 0 { outer.reverse() }
        var holes: [[SIMD2<Double>]] = []
        for var hole in projected.dropFirst() {
            if Profile.signedArea(hole) < 0 { hole.reverse() }
            holes.append(hole)
        }

        return PlanarFace(
            triangles: Array(faceTriangles).sorted(),
            normal: seedNormal,
            origin: centroid,
            basisX: basisX,
            basisY: basisY,
            outline: outer,
            holes: holes
        )
    }
}
