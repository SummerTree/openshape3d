//
//  DeviationPreviewUITests.swift
//  openshape3dUITests
//
//  Views ▸ Deviation Preview on two seeded boxes: the legend appears while
//  the app measures, the numbers arrive, Done ends it, and the menu entry
//  reads "Hide Deviation Preview" while it is on. Also the Accuracy Report
//  sheet's "Show Deviation in Viewport" row, which closes the sheet and
//  opens the same preview.
//

import XCTest

final class DeviationPreviewUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_PAIR"] = "1"   // a 20 mm box inside a 24 mm one
        app.launch()
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 20))
        return app
    }

    private func openViewsMenu(_ app: XCUIApplication) {
        let views = app.buttons["ViewsMenu"]
        XCTAssertTrue(views.waitForExistence(timeout: 10))
        views.tap()
    }

    func testViewsMenuTurnsThePreviewOnAndDoneEndsIt() throws {
        let app = launch()
        openViewsMenu(app)
        let entry = app.buttons["DeviationPreviewButton"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "two bodies make the entry available")
        entry.tap()

        let legend = app.descendants(matching: .any)["DeviationLegend"]
        XCTAssertTrue(legend.waitForExistence(timeout: 5), "the legend shows while the app measures")
        let done = app.buttons["DeviationDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the numbers arrive and Done appears")
        let stats = app.staticTexts["DeviationStats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        XCTAssertTrue(stats.label.contains("within tolerance"), "the legend carries the numbers: \(stats.label)")

        openViewsMenu(app)
        let hide = app.buttons["DeviationPreviewButton"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        XCTAssertEqual(hide.label, "Hide Deviation Preview", "the entry reads as a toggle while the preview is on")
        // Close the menu without choosing; Done is the way out under test.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()

        done.tap()
        XCTAssertTrue(legend.waitForNonExistence(timeout: 5), "Done ends the preview")
    }

    func testAccuracyReportSheetRowOpensThePreview() throws {
        let app = launch()
        openViewsMenu(app)
        let report = app.buttons["AccuracyReportButton"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        report.tap()

        let compare = app.buttons["AccuracyCompareButton"]
        XCTAssertTrue(compare.waitForExistence(timeout: 10), "the sheet picks the two boxes by default")
        compare.tap()
        let row = app.buttons["AccuracyShowDeviationButton"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the row appears with the results")
        row.tap()

        let done = app.buttons["DeviationDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the sheet closes and the preview opens")
        XCTAssertFalse(app.navigationBars["Accuracy Report"].exists, "the sheet is gone")
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["DeviationLegend"].waitForNonExistence(timeout: 5))
    }
}
