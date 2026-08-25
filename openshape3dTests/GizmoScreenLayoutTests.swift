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

    // MARK: - Small viewports (iPhone landscape)

    /// The gizmo's on-screen size follows the viewport HEIGHT, so in iPhone
    /// landscape (~393pt tall) the 0.82-unit arm projects to only ~39pt —
    /// SMALLER than the 44pt arrow touch radius. The hit test used that radius
    /// as its foreshortening gate, so it skipped all three axes, and the 18pt
    /// pivot dead zone swallowed the plane handles. The gizmo drew at full
    /// opacity and was completely un-grabbable; drags fell through to a camera
    /// orbit (2026-08-25 review round 3, finding R3-A).
    ///
    /// `s = 47` reproduces iPhone landscape: arm = 0.82 × 47 ≈ 39pt.
    private func projectSmall(_ local: SIMD3<Float>) -> CGPoint? {
        let s: CGFloat = 47
        let x = CGFloat(local.x), y = CGFloat(local.y), z = CGFloat(local.z)
        return CGPoint(
            x: 200 + (x * 0.866 + z * -0.866) * s,
            y: 200 + (x * 0.5 + y * -1 + z * 0.5) * s)
    }

    private func hitSmall(_ p: CGPoint) -> GizmoPart? {
        GizmoScreenLayout.hitTest(at: p, project: projectSmall)
    }

    func testAxisArrowsAreGrabbableOnAShortViewport() {
        for part in GizmoScreenLayout.axes {
            let anchor = GizmoScreenLayout.axisAnchor(part, project: projectSmall)!
            XCTAssertEqual(hitSmall(anchor), part,
                           "\(part) must be grabbable when the whole gizmo is ~39pt")
        }
    }

    func testPlaneHandlesAreGrabbableOnAShortViewport() {
        for part in GizmoScreenLayout.planes {
            let anchor = GizmoScreenLayout.planeAnchor(part, project: projectSmall)!
            XCTAssertEqual(hitSmall(anchor), part,
                           "\(part) sits ~11pt out and must clear the pivot dead zone")
        }
    }

    func testTheCentreStillGrabsNothingOnAShortViewport() {
        XCTAssertNil(hitSmall(CGPoint(x: 200, y: 200)),
                     "the free-move pivot must stay a dead zone at any size")
    }

    func testOpenSpaceStillGrabsNothingOnAShortViewport() {
        // Tolerances shrink with the gizmo, so a far tap must not be claimed.
        XCTAssertNil(hitSmall(CGPoint(x: 380, y: 60)))
    }

    /// A genuinely foreshortened axis — one pointing into the screen — must
    /// still be skipped. The gate is now a fraction of the LONGEST arm, so it
    /// means the same thing at every gizmo size.
    func testAnAxisPointingIntoTheScreenIsStillSkipped() {
        // y collapses onto the pivot; x and z stay full length.
        func projectFlat(_ local: SIMD3<Float>) -> CGPoint? {
            let s: CGFloat = 120
            let x = CGFloat(local.x), z = CGFloat(local.z)
            return CGPoint(x: 500 + (x * 0.866 - z * 0.866) * s,
                           y: 500 + (x * 0.5 + z * 0.5) * s)
        }
        // The Y arrow projects onto the centre — a tap there grabs nothing.
        let yAnchor = GizmoScreenLayout.axisAnchor(.yAxis, project: projectFlat)!
        XCTAssertEqual(yAnchor, CGPoint(x: 500, y: 500), "y should collapse")
        XCTAssertNil(GizmoScreenLayout.hitTest(at: yAnchor, project: projectFlat),
                     "an axis pointing into the screen must not be grabbable")
        // …while the axes that are still long remain grabbable.
        let xAnchor = GizmoScreenLayout.axisAnchor(.xAxis, project: projectFlat)!
        XCTAssertEqual(GizmoScreenLayout.hitTest(at: xAnchor, project: projectFlat), .xAxis)
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
