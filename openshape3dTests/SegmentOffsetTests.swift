//
//  SegmentOffsetTests.swift
//  openshape3dTests
//
//  The exact line/arc offset behind the drafted rounded profile
//  (docs/DRAFT_TAPER_DESIGN.md slice 3): arcs stay concentric, lines shift,
//  tangent joints stay sealed, non-tangent joints trim to the carriers'
//  intersection, and anything not exactly offsettable is a nil.
//

import XCTest
import simd
@testable import openshape3d

final class SegmentOffsetTests: XCTestCase {

    private typealias Seg = Profile.Segment

    /// A slot: centres (−15,0) and (15,0), radius 10, traversed CCW.
    private func slot(r: Double = 10, half: Double = 15) -> [Seg] {
        [Seg(start: SIMD2(half, r), end: SIMD2(-half, r)),
         Seg(start: SIMD2(-half, r), end: SIMD2(-half, -r), mid: SIMD2(-half - r, 0)),
         Seg(start: SIMD2(-half, -r), end: SIMD2(half, -r)),
         Seg(start: SIMD2(half, -r), end: SIMD2(half, r), mid: SIMD2(half + r, 0))]
    }

    /// A "D": a bulged top (chord 20, sagitta 4 → r 14.5, centre (10, −0.5))
    /// meeting the vertical sides at an angle — NOT tangent.
    private func dShape() -> [Seg] {
        [Seg(start: SIMD2(0, 0), end: SIMD2(20, 0)),
         Seg(start: SIMD2(20, 0), end: SIMD2(20, 10)),
         Seg(start: SIMD2(20, 10), end: SIMD2(0, 10), mid: SIMD2(10, 14)),
         Seg(start: SIMD2(0, 10), end: SIMD2(0, 0))]
    }

    /// A lens: two convex arcs (chord 20, sagitta 6 → r 11.333, centres
    /// (0, ∓5.333)) meeting at (±10, 0) — an arc–arc joint, not tangent.
    private func lens() -> [Seg] {
        [Seg(start: SIMD2(10, 0), end: SIMD2(-10, 0), mid: SIMD2(0, 6)),
         Seg(start: SIMD2(-10, 0), end: SIMD2(10, 0), mid: SIMD2(0, -6))]
    }

    private func assertClosed(_ segs: [Seg], file: StaticString = #filePath, line: UInt = #line) {
        for i in segs.indices {
            let next = segs[(i + 1) % segs.count]
            XCTAssertEqual(simd_length(segs[i].end - next.start), 0, accuracy: 1e-9,
                           "segment \(i) must meet segment \((i + 1) % segs.count)", file: file, line: line)
        }
    }

    private func arc(_ s: Seg) throws -> (center: SIMD2<Double>, radius: Double) {
        try XCTUnwrap(SegmentOffset.circle(through: s.start, try XCTUnwrap(s.mid), s.end))
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
        XCTAssertEqual(off[0].start.y, 7, accuracy: 1e-9); XCTAssertEqual(off[2].start.y, -7, accuracy: 1e-9)
        for i in [1, 3] {
            let (c, r) = try arc(off[i])
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
        XCTAssertEqual(try arc(off[3]).radius, 12, accuracy: 1e-9)
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
            Seg(start: SIMD2(20, 15), end: SIMD2(15, 20),
                mid: SIMD2(15 + 5 / 2.0.squareRoot(), 15 + 5 / 2.0.squareRoot())),
            Seg(start: SIMD2(15, 20), end: SIMD2(0, 20)),
            Seg(start: SIMD2(0, 20), end: SIMD2(0, 0))]
        let off = try XCTUnwrap(SegmentOffset.offset(f, by: -2))
        assertClosed(off)
        XCTAssertEqual(off[0].start.x, 2, accuracy: 1e-9); XCTAssertEqual(off[0].start.y, 2, accuracy: 1e-9)
        let (c, r) = try arc(off[2])
        XCTAssertEqual(c.x, 15, accuracy: 1e-9); XCTAssertEqual(c.y, 15, accuracy: 1e-9)
        XCTAssertEqual(r, 3, accuracy: 1e-9, "the fillet shrank concentrically")
    }

    /// The last draft gap: a non-tangent line–arc joint trims both carriers
    /// to their intersection. Inward by 1: sides at x = 1 / 19, arc radius
    /// 13.5 about (10, −0.5), so the joints sit at y = −0.5 + √(13.5² − 9²)
    /// = 9.5623 and the arc's new mid is straight above the centre, (10, 13).
    func testNonTangentLineArcJointTrimsToTheIntersection() throws {
        let off = try XCTUnwrap(SegmentOffset.offset(dShape(), by: -1))
        assertClosed(off)
        let (c, r) = try arc(off[2])
        XCTAssertEqual(c.x, 10, accuracy: 1e-9); XCTAssertEqual(c.y, -0.5, accuracy: 1e-9)
        XCTAssertEqual(r, 13.5, accuracy: 1e-9)
        let yJoint = -0.5 + (13.5 * 13.5 - 81).squareRoot()
        XCTAssertEqual(off[1].end.x, 19, accuracy: 1e-9); XCTAssertEqual(off[1].end.y, yJoint, accuracy: 1e-9)
        XCTAssertEqual(off[3].start.x, 1, accuracy: 1e-9); XCTAssertEqual(off[3].start.y, yJoint, accuracy: 1e-9)
        let mid = try XCTUnwrap(off[2].mid)
        XCTAssertEqual(mid.x, 10, accuracy: 1e-9); XCTAssertEqual(mid.y, 13, accuracy: 1e-9)
        XCTAssertEqual(off[0].start.x, 1, accuracy: 1e-9); XCTAssertEqual(off[0].start.y, 1, accuracy: 1e-9)
    }

    /// Arc–arc: the lens offset inward by 1 becomes the thinner lens of the
    /// two radius-10.333 circles, whose intersections are at x = ±√(r² − (d/2)²).
    func testNonTangentArcArcJointTrimsToTheCircleIntersection() throws {
        let off = try XCTUnwrap(SegmentOffset.offset(lens(), by: -1))
        assertClosed(off)
        let r = 400.0 / (8 * 6) + 3 - 1                       // 11.333 − 1 = 10.333
        let d = 2 * (r + 1 - 6)                               // centre distance 10.667
        let xJoint = (r * r - (d / 2) * (d / 2)).squareRoot() // 8.851
        for s in off {
            XCTAssertEqual(try arc(s).radius, r, accuracy: 1e-9)
        }
        XCTAssertEqual(abs(off[0].start.x), xJoint, accuracy: 1e-9)
        XCTAssertEqual(off[0].start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(abs(off[1].start.x), xJoint, accuracy: 1e-9)
    }

    func testCarriersThatNoLongerMeetRefuse() {
        // Inward by 7 the lens's circles (r 4.333 each, 10.667 apart) never
        // touch — no intersection, no exact offset.
        XCTAssertNil(SegmentOffset.offset(lens(), by: -7))
    }

    func testCollapseIsRefused() {
        XCTAssertNil(SegmentOffset.offset(slot(), by: -11), "inward past the radius collapses the arcs")
        XCTAssertNotNil(SegmentOffset.offset(slot(), by: -9.9))
    }
}
