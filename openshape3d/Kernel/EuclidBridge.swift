//
//  EuclidBridge.swift
//  openshape3d
//
//  Conversion layer between Euclid types (Double-precision, polygon soup)
//  and the flat Float32 buffers the Metal viewport consumes.
//

import Foundation
import simd
import Euclid

nonisolated enum EuclidBridge {
    /// Quantization for vertex welding: positions/normals equal within this
    /// tolerance share a render vertex. Preserves hard edges because the
    /// normal participates in the key.
    private static let weldQuantum: Float = 1e-5

    private struct WeldKey: Hashable {
        let px, py, pz: Int32
        let nx, ny, nz: Int32

        init(position: SIMD3<Float>, normal: SIMD3<Float>, quantum: Float) {
            let inv = 1 / quantum
            // Clamped: a raw Int32(_: Float) traps past ±21 m or on NaN.
            px = MeshQuantize.key(position.x, inverseQuantum: inv)
            py = MeshQuantize.key(position.y, inverseQuantum: inv)
            pz = MeshQuantize.key(position.z, inverseQuantum: inv)
            nx = MeshQuantize.key(normal.x, inverseQuantum: inv)
            ny = MeshQuantize.key(normal.y, inverseQuantum: inv)
            nz = MeshQuantize.key(normal.z, inverseQuantum: inv)
        }
    }

    /// Triangulates a Euclid mesh and welds vertices into an indexed RenderMesh.
    static func renderMesh(from mesh: Euclid.Mesh) -> RenderMesh {
        let triangulated = mesh.triangulate()
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [UInt32]()
        var lookup = [WeldKey: UInt32]()

        for polygon in triangulated.polygons {
            for vertex in polygon.vertices {
                let p = SIMD3<Float>(
                    Float(vertex.position.x), Float(vertex.position.y), Float(vertex.position.z)
                )
                let n = SIMD3<Float>(
                    Float(vertex.normal.x), Float(vertex.normal.y), Float(vertex.normal.z)
                )
                let key = WeldKey(position: p, normal: n, quantum: weldQuantum)
                if let existing = lookup[key] {
                    indices.append(existing)
                } else {
                    let index = UInt32(positions.count)
                    lookup[key] = index
                    positions.append(p)
                    normals.append(n)
                    indices.append(index)
                }
            }
        }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    /// Rebuilds a Euclid mesh from stored triangle buffers (document load path).
    /// The result is a valid polygon soup for CSG; Euclid re-derives topology.
    static func euclidMesh(from render: RenderMesh) -> Euclid.Mesh {
        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(render.triangleCount)
        var i = 0
        while i + 2 < render.indices.count {
            let ia = Int(render.indices[i])
            let ib = Int(render.indices[i + 1])
            let ic = Int(render.indices[i + 2])
            i += 3
            let vertices = [ia, ib, ic].map { idx in
                Euclid.Vertex(
                    Vector(
                        Double(render.positions[idx].x),
                        Double(render.positions[idx].y),
                        Double(render.positions[idx].z)
                    ),
                    Vector(
                        Double(render.normals[idx].x),
                        Double(render.normals[idx].y),
                        Double(render.normals[idx].z)
                    )
                )
            }
            // Degenerate (zero-area) triangles return nil and are skipped.
            if let polygon = Euclid.Polygon(vertices) {
                polygons.append(polygon)
            }
        }
        return Euclid.Mesh(polygons)
    }

    static func vector(_ v: SIMD3<Double>) -> Vector {
        Vector(v.x, v.y, v.z)
    }

    static func simd(_ v: Vector) -> SIMD3<Double> {
        SIMD3(v.x, v.y, v.z)
    }
}

/// Primitive mesh construction. Slices chosen for a CAD-smooth look
/// (Euclid's defaults of 16 are visibly faceted).
nonisolated extension Euclid.Mesh {
    static func primitive(_ spec: PrimitiveSpec) -> Euclid.Mesh {
        switch spec {
        case let .box(width, depth, height):
            // Euclid cube is centered; shift so the base sits on y=0.
            return .cube(center: Vector(0, height / 2, 0), size: Vector(width, height, depth))
        case let .cylinder(radius, height):
            return .cylinder(radius: radius, height: height, slices: 48)
                .translated(by: Vector(0, height / 2, 0))
        case let .sphere(radius):
            return .sphere(radius: radius, slices: 32, stacks: 24)
                .translated(by: Vector(0, radius, 0))
        }
    }
}
