//
//  WebHandoffUITests.swift
//  openshape3dUITests
//
//  Export ▸ Open on the Web… opens a sheet that explains what is sent and
//  sends nothing until Send. The test never presses Send (no network).
//

import XCTest

final class WebHandoffUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testOpenOnTheWebAsksBeforeSending() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()

        let exportMenu = app.buttons["ExportMenu"]
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 10))
        exportMenu.tap()
        let openOnWeb = app.buttons["OpenOnWebButton"]
        XCTAssertTrue(openOnWeb.waitForExistence(timeout: 3), "Export offers Open on the Web")
        openOnWeb.tap()

        XCTAssertTrue(app.navigationBars["Open on the Web"].waitForExistence(timeout: 5))
        let send = app.buttons["WebHandoffSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '24 hours'")).firstMatch.exists,
                      "The sheet says how long the link lasts before anything is sent")
        XCTAssertFalse(app.otherElements["WebHandoffSending"].exists, "Nothing is sent on open")

        app.buttons["WebHandoffClose"].tap()
        XCTAssertTrue(app.navigationBars["Open on the Web"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["ExportMenu"].exists)
    }
}
