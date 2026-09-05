//
//  ViewportSceneBoundsTests.swift
//  openshape3dTests
//
//  Zoom to Fit frames what is drawn. It used to read bodies only, so a
//  sketch on an empty document left `worldBounds` nil and the fit fell back
//  to the default camera — the head-on view of a drawing snapped to an
//  isometric one with the sketch off-screen (STATUS gotcha 38).
//

import XCTest
import simd
@testable import openshape3d

final class ViewportSceneBoundsTests: XCTestCase {

    func testEmptySceneHasNoBounds() {
        XCTAssertNil(ViewportScene().worldBounds)
    }

    func testSketchLinesAloneGiveBounds() throws {
        var scene = ViewportScene()
        scene.sketchLines = [SketchLineBatch(
            segments: [SIMD3(0, 0, 0), SIMD3(60, 0, 0), SIMD3(60, 0, 0), SIMD3(60, 30, 0)],
            color: SIMD4(0, 0, 1, 1))]
        let bounds = try XCTUnwrap(scene.worldBounds)
        XCTAssertEqual(bounds.min, SIMD3(0, 0, 0))
        XCTAssertEqual(bounds.max, SIMD3(60, 30, 0))
    }

    func testProfileFillsCountToo() throws {
        var scene = ViewportScene()
        scene.profileFills = [SketchFillBatch(
            triangles: [SIMD3(-5, 0, 2), SIMD3(5, 0, 2), SIMD3(0, 7, 2)],
            color: SIMD4(0, 0, 1, 0.3))]
        let bounds = try XCTUnwrap(scene.worldBounds)
        XCTAssertEqual(bounds.min, SIMD3(-5, 0, 2))
        XCTAssertEqual(bounds.max, SIMD3(5, 7, 2))
    }

    func testBodiesAndSketchesUnion() throws {
        var scene = ViewportScene()
        let mesh = RenderMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2])
        scene.bodies = [BodyDrawable(
            id: BodyID(), renderMesh: mesh, edges: nil, meshRevision: 1,
            modelMatrix: matrix_identity_float4x4,
            baseColor: SIMD4(1, 1, 1, 1), selectionState: SelectionStateNone.rawValue)]
        scene.sketchLines = [SketchLineBatch(
            segments: [SIMD3(-10, 0, 0), SIMD3(0, 0, -4)], color: SIMD4(0, 0, 1, 1))]
        let bounds = try XCTUnwrap(scene.worldBounds)
        XCTAssertEqual(bounds.min, SIMD3(-10, 0, -4))
        XCTAssertEqual(bounds.max, SIMD3(1, 1, 0))
    }
}
