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

        // The detailed title block brings its fields.
        XCTAssertFalse(app.textFields["DrawingTitleField_company"].exists)
        let block = app.buttons["DrawingTitleBlockPicker"].firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        block.tap()
        XCTAssertTrue(app.buttons["Detailed"].waitForExistence(timeout: 3))
        app.buttons["Detailed"].tap()
        let company = app.textFields["DrawingTitleField_company"]
        XCTAssertTrue(company.waitForExistence(timeout: 3), "the company field")
        XCTAssertTrue(app.textFields["DrawingTitleField_partNumber"].exists)
        company.tap()
        company.typeText("Laan Labs\n")
        XCTAssertTrue(preview.label.hasPrefix("Drawing at "))
        let detailed = XCTAttachment(screenshot: app.screenshot())
        detailed.name = "drawing-title-block"; detailed.lifetime = .keepAlways; add(detailed)

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
            // The form loads its rows as they scroll in: swipe until it is there.
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
            for _ in 0..<12 where !(element.exists && element.isHittable) {
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

    /// Multiple sheets (spec §15): + under the preview adds a sheet with
    /// nothing placed on it yet; each sheet keeps its own views; the sheets
    /// are saved with the drawing; the extra sheet can be deleted.
    func testSheetsAreAddedSwitchedAndDeleted() throws {
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
            // The form loads its rows as they scroll in: swipe until it is there.
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
            for _ in 0..<12 where !(element.exists && element.isHittable) {
                app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(element.isHittable)
        }

        openDrawing()
        let preview = app.descendants(matching: .any)["DrawingPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let addSection = app.buttons["DrawingAddSection"]
        reveal(addSection)
        addSection.tap()
        XCTAssertEqual(preview.value as? String, "5 views", "sheet 1 has a section view")
        XCTAssertFalse(app.buttons["DrawingSheetTab_2"].exists)

        app.buttons["DrawingAddSheet"].tap()
        let second = app.buttons["DrawingSheetTab_2"]
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertTrue(second.isSelected, "the new sheet is shown")
        XCTAssertEqual(preview.value as? String, "4 views", "a new sheet has the standard views only")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "drawing-sheet-2"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["DrawingSheetTab_1"].tap()
        XCTAssertEqual(preview.value as? String, "5 views")
        app.buttons["DrawingDone"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))

        // Reopened, both sheets are there; sheet 2 goes again.
        openDrawing()
        XCTAssertTrue(second.waitForExistence(timeout: 10), "the sheets are saved with the drawing")
        second.tap()
        let delete = app.buttons["DrawingDeleteSheet"]
        app.collectionViews.firstMatch.swipeDown(velocity: .fast)
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 3))
        XCTAssertEqual(preview.value as? String, "5 views", "back on sheet 1")
        app.buttons["DrawingDone"].tap()
    }

    /// Custom title blocks (spec §15): a logo and a field of your own, saved
    /// as the default — the next design's first drawing starts with both.
    func testTitleBlockLogoFieldsAndDefault() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_HOLE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_DRAWING_LOGO"] = "1"
        app.launch()

        func openDrawing() {
            XCTAssertTrue(app.buttons["ExportMenu"].waitForExistence(timeout: 10))
            app.buttons["ExportMenu"].tap()
            XCTAssertTrue(app.buttons["NewDrawingButton"].waitForExistence(timeout: 3))
            app.buttons["NewDrawingButton"].tap()
        }
        func reveal(_ element: XCUIElement) {
            // The form loads its rows as they scroll in: swipe until it is there.
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
            for _ in 0..<12 where !(element.exists && element.isHittable) {
                app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(element.isHittable)
        }

        openDrawing()
        XCTAssertTrue(app.descendants(matching: .any)["DrawingPreview"].waitForExistence(timeout: 10))
        let addLogo = app.buttons["DrawingAddLogo"]
        reveal(addLogo)
        // A menu opens from its label, not the middle of the row.
        addLogo.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 3))
        app.buttons["Photos"].tap()
        XCTAssertTrue(app.images["DrawingLogoPreview"].waitForExistence(timeout: 3))

        app.buttons["DrawingAddTitleField"].tap()
        let label = app.textFields["DrawingCustomFieldLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertEqual(label.value as? String, "Field 1")
        label.tap()
        label.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        label.typeText("Project")
        let value = app.textFields["DrawingCustomFieldValue"]
        value.tap()
        value.typeText("Apollo\n")
        XCTAssertEqual(label.value as? String, "Project")

        let save = app.buttons["DrawingSaveTitleTemplate"]
        reveal(save)
        save.tap()
        XCTAssertTrue(app.buttons["Saved as Default"].waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "drawing-title-block"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["DrawingDone"].tap()

        // A new design (the settings kept): its first drawing has both.
        app.terminate()
        app.launchEnvironment["OS3D_RESET_STORE"] = nil
        app.launch()
        openDrawing()
        XCTAssertTrue(app.descendants(matching: .any)["DrawingPreview"].waitForExistence(timeout: 10))
        let logo = app.images["DrawingLogoPreview"]
        reveal(logo)
        XCTAssertEqual(app.textFields["DrawingCustomFieldValue"].value as? String, "Apollo")
        XCTAssertTrue(app.buttons["Saved as Default"].exists)
        app.buttons["DrawingRemoveLogo"].tap()
        XCTAssertTrue(logo.waitForNonExistence(timeout: 3))
        let useDefault = app.buttons["DrawingUseTitleTemplate"]
        reveal(useDefault)
        useDefault.tap()
        XCTAssertTrue(logo.waitForExistence(timeout: 3), "Use Default puts the logo back")
        app.buttons["DrawingDone"].tap()
    }

    /// Dimensions & notes (spec §15): the Dimension tool takes two points of
    /// a view, the Note tool places a note; both are listed and deletable.
    func testDimensionAndNoteArePlacedOnTheSheet() throws {
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
        let tools = app.segmentedControls["DrawingToolPicker"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        tools.buttons["Dimension"].tap()

        // Walk taps across the sheet: two in a row inside one view make a
        // dimension (wherever the standard put the views) — two edges an
        // angle, which the walk may place on the way.
        let dimension = app.descendants(matching: .any)["DrawingAnnotation_linear"]
        var placed = false
        outer: for y in stride(from: 0.25, through: 0.75, by: 0.1) {
            for x in stride(from: 0.2, through: 0.8, by: 0.04) {
                preview.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
                if dimension.exists { placed = true; break outer }
            }
        }
        XCTAssertTrue(placed, "a dimension is placed on a view")
        XCTAssertTrue(app.segmentedControls["DrawingAnnotationOrientation"].exists)

        // Its tolerance: Symmetrical brings the ± field; a suffix is typed.
        XCTAssertFalse(app.textFields["DrawingToleranceUpper"].exists, "no tolerance to start with")
        let tolerance = app.buttons["DrawingDimensionTolerance"].firstMatch
        XCTAssertTrue(tolerance.waitForExistence(timeout: 3))
        tolerance.tap()
        XCTAssertTrue(app.buttons["Symmetrical"].waitForExistence(timeout: 3))
        app.buttons["Symmetrical"].tap()
        XCTAssertTrue(app.textFields["DrawingToleranceUpper"].waitForExistence(timeout: 3), "the ± field")
        let suffix = app.textFields["DrawingDimensionSuffix"].firstMatch
        suffix.tap()
        suffix.typeText("TYP\n")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "±")).firstMatch
            .waitForExistence(timeout: 3), "the list shows the tolerance")

        // Its precision: 0.01 writes two decimals.
        let precision = app.buttons["DrawingDimensionPrecision"].firstMatch
        XCTAssertTrue(precision.waitForExistence(timeout: 3))
        precision.tap()
        XCTAssertTrue(app.buttons["0.01"].waitForExistence(timeout: 3))
        app.buttons["0.01"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label MATCHES %@", ".*\\.\\d\\d ±0\\.10.*"))
            .firstMatch.waitForExistence(timeout: 3), "the list shows two decimals")
        let tolerant = XCTAttachment(screenshot: app.screenshot())
        tolerant.name = "drawing-tolerance"; tolerant.lifetime = .keepAlways; add(tolerant)

        // Off the paper, a Note tap does nothing; on it, it places a note.
        tools.buttons["Note"].tap()
        let note = app.descendants(matching: .any)["DrawingAnnotation_note"]
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        XCTAssertFalse(note.waitForExistence(timeout: 1), "the grey around the sheet takes no note")
        for y in stride(from: 0.3, through: 0.8, by: 0.05) where !note.exists {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: y)).tap()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 3), "a free note on the sheet")
        XCTAssertTrue(tools.buttons["Move"].isSelected, "back to Move to drag it")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "drawing-annotations"; shot.lifetime = .keepAlways; add(shot)

        // Deleting removes it.
        let deletes = app.buttons.matching(identifier: "DrawingAnnotationDelete")
        XCTAssertGreaterThanOrEqual(deletes.count, 2)
        deletes.element(boundBy: deletes.count - 1).tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 3))
        XCTAssertTrue(dimension.exists)
    }
}
