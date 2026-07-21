//
//  DimensionUITests.swift
//  openshape3dUITests
//
//  Driving dimensions (plan §C2, spec §2.2). Draws geometry, selects it so its
//  editable dimension label appears in the sketch overlay, opens the inline
//  numeric field, and commits a new value — asserting the solver drives the
//  geometry to that value (read back from the overlay's measured label).
//

import XCTest

final class DimensionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func startGroundSketch(
        _ app: XCUIApplication, window: XCUIElement, tool: String
    ) {
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))
        startSketchTool(app, tool)
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2) // let the head-on camera animation settle
    }

    /// Open the dimension field, clear it, type `value`, and commit.
    private func setDimension(_ app: XCUIApplication, to value: String) {
        let label = app.buttons["DimensionLabel"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 3),
                      "Selecting the entity should show an editable dimension label")
        label.tap()

        let field = app.textFields["DimensionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "Tapping the label opens the field")
        field.tap()
        let existing = (field.value as? String) ?? ""
        if !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)

        let commit = app.buttons["DimensionCommit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 2))
        commit.tap()
    }

    // MARK: - Line length dimension

    func testLineLengthDimensionDrivesGeometry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        startGroundSketch(app, window: window, tool: "Line")

        func p(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }

        // Draw a single line, then tap its middle to select it.
        p(0.34, 0.50).press(forDuration: 0.15, thenDragTo: p(0.62, 0.50))
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.isEnabled, "Drawing a line should push an undoable step")
        p(0.48, 0.50).tap()
        sleep(1)

        // Edit the length dimension to 20 (inline arithmetic also accepted).
        setDimension(app, to: "20")
        sleep(1)

        // The solved line is length 20: the measured label reads it back, and
        // the Dimension edit is one extra undo step (line draw + dimension = 2).
        XCTAssertTrue(app.staticTexts["20.00 mm"].waitForExistence(timeout: 3),
                      "The line should be driven to length 20")
        XCTAssertTrue(undo.isEnabled)
        undo.tap() // undo the dimension
        undo.tap() // undo the line draw
        XCTAssertFalse(undo.isEnabled,
                       "Line draw + dimension should be exactly two undo steps")
    }

    // MARK: - Circle radius dimension

    func testCircleRadiusDimensionDrivesGeometry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        startGroundSketch(app, window: window, tool: "Circle")

        func p(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }

        // Draw a circle (center → radius handle), then tap its ring to select
        // the whole circle (a center tap would select the point instead).
        p(0.50, 0.50).press(forDuration: 0.15, thenDragTo: p(0.63, 0.50))
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.isEnabled, "Drawing a circle should push an undoable step")
        p(0.63, 0.50).tap()
        sleep(1)

        // Edit the radius dimension to 5.
        setDimension(app, to: "5")
        sleep(1)

        // The circle radius is driven to 5; the info bar / radius label reads it.
        XCTAssertTrue(app.staticTexts["5.00 mm"].waitForExistence(timeout: 3),
                      "The circle should be driven to radius 5")
    }
}
