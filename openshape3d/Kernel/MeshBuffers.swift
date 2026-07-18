//
//  MeshBuffers.swift
//  openshape3d
//
//  Flat, Metal-friendly mesh buffers plus the compact binary blob used for
//  persistence ("OS3D" format).
//

import Foundation
import simd

/// Indexed triangle mesh in body-local coordinates, ready for GPU upload.
/// Vertices are welded by (position, normal) so hard edges are preserved.
nonisolated struct RenderMesh: Sendable, Equatable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]

    var triangleCount: Int { indices.count / 3 }

    /// Body-local bounding box, used for pick-ray rejection and fit-view.
    var localAABB: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard !positions.isEmpty else { return (.zero, .zero) }
        var lo = positions[0]
        var hi = positions[0]
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    static func == (lhs: RenderMesh, rhs: RenderMesh) -> Bool {
        lhs.indices == rhs.indices && lhs.positions == rhs.positions && lhs.normals == rhs.normals
    }
}

/// Feature edges as a line list: pairs of world-space endpoints [a0,b0, a1,b1, ...].
nonisolated struct FeatureEdgeSet: Sendable {
    var segments: [SIMD3<Float>]
    var segmentCount: Int { segments.count / 2 }
}

/// Compact binary serialization of a RenderMesh.
/// Layout (little-endian): "OS3D" magic, u32 version, u32 vertexCount,
/// u32 indexCount, positions (f32×3 × vertexCount), normals (f32×3 × vertexCount),
/// indices (u32 × indexCount).
nonisolated enum MeshBlob {
    static let magic: UInt32 = 0x4F533344 // "OS3D"
    static let version: UInt32 = 1

    enum BlobError: Error {
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated
    }

    static func encode(_ mesh: RenderMesh) -> Data {
        let vertexCount = UInt32(mesh.positions.count)
        let indexCount = UInt32(mesh.indices.count)
        var data = Data(capacity: 16 + mesh.positions.count * 24 + mesh.indices.count * 4)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: vertexCount.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: indexCount.littleEndian) { data.append(contentsOf: $0) }
        // SIMD3<Float> has 16-byte stride; write tightly packed 12-byte triples.
        for p in mesh.positions {
            withUnsafeBytes(of: p.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.z) { data.append(contentsOf: $0) }
        }
        for n in mesh.normals {
            withUnsafeBytes(of: n.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: n.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: n.z) { data.append(contentsOf: $0) }
        }
        mesh.indices.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ data: Data) throws -> RenderMesh {
        var offset = 0
        func read<T>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw BlobError.truncated }
            defer { offset += size }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
        }

        let magicValue = try read(UInt32.self)
        guard magicValue == magic else { throw BlobError.badMagic }
        let versionValue = try read(UInt32.self)
        guard versionValue == version else { throw BlobError.unsupportedVersion(versionValue) }
        let vertexCount = Int(try read(UInt32.self))
        let indexCount = Int(try read(UInt32.self))

        let payloadBytes = vertexCount * 24 + indexCount * 4
        guard offset + payloadBytes <= data.count else { throw BlobError.truncated }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let x = try read(Float.self)
            let y = try read(Float.self)
            let z = try read(Float.self)
            positions.append(SIMD3(x, y, z))
        }
        var normals = [SIMD3<Float>]()
        normals.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let x = try read(Float.self)
            let y = try read(Float.self)
            let z = try read(Float.self)
            normals.append(SIMD3(x, y, z))
        }
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            indices.append(try read(UInt32.self))
        }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }
}
