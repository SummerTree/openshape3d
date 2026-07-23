//
//  EdgeOffsetTests.swift
//  openshape3dTests
//
//  Spec §4.13 Offset Edge (3D): derive sketch geometry a fixed distance from a
//  body's face edges. The tests pin the two things a user can see — the output
//  lands on the FACE's plane, and it sits exactly `distance` away from the edge
//  it came from, on the side the sign asked for.
//

import XCTest
import simd
@testable import openshape3d

final class EdgeOffsetTests: XCTestCase {

    /// A 10 x 10 face on the world XY plane, outline CCW.
    private func squareFace(
        origin: SIMD3<Double> = .zero,
        basisX: SIMD3<Double> = SIMD3(1, 0, 0),
        basisY: SIMD3<Double> = SIMD3(0, 1, 0)
    ) -> PlanarFace {
        PlanarFace(
            triangles: [],
            normal: SIMD3<Float>(0, 0, 1),
            origin: origin, basisX: basisX, basisY: basisY,
            outline: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)],
            holes: [])
    }

    private func loopPoints(_ entities: [SketchEntity]) -> [SIMD2<Double>] {
        entities.compactMap { if case let .line(_, a, _) = $0 { return a } else { return nil } }
    }

    // MARK: Chain — the whole boundary

    func testChainOffsetGrowsTheWholeOutlineOutward() throws {
        let result = try XCTUnwrap(EdgeOffsetKit.offset(
            face: squareFace(), pickedPoints: [], distance: 2, mode: .chain))
        let pts = loopPoints(result.entities)
        XCTAssertEqual(pts.count, 4, "a square boundary stays four segments")

        let xs = pts.map(\.x).sorted(), ys = pts.map(\.y).sorted()
        XCTAssertEqual(xs.first!, -2, accuracy: 1e-9)
        XCTAssertEqual(xs.last!, 12, accuracy: 1e-9)
        XCTAssertEqual(ys.first!, -2, accuracy: 1e-9)
        XCTAssertEqual(ys.last!, 12, accuracy: 1e-9,
                       "the 10 x 10 face became a 14 x 14 loop, mitred at the corners")
    }

    func testNegativeChainOffsetShrinksInward() throws {
        let result = try XCTUnwrap(EdgeOffsetKit.offset(
            face: squareFace(), pickedPoints: [], distance: -3, mode: .chain))
        let xs = loopPoints(result.entities).map(\.x).sorted()
        XCTAssertEqual(xs.first!, 3, accuracy: 1e-9)
        XCTAssertEqual(xs.last!, 7, accuracy: 1e-9, "10 shrunk by 3 a side = 4")
    }

    func testAnOffsetThatConsumesTheFaceReturnsNothing() {
        // Shrinking a 10 x 10 face by 8 a side leaves nothing to draw.
        XCTAssertNil(EdgeOffsetKit.offset(
            face: squareFace(), pickedPoints: [], distance: -8, mode: .chain),
            "a collapsed offset must report failure, not emit a flipped loop")
    }

    // MARK: Single — just the picked edges

    func testSingleModeOffsetsOnlyThePickedEdge() throws {
        // Tap the middle of the bottom edge (y = 0).
        let result = try XCTUnwrap(EdgeOffsetKit.offset(
            face: squareFace(), pickedPoints: [SIMD3(5, 0, 0)],
            distance: 2, mode: .single))
        XCTAssertEqual(result.entities.count, 1, "one edge picked, one line out")
        guard case let .line(_, a, b) = result.entities[0] else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, "still horizontal")
        XCTAssertEqual(abs(a.y), 2, accuracy: 1e-9, "exactly the offset distance away")
        XCTAssertEqual(simd_length(b - a), 10, accuracy: 1e-9,
                       "an open offset keeps the edge's length")
    }

    func testTwoPicksProduceTwoOffsetEdges() throws {
        let result = try XCTUnwrap(EdgeOffsetKit.offset(
            face: squareFace(),
            pickedPoints: [SIMD3(5, 0, 0), SIMD3(10, 5, 0)],
            distance: 1, mode: .single))
        XCTAssertEqual(result.entities.count, 2)
    }

    func testSingleModeWithNoPicksIsRefused() {
        XCTAssertNil(EdgeOffsetKit.offset(
            face: squareFace(), pickedPoints: [], distance: 2, mode: .single),
            "Single with nothing selected has no edge to offset")
    }

    // MARK: The host plane

    func testOutputIsHostedOnTheFacesOwnPlane() throws {
        // A face raised 7 up and lying in world XZ.
        let face = squareFace(
            origin: SIMD3(0, 7, 0),
            basisX: SIMD3(1, 0, 0), basisY: SIMD3(0, 0, -1))
        let result = try XCTUnwrap(EdgeOffsetKit.offset(
            face: face, pickedPoints: [], distance: 1, mode: .chain))

        XCTAssertEqual(result.plane.origin, SIMD3(0, 7, 0))
        // Every produced point must land back on that plane in world space.
        for p in loopPoints(result.entities) {
            XCTAssertEqual(result.plane.toWorld(p).y, 7, accuracy: 1e-9,
                           "offset geometry stays on the face it came from")
        }
    }

    func testZeroDistanceIsARefusedNoOp() {
        XCTAssertNil(EdgeOffsetKit.offset(
            face: squareFace(), pickedPoints: [], distance: 0, mode: .chain))
    }

    func testPickSnapsToTheNearestEdgeNotTheNearestCorner() throws {
        // A point just outside the RIGHT edge, closer to it than to any other.
        let result = try XCTUnwrap(EdgeOffsetKit.offset(
            face: squareFace(), pickedPoints: [SIMD3(11, 4, 0)],
            distance: 1, mode: .single))
        guard case let .line(_, a, b) = result.entities[0] else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "the right edge is vertical")
        XCTAssertEqual(abs(abs(a.x) - 10), 1, accuracy: 1e-9,
                       "offset one unit off the x = 10 edge")
    }
}
