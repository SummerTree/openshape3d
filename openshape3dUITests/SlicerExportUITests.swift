//
//  SlicerExportUITests.swift
//  openshape3dUITests
//
//  Export ▸ Export to Slicer on iPad: the print-ready 3MF goes to the
//  share sheet, where slicer apps pick it up.
//

import XCTest

final class SlicerExportUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testExportToSlicerOpensTheShareSheet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["ExportMenu"].waitForExistence(timeout: 10))
        app.buttons["ExportMenu"].tap()
        let slicer = app.buttons["ExportToSlicerButton"]
        XCTAssertTrue(slicer.waitForExistence(timeout: 3))
        slicer.tap()
        // The system share sheet names the file it carries.
        let sheet = app.otherElements["ActivityListView"]
        let named = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '.3mf' OR label CONTAINS 'Untitled'")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 8) || named.waitForExistence(timeout: 2),
                      "the share sheet opens with the 3MF")
    }
}
