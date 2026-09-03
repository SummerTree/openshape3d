import XCTest
@testable import openshape3d

/// A drag's structural DOF is invariant across its ticks, so the drag path
/// analyses the null space once and passes the DOF back on later ticks.
final class DragTickDOFTests: XCTestCase {
    func testAKnownDOFSkipsTheAnalysisButNotTheSolve() {
        // Two welded horizontal lines, free otherwise; drag the far end.
        let a = UUID(), b = UUID()
        let sketch = Sketch(
            plane: .ground,
            entities: [
                .line(id: a, a: SIMD2(0, 0), b: SIMD2(10, 0)),
                .line(id: b, a: SIMD2(10, 0), b: SIMD2(20, 0)),
            ],
            constraints: [
                SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: a, role: .whole)]),
                SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: b, role: .whole)]),
                SketchConstraint(kind: .coincident, refs: [
                    ConstraintRef(entityID: a, role: .endpointB),
                    ConstraintRef(entityID: b, role: .endpointA),
                ]),
            ])
        let analysed = SketchSolverBridge.solveOutcome(
            sketch, movingEntity: b, dragTarget: SIMD2(25, 3))
        let passedBack = SketchSolverBridge.solveOutcome(
            sketch, movingEntity: b, dragTarget: SIMD2(25, 3), knownDOF: analysed.dof)
        XCTAssertGreaterThan(analysed.dof, 0)
        XCTAssertEqual(passedBack.dof, analysed.dof)
        XCTAssertEqual(passedBack.entities, analysed.entities, "same solve, only the analysis skipped")
        XCTAssertEqual(passedBack.structuralResidual, analysed.structuralResidual, accuracy: 1e-12)
        // And it is reported verbatim, never re-derived.
        XCTAssertEqual(SketchSolverBridge.solveOutcome(
            sketch, movingEntity: b, dragTarget: SIMD2(25, 3), knownDOF: 42).dof, 42)
    }
}
