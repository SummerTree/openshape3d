//
//  CommandSearchUITests.swift
//  openshape3dUITests
//
//  The Command Search launcher (spec §8.4) end to end.
//
//  Driven through the toolbar button rather than the X / ⌘F chords on purpose:
//  `typeKey` sends a hardware key that the app may or may not be idle for, and
//  a hotkey test once turned a 41-minute suite into a 78-minute one while
//  still reporting green (the ⌘A trap). The button is also the affordance most
//  users have — an iPad without a keyboard has no chord to press.
//

import XCTest

final class CommandSearchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["CommandSearchButton"].waitForExistence(timeout: 15))
        return app
    }

    private func openLauncher(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["CommandSearchButton"].tap()
        let field = app.textFields["CommandSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the launcher panel should open")
        return field
    }

    /// The headline path: search, choose, and the tool is armed.
    func testSearchingForFilletArmsTheTool() throws {
        let app = launch()
        let field = openLauncher(app)

        field.typeText("fil")
        let result = app.otherElements["CommandResult-Fillet"]
        XCTAssertTrue(result.waitForExistence(timeout: 5),
                      "“fil” should fuzzy-match Fillet")

        result.tap()
        XCTAssertTrue(app.buttons["BlendApply"].waitForExistence(timeout: 5),
                      "choosing Fillet should arm the blend tool")
        XCTAssertFalse(app.textFields["CommandSearchField"].exists,
                       "…and close the launcher")
    }

    /// A command that is real but not applicable keeps the panel OPEN and says
    /// why. Closing on a keystroke that did nothing is what makes a launcher
    /// feel broken — and Circle needs an open sketch, which the seed has not.
    func testAnUnavailableCommandExplainsItselfAndKeepsThePanelOpen() throws {
        let app = launch()
        let field = openLauncher(app)

        field.typeText("circ")
        let circle = app.otherElements["CommandResult-Circle"]
        XCTAssertTrue(circle.waitForExistence(timeout: 5))
        circle.tap()

        XCTAssertTrue(app.staticTexts["CommandSearchRefusal"].waitForExistence(timeout: 5),
                      "the refusal has to be visible, not silent")
        XCTAssertTrue(app.textFields["CommandSearchField"].exists,
                      "the panel stays up so another command can be chosen")
    }

    /// The launcher must never offer a command it cannot run. "Import as New
    /// Project" is in the catalog with a chord and has no editor entry point,
    /// so it must not appear — a result that does nothing when chosen is worse
    /// than one that is absent.
    func testUnroutableCatalogEntriesAreNotOffered() throws {
        let app = launch()
        let field = openLauncher(app)

        field.typeText("import")
        XCTAssertFalse(app.otherElements["CommandResult-Import as New Project"]
            .waitForExistence(timeout: 2),
                       "unroutable commands must stay out of the launcher")
        XCTAssertTrue(app.staticTexts["CommandSearchEmpty"].exists,
                      "…and the panel should say nothing matched")
    }

    /// Tapping outside closes it, which is the gesture people try first.
    func testTappingTheScrimDismisses() throws {
        let app = launch()
        _ = openLauncher(app)

        app.otherElements["CommandSearchScrim"].tap()
        XCTAssertTrue(app.textFields["CommandSearchField"].waitForNonExistence(timeout: 5))
    }
}
