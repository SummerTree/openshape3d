//
//  PushPullKernelTests.swift
//  openshape3dTests
//
//  KernelOps.pushPullPlanarFace: the pure planar face push/pull extracted from
//  EditorViewModel.faceModifiedMesh so the feature graph can replay it.
//  Outward pull unions a flush prism (taller solid); inward push truncates via
//  a coincident-wall-safe half-space cut (shorter solid, no hanging walls).
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class PushPullKernelTests: XCTestCase {

    /// First triangle whose (CCW) normal points along `target`.
    private func seedTriangle(in mesh: RenderMesh, normal target: SIMD3<Float>) -> Int? {
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            if simd_dot(n, target) > 0.999 { return t }
        }
        return nil
    }

    /// Extract the +Z planar face of `mesh`.
    private func plusZFace(of mesh: Euclid.Mesh) throws -> PlanarFace {
        let render = EuclidBridge.renderMesh(from: mesh)
        let seed = try XCTUnwrap(seedTriangle(in: render, normal: SIMD3(0, 0, 1)),
                                 "box has a +Z triangle")
        return try XCTUnwrap(FaceTopology.planarFace(in: render, seedTriangle: seed),
                             "+Z face is planar")
    }

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)
    }

    private func aabb(_ mesh: Euclid.Mesh) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        EuclidBridge.renderMesh(from: mesh).localAABB
    }

    // .box(width→X=4, depth→Z=6, height→Y=4): X∈[-2,2], Y∈[0,4], Z∈[-3,3].
    // +Z face at z=3, area = X·Y = 16.
    private func makeBox() -> Euclid.Mesh {
        Euclid.Mesh.primitive(.box(width: 4, depth: 6, height: 4))
    }

    func testOutwardPullGrowsBoxByFaceAreaTimesDistance() throws {
        let box = makeBox()
        let face = try plusZFace(of: box)
        let faceArea = MeasureKit.faceArea(
            EuclidBridge.renderMesh(from: box), triangles: face.triangles, scale: 1
        )
        XCTAssertEqual(faceArea, 16, accuracy: 1e-6, "+Z face of a 4×4 cross-section")

        let before = aabb(box)
        let beforeVolume = volume(box)
        let result = KernelOps.pushPullPlanarFace(mesh: box, face: face, distance: 2)

        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight, "Pulled solid must stay watertight")

        // Volume grows by exactly faceArea × distance.
        XCTAssertEqual(volume(result) - beforeVolume, faceArea * 2,
                       accuracy: faceArea * 2 * 0.01)

        // The +Z face advanced by +2; every other extent is unchanged.
        let after = aabb(result)
        XCTAssertEqual(after.max.z, before.max.z + 2, accuracy: 0.02, "Taller: +Z face moved +2")
        XCTAssertEqual(after.min.z, before.min.z, accuracy: 0.02)
        XCTAssertEqual(after.min.x, before.min.x, accuracy: 0.02)
        XCTAssertEqual(after.max.x, before.max.x, accuracy: 0.02)
        XCTAssertEqual(after.min.y, before.min.y, accuracy: 0.02)
        XCTAssertEqual(after.max.y, before.max.y, accuracy: 0.02)
    }

    func testInwardPushShrinksBoxWithNoHangingWalls() throws {
        let box = makeBox()
        let face = try plusZFace(of: box)
        let before = aabb(box)
        let beforeVolume = volume(box)

        let result = KernelOps.pushPullPlanarFace(mesh: box, face: face, distance: -2)

        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight,
                      "Truncated solid must be watertight — hanging walls break this")

        // +Z face pushed inward by 2 → volume shrinks by faceArea × 2 (16·2).
        XCTAssertEqual(beforeVolume - volume(result), 16 * 2,
                       accuracy: 16 * 2 * 0.01)

        let render = EuclidBridge.renderMesh(from: result)
        let after = render.localAABB
        XCTAssertEqual(after.max.z, before.max.z - 2, accuracy: 1e-3, "Truncated: +Z face −2")
        XCTAssertEqual(after.min.z, before.min.z, accuracy: 1e-3, "Back face unchanged")
        XCTAssertEqual(after.min.y, before.min.y, accuracy: 1e-3)
        XCTAssertEqual(after.max.y, before.max.y, accuracy: 1e-3)
        // A clean truncated box stays 12 triangles — extra tris = leftover walls.
        XCTAssertEqual(render.triangleCount, 12, "A truncated box is still a clean box")
    }

    func testZeroDistanceReturnsMeshUnchanged() throws {
        let box = makeBox()
        let face = try plusZFace(of: box)
        let result = KernelOps.pushPullPlanarFace(mesh: box, face: face, distance: 0)
        XCTAssertEqual(volume(result), volume(box), accuracy: 1e-9)
        XCTAssertEqual(result.polygons.count, box.polygons.count)
    }
}
