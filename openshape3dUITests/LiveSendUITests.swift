//
//  LiveSendUITests.swift
//  openshape3dUITests
//
//  Release check against PRODUCTION: makes a design by touch (rectangle,
//  extrude), then really presses Send — Report a Bug (with the design
//  attached) and Export ▸ Open on the Web — and prints the report ID and the
//  link so they can be checked on the web. Skipped unless the runner is
//  started with TEST_RUNNER_OS3D_LIVE=1:
//
//    TEST_RUNNER_OS3D_LIVE=1 xcodebuild test -project openshape3d.xcodeproj \
//      -scheme openshape3d -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
//      -parallel-testing-enabled NO -only-testing:openshape3dUITests/LiveSendUITests
//

import XCTest

final class LiveSendUITests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OS3D_LIVE"] == "1",
                          "Sends to production; run with TEST_RUNNER_OS3D_LIVE=1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// A fresh design with one extruded body, drawn by touch.
    private func makeDesign() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        startSketchTool(app, "Rect")
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2) // camera animation
        lookAtSketch(app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60)))
        app.buttons["Exit Sketching"].tap()

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.51)).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5),
                      "Tapping the profile starts Extrude")
        typeExtrudeHeight(app, "20")
        XCTAssertTrue(app.staticTexts["Extrude"].waitForNonExistence(timeout: 5), "The extrude commits")
        return app
    }

    func testSendBugReportWithDesign() throws {
        let app = makeDesign()

        app.buttons["BugReportButton"].tap()
        XCTAssertTrue(app.navigationBars["Report a Bug"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["BugReportNotConfigured"].exists,
                       "This build has no Firebase config, so it can't send")
        let title = app.textFields["BugTitleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("[simulator test] release check — please close")

        app.swipeUp()
        let attach = app.switches["BugAttachToggle"]
        XCTAssertTrue(attach.waitForExistence(timeout: 3))
        XCTAssertEqual(attach.value as? String, "1", "The design is attached by default")

        app.buttons["BugReportSend"].tap()
        let sent = app.alerts["Thanks — report sent"]
        let sentBare = app.alerts["Report sent without the design"]
        let failed = app.alerts["Couldn't send the report"]
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !sent.exists, !sentBare.exists, !failed.exists { sleep(1) }

        for alert in [sent, sentBare, failed] where alert.exists {
            let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            print("LIVE BUG REPORT: \(alert.label): \(message)")
        }
        XCTAssertFalse(failed.exists, "Firestore refused the report")
        XCTAssertTrue(sent.exists, "The report is sent with the design attached")
        sent.buttons["OK"].tap()
    }

    func testOpenOnTheWebSendsAndLinks() throws {
        let app = makeDesign()

        app.buttons["ExportMenu"].tap()
        let openOnWeb = app.buttons["OpenOnWebButton"]
        XCTAssertTrue(openOnWeb.waitForExistence(timeout: 3))
        openOnWeb.tap()
        XCTAssertTrue(app.navigationBars["Open on the Web"].waitForExistence(timeout: 5))
        app.buttons["WebHandoffSend"].tap()

        let link = app.staticTexts["WebHandoffLink"]
        let error = app.descendants(matching: .any)["WebHandoffError"]
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !link.exists, !error.exists { sleep(1) }

        if error.exists { print("LIVE HANDOFF ERROR: \(error.label)") }
        XCTAssertTrue(link.exists, "The sheet shows the link")
        print("LIVE HANDOFF LINK: \(link.label)")
        XCTAssertTrue(link.label.hasPrefix("https://app.openshape3d.com/?open="))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'The link works until'")).firstMatch.exists)
        app.buttons["WebHandoffClose"].tap()
    }
}
