//
//  ClipboardUITests.swift
//  openshape3dUITests
//
//  Edit ▸ Copy / Paste / Cut on a hardware keyboard: ⌘C then ⌘V adds a copy
//  of the selected body (one undo step), and ⌘X removes it while keeping it
//  on the clipboard.
//

import XCTest

final class ClipboardUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func bodyRows(_ app: XCUIApplication) -> Int {
        app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'ItemName-'")).count
            + app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ItemName-'")).count
    }

    func testCopyPasteAndCutBodies() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"   // a 4 mm box, selected
        app.launch()
        XCTAssertTrue(app.staticTexts["Volume"].waitForExistence(timeout: 10), "The seeded box arrives selected")

        app.buttons["ItemsButton"].tap()
        XCTAssertTrue(app.staticTexts["Bodies"].waitForExistence(timeout: 3))
        let before = bodyRows(app)
        XCTAssertGreaterThanOrEqual(before, 1)

        app.typeKey("c", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitFor { self.bodyRows(app) == before + 1 }, "⌘C ⌘V adds a copy of the body")

        app.buttons["UndoButton"].tap()
        XCTAssertTrue(waitFor { self.bodyRows(app) == before }, "Paste is one undo step")

        // Undo left nothing selected: select the box from Items, cut it, then
        // paste it back.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ItemName-'")).firstMatch
        row.tap()
        XCTAssertTrue(app.staticTexts["Volume"].waitForExistence(timeout: 3), "Tapping the row selects the body")
        app.typeKey("x", modifierFlags: .command)
        XCTAssertTrue(waitFor { self.bodyRows(app) == before - 1 }, "⌘X removes the body")
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitFor { self.bodyRows(app) == before }, "…and it is still on the clipboard")
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return condition()
    }
}
