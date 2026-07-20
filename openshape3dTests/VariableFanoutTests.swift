//
//  VariableFanoutTests.swift
//  openshape3dTests
//
//  Regression guards for the Phase D tranche-3 variable-change fan-out, at the
//  pure level (no DocumentSession/ModelContainer — those crash the test process):
//    • variable commands re-derive the cached value on apply/undo/redo, and
//    • a feature formula whose variable is gone errors to 0 (spec §6.6), instead
//      of silently retaining the last resolved value.
//

import XCTest
@testable import openshape3d

@MainActor
final class VariableFanoutTests: XCTestCase {

    func testVariableCommandsKeepValueCacheConsistentAcrossRedo() {
        var doc = DesignDocument()
        let id = VariableID()
        doc.variables = [Variable(id: id, name: "w", expression: "1", value: 1)]

        // setVariable builds `after` by copying `before` and overwriting only the
        // expression — so after.value is the STALE 1, not the new 2.
        var after = doc.variables[0]
        after.expression = "2"
        let cmd = EditVariableCommand(before: doc.variables[0], after: after)

        cmd.apply(to: &doc)
        XCTAssertEqual(doc.variables[0].value, 2, "apply re-resolves the cached value from the expression")
        cmd.revert(in: &doc)
        XCTAssertEqual(doc.variables[0].value, 1, "revert re-resolves to the prior expression's value")
        cmd.apply(to: &doc)   // redo
        XCTAssertEqual(doc.variables[0].value, 2, "redo re-resolves (not the stale after.value snapshot)")
    }

    func testFeatureFormulaErrorsToZeroWhenVariableMissing() {
        let kind = FeatureKind.extrude(
            profile: ProfileRef(sketchID: SketchID(), entityIDs: [], holeEntityIDs: [], seedPoint: nil),
            plane: PlaneRef(source: .ground),
            distance: Expr(value: 40, formula: "h"),   // driven by variable h
            symmetric: false,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: [])

        // h is undefined (deleted/renamed) → the formula errors to 0.
        guard case let .extrude(_, _, distance, _, _, _)? =
                DocumentSession.reevaluatedKind(kind, with: [:]) else {
            return XCTFail("a broken formula must produce a rebuilt kind (value 0), not nil")
        }
        XCTAssertEqual(distance.value, 0, "a formula whose variable is gone errors to 0")
        XCTAssertEqual(distance.formula, "h", "the formula is preserved so re-adding the variable restores it")
    }

    func testFeatureFormulaResolvesAgainstCurrentVariableValue() {
        let kind = FeatureKind.extrude(
            profile: ProfileRef(sketchID: SketchID(), entityIDs: [], holeEntityIDs: [], seedPoint: nil),
            plane: PlaneRef(source: .ground),
            distance: Expr(value: 40, formula: "h * 2"),
            symmetric: false,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: [])
        guard case let .extrude(_, _, distance, _, _, _)? =
                DocumentSession.reevaluatedKind(kind, with: ["h": 5]) else {
            return XCTFail("expected a rebuilt extrude kind")
        }
        XCTAssertEqual(distance.value, 10, "h*2 with h=5 → 10")
        XCTAssertEqual(distance.formula, "h * 2")
    }
}
