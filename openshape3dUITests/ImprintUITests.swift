//
//  ImprintUITests.swift
//  openshape3dUITests
//
//  Imprint Edge (spec §4.17) on the iPad's own chrome: Modify ▸ Imprint
//  Edge arms on the selected body, asks for a sketch, and Cancel leaves the
//  body selected. The split itself — tap a sketch, the region picks and
//  pulls on its own — runs through the same shared editor code in
//  `ImprintTests` and the web's imprint smoke.
//

import XCTest

final class ImprintUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testImprintArmsOnTheSelectedBodyAndCancels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"   // a 4 mm box, selected
        app.launch()
        XCTAssertTrue(app.staticTexts["Volume"].waitForExistence(timeout: 15), "the seeded box arrives selected")

        tapPaletteTool(app, group: "Modify", id: "ImprintButton")
        let prompt = app.staticTexts["Tap a sketch on the body to imprint its edges"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "Imprint Edge asks for a sketch")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Volume"].exists, "the body stays selected")
    }
}
