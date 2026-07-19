//
//  RevolveTests.swift
//  openshape3dTests
//
//  KernelOps.revolve: lathe mapping, partial-angle wedges, axis validation.
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class RevolveTests: XCTestCase {

    /// XY sketch plane (normal +Z) so plane-local coords equal world XY; the
    /// sketch y axis maps to world Y.
    private let xyPlane = SketchPlane(
        origin: .zero,
        xAxis: SIMD3(1, 0, 0),
        yAxis: SIMD3(0, 1, 0)
    )

    /// Axis of revolution = the sketch's y axis through the origin.
    private let yAxis = RevolveAxis(point: .zero, direction: SIMD2(0, 1))

    private func rectProfile(
        x0: Double, x1: Double, y0: Double, y1: Double
    ) -> Profile {
        // CCW when x1 > x0, y1 > y0.
        Profile(
            loop: [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)],
            kind: .polygonal,
            sourceEntityIDs: []
        )
    }

    private func aabb(of mesh: Euclid.Mesh) -> (min: Vector, max: Vector) {
        let bounds = mesh.bounds
        return (bounds.min, bounds.max)
    }

    // MARK: - Full revolve

    func testRectangleOffsetFromAxisMakesRing() {
        // x in [1, 2], y in [0, 0.5] about the y axis -> washer: outer radius
        // 2, inner radius 1, height 0.5.
        let profile = rectProfile(x0: 1, x1: 2, y0: 0, y1: 0.5)
        let mesh = KernelOps.revolve(profile: profile, in: xyPlane, axis: yAxis)

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)

        let (lo, hi) = aabb(of: mesh)
        XCTAssertEqual(lo.x, -2, accuracy: 1e-9)
        XCTAssertEqual(hi.x, 2, accuracy: 1e-9)
        XCTAssertEqual(lo.z, -2, accuracy: 1e-9)
        XCTAssertEqual(hi.z, 2, accuracy: 1e-9)
        XCTAssertEqual(lo.y, 0, accuracy: 1e-9)
        XCTAssertEqual(hi.y, 0.5, accuracy: 1e-9)

        // Hollow core: no vertex closer to the axis than the inner-wall chord.
        let minRadial = mesh.polygons
            .flatMap(\.vertices)
            .map { ($0.position.x * $0.position.x + $0.position.z * $0.position.z).squareRoot() }
            .min() ?? 0
        XCTAssertGreaterThan(minRadial, 0.99)
    }

    func testMirroredProfileRevolvesSameRing() {
        // Same rectangle on the -x side of the axis: mirrored into lathe space.
        let profile = rectProfile(x0: -2, x1: -1, y0: 0, y1: 0.5)
        let mesh = KernelOps.revolve(profile: profile, in: xyPlane, axis: yAxis)

        XCTAssertTrue(mesh.isWatertight)
        let (lo, hi) = aabb(of: mesh)
        XCTAssertEqual(lo.x, -2, accuracy: 1e-9)
        XCTAssertEqual(hi.x, 2, accuracy: 1e-9)
        XCTAssertEqual(lo.y, 0, accuracy: 1e-9)
        XCTAssertEqual(hi.y, 0.5, accuracy: 1e-9)
    }

    func testSemicircleMakesSphere() {
        // Semicircle radius 1 on the +x side (flat edge on the axis) -> sphere.
        let segments = 24
        let loop = (0...segments).map { i -> SIMD2<Double> in
            let angle = -Double.pi / 2 + Double(i) / Double(segments) * .pi
            return SIMD2(cos(angle), sin(angle))
        }
        let profile = Profile(loop: loop, kind: .polygonal, sourceEntityIDs: [])
        let mesh = KernelOps.revolve(profile: profile, in: xyPlane, axis: yAxis)

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)

        let (lo, hi) = aabb(of: mesh)
        XCTAssertEqual(lo.x, -1, accuracy: 1e-6)
        XCTAssertEqual(hi.x, 1, accuracy: 1e-6)
        XCTAssertEqual(lo.y, -1, accuracy: 1e-6)
        XCTAssertEqual(hi.y, 1, accuracy: 1e-6)
        XCTAssertEqual(lo.z, -1, accuracy: 1e-6)
        XCTAssertEqual(hi.z, 1, accuracy: 1e-6)
    }

    // MARK: - Partial angle

    func testQuarterRevolveStaysInQuadrant() {
        // 90 degrees sweeps from +x toward -z (Euclid lathe direction):
        // x in [0, 2], z in [-2, 0].
        let profile = rectProfile(x0: 1, x1: 2, y0: 0, y1: 0.5)
        let mesh = KernelOps.revolve(
            profile: profile, in: xyPlane, axis: yAxis, angle: 90
        )

        XCTAssertFalse(mesh.polygons.isEmpty)
        XCTAssertTrue(mesh.isWatertight)

        let (lo, hi) = aabb(of: mesh)
        XCTAssertEqual(hi.x, 2, accuracy: 1e-6)
        XCTAssertEqual(lo.x, 0, accuracy: 1e-6)
        XCTAssertEqual(hi.z, 0, accuracy: 1e-6)
        XCTAssertEqual(lo.z, -2, accuracy: 1e-6)
        XCTAssertEqual(lo.y, 0, accuracy: 1e-6)
        XCTAssertEqual(hi.y, 0.5, accuracy: 1e-6)
    }

    func testReflexRevolveCoversThreeQuadrants() {
        // 270 degrees removes only the quadrant x >= 0, z >= 0; the AABB still
        // spans the full ring extents.
        let profile = rectProfile(x0: 1, x1: 2, y0: 0, y1: 0.5)
        let mesh = KernelOps.revolve(
            profile: profile, in: xyPlane, axis: yAxis, angle: 270
        )

        XCTAssertTrue(mesh.isWatertight)
        let (lo, hi) = aabb(of: mesh)
        XCTAssertEqual(lo.x, -2, accuracy: 1e-6)
        XCTAssertEqual(hi.x, 2, accuracy: 1e-6)
        XCTAssertEqual(lo.z, -2, accuracy: 1e-6)
        XCTAssertEqual(hi.z, 2, accuracy: 1e-6)

        // Nothing survives in the removed open quadrant (away from the cut
        // planes themselves).
        let intruder = mesh.polygons.flatMap(\.vertices).first {
            $0.position.x > 1e-6 && $0.position.z > 1e-6
        }
        XCTAssertNil(intruder)
    }

    // MARK: - Holes

    func testHoleSubtractsRevolvedTool() {
        // Outer rect x in [1, 3], hole rect x in [1.5, 2.5] (strictly inside):
        // the ring gains an internal square-channel void; outer AABB unchanged.
        let profile = rectProfile(x0: 1, x1: 3, y0: 0, y1: 1)
        let hole = rectProfile(x0: 1.5, x1: 2.5, y0: 0.25, y1: 0.75)
        let solid = KernelOps.revolve(profile: profile, in: xyPlane, axis: yAxis)
        let mesh = KernelOps.revolve(
            profile: profile, holes: [hole], in: xyPlane, axis: yAxis
        )

        XCTAssertTrue(mesh.isWatertight)
        let (lo, hi) = aabb(of: mesh)
        XCTAssertEqual(lo.x, -3, accuracy: 1e-9)
        XCTAssertEqual(hi.x, 3, accuracy: 1e-9)
        XCTAssertEqual(hi.y, 1, accuracy: 1e-9)
        // The hole carves volume: strictly more surface than the plain ring.
        XCTAssertGreaterThan(mesh.polygons.count, solid.polygons.count)
    }

    // MARK: - Validation

    func testAxisCrossingProfileReturnsEmpty() {
        let profile = rectProfile(x0: -1, x1: 1, y0: 0, y1: 0.5)
        let mesh = KernelOps.revolve(profile: profile, in: xyPlane, axis: yAxis)
        XCTAssertTrue(mesh.polygons.isEmpty)
    }

    func testZeroAngleReturnsEmpty() {
        let profile = rectProfile(x0: 1, x1: 2, y0: 0, y1: 0.5)
        let mesh = KernelOps.revolve(
            profile: profile, in: xyPlane, axis: yAxis, angle: 0
        )
        XCTAssertTrue(mesh.polygons.isEmpty)
    }

    // MARK: - Plane / axis mapping

    func testGroundPlaneOffsetAxisMapsToWorld() {
        // Ground plane: sketch x -> world X, sketch y -> world -Z. Axis is the
        // vertical sketch line x = 3, so the solid revolves about the world
        // line (x=3, z=*) ... axis direction (0,1) -> world -Z. Rectangle
        // x in [4, 5] sits 1..2 from the axis; y in [0, 2] spans world
        // z in [-2, 0].
        let profile = rectProfile(x0: 4, x1: 5, y0: 0, y1: 2)
        let axis = RevolveAxis(point: SIMD2(3, 0), direction: SIMD2(0, 1))
        let mesh = KernelOps.revolve(profile: profile, in: .ground, axis: axis)

        XCTAssertTrue(mesh.isWatertight)
        let (lo, hi) = aabb(of: mesh)
        // Radial extents (radius 2 about world x=3, y=0) in the XY plane.
        XCTAssertEqual(lo.x, 1, accuracy: 1e-9)
        XCTAssertEqual(hi.x, 5, accuracy: 1e-9)
        XCTAssertEqual(lo.y, -2, accuracy: 1e-9)
        XCTAssertEqual(hi.y, 2, accuracy: 1e-9)
        // Along the axis: world Z from -2 to 0.
        XCTAssertEqual(lo.z, -2, accuracy: 1e-9)
        XCTAssertEqual(hi.z, 0, accuracy: 1e-9)
    }
}
