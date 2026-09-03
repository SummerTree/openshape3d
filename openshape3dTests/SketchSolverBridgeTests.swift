//
//  SketchSolverBridgeTests.swift
//  openshape3dTests
//
//  Coverage for the Phase C sketch → solver bridge: fully-defined DOF, drag-
//  to-solve with welded coincident endpoints, driving dimensions, and
//  backward-compatible Codable of the new constraint/dimension model.
//

import XCTest
import simd
@testable import openshape3d

final class SketchSolverBridgeTests: XCTestCase {

    // MARK: - 1. Fully-defined rectangle

    func testConstrainedRectangleIsFullyDefined() {
        let l0 = UUID(), l1 = UUID(), l2 = UUID(), l3 = UUID()
        // Corners p0=(0,0) p1=(10,0) p2=(10,5) p3=(0,5), drawn as four lines
        // whose endpoints coincide and weld into four shared points.
        let entities: [SketchEntity] = [
            .line(id: l0, a: SIMD2(0, 0), b: SIMD2(10, 0)),  // bottom
            .line(id: l1, a: SIMD2(10, 0), b: SIMD2(10, 5)), // right
            .line(id: l2, a: SIMD2(10, 5), b: SIMD2(0, 5)),  // top
            .line(id: l3, a: SIMD2(0, 5), b: SIMD2(0, 0)),   // left
        ]
        var sketch = Sketch(plane: .ground, entities: entities)
        sketch.constraints = [
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: l0, role: .whole)]),
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: l2, role: .whole)]),
            SketchConstraint(kind: .vertical, refs: [ConstraintRef(entityID: l1, role: .whole)]),
            SketchConstraint(kind: .vertical, refs: [ConstraintRef(entityID: l3, role: .whole)]),
            SketchConstraint(kind: .fixed, refs: [ConstraintRef(entityID: l0, role: .endpointA)]),
        ]
        sketch.dimensions = [
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: l0, role: .endpointA),
                                   ConstraintRef(entityID: l0, role: .endpointB)],
                            value: 10),
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: l3, role: .endpointA),
                                   ConstraintRef(entityID: l3, role: .endpointB)],
                            value: 5),
        ]

        let (out, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertEqual(dof, 0, "a fully constrained rectangle should have zero DOF")
        XCTAssertEqual(out.count, 4)

        let states = SketchSolverBridge.entityStates(sketch)
        for e in entities {
            XCTAssertEqual(states[e.id], true, "entity \(e.id) should be fully defined (green)")
        }
    }

    func testUnderDefinedRectangleReportsDOFAndBlueEntities() {
        // Same rectangle without the fixed corner or dimensions: free to
        // translate/scale, so it is NOT fully defined.
        let l0 = UUID(), l1 = UUID(), l2 = UUID(), l3 = UUID()
        let entities: [SketchEntity] = [
            .line(id: l0, a: SIMD2(0, 0), b: SIMD2(10, 0)),
            .line(id: l1, a: SIMD2(10, 0), b: SIMD2(10, 5)),
            .line(id: l2, a: SIMD2(10, 5), b: SIMD2(0, 5)),
            .line(id: l3, a: SIMD2(0, 5), b: SIMD2(0, 0)),
        ]
        var sketch = Sketch(plane: .ground, entities: entities)
        sketch.constraints = [
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: l0, role: .whole)]),
            SketchConstraint(kind: .vertical, refs: [ConstraintRef(entityID: l1, role: .whole)]),
        ]
        let (_, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertGreaterThan(dof, 0, "under-constrained sketch should report remaining DOF")
        let states = SketchSolverBridge.entityStates(sketch)
        // At least one entity is under-defined (blue).
        XCTAssertTrue(states.values.contains(false))
    }

    // MARK: - 2. Drag-to-solve pulls welded coincident endpoints

    func testDragMovesPointAndConnectedEndpointsFollow() {
        let la = UUID(), lb = UUID()
        // Two collinear lines sharing an endpoint at (5,0), fully under-defined.
        let entities: [SketchEntity] = [
            .line(id: la, a: SIMD2(0, 0), b: SIMD2(5, 0)),
            .line(id: lb, a: SIMD2(5, 0), b: SIMD2(10, 0)),
        ]
        let sketch = Sketch(plane: .ground, entities: entities)

        // Grab line A near its shared endpoint and drag it to (5,3).
        let (out, _) = SketchSolverBridge.solve(sketch, movingEntity: la, dragTarget: SIMD2(5, 3))
        guard case let .line(_, a0, a1) = out[0],
              case let .line(_, b0, b1) = out[1] else {
            return XCTFail("expected two lines back")
        }

        // Dragged (shared) point moved to the target...
        XCTAssertEqual(a1.x, 5, accuracy: 1e-2)
        XCTAssertEqual(a1.y, 3, accuracy: 1e-2)
        // ...and line B's coincident endpoint followed it.
        XCTAssertEqual(b0.x, 5, accuracy: 1e-2)
        XCTAssertEqual(b0.y, 3, accuracy: 1e-2)
        // Free, unconstrained endpoints stay put.
        XCTAssertEqual(a0.x, 0, accuracy: 1e-2)
        XCTAssertEqual(a0.y, 0, accuracy: 1e-2)
        XCTAssertEqual(b1.x, 10, accuracy: 1e-2)
        XCTAssertEqual(b1.y, 0, accuracy: 1e-2)
    }

    // MARK: - 3. Dimension change drives geometry

    /// A rectangle's only solver points are its two corners, so its width
    /// and height are axis distances between them (`.horizontal` /
    /// `.vertical`), not a corner-to-corner `.distance` (the diagonal). This
    /// is what lets a Rect-tool rectangle be dimensioned in the UI at all —
    /// before, a selected rect offered no dimension.
    func testRectWidthAndHeightDimensionsDriveItsCorners() {
        let r = UUID()
        var sketch = Sketch(plane: .ground,
                            entities: [.rect(id: r, min: SIMD2(0, 0), max: SIMD2(7, 1.2))])
        sketch.constraints = [
            SketchConstraint(kind: .fixed, refs: [ConstraintRef(entityID: r, role: .endpointA)]),
        ]
        let corners = [ConstraintRef(entityID: r, role: .endpointA),
                       ConstraintRef(entityID: r, role: .endpointB)]
        sketch.dimensions = [
            SketchDimension(kind: .horizontal, refs: corners, value: 950),
            SketchDimension(kind: .vertical, refs: corners, value: 230),
        ]

        let (out, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertEqual(dof, 0, "a fixed corner + width + height pins all four rect DOF")
        guard case let .rect(_, mn, mx) = out[0] else { return XCTFail("expected the rect back") }
        XCTAssertEqual(mn.x, 0, accuracy: 1e-6, "fixed corner stays put")
        XCTAssertEqual(mn.y, 0, accuracy: 1e-6)
        XCTAssertEqual(mx.x, 950, accuracy: 1e-3, "width dimension drives the far corner's x")
        XCTAssertEqual(mx.y, 230, accuracy: 1e-3, "height dimension drives the far corner's y")

        // A rect drawn the other way round (max corner fixed) shrinks toward
        // it instead of flipping through zero: the sign is captured as drawn.
        var flipped = Sketch(plane: .ground,
                             entities: [.rect(id: r, min: SIMD2(-40, -10), max: SIMD2(0, 0))])
        flipped.constraints = [
            SketchConstraint(kind: .fixed, refs: [ConstraintRef(entityID: r, role: .endpointB)]),
        ]
        flipped.dimensions = [SketchDimension(kind: .horizontal, refs: corners, value: 10)]
        let (out2, _) = SketchSolverBridge.solve(flipped, movingEntity: nil, dragTarget: nil)
        guard case let .rect(_, mn2, mx2) = out2[0] else { return XCTFail("expected the rect back") }
        XCTAssertEqual(mx2.x, 0, accuracy: 1e-6)
        XCTAssertEqual(mn2.x, -10, accuracy: 1e-3, "the min corner moved toward the fixed max corner")
        XCTAssertLessThan(mn2.x, mx2.x, "still a proper min/max rect")
    }

    func testDistanceDimensionDrivesLength() {
        let l = UUID()
        var sketch = Sketch(plane: .ground,
                            entities: [.line(id: l, a: SIMD2(0, 0), b: SIMD2(10, 0))])
        sketch.constraints = [
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: l, role: .whole)]),
            SketchConstraint(kind: .fixed, refs: [ConstraintRef(entityID: l, role: .endpointA)]),
        ]
        sketch.dimensions = [
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: l, role: .endpointA),
                                   ConstraintRef(entityID: l, role: .endpointB)],
                            value: 20),
        ]

        let (out, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)
        guard case let .line(_, a, b) = out[0] else { return XCTFail("expected a line back") }
        XCTAssertEqual(b.x, 20, accuracy: 1e-2, "length dimension should stretch the line to 20")
        XCTAssertEqual(b.y, 0, accuracy: 1e-2)
        XCTAssertEqual(a.x, 0, accuracy: 1e-2, "fixed endpoint stays put")
        XCTAssertEqual(a.y, 0, accuracy: 1e-2)
        XCTAssertEqual(dof, 0, "fixed + horizontal + length is fully defined")
    }

    // MARK: - 4. Codable round-trip + legacy decode

    func testCodableRoundTripWithConstraintsAndDimensions() throws {
        let l0 = UUID(), l1 = UUID(), c0 = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: l0, a: SIMD2(0, 0), b: SIMD2(10, 0)),
            .line(id: l1, a: SIMD2(10, 0), b: SIMD2(10, 5)),
            .circle(id: c0, center: SIMD2(3, 3), radius: 2),
        ])
        sketch.constraints = [
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: l0, role: .whole)]),
            SketchConstraint(kind: .coincident,
                             refs: [ConstraintRef(entityID: l0, role: .endpointB),
                                    ConstraintRef(entityID: l1, role: .endpointA)]),
        ]
        sketch.dimensions = [
            SketchDimension(kind: .radius, refs: [ConstraintRef(entityID: c0, role: .whole)], value: 2),
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: l0, role: .endpointA),
                                   ConstraintRef(entityID: l0, role: .endpointB)],
                            value: 10),
        ]

        let data = try JSONEncoder().encode(sketch)
        let decoded = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertEqual(decoded, sketch)
        XCTAssertEqual(decoded.constraints.count, 2)
        XCTAssertEqual(decoded.dimensions.count, 2)

        // Legacy document: strip the new keys and confirm it still decodes with
        // empty constraints/dimensions (backward compatible).
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "constraints")
        obj.removeValue(forKey: "dimensions")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let legacy = try JSONDecoder().decode(Sketch.self, from: legacyData)
        XCTAssertEqual(legacy.constraints, [])
        XCTAssertEqual(legacy.dimensions, [])
        XCTAssertEqual(legacy.entities.count, 3)
    }

    // MARK: - Conflict attribution (diagnosis stage 2)

    /// Two dueling lengths on the same line: the solver's compromise (110)
    /// leaves both rows carrying error, so BOTH dimensions are attributed —
    /// there is no innocent party until the user picks one. The satisfied
    /// horizontal constraint stays clean.
    func testDuelingLengthsAttributeBothDimensionsOnly() {
        let line = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: line, a: SIMD2(0, 0), b: SIMD2(100, 0)),
        ])
        let horizontal = SketchConstraint(
            kind: .horizontal, refs: [ConstraintRef(entityID: line, role: .whole)])
        sketch.constraints = [
            horizontal,
            SketchConstraint(kind: .fixed,
                             refs: [ConstraintRef(entityID: line, role: .endpointA)]),
        ]
        let want100 = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: line, role: .endpointA),
                   ConstraintRef(entityID: line, role: .endpointB)],
            value: 100)
        let want120 = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: line, role: .endpointA),
                   ConstraintRef(entityID: line, role: .endpointB)],
            value: 120)
        sketch.dimensions = [want100, want120]

        let blame = SketchSolverBridge.conflictAttribution(sketch)
        XCTAssertEqual(blame.dimensionIDs, [want100.id, want120.id])
        XCTAssertTrue(blame.constraintIDs.isEmpty,
                      "the horizontal constraint is satisfied: \(blame.constraintIDs)")
    }

    /// A line whose two endpoints are LOCKED at 100 apart, dimensioned 120:
    /// the dimension alone carries the whole error and is attributed alone.
    func testAWrongDimensionOnLockedGeometryIsAttributedAlone() {
        let line = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: line, a: SIMD2(0, 0), b: SIMD2(100, 0)),
        ])
        let horizontal = SketchConstraint(
            kind: .horizontal, refs: [ConstraintRef(entityID: line, role: .whole)])
        sketch.constraints = [
            horizontal,
            SketchConstraint(kind: .fixed,
                             refs: [ConstraintRef(entityID: line, role: .endpointA)]),
            SketchConstraint(kind: .fixed,
                             refs: [ConstraintRef(entityID: line, role: .endpointB)]),
        ]
        let wrong = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: line, role: .endpointA),
                   ConstraintRef(entityID: line, role: .endpointB)],
            value: 120)
        sketch.dimensions = [wrong]

        let blame = SketchSolverBridge.conflictAttribution(sketch)
        XCTAssertEqual(blame.dimensionIDs, [wrong.id])
        XCTAssertTrue(blame.constraintIDs.isEmpty, "\(blame.constraintIDs)")
    }

    // MARK: - Conflict partners (diagnosis stage 3, add-time)

    /// The dueling-lengths sketch, asked from dim-120's point of view: the
    /// one partner whose removal lets the rest solve is dim-100 — not the
    /// satisfied horizontal, not the lock.
    func testConflictPartnersOfADuelingLengthNameTheOtherLength() {
        let line = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: line, a: SIMD2(0, 0), b: SIMD2(100, 0)),
        ])
        sketch.constraints = [
            SketchConstraint(kind: .horizontal,
                             refs: [ConstraintRef(entityID: line, role: .whole)]),
            SketchConstraint(kind: .fixed,
                             refs: [ConstraintRef(entityID: line, role: .endpointA)]),
        ]
        let want100 = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: line, role: .endpointA),
                   ConstraintRef(entityID: line, role: .endpointB)],
            value: 100)
        let want120 = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: line, role: .endpointA),
                   ConstraintRef(entityID: line, role: .endpointB)],
            value: 120)
        sketch.dimensions = [want100, want120]

        let partners = SketchSolverBridge.conflictPartners(
            in: sketch, excludingDimensions: [want120.id])
        XCTAssertEqual(partners.dimensionIDs, [want100.id])
        XCTAssertTrue(partners.constraintIDs.isEmpty, "\(partners.constraintIDs)")
    }

    /// A wrong dimension on a line whose endpoints are both locked: the
    /// partners are the two locks (removing either lets the line stretch);
    /// the satisfied horizontal is not implicated.
    func testConflictPartnersOfALockedLineAreTheLocks() {
        let line = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: line, a: SIMD2(0, 0), b: SIMD2(100, 0)),
        ])
        let horizontal = SketchConstraint(
            kind: .horizontal, refs: [ConstraintRef(entityID: line, role: .whole)])
        let lockA = SketchConstraint(
            kind: .fixed, refs: [ConstraintRef(entityID: line, role: .endpointA)])
        let lockB = SketchConstraint(
            kind: .fixed, refs: [ConstraintRef(entityID: line, role: .endpointB)])
        sketch.constraints = [horizontal, lockA, lockB]
        let wrong = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: line, role: .endpointA),
                   ConstraintRef(entityID: line, role: .endpointB)],
            value: 120)
        sketch.dimensions = [wrong]

        let partners = SketchSolverBridge.conflictPartners(
            in: sketch, excludingDimensions: [wrong.id])
        XCTAssertEqual(partners.constraintIDs, [lockA.id, lockB.id])
        XCTAssertTrue(partners.dimensionIDs.isEmpty, "\(partners.dimensionIDs)")
    }

    /// The refusal message names partners in document order, with dimension
    /// values, and keeps the generic wording when there are none.
    func testTheRefusalMessageNamesThePartners() {
        let line = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: line, a: SIMD2(0, 0), b: SIMD2(100, 0)),
        ])
        let horizontal = SketchConstraint(
            kind: .horizontal, refs: [ConstraintRef(entityID: line, role: .whole)])
        let dim = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: line, role: .endpointA),
                   ConstraintRef(entityID: line, role: .endpointB)],
            value: 100)
        sketch.constraints = [horizontal]
        sketch.dimensions = [dim]

        var partners = SketchSolverBridge.ConflictAttribution()
        partners.constraintIDs = [horizontal.id]
        partners.dimensionIDs = [dim.id]
        XCTAssertEqual(
            EditorViewModel.conflictRefusalMessage(
                adding: "Vertical", partners: partners, in: sketch),
            "Vertical conflicts with Horizontal, Distance 100.00 mm — not added.")
        XCTAssertEqual(
            EditorViewModel.conflictRefusalMessage(
                adding: "Vertical", partners: .init(), in: sketch),
            "Vertical conflicts with the existing constraints — not added.")
    }

    /// A sketch that solves has no partners to report.
    func testConflictPartnersOfASatisfiableSketchAreEmpty() {
        let line = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: line, a: SIMD2(0, 0), b: SIMD2(100, 0)),
        ])
        sketch.dimensions = [
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: line, role: .endpointA),
                                   ConstraintRef(entityID: line, role: .endpointB)],
                            value: 100),
        ]
        XCTAssertTrue(SketchSolverBridge.conflictPartners(in: sketch).isEmpty)
    }

    /// A satisfiable sketch attributes nothing — the red paint only ever
    /// appears on a genuine conflict.
    func testASatisfiableSketchAttributesNothing() {
        let l0 = UUID(), l1 = UUID(), l2 = UUID(), l3 = UUID()
        var sketch = Sketch(plane: .ground, entities: [
            .line(id: l0, a: SIMD2(0, 0), b: SIMD2(10, 0)),
            .line(id: l1, a: SIMD2(10, 0), b: SIMD2(10, 5)),
            .line(id: l2, a: SIMD2(10, 5), b: SIMD2(0, 5)),
            .line(id: l3, a: SIMD2(0, 5), b: SIMD2(0, 0)),
        ])
        sketch.constraints = [
            SketchConstraint(kind: .horizontal, refs: [ConstraintRef(entityID: l0, role: .whole)]),
            SketchConstraint(kind: .vertical, refs: [ConstraintRef(entityID: l1, role: .whole)]),
            SketchConstraint(kind: .fixed, refs: [ConstraintRef(entityID: l0, role: .endpointA)]),
        ]
        sketch.dimensions = [
            SketchDimension(kind: .distance,
                            refs: [ConstraintRef(entityID: l0, role: .endpointA),
                                   ConstraintRef(entityID: l0, role: .endpointB)],
                            value: 10),
        ]
        XCTAssertTrue(SketchSolverBridge.conflictAttribution(sketch).isEmpty)
    }
}
