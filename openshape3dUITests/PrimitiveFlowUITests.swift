//
//  PrimitiveFlowUITests.swift
//  openshape3dUITests
//
//  End-to-end: arm the Box tool, tap the viewport to place it, confirm the
//  dimension bar appears, relaunch, and confirm the body persisted (it can be
//  selected again).
//

import XCTest

final class PrimitiveFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchIntoEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_AUTO_OPEN"] = "1"
        app.launch()
        return app
    }

    func testPlaceBoxAndPersist() throws {
        let app = launchIntoEditor()

        // Arm the Box tool from the palette.
        let boxButton = app.buttons.containing(.staticText, identifier: "Box").firstMatch
        XCTAssertTrue(boxButton.waitForExistence(timeout: 10), "Box tool should be in the palette")
        boxButton.tap()

        // Tap the viewport right of center to place the box on the ground.
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5))
            .tap()

        // Placement enters dimension editing: the numeric bar appears.
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5),
                      "Placing a box should open the dimension editor")
        XCTAssertTrue(app.staticTexts["W"].exists)
        XCTAssertTrue(app.staticTexts["H"].exists)
        doneButton.tap()

        // Give the debounced autosave time to write, then relaunch.
        sleep(4)
        app.terminate()

        let relaunched = launchIntoEditor()
        // Tap the same spot: the persisted box should select and reopen the bar.
        let viewport = relaunched.windows.firstMatch
        let target = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5))
        XCTAssertTrue(relaunched.buttons.containing(.staticText, identifier: "Box").firstMatch
            .waitForExistence(timeout: 10))
        target.tap()

        XCTAssertTrue(relaunched.buttons["Done"].waitForExistence(timeout: 5),
                      "The persisted box should be selectable after relaunch")
    }
}
