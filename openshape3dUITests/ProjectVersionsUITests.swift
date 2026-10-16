//
//  ProjectVersionsUITests.swift
//  openshape3dUITests
//
//  Project Versions (spec §13.3): a design with a box is kept as version 1
//  when it opens; deleting the box and leaving keeps version 2; the gallery's
//  Versions… lists both, and Restore as Latest brings the box back — keeping
//  the empty design as a version first.
//

import XCTest

final class ProjectVersionsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testVersionsAreKeptAndRestored() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"   // a box, selected
        app.launch()

        let delete = app.buttons["DeleteButton"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        app.buttons["Designs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Untitled"].waitForExistence(timeout: 5))

        func openVersions() {
            app.staticTexts["Untitled"].press(forDuration: 1.0)
            let item = app.buttons["Versions…"]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "the design's menu offers Versions…")
            item.tap()
        }
        openVersions()
        let latest = app.descendants(matching: .any)["ProjectVersion_2"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "leaving after an edit kept version 2")
        XCTAssertTrue(latest.staticTexts["0 bodies"].exists, "\(latest.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["ProjectVersion_1"].staticTexts["1 body"].exists,
                      "opening the design kept version 1, with its box")
        XCTAssertFalse(app.buttons["ProjectVersionRestore_2"].exists, "the latest has nothing to restore")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "project-versions"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["ProjectVersionRestore_1"].tap()
        XCTAssertTrue(app.staticTexts["Untitled"].waitForExistence(timeout: 5), "the restored design keeps its name")
        openVersions()
        let restored = app.descendants(matching: .any)["ProjectVersion_4"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.staticTexts["Restored from version 1 · 1 body"].exists, "\(restored.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["ProjectVersion_3"]
            .staticTexts["Before restoring version 1 · 0 bodies"].exists, "the empty design was kept first")
        app.buttons["ProjectVersionsDone"].tap()

        // The design opens with its box again (the restored version's own
        // body: the seed only fills an empty design).
        app.staticTexts["Untitled"].tap()
        XCTAssertTrue(app.buttons["DeleteButton"].waitForExistence(timeout: 10))
        sleep(2)
        let reopened = XCTAttachment(screenshot: app.screenshot())
        reopened.name = "project-versions-restored"; reopened.lifetime = .keepAlways; add(reopened)
    }

    /// Export ▸ Save Version… keeps the design under a name; the gallery's
    /// Versions… shows it by that name and can rename it.
    func testSaveVersionNamesItAndVersionsCanBeRenamed() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["ExportMenu"].waitForExistence(timeout: 10))
        sleep(2) // version 1, on opening
        app.buttons["ExportMenu"].tap()
        let save = app.buttons["SaveVersionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        // An alert's field and buttons go by the alert, not their identifiers.
        let alert = app.alerts["Save Version"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let name = alert.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Before the fillets")
        alert.buttons["Save"].firstMatch.tap()
        let notice = app.staticTexts["VersionSavedNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertEqual(notice.label, "Saved as “Before the fillets”")

        app.buttons["Designs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Untitled"].waitForExistence(timeout: 5))
        app.staticTexts["Untitled"].press(forDuration: 1.0)
        app.buttons["Versions…"].tap()
        // The named one: version 1 when nothing changed since it opened,
        // else a new version 2.
        let title = app.staticTexts["Before the fillets"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let number = title.identifier.replacingOccurrences(of: "ProjectVersionTitle_", with: "")
        XCTAssertTrue(app.descendants(matching: .any)["ProjectVersion_\(number)"]
            .staticTexts["Version \(number) · 1 body"].exists)

        app.buttons["ProjectVersionName_\(number)"].tap()
        let rename = app.alerts["Name Version"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        let field = rename.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "Before the fillets")
        // The alert's field has the keyboard: clear it and type the new name.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Ready to print")
        rename.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Ready to print"].waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "project-versions-named"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["ProjectVersionsDone"].tap()
    }
}
