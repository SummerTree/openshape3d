//
//  CatmullRomBezierTests.swift
//  openshape3dTests
//
//  Spline-as-profile slice 0 (docs/SPLINE_PROFILE_DESIGN.md): the Bézier
//  spans are the SAME curve `splinePoints` draws, to floating point, and the
//  Gauss–Legendre area is exact.
//

import XCTest
import simd
@testable import openshape3d

final class CatmullRomBezierTests: XCTestCase {

    /// Unevenly spaced, so the centripetal knots are all different.
    private let points: [SIMD2<Double>] = [
        SIMD2(0, 0), SIMD2(30, 4), SIMD2(38, 22), SIMD2(20, 41), SIMD2(-6, 30), SIMD2(-12, 9)]

    private func sampled(_ spans: [CatmullRomBezier.Span], steps: Int = 16) -> [SIMD2<Double>] {
        spans.flatMap { s in (0..<steps).map { CatmullRomBezier.point(s, Double($0) / Double(steps)) } }
    }

    private func assertSamePolyline(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>],
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "same number of samples", file: file, line: line)
        for (p, q) in zip(a, b) {
            XCTAssertEqual(simd_length(p - q), 0, accuracy: 1e-9, "\(p) vs \(q)", file: file, line: line)
        }
    }

    /// Closed: every span is a proper Catmull–Rom span, and the sampled Béziers
    /// reproduce `splinePoints` point for point.
    func testClosedSpansReproduceSplinePointsExactly() {
        let spans = CatmullRomBezier.spans(points, closed: true)
        XCTAssertEqual(spans.count, points.count)
        XCTAssertFalse(spans.contains { $0.isStraight })
        assertSamePolyline(sampled(spans), SketchEntity.splinePoints(points, closed: true))
        // Consecutive spans meet at the control points.
        for i in spans.indices {
            XCTAssertEqual(simd_length(spans[i].p3 - spans[(i + 1) % spans.count].p0), 0, accuracy: 1e-12)
            XCTAssertEqual(simd_length(spans[i].p0 - points[i]), 0, accuracy: 1e-12)
        }
    }

    /// Open: `splinePoints` clamps the end neighbours, which makes the first
    /// and last spans degenerate and therefore STRAIGHT; the interior spans
    /// match exactly.
    func testOpenSpansMatchInteriorAndAreStraightAtTheEnds() {
        let spans = CatmullRomBezier.spans(points, closed: false)
        XCTAssertEqual(spans.count, points.count - 1)
        XCTAssertTrue(spans.first!.isStraight); XCTAssertTrue(spans.last!.isStraight)
        // splinePoints(open) = [p0] + interior samples + [p(n-2), p(n-1)]
        let reference = SketchEntity.splinePoints(points, closed: false)
        let interior = Array(spans[1..<(spans.count - 1)])
        assertSamePolyline(sampled(interior), Array(reference[1..<(reference.count - 2)]))
        XCTAssertEqual(reference.first!, points.first!)
        XCTAssertEqual(reference.last!, points.last!)
    }

    /// Uniform spacing reduces the tangents to the textbook (p₂ − p₀)/2.
    func testUniformKnotsGiveTheClassicTangent() {
        let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let spans = CatmullRomBezier.spans(square, closed: true)
        // Span 0 runs p0→p1 with neighbours p3 and p2: tangent at p0 = (p1 − p3)/2 = (5, −5),
        // so the first handle is p0 + (5,−5)/3.
        let expected = SIMD2(10.0, 0) - SIMD2(0, 10.0)
        XCTAssertEqual(simd_length(spans[0].p1 - (square[0] + expected / 2 / 3)), 0, accuracy: 1e-9)
    }

    /// Gauss–Legendre on a degree-5 integrand is exact: it agrees with a very
    /// dense polygon to the polygon's own convergence, and flips sign with
    /// orientation.
    func testSignedAreaIsExactAndOriented() {
        let spans = CatmullRomBezier.spans(points, closed: true)
        let exact = CatmullRomBezier.signedArea(spans)
        let dense = Profile.signedArea(sampled(spans, steps: 4000))
        XCTAssertEqual(exact, dense, accuracy: abs(dense) * 1e-7)
        XCTAssertGreaterThan(exact, 0, "CCW point order")
        let reversedSpans = CatmullRomBezier.spans(points.reversed(), closed: true)
        XCTAssertEqual(CatmullRomBezier.signedArea(reversedSpans), -exact, accuracy: abs(exact) * 1e-9)
    }

    func testFewPointsAreStraight() {
        XCTAssertTrue(CatmullRomBezier.spans([SIMD2(0, 0)], closed: false).isEmpty)
        let two = CatmullRomBezier.spans([SIMD2(0, 0), SIMD2(5, 5)], closed: false)
        XCTAssertEqual(two.count, 1); XCTAssertTrue(two[0].isStraight)
        XCTAssertEqual(CatmullRomBezier.point(two[0], 0.5), SIMD2(2.5, 2.5))
    }
}
