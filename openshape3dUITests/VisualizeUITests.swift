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

        // Faces: a tap picks the face under it, and a material dresses just that face.
        app.segmentedControls["VisualizeApplyTo"].buttons["Faces"].tap()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 3), "switching to faces clears the pick")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["1 face selected"].waitForExistence(timeout: 3))
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "rubber")
        let rubber = app.buttons["Material_Rubber"]
        XCTAssertTrue(rubber.waitForExistence(timeout: 3))
        rubber.tap()
        XCTAssertTrue(app.buttons["UsedMaterial_Rubber"].waitForExistence(timeout: 3), "the face wears it")
        XCTAssertTrue(app.buttons["UsedMaterial_Copper"].exists, "the rest of the box keeps copper")
        let faced = XCTAttachment(screenshot: app.screenshot())
        faced.name = "visualize-face-material"; faced.lifetime = .keepAlways; add(faced)
        // A see-through material on the face: the box shows through it.
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "tinted")
        let glass = app.buttons["Material_Tinted Glass"]
        XCTAssertTrue(glass.waitForExistence(timeout: 3))
        glass.tap()
        XCTAssertTrue(app.buttons["UsedMaterial_Tinted Glass"].waitForExistence(timeout: 3), "the face wears glass")
        let glassed = XCTAttachment(screenshot: app.screenshot())
        glassed.name = "visualize-glass-face"; glassed.lifetime = .keepAlways; add(glassed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.25)).tap()
        XCTAssertTrue(app.staticTexts["1 face selected"].waitForNonExistence(timeout: 3), "empty space clears the pick")
        let clean = XCTAttachment(screenshot: app.screenshot())
        clean.name = "visualize-face-material-unpicked"; clean.lifetime = .keepAlways; add(clean)
        app.segmentedControls["VisualizeApplyTo"].buttons["Bodies"].tap()

        app.buttons["Environment"].tap()
        let sunset = app.buttons["Environment_Sunset"]
        XCTAssertTrue(sunset.waitForExistence(timeout: 3))
        sunset.tap()
        XCTAssertTrue(sunset.isSelected)
        XCTAssertTrue(app.sliders["EnvironmentElevation"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "visualize-sunset"; shot.lifetime = .keepAlways; add(shot)

        // Depth of field: on, then focused on a point picked on the box.
        let dof = app.switches["EnvironmentDepthOfField"]
        for _ in 0..<4 where !dof.isHittable {
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(dof.isHittable, "\(dof.frame) in \(panel.frame)")
        dof.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.sliders["EnvironmentBlur"].waitForExistence(timeout: 3), "depth of field brings its blur")
        app.buttons["EnvironmentFocusPick"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["EnvironmentFocusReset"].waitForExistence(timeout: 3), "the tap set a focus point")
        let blurred = XCTAttachment(screenshot: app.screenshot())
        blurred.name = "visualize-depth-of-field"; blurred.lifetime = .keepAlways; add(blurred)

        app.buttons["VisualizeDone"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }
}
