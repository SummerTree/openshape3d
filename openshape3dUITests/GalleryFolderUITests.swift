//
//  GalleryFolderUITests.swift
//  openshape3dUITests
//
//  Project folders (spec §13.1): create a folder, open it, create a design
//  inside, breadcrumbs and Back, move a design in via "Move to Folder…",
//  nested folder from the sidebar, and delete with its confirmation.
//

import XCTest

final class GalleryFolderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// Fill the alert's text field and confirm.
    private func fillAlert(_ app: XCUIApplication, title: String, text: String, confirm: String) {
        let alert = app.alerts[title]
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "\(title) alert should appear")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        // Clear the prefilled name, then type ours.
        let existing = ((field.value as? String) ?? "").count + 2
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing))
        field.typeText(text)
        alert.buttons[confirm].tap()
    }

    func testCreateOpenMoveAndDeleteFolder() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()

        // OS3D_FRESH opens a new design ("Untitled") at the root; go back.
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        app.buttons["Designs"].firstMatch.tap()
        XCTAssertTrue(app.buttons["NewFolderButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Untitled"].waitForExistence(timeout: 3))

        // Sidebar is up on the iPad's regular width.
        XCTAssertTrue(app.buttons["SidebarRoot"].exists, "The folder sidebar should show")

        // New Folder → "Brackets" appears as a card and in the sidebar.
        app.buttons["NewFolderButton"].tap()
        fillAlert(app, title: "New Folder", text: "Brackets", confirm: "Create")
        XCTAssertTrue(app.buttons["FolderCard-Brackets"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["SidebarFolder-Brackets"].exists)

        // Open it: empty-folder state, breadcrumbs, title.
        app.buttons["FolderCard-Brackets"].tap()
        XCTAssertTrue(app.staticTexts["Empty Folder"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Crumb-Designs"].exists)
        XCTAssertTrue(app.navigationBars["Brackets"].exists)
        XCTAssertFalse(app.staticTexts["Untitled"].exists,
                       "A root design is not listed inside the folder")

        // A design created here lands in the folder.
        app.buttons["New Design"].firstMatch.tap()
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        app.buttons["Brackets"].firstMatch.tap() // back button carries the folder's name
        XCTAssertTrue(app.staticTexts["Untitled 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Brackets"].exists, "Leaving the editor returns to the folder")

        // Breadcrumb root → back at Designs; the folder card counts 1 design.
        app.buttons["Crumb-Designs"].tap()
        XCTAssertTrue(app.staticTexts["Untitled"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Untitled 2"].exists)
        XCTAssertTrue(app.staticTexts["1 design"].exists)

        // Back / Forward history (⌘[ / ⌘]).
        let back = app.buttons["GalleryBackButton"]
        XCTAssertTrue(back.isEnabled)
        back.tap()
        XCTAssertTrue(app.navigationBars["Brackets"].waitForExistence(timeout: 3))
        app.buttons["GalleryForwardButton"].tap()
        XCTAssertTrue(app.navigationBars["Designs"].waitForExistence(timeout: 3))

        // Move "Untitled" into Brackets from its context menu.
        let card = app.staticTexts["Untitled"]
        card.press(forDuration: 1.0)
        let moveItem = app.buttons["Move to Folder…"]
        XCTAssertTrue(moveItem.waitForExistence(timeout: 3), "Card context menu should show Move")
        moveItem.tap()
        let pick = app.buttons["MovePick-Brackets"]
        XCTAssertTrue(pick.waitForExistence(timeout: 3))
        pick.tap()
        XCTAssertFalse(app.staticTexts["Untitled"].waitForExistence(timeout: 2),
                       "The moved design leaves the root")
        XCTAssertTrue(app.staticTexts["2 designs"].exists)

        // Nested folder from the sidebar row's context menu.
        app.buttons["SidebarFolder-Brackets"].press(forDuration: 1.0)
        let nested = app.buttons["New Folder Inside"]
        XCTAssertTrue(nested.waitForExistence(timeout: 3))
        nested.tap()
        fillAlert(app, title: "New Folder", text: "Steel", confirm: "Create")
        XCTAssertTrue(app.buttons["SidebarFolder-Steel"].waitForExistence(timeout: 3),
                      "The parent expands to show the new subfolder")
        app.buttons["SidebarFolder-Steel"].tap()
        XCTAssertTrue(app.navigationBars["Steel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Crumb-Brackets"].exists, "Breadcrumbs show the parent")

        // Delete Brackets (and everything in it) from the sidebar; land at the root.
        app.buttons["SidebarFolder-Brackets"].press(forDuration: 1.0)
        let deleteItem = app.buttons["Delete"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3))
        deleteItem.tap()
        let confirm = app.alerts["Delete “Brackets”?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.staticTexts.element(matching: NSPredicate(
            format: "label CONTAINS '2 designs' AND label CONTAINS '1 subfolder'")).exists,
            "The confirmation spells out what goes with the folder")
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(app.navigationBars["Designs"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["FolderCard-Brackets"].exists)
        XCTAssertFalse(app.buttons["SidebarFolder-Brackets"].exists)
        XCTAssertTrue(app.staticTexts["No Designs"].waitForExistence(timeout: 3),
                      "Both designs went with the folder")
    }
}
