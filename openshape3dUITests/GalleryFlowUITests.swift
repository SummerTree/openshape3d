//
//  GalleryFlowUITests.swift
//  openshape3dUITests
//
//  Open a design, leave it, and confirm the gallery still lists it (and the
//  thumbnail-capture path on exit doesn't break navigation).
//

import XCTest

final class GalleryFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpenDesignAndReturnToGallery() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_AUTO_OPEN"] = "1"
        app.launch()

        // In the editor (auto-opened).
        let rectButton = app.buttons.containing(.staticText, identifier: "Rect").firstMatch
        XCTAssertTrue(rectButton.waitForExistence(timeout: 10))

        // Navigate back to the gallery — triggers thumbnail capture + save.
        // The back button carries the previous screen's title.
        let backButton = app.buttons["Designs"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Back button should exist")
        backButton.tap()

        XCTAssertTrue(rectButton.waitForNonExistence(timeout: 5),
                      "Editor chrome should be gone after popping to the gallery")
        XCTAssertFalse(app.staticTexts["No Designs"].exists,
                       "Existing designs should be listed")
    }
}
