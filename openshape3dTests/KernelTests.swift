//
//  KernelTests.swift
//  openshape3dTests
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class KernelTests: XCTestCase {

    // MARK: - EuclidBridge

    func testCubeRenderMeshWeldsHardEdges() {
        let cube = Euclid.Mesh.cube(size: Vector(1, 1, 1))
        let render = EuclidBridge.renderMesh(from: cube)

        // A welded cube has 24 vertices (4 per face — corners stay split
        // across faces because normals differ) and 12 triangles.
        XCTAssertEqual(render.positions.count, 24)
        XCTAssertEqual(render.normals.count, 24)
        XCTAssertEqual(render.indices.count, 36)
        XCTAssertEqual(render.triangleCount, 12)

        let aabb = render.localAABB
        XCTAssertEqual(aabb.min.x, -0.5, accuracy: 1e-6)
        XCTAssertEqual(aabb.max.y, 0.5, accuracy: 1e-6)
    }

    func testEuclidRoundTripPreservesGeometry() {
        let cylinder = Euclid.Mesh.cylinder(radius: 0.5, height: 2, slices: 48)
        let render = EuclidBridge.renderMesh(from: cylinder)
        let rebuilt = EuclidBridge.euclidMesh(from: render)

        XCTAssertFalse(rebuilt.polygons.isEmpty)
        XCTAssertTrue(rebuilt.isWatertight, "Round-tripped cylinder should stay watertight")

        // Round-trip again through the bridge; the vertex/index counts must be stable.
        let render2 = EuclidBridge.renderMesh(from: rebuilt)
        XCTAssertEqual(render.triangleCount, render2.triangleCount)
        XCTAssertEqual(render.positions.count, render2.positions.count)
    }

    func testPrimitiveBoxSitsOnGround() {
        let box = Euclid.Mesh.primitive(.box(width: 2, depth: 3, height: 4))
        let render = EuclidBridge.renderMesh(from: box)
        let aabb = render.localAABB
        XCTAssertEqual(aabb.min.y, 0, accuracy: 1e-6)
        XCTAssertEqual(aabb.max.y, 4, accuracy: 1e-6)
        XCTAssertEqual(aabb.min.x, -1, accuracy: 1e-6)
        XCTAssertEqual(aabb.max.z, 1.5, accuracy: 1e-6)
    }

    // MARK: - MeshBlob

    func testMeshBlobRoundTrip() throws {
        let sphere = Euclid.Mesh.sphere(radius: 1, slices: 32, stacks: 24)
        let render = EuclidBridge.renderMesh(from: sphere)

        let data = MeshBlob.encode(render)
        let decoded = try MeshBlob.decode(data)

        XCTAssertEqual(decoded, render)
    }

    func testMeshBlobRejectsGarbage() {
        XCTAssertThrowsError(try MeshBlob.decode(Data([1, 2, 3])))
        XCTAssertThrowsError(try MeshBlob.decode(Data(repeating: 0xFF, count: 64)))
    }

    // MARK: - Transform3D

    func testTransformCodableRoundTrip() throws {
        var transform = Transform3D()
        transform.translation = SIMD3(1, 2, 3)
        transform.rotation = simd_quatd(angle: .pi / 3, axis: simd_normalize(SIMD3(1, 1, 0)))
        transform.scale = 2.5

        let data = try JSONEncoder().encode(transform)
        let decoded = try JSONDecoder().decode(Transform3D.self, from: data)

        XCTAssertEqual(decoded.translation, transform.translation)
        XCTAssertEqual(decoded.scale, transform.scale)
        XCTAssertEqual(decoded.rotation.vector.x, transform.rotation.vector.x, accuracy: 1e-12)
        XCTAssertEqual(decoded.rotation.vector.w, transform.rotation.vector.w, accuracy: 1e-12)
    }

    func testTransformMatrixMatchesComponents() {
        var transform = Transform3D()
        transform.translation = SIMD3(5, -1, 2)
        transform.rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        transform.scale = 3

        let point = SIMD3<Double>(1, 0, 0)
        let viaMatrix = transform.matrix * SIMD4(point, 1)
        let direct = transform.applying(to: point)

        XCTAssertEqual(viaMatrix.x, direct.x, accuracy: 1e-9)
        XCTAssertEqual(viaMatrix.y, direct.y, accuracy: 1e-9)
        XCTAssertEqual(viaMatrix.z, direct.z, accuracy: 1e-9)
        // Rotating +X by 90° about +Y lands on -Z, then scale 3 and translate.
        XCTAssertEqual(direct.x, 5, accuracy: 1e-9)
        XCTAssertEqual(direct.z, 2 - 3, accuracy: 1e-9)
    }

    func testTransformEuclidBridgeAgreement() {
        var transform = Transform3D()
        transform.translation = SIMD3(1, 2, 3)
        transform.rotation = simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(0.3, 1, -0.2)))
        transform.scale = 1.5

        let point = SIMD3<Double>(0.4, -0.6, 1.1)
        let ours = transform.applying(to: point)
        let theirs = EuclidBridge.vector(point).transformed(by: transform.euclid)

        XCTAssertEqual(theirs.x, ours.x, accuracy: 1e-9)
        XCTAssertEqual(theirs.y, ours.y, accuracy: 1e-9)
        XCTAssertEqual(theirs.z, ours.z, accuracy: 1e-9)
    }
}
