//
//  HistoryPanelUITests.swift
//  openshape3dUITests
//
//  Phase D tranche 1: the parametric history timeline records a feature at each
//  solid-modeling commit and surfaces it in the History panel. This drives the
//  live app — sketch a rectangle, extrude it (which records an Extrude feature),
//  open the History panel, and confirm the recorded step appears with its inline
//  distance editor. (The downstream rebuild-on-edit is proven in the pure
//  FeatureGraph unit tests.)
//

import XCTest

final class HistoryPanelUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testExtrudeRecordsFeatureShownInHistoryPanel() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()
        let window = app.windows.firstMatch

        // Sketch a rectangle on the ground plane.
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        startSketchTool(app, "Rect")
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(1)
        lookAtSketch(app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
            .press(forDuration: 0.15,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60)))
        app.buttons["Exit Sketching"].tap()
        sleep(1)

        // Tap inside the filled profile → Extrude command → commit a new body.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.51)).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))
        typeExtrudeHeight(app)
        sleep(1)

        // Open the History panel — the committed extrude must appear as a step
        // with its editable distance (proves recording + display end-to-end).
        let historyButton = app.buttons["HistoryButton"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 5), "History button exists")
        historyButton.tap()

        // Query by identifier across any element type (the panel wraps a ScrollView).
        let panel = app.descendants(matching: .any).matching(identifier: "HistoryPanel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 4), "History panel opens")
        XCTAssertTrue(app.textFields["HistoryDistanceField"].waitForExistence(timeout: 3),
                      "the recorded Extrude step shows its inline distance editor")

        // G8 options: the row's Symmetric checkbox flips the node and the row
        // is re-derived from the document — so a flipped value proves the
        // edit-and-rebuild round trip, not just a local toggle.
        let symmetric = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'HistoryOption-symmetric-'")).firstMatch
        XCTAssertTrue(symmetric.waitForExistence(timeout: 3), "the extrude row offers Symmetric")
        XCTAssertEqual(symmetric.value as? String, "off")
        symmetric.tap()
        let flipped = NSPredicate(format: "value == 'on'")
        expectation(for: flipped, evaluatedWith: symmetric)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(symmetric.value as? String, "on", "the document's extrude is symmetric now")
    }
}
