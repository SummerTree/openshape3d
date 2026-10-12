//
//  SplineUITests.swift
//  openshape3dUITests
//
//  Sketch ▸ Spline (spec §1.4): Fit Point places a curve through each tap
//  and Finish commits it open; Control Point taps a control polygon, and
//  tapping the first point again closes it into an extrudable profile.
//

import XCTest

final class SplineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func sketchSpline(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        startSketchTool(app, "Spline")
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2) // camera animation
        lookAtSketch(app)
        return window
    }

    func testFitSplineFinishesOpen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()
        let window = sketchSpline(app)

        XCTAssertTrue(app.staticTexts["Tap to place the first point"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["FinishSpline"].exists, "Nothing to finish yet")
        for (x, y) in [(0.35, 0.50), (0.45, 0.40), (0.55, 0.55), (0.65, 0.45)] {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        }
        XCTAssertTrue(app.staticTexts["Tap to add points, or the first point to close"].waitForExistence(timeout: 3))
        let undo = app.buttons["UndoButton"]
        XCTAssertFalse(undo.isEnabled, "Placing points is not yet an edit")

        app.buttons["FinishSpline"].tap()
        XCTAssertTrue(undo.waitForEnabled(timeout: 3), "Finishing commits the spline")
        XCTAssertTrue(app.staticTexts["Tap to place the first point"].waitForExistence(timeout: 3),
                      "The tool stays armed for the next spline")
    }

    func testClosedControlSplineIsAnExtrudableProfile() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()
        let window = sketchSpline(app)

        let picker = app.segmentedControls["SplineTypePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.buttons["Control Point"].tap()

        let corners = [(0.38, 0.40), (0.62, 0.40), (0.62, 0.60), (0.38, 0.60)]
        for (x, y) in corners {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        }
        XCTAssertTrue(app.staticTexts["Tap to add points, or the first point to close"].waitForExistence(timeout: 3),
                      "four control points placed: \(app.staticTexts["SplineInstruction"].label)")
        // Back on the first point: closes and commits.
        window.coordinate(withNormalizedOffset: CGVector(dx: corners[0].0, dy: corners[0].1)).tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForEnabled(timeout: 3), "Closing commits the spline")

        app.buttons["Exit Sketching"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5),
                      "A closed spline bounds a region that extrudes")
    }
}

private extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isEnabled { return true }
            usleep(100_000)
        }
        return isEnabled
    }
}
