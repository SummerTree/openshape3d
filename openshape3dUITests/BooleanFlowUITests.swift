//
//  BooleanFlowUITests.swift
//  openshape3dUITests
//
//  Boolean flow, Shapr3D-style: create two bodies by sketching rectangles and
//  extruding them, select one, arm Subtract, tap the other, and verify the
//  operation completes (tool body consumed, result selected).
//

import XCTest

final class BooleanFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Draws a rectangle between two normalized points and extrudes it via
    /// the numeric bar (works in the head-on sketch view).
    private func makeBody(
        in app: XCUIApplication,
        from start: CGVector, to end: CGVector, tapInside: CGVector
    ) {
        let window = app.windows.firstMatch
        let rectButton = app.buttons.containing(.staticText, identifier: "Rect").firstMatch
        rectButton.tap()
        // Plane pickers appear; tap the bare ground to sketch there.
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2) // camera animation to head-on

        window.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: end))
        app.buttons["Exit Sketching"].tap()

        window.coordinate(withNormalizedOffset: tapInside).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))
        app.buttons["Extrude"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Extrude"].exists)
    }

    func testSubtractFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()

        let rectButton = app.buttons.containing(.staticText, identifier: "Rect").firstMatch
        XCTAssertTrue(rectButton.waitForExistence(timeout: 10))

        // Two separate bodies. The camera stays head-on between sketches, so
        // screen coordinates map stably onto the ground plane.
        makeBody(
            in: app,
            from: CGVector(dx: 0.30, dy: 0.42), to: CGVector(dx: 0.45, dy: 0.58),
            tapInside: CGVector(dx: 0.37, dy: 0.5)
        )
        makeBody(
            in: app,
            from: CGVector(dx: 0.58, dy: 0.42), to: CGVector(dx: 0.73, dy: 0.58),
            tapInside: CGVector(dx: 0.65, dy: 0.5)
        )

        let window = app.windows.firstMatch

        // Select the first body (bodies occlude their profiles from above).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.37, dy: 0.5)).tap()
        let deleteButton = app.buttons.containing(.staticText, identifier: "Delete").firstMatch
        XCTAssertTrue(deleteButton.isEnabled, "First body should be selected")

        // Arm Subtract and tap the second body.
        let subtractButton = app.buttons.containing(.staticText, identifier: "Subtract").firstMatch
        XCTAssertTrue(subtractButton.isEnabled)
        subtractButton.tap()
        XCTAssertTrue(app.staticTexts["Tap the second body to subtract"].waitForExistence(timeout: 3))

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).tap()

        // Computation completes and the result stays selected.
        let selected = NSPredicate(format: "isEnabled == true")
        expectation(for: selected, evaluatedWith: deleteButton)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.staticTexts["Tap the second body to subtract"].exists)
    }
}
