//
//  ConstraintIntegrationTests.swift
//  openshape3dTests
//
//  Phase C end-to-end integration gate. Exercises the WHOLE stack through the
//  shared contract in one flow: a real `Sketch` of four lines with explicit
//  `.coincident` corner constraints is lowered by `SketchSolverBridge` onto the
//  `ConstraintResidual` set (Constraints.swift) and driven by the pure-Swift
//  Levenberg–Marquardt `ConstraintSolver` (Solver.swift). We assert the solve
//  produces a correctly-sized, axis-aligned rectangle at DOF 0 with every
//  entity fully defined (green), and that stripping the anchor + dimensions
//  leaves the same sketch under-defined (DOF > 0, at least one blue entity).
//

import XCTest
import simd
@testable import openshape3d

final class ConstraintIntegrationTests: XCTestCase {

    private let width = 10.0
    private let height = 6.0

    /// Endpoints of the line entity with `id` in a solved entity list.
    private func line(
        _ entities: [SketchEntity], _ id: UUID,
        file: StaticString = #filePath, line: UInt = #line
    ) -> (a: SIMD2<Double>, b: SIMD2<Double>) {
        for e in entities {
            if case let .line(eid, a, b) = e, eid == id { return (a, b) }
        }
        XCTFail("line \(id) missing from solved entities", file: file, line: line)
        return (.zero, .zero)
    }

    private func assertClose(
        _ p: SIMD2<Double>, _ q: SIMD2<Double>, _ tol: Double = 1e-4, _ msg: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(p.x, q.x, accuracy: tol, msg, file: file, line: line)
        XCTAssertEqual(p.y, q.y, accuracy: tol, msg, file: file, line: line)
    }

    /// Four lines forming a rough rectangle. Corners are deliberately perturbed
    /// (adjacent endpoints ~0.2–0.3 apart) so the solver must actually move the
    /// geometry — and so the explicit `.coincident` corner constraints (not just
    /// proximity welding) are what fuse each pair of endpoints into one point.
    /// The bottom-left corner starts exactly at the origin so the `.fixed`
    /// anchor pins the whole rectangle there deterministically.
    private func roughRectangle() -> (l0: UUID, l1: UUID, l2: UUID, l3: UUID, entities: [SketchEntity]) {
        let l0 = UUID(), l1 = UUID(), l2 = UUID(), l3 = UUID()
        let entities: [SketchEntity] = [
            // bottom: BL(0,0) → BR(~10,0)
            .line(id: l0, a: SIMD2(0, 0), b: SIMD2(10.3, 0.2)),
            // right: BR(~10,0) → TR(~10,6)
            .line(id: l1, a: SIMD2(10.1, -0.2), b: SIMD2(9.8, 6.3)),
            // top: TR(~10,6) → TL(~0,6)
            .line(id: l2, a: SIMD2(10.2, 5.9), b: SIMD2(0.2, 5.8)),
            // left: TL(~0,6) → BL(0,0)
            .line(id: l3, a: SIMD2(-0.2, 6.2), b: SIMD2(0, 0)),
        ]
        return (l0, l1, l2, l3, entities)
    }

    /// Explicit coincident constraints fusing the four corners.
    private func cornerCoincidences(_ l0: UUID, _ l1: UUID, _ l2: UUID, _ l3: UUID) -> [SketchConstraint] {
        [
            .init(kind: .coincident, refs: [ConstraintRef(entityID: l0, role: .endpointB),   // BR
                                            ConstraintRef(entityID: l1, role: .endpointA)]),
            .init(kind: .coincident, refs: [ConstraintRef(entityID: l1, role: .endpointB),   // TR
                                            ConstraintRef(entityID: l2, role: .endpointA)]),
            .init(kind: .coincident, refs: [ConstraintRef(entityID: l2, role: .endpointB),   // TL
                                            ConstraintRef(entityID: l3, role: .endpointA)]),
            .init(kind: .coincident, refs: [ConstraintRef(entityID: l3, role: .endpointB),   // BL
                                            ConstraintRef(entityID: l0, role: .endpointA)]),
        ]
    }

    // MARK: - Fully-defined rectangle (green, DOF 0)

    func testFullyConstrainedRectangleSolvesToExactAxisAlignedRectangle() {
        let (l0, l1, l2, l3, entities) = roughRectangle()
        var sketch = Sketch(plane: .ground, entities: entities)

        sketch.constraints =
            cornerCoincidences(l0, l1, l2, l3) + [
                // bottom & top horizontal, left & right vertical.
                .init(kind: .horizontal, refs: [ConstraintRef(entityID: l0, role: .whole)]),
                .init(kind: .horizontal, refs: [ConstraintRef(entityID: l2, role: .whole)]),
                .init(kind: .vertical,   refs: [ConstraintRef(entityID: l1, role: .whole)]),
                .init(kind: .vertical,   refs: [ConstraintRef(entityID: l3, role: .whole)]),
                // Anchor the bottom-left corner (origin) — removes translation.
                .init(kind: .fixed, refs: [ConstraintRef(entityID: l0, role: .endpointA)]),
            ]
        sketch.dimensions = [
            // width along the bottom edge...
            .init(kind: .distance,
                  refs: [ConstraintRef(entityID: l0, role: .endpointA),
                         ConstraintRef(entityID: l0, role: .endpointB)],
                  value: width),
            // ...height along the right edge.
            .init(kind: .distance,
                  refs: [ConstraintRef(entityID: l1, role: .endpointA),
                         ConstraintRef(entityID: l1, role: .endpointB)],
                  value: height),
        ]

        let (out, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)

        // The whole stack drove the geometry to a fully-determined solution.
        XCTAssertEqual(dof, 0, "anchor + H/V + width + height fully constrains the rectangle")
        XCTAssertEqual(out.count, 4)

        // Solved corners: BL(0,0) BR(W,0) TR(W,H) TL(0,H), exactly.
        let bl = SIMD2(0.0, 0.0)
        let br = SIMD2(width, 0.0)
        let tr = SIMD2(width, height)
        let tl = SIMD2(0.0, height)

        let (a0, b0) = line(out, l0)  // bottom BL→BR
        let (a1, b1) = line(out, l1)  // right  BR→TR
        let (a2, b2) = line(out, l2)  // top    TR→TL
        let (a3, b3) = line(out, l3)  // left   TL→BL

        assertClose(a0, bl, 1e-4, "bottom start = BL")
        assertClose(b0, br, 1e-4, "bottom end = BR")
        assertClose(a1, br, 1e-4, "right start = BR")
        assertClose(b1, tr, 1e-4, "right end = TR")
        assertClose(a2, tr, 1e-4, "top start = TR")
        assertClose(b2, tl, 1e-4, "top end = TL")
        assertClose(a3, tl, 1e-4, "left start = TL")
        assertClose(b3, bl, 1e-4, "left end = BL")

        // Corners are welded: adjacent endpoints are the SAME solved point.
        assertClose(b0, a1, 1e-6, "BR corner welded")
        assertClose(b1, a2, 1e-6, "TR corner welded")
        assertClose(b2, a3, 1e-6, "TL corner welded")
        assertClose(b3, a0, 1e-6, "BL corner welded")

        // Axis-aligned + correctly sized (independent of the exact corners).
        XCTAssertEqual(a0.y, b0.y, accuracy: 1e-4, "bottom edge horizontal")
        XCTAssertEqual(a2.y, b2.y, accuracy: 1e-4, "top edge horizontal")
        XCTAssertEqual(a1.x, b1.x, accuracy: 1e-4, "right edge vertical")
        XCTAssertEqual(a3.x, b3.x, accuracy: 1e-4, "left edge vertical")
        XCTAssertEqual(simd_distance(a0, b0), width, accuracy: 1e-4, "bottom length = width")
        XCTAssertEqual(simd_distance(a1, b1), height, accuracy: 1e-4, "right length = height")

        // Every entity is fully defined (green).
        let states = SketchSolverBridge.entityStates(sketch)
        for id in [l0, l1, l2, l3] {
            XCTAssertEqual(states[id], true, "entity \(id) should be fully defined (green)")
        }
        XCTAssertFalse(states.values.contains(false), "no entity should be under-defined")
    }

    // MARK: - Under-defined rectangle (blue, DOF > 0)

    func testUnderConstrainedRectangleReportsRemainingDOF() {
        let (l0, l1, l2, l3, entities) = roughRectangle()
        var sketch = Sketch(plane: .ground, entities: entities)
        // Same welded corners + H/V, but NO anchor and NO dimensions: the shape
        // is still free to translate and to scale in width & height.
        sketch.constraints =
            cornerCoincidences(l0, l1, l2, l3) + [
                .init(kind: .horizontal, refs: [ConstraintRef(entityID: l0, role: .whole)]),
                .init(kind: .horizontal, refs: [ConstraintRef(entityID: l2, role: .whole)]),
                .init(kind: .vertical,   refs: [ConstraintRef(entityID: l1, role: .whole)]),
                .init(kind: .vertical,   refs: [ConstraintRef(entityID: l3, role: .whole)]),
            ]

        let (out, dof) = SketchSolverBridge.solve(sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertEqual(out.count, 4)
        XCTAssertGreaterThan(dof, 0, "no anchor / no dimensions ⇒ remaining degrees of freedom")

        // Corners must still be welded even while the whole shape is loose.
        let (_, b0) = line(out, l0)
        let (a1, _) = line(out, l1)
        assertClose(b0, a1, 1e-4, "BR corner stays welded under-constrained")

        // At least one entity is under-defined (blue).
        let states = SketchSolverBridge.entityStates(sketch)
        XCTAssertTrue(states.values.contains(false), "an under-defined sketch has blue entities")
    }
}
