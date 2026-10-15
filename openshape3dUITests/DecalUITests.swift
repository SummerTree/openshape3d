//
//  DecalUITests.swift
//  openshape3dUITests
//
//  Visualize ▸ Decals (spec §14): Add Decal waits for a tap, the tap puts
//  the image on the box, the decal is listed with its sliders, and Remove
//  takes it off. OS3D_DEBUG_DECAL stands in a test image for the picker.
//

import XCTest

final class DecalUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testADecalIsPlacedResizedAndRemoved() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"   // a box
        app.launchEnvironment["OS3D_DEBUG_DECAL"] = "1"
        app.launch()

        let visualize = app.buttons["VisualizeButton"]
        XCTAssertTrue(visualize.waitForExistence(timeout: 10))
        visualize.tap()
        app.segmentedControls["VisualizeTab"].buttons["Decals"].tap()
        let addDecal = app.buttons["DecalAdd"]
        XCTAssertTrue(addDecal.waitForExistence(timeout: 3))
        addDecal.tap()
        let files = app.buttons["From Files…"]
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        files.tap()
        XCTAssertTrue(app.staticTexts["DecalHint"].waitForExistence(timeout: 3), "it waits for a tap on the model")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        let row = app.descendants(matching: .any)["Decal_Test Decal"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the tap placed it")
        XCTAssertFalse(app.staticTexts["DecalHint"].exists)
        let size = app.sliders["DecalSize"]
        XCTAssertTrue(size.waitForExistence(timeout: 3), "a new decal starts selected, sliders out")
        size.adjust(toNormalizedSliderPosition: 0.45)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "decal-on-box"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["DecalRemove"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        app.buttons["VisualizeDone"].tap()
    }
}
