//
//  BooleanFlowUITests.swift
//  openshape3dUITests
//
//  Boolean flow: place two boxes, select one, arm Subtract, tap the other,
//  and verify the operation completes (tool body consumed, result selected).
//

import XCTest

final class BooleanFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSubtractFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()

        let window = app.windows.firstMatch
        let boxButton = app.buttons.containing(.staticText, identifier: "Box").firstMatch
        XCTAssertTrue(boxButton.waitForExistence(timeout: 10))

        // Place two boxes at separated spots.
        boxButton.tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.48)).tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        boxButton.tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.52)).tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // Select the first box.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.45)).tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "First box selected")

        // Arm Subtract and tap the second box.
        let subtractButton = app.buttons.containing(.staticText, identifier: "Subtract").firstMatch
        XCTAssertTrue(subtractButton.isEnabled)
        subtractButton.tap()
        XCTAssertTrue(app.staticTexts["Tap the second body to subtract"].waitForExistence(timeout: 3))

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.49)).tap()

        // Computation completes and the result stays selected.
        let deleteButton = app.buttons.containing(.staticText, identifier: "Delete").firstMatch
        let selected = NSPredicate(format: "isEnabled == true")
        expectation(for: selected, evaluatedWith: deleteButton)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.staticTexts["Tap the second body to subtract"].exists)
    }
}
