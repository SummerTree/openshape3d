//
//  ViewsUITests.swift
//  openshape3dUITests
//
//  A7: the Views popover — snap to a standard view, then confirm the app is
//  still fully interactive by drawing a rectangle in sketch mode.
//

import XCTest

final class ViewsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testFrontViewThenSketchStillWorks() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_AUTO_OPEN"] = "1"
        app.launch()

        let window = app.windows.firstMatch

        // Open the Views popover and snap to Front.
        let viewsButton = app.buttons["ViewsMenu"]
        XCTAssertTrue(viewsButton.waitForExistence(timeout: 10))
        viewsButton.tap()
        let front = app.buttons["Front"]
        XCTAssertTrue(front.waitForExistence(timeout: 3))
        front.tap()

        // Let the camera flight settle; the app must remain interactive.
        sleep(1)

        // Draw a rectangle: arm Rect, pick the ground plane, drag.
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 5))
        startSketchTool(app, "Rect")

        // From the front view the XY plane tile sits head-on just up-right of
        // the screen center (tiles span 0.3–2.3 world units from the origin).
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.40)).tap()

        XCTAssertTrue(app.staticTexts["Sketching on plane"].waitForExistence(timeout: 3),
                      "Sketch mode should start after the Front view snap")
        lookAtSketch(app)

        // Let the head-on camera animation settle.
        sleep(2)
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.62))
        start.press(forDuration: 0.15, thenDragTo: end)

        let undo = app.buttons["UndoButton"]
        XCTAssertTrue(undo.isEnabled,
                      "Drawing a rectangle after a standard-view snap should still commit")

        app.buttons["Exit Sketching"].firstMatch.tap()
    }

    /// View ▸ Field of View…: dragging the slider to 0 reads Orthographic,
    /// and Nearest Ortho View runs from the same menu.
    func testFieldOfViewReachesOrthographic() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()
        let viewsButton = app.buttons["ViewsMenu"]
        XCTAssertTrue(viewsButton.waitForExistence(timeout: 10))

        viewsButton.tap()
        XCTAssertTrue(app.buttons["Nearest Ortho View"].waitForExistence(timeout: 3))
        app.buttons["Nearest Ortho View"].tap()

        viewsButton.tap()
        app.buttons["Field of View…"].tap()
        let value = app.staticTexts["FieldOfViewValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 3))
        XCTAssertEqual(value.label, "40°", "Starts at the default perspective")
        app.sliders["FieldOfViewSlider"].adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(app.staticTexts["Orthographic"].waitForExistence(timeout: 3),
                      "0° is orthographic")
        app.buttons["Done"].firstMatch.tap()
    }
}
