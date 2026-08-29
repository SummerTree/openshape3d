//
//  MeasureUITests.swift
//  openshape3dUITests
//
//  A9 measure/info bar: tapping a face shows Area in the bottom info strip;
//  the Measure tool shows a distance after two notable-point picks.
//

import XCTest

final class MeasureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        sleep(1) // camera fit settles
        return app
    }

    func testFaceSelectionShowsAreaInInfoBar() throws {
        let app = launchSeeded()
        let window = app.windows.firstMatch

        // Seeded box arrives selected: the info bar already shows Volume.
        XCTAssertTrue(
            app.staticTexts["Volume"].waitForExistence(timeout: 3),
            "Whole-body selection should show Volume in the info bar"
        )

        // Deselect, then tap the box's top face → face selection.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        sleep(1) // stay clear of the double-tap window
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        XCTAssertTrue(
            app.staticTexts["Area"].waitForExistence(timeout: 3),
            "Face selection should show Area in the info bar"
        )
        XCTAssertTrue(app.staticTexts["Perimeter"].exists)
    }

    func testMeasureTwoPointsShowsDistance() throws {
        let app = launchSeeded()
        let window = app.windows.firstMatch

        app.buttons["MeasureButton"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Tap two points to measure"].waitForExistence(timeout: 3)
        )

        // Tap near two box corners; the picker snaps to the nearest body
        // vertex within tolerance. Sweep a few candidate spots so the test
        // survives camera-framing differences.
        let candidates: [CGVector] = [
            CGVector(dx: 0.58, dy: 0.42),  // front-top corner
            CGVector(dx: 0.87, dy: 0.72),  // bottom-right corner
            CGVector(dx: 0.44, dy: 0.22),  // top-back corner
            CGVector(dx: 0.91, dy: 0.28),  // top-right corner
            CGVector(dx: 0.57, dy: 0.86),  // bottom-front corner
            CGVector(dx: 0.13, dy: 0.70),  // bottom-left corner
        ]
        let distance = app.staticTexts["MeasureDistanceValue"]
        for offset in candidates {
            window.coordinate(withNormalizedOffset: offset).tap()
            sleep(1) // stay clear of the double-tap recognizer window
            if distance.exists { break }
        }

        XCTAssertTrue(
            distance.waitForExistence(timeout: 3),
            "Two measure picks should show the distance pill"
        )
        XCTAssertTrue(distance.label.hasSuffix("mm"))

        // Done exits the tool.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["MeasureDistanceValue"].exists)
    }
}
