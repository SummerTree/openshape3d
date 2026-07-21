//
//  BlendUITests.swift
//  openshape3dUITests
//
//  Phase E tranche 1: drive Chamfer/Fillet end to end — extrude a box, arm the
//  tool, tap an edge, Apply, and verify a healthy feature lands in History.
//

import XCTest

final class BlendUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Extrude a plain rectangle on the ground into a box, then view isometric.
    private func extrudeBox(_ app: XCUIApplication, _ window: XCUIElement) {
        func p(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }
        startSketchTool(app, "Rect")
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        p(0.80, 0.78).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2)
        p(0.32, 0.32).press(forDuration: 0.15, thenDragTo: p(0.68, 0.62))
        app.buttons["Exit Sketching"].tap(); sleep(1)
        p(0.45, 0.45).tap()   // arm extrude on the region
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))
        app.buttons["Extrude"].firstMatch.tap(); sleep(1)
        app.buttons["ViewsMenu"].tap()
        app.buttons["Isometric"].tap(); sleep(2)
    }

    func testChamferAnEdgeRecordsHealthyFeature() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))

        extrudeBox(app, window)
        shot("01-box")

        // Arm Chamfer from the Modify group.
        tapPaletteTool(app, group: "Modify", id: "ChamferButton")
        XCTAssertTrue(app.buttons["BlendApply"].waitForExistence(timeout: 3),
                      "the blend bar should appear")
        shot("02-chamfer-armed")

        // Tap the body to pick the nearest edge; Apply enables once an edge is in.
        func p(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }
        let apply = app.buttons["BlendApply"]
        for pt in [(0.5, 0.42), (0.5, 0.5), (0.55, 0.45), (0.45, 0.55)] {
            p(CGFloat(pt.0), CGFloat(pt.1)).tap()
            sleep(1)
            if apply.isEnabled { break }
        }
        XCTAssertTrue(apply.isEnabled, "tapping the body should select an edge and enable Apply")
        shot("03-edge-selected")

        apply.tap(); sleep(2)
        shot("04-after-chamfer")

        // History has a healthy Chamfer feature (no error badge).
        app.buttons["HistoryButton"].firstMatch.tap(); sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryRow-Chamfer'"))
            .firstMatch.waitForExistence(timeout: 3),
            "a Chamfer feature should be recorded")
        let errors = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryError-'"))
        NSLog("OS3D_BUG chamfer errorBadges=\(errors.count)")
        XCTAssertEqual(errors.count, 0, "the chamfer must evaluate cleanly")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
    }

    func testFilletAnEdgeRecordsHealthyFeature() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))

        extrudeBox(app, window)

        tapPaletteTool(app, group: "Modify", id: "FilletButton")
        XCTAssertTrue(app.buttons["BlendApply"].waitForExistence(timeout: 3),
                      "the blend bar should appear for fillet")

        func p(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }
        let apply = app.buttons["BlendApply"]
        for pt in [(0.5, 0.42), (0.5, 0.5), (0.55, 0.45), (0.45, 0.55)] {
            p(CGFloat(pt.0), CGFloat(pt.1)).tap()
            sleep(1)
            if apply.isEnabled { break }
        }
        XCTAssertTrue(apply.isEnabled, "tapping the body should select an edge")
        apply.tap(); sleep(2)
        shot("fillet-after")

        app.buttons["HistoryButton"].firstMatch.tap(); sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryRow-Fillet'"))
            .firstMatch.waitForExistence(timeout: 3),
            "a Fillet feature should be recorded")
        let errors = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryError-'"))
        NSLog("OS3D_BUG fillet errorBadges=\(errors.count)")
        XCTAssertEqual(errors.count, 0, "the fillet must evaluate cleanly")
    }
}
