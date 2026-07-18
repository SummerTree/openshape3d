//
//  ExtrudeFlowUITests.swift
//  openshape3dUITests
//
//  The core Shapr3D loop end-to-end: sketch a rectangle, finish, tap inside
//  the profile, and pull it into a solid.
//

import XCTest

final class ExtrudeFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSketchThenExtrudeMakesBody() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1" // brand-new design
        app.launch()

        // Draw a rectangle in sketch mode.
        let rectButton = app.buttons.containing(.staticText, identifier: "Rect").firstMatch
        XCTAssertTrue(rectButton.waitForExistence(timeout: 10))
        rectButton.tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2) // camera animation

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60))
        start.press(forDuration: 0.15, thenDragTo: end)

        app.buttons["Finish Sketch"].tap()

        // Tap inside the rectangle → extrude mode with preview + bar.
        let inside = window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.51))
        inside.tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5),
                      "Tapping inside a closed profile should start extruding")

        // Pull upward to increase the distance, then commit.
        let pullStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.45))
        let pullEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.30))
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd)

        app.buttons["Extrude"].firstMatch.tap()

        // Commit selects the new body: the Delete tool lights up.
        let deleteButton = app.buttons.containing(.staticText, identifier: "Delete").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        XCTAssertTrue(deleteButton.isEnabled,
                      "The extruded body should be selected after commit")
        XCTAssertFalse(app.staticTexts["Extrude"].exists, "Extrude bar should dismiss")
    }
}
