//
//  HistoryReorderUITests.swift
//  openshape3dUITests
//
//  Phase D tranche 6: drag-to-reorder history steps. Backend (MoveFeatureCommand
//  + graph re-eval + broken-ref surfacing) is unit-covered; this drives the
//  History-panel drag and verifies it commits without error.
//

import XCTest

final class HistoryReorderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Sketch a rectangle on the ground between two points and extrude the default.
    private func extrudeRect(_ app: XCUIApplication, _ window: XCUIElement,
                             from a: CGVector, to b: CGVector, tapInside: CGVector) {
        startSketchTool(app, "Rect")
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2)
        window.coordinate(withNormalizedOffset: a)
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: b))
        app.buttons["Exit Sketching"].tap(); sleep(1)
        window.coordinate(withNormalizedOffset: tapInside).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))
        app.buttons["Extrude"].firstMatch.tap(); sleep(1)
    }

    func testDragReorderTwoExtrudes() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))

        // Two independent extrudes → two history rows (both "Extrude").
        extrudeRect(app, window,
                    from: CGVector(dx: 0.30, dy: 0.40), to: CGVector(dx: 0.44, dy: 0.56),
                    tapInside: CGVector(dx: 0.37, dy: 0.48))
        extrudeRect(app, window,
                    from: CGVector(dx: 0.56, dy: 0.40), to: CGVector(dx: 0.70, dy: 0.56),
                    tapInside: CGVector(dx: 0.63, dy: 0.48))

        app.buttons["HistoryButton"].firstMatch.tap(); sleep(1)
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryRow-'"))
        XCTAssertEqual(rows.count, 2, "two extrudes → two history rows")
        let att0 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att0.name = "before-reorder"; att0.lifetime = .keepAlways; add(att0)

        // Drag the second row onto the first to reorder.
        let second = rows.element(boundBy: 1)
        let first = rows.element(boundBy: 0)
        second.press(forDuration: 1.0, thenDragTo: first)
        sleep(2)
        let att1 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att1.name = "after-reorder"; att1.lifetime = .keepAlways; add(att1)

        // The reorder committed and left both features healthy (no broken-ref badge).
        let errBadges = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryError-'"))
        NSLog("OS3D_BUG reorder errorBadges=\(errBadges.count) rows=\(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryRow-'")).count)")
        XCTAssertEqual(errBadges.count, 0, "reordering two independent extrudes must not break refs")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)

        // Undo restores; both extrudes survive the round-trip.
        app.buttons["Undo"].tap(); sleep(1)
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryRow-'")).count,
            2, "undoing the reorder keeps both features")
    }
}
