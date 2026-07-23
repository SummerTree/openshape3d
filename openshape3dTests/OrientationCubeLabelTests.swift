//
//  OrientationCubeLabelTests.swift
//  openshape3dTests
//
//  Spec §7.2 — standard-view names on the orientation cube. The names have to
//  agree with the Views menu (a cube that calls +Z "Back" while the menu flies
//  to it as "Front" is worse than no labels), sit ON the face they name, and
//  only appear for faces you could actually tap.
//

import XCTest
import simd
@testable import openshape3d

final class OrientationCubeLabelTests: XCTestCase {

    private let viewSize = CGSize(width: 1000, height: 800)

    private func camera(_ view: StandardView) -> TurntableCamera {
        var cam = TurntableCamera()
        cam.distance = 500
        return view.applied(to: cam)
    }

    private func labels(_ view: StandardView) -> [OrientationCube.FaceLabel] {
        OrientationCube.faceLabels(camera: camera(view), viewSize: viewSize)
    }

    // MARK: Naming agrees with the Views menu

    func testHeadOnViewsNameTheFaceTheyFlyTo() {
        for view in [StandardView.front, .back, .left, .right] {
            let names = labels(view).map(\.name)
            XCTAssertEqual(names.first, view.rawValue,
                           "\(view.rawValue) should be the most-facing label")
        }
    }

    func testTopViewNamesTop() {
        // Top/Bottom clamp 1° short of a true plan view, so the named face is
        // Top with a sliver of a side face possibly alongside it.
        XCTAssertEqual(labels(.top).first?.name, "Top")
        XCTAssertEqual(labels(.bottom).first?.name, "Bottom")
    }

    func testEveryLabelNameIsAStandardView() {
        let valid = Set(StandardView.allCases.map(\.rawValue))
        for label in labels(.isometric) {
            XCTAssertTrue(valid.contains(label.name),
                          "\(label.name) is not a view the camera can fly to")
        }
    }

    // MARK: Which faces are named

    func testAHeadOnViewNamesOnlyTheFacingFace() {
        XCTAssertEqual(labels(.front).count, 1,
                       "the four side faces are edge-on and unreadable")
    }

    func testAnIsometricViewNamesTheThreeVisibleFaces() {
        let names = Set(labels(.isometric).map(\.name))
        XCTAssertEqual(names.count, 3, "a corner view shows exactly three faces")
        XCTAssertTrue(names.isSuperset(of: ["Top"]),
                      "an isometric looks down, so Top is one of them")
    }

    func testOppositeFacesAreNeverNamedTogether() {
        for view in StandardView.allCases {
            let names = Set(OrientationCube.faceLabels(
                camera: camera(view), viewSize: viewSize).map(\.name))
            for pair in [("Front", "Back"), ("Left", "Right"), ("Top", "Bottom")] {
                XCTAssertFalse(names.contains(pair.0) && names.contains(pair.1),
                               "\(pair) can't both face the camera in \(view.rawValue)")
            }
        }
    }

    // MARK: Placement

    func testLabelsLandInsideTheCubesOwnRect() {
        let rect = OrientationCube.rect(in: viewSize).insetBy(dx: -6, dy: -6)
        for view in StandardView.allCases {
            for label in OrientationCube.faceLabels(
                camera: camera(view), viewSize: viewSize) {
                XCTAssertTrue(rect.contains(label.point),
                              "\(label.name) at \(label.point) escaped the cube in \(view.rawValue)")
            }
        }
    }

    func testAHeadOnFaceIsLabelledAtTheCubesCentre() {
        let label = try? XCTUnwrap(labels(.front).first)
        let centre = OrientationCube.rect(in: viewSize).center
        XCTAssertEqual(label?.point.x ?? 0, centre.x, accuracy: 1)
        XCTAssertEqual(label?.point.y ?? 0, centre.y, accuracy: 1)
    }

    func testFacingFacesAreMoreOpaqueThanGrazingOnes() {
        let sorted = labels(.isometric).sorted { $0.opacity > $1.opacity }
        XCTAssertGreaterThan(sorted.first?.opacity ?? 0, sorted.last?.opacity ?? 1,
                             "a face turning away fades out")
        for label in sorted {
            XCTAssertGreaterThan(label.opacity, 0)
            XCTAssertLessThanOrEqual(label.opacity, 1)
        }
    }

    // MARK: Degenerate input

    func testAZeroSizedViewportProducesNoLabels() {
        XCTAssertTrue(OrientationCube.faceLabels(
            camera: camera(.front), viewSize: .zero).isEmpty)
    }

    func testACameraSittingOnItsTargetProducesNoLabels() {
        var cam = camera(.front)
        cam.distance = 0
        XCTAssertTrue(OrientationCube.faceLabels(
            camera: cam, viewSize: viewSize).isEmpty,
            "with no eye direction there is no facing to compute")
    }

}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
