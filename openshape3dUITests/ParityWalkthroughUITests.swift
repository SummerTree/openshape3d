//
//  ParityWalkthroughUITests.swift
//  openshape3dUITests
//
//  Visual parity walkthrough: drives every major flow and captures named
//  screenshots (kept in the result bundle) for review against
//  docs/SHAPR3D_PARITY_SPEC.md. Assertions are deliberately light — the
//  screenshots are the deliverable; flow tests elsewhere assert behavior.
//

import XCTest

final class ParityWalkthroughUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        usleep(300_000)
    }

    private func launchFresh(seed: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        if seed { app.launchEnvironment["OS3D_DEBUG_SEED"] = "1" }
        app.launch()
        let rectButton = app.buttons.containing(.staticText, identifier: "Rect").firstMatch
        XCTAssertTrue(rectButton.waitForExistence(timeout: 10))
        sleep(1)
        return app
    }

    func testWalkthrough01SketchTools() throws {
        let app = launchFresh()
        let window = app.windows.firstMatch
        snap("01-editor-empty-palette")

        // Plane pickers
        app.buttons.containing(.staticText, identifier: "Rect").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3))
        snap("02-plane-pickers")

        // Ground sketch: rect + circle inside (hole) + polygon beside
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        XCTAssertTrue(app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3))
        sleep(2)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.60)))
        app.buttons.containing(.staticText, identifier: "Circle").firstMatch.tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.47))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: 0.51)))
        app.buttons.containing(.staticText, identifier: "Polygon").firstMatch.tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.42))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.50)))
        snap("03-sketch-rect-hole-polygon-fills")

        app.buttons["Exit Sketching"].tap()
        sleep(1)
        snap("04-fills-after-exit")
    }

    func testWalkthrough02ExtrudeBar() throws {
        let app = launchFresh()
        let window = app.windows.firstMatch

        app.buttons.containing(.staticText, identifier: "Rect").firstMatch.tap()
        _ = app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        _ = app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3)
        sleep(2)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.40))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.58)))
        app.buttons["Exit Sketching"].tap()
        sleep(1)

        // Tap the fill: full extrude bar (badge, symmetric, revolve/sweep/loft)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.51, dy: 0.49)).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))
        snap("05-extrude-bar-with-badge")

        // Pull upward: dynamic preview + arrow
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.51, dy: 0.49))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.51, dy: 0.30)))
        snap("06-extrude-pull-preview")

        app.buttons["Extrude"].firstMatch.tap()
        sleep(1)
        snap("07-committed-body-info-bar")
    }

    func testWalkthrough03FaceItemsViews() throws {
        let app = launchFresh(seed: true)
        let window = app.windows.firstMatch
        snap("08-seeded-selected-gizmo-rings")

        // Face selection
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        sleep(1)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(
            app.staticTexts["Face selected — drag it to push or pull"].waitForExistence(timeout: 3)
        )
        snap("09-face-selected-highlight")

        // Items panel
        app.buttons["ItemsButton"].tap()
        XCTAssertTrue(app.staticTexts["Bodies"].waitForExistence(timeout: 3))
        snap("10-items-panel")
        app.buttons["ItemsButton"].tap()

        // Views menu
        app.buttons["ViewsMenu"].tap()
        XCTAssertTrue(app.buttons["Front"].waitForExistence(timeout: 3))
        snap("11-views-menu")
        app.buttons["Front"].tap()
        sleep(1)
        snap("12-front-view")
    }

    func testWalkthrough04PatternMeasure() throws {
        let app = launchFresh(seed: true)
        let window = app.windows.firstMatch

        // Pattern bar with ghost previews
        app.buttons["PatternButton"].tap()
        XCTAssertTrue(app.buttons["PatternApply"].waitForExistence(timeout: 3))
        snap("13-pattern-bar-ghosts")
        app.buttons["Cancel"].firstMatch.tap()
        sleep(1)

        // Measure two corners
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        sleep(1)
        app.buttons["MeasureButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Tap two points to measure"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.62)).tap()
        sleep(1)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.62)).tap()
        _ = app.staticTexts["MeasureDistanceValue"].waitForExistence(timeout: 3)
        snap("14-measure-distance")
        app.buttons["Done"].firstMatch.tap()
    }

    func testWalkthrough05RevolveSweepLoft() throws {
        let app = launchFresh()
        let window = app.windows.firstMatch

        // Rect + separate vertical line (axis), then arm Revolve
        app.buttons.containing(.staticText, identifier: "Rect").firstMatch.tap()
        _ = app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        _ = app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3)
        sleep(2)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.40))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.56)))
        let lineButton = app.buttons.containing(.staticText, identifier: "Line").firstMatch
        lineButton.tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.35))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.62)))
        app.buttons["Exit Sketching"].tap()
        sleep(1)

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.47)).tap()
        XCTAssertTrue(app.staticTexts["Extrude"].waitForExistence(timeout: 5))

        app.buttons["Revolve"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Tap a sketch line to set the revolve axis"].waitForExistence(timeout: 3)
        )
        snap("15-revolve-axis-pill")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.48)).tap()
        XCTAssertTrue(app.staticTexts["Angle"].waitForExistence(timeout: 5))
        snap("16-revolve-preview-angle-bar")

        app.buttons["Cancel"].firstMatch.tap()
    }
}
