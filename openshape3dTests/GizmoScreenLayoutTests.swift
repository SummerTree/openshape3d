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

    /// The tile is a QUAD lying in its plane, not a screen-aligned square, so
    /// every point inside the shape the user sees grabs that plane — including
    /// the corners, which a centre-plus-radius target used to miss entirely.
    func testTapAnywhereInsideAPlaneTileGrabsIt() {
        for part in GizmoScreenLayout.planes {
            let quad = GizmoScreenLayout.planeQuad(part, project: project)!
            let centre = GizmoScreenLayout.planeAnchor(part, project: project)!
            for corner in quad {
                // 80% of the way out to each corner — inside, but well past
                // where a small circular target would have ended.
                let p = CGPoint(x: centre.x + (corner.x - centre.x) * 0.8,
                                y: centre.y + (corner.y - centre.y) * 0.8)
                XCTAssertEqual(hit(p), part, "\(part) must be grabbable at its corners")
            }
        }
    }

    /// Each tile leans with its plane: its projected edges run along the two
    /// axes that span that plane. That orientation is the whole affordance —
    /// the square tells you which way it drags.
    func testAPlaneTileIsOrientedToItsPlane() {
        for part in GizmoScreenLayout.planes {
            let quad = GizmoScreenLayout.planeQuad(part, project: project)!
            let (u, v) = GizmoScreenLayout.planeBasis(for: part)
            let centre = project(.zero)!
            func screenDir(_ axis: SIMD3<Float>) -> CGVector {
                let p = project(axis)!
                let dx = p.x - centre.x, dy = p.y - centre.y
                let len = hypot(dx, dy)
                return CGVector(dx: dx / len, dy: dy / len)
            }
            // Corner order is (u,v) = (min,min) → (max,min) → (max,max), so
            // edge 0→1 runs along u and edge 1→2 along v.
            let edges = [(quad[0], quad[1], screenDir(u)), (quad[1], quad[2], screenDir(v))]
            for (a, b, expected) in edges {
                let dx = b.x - a.x, dy = b.y - a.y
                let len = hypot(dx, dy)
                XCTAssertGreaterThan(len, 1, "\(part) edge should not be degenerate")
                let dot = (dx / len) * expected.dx + (dy / len) * expected.dy
                XCTAssertEqual(dot, 1, accuracy: 0.01,
                               "\(part) edge should run along its own plane axis")
            }
        }
    }

    /// A tile seen edge-on (its plane pointing at the camera) is a sliver: the
    /// overlay fades it out, so the hit test must not hand it a drag either.
    func testAnEdgeOnPlaneTileIsNotGrabbable() {
        // y collapses onto the pivot: the xy and yz tiles go edge-on, zx stays.
        func projectFlat(_ local: SIMD3<Float>) -> CGPoint? {
            let s: CGFloat = 120
            let x = CGFloat(local.x), z = CGFloat(local.z)
            return CGPoint(x: 500 + (x * 0.866 - z * 0.866) * s,
                           y: 500 + (x * 0.5 + z * 0.5) * s)
        }
        let visible = GizmoScreenLayout.visiblePlaneQuads(project: projectFlat).map(\.part)
        XCTAssertEqual(visible, [.zxPlane],
                       "only the tile still facing the camera should survive")
        let collapsed = GizmoScreenLayout.planeAnchor(.xyPlane, project: projectFlat)!
        XCTAssertNotEqual(GizmoScreenLayout.hitTest(at: collapsed, project: projectFlat),
                          .xyPlane, "an edge-on tile must not claim a drag")
    }

    /// The tiles start ~0.18 gizmo units out, so on a short viewport their
    /// inner corners land inside the pivot dead zone. Containment has to win
    /// there, or the tiles are ungrabbable exactly where they are smallest.
    func testAPlaneTileBeatsThePivotDeadZone() {
        let quad = GizmoScreenLayout.planeQuad(.xyPlane, project: projectSmall)!
        let centre = projectSmall(.zero)!
        // The corner nearest the pivot.
        let inner = quad.min(by: {
            hypot($0.x - centre.x, $0.y - centre.y) < hypot($1.x - centre.x, $1.y - centre.y)
        })!
        let tileCentre = GizmoScreenLayout.planeAnchor(.xyPlane, project: projectSmall)!
        let p = CGPoint(x: tileCentre.x + (inner.x - tileCentre.x) * 0.9,
                        y: tileCentre.y + (inner.y - tileCentre.y) * 0.9)
        XCTAssertEqual(hitSmall(p), .xyPlane)
    }

    /// A grab near the plane tiles must never be claimed by a rotation arc.
    /// The arcs' touch band is deliberately fat, and it used to reach right
    /// back over the tiles: a near-miss on a skinny tile rotated the body
    /// instead of sliding it, which is what "the squares don't drag in their
    /// plane" actually was.
    func testAGrabNearThePlaneTilesIsNeverARotation() {
        let centre = project(.zero)!
        // Out to the furthest tile corner (plus a touch): the band a user aims
        // at when they go for a square.
        let reach = GizmoScreenLayout.planes
            .compactMap { GizmoScreenLayout.planeQuad($0, project: project) }
            .flatMap { $0 }
            .map { hypot($0.x - centre.x, $0.y - centre.y) }
            .max()! + 6
        for radius in stride(from: CGFloat(15), through: reach, by: 5) {
            for degrees in stride(from: CGFloat(0), to: 360, by: 5) {
                let a = degrees * .pi / 180
                let p = CGPoint(x: centre.x + cos(a) * radius, y: centre.y + sin(a) * radius)
                if let part = hit(p) {
                    XCTAssertFalse(part.isRing,
                                   "a grab \(Int(radius))pt from the pivot became \(part)")
                }
            }
        }
    }

    /// …while the arcs themselves stay grabbable where they are drawn.
    func testRotationArcsAreStillGrabbableOutAtTheirRadius() {
        for part in GizmoScreenLayout.rings {
            let poly = GizmoScreenLayout.ringPolyline(part, project: project)
            XCTAssertEqual(hit(poly[poly.count / 2]), part)
        }
    }

    // MARK: Pivot

    func testThePivotTargetGrowsOnceArmed() {
        // 26pt off-centre: outside the dead zone, inside the armed grab circle.
        let p = CGPoint(x: 526, y: 500)
        XCTAssertFalse(GizmoScreenLayout.hitsPivot(at: p, armed: false, project: project))
        XCTAssertTrue(GizmoScreenLayout.hitsPivot(at: p, armed: true, project: project))
    }

    func testThePivotIsHitDeadCentre() {
        let centre = project(.zero)!
        XCTAssertTrue(GizmoScreenLayout.hitsPivot(at: centre, armed: false, project: project))
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
