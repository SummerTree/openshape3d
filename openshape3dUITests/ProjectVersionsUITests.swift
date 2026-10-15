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
}
