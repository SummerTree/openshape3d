//
//  DrawingUITests.swift
//  openshape3dUITests
//
//  File ▸ New Drawing (spec §15): the Export menu's Drawing… opens a live
//  sheet of the model's views; the options change it and Export offers the
//  file formats.
//

import XCTest

final class DrawingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testDrawingSheetPreviewsAndExports() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_HOLE"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["ExportMenu"].waitForExistence(timeout: 10))
        app.buttons["ExportMenu"].tap()
        XCTAssertTrue(app.buttons["NewDrawingButton"].waitForExistence(timeout: 3))
        app.buttons["NewDrawingButton"].tap()

        let preview = app.descendants(matching: .any)["DrawingPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.hasPrefix("Drawing at "), "a drawn sheet, not an empty one: \(preview.label)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "drawing-sheet"; shot.lifetime = .keepAlways; add(shot)

        // Turning the isometric off keeps a drawn sheet.
        let iso = app.switches["DrawingIsometricToggle"]
        XCTAssertTrue(iso.waitForExistence(timeout: 3))
        for _ in 0..<4 where !iso.isHittable {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(iso.isHittable)
        iso.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(preview.label.hasPrefix("Drawing at "))

        app.buttons["DrawingExportMenu"].tap()
        for format in ["PDF", "SVG", "DXF"] {
            XCTAssertTrue(app.buttons["DrawingExport\(format)"].waitForExistence(timeout: 3), format)
        }
        app.buttons["DrawingExportPDF"].tap()
        // The save panel opens over the sheet.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "the save panel opens")
        cancel.tap()
        app.buttons["DrawingDone"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
    }

    /// Drawings v2: section and detail views appear on the sheet, and the
    /// drawing is kept in the design — reopening it brings them back.
    func testSectionAndDetailViewsAreSavedWithTheDrawing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_HOLE"] = "1"
        app.launch()

        func openDrawing() {
            XCTAssertTrue(app.buttons["ExportMenu"].waitForExistence(timeout: 10))
            app.buttons["ExportMenu"].tap()
            XCTAssertTrue(app.buttons["NewDrawingButton"].waitForExistence(timeout: 3))
            app.buttons["NewDrawingButton"].tap()
        }
        func reveal(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            for _ in 0..<8 where !element.isHittable {
                app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(element.isHittable)
        }

        openDrawing()
        let preview = app.descendants(matching: .any)["DrawingPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(preview.value as? String, "4 views", "Front, Top, Right, Isometric")

        let addSection = app.buttons["DrawingAddSection"]
        reveal(addSection)
        addSection.tap()
        let addDetail = app.buttons["DrawingAddDetail"]
        reveal(addDetail)
        addDetail.tap()
        XCTAssertEqual(preview.value as? String, "6 views", "plus Section A-A and Detail B")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "drawing-section-detail"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["DrawingDone"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))

        // Export ▸ Drawing… reopens the same drawing, views and all.
        openDrawing()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(preview.value as? String, "6 views")
        app.buttons["DrawingDone"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
    }
}
