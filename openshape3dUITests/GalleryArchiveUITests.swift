//
//  GalleryArchiveUITests.swift
//  openshape3dUITests
//
//  Phase F sharing tranche: Duplicate now rides the .os3d archive round-trip.
//  The old field-copy dropped the feature graph — this test extrudes a box,
//  duplicates the project from the gallery, opens the copy and asserts the
//  Extrude FEATURE (not just the mesh) survived.
//

import XCTest

final class GalleryArchiveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testDuplicateCarriesFeatureGraph() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))

        // Extrude a box so the project has one feature.
        func p(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }
        startSketchTool(app, "Rect")
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        p(0.80, 0.78).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2)
        lookAtSketch(app)
        p(0.32, 0.32).press(forDuration: 0.15, thenDragTo: p(0.68, 0.62))
        app.buttons["Exit Sketching"].tap(); sleep(1)
        p(0.45, 0.45).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))
        typeExtrudeHeight(app); sleep(2)

        // Remember this project's name from the editor title, then go back.
        let backButton = app.navigationBars.buttons.firstMatch
        backButton.tap()
        XCTAssertTrue(app.navigationBars["Designs"].waitForExistence(timeout: 5))

        // Long-press the newest card → Duplicate.
        let card = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Untitled'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        let originalName = card.label
        card.press(forDuration: 1.2)
        let duplicateButton = app.buttons["Duplicate"]
        XCTAssertTrue(duplicateButton.waitForExistence(timeout: 3))
        duplicateButton.tap()
        sleep(1)

        // The copy exists under a fresh name…
        let copyCard = app.staticTexts["\(originalName) Copy"]
        XCTAssertTrue(copyCard.waitForExistence(timeout: 3),
                      "duplicating creates '<name> Copy'")

        // …and opening it shows the Extrude FEATURE in History — the graph
        // (not just the baked mesh) came along, with remapped IDs.
        copyCard.tap()
        XCTAssertTrue(app.buttons["HistoryButton"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["HistoryButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryRow-Extrude'"))
            .firstMatch.waitForExistence(timeout: 5),
            "the duplicated project must keep its feature graph")
        let errors = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryError-'"))
        XCTAssertEqual(errors.count, 0,
                       "remapped references must still resolve — no error badges")
    }
}
