//
//  ChangeSketchPlaneTests.swift
//  openshape3dTests
//
//  Spec §2.4 — re-hosting a sketch on a different plane. Entity coordinates are
//  plane-LOCAL, so the drawing must keep its shape and simply land on the new
//  plane; anything built from it re-evaluates against the new orientation.
//

import XCTest
import simd
@testable import openshape3d

final class ChangeSketchPlaneTests: XCTestCase {

    private func rectSketch() -> Sketch {
        Sketch(plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(10, 6)),
        ])
    }

    /// A plane parallel to ground but raised — distinct enough to detect.
    private var raised: SketchPlane {
        SketchPlane(origin: SIMD3(0, 25, 0), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1))
    }

    /// A vertical plane, so the sketch changes ORIENTATION, not just height.
    private var vertical: SketchPlane {
        SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
    }

    func testCommandSwapsThePlaneAndUndoRestoresIt() {
        var document = DesignDocument()
        let sketch = rectSketch()
        document.sketches.append(sketch)

        let command = ChangeSketchPlaneCommand(
            sketchID: sketch.id, before: sketch.plane, after: raised)
        command.apply(to: &document)
        XCTAssertEqual(document.sketches[0].plane.origin, SIMD3(0, 25, 0),
                       "the sketch moved to the new plane")

        command.revert(in: &document)
        XCTAssertEqual(document.sketches[0].plane.origin, sketch.plane.origin,
                       "undo restores the original plane")
    }

    func testEntityCoordinatesAreUntouchedSoTheDrawingKeepsItsShape() {
        var document = DesignDocument()
        let sketch = rectSketch()
        document.sketches.append(sketch)
        let before = document.sketches[0].entities

        ChangeSketchPlaneCommand(sketchID: sketch.id, before: sketch.plane, after: vertical)
            .apply(to: &document)

        XCTAssertEqual(document.sketches[0].entities, before,
                       "plane-local coordinates must not be rewritten")
    }

    /// The point of §2.4: the geometry actually lands somewhere else in WORLD
    /// space once the host plane changes.
    func testWorldPositionsFollowTheNewPlane() {
        let local = SIMD2<Double>(10, 6)
        let onGround = SketchPlane.ground.toWorld(local)
        let onVertical = vertical.toWorld(local)
        XCTAssertNotEqual(onGround, onVertical,
                          "the same local point maps to a different world point")
        // Ground is the y = 0 plane; the vertical plane spans world XY.
        XCTAssertEqual(onGround.y, 0, accuracy: 1e-9)
        XCTAssertEqual(onVertical.y, 6, accuracy: 1e-9,
                       "local y becomes world y on the vertical plane")
    }

    func testChangingToTheSamePlaneIsANoOp() {
        var document = DesignDocument()
        let sketch = rectSketch()
        document.sketches.append(sketch)
        let command = ChangeSketchPlaneCommand(
            sketchID: sketch.id, before: sketch.plane, after: sketch.plane)
        command.apply(to: &document)
        XCTAssertEqual(document.sketches[0].plane, sketch.plane)
    }

    func testUnknownSketchIDIsIgnoredRatherThanCrashing() {
        var document = DesignDocument()
        document.sketches.append(rectSketch())
        let snapshot = document.sketches
        ChangeSketchPlaneCommand(sketchID: SketchID(), before: .ground, after: vertical)
            .apply(to: &document)
        XCTAssertEqual(document.sketches, snapshot, "a stale ID must be a no-op")
    }
}
