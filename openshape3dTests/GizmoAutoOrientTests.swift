//
//  GizmoAutoOrientTests.swift
//  openshape3dTests
//
//  Move/Rotate Auto-Orient (spec §5.1): the gizmo can carry its own frame —
//  a turned body's axes, a face's edge and normal — and its hit test and
//  drags then run along those axes instead of the world's.
//

import XCTest
import simd
@testable import openshape3d

final class GizmoAutoOrientTests: XCTestCase {

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), 1e-5, "\(a) vs \(b) \(message)", file: file, line: line)
    }

    /// Turned 90° about world Y: gizmo X points along world −Z.
    private let turned = GizmoBasis.rotation(simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0)))

    func testFramesAreRightHandedAndOrthonormal() throws {
        let frame = try XCTUnwrap(GizmoBasis.frame(z: SIMD3(0, 0, 2), x: SIMD3(1, 0, 0.5)))
        assertClose(frame.z, SIMD3(0, 0, 1))
        assertClose(frame.x, SIMD3(1, 0, 0), "x is made perpendicular to z")
        assertClose(simd_cross(frame.x, frame.y), frame.z)
        XCTAssertNil(GizmoBasis.frame(z: SIMD3(0, 0, 1), x: SIMD3(0, 0, 3)), "parallel directions")

        assertClose(turned.x, SIMD3(0, 0, -1))
        assertClose(turned.z, SIMD3(1, 0, 0))
        assertClose(turned.y, SIMD3(0, 1, 0))
        XCTAssertTrue(GizmoBasis.world.isWorld)
        XCTAssertFalse(turned.isWorld)
        assertClose(turned.local(turned.world(SIMD3(1, 2, 3))), SIMD3(1, 2, 3))
    }

    func testHitTestFollowsTheFrame() {
        let gizmo = GizmoState(origin: SIMD3(10, 0, 0), scale: 2, highlighted: nil, basis: turned)
        // Near the X arrow's tip (clear of the rings): origin + (0, 0, −1) · 0.95 · scale.
        let target = gizmo.world(SIMD3(0.95, 0, 0))
        assertClose(target, SIMD3(10, 0, -1.9))
        let ray = Ray(origin: target + SIMD3(0, 50, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(GizmoGeometry.hitTest(ray: ray, gizmo: gizmo), .xAxis)
        // Where the world X arrow would be, the turned gizmo has its Z arrow.
        let worldX = Ray(origin: SIMD3(10 + 1.9, 50, 0), direction: SIMD3(0, -1, 0))
        XCTAssertEqual(GizmoGeometry.hitTest(ray: worldX, gizmo: gizmo), .zAxis)
    }

    func testArrowDragMovesAlongTheTurnedAxis() throws {
        let gizmo = GizmoState(origin: .zero, scale: 1, highlighted: nil, basis: turned)
        let start = Ray(origin: SIMD3(0, 10, -0.5), direction: SIMD3(0, -1, 0))
        let session = try XCTUnwrap(GizmoDragSession(part: .xAxis, gizmo: gizmo, ray: start))
        assertClose(session.axis, SIMD3(0, 0, -1))
        // The finger slides diagonally; only the turned X component counts.
        let moved = Ray(origin: SIMD3(3, 10, -4.5), direction: SIMD3(0, -1, 0))
        let delta = try XCTUnwrap(session.translationDelta(for: moved))
        assertClose(delta, SIMD3(0, 0, -4))
    }

    func testRingDragTurnsInTheTurnedPlane() throws {
        // A face frame tilted 90° about X: the Z ring now lies in the world XZ plane.
        let frame = try XCTUnwrap(GizmoBasis.frame(z: SIMD3(0, 1, 0), x: SIMD3(1, 0, 0)))
        let gizmo = GizmoState(origin: .zero, scale: 1, highlighted: nil, basis: frame)
        let down = SIMD3<Float>(0, -1, 0)
        let grab = Ray(origin: SIMD3(1, 5, 0), direction: down)
        var session = try XCTUnwrap(GizmoDragSession(part: .zRing, gizmo: gizmo, ray: grab))
        assertClose(session.axis, SIMD3(0, 1, 0))
        // A quarter turn in the frame's own XY plane (world X → frame Y).
        let quarter = Ray(origin: frame.y * 1 + SIMD3(0, 5, 0), direction: down)
        let angle = try XCTUnwrap(session.rotationDelta(for: quarter))
        XCTAssertEqual(angle, .pi / 2, accuracy: 1e-4)
    }

    func testWorldBasisIsUnchangedBehavior() throws {
        let gizmo = GizmoState(origin: .zero, scale: 1, highlighted: nil)
        XCTAssertEqual(gizmo.basis, .world)
        let start = Ray(origin: SIMD3(0.5, 10, 0), direction: SIMD3(0, -1, 0))
        let session = try XCTUnwrap(GizmoDragSession(part: .xAxis, gizmo: gizmo, ray: start))
        let delta = try XCTUnwrap(session.translationDelta(for: Ray(origin: SIMD3(2.5, 10, 7), direction: SIMD3(0, -1, 0))))
        assertClose(delta, SIMD3(2, 0, 0))
    }
}
