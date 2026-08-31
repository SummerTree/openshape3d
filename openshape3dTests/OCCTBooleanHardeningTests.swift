//
//  OCCTBooleanHardeningTests.swift
//  openshape3dTests
//
//  The boolean-hygiene contract (docs/FREECAD_PLAYBOOK.md B1/B2): results
//  are unwrapped from their compound, unified, and validated before they are
//  stored, a body-splitting cut is REPORTED rather than silent, and the
//  boolean → shell chain works because shell finally receives in-contract
//  input (review R4-O3). Pure-value tests over OCCTKernel.
//

import XCTest
import simd
@testable import openshape3d

final class OCCTBooleanHardeningTests: XCTestCase {

    /// Two 10-boxes sharing a face. Box primitives sit centered in x/z with
    /// the base on y=0, so a +10 x-translation makes them meet at x=5.
    private func adjacentBoxes() throws -> (BRepHandle, BRepHandle) {
        let a = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10), placement: .identity))
        let b = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10),
            placement: Transform3D(translation: SIMD3(10, 0, 0))))
        return (a, b)
    }

    func testCoplanarFuseUnifiesToSixFaces() throws {
        let (a, b) = try adjacentBoxes()
        let outcome = try OCCTKernel.booleanResult(a, b, op: 0).get()
        XCTAssertEqual(outcome.solidCount, 1)
        // Without ShapeUpgrade_UnifySameDomain the fuse keeps both original
        // top/bottom/front/back faces plus the seam edge — 10 planar faces
        // whose spurious seams are selectable and blendable. Unified, a
        // 20×10×10 slab is a plain box again.
        let counts = OCCTKernel.faceTypeCounts(outcome.handle)
        XCTAssertEqual(counts.planar, 6, "coplanar faces merged, seams gone")
        XCTAssertEqual(OCCTKernel.volume(outcome.handle), 2000, accuracy: 1e-6)
    }

    func testSplittingCutReportsBothSolids() throws {
        let bar = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 30, depth: 10, height: 10), placement: .identity))
        // A tool that severs the bar's middle clean through.
        let blade = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 6, depth: 14, height: 14),
            placement: Transform3D(translation: SIMD3(0, -1, 0))))
        let outcome = try OCCTKernel.booleanResult(bar, blade, op: 1).get()
        XCTAssertEqual(outcome.solidCount, 2,
                       "a cut that splits the body must SAY it did (R4-O3)")
        XCTAssertEqual(OCCTKernel.volume(outcome.handle), 2 * 12 * 10 * 10,
                       accuracy: 1e-6)
    }

    func testCutThatLeavesNothingFailsTyped() throws {
        let small = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10), placement: .identity))
        let bigger = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 20, depth: 20, height: 20),
            placement: Transform3D(translation: SIMD3(0, -1, 0))))
        let result = OCCTKernel.booleanResult(small, bigger, op: 1)
        guard case let .failure(error) = result else {
            return XCTFail("subtracting a superset must fail, not return emptiness")
        }
        XCTAssertTrue(error.message.contains("no solid"), "says why: \(error.message)")
    }

    /// The killer chain (R4-O3): fuse two boxes, then shell the fused top.
    /// Before result normalization the fuse handed shell a raw compound with
    /// duplicated coplanar faces — out of contract for MakeThickSolid.
    func testShellAfterCoplanarFuseSucceeds() throws {
        let (a, b) = try adjacentBoxes()
        let fused = try OCCTKernel.booleanResult(a, b, op: 0).get().handle
        // The fused slab spans x ∈ [-5, 15]; its (unified) top face's centroid
        // sits at (5, 10, 0) — exactly where the seam used to be.
        let hollow = try OCCTKernel.shellResult(
            fused, openingAt: [SIMD3(5, 10, 0)], thickness: 1,
            tolerance: OCCTKernel.matchTolerance(for: fused)).get()
        let volume = OCCTKernel.volume(hollow)
        // Open-top box 20×10×10 with 1 mm walls: 2000 − 18·8·9 = 704.
        XCTAssertEqual(volume, 704, accuracy: 1.0)
    }

    /// T1's canonical case: shelling the top of a thin plate must leave the
    /// bottom CLOSED. With the old body-scaled tolerance the pick ball
    /// (2% of the ~141 mm diagonal ≈ 2.8 mm) dwarfed the 1 mm thickness.
    func testThinPlateShellOpensOnlyTheTop() throws {
        let plate = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 100, depth: 100, height: 1), placement: .identity))
        let hollow = try OCCTKernel.shellResult(
            plate, openingAt: [SIMD3(0, 1, 0)], thickness: 0.3,
            tolerance: OCCTKernel.matchTolerance(for: plate)).get()
        let volume = OCCTKernel.volume(hollow)
        // Open-top: 10000 − 99.4·99.4·0.7 ≈ 3083. Both faces opened would
        // leave ≈ 120 — the failure this test pins against.
        XCTAssertGreaterThan(volume, 2000, "the bottom face stayed closed")
        XCTAssertLessThan(volume, 5000, "…but the shell did hollow the plate")
    }
}
