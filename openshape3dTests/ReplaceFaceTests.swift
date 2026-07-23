//
//  ReplaceFaceTests.swift
//  openshape3dTests
//
//  Spec §4.12 Replace Face. The user-visible contract is simple: after the
//  operation the chosen face sits exactly on the target plane, whether that
//  meant growing the body or cutting it back — so the tests assert the body's
//  bounds and volume, not the intermediate prism.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class ReplaceFaceTests: XCTestCase {

    /// A 10-cube from the origin, and its +Z (top) face.
    private func cube() -> Euclid.Mesh {
        Euclid.Mesh.primitive(.box(width: 10, depth: 10, height: 10))
    }

    private func topFace(of mesh: Euclid.Mesh) throws -> PlanarFace {
        let render = EuclidBridge.renderMesh(from: mesh)
        for t in 0..<render.triangleCount {
            let a = render.positions[Int(render.indices[t * 3])]
            let b = render.positions[Int(render.indices[t * 3 + 1])]
            let c = render.positions[Int(render.indices[t * 3 + 2])]
            let n = simd_cross(b - a, c - a)
            guard simd_length(n) > 1e-9, (n / simd_length(n)).z > 0.999 else { continue }
            if let face = FaceTopology.planarFace(in: render, seedTriangle: t) {
                return face
            }
        }
        throw Refusal.noTopFace
    }

    private enum Refusal: Error { case noTopFace }

    private func volume(_ mesh: Euclid.Mesh) -> Double { KernelOps.volume(of: mesh) }

    private func topZ(_ mesh: Euclid.Mesh) -> Double {
        Double(EuclidBridge.renderMesh(from: mesh).localAABB.max.z)
    }

    // MARK: Planning

    func testATargetAboveTheFaceIsAnExtend() throws {
        let face = try topFace(of: cube())
        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin + SIMD3(0, 0, 4),
            targetNormal: SIMD3(0, 0, 1))
        XCTAssertEqual(plan, .extend(distance: 4))
    }

    func testATargetBelowTheFaceIsATrim() throws {
        let face = try topFace(of: cube())
        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin - SIMD3(0, 0, 3),
            targetNormal: SIMD3(0, 0, 1))
        XCTAssertEqual(plan, .trim(distance: 3))
    }

    func testFlipAlignmentReversesTheDirection() throws {
        let face = try topFace(of: cube())
        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin + SIMD3(0, 0, 4),
            targetNormal: SIMD3(0, 0, 1), flip: true)
        XCTAssertEqual(plan, .trim(distance: 4),
                       "Flip Alignment extends to the other side")
    }

    func testAnInvertedTargetNormalStillPlansFromTheFace() throws {
        // The replacing face may point the other way; only its PLANE matters.
        let face = try topFace(of: cube())
        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin + SIMD3(0, 0, 2),
            targetNormal: SIMD3(0, 0, -1))
        XCTAssertEqual(plan, .extend(distance: 2))
    }

    // MARK: Refusals

    func testANonParallelTargetIsRefused() throws {
        let face = try topFace(of: cube())
        XCTAssertThrowsError(try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin + SIMD3(0, 0, 5),
            targetNormal: simd_normalize(SIMD3(0, 1, 1)))) { error in
            XCTAssertEqual(error as? ReplaceFaceKit.Refusal, .targetNotParallel,
                           "a varying gap cannot be one prism — refuse, don't guess")
        }
    }

    func testATargetOnTheFaceItselfIsRefused() throws {
        let face = try topFace(of: cube())
        XCTAssertThrowsError(try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin, targetNormal: SIMD3(0, 0, 1))) { error in
            XCTAssertEqual(error as? ReplaceFaceKit.Refusal, .noChange)
        }
    }

    // MARK: Applying — where the face ends up

    func testExtendingGrowsTheBodyToTheTargetPlane() throws {
        let solid = cube()
        let face = try topFace(of: solid)
        let before = topZ(solid)

        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin + SIMD3(0, 0, 4),
            targetNormal: SIMD3(0, 0, 1))
        let result = try XCTUnwrap(ReplaceFaceKit.apply(to: solid, face: face, plan: plan))

        XCTAssertEqual(topZ(result), before + 4, accuracy: 1e-6,
                       "the face now sits ON the target plane")
        XCTAssertEqual(volume(result), 1000 + 400, accuracy: 1e-3)
    }

    func testTrimmingCutsTheBodyBackToTheTargetPlane() throws {
        let solid = cube()
        let face = try topFace(of: solid)
        let before = topZ(solid)

        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin - SIMD3(0, 0, 3),
            targetNormal: SIMD3(0, 0, 1))
        let result = try XCTUnwrap(ReplaceFaceKit.apply(to: solid, face: face, plan: plan))

        XCTAssertEqual(topZ(result), before - 3, accuracy: 1e-6)
        XCTAssertEqual(volume(result), 1000 - 300, accuracy: 1e-3)
    }

    func testTheOppositeFaceIsUntouched() throws {
        let solid = cube()
        let face = try topFace(of: solid)
        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin + SIMD3(0, 0, 5),
            targetNormal: SIMD3(0, 0, 1))
        let result = try XCTUnwrap(ReplaceFaceKit.apply(to: solid, face: face, plan: plan))

        XCTAssertEqual(Double(EuclidBridge.renderMesh(from: result).localAABB.min.z),
                       Double(EuclidBridge.renderMesh(from: solid).localAABB.min.z),
                       accuracy: 1e-6,
                       "replacing one face must not move the rest of the body")
    }

    func testAHoleInTheFaceSurvivesAnExtend() throws {
        // A cube with a through-hole: extending the top must not plug it.
        let drilled = cube().subtracting(
            KernelOps.cylinderAlongAxis(
                baseCenter: SIMD3(0, 0, -20), axisDir: SIMD3(0, 0, 1),
                radius: 2, height: 40)).makeWatertight()
        let face = try topFace(of: drilled)
        let plan = try ReplaceFaceKit.plan(
            face: face, targetOrigin: face.origin + SIMD3(0, 0, 4),
            targetNormal: SIMD3(0, 0, 1))
        let result = try XCTUnwrap(ReplaceFaceKit.apply(to: drilled, face: face, plan: plan))

        let added = volume(result) - volume(drilled)
        // The face picker hands back the drilled top as a KEYHOLE outline (the
        // hole seam-connected into the boundary) rather than outline + hole, so
        // the contract is: whatever area the face actually covers, swept.
        XCTAssertEqual(added, abs(Profile.signedArea(face.outline)) * 4,
                       accuracy: 1e-3,
                       "the prism is the face's own area, not its bounding square")
        XCTAssertLessThan(added, 400 - 20,
                          "a plugged extension would have added the full square")
    }

    func testZeroDistanceProducesNoSolid() throws {
        let face = try topFace(of: cube())
        XCTAssertNil(ReplaceFaceKit.sweptSolid(face: face, plan: .extend(distance: 0)))
    }
}
