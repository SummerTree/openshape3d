//
//  FacePushPullTests.swift
//  openshape3dTests
//
//  Regression for the "hanging surfaces" bug: pushing a body's planar face
//  inward must truncate the solid cleanly. A same-cross-section boolean
//  subtract leaves the original side walls behind (coincident faces don't
//  cancel in mesh CSG), producing a non-watertight mesh with excess area.
//  The fix truncates via a half-space cut instead.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FacePushPullTests: XCTestCase {

    private let groundNormal = SIMD3<Double>(0, 1, 0)

    /// The half-space truncation used by the face push/pull inward path.
    private func truncateTop(_ mesh: Euclid.Mesh, keepBelowY y: Double) -> Euclid.Mesh {
        let plane = SketchPlane(
            origin: SIMD3(0, y, 0),
            xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 0, -1) // normal = xAxis × yAxis = +Y
        )
        return SplitKit.split(mesh: mesh, byPlane: plane).other // −Y side (below)
    }

    func testCylinderTopPushedInwardStaysClean() {
        // A 10-tall cylinder, radius 2, base on the ground.
        let cyl = Euclid.Mesh.primitive(.cylinder(radius: 2, height: 10))
        XCTAssertTrue(cyl.isWatertight)

        // Push the top face down by 4 → an 8-tall cylinder.
        let result = truncateTop(cyl, keepBelowY: 6)

        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight,
                      "Truncated cylinder must be watertight — hanging walls break this")

        let render = EuclidBridge.renderMesh(from: result)
        let aabb = render.localAABB
        XCTAssertEqual(aabb.min.y, 0, accuracy: 1e-3)
        XCTAssertEqual(aabb.max.y, 6, accuracy: 0.05, "Top truncated to y=6, no walls above")

        // Volume of the 6-tall cylinder; hanging walls would not change volume
        // but WOULD add surface area, so check both.
        let volume = MeasureKit.bodyVolume(render, scale: 1)
        XCTAssertEqual(volume, Double.pi * 4 * 6, accuracy: Double.pi * 4 * 6 * 0.03)

        // Surface area of a clean r=2 h=6 cylinder = 2πr² + 2πrh.
        let area = MeasureKit.surfaceArea(render, scale: 1)
        let expected = 2 * Double.pi * 4 + 2 * Double.pi * 2 * 6
        XCTAssertEqual(area, expected, accuracy: expected * 0.04,
                       "Excess area means leftover hanging walls")
    }

    func testBoxTopPushedInwardStaysClean() {
        let box = Euclid.Mesh.primitive(.box(width: 4, depth: 4, height: 10))
        let result = truncateTop(box, keepBelowY: 6)

        XCTAssertTrue(result.isWatertight)
        let render = EuclidBridge.renderMesh(from: result)
        let aabb = render.localAABB
        XCTAssertEqual(aabb.max.y, 6, accuracy: 1e-3)

        let volume = MeasureKit.bodyVolume(render, scale: 1)
        XCTAssertEqual(volume, 4 * 4 * 6, accuracy: 4 * 4 * 6 * 0.01)
        // 12 triangles for a box → truncation stays a clean box (12 tris).
        XCTAssertEqual(render.triangleCount, 12, "A truncated box is still a clean box")
    }

    func testOutwardPullExtendsCleanly() {
        // Pulling a face outward unions a flush prism; the result must stay a
        // single watertight solid of the extended height.
        let cyl = Euclid.Mesh.primitive(.cylinder(radius: 2, height: 6))
        let prism = Euclid.Mesh.primitive(.cylinder(radius: 2, height: 3))
            .translated(by: Vector(0, 6, 0))
        let result = cyl.union(prism).makeWatertight()

        XCTAssertTrue(result.isWatertight)
        let aabb = EuclidBridge.renderMesh(from: result).localAABB
        XCTAssertEqual(aabb.max.y, 9, accuracy: 0.05, "Union extends the cylinder to y=9")
    }
}
