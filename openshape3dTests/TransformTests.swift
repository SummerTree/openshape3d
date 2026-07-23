//
//  TransformTests.swift
//  openshape3dTests
//
//  Phase A6: mirror kernel op and rotation-ring gizmo math.
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class TransformTests: XCTestCase {

    // MARK: - Mirror

    func testMirroredBoxAABBIsReflected() {
        // Box spanning x ∈ [1, 3], y ∈ [0, 2], z ∈ [-1, 1].
        let box = Euclid.Mesh.cube(center: Vector(2, 1, 0), size: Vector(2, 2, 2))
        let mirrored = KernelOps.mirror(mesh: box, across: .worldYZ)

        let bounds = mirrored.bounds
        XCTAssertEqual(bounds.min.x, -3, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.x, -1, accuracy: 1e-9)
        // Off-normal extents are unchanged.
        XCTAssertEqual(bounds.min.y, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.y, 2, accuracy: 1e-9)
        XCTAssertEqual(bounds.min.z, -1, accuracy: 1e-9)
        XCTAssertEqual(bounds.max.z, 1, accuracy: 1e-9)
    }

    func testMirroredMeshIsWatertight() {
        let cylinder = Euclid.Mesh.cylinder(radius: 1, height: 2, slices: 24)
            .translated(by: Vector(0.5, 1, 3))
        let mirrored = KernelOps.mirror(mesh: cylinder, across: .worldXY)

        XCTAssertFalse(mirrored.polygons.isEmpty)
        XCTAssertTrue(mirrored.isWatertight, "Mirrored mesh should stay watertight")
        // Reflected across z = 0: the solid lands on the other side.
        XCTAssertEqual(mirrored.bounds.max.z, -2, accuracy: 1e-9)
        XCTAssertEqual(mirrored.bounds.min.z, -4, accuracy: 1e-9)
    }

    func testMirrorAcrossOffsetPlanePreservesDistance() {
        // Plane y = 2; a unit cube centered at y = 0.5 reflects to y ∈ [3, 4].
        let plane = SketchPlane(
            origin: SIMD3(0, 2, 0), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1)
        )
        let cube = Euclid.Mesh.cube(center: Vector(0, 0.5, 0), size: Vector(1, 1, 1))
        let mirrored = KernelOps.mirror(mesh: cube, across: plane)

        XCTAssertEqual(mirrored.bounds.min.y, 3, accuracy: 1e-9)
        XCTAssertEqual(mirrored.bounds.max.y, 4, accuracy: 1e-9)
        XCTAssertTrue(mirrored.isWatertight)
    }

    // MARK: - Rotation ring math

    func testRingHitTestAndQuarterTurnDelta() throws {
        let gizmo = GizmoState(origin: .zero, scale: 1, highlighted: nil)
        let r = GizmoGeometry.ringRadius
        // Looking down -Z at the Z ring, anchored at its 45° point (off the
        // axes, so no arrow can claim the hit).
        let d = r / sqrt(2)
        let anchorRay = Ray(origin: SIMD3(d, d, 10), direction: SIMD3(0, 0, -1))
        XCTAssertEqual(GizmoGeometry.hitTest(ray: anchorRay, gizmo: gizmo), .zRing)

        let session = try XCTUnwrap(
            GizmoDragSession(part: .zRing, gizmo: gizmo, ray: anchorRay)
        )
        // Ray over the 135° point: a quarter turn about +Z.
        let quarterRay = Ray(origin: SIMD3(-d, d, 10), direction: SIMD3(0, 0, -1))
        let delta = try XCTUnwrap(session.rotationDelta(for: quarterRay))
        XCTAssertEqual(delta, .pi / 2, accuracy: 1e-4)

        // The reverse direction is a negative quarter turn.
        let backRay = Ray(origin: SIMD3(d, -d, 10), direction: SIMD3(0, 0, -1))
        let back = try XCTUnwrap(session.rotationDelta(for: backRay))
        XCTAssertEqual(back, -.pi / 2, accuracy: 1e-4)

        // Ring drags have no translation component.
        XCTAssertNil(session.translationDelta(for: quarterRay))
    }

    /// The rotation handle must be a GENEROUS grab target — the reported bug
    /// was that it was too small to grab. A tap a good bit off the exact ring
    /// radius still lands the ring.
    func testRotationHandleHasAForgivingGrabBand() throws {
        let gizmo = GizmoState(origin: .zero, scale: 1, highlighted: nil)
        let r = GizmoGeometry.ringRadius
        // Off the axes (45°) so no arrow competes, and OUTSIDE the true radius
        // by most of the tolerance (the outer band never overlaps the plane
        // tiles) — a sloppy grab still lands the rotation.
        let outer = (r + GizmoGeometry.ringHitWidth * 0.8) / sqrt(2)
        let ray = Ray(origin: SIMD3(outer, outer, 10), direction: SIMD3(0, 0, -1))
        XCTAssertEqual(GizmoGeometry.hitTest(ray: ray, gizmo: gizmo), .zRing,
                       "a tap off the exact ring radius still rotates")

        // …and the band is meaningfully wide (the fix), not a hairline.
        XCTAssertGreaterThanOrEqual(GizmoGeometry.ringHitWidth, 0.2,
                                    "the rotation grab band must stay generous")
    }

    func testArrowsStillWinOverRings() {
        // Regression: a ray down the middle of the Y arrow shaft must keep
        // hitting the arrow, not a ring.
        let gizmo = GizmoState(origin: .zero, scale: 1, highlighted: nil)
        let ray = Ray(
            origin: SIMD3(0, 0.5, 10),
            direction: simd_normalize(SIMD3(0, 0, -1))
        )
        XCTAssertEqual(GizmoGeometry.hitTest(ray: ray, gizmo: gizmo), .yAxis)
    }

    func testQuarterTurnQuaternionRotatesAxes() {
        // The quaternion the ring drag applies: +90° about +Z maps +X to +Y.
        let q = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let rotated = q.act(SIMD3<Double>(1, 0, 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-12)
        XCTAssertEqual(rotated.y, 1, accuracy: 1e-12)
        XCTAssertEqual(rotated.z, 0, accuracy: 1e-12)
    }
}
