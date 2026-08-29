//
//  ConstructionAxisUITests.swift
//  openshape3dUITests
//
//  Add Axis (spec §6.2). The tool derives WHICH of the five constructions to
//  use from what you tap, so the assertions are on the construction the bar
//  reports — that label is the user-visible proof the inference ran.
//

import XCTest

final class ConstructionAxisUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Fresh document seeded with a single cylinder, so there is a round face
    /// AND flat caps to pick from.
    private func appWithCylinder() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_CYLINDER"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["AxisButton"].waitForExistence(timeout: 10))
        return (app, app.windows.firstMatch)
    }

    func testTappingARoundFaceDerivesTheCylinderAxisAndCommits() throws {
        let (app, window) = appWithCylinder()

        app.buttons["AxisButton"].tap()
        XCTAssertTrue(app.staticTexts["Tap an edge or face"].waitForExistence(timeout: 3),
                      "Arming the tool should show its bar")
        XCTAssertFalse(app.buttons["AxisApply"].isEnabled,
                       "Apply stays disabled until the picks resolve to an axis")

        // The cylinder's curved side.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.55)).tap()
        XCTAssertTrue(app.staticTexts["Axis of Cylinder/Cone"].waitForExistence(timeout: 3),
                      "A round face should derive its own fitted axis")
        XCTAssertTrue(app.buttons["AxisApply"].isEnabled)

        app.buttons["AxisApply"].tap()

        // Committing disarms the tool and leaves an item behind.
        XCTAssertFalse(app.staticTexts["Axis of Cylinder/Cone"].exists)

        app.buttons["ItemsButton"].tap()
        XCTAssertTrue(app.staticTexts["Axes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["ItemName-Axis 1"].exists
                        || app.staticTexts["Axis 1"].exists,
                      "The committed axis should appear in Items")
    }

    func testTappingAFlatCapDerivesAPerpendicularAxis() throws {
        let (app, window) = appWithCylinder()

        app.buttons["AxisButton"].tap()
        XCTAssertTrue(app.staticTexts["Tap an edge or face"].waitForExistence(timeout: 3))

        // The flat top cap.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.33)).tap()
        XCTAssertTrue(app.staticTexts["Perpendicular to Face"].waitForExistence(timeout: 3),
                      "A flat face should derive the normal through it")
        XCTAssertTrue(app.buttons["AxisApply"].isEnabled)
    }

    func testCancelLeavesNoAxisBehind() throws {
        let (app, window) = appWithCylinder()

        app.buttons["AxisButton"].tap()
        XCTAssertTrue(app.staticTexts["Tap an edge or face"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.55)).tap()
        XCTAssertTrue(app.staticTexts["Axis of Cylinder/Cone"].waitForExistence(timeout: 3))

        app.buttons["AxisCancel"].tap()
        XCTAssertFalse(app.staticTexts["Axis of Cylinder/Cone"].exists)

        // Assert on the document, not the undo stack: the seeded cylinder is
        // itself a command, so Undo is already enabled before the tool runs.
        app.buttons["ItemsButton"].tap()
        XCTAssertTrue(app.staticTexts["Axes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No axes yet"].exists,
                      "Cancelling must not add an axis")
    }
}
