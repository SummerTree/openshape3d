//
//  ProfileOffsetTests.swift
//  openshape3dTests
//
//  The mitred 2D polygon offset behind draft/taper extrude — exact coordinates
//  for the shapes a draft actually offsets (rects, n-gons), and the honest nil
//  when an inward offset collapses the loop.
//

import XCTest
import simd
@testable import openshape3d

final class ProfileOffsetTests: XCTestCase {

    private func assertLoop(_ got: [SIMD2<Double>]?, _ want: [SIMD2<Double>],
                            _ msg: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        let g = try? XCTUnwrap(got, msg, file: file, line: line)
        guard let g else { return }
        XCTAssertEqual(g.count, want.count, "count \(msg)", file: file, line: line)
        for (a, b) in zip(g, want) {
            XCTAssertLessThan(simd_distance(a, b), 1e-9,
                              "\(a) vs \(b) \(msg)", file: file, line: line)
        }
    }

    /// A 40×40 square offset INWARD by 3.527 mm (= 20·tan10°) is a 32.946 mm
    /// square — the exact top section of the validated 10° drafted box.
    func testASquareOffsetsInwardToTheExactDraftSection() {
        let sq: [SIMD2<Double>] = [
            SIMD2(-20, -20), SIMD2(20, -20), SIMD2(20, 20), SIMD2(-20, 20)]
        let d: Double = 20 * tan(10 * Double.pi / 180)   // 3.5265
        let want: Double = 20 - d
        assertLoop(ProfileOffset.offsetLoop(sq, by: -d), [
            SIMD2(-want, -want), SIMD2(want, -want),
            SIMD2(want, want), SIMD2(-want, want)], "inward")
        // Outward expands by the same amount.
        let big: Double = 20 + d
        assertLoop(ProfileOffset.offsetLoop(sq, by: d), [
            SIMD2(-big, -big), SIMD2(big, -big),
            SIMD2(big, big), SIMD2(-big, big)], "outward")
    }

    /// Winding is preserved: a clockwise loop offsets to a clockwise loop, and
    /// negative distance still means inward regardless of winding.
    func testWindingIsPreservedAndSignIsWindingIndependent() {
        let cw: [SIMD2<Double>] = [
            SIMD2(-10, -10), SIMD2(-10, 10), SIMD2(10, 10), SIMD2(10, -10)]
        XCTAssertLessThan(Profile.signedArea(cw), 0, "fixture is CW")
        let inward = ProfileOffset.offsetLoop(cw, by: -2)
        let g = try? XCTUnwrap(inward)
        guard let g else { return XCTFail("inward offset") }
        XCTAssertLessThan(Profile.signedArea(g), 0, "still CW")
        // inward of a 20×20 CW square by 2 → 16×16, same first corner shrunk
        assertLoop(inward, [
            SIMD2(-8, -8), SIMD2(-8, 8), SIMD2(8, 8), SIMD2(8, -8)], "cw inward")
    }

    /// A regular hexagon (across-flats 24) offset inward keeps six sides and
    /// shrinks its across-flats by 2·distance.
    func testAHexagonOffsetsInwardKeepingSixSides() {
        let R = 24.0 / 3.0.squareRoot()          // circumradius for AF 24
        let hex = (0..<6).map { i -> SIMD2<Double> in
            let a: Double = Double(i) / 6 * 2 * Double.pi
            return SIMD2(R * cos(a), R * sin(a))
        }
        let g = try? XCTUnwrap(ProfileOffset.offsetLoop(hex, by: -2))
        guard let g else { return XCTFail("hex offset") }
        XCTAssertEqual(g.count, 6)
        // apothem was 12; inward 2 → 10; new circumradius = 10 / cos(30°).
        let newR = 10 / cos(Double.pi / 6)
        for p in g {
            XCTAssertEqual(simd_length(p), newR, accuracy: 1e-9)
        }
    }

    /// An inward offset large enough to collapse the loop returns nil — the
    /// honest "no valid section" signal, never a self-intersected profile.
    func testAnOverLargeInwardOffsetIsRefused() {
        let sq: [SIMD2<Double>] = [
            SIMD2(-5, -5), SIMD2(5, -5), SIMD2(5, 5), SIMD2(-5, 5)]
        // Half-width is 5; offsetting inward by 5 collapses it to a point,
        // by 6 inverts it — both invalid.
        XCTAssertNil(ProfileOffset.offsetLoop(sq, by: -5), "collapse")
        XCTAssertNil(ProfileOffset.offsetLoop(sq, by: -6), "inversion")
    }

    /// A 100×60 rectangle with 2 mm corner cuts offset inward by 10: each cut
    /// is consumed (its mitres cross after 2.4 mm) and collapses onto the
    /// sharp corner where its neighbours meet — the vertex count survives
    /// (the draft lofts edge-for-edge), the two corner vertices sit ε apart,
    /// and the section is the 80×40 inner rectangle.
    func testAConsumedCornerCutCollapsesOntoItsNeighboursCorner() throws {
        let c = 2.0
        let loop: [SIMD2<Double>] = [
            SIMD2(-50 + c, -30), SIMD2(50 - c, -30), SIMD2(50, -30 + c), SIMD2(50, 30 - c),
            SIMD2(50 - c, 30), SIMD2(-50 + c, 30), SIMD2(-50, 30 - c), SIMD2(-50, -30 + c)]
        let g = try XCTUnwrap(ProfileOffset.offsetLoop(loop, by: -10), "consumed corners must not refuse")
        XCTAssertEqual(g.count, 8, "vertex count is kept for the loft")
        let corners: [SIMD2<Double>] = [SIMD2(40, -20), SIMD2(40, 20), SIMD2(-40, 20), SIMD2(-40, -20)]
        for (k, corner) in corners.enumerated() {
            let a = g[(1 + 2 * k) % 8], b = g[(2 + 2 * k) % 8]
            XCTAssertLessThan(simd_distance(a, corner), 2e-3, "corner \(k) vertex a \(a)")
            XCTAssertLessThan(simd_distance(b, corner), 2e-3, "corner \(k) vertex b \(b)")
            XCTAssertGreaterThan(simd_distance(a, b), 1e-4, "the two must stay distinct points")
        }
        // the ε-spread corner pairs add slivers of order ε·(half-side): ~0.09 mm²
        XCTAssertEqual(Profile.signedArea(g), 80 * 40, accuracy: 0.2)
    }

    /// A rectangle whose one corner is a tessellated round (four 0.8 mm
    /// segments): a 10 mm inward offset consumes the whole run, which collapses
    /// together onto the corner; the other three corners mitre as usual.
    func testARunOfTinySegmentsCollapsesTogether() throws {
        // The (+x, +y) corner is a 2 mm round tessellated in four 0.78 mm chords:
        // (30, 18) → three points on the arc about (28, 18) → (28, 20).
        let r = 2.0, centre = SIMD2(28.0, 18.0)
        var loop: [SIMD2<Double>] = [SIMD2(-30, -20), SIMD2(30, -20), SIMD2(30, 18)]
        for i in 1...3 {
            let a = Double(i) / 4 * (Double.pi / 2)
            loop.append(centre + SIMD2(cos(a), sin(a)) * r)
        }
        loop += [SIMD2(28, 20), SIMD2(-30, 20)]
        XCTAssertEqual(loop.count, 8)
        let g = try XCTUnwrap(ProfileOffset.offsetLoop(loop, by: -10))
        XCTAssertEqual(g.count, 8)
        for p in g[2...6] {
            XCTAssertLessThan(simd_distance(p, SIMD2(20, 10)), 5e-3, "run vertex \(p) collapses onto (20, 10)")
        }
        XCTAssertLessThan(simd_distance(g[0], SIMD2(-20, -10)), 1e-9)
        XCTAssertLessThan(simd_distance(g[7], SIMD2(-20, 10)), 1e-9)
        XCTAssertEqual(Profile.signedArea(g), 40 * 20, accuracy: 0.05)
    }

    func testDegenerateInputsAreRejected() {
        XCTAssertNil(ProfileOffset.offsetLoop([SIMD2(0, 0), SIMD2(1, 0)], by: 1),
                     "fewer than three points")
        // A zero offset returns the loop untouched.
        let sq: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        assertLoop(ProfileOffset.offsetLoop(sq, by: 0), sq, "zero offset")
    }
}
