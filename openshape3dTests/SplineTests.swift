//
//  SplineTests.swift
//  openshape3dTests
//
//  Spec §1.4 (Spline — Fit). The fit spline INTERPOLATES its control points, so
//  the defining property to protect is: every control point lies exactly on the
//  curve. Centripetal parameterisation is what keeps unevenly-spaced points from
//  producing cusps or self-intersections.
//

import XCTest
import simd
@testable import openshape3d

final class SplineTests: XCTestCase {

    private func distance(_ p: SIMD2<Double>, toPolyline curve: [SIMD2<Double>]) -> Double {
        guard curve.count >= 2 else { return .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        for i in 1..<curve.count {
            let a = curve[i - 1], b = curve[i]
            let ab = b - a
            let len2 = simd_length_squared(ab)
            let t = len2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / len2)) : 0
            best = min(best, simd_length(p - (a + ab * t)))
        }
        return best
    }

    // MARK: Interpolation — the defining property of a FIT spline

    func testCurvePassesThroughEveryControlPoint() {
        let pts: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(10, 8), SIMD2(22, -4), SIMD2(30, 6), SIMD2(41, 1),
        ]
        let curve = SketchEntity.splinePoints(pts, closed: false)
        XCTAssertGreaterThan(curve.count, pts.count, "curve is tessellated, not just the points")
        for p in pts {
            XCTAssertLessThan(distance(p, toPolyline: curve), 1e-9,
                              "a FIT spline must interpolate every control point")
        }
    }

    func testClosedSplineAlsoInterpolatesAndWrapsAround() {
        let pts: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10),
        ]
        let curve = SketchEntity.splinePoints(pts, closed: true)
        for p in pts {
            XCTAssertLessThan(distance(p, toPolyline: curve), 1e-9,
                              "closed fit spline interpolates its points too")
        }
        // Closed curves do not repeat the first point (same convention as
        // ellipsePoints), so the ends must be far apart, not coincident.
        XCTAssertGreaterThan(simd_length(curve.last! - curve.first!), 1e-6,
                             "first point is not duplicated at the end")
    }

    // MARK: Degenerate inputs

    func testTwoPointsDegenerateToALine() {
        let pts: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(5, 5)]
        XCTAssertEqual(SketchEntity.splinePoints(pts, closed: false), pts,
                       "a 2-point fit spline is just the straight span")
    }

    func testDuplicatePointsDoNotProduceNaNs() {
        // Repeated points make a uniform Catmull-Rom blow up; centripetal
        // parameterisation plus the degenerate-span guard must survive it.
        let pts: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(0, 0), SIMD2(5, 5), SIMD2(5, 5), SIMD2(9, 0),
        ]
        let curve = SketchEntity.splinePoints(pts, closed: false)
        XCTAssertFalse(curve.isEmpty)
        for p in curve {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "no NaN/Inf from duplicate points")
        }
    }

    // MARK: Integration with the rest of the sketch pipeline

    func testTransformsActOnTheCurveExactly() {
        let id = UUID()
        let pts: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(4, 6), SIMD2(9, 2)]
        let spline = SketchEntity.spline(id: id, points: pts, closed: false)

        let moved = SketchTransform.translate(entities: [spline], by: SIMD2(3, -2))
        guard case let .spline(movedID, movedPts, _) = moved[0] else {
            return XCTFail("translate must preserve the spline case")
        }
        XCTAssertEqual(movedID, id, "id is preserved")
        XCTAssertEqual(movedPts, pts.map { $0 + SIMD2(3, -2) })
    }

    func testLengthMatchesTheTessellatedCurve() {
        let pts: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(20, 0)]
        // Collinear points ⇒ the curve is a straight 20-unit run.
        let spline = SketchEntity.spline(id: UUID(), points: pts, closed: false)
        XCTAssertEqual(MeasureKit.length(of: spline), 20, accuracy: 1e-6,
                       "collinear fit points give a straight, exactly-measurable curve")
    }

    func testHitTestDistanceIsZeroOnTheCurveAndPositiveOff() {
        let pts: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 10), SIMD2(20, 0)]
        let spline = SketchEntity.spline(id: UUID(), points: pts, closed: false)
        XCTAssertLessThan(SketchHitTester.distance(from: SIMD2(10, 10), to: spline), 1e-6,
                          "a control point is ON the curve, so picking works")
        XCTAssertGreaterThan(SketchHitTester.distance(from: SIMD2(10, 40), to: spline), 25,
                             "a far point is far")
    }

    func testOpenSplineIsAValidSweepSpine() {
        let pts: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(5, 4), SIMD2(12, 1)]
        let open = SketchEntity.spline(id: UUID(), points: pts, closed: false)
        let closed = SketchEntity.spline(id: UUID(), points: pts, closed: true)
        XCTAssertNotNil(EditorViewModel.sweepPathPolyline(of: open),
                        "sweeping along a drawn curve is the point of splines (§4.11)")
        XCTAssertNil(EditorViewModel.sweepPathPolyline(of: closed),
                     "a closed curve cannot be a spine")
    }

    func testSplineSurvivesCodableRoundTrip() throws {
        let spline = SketchEntity.spline(
            id: UUID(), points: [SIMD2(0, 0), SIMD2(3, 7), SIMD2(8, 2)], closed: true)
        let data = try JSONEncoder().encode(spline)
        let back = try JSONDecoder().decode(SketchEntity.self, from: data)
        XCTAssertEqual(back, spline, "splines must persist in the document")
    }
}
