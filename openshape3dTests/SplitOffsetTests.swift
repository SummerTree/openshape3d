//
//  SplitOffsetTests.swift
//  openshape3dTests
//
//  SplitKit plane/profile body splitting and SketchOffset entity offsetting.
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class SplitOffsetTests: XCTestCase {

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh))
    }

    /// 2×2×2 box spanning x, z in [-1, 1] and y in [0, 2]; volume 8.
    private var box: Euclid.Mesh {
        Euclid.Mesh.cube(center: Vector(0, 1, 0), size: Vector(2, 2, 2))
    }

    // MARK: - Split by plane

    func testPlaneSplitBoxYieldsComplementaryWatertightHalves() {
        // Split at y = 0.8: kept (+normal = +Y) is 2×2×1.2, other is 2×2×0.8.
        let (kept, other) = KernelOps.split(body: box, byPlane: .offsetGround(y: 0.8))

        XCTAssertFalse(kept.polygons.isEmpty)
        XCTAssertFalse(other.polygons.isEmpty)
        XCTAssertTrue(kept.isWatertight)
        XCTAssertTrue(other.isWatertight)

        XCTAssertEqual(kept.bounds.min.y, 0.8, accuracy: 1e-6)
        XCTAssertEqual(kept.bounds.max.y, 2.0, accuracy: 1e-6)
        XCTAssertEqual(other.bounds.min.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(other.bounds.max.y, 0.8, accuracy: 1e-6)

        XCTAssertEqual(volume(kept), 4.8, accuracy: 0.048)
        XCTAssertEqual(volume(other), 3.2, accuracy: 0.032)
        // Split removes no material: halves sum to the original within 1%.
        XCTAssertEqual(volume(kept) + volume(other), 8, accuracy: 0.08)
    }

    func testPlaneMissingBodyLeavesWholeBodyOnOneSide() {
        let (kept, other) = KernelOps.split(body: box, byPlane: .offsetGround(y: 5))
        XCTAssertTrue(kept.polygons.isEmpty)
        XCTAssertTrue(other.isWatertight)
        XCTAssertEqual(volume(other), 8, accuracy: 0.08)
    }

    // MARK: - Split by profile

    func testProfileSplitBoxIntoCylinderAndRemainder() {
        // Circle r = 0.5 at the ground-plane origin, extruded through the box:
        // inside is a through-cylinder (≈ π·r²·h), outside the drilled rest.
        let segments = 48
        let radius = 0.5
        let loop = (0..<segments).map { i -> SIMD2<Double> in
            let angle = Double(i) / Double(segments) * 2 * .pi
            return SIMD2(cos(angle), sin(angle)) * radius
        }
        let profile = Profile(
            loop: loop,
            kind: .circle(center: .zero, radius: radius),
            sourceEntityIDs: []
        )
        let (inside, outside) = KernelOps.split(body: box, byProfile: profile, in: .ground)

        XCTAssertFalse(inside.polygons.isEmpty)
        XCTAssertFalse(outside.polygons.isEmpty)
        XCTAssertTrue(inside.isWatertight)
        XCTAssertTrue(outside.isWatertight)

        // Cylinder spans the box's full height.
        XCTAssertEqual(inside.bounds.min.y, 0, accuracy: 1e-6)
        XCTAssertEqual(inside.bounds.max.y, 2, accuracy: 1e-6)
        XCTAssertEqual(volume(inside), .pi * radius * radius * 2, accuracy: 0.02)
        XCTAssertEqual(volume(inside) + volume(outside), 8, accuracy: 0.08)
    }

    // MARK: - Offset: closed primitives

    func testCircleOffsetAdjustsRadius() {
        let circle = SketchEntity.circle(id: UUID(), center: SIMD2(1, 2), radius: 1)

        let grown = SketchOffset.offset(entities: [circle], by: 0.25)
        guard case let .circle(_, center, radius) = grown.first else {
            return XCTFail("Expected a circle, got \(grown)")
        }
        XCTAssertEqual(grown.count, 1)
        XCTAssertEqual(center, SIMD2(1, 2))
        XCTAssertEqual(radius, 1.25, accuracy: 1e-12)

        let shrunk = SketchOffset.offset(entities: [circle], by: -0.25)
        guard case let .circle(_, _, small) = shrunk.first else {
            return XCTFail("Expected a circle, got \(shrunk)")
        }
        XCTAssertEqual(small, 0.75, accuracy: 1e-12)

        // Shrinking past the center collapses the circle entirely.
        XCTAssertTrue(SketchOffset.offset(entities: [circle], by: -1.5).isEmpty)
    }

    func testArcOffsetKeepsCenterAndAngles() {
        let arc = SketchEntity.arc(
            id: UUID(), center: SIMD2(3, -1), radius: 2,
            startAngle: 0.25, endAngle: 1.75
        )
        let offset = SketchOffset.offset(entities: [arc], by: 0.5)
        guard case let .arc(_, center, radius, start, end) = offset.first else {
            return XCTFail("Expected an arc, got \(offset)")
        }
        XCTAssertEqual(offset.count, 1)
        XCTAssertEqual(center, SIMD2(3, -1))
        XCTAssertEqual(radius, 2.5, accuracy: 1e-12)
        XCTAssertEqual(start, 0.25, accuracy: 1e-12)
        XCTAssertEqual(end, 1.75, accuracy: 1e-12)
    }

    func testRectGrowShrinkAndDegenerateCollapse() {
        let rect = SketchEntity.rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(4, 2))

        let grown = SketchOffset.offset(entities: [rect], by: 0.5)
        guard case let .rect(_, lo, hi) = grown.first else {
            return XCTFail("Expected a rect, got \(grown)")
        }
        XCTAssertEqual(lo, SIMD2(-0.5, -0.5))
        XCTAssertEqual(hi, SIMD2(4.5, 2.5))

        let shrunk = SketchOffset.offset(entities: [rect], by: -0.9)
        guard case let .rect(_, slo, shi) = shrunk.first else {
            return XCTFail("Expected a rect, got \(shrunk)")
        }
        XCTAssertEqual(slo.x, 0.9, accuracy: 1e-12)
        XCTAssertEqual(slo.y, 0.9, accuracy: 1e-12)
        XCTAssertEqual(shi.x, 3.1, accuracy: 1e-12)
        XCTAssertEqual(shi.y, 1.1, accuracy: 1e-12)

        // Shrinking past the short midline collapses the rect.
        XCTAssertTrue(SketchOffset.offset(entities: [rect], by: -1.5).isEmpty)
    }

    func testPolygonOffsetMovesEdgesByDistance() {
        let hexagon = SketchEntity.polygon(
            id: UUID(), center: SIMD2(0, 0), radius: 1, sides: 6, rotation: 0
        )
        let offset = SketchOffset.offset(entities: [hexagon], by: 0.5)
        guard case let .polygon(_, _, radius, sides, _) = offset.first else {
            return XCTFail("Expected a polygon, got \(offset)")
        }
        XCTAssertEqual(sides, 6)
        // Apothem (edge distance) grows by exactly the offset distance.
        let apothem = radius * cos(.pi / 6)
        XCTAssertEqual(apothem, cos(.pi / 6) + 0.5, accuracy: 1e-12)
    }

    // MARK: - Offset: line chains and loops

    func testOpenChainOffsetsLeftOfTravel() {
        let line = SketchEntity.line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(2, 0))
        let offset = SketchOffset.offset(entities: [line], by: 0.5)
        guard case let .line(_, a, b) = offset.first else {
            return XCTFail("Expected a line, got \(offset)")
        }
        XCTAssertEqual(offset.count, 1)
        // Travel +X: left is +Y.
        XCTAssertEqual(a.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(b.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(a.x, 0, accuracy: 1e-12)
        XCTAssertEqual(b.x, 2, accuracy: 1e-12)
    }

    /// L outline: horizontal arm 5×1, vertical arm 2×4 (CCW, area 11).
    private var lLoop: [SketchEntity] {
        let corners: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(5, 0), SIMD2(5, 1),
            SIMD2(2, 1), SIMD2(2, 4), SIMD2(0, 4),
        ]
        return corners.indices.map { i in
            .line(id: UUID(), a: corners[i], b: corners[(i + 1) % corners.count])
        }
    }

    func testLLoopInwardOffsetCollapsesThinArmToSimpleLoop() {
        // Inward 0.6 exceeds half the horizontal arm's height (1): that arm
        // collapses and only the 0.8 × 2.8 band of the vertical arm survives.
        let offset = SketchOffset.offset(entities: lLoop, by: -0.6)
        XCTAssertFalse(offset.isEmpty)

        let sketch = Sketch(plane: .worldXY, entities: offset)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)

        guard let profile = profiles.first else { return }
        XCTAssertEqual(abs(profile.area), 0.8 * 2.8, accuracy: 1e-9)
        let xs = profile.loop.map(\.x)
        let ys = profile.loop.map(\.y)
        XCTAssertEqual(xs.min() ?? .nan, 0.6, accuracy: 1e-9)
        XCTAssertEqual(xs.max() ?? .nan, 1.4, accuracy: 1e-9)
        XCTAssertEqual(ys.min() ?? .nan, 0.6, accuracy: 1e-9)
        XCTAssertEqual(ys.max() ?? .nan, 3.4, accuracy: 1e-9)
    }

    func testLLoopOutwardOffsetStaysSimple() {
        let offset = SketchOffset.offset(entities: lLoop, by: 0.5)
        XCTAssertEqual(offset.count, 6)

        let sketch = Sketch(plane: .worldXY, entities: offset)
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)
        // Mitred outward hexagon: 6×5 bounding box minus the 3×3 notch.
        XCTAssertEqual(abs(profiles.first?.area ?? 0), 21, accuracy: 1e-9)
    }

    func testLoopFullyCollapsedByLargeInwardOffsetReturnsNothing() {
        // Inward 3 swallows both arms entirely.
        XCTAssertTrue(SketchOffset.offset(entities: lLoop, by: -3).isEmpty)
    }
}
