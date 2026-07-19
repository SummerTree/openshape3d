//
//  SketchEntityTests.swift
//  openshape3dTests
//
//  Coverage for the A2 sketch entity breadth: arc, ellipse, polygon —
//  profile detection, snapping, tessellation, and Codable compatibility.
//

import XCTest
import simd
@testable import openshape3d

final class SketchEntityTests: XCTestCase {

    private func makeSketch(_ entities: [SketchEntity]) -> Sketch {
        Sketch(plane: .ground, entities: entities)
    }

    // MARK: - Profile detection

    func testArcWithTwoLinesClosesLoop() {
        // Semicircle over the x-axis (r = 2, CCW from (2,0) to (-2,0)) closed
        // by two lines through (0,-2). Area = πr²/2 + triangle = 2π + 4.
        let arcID = UUID()
        let sketch = makeSketch([
            .arc(id: arcID, center: SIMD2(0, 0), radius: 2, startAngle: 0, endAngle: .pi),
            .line(id: UUID(), a: SIMD2(-2, 0), b: SIMD2(0, -2)),
            .line(id: UUID(), a: SIMD2(0, -2), b: SIMD2(2, 0)),
        ])
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].sourceEntityIDs.count, 3)
        XCTAssertTrue(profiles[0].sourceEntityIDs.contains(arcID))
        XCTAssertEqual(profiles[0].area, 2 * .pi + 4, accuracy: 0.1)
        XCTAssertTrue(profiles[0].contains(SIMD2(0, 0.5)))
        XCTAssertTrue(profiles[0].contains(SIMD2(0, -0.5)))
        XCTAssertFalse(profiles[0].contains(SIMD2(3, 0)))
    }

    func testArcWithSingleClosingLineMakesHalfDisc() {
        let sketch = makeSketch([
            .arc(id: UUID(), center: SIMD2(0, 0), radius: 2, startAngle: 0, endAngle: .pi),
            .line(id: UUID(), a: SIMD2(-2, 0), b: SIMD2(2, 0)),
        ])
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].area, 2 * .pi, accuracy: 0.1)
    }

    func testOpenArcAloneMakesNoProfile() {
        let sketch = makeSketch([
            .arc(id: UUID(), center: SIMD2(0, 0), radius: 2, startAngle: 0, endAngle: .pi / 2),
        ])
        XCTAssertTrue(ProfileDetector.detectProfiles(in: sketch).isEmpty)
    }

    func testPolygonProfileAreaMatchesRegularNGonFormula() {
        // Regular n-gon area = (n/2)·r²·sin(2π/n).
        for sides in [3, 5, 6, 8] {
            let radius = 2.0
            let sketch = makeSketch([
                .polygon(id: UUID(), center: SIMD2(1, -1), radius: radius, sides: sides, rotation: 0.4),
            ])
            let profiles = ProfileDetector.detectProfiles(in: sketch)
            XCTAssertEqual(profiles.count, 1)
            XCTAssertEqual(profiles[0].loop.count, sides)
            let expected = Double(sides) / 2 * radius * radius * sin(2 * .pi / Double(sides))
            XCTAssertEqual(profiles[0].area, expected, accuracy: 1e-9, "\(sides)-gon area")
        }
    }

    func testEllipseProfileDetectedAndContainsCenter() {
        let center = SIMD2<Double>(2, 1)
        let sketch = makeSketch([
            .ellipse(id: UUID(), center: center, radiusX: 3, radiusY: 1.5, rotation: 0.3),
        ])
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].contains(center))
        XCTAssertEqual(profiles[0].area, .pi * 3 * 1.5, accuracy: 0.1)
        // A point past the minor radius but inside the major one, along the
        // (rotated) major axis direction, is inside; perpendicular it is not.
        let major = SIMD2(cos(0.3), sin(0.3))
        let minor = SIMD2(-sin(0.3), cos(0.3))
        XCTAssertTrue(profiles[0].contains(center + major * 2.5))
        XCTAssertFalse(profiles[0].contains(center + minor * 2.5))
    }

    // MARK: - Snapping

    func testArcEndpointsAndCenterSnappable() {
        let sketch = makeSketch([
            .arc(id: UUID(), center: SIMD2(1, 1), radius: 2, startAngle: 0, endAngle: .pi / 2),
        ])
        // Start endpoint (3, 1).
        let start = SnapEngine.snap(SIMD2(3.1, 1.1), in: sketch)
        XCTAssertTrue(start.snappedToPoint)
        XCTAssertEqual(start.point.x, 3, accuracy: 1e-9)
        XCTAssertEqual(start.point.y, 1, accuracy: 1e-9)
        // End endpoint (1, 3).
        let end = SnapEngine.snap(SIMD2(0.9, 3.1), in: sketch)
        XCTAssertTrue(end.snappedToPoint)
        XCTAssertEqual(end.point.x, 1, accuracy: 1e-9)
        XCTAssertEqual(end.point.y, 3, accuracy: 1e-9)
        // Center (1, 1).
        let center = SnapEngine.snap(SIMD2(1.1, 0.9), in: sketch)
        XCTAssertTrue(center.snappedToPoint)
        XCTAssertEqual(center.point.x, 1, accuracy: 1e-9)
        XCTAssertEqual(center.point.y, 1, accuracy: 1e-9)
    }

    func testLineMidpointSnappable() {
        let sketch = makeSketch([
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(4, 2)),
        ])
        let result = SnapEngine.snap(SIMD2(2.1, 1.1), in: sketch)
        XCTAssertTrue(result.snappedToPoint)
        XCTAssertEqual(result.point.x, 2, accuracy: 1e-9)
        XCTAssertEqual(result.point.y, 1, accuracy: 1e-9)
    }

    func testPolygonVerticesSnappableAndEllipseCenterSnappable() {
        let sketch = makeSketch([
            .polygon(id: UUID(), center: SIMD2(0, 0), radius: 2, sides: 4, rotation: 0),
            .ellipse(id: UUID(), center: SIMD2(10, 10), radiusX: 3, radiusY: 1, rotation: 0),
        ])
        // Square vertex at (0, 2) (rotation 0 → vertices on the axes).
        let vertex = SnapEngine.snap(SIMD2(0.1, 2.1), in: sketch)
        XCTAssertTrue(vertex.snappedToPoint)
        XCTAssertEqual(vertex.point.x, 0, accuracy: 1e-9)
        XCTAssertEqual(vertex.point.y, 2, accuracy: 1e-9)

        let center = SnapEngine.snap(SIMD2(10.1, 9.9), in: sketch)
        XCTAssertTrue(center.snappedToPoint)
        XCTAssertEqual(center.point.x, 10, accuracy: 1e-9)
        XCTAssertEqual(center.point.y, 10, accuracy: 1e-9)
    }

    // MARK: - Tessellation

    func testTessellationEmitsSegmentsForNewEntities() {
        let sides = 6
        let entities: [SketchEntity] = [
            .arc(id: UUID(), center: SIMD2(0, 0), radius: 2, startAngle: 0, endAngle: .pi),
            .ellipse(id: UUID(), center: SIMD2(0, 0), radiusX: 3, radiusY: 1.5, rotation: 0),
            .polygon(id: UUID(), center: SIMD2(0, 0), radius: 2, sides: sides, rotation: 0),
        ]
        for entity in entities {
            let points = SketchTessellator.segments(for: [entity], on: .ground)
            XCTAssertFalse(points.isEmpty, "\(entity) tessellates")
            XCTAssertEqual(points.count % 2, 0, "Segment list is pairs")
        }
        // Polygon: exactly `sides` closed-loop segments.
        let polygonPoints = SketchTessellator.segments(for: [entities[2]], on: .ground)
        XCTAssertEqual(polygonPoints.count, sides * 2)
        // Half-circle arc gets roughly half the full-circle density.
        let arcPoints = SketchTessellator.segments(for: [entities[0]], on: .ground)
        XCTAssertEqual(arcPoints.count / 2, SketchTessellator.circleSegments / 2)
    }

    // MARK: - Codable

    func testSketchWithEveryEntityKindRoundTrips() throws {
        let sketch = makeSketch([
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(1, 2)),
            .rect(id: UUID(), min: SIMD2(-1, -1), max: SIMD2(3, 2)),
            .circle(id: UUID(), center: SIMD2(5, 5), radius: 1.25),
            .arc(id: UUID(), center: SIMD2(0, 0), radius: 2, startAngle: 0.5, endAngle: 2.5),
            .ellipse(id: UUID(), center: SIMD2(1, 1), radiusX: 3, radiusY: 1.5, rotation: 0.3),
            .polygon(id: UUID(), center: SIMD2(-2, 4), radius: 1.5, sides: 6, rotation: 0.1),
        ])
        let data = try JSONEncoder().encode(sketch)
        let decoded = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertEqual(decoded, sketch)
    }

    func testLegacySketchWithoutNewCasesStillDecodes() throws {
        // Persisted sketches written before arc/ellipse/polygon existed must
        // keep decoding: encode only old cases, decode with the extended enum.
        let sketch = makeSketch([
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(1, 0)),
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(1, 1)),
            .circle(id: UUID(), center: SIMD2(0, 0), radius: 1),
        ])
        let data = try JSONEncoder().encode(sketch)
        let decoded = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertEqual(decoded, sketch)
    }
}
