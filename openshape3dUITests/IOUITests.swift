//
//  IOUITests.swift
//  openshape3dUITests
//
//  Import/export chrome (spec §12): Export menu entries and the screenshot
//  options sheet. The system file dialogs are never driven — only the app's
//  own chrome is asserted.
//

import XCTest

final class IOUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testExportMenuEntriesAndScreenshotOptions() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()

        // Import lives in its own toolbar menu.
        XCTAssertTrue(app.buttons["ImportMenu"].waitForExistence(timeout: 10))

        // Export menu lists every format plus the screenshot entry.
        let exportMenu = app.buttons["ExportMenu"]
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 10))
        exportMenu.tap()
        XCTAssertTrue(app.buttons["STL"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["OBJ"].exists)
        XCTAssertTrue(app.buttons["3MF"].exists)
        let screenshotEntry = app.buttons["PNG Screenshot…"]
        XCTAssertTrue(screenshotEntry.exists)

        // The screenshot entry opens the options sheet; assert the options
        // then cancel without exporting.
        screenshotEntry.tap()
        XCTAssertTrue(app.staticTexts["Screenshot"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Resolution"].exists)
        XCTAssertTrue(app.switches["ScreenshotTransparent"].exists)
        XCTAssertTrue(app.switches["ScreenshotGrid"].exists)
        XCTAssertTrue(app.buttons["ScreenshotExport"].exists)

        let cancel = app.buttons["ScreenshotCancel"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertFalse(app.staticTexts["Resolution"].waitForExistence(timeout: 2),
                       "Cancel should dismiss the screenshot sheet")
    }
}
