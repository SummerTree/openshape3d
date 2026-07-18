//
//  ExtrudeFlowUITests.swift
//  openshape3dUITests
//
//  The core Shapr3D loop end-to-end: sketch a rectangle base, exit sketching,
//  then turn the filled profile into a solid — both by tapping it (numeric
//  extrude) and by pulling it directly (push/pull, commits on release).
//

import XCTest

final class ExtrudeFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func drawRectangle(in app: XCUIApplication) {
        let rectButton = app.buttons.containing(.staticText, identifier: "Rect").firstMatch
        XCTAssertTrue(rectButton.waitForExistence(timeout: 10))
        rectButton.tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2) // camera animation

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60))
        start.press(forDuration: 0.15, thenDragTo: end)

        app.buttons["Exit Sketching"].tap()
    }

    func testTapProfileThenExtrudeButton() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()

        drawRectangle(in: app)

        // Tap inside the filled profile → jumps into the Extrude command.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.51)).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5),
                      "Tapping a filled profile should start extruding")

        app.buttons["Extrude"].firstMatch.tap()

        // Commit selects the new body: Delete lights up, extrude bar dismisses.
        let deleteButton = app.buttons.containing(.staticText, identifier: "Delete").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        XCTAssertTrue(deleteButton.isEnabled)
        XCTAssertFalse(app.staticTexts["Extrude"].exists)
    }

    func testPullProfileCreatesBodyOnRelease() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()

        drawRectangle(in: app)

        // Push/pull: drag upward starting inside the fill. In the head-on
        // view the screen-space fallback drives the distance. Releasing keeps
        // the dynamic preview (Shapr3D); completing the tool commits.
        let window = app.windows.firstMatch
        let pullStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.51))
        let pullEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.30))
        pullStart.press(forDuration: 0.15, thenDragTo: pullEnd)

        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 3),
                      "Releasing the pull keeps the Extrude tool active")
        app.buttons["Extrude"].firstMatch.tap()

        // Two undoable commands now: the sketch entity and the extrude.
        let deleteButton = app.buttons.containing(.staticText, identifier: "Delete").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        XCTAssertTrue(deleteButton.isEnabled, "Pulled body should be selected")

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap() // undo extrude
        XCTAssertTrue(undo.isEnabled, "Sketch command should remain")
        undo.tap() // undo sketch entity
        XCTAssertFalse(undo.isEnabled)
    }
}
