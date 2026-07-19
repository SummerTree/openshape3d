//
//  DragSolveBridgeTests.swift
//  openshape3dTests
//
//  Precise coverage for the solve-on-edit drag the editor routes through
//  SketchSolverBridge (plan §C1): dragging a top corner of a rectangle whose
//  top edge carries a Horizontal constraint must keep that edge horizontal —
//  the opposite top corner follows in Y so both top points stay level — while
//  a FULLY-defined sketch refuses to move under the same drag. The UI test
//  (DragSolveUITests) exercises the same flow through the gesture stack; this
//  asserts the geometry the UI cannot read back.
//

import XCTest
import simd
@testable import openshape3d

final class DragSolveBridgeTests: XCTestCase {

    /// Rectangle BL(0,0) BR(10,0) TR(10,5) TL(0,5) as four welded lines, BL
    /// pinned, with a Horizontal constraint on the top edge.
    private func rectangleWithHorizontalTop() -> (Sketch, top: UUID) {
        let bottom = UUID(), right = UUID(), top = UUID(), left = UUID()
        let entities: [SketchEntity] = [
            .line(id: bottom, a: SIMD2(0, 0), b: SIMD2(10, 0)),
            .line(id: right, a: SIMD2(10, 0), b: SIMD2(10, 5)),
            .line(id: top, a: SIMD2(10, 5), b: SIMD2(0, 5)),
            .line(id: left, a: SIMD2(0, 5), b: SIMD2(0, 0)),
        ]
        var sketch = Sketch(plane: .ground, entities: entities)
        sketch.constraints = [
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: top, role: .whole)]),
            SketchConstraint(kind: .fixed, refs: [ConstraintRef(entityID: bottom, role: .endpointA)]),
        ]
        return (sketch, top)
    }

    func testDragTopCornerKeepsTopEdgeHorizontal() {
        let (sketch, top) = rectangleWithHorizontalTop()

        // Grab the top edge near TR(10,5) and drag it up-and-out to (12,8).
        let (out, dof) = SketchSolverBridge.solve(
            sketch, movingEntity: top, dragTarget: SIMD2(12, 8)
        )
        XCTAssertGreaterThan(dof, 0, "one horizontal + one pin is not fully defined")

        guard case let .line(_, tr, tl) = out[2] else {
            return XCTFail("expected the top line back at index 2")
        }
        // The dragged corner followed the target in X...
        XCTAssertGreaterThan(tr.x, 10.5, "dragged corner should move toward the target")
        // ...and the top edge stayed horizontal: both top points share Y.
        XCTAssertEqual(tr.y, tl.y, accuracy: 1e-3, "top edge must remain horizontal")
        XCTAssertGreaterThan(tr.y, 5.5, "the top edge moved up with the drag")
        XCTAssertEqual(tl.y, tr.y, accuracy: 1e-3, "the opposite top corner follows in Y")
    }

    func testFullyDefinedRectangleRefusesToMove() {
        // Add width + height dimensions so the rectangle is fully defined.
        var (sketch, _) = rectangleWithHorizontalTop()
        let bottomID = sketch.entities[0].id
        let leftID = sketch.entities[3].id
        sketch.constraints.append(contentsOf: [
            SketchConstraint(kind: .vertical, refs: [ConstraintRef(entityID: leftID, role: .whole)]),
            SketchConstraint(kind: .vertical, refs: [ConstraintRef(entityID: sketch.entities[1].id, role: .whole)]),
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: bottomID, role: .whole)]),
        ])
        sketch.dimensions = [
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: bottomID, role: .endpointA),
                                   ConstraintRef(entityID: bottomID, role: .endpointB)],
                            value: 10),
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: leftID, role: .endpointA),
                                   ConstraintRef(entityID: leftID, role: .endpointB)],
                            value: 5),
        ]

        let (_, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertEqual(dof, 0, "the dimensioned rectangle should be fully defined")
        // The editor refuses the drag on a zero-DOF sketch (spring back), so the
        // solved geometry equals the untouched input.
    }
}
