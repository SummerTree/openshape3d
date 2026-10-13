//
//  VisualizeUITests.swift
//  openshape3dUITests
//
//  Tools ▸ Visualize (spec §14): the toolbar opens the Visualization
//  panel, a library material lands on the selected body (and in Used
//  Materials), an environment preset is chosen, and Done leaves.
//

import XCTest

final class VisualizeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testVisualizePanelAppliesMaterialAndEnvironment() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"   // a box, selected
        app.launch()

        let visualize = app.buttons["VisualizeButton"]
        XCTAssertTrue(visualize.waitForExistence(timeout: 10))
        visualize.tap()
        let panel = app.descendants(matching: .any)["VisualizationPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        // Tapping empty space clears the selection; tapping the box selects
        // the whole body (not a face), ready to dress.
        let edit = app.buttons["VisualizeEditMaterial"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "the seeded box starts selected")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.85)).tap()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 3), "empty space deselects")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "the box is selected again")

        let search = app.textFields["MaterialSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("copper")
        let copper = app.buttons["Material_Copper"]
        XCTAssertTrue(copper.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Material_Steel"].exists, "search narrows the library")
        copper.tap()
        XCTAssertTrue(app.buttons["UsedMaterial_Copper"].waitForExistence(timeout: 3),
                      "the box wears it, so it is a used material")

        app.buttons["Environment"].tap()
        let sunset = app.buttons["Environment_Sunset"]
        XCTAssertTrue(sunset.waitForExistence(timeout: 3))
        sunset.tap()
        XCTAssertTrue(sunset.isSelected)
        XCTAssertTrue(app.sliders["EnvironmentElevation"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "visualize-sunset"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["VisualizeDone"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }
}
