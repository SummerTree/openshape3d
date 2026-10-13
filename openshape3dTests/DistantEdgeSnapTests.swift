//
//  DistantEdgeSnapTests.swift
//  openshape3dTests
//
//  Snapping ▸ Distant Edges: edges of bodies away from the sketch plane,
//  projected onto it, offer their corners, midpoints, circle centers and
//  straight runs — and the setting turns them off.
//

import XCTest
import simd
@testable import openshape3d

final class DistantEdgeSnapTests: XCTestCase {

    /// The 12 edges of an axis-aligned box as segment pairs.
    private func boxEdges(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> [SIMD3<Double>] {
        func c(_ i: Int) -> SIMD3<Double> {
            SIMD3((i & 1) == 0 ? lo.x : hi.x, (i & 2) == 0 ? lo.y : hi.y, (i & 4) == 0 ? lo.z : hi.z)
        }
        let pairs = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        return pairs.flatMap { [c($0.0), c($0.1)] }
    }

    /// A circle of `n` facets at height y, as chained segments.
    private func circleEdges(center: SIMD3<Double>, radius: Double, n: Int = 48) -> [SIMD3<Double>] {
        (0..<n).flatMap { i -> [SIMD3<Double>] in
            let a = Double(i) / Double(n) * 2 * .pi, b = Double(i + 1) / Double(n) * 2 * .pi
            return [center + SIMD3(cos(a), 0, sin(a)) * radius, center + SIMD3(cos(b), 0, sin(b)) * radius]
        }
    }

    /// A sketch plane 50 mm above the ground: sketch (x, y) = world (x, -z).
    private let above = SketchPlane.offsetGround(y: 50)

    func testBoxProjectsToItsFootprint() {
        let g = DistantSnapGeometry.build(segments: boxEdges(.zero, SIMD3(10, 20, 6)), plane: above)
        let corners = Set(g.corners.map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" })
        XCTAssertEqual(corners, ["0,0", "10,0", "0,-6", "10,-6"], "top and bottom corners land on the same four points")
        XCTAssertTrue(g.midpoints.contains { simd_distance($0, SIMD2(5, 0)) < 1e-9 })
        XCTAssertTrue(g.midpoints.contains { simd_distance($0, SIMD2(0, -3)) < 1e-9 })
        XCTAssertTrue(g.centers.isEmpty)
        XCTAssertEqual(g.runs.count, 8, "the vertical edges are seen end-on and add no run")
    }

    func testCircleOffersItsCenterNotItsFacets() {
        let g = DistantSnapGeometry.build(segments: circleEdges(center: SIMD3(30, 5, -40), radius: 4), plane: above)
        XCTAssertEqual(g.centers.count, 1)
        XCTAssertEqual(g.centers[0].x, 30, accuracy: 1e-9)
        XCTAssertEqual(g.centers[0].y, 40, accuracy: 1e-9)
        XCTAssertTrue(g.corners.isEmpty, "a smooth circle has no corners")
        XCTAssertTrue(g.runs.isEmpty)
    }

    func testSnapPrefersDistantCornerAndHonorsTheSetting() {
        let g = DistantSnapGeometry.build(segments: boxEdges(.zero, SIMD3(10, 20, 6)), plane: above)
        let near = SIMD2<Double>(10.2, -0.15)
        let on = SnapEngine.snap(near, in: nil, distant: g, options: SnapOptions(), tolerance: 0.5)
        XCTAssertEqual(on.kind, .endpoint)
        XCTAssertEqual(on.point, SIMD2(10, 0))

        var off = SnapOptions()
        off.distantEdges = false
        let ignored = SnapEngine.snap(near, in: nil, distant: g, options: off, tolerance: 0.5)
        XCTAssertEqual(ignored.kind, .grid, "Distant Edges off falls back to the grid")

        // Sliding along a projected edge stays on it.
        let along = SnapEngine.snap(SIMD2(3.3, -0.1), in: nil, distant: g, options: SnapOptions(), tolerance: 0.5)
        XCTAssertEqual(along.kind, .edge)
        XCTAssertEqual(along.point.y, 0, accuracy: 1e-9)
    }

    func testEmptyInputIsEmpty() {
        XCTAssertTrue(DistantSnapGeometry.build(segments: [], plane: above).isEmpty)
    }
}
