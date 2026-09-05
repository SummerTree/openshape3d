//
//  BugReportUITests.swift
//  openshape3dUITests
//
//  The Report a Bug sheet opens from the editor toolbar, requires a
//  summary before Send enables, offers the design attachment, and cancels
//  cleanly. Nothing is sent (the test never presses Send).
//

import XCTest

final class BugReportUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testBugReportSheetOpensValidatesAndCancels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        let bug = app.buttons["BugReportButton"]
        XCTAssertTrue(bug.waitForExistence(timeout: 5), "The toolbar should carry the bug button")
        bug.tap()

        XCTAssertTrue(app.navigationBars["Report a Bug"].waitForExistence(timeout: 5))
        let send = app.buttons["BugReportSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled, "Send needs a summary")
        // A SwiftUI Toggle folds its label into the switch element, so match
        // by label rather than by a separate static text.
        let attach = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Attach this design'")).firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 3),
                      "In the editor the design can be attached")

        let title = app.textFields["BugTitleField"]
        title.tap()
        title.typeText("Fillet closes the app")
        let configured = !app.staticTexts["BugReportNotConfigured"].exists
        XCTAssertEqual(send.isEnabled, configured,
                       "Send enables with a summary when the build carries a Firebase config")

        // The "what goes along" section sits below the fold in portrait; a
        // Form only realises rows on screen, so scroll before asserting.
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Included with your report"].waitForExistence(timeout: 3),
                      "The form lists what is sent automatically")

        app.buttons["BugReportCancel"].tap()
        XCTAssertTrue(app.navigationBars["Report a Bug"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["SketchGroup"].exists)
    }
}
