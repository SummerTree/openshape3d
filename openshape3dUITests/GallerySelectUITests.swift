//
//  GallerySelectUITests.swift
//  openshape3dUITests
//
//  Gallery select mode: "Select" arms Photos-style multi-selection, card taps
//  toggle membership instead of opening, and the toolbar Delete removes every
//  selected design behind a confirmation alert.
//

import XCTest

final class GallerySelectUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testSelectModeMultiDelete() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()
        // OS3D_FRESH opens a fresh design; return to the gallery.
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Designs"].waitForExistence(timeout: 5))

        // A second design via "+", then back again.
        app.buttons["New Design"].tap()
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Designs"].waitForExistence(timeout: 5))

        // The two newest cards are ours (the grid sorts by modifiedAt desc);
        // the store may hold older designs this test must not touch.
        let cards = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Untitled'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3))
        let nameA = cards.element(boundBy: 0).label
        let nameB = cards.element(boundBy: 1).label
        XCTAssertNotEqual(nameA, nameB, "fresh designs get unique names")

        // Select both and multi-delete, confirming the alert.
        app.buttons["SelectProjectsButton"].tap()
        app.staticTexts[nameA].tap()
        app.staticTexts[nameB].tap()
        let deleteButton = app.buttons["DeleteSelectedButton"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.tap()
        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3),
                      "multi-delete must ask before destroying designs")
        confirm.tap()

        XCTAssertFalse(app.staticTexts[nameA].waitForExistence(timeout: 2),
                       "deleted designs should leave the gallery")
        XCTAssertFalse(app.staticTexts[nameB].exists)
        // Select mode exits after the delete — the normal toolbar is back.
        XCTAssertTrue(app.buttons["New Design"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["DeleteSelectedButton"].exists)
    }

    func testSelectModeCancelKeepsDesigns() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Designs"].waitForExistence(timeout: 5))

        let cards = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Untitled'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3))
        let name = cards.element(boundBy: 0).label

        app.buttons["SelectProjectsButton"].tap()
        app.staticTexts[name].tap()
        // Delete is armed but Cancel backs out without touching anything.
        XCTAssertTrue(app.buttons["DeleteSelectedButton"].isEnabled)
        app.buttons["CancelSelectButton"].tap()
        XCTAssertTrue(app.staticTexts[name].exists,
                      "cancelling select mode must not delete anything")
        XCTAssertTrue(app.buttons["New Design"].waitForExistence(timeout: 3))
    }
}
