//
//  ConstraintResidualTests.swift
//  openshape3dTests
//
//  Phase C — geometric constraint residuals. For each constraint type we
//  assert residuals are ~0 at a satisfying configuration, non-zero at a
//  violating one, and that `residualCount` / `variableIndices` are correct.
//  Point-index `i` occupies flat variables (2*i, 2*i+1).
//

import XCTest
import simd
@testable import openshape3d

final class ConstraintResidualTests: XCTestCase {

    private let zero = 1e-9

    /// Assert every residual is ~0.
    private func assertSatisfied(
        _ c: any ConstraintResidual, _ vars: [Double],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = c.residuals(vars)
        XCTAssertEqual(r.count, c.residualCount, "residualCount mismatch", file: file, line: line)
        for (i, v) in r.enumerated() {
            XCTAssertEqual(v, 0, accuracy: zero, "residual[\(i)] not zero", file: file, line: line)
        }
    }

    /// Assert at least one residual has meaningful magnitude.
    private func assertViolated(
        _ c: any ConstraintResidual, _ vars: [Double],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = c.residuals(vars)
        XCTAssertEqual(r.count, c.residualCount, "residualCount mismatch", file: file, line: line)
        XCTAssertTrue(r.contains { abs($0) > 1e-4 }, "expected a non-zero residual, got \(r)",
                      file: file, line: line)
    }

    // MARK: - Coincident / Concentric

    func testCoincident() {
        let c = CoincidentConstraint(pA: 0, pB: 1)
        XCTAssertEqual(c.residualCount, 2)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3])
        assertSatisfied(c, [1, 2, 1, 2])
        assertViolated(c, [1, 2, 3, 4])
    }

    func testConcentric() {
        let c = ConcentricConstraint(cA: 1, cB: 2)
        XCTAssertEqual(c.residualCount, 2)
        XCTAssertEqual(c.variableIndices, [2, 3, 4, 5])
        // pt1 = (5,6), pt2 = (5,6) coincident
        assertSatisfied(c, [0, 0, 5, 6, 5, 6])
        assertViolated(c, [0, 0, 5, 6, 5, 7])
    }

    // MARK: - Colinear / Midpoint

    func testColinearPoint() {
        // line through (0,0)-(2,2); point (1,1) is on it.
        let c = ColinearPointConstraint(p: 0, lA: 1, lB: 2)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5])
        assertSatisfied(c, [1, 1, 0, 0, 2, 2])
        assertViolated(c, [1, 0, 0, 0, 2, 2])
    }

    func testMidpoint() {
        // p=(1,1) is midpoint of (0,0)-(2,2).
        let c = MidpointConstraint(p: 0, lA: 1, lB: 2)
        XCTAssertEqual(c.residualCount, 2)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5])
        assertSatisfied(c, [1, 1, 0, 0, 2, 2])
        assertViolated(c, [0, 0, 0, 0, 2, 2])
    }

    // MARK: - Horizontal / Vertical

    func testHorizontal() {
        let c = HorizontalConstraint(pA: 0, pB: 1)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3])
        assertSatisfied(c, [0, 5, 3, 5])
        assertViolated(c, [0, 5, 3, 7])
    }

    func testVertical() {
        let c = VerticalConstraint(pA: 0, pB: 1)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3])
        assertSatisfied(c, [5, 0, 5, 3])
        assertViolated(c, [5, 0, 7, 3])
    }

    // MARK: - Fixed

    func testFixedPoint() {
        let c = FixedPointConstraint(p: 0, target: SIMD2(2, 3))
        XCTAssertEqual(c.residualCount, 2)
        XCTAssertEqual(c.variableIndices, [0, 1])
        assertSatisfied(c, [2, 3])
        assertViolated(c, [2, 4])
    }

    // MARK: - Distances

    func testDistance() {
        // (0,0)-(3,4) has length 5.
        let c = DistanceConstraint(pA: 0, pB: 1, distance: 5)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3])
        assertSatisfied(c, [0, 0, 3, 4])
        assertViolated(c, [0, 0, 3, 3])
    }

    func testPointDistanceToLine() {
        // Line = x-axis (0,0)-(1,0); point at height 3 → distance 3.
        let c = PointDistanceToLineConstraint(p: 0, lA: 1, lB: 2, distance: 3)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5])
        assertSatisfied(c, [5, 3, 0, 0, 1, 0])
        // Unsigned: point below the line at the same distance also satisfies.
        assertSatisfied(c, [5, -3, 0, 0, 1, 0])
        assertViolated(c, [5, 2, 0, 0, 1, 0])
    }

    // MARK: - Line-pair relations

    func testParallel() {
        // seg1 (0,0)-(1,0), seg2 (0,1)-(2,1): both horizontal.
        let c = ParallelConstraint(l1A: 0, l1B: 1, l2A: 2, l2B: 3)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5, 6, 7])
        assertSatisfied(c, [0, 0, 1, 0, 0, 1, 2, 1])
        // seg2 sloped → not parallel.
        assertViolated(c, [0, 0, 1, 0, 0, 1, 1, 2])
    }

    func testPerpendicular() {
        // seg1 along +x, seg2 along +y → perpendicular.
        let c = PerpendicularConstraint(l1A: 0, l1B: 1, l2A: 2, l2B: 3)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5, 6, 7])
        assertSatisfied(c, [0, 0, 1, 0, 0, 0, 0, 1])
        // seg2 at 45° → not perpendicular.
        assertViolated(c, [0, 0, 1, 0, 0, 0, 1, 1])
    }

    func testEqualLength() {
        // seg1 (0,0)-(3,4) len 5, seg2 (0,0)-(5,0) len 5.
        let c = EqualLengthConstraint(l1A: 0, l1B: 1, l2A: 2, l2B: 3)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5, 6, 7])
        assertSatisfied(c, [0, 0, 3, 4, 0, 0, 5, 0])
        assertViolated(c, [0, 0, 3, 4, 0, 0, 4, 0])
    }

    func testAngle() {
        // seg1 along +x, seg2 along +y → directed angle π/2.
        let c = AngleConstraint(l1A: 0, l1B: 1, l2A: 2, l2B: 3, angle: .pi / 2)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5, 6, 7])
        assertSatisfied(c, [0, 0, 1, 0, 0, 0, 0, 1])
        // Same geometry, wrong target angle.
        let c45 = AngleConstraint(l1A: 0, l1B: 1, l2A: 2, l2B: 3, angle: .pi / 4)
        assertViolated(c45, [0, 0, 1, 0, 0, 0, 0, 1])
        // 45° geometry with a π/4 target satisfies.
        assertSatisfied(c45, [0, 0, 1, 0, 0, 0, 1, 1])
    }

    // MARK: - Symmetry

    func testSymmetric() {
        // Axis = y-axis through (0,0)-(0,1); (-2,3) and (2,3) mirror across it.
        let c = SymmetricConstraint(pA: 0, pB: 1, lA: 2, lB: 3)
        XCTAssertEqual(c.residualCount, 2)
        XCTAssertEqual(c.variableIndices, [0, 1, 2, 3, 4, 5, 6, 7])
        assertSatisfied(c, [-2, 3, 2, 3, 0, 0, 0, 1])
        // pB off the mirror position.
        assertViolated(c, [-2, 3, 3, 3, 0, 0, 0, 1])
        // Mirror across a diagonal axis y=x: (1,0) ↔ (0,1).
        let d = SymmetricConstraint(pA: 0, pB: 1, lA: 2, lB: 3)
        assertSatisfied(d, [1, 0, 0, 1, 0, 0, 1, 1])
    }

    // MARK: - Radius

    func testRadius() {
        let c = RadiusConstraint(radiusVar: 0, radius: 5)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0])
        assertSatisfied(c, [5])
        assertViolated(c, [4])
    }

    func testEqualRadius() {
        let c = EqualRadiusConstraint(rVar1: 0, rVar2: 1)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [0, 1])
        assertSatisfied(c, [5, 5])
        assertViolated(c, [5, 4])
    }

    // MARK: - Tangency

    func testTangentLineCircle() {
        // center = point 0 (3,2); line = x-axis (points 1,2); radiusVar = 6.
        // distance from center to x-axis is 2 → tangent when r = 2.
        let c = TangentLineCircleConstraint(lA: 1, lB: 2, center: 0, radiusVar: 6)
        XCTAssertEqual(c.residualCount, 1)
        XCTAssertEqual(c.variableIndices, [2, 3, 4, 5, 0, 1, 6])
        assertSatisfied(c, [3, 2, 0, 0, 1, 0, 2])
        // Line crossing the circle (r too big) → not tangent.
        assertViolated(c, [3, 2, 0, 0, 1, 0, 3])
    }

    // MARK: - Residual normalization (scale honesty, playbook S1 fast-follow)

    /// The same 30° misalignment reads the same whether the lines are 1mm or
    /// 1000mm long — sin(30°) = 0.5 either way. Raw cross2 was mm² and made
    /// the conflict gate over-sensitive on long lines, blind on short ones.
    func testParallelResidualIsScaleFree() {
        let c = ParallelConstraint(l1A: 0, l1B: 1, l2A: 2, l2B: 3)
        let angle = Double.pi / 6
        for length in [1.0, 1000.0] {
            let vars = [0, 0, length, 0,
                        0, 0, length * cos(angle), length * sin(angle)]
            let r = c.residuals(vars)
            XCTAssertEqual(abs(r[0]), 0.5, accuracy: 1e-9,
                           "length \(length) distorted the residual: \(r)")
        }
    }

    /// Perpendicular reads cos(angle): 0 when square, ±cos elsewhere,
    /// independent of segment lengths.
    func testPerpendicularResidualIsScaleFree() {
        let c = PerpendicularConstraint(l1A: 0, l1B: 1, l2A: 2, l2B: 3)
        for length in [1.0, 1000.0] {
            assertSatisfied(c, [0, 0, length, 0, 0, 0, 0, length])
            let r = c.residuals([0, 0, length, 0, 0, 0, length, 0])
            XCTAssertEqual(abs(r[0]), 1.0, accuracy: 1e-9, "\(r)")
        }
    }

    /// Colinear reads the point's perpendicular distance in mm — 3mm off the
    /// line is 3.0 whether the line is 10mm or 200mm long.
    func testColinearResidualIsThePerpendicularDistance() {
        let c = ColinearPointConstraint(p: 0, lA: 1, lB: 2)
        for length in [10.0, 200.0] {
            let r = c.residuals([length / 2, 3, 0, 0, length, 0])
            XCTAssertEqual(abs(r[0]), 3.0, accuracy: 1e-9,
                           "length \(length) distorted the residual: \(r)")
        }
    }

    /// Symmetric reads mm on both rows (midpoint's perpendicular distance to
    /// the axis; A→B's along-axis projection), independent of axis length.
    func testSymmetricResidualsReadInMillimetres() {
        let c = SymmetricConstraint(pA: 0, pB: 1, lA: 2, lB: 3)
        for length in [10.0, 500.0] {
            // Vertical axis x=0. A=(−4,1), B=(4,1): symmetric except the
            // midpoint sits ON the axis and A→B ⟂ axis — satisfied.
            assertSatisfied(c, [-4, 1, 4, 1, 0, 0, 0, length])
            // Shift both points +2 in x: midpoint 2mm off the axis.
            let r = c.residuals([-2, 1, 6, 1, 0, 0, 0, length])
            XCTAssertEqual(abs(r[0]), 2.0, accuracy: 1e-9,
                           "axis length \(length) distorted row 0: \(r)")
            XCTAssertEqual(r[1], 0, accuracy: 1e-9, "\(r)")
        }
    }
}
