//
//  ConstructionPlaneUITests.swift
//  openshape3dUITests
//
//  Construct ▸ Plane (spec §6.1): the menu arms one construction, the bar
//  says what to tap next, Apply enables once the picks define a plane, and
//  the committed plane appears in Items.
//

import XCTest

final class ConstructionPlaneUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func appWithCylinder() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_CYLINDER"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["ConstructGroup"].waitForExistence(timeout: 10))
        return (app, app.windows.firstMatch)
    }

    private func armPlane(_ app: XCUIApplication, _ construction: String) {
        tapPaletteTool(app, group: "Construct", id: "PlaneButton")
        let entry = app.buttons["PlaneConstruction-" + construction]
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "The Plane menu lists its constructions")
        entry.tap()
    }

    func testOffsetPlaneFromTheCapCommitsToItems() throws {
        let (app, window) = appWithCylinder()

        armPlane(app, "offset")
        XCTAssertTrue(app.staticTexts["Tap a flat face or plane"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["PlaneApply"].isEnabled)
        XCTAssertTrue(app.textFields["PlaneOffsetField"].exists, "Offset shows its distance")

        // The flat top cap.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.33)).tap()
        XCTAssertTrue(app.staticTexts["Offset Plane"].waitForExistence(timeout: 3),
                      "With its face picked the bar names the construction")
        XCTAssertTrue(app.buttons["PlaneApply"].isEnabled)
        app.buttons["PlaneApply"].tap()
        XCTAssertFalse(app.buttons["PlaneApply"].exists, "Apply disarms the tool")

        app.buttons["ItemsButton"].tap()
        XCTAssertTrue(app.staticTexts["Planes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["ItemName-Plane 1"].exists || app.staticTexts["Plane 1"].exists,
                      "The committed plane should appear in Items")
    }

    func testThreePointsCountsItsPicksAndSwitchingResets() throws {
        let (app, window) = appWithCylinder()

        armPlane(app, "threePoints")
        XCTAssertTrue(app.staticTexts["Tap a point (1 of 3)"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.50)).tap()
        XCTAssertTrue(app.staticTexts["Tap a point (2 of 3)"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.62)).tap()
        XCTAssertTrue(app.staticTexts["Tap a point (3 of 3)"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["PlaneClear"].exists)
        XCTAssertFalse(app.buttons["PlaneApply"].isEnabled)

        // Another construction from the bar's menu starts its picks over.
        app.buttons["PlaneConstructionMenu"].tap()
        app.buttons["Plane Parallel to Face at Point"].tap()
        XCTAssertTrue(app.staticTexts["Tap a flat face or plane (1 of 2)"].waitForExistence(timeout: 3))

        app.buttons["PlaneCancel"].tap()
        XCTAssertFalse(app.buttons["PlaneApply"].exists)
    }
}
