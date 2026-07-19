//
//  MeasureTests.swift
//  openshape3dTests
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class MeasureTests: XCTestCase {

    private func boxMesh(width: Double = 2, depth: Double = 3, height: Double = 4) -> RenderMesh {
        EuclidBridge.renderMesh(
            from: Euclid.Mesh.primitive(.box(width: width, depth: depth, height: height))
        )
    }

    // MARK: - Volume

    func testBoxVolumeExact() {
        let render = boxMesh()
        XCTAssertEqual(MeasureKit.bodyVolume(render), 24, accuracy: 1e-4)
    }

    func testCylinderVolumeWithinOnePercent() {
        let cylinder = Euclid.Mesh.cylinder(radius: 0.5, height: 2, slices: 48)
        let render = EuclidBridge.renderMesh(from: cylinder)
        let exact = Double.pi * 0.5 * 0.5 * 2
        let measured = MeasureKit.bodyVolume(render)
        XCTAssertEqual(measured, exact, accuracy: exact * 0.01)
        // Faceted cylinders always under-approximate the true volume.
        XCTAssertLessThan(measured, exact)
    }

    func testScaledBodyVolumeScalesCubed() {
        let render = boxMesh()
        let unscaled = MeasureKit.bodyVolume(render)
        XCTAssertEqual(MeasureKit.bodyVolume(render, scale: 2), unscaled * 8, accuracy: 1e-3)
        XCTAssertEqual(MeasureKit.bodyVolume(render, scale: 0.5), unscaled / 8, accuracy: 1e-6)
    }

    // MARK: - Area

    func testBoxSurfaceAreaExact() {
        let render = boxMesh()
        // 2·(2·3 + 2·4 + 3·4) = 52
        XCTAssertEqual(MeasureKit.surfaceArea(render), 52, accuracy: 1e-4)
        XCTAssertEqual(MeasureKit.surfaceArea(render, scale: 3), 52 * 9, accuracy: 1e-3)
    }

    func testBoxTopFaceAreaIsWidthTimesDepth() throws {
        let render = boxMesh()
        // Seed a triangle on the top face (all vertices at y = height).
        let seed = try XCTUnwrap((0..<render.triangleCount).first { t in
            (0..<3).allSatisfy { k in
                abs(render.positions[Int(render.indices[t * 3 + k])].y - 4) < 1e-5
            }
        })
        let face = try XCTUnwrap(FaceTopology.planarFace(in: render, seedTriangle: seed))
        XCTAssertEqual(MeasureKit.faceArea(render, triangles: face.triangles), 6, accuracy: 1e-4)
        XCTAssertEqual(
            MeasureKit.faceArea(render, triangles: face.triangles, scale: 2),
            24,
            accuracy: 1e-4
        )
    }

    func testFaceAreaIgnoresOutOfRangeTriangles() {
        let render = boxMesh()
        XCTAssertEqual(
            MeasureKit.faceArea(render, triangles: [-1, render.triangleCount]),
            0
        )
    }

    // MARK: - Bounding box

    func testBoundingBoxTransformsCorners() {
        let mesh = Euclid.Mesh.primitive(.box(width: 2, depth: 2, height: 2))
        var transform = Transform3D()
        transform.translation = SIMD3(10, 0, -5)
        transform.scale = 2
        let body = Body(name: "Box", transform: transform, euclidMesh: mesh, revision: 1)

        let bounds = MeasureKit.boundingBox(bodies: [body])
        XCTAssertNotNil(bounds)
        guard let bounds else { return }
        // Local AABB is x,z ∈ [-1,1], y ∈ [0,2]; scaled ×2 then translated.
        XCTAssertEqual(bounds.min.x, 8, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.x, 12, accuracy: 1e-5)
        XCTAssertEqual(bounds.min.y, 0, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.y, 4, accuracy: 1e-5)
        XCTAssertEqual(bounds.min.z, -7, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.z, -3, accuracy: 1e-5)
    }

    func testBoundingBoxEmptyIsNil() {
        XCTAssertNil(MeasureKit.boundingBox(bodies: []))
    }

    // MARK: - Distance

    func testPointDistanceAndDeltas() {
        let result = MeasureKit.distance(a: SIMD3(1, 2, 3), b: SIMD3(4, -2, 3))
        XCTAssertEqual(result.distance, 5, accuracy: 1e-12)
        XCTAssertEqual(result.deltas.x, 3, accuracy: 1e-12)
        XCTAssertEqual(result.deltas.y, -4, accuracy: 1e-12)
        XCTAssertEqual(result.deltas.z, 0, accuracy: 1e-12)
    }

    // MARK: - Sketch entities

    func testSketchEntityLengths() {
        let line = SketchEntity.line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(3, 4))
        XCTAssertEqual(MeasureKit.length(of: line), 5, accuracy: 1e-12)

        let rect = SketchEntity.rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(2, 3))
        XCTAssertEqual(MeasureKit.length(of: rect), 10, accuracy: 1e-12)

        let circle = SketchEntity.circle(id: UUID(), center: .zero, radius: 2)
        XCTAssertEqual(MeasureKit.length(of: circle), 4 * .pi, accuracy: 1e-12)
    }

    func testCircleRadiusAndDiameter() {
        let circle = SketchEntity.circle(id: UUID(), center: SIMD2(1, 1), radius: 2.5)
        XCTAssertEqual(MeasureKit.radius(of: circle), 2.5)
        XCTAssertEqual(MeasureKit.diameter(of: circle), 5)

        let line = SketchEntity.line(id: UUID(), a: .zero, b: SIMD2(1, 0))
        XCTAssertNil(MeasureKit.radius(of: line))
        XCTAssertNil(MeasureKit.diameter(of: line))
    }

    func testArcLength() {
        // Quarter circle, radius 2.
        XCTAssertEqual(
            MeasureKit.arcLength(radius: 2, startAngle: 0, endAngle: .pi / 2),
            .pi,
            accuracy: 1e-12
        )
        // Sweep crossing the 0-angle seam: 3π/2 → π/2 is a half circle.
        XCTAssertEqual(
            MeasureKit.arcLength(radius: 1, startAngle: 3 * .pi / 2, endAngle: .pi / 2),
            .pi,
            accuracy: 1e-12
        )
    }

    func testClosedProfileArea() {
        let sketch = Sketch(
            plane: .ground,
            entities: [.rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(4, 2))]
        )
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(MeasureKit.area(of: profiles[0]), 8, accuracy: 1e-9)

        // Winding must not affect the reported area.
        var reversed = profiles[0]
        reversed.loop.reverse()
        XCTAssertEqual(MeasureKit.area(of: reversed), 8, accuracy: 1e-9)
    }
}
