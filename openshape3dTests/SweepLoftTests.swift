//
//  SweepLoftTests.swift
//  openshape3dTests
//
//  KernelOps.sweep / KernelOps.loft / HelixKit: transported sweep sections,
//  mitred corners, loft resampling, helix spine generation.
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class SweepLoftTests: XCTestCase {

    /// XY sketch plane (normal +Z): plane-local coords equal world XY.
    private let xyPlane = SketchPlane(
        origin: .zero,
        xAxis: SIMD3(1, 0, 0),
        yAxis: SIMD3(0, 1, 0)
    )

    private func squareProfile(
        center: SIMD2<Double> = .zero, halfSize: Double
    ) -> Profile {
        let h = halfSize
        return Profile(
            loop: [
                center + SIMD2(-h, -h), center + SIMD2(h, -h),
                center + SIMD2(h, h), center + SIMD2(-h, h),
            ],
            kind: .polygonal,
            sourceEntityIDs: []
        )
    }

    private func circleProfile(
        center: SIMD2<Double>, radius: Double, segments: Int = 48
    ) -> Profile {
        let loop = (0..<segments).map { i -> SIMD2<Double> in
            let angle = Double(i) / Double(segments) * 2 * .pi
            return center + radius * SIMD2(cos(angle), sin(angle))
        }
        return Profile(
            loop: loop,
            kind: .circle(center: center, radius: radius),
            sourceEntityIDs: []
        )
    }

    /// Signed-tetrahedron volume of a closed mesh.
    private func volume(of mesh: Euclid.Mesh) -> Double {
        var sum = 0.0
        for polygon in mesh.triangulate().polygons {
            let v = polygon.vertices
            let p0 = SIMD3(v[0].position.x, v[0].position.y, v[0].position.z)
            let p1 = SIMD3(v[1].position.x, v[1].position.y, v[1].position.z)
            let p2 = SIMD3(v[2].position.x, v[2].position.y, v[2].position.z)
            sum += simd_dot(p0, simd_cross(p1, p2))
        }
        return abs(sum) / 6
    }

    // MARK: - Sweep

    func testSweepSquareAlongStraightLineMatchesExtrude() {
        // Unit square in [0, 1]² swept 2 up the plane normal == extrude(2).
        let profile = Profile(
            loop: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)],
            kind: .polygonal,
            sourceEntityIDs: []
        )
        let spine: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0, 0, 2)]
        let swept = KernelOps.sweep(profile: profile, in: xyPlane, alongPath: spine)
        let extruded = KernelOps.extrude(profile: profile, in: xyPlane, distance: 2)

        XCTAssertFalse(swept.polygons.isEmpty)
        XCTAssertTrue(swept.isWatertight)

        let s = swept.bounds, e = extruded.bounds
        XCTAssertEqual(s.min.x, e.min.x, accuracy: 1e-9)
        XCTAssertEqual(s.min.y, e.min.y, accuracy: 1e-9)
        XCTAssertEqual(s.min.z, e.min.z, accuracy: 1e-9)
        XCTAssertEqual(s.max.x, e.max.x, accuracy: 1e-9)
        XCTAssertEqual(s.max.y, e.max.y, accuracy: 1e-9)
        XCTAssertEqual(s.max.z, e.max.z, accuracy: 1e-9)
        XCTAssertEqual(volume(of: swept), 2, accuracy: 1e-9)
    }

    func testSweepAlongLShapedSpine() {
        // 0.5×0.5 square swept up 2 then right 2: the mitred corner makes
        // the solid the union of the two straight legs.
        let profile = squareProfile(halfSize: 0.25)
        let spine: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 2), SIMD3(2, 0, 2),
        ]
        let mesh = KernelOps.sweep(profile: profile, in: xyPlane, alongPath: spine)

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)

        let bounds = mesh.bounds
        XCTAssertEqual(bounds.min.x, -0.25, accuracy: 1e-9)
        XCTAssertEqual(bounds.min.y, -0.25, accuracy: 1e-9)
        XCTAssertEqual(bounds.min.z, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.x, 2, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.z, 2.25, accuracy: 1e-9)

        // Two 0.5×0.5 boxes of centreline length 2.25 minus the shared
        // 0.5³ corner cube.
        XCTAssertEqual(volume(of: mesh), 1.0, accuracy: 1e-9)
    }

    func testSweepWithHoleCarvesTube() {
        // Square ring swept along a straight spine -> square tube.
        let outer = squareProfile(halfSize: 0.5)
        let hole = squareProfile(halfSize: 0.25)
        let spine: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0, 0, 1)]
        let mesh = KernelOps.sweep(
            profile: outer, holes: [hole], in: xyPlane, alongPath: spine
        )

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)
        // 1×1×1 minus the 0.5×0.5×1 core.
        XCTAssertEqual(volume(of: mesh), 0.75, accuracy: 1e-6)
    }

    // MARK: - Loft

    func testLoftSquareToSmallerSquareMakesFrustum() {
        let bottom = squareProfile(halfSize: 0.5) // area 1 at z = 0
        let top = squareProfile(halfSize: 0.25) // area 0.25 at z = 1
        let topPlane = SketchPlane(
            origin: SIMD3(0, 0, 1),
            xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0)
        )
        let mesh = KernelOps.loft(profiles: [
            (profile: bottom, holes: [], plane: xyPlane),
            (profile: top, holes: [], plane: topPlane),
        ])

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)

        let bounds = mesh.bounds
        XCTAssertEqual(bounds.min.z, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.z, 1, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.x, 0.5, accuracy: 1e-9)

        // Frustum volume h/3·(A1 + A2 + √(A1·A2)) = 7/12, strictly between
        // the two prism volumes.
        let v = volume(of: mesh)
        XCTAssertGreaterThan(v, 0.25)
        XCTAssertLessThan(v, 1.0)
        XCTAssertEqual(v, 7.0 / 12.0, accuracy: 1e-9)
    }

    func testLoftSquareToCircleIsWatertight() {
        // 4-point square resampled against a 48-point circle.
        let bottom = squareProfile(halfSize: 1)
        let top = circleProfile(center: .zero, radius: 0.8)
        let topPlane = SketchPlane(
            origin: SIMD3(0, 0, 1),
            xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0)
        )
        let mesh = KernelOps.loft(profiles: [
            (profile: bottom, holes: [], plane: xyPlane),
            (profile: top, holes: [], plane: topPlane),
        ])

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)

        let bounds = mesh.bounds
        // Square corners survive the resampling (48 is a multiple of 4).
        XCTAssertEqual(bounds.min.x, -1, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.x, 1, accuracy: 1e-9)
        XCTAssertEqual(bounds.min.z, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.z, 1, accuracy: 1e-9)

        // Between the inscribed prisms of the two sections.
        let v = volume(of: mesh)
        XCTAssertGreaterThan(v, .pi * 0.8 * 0.8 * 0.95) // > circle prism
        XCTAssertLessThan(v, 4.0) // < square prism
    }

    // MARK: - Helix

    func testHelixPointCountPitchAndRadius() {
        let path = HelixKit.path(
            radius: 2, pitch: 1, turns: 2, in: xyPlane, segmentsPerTurn: 48
        )
        XCTAssertEqual(path.count, 97) // 2 × 48 segments + 1

        // Starts on the plane at angle 0, ends after 2 turns at height 2.
        XCTAssertEqual(path[0].x, 2, accuracy: 1e-12)
        XCTAssertEqual(path[0].y, 0, accuracy: 1e-12)
        XCTAssertEqual(path[0].z, 0, accuracy: 1e-12)
        XCTAssertEqual(path[96].x, 2, accuracy: 1e-9)
        XCTAssertEqual(path[96].y, 0, accuracy: 1e-9)
        XCTAssertEqual(path[96].z, 2, accuracy: 1e-9)

        for (i, p) in path.enumerated() {
            // Constant radius about the plane normal through the origin.
            let radial = (p.x * p.x + p.y * p.y).squareRoot()
            XCTAssertEqual(radial, 2, accuracy: 1e-9)
            // Height climbs pitch per turn.
            XCTAssertEqual(p.z, Double(i) / 48.0, accuracy: 1e-9)
        }

        // Counter-clockwise by default (as seen down +normal); clockwise
        // flips the coil direction.
        XCTAssertGreaterThan(path[1].y, 0)
        let cw = HelixKit.path(
            radius: 2, pitch: 1, turns: 2, clockwise: true, in: xyPlane,
            segmentsPerTurn: 48
        )
        XCTAssertEqual(cw.count, 97)
        XCTAssertLessThan(cw[1].y, 0)
    }

    func testHelixFractionalTurnsEndsAtExactHeight() {
        let path = HelixKit.path(
            radius: 1, pitch: 4, turns: 1.5, in: xyPlane, segmentsPerTurn: 48
        )
        XCTAssertEqual(path.count, 73) // ceil(1.5 × 48) + 1
        // 1.5 turns from angle 0 ends at angle π: (-1, 0), height 6.
        let last = path[path.count - 1]
        XCTAssertEqual(last.x, -1, accuracy: 1e-9)
        XCTAssertEqual(last.y, 0, accuracy: 1e-9)
        XCTAssertEqual(last.z, 6, accuracy: 1e-9)
    }

    // MARK: - Sweep along helix

    func testSweepCircleAlongHelixMakesThread() {
        // Small circular profile at the helix start, swept two coils.
        let spine = HelixKit.path(
            radius: 2, pitch: 1, turns: 2, in: xyPlane, segmentsPerTurn: 48
        )
        let profile = circleProfile(
            center: SIMD2(2, 0), radius: 0.2, segments: 16
        )
        let mesh = KernelOps.sweep(profile: profile, in: xyPlane, alongPath: spine)

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)

        // Bounded by helix radius + profile radius (tiny mitre slack) and
        // the coil height span.
        let bounds = mesh.bounds
        XCTAssertGreaterThan(bounds.min.x, -2.3)
        XCTAssertLessThan(bounds.max.x, 2.3)
        XCTAssertGreaterThan(bounds.min.y, -2.3)
        XCTAssertLessThan(bounds.max.y, 2.3)
        XCTAssertGreaterThan(bounds.min.z, -0.3)
        XCTAssertLessThan(bounds.max.z, 2.3)

        // Hollow core: nothing near the helix axis.
        let minRadial = mesh.polygons
            .flatMap(\.vertices)
            .map { ($0.position.x * $0.position.x + $0.position.y * $0.position.y).squareRoot() }
            .min() ?? 0
        XCTAssertGreaterThan(minRadial, 1.5)
    }
}
