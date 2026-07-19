//
//  PlaneTests.swift
//  openshape3dTests
//
//  Sketch planes (A1): world planes, geometric plane matching, plane picker
//  hit-testing, and the offset construction plane model/command.
//

import XCTest
import simd
@testable import openshape3d

@MainActor
final class PlaneTests: XCTestCase {

    // MARK: - World planes

    func testWorldPlaneNormals() {
        XCTAssertEqual(SketchPlane.ground.normal, SIMD3(0, 1, 0))
        XCTAssertEqual(SketchPlane.worldXY.normal, SIMD3(0, 0, 1))
        XCTAssertEqual(SketchPlane.worldYZ.normal, SIMD3(1, 0, 0))
    }

    // MARK: - Plane coincidence (find-or-create rule)

    func testCoincidenceIgnoresBasisAndInPlaneOrigin() {
        // Same geometric plane, different basis orientation and origin.
        let rotated = SketchPlane(
            origin: SIMD3(3, 0, -2),
            xAxis: simd_normalize(SIMD3(1, 0, -1)),
            yAxis: simd_normalize(SIMD3(-1, 0, -1))
        )
        XCTAssertTrue(SketchPlane.ground.isCoincident(with: rotated))
        // Opposite-facing normal is still the same geometric plane.
        let flipped = SketchPlane(
            origin: .zero,
            xAxis: SIMD3(0, 0, -1),
            yAxis: SIMD3(1, 0, 0)
        )
        XCTAssertEqual(flipped.normal, SIMD3(0, -1, 0))
        XCTAssertTrue(SketchPlane.ground.isCoincident(with: flipped))
    }

    func testCoincidenceRejectsOffsetAndTiltedPlanes() {
        XCTAssertFalse(SketchPlane.ground.isCoincident(with: .offsetGround(y: 2)))
        XCTAssertFalse(SketchPlane.ground.isCoincident(with: .worldXY))
    }

    // MARK: - Plane picker hit-testing

    func testPickHitsTileWithinBoundsOnly() {
        let tiles = PlanePicking.worldTiles
        // Straight down onto the center of the ground tile: local (1.3, 1.3)
        // maps to world (1.3, 0, -1.3).
        let hitRay = Ray(origin: SIMD3(1.3, 10, -1.3), direction: SIMD3(0, -1, 0))
        let hit = PlanePicking.pick(ray: hitRay, tiles: tiles)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.tile.plane.normal, SIMD3(0, 1, 0))
        XCTAssertEqual(hit.map(\.distance) ?? 0, 10, accuracy: 1e-4)

        // Down onto the ground but outside every tile rectangle.
        let missRay = Ray(origin: SIMD3(5, 10, 5), direction: SIMD3(0, -1, 0))
        XCTAssertNil(PlanePicking.pick(ray: missRay, tiles: tiles))
    }

    func testPickReturnsNearestTile() {
        // Ray through the XY tile first, then onward to the ground tile.
        let target = SIMD3<Float>(1.3, 1.3, 0) // XY tile center
        let origin = SIMD3<Float>(1.3, 5, 5)
        let ray = Ray(origin: origin, direction: simd_normalize(target - origin))
        let hit = PlanePicking.pick(ray: ray, tiles: PlanePicking.worldTiles)
        XCTAssertEqual(hit?.tile.plane.normal, SIMD3(0, 0, 1))
    }

    // MARK: - Construction plane model

    func testConstructionPlaneCodableRoundTrip() throws {
        let plane = ConstructionPlane(
            plane: SketchPlane(
                origin: SIMD3(0, 2.5, 0),
                xAxis: SIMD3(1, 0, 0),
                yAxis: SIMD3(0, 0, -1)
            ),
            size: 6
        )
        let data = try JSONEncoder().encode(plane)
        let decoded = try JSONDecoder().decode(ConstructionPlane.self, from: data)
        XCTAssertEqual(decoded, plane)
    }

    func testAddConstructionPlaneCommandAppliesAndReverts() {
        var document = DesignDocument()
        let plane = ConstructionPlane(plane: .offsetGround(y: 3), size: 4)
        let command = AddConstructionPlaneCommand(plane: plane)

        command.apply(to: &document)
        XCTAssertEqual(document.planes, [plane])

        command.revert(in: &document)
        XCTAssertTrue(document.planes.isEmpty)
    }
}
