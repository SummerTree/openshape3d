//
//  MeshBlobTests.swift
//  openshape3dTests
//
//  The OS3D mesh blob is UNTRUSTED INPUT: it arrives inside .os3d project
//  archives that users share. Decoding validated byte lengths but not index
//  VALUES, so a corrupt or hostile file trapped on the first hit-test
//  (`positions[index]`) — and the vertex weld keys trapped on any coordinate
//  past ±21 m or on NaN. Both are 2026-08-25 review round-2 findings; these
//  tests pin the guards.
//

import XCTest
import simd
@testable import openshape3d

final class MeshBlobTests: XCTestCase {

    // MARK: - Blob helpers

    /// A hand-built blob so the header can disagree with the payload the way a
    /// corrupt file does. `indices` are written verbatim, unvalidated.
    private func makeBlob(
        magic: UInt32 = MeshBlob.magic,
        version: UInt32 = MeshBlob.version,
        vertexCount: UInt32,
        indices: [UInt32]
    ) -> Data {
        var data = Data()
        for value in [magic, version, vertexCount, UInt32(indices.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        // positions then normals: 3 floats per vertex each.
        for _ in 0..<(Int(vertexCount) * 6) {
            withUnsafeBytes(of: Float(0)) { data.append(contentsOf: $0) }
        }
        for index in indices {
            withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func triangleMesh() -> RenderMesh {
        RenderMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2]
        )
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTripsExactly() throws {
        let mesh = triangleMesh()
        let decoded = try MeshBlob.decode(MeshBlob.encode(mesh))
        XCTAssertEqual(decoded, mesh)
    }

    func testEmptyMeshRoundTrips() throws {
        let empty = RenderMesh(positions: [], normals: [], indices: [])
        let decoded = try MeshBlob.decode(MeshBlob.encode(empty))
        XCTAssertEqual(decoded.positions.count, 0)
        XCTAssertEqual(decoded.indices.count, 0)
    }

    // MARK: - Malformed input is rejected, never trapped

    func testIndexPastVertexArrayIsRejected() {
        // The crash case: 3 vertices, but a triangle references vertex 99.
        let blob = makeBlob(vertexCount: 3, indices: [0, 1, 99])
        XCTAssertThrowsError(try MeshBlob.decode(blob)) { error in
            guard case MeshBlob.BlobError.corruptIndices = error else {
                return XCTFail("expected corruptIndices, got \(error)")
            }
        }
    }

    func testIndexIntoEmptyVertexArrayIsRejected() {
        let blob = makeBlob(vertexCount: 0, indices: [0, 0, 0])
        XCTAssertThrowsError(try MeshBlob.decode(blob))
    }

    func testIndexCountNotWholeTrianglesIsRejected() {
        let blob = makeBlob(vertexCount: 3, indices: [0, 1])
        XCTAssertThrowsError(try MeshBlob.decode(blob)) { error in
            guard case MeshBlob.BlobError.corruptIndices = error else {
                return XCTFail("expected corruptIndices, got \(error)")
            }
        }
    }

    func testTruncatedPayloadIsRejected() {
        var blob = MeshBlob.encode(triangleMesh())
        blob.removeLast(8)
        XCTAssertThrowsError(try MeshBlob.decode(blob))
    }

    func testBadMagicIsRejected() {
        let blob = makeBlob(magic: 0xDEADBEEF, vertexCount: 3, indices: [0, 1, 2])
        XCTAssertThrowsError(try MeshBlob.decode(blob)) { error in
            guard case MeshBlob.BlobError.badMagic = error else {
                return XCTFail("expected badMagic, got \(error)")
            }
        }
    }

    func testFutureVersionIsRejected() {
        let blob = makeBlob(version: 99, vertexCount: 3, indices: [0, 1, 2])
        XCTAssertThrowsError(try MeshBlob.decode(blob)) { error in
            guard case MeshBlob.BlobError.unsupportedVersion = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testEmptyDataIsRejected() {
        XCTAssertThrowsError(try MeshBlob.decode(Data()))
    }

    // MARK: - Weld quantization survives extreme coordinates

    func testQuantizeClampsBeyondInt32RangeInsteadOfTrapping() {
        // 1e-5 quantum ⇒ anything past ~21.47 m overflowed Int32 and trapped.
        let inv: Float = 1 / 1e-5
        let huge = MeshQuantize.key(50_000, inverseQuantum: inv)
        let hugeNegative = MeshQuantize.key(-50_000, inverseQuantum: inv)
        XCTAssertGreaterThan(huge, 0, "clamped, not wrapped")
        XCTAssertLessThan(hugeNegative, 0, "clamped, not wrapped")
    }

    func testQuantizeMapsNonFiniteToZero() {
        let inv: Float = 1 / 1e-5
        XCTAssertEqual(MeshQuantize.key(.nan, inverseQuantum: inv), 0)
        XCTAssertEqual(MeshQuantize.key(.infinity, inverseQuantum: inv), 0)
        XCTAssertEqual(MeshQuantize.key(-.infinity, inverseQuantum: inv), 0)
    }

    func testQuantizeIsExactInNormalModelRange() {
        let inv: Float = 1 / 1e-5
        XCTAssertEqual(MeshQuantize.key(1, inverseQuantum: inv), 100_000)
        XCTAssertEqual(MeshQuantize.key(-2.5, inverseQuantum: inv), -250_000)
        XCTAssertEqual(MeshQuantize.key(0, inverseQuantum: inv), 0)
    }

    /// A metre-scale import (or a degenerate op emitting NaN) must not crash
    /// while merely extracting feature edges.
    func testFeatureEdgeExtractionOnExtremeCoordinatesDoesNotTrap() {
        let far: Float = 40_000 // 40 m — past the old Int32 weld limit
        let mesh = RenderMesh(
            positions: [SIMD3(far, 0, 0), SIMD3(far + 1, 0, 0), SIMD3(far, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2]
        )
        _ = FeatureEdgeExtractor.edges(from: mesh)
    }

    func testFeatureEdgeExtractionOnNaNCoordinatesDoesNotTrap() {
        let mesh = RenderMesh(
            positions: [SIMD3(.nan, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2]
        )
        _ = FeatureEdgeExtractor.edges(from: mesh)
    }
}
