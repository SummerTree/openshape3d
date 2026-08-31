//
//  OCCTFilletDiagnosticsTests.swift
//  openshape3dTests
//
//  Typed-diagnostics contract for the blend ops (docs/FREECAD_PLAYBOOK.md
//  F1/F2): a failing fillet/chamfer must say WHY — and a partial build must
//  be discarded, never returned. Pure-value tests over OCCTKernel; no
//  DocumentSession/ModelContainer (CLAUDE.md).
//

import XCTest
import simd
@testable import openshape3d

final class OCCTFilletDiagnosticsTests: XCTestCase {

    private func cylinder(radius: Double = 5, height: Double = 20) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: radius, height: height), placement: .identity))
    }
    private func box(_ s: Double = 10) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: s, depth: s, height: s), placement: .identity))
    }
    private func tol(_ h: BRepHandle) -> Double { OCCTKernel.matchTolerance(for: h) }

    // MARK: F1 — the Ø10 rim case (3 mm works / 6 mm was a crash)

    func testModestRimFilletSucceedsAndValidates() throws {
        let cyl = try cylinder()
        let rim = SIMD3<Double>(5, 20, 0)
        let result = OCCTKernel.filletResult(cyl, at: [rim], radius: 3, tolerance: tol(cyl))
        let blended = try XCTUnwrap(try? result.get(), "r=3 on a Ø10 rim must build")
        // Success implies the bridge's BRepCheck_Analyzer pass — spot-check
        // the topology stayed analytic: wall + blend + 2 caps-ish.
        let counts = OCCTKernel.faceTypeCounts(blended)
        XCTAssertGreaterThanOrEqual(counts.cylindrical, 1, "the wall survives")
        XCTAssertLessThan(OCCTKernel.volume(blended), OCCTKernel.volume(cyl),
                          "a fillet removes material")
    }

    func testOversizeRimFilletFailsWithPartialResult() throws {
        let cyl = try cylinder()
        let rim = SIMD3<Double>(5, 20, 0)
        let result = OCCTKernel.filletResult(cyl, at: [rim], radius: 6, tolerance: tol(cyl))
        guard case let .failure(error) = result else {
            return XCTFail("r=6 exceeds the Ø10 rim's geometry — must fail")
        }
        guard case .partialResult = error else {
            return XCTFail("expected .partialResult (radius too large), got \(error)")
        }
        XCTAssertTrue(error.message.contains("try a smaller value"),
                      "actionable message: \(error.message)")
    }

    func testOversizeChamferFailsTyped() throws {
        let b = try box()
        // A vertical edge of the 10-box: (5, mid-height, 5).
        let edge = SIMD3<Double>(5, 5, 5)
        let ok = OCCTKernel.chamferResult(b, at: [edge], distance: 2, tolerance: tol(b))
        XCTAssertNotNil(try? ok.get(), "a 2 mm chamfer on a 10-box edge builds")
        let result = OCCTKernel.chamferResult(b, at: [edge], distance: 20, tolerance: tol(b))
        guard case .failure = result else {
            return XCTFail("a 20 mm chamfer on a 10-box must fail, not ship garbage")
        }
    }

    // MARK: F2 — unblendable picks are refused up front, with the reason

    func testSpherePickIsRefusedAsNoTarget() throws {
        let sphere = try XCTUnwrap(OCCTKernel.primitiveShape(
            .sphere(radius: 5), placement: .identity))
        // A point on the equator: the only "edges" a sphere has are its seam
        // meridian and the degenerate pole edges — none blendable.
        let equator = SIMD3<Double>(5, 5, 0)
        let result = OCCTKernel.filletResult(sphere, at: [equator], radius: 1,
                                             tolerance: 10)  // generous: force a match
        guard case let .failure(error) = result else {
            return XCTFail("a sphere has no blendable edge — must fail")
        }
        guard case .noTargetMatched = error else {
            return XCTFail("expected .noTargetMatched (seam/degenerate filter), got \(error)")
        }
    }

    func testPickFarFromEveryEdgeSaysSo() throws {
        let b = try box()
        // Center of the top face: ~5 mm from every edge, far outside the
        // deflection-derived tolerance (~0.4 mm).
        let result = OCCTKernel.filletResult(b, at: [SIMD3(0, 10, 0)],
                                             radius: 1, tolerance: tol(b))
        guard case let .failure(error) = result, case .noTargetMatched = error else {
            return XCTFail("a face-center pick must miss, and say so")
        }
    }
}
