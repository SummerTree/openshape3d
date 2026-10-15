//
//  StartWithUITests.swift
//  openshape3dUITests
//
//  Settings ▸ Start With (spec §17): with "Last Opened Design" the app
//  reopens the design used last instead of showing the gallery.
//

import XCTest

final class StartWithUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLastOpenedDesignReopensAtLaunch() throws {
        // 1. A clean store and a new design: opening it records it as last.
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_FRESH_NAME"] = "Start With Part"
        app.launch()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 10), "the editor is open")
        app.terminate()

        // 2. No hooks, Start With ▸ Last Opened Design (UserDefaults argument
        // domain): straight back into that design, no gallery.
        let again = XCUIApplication()
        again.launchArguments += ["-os3d.startWith", "lastDesign", "-os3d.hasSeenWelcome", "YES"]
        again.launch()
        XCTAssertTrue(again.buttons["UndoButton"].waitForExistence(timeout: 10),
                      "the last design opens at launch")
        XCTAssertTrue(again.staticTexts["Start With Part"].exists || again.navigationBars["Start With Part"].exists
                      || again.otherElements["Start With Part"].exists || again.buttons["Start With Part"].exists,
                      "and it is the design opened last")
        again.terminate()

        // 3. The default (gallery) stays in the gallery.
        let gallery = XCUIApplication()
        gallery.launchArguments += ["-os3d.startWith", "gallery", "-os3d.hasSeenWelcome", "YES"]
        gallery.launch()
        XCTAssertFalse(gallery.buttons["UndoButton"].waitForExistence(timeout: 4), "the gallery shows")
    }
}
