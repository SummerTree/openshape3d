//
//  SegmentOffsetTests.swift
//  openshape3dTests
//
//  The exact line/arc offset behind the drafted rounded profile
//  (docs/DRAFT_TAPER_DESIGN.md slice 3): arcs stay concentric, lines shift,
//  tangent joints stay sealed, and anything not exactly offsettable is a nil.
//

import XCTest
import simd
@testable import openshape3d

final class SegmentOffsetTests: XCTestCase {

    private typealias Seg = Profile.Segment

    /// A slot: centres (−15,0) and (15,0), radius 10, traversed CCW.
    /// top line → left semicircle (through (−25,0)) → bottom line → right
    /// semicircle (through (25,0)).
    private func slot(r: Double = 10, half: Double = 15) -> [Seg] {
        [Seg(start: SIMD2(half, r), end: SIMD2(-half, r)),
         Seg(start: SIMD2(-half, r), end: SIMD2(-half, -r), mid: SIMD2(-half - r, 0)),
         Seg(start: SIMD2(-half, -r), end: SIMD2(half, -r)),
         Seg(start: SIMD2(half, -r), end: SIMD2(half, r), mid: SIMD2(half + r, 0))]
    }

    private func assertClosed(_ segs: [Seg], file: StaticString = #filePath, line: UInt = #line) {
        for i in segs.indices {
            let next = segs[(i + 1) % segs.count]
            XCTAssertEqual(simd_length(segs[i].end - next.start), 0, accuracy: 1e-9,
                           "segment \(i) must meet segment \((i + 1) % segs.count)", file: file, line: line)
        }
    }

    func testCircleThroughThreePoints() throws {
        let (c, r) = try XCTUnwrap(SegmentOffset.circle(through: SIMD2(15, 10), SIMD2(25, 0), SIMD2(15, -10)))
        XCTAssertEqual(c.x, 15, accuracy: 1e-9); XCTAssertEqual(c.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r, 10, accuracy: 1e-9)
        XCTAssertNil(SegmentOffset.circle(through: SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2)), "collinear")
    }

    func testInwardOffsetKeepsArcsConcentricAndJointsSealed() throws {
        let off = try XCTUnwrap(SegmentOffset.offset(slot(), by: -3))
        XCTAssertEqual(off.count, 4)
        assertClosed(off)
        // Lines moved inward to y = ±7.
        XCTAssertEqual(off[0].start.y, 7, accuracy: 1e-9); XCTAssertEqual(off[2].start.y, -7, accuracy: 1e-9)
        // Arcs concentric, radius 7.
        for i in [1, 3] {
            let (c, r) = try XCTUnwrap(SegmentOffset.circle(through: off[i].start, off[i].mid!, off[i].end))
            XCTAssertEqual(abs(c.x), 15, accuracy: 1e-9); XCTAssertEqual(c.y, 0, accuracy: 1e-9)
            XCTAssertEqual(r, 7, accuracy: 1e-9)
        }
        // Steiner: the offset area is A + P·d + π·d² for a fully rounded convex shape.
        let a0 = 2 * 10.0 * 30 + .pi * 100, p0 = 2 * 30.0 + 2 * .pi * 10
        let want = a0 + p0 * (-3) + .pi * 9
        let got = Profile.signedArea(SegmentOffset.loop(from: off, arcPoints: 720))
        XCTAssertEqual(got, want, accuracy: want * 1e-4)
    }

    func testOutwardOffsetGrowsArcs() throws {
        let off = try XCTUnwrap(SegmentOffset.offset(slot(), by: 2))
        assertClosed(off)
        let (_, r) = try XCTUnwrap(SegmentOffset.circle(through: off[3].start, off[3].mid!, off[3].end))
        XCTAssertEqual(r, 12, accuracy: 1e-9)
        XCTAssertEqual(off[0].start.y, 12, accuracy: 1e-9)
    }

    func testClockwiseInputKeepsItsWinding() throws {
        let cw = slot().reversed().map { Seg(start: $0.end, end: $0.start, mid: $0.mid) }
        let off = try XCTUnwrap(SegmentOffset.offset(cw, by: -3))
        assertClosed(off)
        XCTAssertLessThan(Profile.signedArea(SegmentOffset.loop(from: off)), 0, "still CW")
        XCTAssertEqual(abs(off[0].start.y), 7, accuracy: 1e-9, "same geometry as the CCW case")
    }

    func testSharpCornersMitreAndFilletStaysTangent() throws {
        // A 20×20 square whose top-right corner is a radius-5 fillet.
        let f: [Seg] = [
            Seg(start: SIMD2(0, 0), end: SIMD2(20, 0)),
            Seg(start: SIMD2(20, 0), end: SIMD2(20, 15)),
            Seg(start: SIMD2(20, 15), end: SIMD2(15, 20), mid: SIMD2(15 + 5 / 2.0.squareRoot(), 15 + 5 / 2.0.squareRoot())),
            Seg(start: SIMD2(15, 20), end: SIMD2(0, 20)),
            Seg(start: SIMD2(0, 20), end: SIMD2(0, 0))]
        let off = try XCTUnwrap(SegmentOffset.offset(f, by: -2))
        assertClosed(off)
        XCTAssertEqual(off[0].start.x, 2, accuracy: 1e-9); XCTAssertEqual(off[0].start.y, 2, accuracy: 1e-9)  // mitred corner
        let (c, r) = try XCTUnwrap(SegmentOffset.circle(through: off[2].start, off[2].mid!, off[2].end))
        XCTAssertEqual(c.x, 15, accuracy: 1e-9); XCTAssertEqual(c.y, 15, accuracy: 1e-9)
        XCTAssertEqual(r, 3, accuracy: 1e-9, "the fillet shrank concentrically")
    }

    func testNonTangentArcJointRefuses() {
        // A "D": a bulged top that meets the vertical sides at an angle.
        let d: [Seg] = [
            Seg(start: SIMD2(0, 0), end: SIMD2(20, 0)),
            Seg(start: SIMD2(20, 0), end: SIMD2(20, 10)),
            Seg(start: SIMD2(20, 10), end: SIMD2(0, 10), mid: SIMD2(10, 14)),   // not tangent to the sides
            Seg(start: SIMD2(0, 10), end: SIMD2(0, 0))]
        XCTAssertNil(SegmentOffset.offset(d, by: -1), "an angled arc joint is not exactly offsettable")
    }

    func testCollapseIsRefused() {
        XCTAssertNil(SegmentOffset.offset(slot(), by: -11), "inward past the radius collapses the arcs")
        XCTAssertNotNil(SegmentOffset.offset(slot(), by: -9.9))
    }
}
