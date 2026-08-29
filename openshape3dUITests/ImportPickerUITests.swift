//
//  ImportPickerUITests.swift
//  openshape3dUITests
//
//  Every Import-menu entry must actually OPEN a file picker.
//
//  This is the one thing the other IO tests could not see. They assert the
//  menu lists its entries — and the entries were listed, and tapping them did
//  absolutely nothing, for as long as the view stacked one `.fileImporter`
//  per format: SwiftUI keeps only the LAST one in such a chain alive, so STL
//  and DXF import were dead on arrival and nothing failed. The fix is a single
//  importer driven by `EditorView.ImportRequest`; this test is what stops the
//  chain from growing back.
//
//  The system picker belongs to another process, so it is asserted through
//  its own app element and dismissed again — no file is ever chosen here.
//

import XCTest

final class ImportPickerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testEveryImportEntryOpensAPicker() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()

        let importMenu = app.buttons["ImportMenu"]
        XCTAssertTrue(importMenu.waitForExistence(timeout: 15))

        for entry in ["ImportSTL", "ImportDXF", "ImportSTEP"] {
            importMenu.tap()
            let item = app.buttons[entry]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "\(entry) must be in the menu")
            item.tap()

            // The picker is a remote view service, but its content surfaces
            // in the app's element tree — "On My iPad" is the sidebar row
            // that is present whatever the allowed content types are.
            XCTAssertTrue(app.staticTexts["On My iPad"].waitForExistence(timeout: 10),
                          "\(entry) must open a document picker; a stacked "
                          + ".fileImporter silently does nothing at all")

            // Leave without picking anything: the picker's leading button is
            // its close control. Assert on the picker being GONE, not on the
            // editor being back — `ImportMenu` still `exists` underneath a
            // modal, so waiting for it would pass with the picker still up.
            app.buttons.firstMatch.tap()
            XCTAssertTrue(app.staticTexts["On My iPad"].waitForNonExistence(timeout: 10),
                          "the picker must close before the next entry is tried")
        }
    }
}
