//
//  FaceFlowUITests.swift
//  openshape3dUITests
//
//  Shapr3D face push/pull: tap a body to select the face under the tap,
//  drag the face to pull it out (auto-union), and complete the tool.
//

import XCTest

final class FaceFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testSelectFaceAndPull() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()

        let rectButton = app.buttons.containing(.staticText, identifier: "Rect").firstMatch
        XCTAssertTrue(rectButton.waitForExistence(timeout: 10))
        sleep(1) // camera fit settles

        let window = app.windows.firstMatch

        // Deselect the seeded box (tap empty space, away from the palette).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        sleep(1) // stay clear of the double-tap window

        // Tap the box's top face → face selection.
        let facePoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        facePoint.tap()
        sleep(1)
        XCTAssertTrue(
            app.staticTexts["Face selected — drag it to push or pull"].waitForExistence(timeout: 3),
            "Tapping a body should select the face under the tap"
        )

        // Pull the face upward (push/pull with dynamic preview).
        let pullEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        facePoint.press(forDuration: 0.15, thenDragTo: pullEnd)

        // Complete the tool.
        app.buttons["Extrude"].firstMatch.tap()

        // Seed add + face extrude = two undoable commands.
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(undo.isEnabled, "Face extrude should undo first, leaving the seed")
        undo.tap()
        XCTAssertFalse(undo.isEnabled)
    }
}
