//
//  SettingsUITests.swift
//  openshape3dUITests
//
//  Phase F tranche 1: the Settings sheet exists and switching the display
//  unit re-renders the selection info bar live (mm³ → in³ and back).
//

import XCTest

final class SettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Extrude a rectangle into a box and select it, so the info bar shows
    /// Volume/Bounds rows with unit readouts.
    private func makeAndSelectBox(_ app: XCUIApplication, _ window: XCUIElement) {
        func p(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }
        startSketchTool(app, "Rect")
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        p(0.80, 0.78).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2)
        lookAtSketch(app)
        p(0.32, 0.32).press(forDuration: 0.15, thenDragTo: p(0.68, 0.62))
        app.buttons["Exit Sketching"].tap(); sleep(1)
        p(0.45, 0.45).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))
        typeExtrudeHeight(app); sleep(1)
        p(0.5, 0.5).doubleTap(); sleep(1)
    }

    func testUnitSwitchRelabelsInfoBarLive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))

        makeAndSelectBox(app, window)

        func hasUnitText(_ suffix: String) -> Bool {
            app.staticTexts.matching(
                NSPredicate(format: "label ENDSWITH %@", suffix)
            ).firstMatch.waitForExistence(timeout: 3)
        }

        // Settings persist across runs on the same simulator — normalize to
        // mm through the UI first, then flip to inches, then restore.
        func setUnit(_ symbol: String) {
            app.buttons["SettingsButton"].tap()
            XCTAssertTrue(app.buttons["SettingsDone"].waitForExistence(timeout: 3))
            app.buttons[symbol].firstMatch.tap()
            app.buttons["SettingsDone"].tap()
            sleep(1)
        }

        setUnit("mm")
        XCTAssertTrue(hasUnitText("mm³"), "volume row shows mm³ in millimetres")

        setUnit("in")
        XCTAssertTrue(hasUnitText("in³"), "volume row re-renders to in³ live")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'mm³'"))
                .firstMatch.exists,
            "no stale mm³ readout remains")

        setUnit("mm")
        XCTAssertTrue(hasUnitText("mm³"), "switching back restores mm³")
    }
}
