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

    func testDegenerateInputsAreRejected() {
        XCTAssertNil(ProfileOffset.offsetLoop([SIMD2(0, 0), SIMD2(1, 0)], by: 1),
                     "fewer than three points")
        // A zero offset returns the loop untouched.
        let sq: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        assertLoop(ProfileOffset.offsetLoop(sq, by: 0), sq, "zero offset")
    }
}
