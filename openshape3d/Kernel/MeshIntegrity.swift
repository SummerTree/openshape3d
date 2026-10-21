//
//  MeshIntegrity.swift
//  openshape3d
//
//  Is a render mesh a closed surface? Render meshes are unwelded — every
//  face owns its vertices, so a cube has 24 positions, not 8 — which means
//  the question cannot be answered from indices alone. Positions are welded
//  by quantised coordinate first, then every triangle edge is counted: an
//  edge used by exactly one triangle is a boundary, and a surface with any
//  boundary encloses no volume. Used by the mesh importers to say "this is
//  an open mesh" instead of letting a zero-volume body pass as a solid.
//

import Foundation
import simd

nonisolated enum MeshIntegrity {

    /// Boundary edges of the mesh: triangle edges with no partner. 0 for a
    /// closed surface (a cube, a sphere, any watertight scan); 3 for a lone
    /// triangle; a hole's rim for a sheet with a hole in it. Degenerate
    /// triangles (two welded corners the same) are skipped, so they neither
    /// open nor close anything.
    static func openEdgeCount(_ mesh: RenderMesh) -> Int {
        let welded = weldedIndices(mesh)
        var incidence = [EdgeKey: Int]()
        var i = 0
        while i + 2 < welded.count {
            let a = welded[i], b = welded[i + 1], c = welded[i + 2]
            i += 3
            guard a != b, b != c, a != c else { continue }
            incidence[EdgeKey(a, b), default: 0] += 1
            incidence[EdgeKey(b, c), default: 0] += 1
            incidence[EdgeKey(c, a), default: 0] += 1
        }
        return incidence.values.filter { $0 == 1 }.count
    }

    /// A closed surface has no boundary and at least one triangle.
    static func isClosed(_ mesh: RenderMesh) -> Bool {
        mesh.indices.count >= 3 && openEdgeCount(mesh) == 0
    }

    /// The mesh's index buffer with coincident positions merged. Quantised
    /// to 1e-5 of the mesh's own unit (mm), well below any modelling
    /// tolerance and well above float noise on a part measured in metres.
    private static func weldedIndices(_ mesh: RenderMesh) -> [Int] {
        var lookup = [SIMD3<Int64>: Int]()
        var remap = [Int](repeating: 0, count: mesh.positions.count)
        for (index, p) in mesh.positions.enumerated() {
            let key = SIMD3<Int64>(Int64((Double(p.x) * 1e5).rounded()),
                                   Int64((Double(p.y) * 1e5).rounded()),
                                   Int64((Double(p.z) * 1e5).rounded()))
            if let existing = lookup[key] {
                remap[index] = existing
            } else {
                lookup[key] = index
                remap[index] = index
            }
        }
        return mesh.indices.map { Int($0) < remap.count ? remap[Int($0)] : Int($0) }
    }

    private struct EdgeKey: Hashable {
        let lo: Int, hi: Int
        init(_ a: Int, _ b: Int) { lo = min(a, b); hi = max(a, b) }
    }
}
