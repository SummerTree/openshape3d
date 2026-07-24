//
//  FaceSnapTests.swift
//  openshape3dTests
//
//  Sketching on a solid's face used to have NOTHING to snap to but the grid —
//  there is no sketch geometry on a bare face — so a rectangle landed wherever
//  the finger was, often straddling an edge. These cover the face's own
//  boundary being offered as snap targets: corners, edge midpoints, the loop
//  centre, and sliding along an edge.
//

import XCTest
import simd
@testable import openshape3d

final class FaceSnapTests: XCTestCase {

    /// A 4×4 face centred on the sketch plane origin.
    private let square: [SIMD2<Double>] = [
        SIMD2(-2, -2), SIMD2(2, -2), SIMD2(2, 2), SIMD2(-2, 2),
    ]

    private func snap(_ p: SIMD2<Double>) -> SnapResult {
        SnapEngine.snap(p, in: nil, faceLoops: [square])
    }

    func testSnapsToAFaceCorner() {
        let result = snap(SIMD2(1.93, 2.06))     // near the (2,2) corner
        XCTAssertEqual(result.kind, .endpoint)
        XCTAssertEqual(result.point.x, 2, accuracy: 1e-9)
        XCTAssertEqual(result.point.y, 2, accuracy: 1e-9)
    }

    func testSnapsToAnEdgeMidpoint() {
        let result = snap(SIMD2(0.08, -1.94))    // near the midpoint of the bottom edge
        XCTAssertEqual(result.kind, .midpoint)
        XCTAssertEqual(result.point.x, 0, accuracy: 1e-9)
        XCTAssertEqual(result.point.y, -2, accuracy: 1e-9)
    }

    func testSnapsToTheFaceCenter() {
        let result = snap(SIMD2(0.1, -0.12))
        XCTAssertEqual(result.kind, .center)
        XCTAssertEqual(simd_length(result.point), 0, accuracy: 1e-9)
    }

    /// Sliding along a boundary: not near any named point, but close to the
    /// edge, should land exactly ON the edge rather than on the grid.
    func testSlidesAlongAnEdge() {
        let result = snap(SIMD2(1.2, 2.1))       // near the top edge, away from corner/midpoint
        XCTAssertEqual(result.kind, .edge)
        XCTAssertEqual(result.point.y, 2, accuracy: 1e-9, "pinned onto the edge line")
        XCTAssertEqual(result.point.x, 1.2, accuracy: 1e-9, "free to slide along it")
    }

    /// A named point must beat a mere edge slide, or you could never land on a
    /// corner while tracing the boundary.
    func testCornerBeatsEdgeAtATie() {
        let result = snap(SIMD2(1.98, 2.02))
        XCTAssertEqual(result.kind, .endpoint, "the corner wins over the edge it sits on")
    }

    /// Far from the face, behaviour is unchanged — the grid still governs, so
    /// this can't hijack ordinary sketching.
    func testFarFromTheFaceFallsBackToTheGrid() {
        let result = snap(SIMD2(9.03, 7.04))
        XCTAssertEqual(result.kind, .grid)
    }

    /// Holes in the face are snappable too (an inner boundary is exactly what
    /// you align to when cutting a concentric feature).
    func testHoleLoopIsAlsoSnappable() {
        let hole: [SIMD2<Double>] = [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5),
        ]
        let result = SnapEngine.snap(SIMD2(0.44, 0.53), in: nil, faceLoops: [square, hole])
        XCTAssertEqual(result.kind, .endpoint)
        XCTAssertEqual(result.point.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.point.y, 0.5, accuracy: 1e-9)
    }

    /// With no face supplied the engine behaves exactly as before.
    func testNoFaceLoopsIsUnchangedGridBehaviour() {
        let result = SnapEngine.snap(SIMD2(1.2, 2.1), in: nil)
        XCTAssertEqual(result.kind, .grid)
    }
}
