//
//  StrokeClassifierTests.swift
//  openshape3dTests
//
//  Spec §1.2 — Line/Arc Automatic mode. The classifier is judged on strokes a
//  hand would actually produce: a "straight" line is never perfectly straight,
//  and an arc drawn quickly is under-sampled and noisy. These tests use jittered
//  input for exactly that reason.
//

import XCTest
import simd
@testable import openshape3d

final class StrokeClassifierTests: XCTestCase {

    /// Deterministic pseudo-jitter — a fixed wobble pattern, no RNG, so a
    /// failure always reproduces.
    private func jitter(_ i: Int, _ amplitude: Double) -> SIMD2<Double> {
        SIMD2(sin(Double(i) * 2.3) * amplitude, cos(Double(i) * 1.7) * amplitude)
    }

    private func handDrawnLine(
        from a: SIMD2<Double> = SIMD2(0, 0), to b: SIMD2<Double> = SIMD2(100, 0),
        samples: Int = 40, wobble: Double = 0.3
    ) -> [SIMD2<Double>] {
        (0...samples).map { i in
            let t = Double(i) / Double(samples)
            return a + (b - a) * t + jitter(i, wobble)
        }
    }

    /// A CCW arc of `sweep` radians on a circle of `radius` centred at origin.
    private func handDrawnArc(
        radius: Double = 50, sweep: Double = .pi / 2, start: Double = 0,
        samples: Int = 40, wobble: Double = 0.3, clockwise: Bool = false
    ) -> [SIMD2<Double>] {
        (0...samples).map { i in
            let t = Double(i) / Double(samples)
            let angle = start + (clockwise ? -sweep : sweep) * t
            return SIMD2(cos(angle), sin(angle)) * radius + jitter(i, wobble)
        }
    }

    // MARK: Automatic detection

    func testAHandDrawnStraightStrokeReadsAsALine() throws {
        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: handDrawnLine(), lineType: .automatic))
        guard case let .line(a, b) = shape else {
            return XCTFail("hand wobble must not be mistaken for curvature: \(shape)")
        }
        XCTAssertEqual(simd_length(b - a), 100, accuracy: 2,
                       "the line spans the stroke's endpoints")
    }

    func testAHandDrawnCurvedStrokeReadsAsAnArc() throws {
        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: handDrawnArc(), lineType: .automatic))
        guard case let .arc(center, radius, _, _) = shape else {
            return XCTFail("a quarter turn is clearly an arc: \(shape)")
        }
        XCTAssertEqual(radius, 50, accuracy: 2, "the fitted radius matches the stroke")
        XCTAssertEqual(simd_length(center), 0, accuracy: 2, "…and so does the centre")
    }

    func testAVeryShallowArcStillReadsAsALine() throws {
        // 3° of a huge circle: geometrically an arc, but the user meant a line.
        let shape = try XCTUnwrap(StrokeClassifier.shape(
            from: handDrawnArc(radius: 2000, sweep: .pi / 60), lineType: .automatic))
        guard case .line = shape else {
            return XCTFail("a barely-bowed stroke should stay a line: \(shape)")
        }
    }

    func testASemicircleReadsAsAnArcWithTheRightRadius() throws {
        let shape = try XCTUnwrap(StrokeClassifier.shape(
            from: handDrawnArc(radius: 30, sweep: .pi), lineType: .automatic))
        guard case let .arc(_, radius, _, _) = shape else {
            return XCTFail("expected an arc: \(shape)")
        }
        XCTAssertEqual(radius, 30, accuracy: 2)
    }

    // MARK: Sweep direction

    func testACounterclockwiseStrokeKeepsItsDrawnDirection() throws {
        let points = handDrawnArc(radius: 40, sweep: .pi / 2, start: 0, wobble: 0)
        let shape = try XCTUnwrap(StrokeClassifier.shape(from: points, lineType: .arc))
        guard case let .arc(_, _, start, end) = shape else { return XCTFail("expected arc") }
        // Entity arcs sweep CCW from start; drawn CCW, so start ≈ 0.
        XCTAssertEqual(SketchEntity.arcSweep(startAngle: start, endAngle: end),
                       .pi / 2, accuracy: 0.1)
        XCTAssertEqual(start, 0, accuracy: 0.1, "start is where the pen started")
    }

    func testAClockwiseStrokeIsStoredAsTheSameArcSweptCCW() throws {
        // Drawn from 90° down to 0°; stored CCW that is 0° → 90°.
        let points = handDrawnArc(radius: 40, sweep: .pi / 2, start: .pi / 2,
                                  wobble: 0, clockwise: true)
        let shape = try XCTUnwrap(StrokeClassifier.shape(from: points, lineType: .arc))
        guard case let .arc(_, _, start, end) = shape else { return XCTFail("expected arc") }
        XCTAssertEqual(SketchEntity.arcSweep(startAngle: start, endAngle: end),
                       .pi / 2, accuracy: 0.1,
                       "a clockwise stroke must not become a 270° arc")
        XCTAssertEqual(start, 0, accuracy: 0.1, "start/end swapped to keep the CCW rule")
    }

    // MARK: Line Type override

    func testLineOverrideForcesALineFromACurvedStroke() throws {
        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: handDrawnArc(), lineType: .line))
        guard case .line = shape else { return XCTFail("the override must win: \(shape)") }
    }

    func testArcOverrideForcesAnArcFromAStraightStroke() throws {
        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: handDrawnLine(), lineType: .arc))
        guard case .arc = shape else { return XCTFail("the override must win: \(shape)") }
    }

    func testArcOverrideOnAPerfectlyStraightStrokeFallsBackToALine() throws {
        // No circle passes through collinear samples, and the Arc override has
        // no bow to work from — a line is the honest answer rather than a
        // degenerate arc.
        let points = (0...10).map { SIMD2<Double>(Double($0) * 10, 0) }
        let shape = try XCTUnwrap(StrokeClassifier.shape(from: points, lineType: .arc))
        guard case .line = shape else { return XCTFail("expected the fallback line") }
    }

    func testWiggledStraightStrokeGetsAVisibleDefaultBow() throws {
        // Toggling a straight stroke to an arc has no fitted curvature to use,
        // so it must still produce something the user can SEE and then drag.
        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: wiggledLine(), lineType: .automatic))
        guard case let .arc(center, radius, start, end) = shape else {
            return XCTFail("expected an arc: \(shape)")
        }
        let pts = SketchEntity.arcPoints(
            center: center, radius: radius, startAngle: start, endAngle: end,
            segmentsPerTurn: 720)
        XCTAssertGreaterThan(pts.count, 1)
        // Endpoints preserved, and the middle bows clear of the chord.
        let bow = pts.map { abs($0.y) }.max() ?? 0
        XCTAssertEqual(bow, 10, accuracy: 0.5,
                       "a tenth of the 100 chord — unmistakably curved")
    }

    // MARK: Wiggle toggles the automatic answer

    /// A stroke that goes straight, scribbles back and forth, then continues.
    private func wiggledLine() -> [SIMD2<Double>] {
        var points = (0...20).map { SIMD2<Double>(Double($0) * 2, 0) }  // 0 → 40
        // Back-and-forth over a few units — short relative to the 100 span.
        for step in [-6.0, 6.0, -6.0, 6.0] {
            points.append(points[points.count - 1] + SIMD2(step, 0))
        }
        points += (21...50).map { SIMD2<Double>(Double($0) * 2, 0) }    // 42 → 100
        return points
    }

    func testWiggleIsDetected() {
        XCTAssertTrue(StrokeClassifier.isWiggled(wiggledLine()))
        XCTAssertFalse(StrokeClassifier.isWiggled(handDrawnLine()),
                       "ordinary hand wobble is not a wiggle")
        XCTAssertFalse(StrokeClassifier.isWiggled(handDrawnArc()),
                       "a smooth curve is not a wiggle")
    }

    func testWigglingAStraightStrokeTurnsItIntoAnArc() throws {
        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: wiggledLine(), lineType: .automatic))
        guard case .arc = shape else {
            return XCTFail("the wiggle should have flipped line → arc: \(shape)")
        }
    }

    func testWigglingACurvedStrokeTurnsItIntoALine() throws {
        // A clean arc with a scribble inserted at its midpoint.
        var points = handDrawnArc(radius: 50, sweep: .pi / 2, samples: 20, wobble: 0)
        let mid = points.count / 2
        let scribble = (0..<4).map { i in
            points[mid] + SIMD2(0, i % 2 == 0 ? -3 : 3)
        }
        points.insert(contentsOf: scribble, at: mid)

        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: points, lineType: .automatic))
        guard case .line = shape else {
            return XCTFail("the wiggle should have flipped arc → line: \(shape)")
        }
    }

    func testWiggleIsExcludedFromTheFittedGeometry() throws {
        let shape = try XCTUnwrap(
            StrokeClassifier.shape(from: wiggledLine(), lineType: .line))
        guard case let .line(a, b) = shape else { return XCTFail("expected a line") }
        XCTAssertEqual(a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(b.x, 100, accuracy: 1e-9,
                       "the stroke still spans its true endpoints")
    }

    // MARK: Entities + degenerate input

    func testEntityFactoryProducesTheMatchingSketchEntity() throws {
        let line = try XCTUnwrap(
            StrokeClassifier.entity(from: handDrawnLine(), lineType: .automatic))
        guard case .line = line else { return XCTFail("expected a line entity") }

        let arc = try XCTUnwrap(
            StrokeClassifier.entity(from: handDrawnArc(), lineType: .automatic))
        guard case .arc = arc else { return XCTFail("expected an arc entity") }
    }

    func testTooFewSamplesProduceNothing() {
        XCTAssertNil(StrokeClassifier.shape(from: [], lineType: .automatic))
        XCTAssertNil(StrokeClassifier.shape(from: [SIMD2(1, 1)], lineType: .automatic))
    }

    func testATapInPlaceProducesNothing() {
        // Many samples, all at the same point — a tap, not a stroke.
        let points = Array(repeating: SIMD2<Double>(4, 4), count: 30)
        XCTAssertNil(StrokeClassifier.shape(from: points, lineType: .automatic),
                     "a stationary pen must not emit a zero-length entity")
    }

    func testTwoSamplesAreAlwaysALine() throws {
        let shape = try XCTUnwrap(StrokeClassifier.shape(
            from: [SIMD2(0, 0), SIMD2(10, 5)], lineType: .automatic))
        guard case .line = shape else { return XCTFail("two points cannot bow") }
    }

    func testLineTypeMenuOffersTheThreeSpecOptions() {
        XCTAssertEqual(LineType.allCases.map(\.label),
                       ["Automatic", "Line", "Arc"])
    }
}
