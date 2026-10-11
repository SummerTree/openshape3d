//
//  RenderDefects.swift
//  openshape3dTests
//
//  What a see-through hole IS in the triangles the app draws. Euclid's
//  `isWatertight` judges the polygon mesh before triangulation and calls the
//  harmless T-junction seams every mesh boolean leaves "not watertight", yet
//  passed the filleted body of bug report a6fea315 — which rendered with a
//  long sliver hole. Counting on the render mesh tells the two apart.
//

import simd
@testable import openshape3d

enum RenderDefects {
    /// `open`: edges used by an odd number of triangles. `flipped`: edges two
    /// triangles cross in the SAME direction — one of them faces inward and
    /// is back-face culled, which is the hole the user sees. Vertices are
    /// welded at `weld` first. Both are zero for a well-formed solid.
    static func count(_ mesh: RenderMesh, weld: Float = 1e-5) -> (open: Int, flipped: Int) {
        struct Key: Hashable { let x, y, z: Int32 }
        struct Edge: Hashable { let a, b: Key }
        let keys = mesh.positions.map {
            Key(x: Int32(($0.x / weld).rounded()), y: Int32(($0.y / weld).rounded()),
                z: Int32(($0.z / weld).rounded()))
        }
        var directed = [Edge: Int]()
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let corners = (0..<3).map { keys[Int(mesh.indices[t + $0])] }
            for i in 0..<3 where corners[i] != corners[(i + 1) % 3] {
                directed[Edge(a: corners[i], b: corners[(i + 1) % 3]), default: 0] += 1
            }
        }
        func precedes(_ a: Key, _ b: Key) -> Bool { (a.x, a.y, a.z) < (b.x, b.y, b.z) }
        var open = 0, flipped = 0
        for (edge, count) in directed {
            if count > 1 { flipped += 1 }
            // Each undirected edge once: from its canonical direction, or from
            // the only direction present.
            let reverse = directed[Edge(a: edge.b, b: edge.a)] ?? 0
            if (count + reverse) % 2 == 1, reverse == 0 || precedes(edge.a, edge.b) {
                open += 1
            }
        }
        return (open, flipped)
    }
}
