//
//  MoveFaceKernelTests.swift
//  openshape3dTests
//
//  KernelOps.moveFace: the general Shapr3D "Move" on a face. Translating a
//  face's vertices by a 3D delta deforms the solid — a lateral move shears a
//  box into a parallelepiped (volume preserved), a normal move thickens it
//  (volume grows by faceArea·distance, matching push/pull).
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class MoveFaceKernelTests: XCTestCase {

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

    /// Extract the +Y (top) planar face of `mesh`.
    private func topFace(of mesh: Euclid.Mesh) throws -> PlanarFace {
        let render = EuclidBridge.renderMesh(from: mesh)
        let seed = try XCTUnwrap(seedTriangle(in: render, normal: SIMD3(0, 1, 0)),
                                 "box has a +Y triangle")
        return try XCTUnwrap(FaceTopology.planarFace(in: render, seedTriangle: seed),
                             "+Y face is planar")
    }

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)
    }

    private func aabb(_ mesh: Euclid.Mesh) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        EuclidBridge.renderMesh(from: mesh).localAABB
    }

    // .box(width→X=4, depth→Z=6, height→Y=4): X∈[-2,2], Y∈[0,4], Z∈[-3,3].
    // Top (+Y) face at y=4, area = X·Z = 24.
    private func makeBox() -> Euclid.Mesh {
        Euclid.Mesh.primitive(.box(width: 4, depth: 6, height: 4))
    }

    /// Sliding the top face sideways shears the box into a parallelepiped: the
    /// top slab translates, the walls skew to follow, the base holds, and the
    /// volume is unchanged (a shear preserves volume).
    func testLateralMoveShearsBoxAndPreservesVolume() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let before = aabb(box)
        let beforeVolume = volume(box)

        let result = KernelOps.moveFace(mesh: box, face: top, delta: SIMD3(2, 0, 0))

        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight, "A sheared solid must stay watertight")
        XCTAssertEqual(volume(result), beforeVolume, accuracy: beforeVolume * 0.01,
                       "A lateral face move shears the solid — volume is unchanged")

        let after = aabb(result)
        XCTAssertEqual(after.max.x, before.max.x + 2, accuracy: 0.02,
                       "The top face slid +2 in X, so the far corner reaches x=4")
        XCTAssertEqual(after.min.x, before.min.x, accuracy: 0.02,
                       "The base did not move")
        XCTAssertEqual(after.min.y, before.min.y, accuracy: 0.02)
        XCTAssertEqual(after.max.y, before.max.y, accuracy: 0.02, "Height unchanged")
    }

    /// A user-DRAWN box (sketch rect → extrude) has different mesh topology than
    /// a primitive box — the top cap and side walls come from separate kernel
    /// steps. The lateral face move must still shear it (walls follow, volume
    /// preserved), or a drawn box would "move the face without shearing".
    func testLateralMoveShearsAnExtrudedBox() throws {
        let rect = Profile(
            loop: [SIMD2(-2, -2), SIMD2(2, -2), SIMD2(2, 2), SIMD2(-2, 2)],
            kind: .polygonal, sourceEntityIDs: [])
        // Extrude on the ground plane (+Y normal): a 4×4×4 box, y∈[0,4].
        let box = KernelOps.extrude(
            profile: rect, holes: [], in: .ground, distance: 4, symmetric: false)
        XCTAssertFalse(box.polygons.isEmpty, "extrude produced a solid")
        let top = try topFace(of: box)
        let beforeVolume = volume(box)
        let beforeMaxX = aabb(box).max.x

        let result = KernelOps.moveFace(mesh: box, face: top, delta: SIMD3(2, 0, 0))

        XCTAssertTrue(result.isWatertight, "A sheared drawn box must stay watertight")
        XCTAssertEqual(volume(result), beforeVolume, accuracy: beforeVolume * 0.02,
                       "A lateral face move shears the drawn box — volume unchanged")
        XCTAssertEqual(aabb(result).max.x, beforeMaxX + 2, accuracy: 0.1,
                       "The top face slid +2 in X (the walls followed — it sheared)")
        XCTAssertEqual(aabb(result).min.y, aabb(box).min.y, accuracy: 0.05, "base held")
    }

    /// Moving the top face along its own normal thickens the box, exactly like a
    /// positive push/pull: volume grows by faceArea · distance.
    func testNormalMoveThickensLikePushPull() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let beforeVolume = volume(box)

        let result = KernelOps.moveFace(mesh: box, face: top, delta: SIMD3(0, 2, 0))

        XCTAssertTrue(result.isWatertight)
        XCTAssertEqual(volume(result) - beforeVolume, 24 * 2, accuracy: 24 * 2 * 0.02,
                       "Top face area (24) × 2 = +48")
        XCTAssertEqual(aabb(result).max.y, 6, accuracy: 0.02, "Top rose from y=4 to y=6")
    }

    func testZeroDeltaReturnsMeshUnchanged() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let result = KernelOps.moveFace(mesh: box, face: top, delta: .zero)
        XCTAssertEqual(volume(result), volume(box), accuracy: 1e-9)
    }

    // MARK: - Scale face (taper)

    /// Scaling the top face DOWN about its centre tapers the box into a frustum:
    /// the top shrinks, the walls slope in, the base holds, the height is kept.
    func testUniformScaleDownTapersBoxIntoFrustum() throws {
        let box = makeBox()                 // 4(X) × 6(Z) × 4(Y), top area 24
        let top = try topFace(of: box)

        let result = KernelOps.scaleFace(mesh: box, face: top, factor: 0.5)

        XCTAssertTrue(result.isWatertight, "A tapered box (frustum) stays watertight")
        // Frustum: V = (h/3)(A_b + A_t + √(A_b·A_t)) = (4/3)(24 + 6 + 12) = 56.
        XCTAssertEqual(volume(result), 56, accuracy: 56 * 0.03,
                       "top face scaled ×0.5 → frustum volume 56")
        XCTAssertEqual(aabb(result).min.y, aabb(box).min.y, accuracy: 0.02, "base held")
        XCTAssertEqual(aabb(result).max.y, aabb(box).max.y, accuracy: 0.02, "height unchanged")
    }

    /// Scaling the top face UP flares it out past the base (top wider than base).
    func testUniformScaleUpFlaresTopBeyondBase() throws {
        let box = makeBox()
        let top = try topFace(of: box)

        let result = KernelOps.scaleFace(mesh: box, face: top, factor: 1.5)

        XCTAssertTrue(result.isWatertight)
        // Top X half-extent 2 × 1.5 = 3, so the flared top reaches x = 3 (> base 2).
        XCTAssertEqual(aabb(result).max.x, 3, accuracy: 0.1, "flared top reaches past the base")
        XCTAssertGreaterThan(volume(result), volume(box), "a flared frustum has more volume")
    }

    func testScaleFactorOneIsNoOp() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        XCTAssertEqual(volume(KernelOps.scaleFace(mesh: box, face: top, factor: 1)),
                       volume(box), accuracy: 1e-9)
    }
}
