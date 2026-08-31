//
//  ShapeHealthTests.swift
//  openshape3dTests
//
//  The geometry health report (docs/FREECAD_PLAYBOOK.md D1): a healthy solid
//  reports clean with real context numbers; a deliberately broken one names
//  its faults per sub-shape; the slow BOP check runs only when asked AND only
//  on a shape that already passed BRepCheck. Pure values over OCCTKernel —
//  no DocumentSession/ModelContainer.
//

import XCTest
import simd
@testable import openshape3d

final class ShapeHealthTests: XCTestCase {

    private func box(_ size: Double) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: size, depth: size, height: size), placement: .identity))
    }

    private func invalidOpenBox(_ size: Double = 10) throws -> BRepHandle {
        try BRepHandle(XCTUnwrap(OCCTBridge.debugInvalidOpenBox(withSize: size)))
    }

    // MARK: - Healthy shapes

    func testAValidBoxReportsHealthyWithRealNumbers() throws {
        let health = OCCTKernel.healthReport(for: try box(10))
        XCTAssertTrue(health.isValid)
        XCTAssertTrue(health.findings.isEmpty)
        XCTAssertNil(health.error)
        XCTAssertEqual(health.counts["solids"], 1)
        XCTAssertEqual(health.counts["faces"], 6)
        XCTAssertEqual(health.counts["edges"], 12)
        XCTAssertEqual(health.counts["vertices"], 8)
        XCTAssertEqual(health.volumeMM3, 1000, accuracy: 1e-9)
        // A fresh analytic primitive sits at Precision::Confusion() (1e-7).
        XCTAssertLessThanOrEqual(health.toleranceMax, 1e-6)
        // A closed solid has no free boundary wires.
        XCTAssertEqual(health.openFreeWires, 0)
    }

    func testACylinderReportsItsAnalyticFaces() throws {
        let cylinder = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 4, height: 6), placement: .identity))
        let health = OCCTKernel.healthReport(for: cylinder)
        XCTAssertTrue(health.isValid)
        XCTAssertEqual(health.counts["faces"], 3)  // 2 caps + 1 wall
        XCTAssertEqual(health.volumeMM3, Double.pi * 16 * 6, accuracy: 1e-6)
    }

    // MARK: - Faulty shapes

    /// The DEBUG factory builds a box whose shell is missing one face — the
    /// solid cannot be closed, and the report must SAY so, naming the
    /// offending sub-shape rather than shrugging "invalid".
    func testTheOpenBoxIsDiagnosedAsNotClosed() throws {
        let health = OCCTKernel.healthReport(for: try invalidOpenBox())
        XCTAssertFalse(health.isValid)
        XCTAssertFalse(health.findings.isEmpty,
                       "an invalid shape must carry at least one named finding")
        XCTAssertTrue(health.findings.contains { $0.status == "notClosed" },
                      "expected a notClosed finding, got: \(health.findingsSummary)")
        // Five faces of the box survive; the report's context numbers agree.
        XCTAssertEqual(health.counts["faces"], 5)
        XCTAssertFalse(health.findingsSummary.isEmpty)
    }

    /// The missing face leaves exactly one free boundary loop — and because
    /// its edges close into a rectangle, it is a CLOSED free wire (open free
    /// wires are unclosed chains, a different kind of sick).
    func testTheOpenBoxHasOneFreeBoundaryLoop() throws {
        let health = OCCTKernel.healthReport(for: try invalidOpenBox())
        XCTAssertEqual(health.closedFreeWires, 1)
        XCTAssertEqual(health.openFreeWires, 0)
    }

    // MARK: - BOP check gating

    func testBOPCheckRunsOnAValidShapeAndFindsNothingWrongWithABox() throws {
        let health = OCCTKernel.healthReport(for: try box(10), runBOPCheck: true)
        XCTAssertTrue(health.bopCheckRan)
        XCTAssertTrue(health.bopFindings.isEmpty,
                      "a plain box has no BOP faults, got: \(health.bopFindings)")
    }

    func testBOPCheckIsDeclinedForAnInvalidShape() throws {
        // FreeCAD's gating, kept deliberately: the BOP check is advisory and
        // slow, and running it on a shape BRepCheck already condemned only
        // buries the real findings.
        let health = OCCTKernel.healthReport(for: try invalidOpenBox(),
                                             runBOPCheck: true)
        XCTAssertFalse(health.bopCheckRan)
    }

    func testBOPCheckIsNotRunUnlessRequested() throws {
        let health = OCCTKernel.healthReport(for: try box(4))
        XCTAssertFalse(health.bopCheckRan)
    }

    // MARK: - Transport

    /// The raw dictionary is served verbatim by /v1/check, so it must be
    /// JSON-encodable exactly as the bridge hands it over — for the healthy,
    /// the broken, and the BOP-checked case alike.
    func testHealthReportDictionariesAreJSONSafe() throws {
        for handle in [try box(10), try invalidOpenBox()] {
            let dictionary = OCCTKernel.healthReportDictionary(
                for: handle, runBOPCheck: true)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dictionary))
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: dictionary))
        }
    }

    /// A result straight out of a boolean must read as healthy — this is the
    /// integration the report exists for: "did the op hand back something
    /// sick" answered by numbers instead of squinting at the viewport.
    func testABooleanResultReportsHealthy() throws {
        let plate = try box(10)
        let cutter = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 2, height: 20), placement: .identity))
        let result = try OCCTKernel.booleanResult(plate, cutter, op: 1).get()
        let health = OCCTKernel.healthReport(for: result.handle, runBOPCheck: true)
        XCTAssertTrue(health.isValid)
        XCTAssertTrue(health.bopCheckRan)
        XCTAssertTrue(health.bopFindings.isEmpty)
    }
}
