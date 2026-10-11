//
//  BugReportUITests.swift
//  openshape3dUITests
//
//  The Report a Bug sheet opens from the editor toolbar, requires a
//  summary before Send enables, offers the design attachment, and cancels
//  cleanly; a failure alert's "Report This…" opens it pre-filled. Nothing
//  is sent (the tests never press Send).
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
        // Type the summary while the first section is still on screen: a
        // Form only realises rows on screen, and how far a swipe scrolls
        // varies from run to run (2026-09-13: the title field was gone
        // after the swipe below once in a full-suite run).
        let title = app.textFields["BugTitleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Fillet closes the app")
        let configured = !app.staticTexts["BugReportNotConfigured"].exists
        XCTAssertEqual(send.isEnabled, configured,
                       "Send enables with a summary when the build carries a Firebase config")

        // In portrait the attachment section is below the Form's realised
        // rows. Scroll before querying it, and use its stable identifier rather
        // than depending on how SwiftUI folds a Toggle label into a switch.
        app.swipeUp()
        let attach = app.switches["BugAttachToggle"]
        XCTAssertTrue(attach.waitForExistence(timeout: 3),
                      "In the editor the design can be attached")

        // The "what goes along" section sits further down; scroll again
        // before asserting.
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Included with your report"].waitForExistence(timeout: 3),
                      "The form lists what is sent automatically")

        app.buttons["BugReportCancel"].tap()
        XCTAssertTrue(app.navigationBars["Report a Bug"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["SketchGroup"].exists)
    }

    func testFailureAlertOffersAPrefilledReport() throws {
        let failure = "The fillet produced no geometry."
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_REPORTABLE_FAILURE"] = failure
        app.launch()

        let alert = app.alerts["Something Went Wrong"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The failure should raise the alert")
        XCTAssertTrue(alert.staticTexts[failure].exists)
        let report = alert.buttons["Report This…"]
        XCTAssertTrue(report.exists, "An app failure offers a report")
        XCTAssertTrue(alert.buttons["OK"].exists)
        report.tap()

        XCTAssertTrue(app.navigationBars["Report a Bug"].waitForExistence(timeout: 5),
                      "Report This… opens the form")
        let title = app.textFields["BugTitleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.value as? String, failure, "The summary names the failure")
        let details = app.textViews["BugDetailsField"]
        XCTAssertTrue((details.value as? String ?? "").contains("The app said: “\(failure)”"),
                      "The details quote the app's message")
        let configured = !app.staticTexts["BugReportNotConfigured"].exists
        XCTAssertEqual(app.buttons["BugReportSend"].isEnabled, configured,
                       "A pre-filled summary is enough to send")

        app.buttons["BugReportCancel"].tap()
        XCTAssertTrue(app.navigationBars["Report a Bug"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(alert.exists, "The alert doesn't come back after the form closes")

        // The toolbar button still opens an empty form.
        app.buttons["BugReportButton"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertNotEqual(title.value as? String, failure, "The toolbar starts blank")
        app.buttons["BugReportCancel"].tap()
    }
}
