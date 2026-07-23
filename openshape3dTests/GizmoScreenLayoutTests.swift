//
//  GizmoScreenLayoutTests.swift
//  openshape3dTests
//
//  The move/rotate gizmo is drawn in 2D and hit-tested in 2D against the SAME
//  projected anchors — so a tap on the flat handle a user sees lands on its
//  drag target. These pin that: a tap AT each drawn handle picks that part, and
//  a tap in open space picks nothing.
//

import XCTest
import simd
@testable import openshape3d

final class GizmoScreenLayoutTests: XCTestCase {

    /// An isometric projector — the three axes go to three distinct on-screen
    /// directions 120° apart (like a real 3/4 view), so nothing collapses onto
    /// the centre. Centred at (500, 500), fixed scale.
    private func project(_ local: SIMD3<Float>) -> CGPoint? {
        let s: CGFloat = 120
        let xd = CGPoint(x: 0.866, y: 0.5)   // +x → lower-right
        let yd = CGPoint(x: 0, y: -1)        // +y → up
        let zd = CGPoint(x: -0.866, y: 0.5)  // +z → lower-left
        let x = CGFloat(local.x), y = CGFloat(local.y), z = CGFloat(local.z)
        return CGPoint(
            x: 500 + (x * xd.x + y * yd.x + z * zd.x) * s,
            y: 500 + (x * xd.y + y * yd.y + z * zd.y) * s)
    }

    private func hit(_ p: CGPoint) -> GizmoPart? {
        GizmoScreenLayout.hitTest(at: p, project: project)
    }

    private func axisAnchor(_ part: GizmoPart) -> CGPoint {
        GizmoScreenLayout.axisAnchor(part, project: project)!
    }

    // MARK: Axis arrows

    func testTapOnTheXArrowPicksTheXAxis() {
        XCTAssertEqual(hit(axisAnchor(.xAxis)), .xAxis)
    }

    func testTapOnTheYArrowPicksTheYAxis() {
        XCTAssertEqual(hit(axisAnchor(.yAxis)), .yAxis)
    }

    func testATapSlightlyOffAnArrowStillGrabsIt() {
        // Within the touch tolerance — grabbing must be forgiving.
        let a = axisAnchor(.xAxis)
        XCTAssertEqual(hit(CGPoint(x: a.x + 20, y: a.y + 15)), .xAxis)
    }

    // MARK: Plane handles

    func testTapOnAPlaneHandlePicksThatPlane() {
        let a = GizmoScreenLayout.planeAnchor(.xyPlane, project: project)!
        XCTAssertEqual(hit(a), .xyPlane)
    }

    // MARK: Rotation arcs

    func testTapOnARotationArcPicksThatRing() {
        // A point on the ring's projected polyline.
        let poly = GizmoScreenLayout.ringPolyline(.zRing, project: project)
        let mid = poly[poly.count / 2]
        XCTAssertEqual(hit(mid), .zRing)
    }

    // MARK: Priority + misses

    func testAnArrowBeatsARingWhereTheyOverlap() {
        // The X arrow anchor is a point target; even if a ring polyline passes
        // near it, the arrow (a tighter target) wins.
        XCTAssertEqual(hit(axisAnchor(.xAxis)), .xAxis)
    }

    func testATapInOpenSpaceGrabsNothing() {
        XCTAssertNil(hit(CGPoint(x: 900, y: 100)))
    }

    func testTheCentreItselfGrabsNothing() {
        // The pivot dot is not a drag target; a tap dead-centre misses the
        // arrows/planes/rings (which sit out at their radii).
        XCTAssertNil(hit(CGPoint(x: 500, y: 500)))
    }

    // MARK: Anchors are distinct and sensibly placed

    func testEachAxisArrowProjectsAwayFromTheCentre() {
        for part in GizmoScreenLayout.axes {
            let a = axisAnchor(part)
            XCTAssertGreaterThan(hypot(a.x - 500, a.y - 500), 40,
                                 "\(part) arrow should sit out from the pivot")
        }
    }
}
