//
//  PatternTextTests.swift
//  openshape3dTests
//
//  Pattern math (spec §1.11 / §5.7) and text-to-sketch (spec §1.12).
//

import XCTest
import simd
@testable import openshape3d

final class PatternTextTests: XCTestCase {

    // MARK: - Linear pattern (3D)

    func testLinearPatternCountAndPositions() {
        let transforms = PatternKit.linearTransforms(
            direction: SIMD3(1, 0, 0), spacing: 2, count: 4
        )
        XCTAssertEqual(transforms.count, 4)
        XCTAssertEqual(transforms[0].translation, .zero, "First instance is the original")
        XCTAssertEqual(transforms[0].rotation.angle, 0, accuracy: 1e-12)
        for i in 0..<4 {
            XCTAssertEqual(transforms[i].translation.x, Double(i) * 2, accuracy: 1e-12)
            XCTAssertEqual(transforms[i].translation.y, 0, accuracy: 1e-12)
            XCTAssertEqual(transforms[i].translation.z, 0, accuracy: 1e-12)
        }
    }

    func testLinearPatternNormalizesDirection() {
        // Non-unit direction: spacing is still the center-to-center distance.
        let transforms = PatternKit.linearTransforms(
            direction: SIMD3(0, 5, 0), spacing: 3, count: 2
        )
        XCTAssertEqual(transforms.count, 2)
        XCTAssertEqual(transforms[1].translation.y, 3, accuracy: 1e-12)
    }

    func testTwoAxisGridCountAndPositions() {
        let transforms = PatternKit.linearTransforms(
            direction: SIMD3(1, 0, 0), spacing: 2, count: 3,
            secondDirection: SIMD3(0, 0, 1), secondSpacing: 5, secondCount: 2
        )
        XCTAssertEqual(transforms.count, 6, "3 × 2 grid")
        XCTAssertEqual(transforms[0].translation, .zero)

        // Every grid slot present exactly once.
        var expected = Set<String>()
        for j in 0..<2 {
            for i in 0..<3 {
                expected.insert("\(i * 2),0,\(j * 5)")
            }
        }
        let actual = Set(transforms.map { t in
            "\(Int(t.translation.x.rounded())),\(Int(t.translation.y.rounded())),\(Int(t.translation.z.rounded()))"
        })
        XCTAssertEqual(actual, expected)
    }

    func testThreeAxisGridCount() {
        let transforms = PatternKit.linearTransforms(
            direction: SIMD3(1, 0, 0), spacing: 1, count: 2,
            secondDirection: SIMD3(0, 1, 0), secondSpacing: 1, secondCount: 3,
            thirdDirection: SIMD3(0, 0, 1), thirdSpacing: 1, thirdCount: 4
        )
        XCTAssertEqual(transforms.count, 24)
        XCTAssertEqual(
            transforms.last!.translation, SIMD3(1, 2, 3),
            "Far corner of the 2×3×4 grid"
        )
    }

    // MARK: - Circular pattern (3D)

    func testCircularFullTurnPositionsOnCircle() {
        let center = SIMD3<Double>(0, 0, 0)
        let seed = SIMD3<Double>(1, 0, 0)
        let transforms = PatternKit.circularTransforms(
            center: center, axis: SIMD3(0, 1, 0), count: 6,
            totalAngle: 2 * .pi, rotateInstances: true
        )
        XCTAssertEqual(transforms.count, 6)
        XCTAssertEqual(transforms[0].translation, .zero, "First instance is the original")

        // Full turn / 6: instances every 60°, each landing on the unit circle.
        for (i, t) in transforms.enumerated() {
            let p = t.applying(to: seed)
            XCTAssertEqual(simd_length(p - center), 1, accuracy: 1e-9)
            XCTAssertEqual(p.y, 0, accuracy: 1e-9, "Stays in the plane normal to the axis")
            let angle = atan2(-p.z, p.x) // +Y axis rotation carries +X toward -Z
            let expected = Double(i) * .pi / 3
            let wrapped = (angle - expected).truncatingRemainder(dividingBy: 2 * .pi)
            XCTAssertEqual(
                min(abs(wrapped), 2 * .pi - abs(wrapped)), 0, accuracy: 1e-9,
                "Instance \(i) at \(expected) rad"
            )
        }
    }

    func testCircularRotatedInstanceRotationValues() {
        let transforms = PatternKit.circularTransforms(
            center: SIMD3(2, 0, 0), axis: SIMD3(0, 1, 0), count: 6,
            totalAngle: 2 * .pi, rotateInstances: true
        )
        for (i, t) in transforms.enumerated() {
            XCTAssertEqual(
                t.rotation.angle, Double(i) * .pi / 3, accuracy: 1e-9,
                "Rotated orientation spins with the pattern"
            )
        }
    }

    func testCircularUniformKeepsOrientation() {
        let center = SIMD3<Double>(0, 0, 0)
        let seed = SIMD3<Double>(1, 0, 0)
        let transforms = PatternKit.circularTransforms(
            center: center, axis: SIMD3(0, 1, 0), count: 4,
            totalAngle: 2 * .pi, rotateInstances: false, referencePoint: seed
        )
        for t in transforms {
            XCTAssertEqual(t.rotation.angle, 0, accuracy: 1e-12, "Uniform keeps orientation")
            let p = t.applying(to: seed)
            XCTAssertEqual(simd_length(p - center), 1, accuracy: 1e-9)
        }
    }

    func testCircularPartialAngleSpreadsFirstToLast() {
        // 90° over 3 instances: first→last is the total angle (45° spacing).
        let transforms = PatternKit.circularTransforms(
            center: .zero, axis: SIMD3(0, 0, 1), count: 3,
            totalAngle: .pi / 2, rotateInstances: true
        )
        XCTAssertEqual(transforms[1].rotation.angle, .pi / 4, accuracy: 1e-9)
        XCTAssertEqual(transforms[2].rotation.angle, .pi / 2, accuracy: 1e-9)
    }

    // MARK: - Sketch-space patterns

    func testLinearSketchTransforms() {
        let transforms = PatternKit.linearSketchTransforms(
            direction: SIMD2(0, 1), spacing: 4, count: 3
        )
        XCTAssertEqual(transforms.count, 3)
        XCTAssertEqual(transforms[0], .identity)
        XCTAssertEqual(transforms[2].apply(SIMD2(1, 1)), SIMD2(1, 9))
    }

    func testCircularSketchRotationOfRectEntity() {
        // Rotate a rect 90° CCW about the origin: it can't stay an
        // axis-aligned rect, so it explodes into four lines.
        let rect = SketchEntity.rect(id: UUID(), min: SIMD2(1, 0), max: SIMD2(2, 1))
        let transforms = PatternKit.circularSketchTransforms(
            center: .zero, count: 4, totalAngle: 2 * .pi, rotateInstances: true
        )
        XCTAssertEqual(transforms.count, 4)

        let copy = PatternKit.transformed(rect, by: transforms[1])
        XCTAssertEqual(copy.count, 4, "Rotated rect becomes four lines")

        // (1,0)→(0,1), (2,1)→(-1,2): collect all endpoints and check corners.
        var endpoints: [SIMD2<Double>] = []
        for entity in copy {
            guard case let .line(_, a, b) = entity else {
                return XCTFail("Expected line entities")
            }
            endpoints.append(a)
            endpoints.append(b)
        }
        let expectedCorners: [SIMD2<Double>] = [
            SIMD2(0, 1), SIMD2(0, 2), SIMD2(-1, 2), SIMD2(-1, 1),
        ]
        for corner in expectedCorners {
            XCTAssertTrue(
                endpoints.contains { simd_length($0 - corner) < 1e-9 },
                "Missing rotated corner \(corner)"
            )
        }

        // Identity instance keeps the rect an axis-aligned rect.
        let original = PatternKit.transformed(rect, by: transforms[0])
        XCTAssertEqual(original.count, 1)
        guard case .rect = original[0] else {
            return XCTFail("Identity transform should keep the rect entity")
        }
    }

    func testSketchRotationCarriesEntityRotationFields() {
        var t = SketchPatternTransform.identity
        t.rotation = .pi / 2

        let polygon = SketchEntity.polygon(
            id: UUID(), center: SIMD2(1, 0), radius: 2, sides: 6, rotation: 0.1
        )
        guard case let .polygon(_, center, radius, sides, rotation) =
                PatternKit.transformed(polygon, by: t)[0] else {
            return XCTFail("Polygon should stay a polygon")
        }
        XCTAssertEqual(sides, 6)
        XCTAssertEqual(radius, 2, accuracy: 1e-12)
        XCTAssertEqual(rotation, 0.1 + .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(simd_length(center - SIMD2(0, 1)), 0, accuracy: 1e-9)

        let ellipse = SketchEntity.ellipse(
            id: UUID(), center: .zero, radiusX: 3, radiusY: 1, rotation: 0.2
        )
        guard case let .ellipse(_, _, _, _, eRotation) =
                PatternKit.transformed(ellipse, by: t)[0] else {
            return XCTFail("Ellipse should stay an ellipse")
        }
        XCTAssertEqual(eRotation, 0.2 + .pi / 2, accuracy: 1e-12)
    }

    // MARK: - Text to sketch

    private func loopBounds(of entities: [SketchEntity]) -> (min: SIMD2<Double>, max: SIMD2<Double>) {
        var lo = SIMD2<Double>(.infinity, .infinity)
        var hi = SIMD2<Double>(-.infinity, -.infinity)
        for entity in entities {
            guard case let .line(_, a, b) = entity else { continue }
            lo = simd_min(lo, simd_min(a, b))
            hi = simd_max(hi, simd_max(a, b))
        }
        return (lo, hi)
    }

    func testTextIProducesClosedProfile() {
        let entities = TextSketch.glyphEntities(text: "I", height: 10)
        XCTAssertFalse(entities.isEmpty)
        for entity in entities {
            guard case .line = entity else {
                return XCTFail("Text should flatten to line entities")
            }
        }

        let sketch = Sketch(plane: .ground, entities: entities)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertGreaterThanOrEqual(profiles.count, 1, "The 'I' outline is a closed profile")
        XCTAssertGreaterThan(abs(profiles[0].area), 0)
    }

    func testTextOProducesNestedLoops() {
        let entities = TextSketch.glyphEntities(text: "O", height: 10)
        let sketch = Sketch(plane: .ground, entities: entities)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 2, "Outer outline plus counter hole")

        let outer = profiles.max { abs($0.area) < abs($1.area) }!
        let holes = ProfileDetector.holes(of: outer, among: profiles)
        XCTAssertEqual(holes.count, 1, "Counter loop nests inside the outline")
    }

    func testGlyphHeightMatchesRequested() {
        let height = 10.0
        let entities = TextSketch.glyphEntities(text: "I", height: height)
        let bounds = loopBounds(of: entities)
        let measured = bounds.max.y - bounds.min.y
        XCTAssertEqual(
            measured, height, accuracy: height * 0.1,
            "Cap height scaling puts 'I' within 10% of the requested height"
        )
    }

    func testTextAdvancesFromOrigin() {
        let origin = SIMD2<Double>(5, 3)
        let entities = TextSketch.glyphEntities(text: "II", height: 10, at: origin)
        let bounds = loopBounds(of: entities)
        XCTAssertGreaterThanOrEqual(bounds.min.x, origin.x - 1e-9, "Layout starts at origin")
        XCTAssertGreaterThanOrEqual(bounds.min.y, origin.y - 1e-9, "Baseline sits at origin")

        // Two glyphs → two separate closed profiles, advanced apart.
        let sketch = Sketch(plane: .ground, entities: entities)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertNotEqual(
            profiles[0].centroid.x, profiles[1].centroid.x, accuracy: 0.5,
            "Second glyph advances along the baseline"
        )
    }
}
