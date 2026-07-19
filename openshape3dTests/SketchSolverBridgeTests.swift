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
}
