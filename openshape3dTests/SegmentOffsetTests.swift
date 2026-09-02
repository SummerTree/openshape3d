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

    /// A spline segment has no exact offset (the offset of a cubic is not a
    /// cubic): the boundary takes the polygon path instead.
    func testSplineSegmentsRefuse() {
        let withSpline: [Seg] = [
            Seg(start: SIMD2(0, 0), end: SIMD2(20, 0)),
            Seg(start: SIMD2(20, 0), end: SIMD2(0, 0),
                controlPoints: [SIMD2(20, 0), SIMD2(15, 8), SIMD2(5, 8), SIMD2(0, 0)])]
        XCTAssertNil(SegmentOffset.offset(withSpline, by: -1))
    }

    func testCollapseIsRefused() {
        XCTAssertNil(SegmentOffset.offset(slot(), by: -11), "inward past the radius collapses the arcs")
        XCTAssertNotNil(SegmentOffset.offset(slot(), by: -9.9))
    }

    /// A 60×20 outline with R5 rounds on the right and 2 mm chamfers on the
    /// left: 4 mm inward, the rounds shrink to R1 exactly while each chamfer
    /// is consumed (its mitres cross after 2.4 mm) and collapses onto the
    /// sharp corner where the top/bottom line meets the left line — the
    /// segment count survives, the stub is ε long, and the section area is
    /// the 52×12 rectangle less two R1 corner deficits.
    private func roundedAndChamfered() -> [Seg] {
        let c = 0.7071067811865476 * 5
        return [
            Seg(start: SIMD2(-28, -10), end: SIMD2(25, -10)),
            Seg(start: SIMD2(25, -10), end: SIMD2(30, -5), mid: SIMD2(25 + c, -5 - c)),
            Seg(start: SIMD2(30, -5), end: SIMD2(30, 5)),
            Seg(start: SIMD2(30, 5), end: SIMD2(25, 10), mid: SIMD2(25 + c, 5 + c)),
            Seg(start: SIMD2(25, 10), end: SIMD2(-28, 10)),
            Seg(start: SIMD2(-28, 10), end: SIMD2(-30, 8)),
            Seg(start: SIMD2(-30, 8), end: SIMD2(-30, -8)),
            Seg(start: SIMD2(-30, -8), end: SIMD2(-28, -10)),
        ]
    }

    func testAConsumedChamferBetweenLinesCollapsesOntoTheCorner() throws {
        let g = try XCTUnwrap(SegmentOffset.offset(roundedAndChamfered(), by: -4), "consumed chamfers must not refuse")
        XCTAssertEqual(g.count, 8, "segment count survives for the loft")
        for i in [5, 7] {
            XCTAssertLessThan(simd_distance(g[i].start, g[i].end), 2e-3, "chamfer \(i) is an ε-stub")
        }
        XCTAssertLessThan(simd_distance(g[5].start, SIMD2(-26, 6)), 2e-3, "top-left corner \(g[5].start)")
        XCTAssertLessThan(simd_distance(g[7].start, SIMD2(-26, -6)), 2e-3, "bottom-left corner \(g[7].start)")
        // the rounds are concentric R1 arcs, still exact
        let mid1 = try XCTUnwrap(g[1].mid), mid3 = try XCTUnwrap(g[3].mid)
        XCTAssertEqual(simd_distance(mid1, SIMD2(25, -5)), 1, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(mid3, SIMD2(25, 5)), 1, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(g[6].start, SIMD2(-26, 6)), 0, accuracy: 2e-3)
        XCTAssertEqual(simd_distance(g[6].end, SIMD2(-26, -6)), 0, accuracy: 2e-3)
        let area = Profile.signedArea(SegmentOffset.loop(from: g, arcPoints: 64))
        XCTAssertEqual(area, 52 * 12 - 2 * (1 - Double.pi / 4), accuracy: 0.05)
    }

    func testAnOffsetPastTheRoundsStillRefuses() {
        XCTAssertNil(SegmentOffset.offset(roundedAndChamfered(), by: -8),
                     "8 mm inward collapses the R5 rounds and reverses the right flank — no section")
    }
}
