//
//  SketchTransformProjectTests.swift
//  openshape3dTests
//
//  Plan §B6 (sketch transforms), §B8 (projection), §B9 (construction flag).
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class SketchTransformProjectTests: XCTestCase {

    // MARK: Helpers

    private func assertEqual(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, accuracy: Double = 1e-9,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    private func makeBody(_ spec: PrimitiveSpec, at translation: SIMD3<Double>) -> Body {
        var transform = Transform3D.identity
        transform.translation = translation
        return Body(
            name: spec.displayName,
            transform: transform,
            primitive: spec,
            euclidMesh: .primitive(spec),
            revision: 1
        )
    }

    // MARK: - Translate

    func testTranslateRoundTripPreservesEntitiesAndIDs() {
        let entities: [SketchEntity] = [
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(4, 1)),
            .rect(id: UUID(), min: SIMD2(-1, -1), max: SIMD2(2, 3)),
            .circle(id: UUID(), center: SIMD2(1, 2), radius: 0.75),
            .arc(id: UUID(), center: SIMD2(3, -2), radius: 1.5, startAngle: 0.25, endAngle: 2.0),
            .ellipse(id: UUID(), center: SIMD2(0, 5), radiusX: 2, radiusY: 1, rotation: 0.3),
            .polygon(id: UUID(), center: SIMD2(-3, 0), radius: 2, sides: 6, rotation: 0.1),
        ]
        let delta = SIMD2(1.5, -2.25) // dyadic, so + then - is exact

        let there = SketchTransform.translate(entities: entities, by: delta)
        let back = SketchTransform.translate(entities: there, by: -delta)

        XCTAssertEqual(back, entities, "Translate there-and-back must be exact")
        XCTAssertEqual(there.map(\.id), entities.map(\.id), "Translate must preserve IDs")
    }

    // MARK: - Rotate

    func testRotateRect90DegreesSwapsAABB() {
        let id = UUID()
        let rect = SketchEntity.rect(id: id, min: SIMD2(0, 0), max: SIMD2(4, 2))
        let center = SIMD2(2.0, 1.0)

        let rotated = SketchTransform.rotate(entities: [rect], about: center, angle: .pi / 2)

        XCTAssertEqual(rotated.count, 1, "Right-angle rotation keeps the rect a rect")
        guard case let .rect(newID, lo, hi) = rotated[0] else {
            return XCTFail("Expected a rect, got \(rotated[0])")
        }
        XCTAssertEqual(newID, id)
        // 4x2 about its center -> 2x4: x in [1,3], y in [-1,3].
        assertEqual(lo, SIMD2(1, -1))
        assertEqual(hi, SIMD2(3, 3))
        XCTAssertEqual(hi.x - lo.x, 2, accuracy: 1e-9, "Width and height swap")
        XCTAssertEqual(hi.y - lo.y, 4, accuracy: 1e-9, "Width and height swap")
    }

    func testRotateRectArbitraryAngleBecomesFourLines() {
        let id = UUID()
        let rect = SketchEntity.rect(id: id, min: SIMD2(0, 0), max: SIMD2(3, 2))

        let rotated = SketchTransform.rotate(entities: [rect], about: SIMD2(0, 0), angle: .pi / 6)

        XCTAssertEqual(rotated.count, 4, "Non-right-angle rotation decomposes the rect")
        XCTAssertEqual(rotated[0].id, id, "First line inherits the rect ID")
        var perimeter = 0.0
        for entity in rotated {
            guard case let .line(_, a, b) = entity else {
                return XCTFail("Expected lines, got \(entity)")
            }
            perimeter += simd_length(b - a)
        }
        XCTAssertEqual(perimeter, 10, accuracy: 1e-9, "Perimeter is rotation-invariant")
    }

    func testRotateArcPreservesRadiusAndSpanAndMovesEndpoints() {
        let id = UUID()
        let center = SIMD2(1.0, 0.0)
        let pivot = SIMD2(0.5, -0.5)
        let angle = 0.7
        let arc = SketchEntity.arc(id: id, center: center, radius: 2, startAngle: 0.3, endAngle: 1.4)

        let rotated = SketchTransform.rotate(entities: [arc], about: pivot, angle: angle)

        guard case let .arc(newID, newCenter, radius, start, end) = rotated[0] else {
            return XCTFail("Expected an arc, got \(rotated[0])")
        }
        XCTAssertEqual(newID, id)
        XCTAssertEqual(radius, 2, accuracy: 1e-12, "Rotation preserves radius")
        XCTAssertEqual(
            SketchEntity.arcSweep(startAngle: start, endAngle: end),
            SketchEntity.arcSweep(startAngle: 0.3, endAngle: 1.4),
            accuracy: 1e-9, "Rotation preserves sweep"
        )

        func rotatedPoint(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let d = p - pivot
            return pivot + SIMD2(d.x * cos(angle) - d.y * sin(angle),
                                 d.x * sin(angle) + d.y * cos(angle))
        }
        assertEqual(
            SketchEntity.arcPoint(center: newCenter, radius: radius, angle: start),
            rotatedPoint(SketchEntity.arcPoint(center: center, radius: 2, angle: 0.3)),
            "Arc start endpoint tracks the rigid rotation"
        )
        assertEqual(
            SketchEntity.arcPoint(center: newCenter, radius: radius, angle: end),
            rotatedPoint(SketchEntity.arcPoint(center: center, radius: 2, angle: 1.4)),
            "Arc end endpoint tracks the rigid rotation"
        )
    }

    // MARK: - Scale

    func testScaleRoundTripAndFactors() {
        let entities: [SketchEntity] = [
            .line(id: UUID(), a: SIMD2(1, 1), b: SIMD2(3, 2)),
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(2, 1)),
            .circle(id: UUID(), center: SIMD2(4, 0), radius: 1.5),
            .arc(id: UUID(), center: SIMD2(0, 4), radius: 2, startAngle: 0.5, endAngle: 1.5),
        ]
        let pivot = SIMD2(1.0, 1.0)

        let doubled = SketchTransform.scale(entities: entities, about: pivot, factor: 2)
        guard case let .circle(_, scaledCenter, scaledRadius) = doubled[2] else {
            return XCTFail("Expected a circle")
        }
        assertEqual(scaledCenter, SIMD2(7, -1))
        XCTAssertEqual(scaledRadius, 3, accuracy: 1e-12)
        guard case let .rect(_, lo, hi) = doubled[1] else {
            return XCTFail("Expected a rect")
        }
        assertEqual(lo, SIMD2(-1, -1))
        assertEqual(hi, SIMD2(3, 1))

        let back = SketchTransform.scale(entities: doubled, about: pivot, factor: 0.5)
        XCTAssertEqual(back, entities, "Scale by 2 then 0.5 about the same pivot is exact")
        XCTAssertEqual(doubled.map(\.id), entities.map(\.id), "Scale must preserve IDs")
    }

    // MARK: - Construction flag (spec §3.3)

    func testConstructionFlagRoundTripAndHelpers() throws {
        let lineID = UUID()
        var sketch = Sketch(
            plane: .ground,
            entities: [
                .line(id: lineID, a: SIMD2(0, 0), b: SIMD2(1, 0)),
                .circle(id: UUID(), center: .zero, radius: 1),
            ]
        )
        XCTAssertFalse(sketch.isConstruction(lineID))
        sketch.setConstruction(true, forEntityIDs: [lineID])
        XCTAssertTrue(sketch.isConstruction(lineID))
        XCTAssertEqual(sketch.regularEntities.count, 1)

        let data = try JSONEncoder().encode(sketch)
        let decoded = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertEqual(decoded.constructionEntityIDs, [lineID])

        sketch.setConstruction(false, forEntityIDs: [lineID])
        XCTAssertFalse(sketch.isConstruction(lineID))
        XCTAssertEqual(sketch.regularEntities.count, 2)
    }

    func testConstructionFlagDecodesLegacyJSONWithoutField() throws {
        let sketch = Sketch(
            plane: .ground,
            entities: [.circle(id: UUID(), center: SIMD2(1, 1), radius: 2)]
        )
        let data = try JSONEncoder().encode(sketch)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json.removeValue(forKey: "constructionEntityIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Sketch.self, from: legacyData)
        XCTAssertTrue(decoded.constructionEntityIDs.isEmpty,
                      "Pre-B9 documents decode with an empty construction set")
        XCTAssertEqual(decoded.entities, sketch.entities)
    }

    // MARK: - Projection (spec §1.13 v1)

    func testProjectBoxEdgesOntoGroundYieldsSquareProfile() {
        let body = makeBody(.box(width: 2, depth: 2, height: 2), at: SIMD3(3, 5, 0))

        let projected = ProjectionKit.project(body: body, onto: .ground)

        XCTAssertEqual(
            projected.count, 4,
            "Box edges flatten to 4 lines (verticals dropped, top/bottom rims merged)"
        )
        let sketch = Sketch(plane: .ground, entities: projected)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1, "Projected outline closes into one profile")
        if let profile = profiles.first {
            XCTAssertEqual(abs(profile.area), 4, accuracy: 1e-6,
                           "2x2 box projects to a 2x2 square")
            let centroid = profile.loop.reduce(SIMD2<Double>.zero, +) / Double(profile.loop.count)
            assertEqual(centroid, SIMD2(3, 0), accuracy: 1e-6,
                        "Body translation carries into the projection")
        }
    }

    func testProjectSilhouetteBoxIsSquareOutline() {
        let body = makeBody(.box(width: 2, depth: 2, height: 2), at: .zero)

        let outline = ProjectionKit.projectSilhouette(body: body, onto: .ground)

        XCTAssertEqual(outline.count, 4,
                       "Silhouette of a box seen top-down is its square outline")
        let sketch = Sketch(plane: .ground, entities: outline)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)
        if let profile = profiles.first {
            XCTAssertEqual(abs(profile.area), 4, accuracy: 1e-5)
        }
    }

    func testProjectCylinderSideViewYieldsRectOutlineEntities() {
        // Front plane (XY): cylinder rims project to two horizontal lines.
        let frontPlane = SketchPlane(
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)
        )
        let body = makeBody(.cylinder(radius: 1, height: 2), at: .zero)

        let projected = ProjectionKit.project(body: body, onto: frontPlane)

        XCTAssertEqual(projected.count, 2, "Each rim circle flattens to one merged line")
        var rimHeights: [Double] = []
        for entity in projected {
            guard case let .line(_, a, b) = entity else {
                return XCTFail("Expected lines, got \(entity)")
            }
            XCTAssertEqual(a.y, b.y, accuracy: 1e-5, "Rim lines are horizontal")
            XCTAssertEqual(simd_length(b - a), 2, accuracy: 1e-3, "Diameter-wide")
            rimHeights.append(a.y)
        }
        rimHeights.sort()
        XCTAssertEqual(rimHeights[0], 0, accuracy: 1e-4, "Base rim at y = 0")
        XCTAssertEqual(rimHeights[1], 2, accuracy: 1e-4, "Top rim at y = 2")
    }
}
