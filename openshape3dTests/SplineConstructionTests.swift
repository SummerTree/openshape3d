//
//  SplineConstructionTests.swift
//  openshape3dTests
//
//  Sketch ▸ Spline (spec §1.4): the entity each placement commits, the
//  clamped / periodic B-spline behind Control Point mode, and that the fit
//  points a control spline is stored as reproduce that B-spline.
//

import XCTest
import simd
@testable import openshape3d

final class SplineConstructionTests: XCTestCase {

    private let zigzag: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 10), SIMD2(20, 0), SIMD2(30, 10), SIMD2(40, 0)]

    func testFitKeepsTheTappedPoints() throws {
        let entity = try XCTUnwrap(SplineConstruction.entity(id: UUID(), type: .fit, points: zigzag, closed: false))
        guard case let .spline(_, points, closed) = entity else { return XCTFail("expected a spline") }
        XCTAssertEqual(points, zigzag)
        XCTAssertFalse(closed)
    }

    func testTwoPointsAreALineAndOneIsNothing() {
        let line = SplineConstruction.entity(id: UUID(), type: .control, points: Array(zigzag.prefix(2)), closed: false)
        if case .line = line {} else { XCTFail("two points should commit a straight line") }
        XCTAssertNil(SplineConstruction.entity(id: UUID(), type: .fit, points: [.zero], closed: false))
    }

    func testOpenControlSplineIsClampedToItsEnds() {
        let curve = SplineConstruction.bSpline(control: zigzag, closed: false)
        XCTAssertEqual(simd_length(curve.first! - zigzag.first!), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_length(curve.last! - zigzag.last!), 0, accuracy: 1e-9)
        // A B-spline is pulled toward its interior control points, not through them.
        let peak = curve.map(\.y).max()!
        XCTAssertLessThan(peak, 10 - 1e-3)
        XCTAssertGreaterThan(peak, 2)
        // Convex hull: every point stays inside the control polygon's box.
        for p in curve {
            XCTAssertTrue(p.x >= -1e-9 && p.x <= 40 + 1e-9 && p.y >= -1e-9 && p.y <= 10 + 1e-9)
        }
    }

    func testClosedControlSplineIsSmoothAndInsideItsPolygon() {
        let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let curve = SplineConstruction.bSpline(control: square, closed: true, perSpan: 32)
        XCTAssertEqual(curve.count, 4 * 32)
        let centre = SIMD2<Double>(5, 5)
        for p in curve {
            XCTAssertLessThan(simd_length(p - centre), simd_length(square[0] - centre))
        }
        // Symmetric control polygon → the curve is symmetric about the centre.
        let mean = curve.reduce(SIMD2<Double>.zero, +) / Double(curve.count)
        XCTAssertEqual(simd_length(mean - centre), 0, accuracy: 1e-9)
    }

    func testControlSplineIsStoredAsFitPointsOnItsCurve() throws {
        let entity = try XCTUnwrap(SplineConstruction.entity(id: UUID(), type: .control, points: zigzag, closed: false))
        guard case let .spline(_, fit, _) = entity else { return XCTFail("expected a spline") }
        XCTAssertGreaterThan(fit.count, zigzag.count)
        // The interpolated fit spline stays within a small tolerance of the
        // exact B-spline everywhere.
        let exact = SplineConstruction.bSpline(control: zigzag, closed: false, perSpan: 64)
        let stored = SketchEntity.splinePoints(fit, closed: false, segmentsPerSpan: 16)
        func distance(_ p: SIMD2<Double>, toPolyline line: [SIMD2<Double>]) -> Double {
            zip(line, line.dropFirst()).map { a, b in
                let d = b - a
                let t = min(max(simd_dot(p - a, d) / max(simd_length_squared(d), 1e-18), 0), 1)
                return simd_length(p - (a + d * t))
            }.min() ?? .infinity
        }
        // 40 mm wide, 10 mm tall: within 0.1 mm everywhere.
        for p in exact {
            XCTAssertLessThan(distance(p, toPolyline: stored), 0.1, "stored curve drifts from the B-spline at \(p)")
        }
    }
}
