//
//  SectionDisplayUITests.swift
//  openshape3dUITests
//
//  Section View + Display modes (plan §B11/§B12, spec §16): the Views menu
//  switches shaders (the submenu labels the active one) with the model still
//  selectable afterwards, and Section View arms via the plane tiles with
//  Flip/Off badges restoring the full model. Screenshot-free assertions:
//  menu labels, badges, and status pills only.
//

import XCTest

final class SectionDisplayUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testXRayDisplayModeTogglesAndBoxStaysSelectable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()

        let window = app.windows.firstMatch
        let viewsButton = app.buttons["ViewsMenu"]
        XCTAssertTrue(viewsButton.waitForExistence(timeout: 10))
        sleep(1) // camera fit settles

        // Views → Display: Shaded → X-Ray.
        viewsButton.tap()
        let displayShaded = app.buttons["Display: Shaded"]
        XCTAssertTrue(displayShaded.waitForExistence(timeout: 3),
                      "The Display submenu should label the active shader")
        displayShaded.tap()
        let xray = app.buttons["X-Ray"]
        XCTAssertTrue(xray.waitForExistence(timeout: 3))
        xray.tap()

        // Menu state reflects the switch — the submenu is labeled X-Ray now.
        viewsButton.tap()
        let displayXRay = app.buttons["Display: X-Ray"]
        XCTAssertTrue(displayXRay.waitForExistence(timeout: 3),
                      "Switching shaders should relabel the Display submenu")
        // Show Hidden Edges lives in the same submenu (menu Toggles can
        // surface as buttons or switches — match either).
        displayXRay.tap()
        let hiddenEdges = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Show Hidden Edges'")).firstMatch
        XCTAssertTrue(hiddenEdges.waitForExistence(timeout: 3))
        hiddenEdges.tap()

        // The seeded box must stay tappable in X-Ray: deselect, then tap its
        // top face (same coordinates PlanesUITests uses for this seed).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        sleep(1) // stay clear of the double-tap window
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(
            app.staticTexts["Face selected — drag it to push or pull"]
                .waitForExistence(timeout: 3),
            "Bodies must remain selectable in X-Ray display mode"
        )

        // Back to Shaded for good measure — the label follows.
        app.buttons["Done"].firstMatch.tap() // commit-free exit of face mode
        viewsButton.tap()
        XCTAssertTrue(app.buttons["Display: X-Ray"].waitForExistence(timeout: 3))
        app.buttons["Display: X-Ray"].tap()
        let shaded = app.buttons["Shaded"]
        XCTAssertTrue(shaded.waitForExistence(timeout: 3))
        shaded.tap()
        viewsButton.tap()
        XCTAssertTrue(app.buttons["Display: Shaded"].waitForExistence(timeout: 3))
        // Close the menu without acting.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
    }

    func testSectionViaZXTileThenFlipOffAndCancel() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()

        let window = app.windows.firstMatch
        let viewsButton = app.buttons["ViewsMenu"]
        XCTAssertTrue(viewsButton.waitForExistence(timeout: 10))

        // Views → Section arms the plane picker.
        viewsButton.tap()
        let sectionButton = app.buttons["Section"]
        XCTAssertTrue(sectionButton.waitForExistence(timeout: 3))
        sectionButton.tap()
        XCTAssertTrue(app.staticTexts["Choose a section plane"].waitForExistence(timeout: 3))

        // The ZX (ground) tile center projects here under the default camera
        // (world (1.3, 0, -1.3); same projection math as the plane tests).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.77, dy: 0.49)).tap()

        // Section active: picker pill gone, Flip/Off badges up.
        let flip = app.buttons["SectionFlip"]
        XCTAssertTrue(flip.waitForExistence(timeout: 3),
                      "Picking the ZX tile should activate the section")
        XCTAssertFalse(app.staticTexts["Choose a section plane"].exists)
        flip.tap() // flip keeps the badges up

        // The Views menu now reflects the active section.
        viewsButton.tap()
        XCTAssertTrue(app.buttons["Flip Section"].waitForExistence(timeout: 3),
                      "The Views menu should offer Flip/Off while sectioned")
        app.buttons["Flip Section"].tap()

        // Section Off restores the full model (badges disappear).
        let off = app.buttons["SectionOff"]
        XCTAssertTrue(off.waitForExistence(timeout: 3))
        off.tap()
        XCTAssertFalse(flip.exists, "Section Off should drop the section badges")

        // Cancel path: re-arm the picker and cancel — no section appears.
        viewsButton.tap()
        XCTAssertTrue(sectionButton.waitForExistence(timeout: 3),
                      "With the section off the menu offers Section again")
        sectionButton.tap()
        XCTAssertTrue(app.staticTexts["Choose a section plane"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Choose a section plane"].exists)
        XCTAssertFalse(flip.exists)
    }
}
