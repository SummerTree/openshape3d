//
//  KeyboardShortcutsUITests.swift
//  openshape3dUITests
//
//  Settings ▸ Keyboard Shortcuts (spec §8.4), with a hardware keyboard:
//  record J for Command Search, and the editor answers J — not X — after.
//

import XCTest

final class KeyboardShortcutsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordedShortcutRunsTheCommand() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        // A clean slate whatever an earlier run stored.
        app.launchArguments += ["-os3d.keyboardShortcuts", "{}"]
        app.launch()
        XCTAssertTrue(app.buttons["SettingsButton"].waitForExistence(timeout: 15))

        app.buttons["SettingsButton"].tap()
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let link = app.descendants(matching: .any)["SettingsKeyboardShortcuts"]
        for _ in 0..<12 where !link.exists || !link.isHittable { form.swipeUp() }
        XCTAssertTrue(link.isHittable, "Settings ▸ Interface ▸ Keyboard Shortcuts")
        link.tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Command Search")
        let row = app.descendants(matching: .any)["Shortcut-app.commandSearch"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("X"), "ships as X: \(row.label)")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ShortcutRecording"].waitForExistence(timeout: 3))
        app.typeKey("j", modifierFlags: [])
        let rebound = NSPredicate(format: "label CONTAINS 'J' AND label CONTAINS 'Default: X'")
        expectation(for: rebound, evaluatedWith: row)
        waitForExpectations(timeout: 5)

        app.navigationBars["Keyboard Shortcuts"].buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["SettingsDone"].waitForExistence(timeout: 5))
        app.buttons["SettingsDone"].tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 5))

        app.typeKey("j", modifierFlags: [])
        let field = app.textFields["CommandSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "J now opens Command Search")
        app.buttons["CommandSearchClose"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        app.typeKey("x", modifierFlags: [])
        XCTAssertFalse(field.waitForExistence(timeout: 2), "X no longer does")
    }
}
