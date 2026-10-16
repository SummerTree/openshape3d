//
//  MaterialPatternUITests.swift
//  openshape3dUITests
//
//  Texture mapping (spec §14): library materials with a pattern — wood
//  grain, carbon fibre, knurl, marble — dress the seeded box (screenshots
//  for review), and the Material sheet shows the pattern with its size.
//

import XCTest

final class MaterialPatternUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPatternedMaterialsDressTheBox() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_HOLE"] = "1"   // a 10 mm block with a hole
        app.launch()

        let visualize = app.buttons["VisualizeButton"]
        XCTAssertTrue(visualize.waitForExistence(timeout: 10))
        visualize.tap()
        let block = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        block.tap()
        let search = app.textFields["MaterialSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        var typed = 0
        for (query, name) in [("oak", "Oak"), ("carbon", "Carbon Fibre"), ("knurl", "Knurled Steel"), ("marble", "Marble")] {
            search.tap()
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed) + query)
            typed = query.count
            let material = app.buttons["Material_\(name)"]
            XCTAssertTrue(material.waitForExistence(timeout: 3), name)
            material.tap()
            XCTAssertTrue(app.buttons["UsedMaterial_\(name)"].waitForExistence(timeout: 3), name)
            // Unselected — switching to Faces clears the pick — so the pattern
            // shows without the selection tint.
            app.segmentedControls["VisualizeApplyTo"].buttons["Faces"].tap()
            XCTAssertTrue(app.buttons["VisualizeEditMaterial"].waitForNonExistence(timeout: 3), "deselected")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "pattern-\(query)"; shot.lifetime = .keepAlways; add(shot)
            app.segmentedControls["VisualizeApplyTo"].buttons["Bodies"].tap()
            block.tap()
        }

        // The sheet shows the pattern and its size.
        app.buttons["VisualizeEditMaterial"].tap()
        XCTAssertTrue(app.buttons["MaterialApply"].waitForExistence(timeout: 5))
        let size = app.sliders["MaterialPatternSize"]
        for _ in 0..<6 where !size.exists { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(size.waitForExistence(timeout: 3), "Marble's pattern shows with its size")
        XCTAssertTrue(app.descendants(matching: .any)["MaterialPatternPicker"].exists)
        app.buttons["MaterialCancel"].tap()
    }

    /// Texture Mapping ▸ Image: a picture of your own on the block, from its
    /// sides — Apply waits for the picture.
    func testAnImageDressesTheBox() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_HOLE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_MATERIAL_IMAGE"] = "1"
        app.launch()

        let visualize = app.buttons["VisualizeButton"]
        XCTAssertTrue(visualize.waitForExistence(timeout: 10))
        visualize.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        let edit = app.buttons["VisualizeEditMaterial"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.buttons["MaterialApply"].waitForExistence(timeout: 5))
        let picker = app.descendants(matching: .any)["MaterialPatternPicker"]
        for _ in 0..<6 where !picker.isHittable { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
        picker.tap()
        let imageOption = app.buttons["Image"]
        XCTAssertTrue(imageOption.waitForExistence(timeout: 3))
        imageOption.tap()
        XCTAssertFalse(app.buttons["MaterialApply"].isEnabled, "nothing to lay on yet")

        let choose = app.buttons["Choose Image…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        choose.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 3))
        app.buttons["Photos"].tap()
        XCTAssertTrue(app.images["MaterialImagePreview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["MaterialApply"].isEnabled)
        app.buttons["MaterialApply"].tap()

        app.segmentedControls["VisualizeApplyTo"].buttons["Faces"].tap()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 3), "deselected")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "pattern-image"; shot.lifetime = .keepAlways; add(shot)
    }
}
