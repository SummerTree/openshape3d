//
//  GizmoOrientUITests.swift
//  openshape3dUITests
//
//  Move/Rotate Auto-Orient (spec §5.1): the Orient badge appears when the
//  selection has axes of its own (a turned body) and toggles the gizmo onto
//  them; a world-aligned body has nothing to orient to.
//

import XCTest

final class GizmoOrientUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testOrientBadgeTogglesForATurnedBody() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_TURNED"] = "1"
        app.launch()

        let orient = app.buttons["OrientBadge"]
        XCTAssertTrue(orient.waitForExistence(timeout: 10), "a turned body offers Orient")
        XCTAssertTrue(app.buttons["RepositionBadge"].exists)
        XCTAssertEqual(orient.value as? String, "off")
        orient.tap()
        XCTAssertEqual(orient.value as? String, "on", "the gizmo turns with the body")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "oriented-gizmo"; shot.lifetime = .keepAlways; add(shot)
        orient.tap()
        XCTAssertEqual(orient.value as? String, "off")
    }

    func testWorldAlignedBodyHasNoOrientBadge() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["RepositionBadge"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["OrientBadge"].exists, "nothing to orient to")
    }
}
