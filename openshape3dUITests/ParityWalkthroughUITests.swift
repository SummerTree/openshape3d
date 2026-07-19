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

    func testWalkthrough06SectionAndXRay() throws {
        let app = launchFresh(seed: true)
        let window = app.windows.firstMatch

        // Deselect the seeded box so the section shot is uncluttered.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        sleep(1)

        // Views → Section arms the plane picker.
        app.buttons["ViewsMenu"].tap()
        let section = app.buttons["Section"]
        XCTAssertTrue(section.waitForExistence(timeout: 3))
        section.tap()
        XCTAssertTrue(app.staticTexts["Choose a section plane"].waitForExistence(timeout: 3))
        snap("17-section-plane-pickers")

        // Tap a plane tile through the box (candidates cover camera-fit
        // variance, same pattern as SplitPatternUITests).
        let flip = app.buttons["SectionFlip"]
        let candidates: [CGVector] = [
            CGVector(dx: 0.42, dy: 0.55),
            CGVector(dx: 0.46, dy: 0.50),
            CGVector(dx: 0.50, dy: 0.55),
            CGVector(dx: 0.54, dy: 0.50),
            CGVector(dx: 0.77, dy: 0.49),
            CGVector(dx: 0.38, dy: 0.60),
        ]
        for offset in candidates where !flip.exists {
            window.coordinate(withNormalizedOffset: offset).tap()
            _ = flip.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(flip.exists, "A tile tap should activate the section")
        sleep(1)
        // Orbit slightly off the head-on view so the open cut reads as a
        // sectioned box, not a flat quad (drag starts on empty grid →
        // camera orbit; orbit sensitivity is high, keep the drag tiny).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.33))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.35)))
        sleep(1)
        snap("18-section-active-flip-off-badges")
        app.buttons["SectionOff"].tap()
        sleep(1)

        // Views → Display → X-Ray.
        app.buttons["ViewsMenu"].tap()
        let displayShaded = app.buttons["Display: Shaded"]
        XCTAssertTrue(displayShaded.waitForExistence(timeout: 3))
        displayShaded.tap()
        let xray = app.buttons["X-Ray"]
        XCTAssertTrue(xray.waitForExistence(timeout: 3))
        xray.tap()
        sleep(1)
        snap("19-xray-display-mode")
    }

    func testWalkthrough07MarqueeAndMaterial() throws {
        let app = launchFresh(seed: true)
        let window = app.windows.firstMatch

        // Pattern the seeded box so the marquee has several targets.
        app.buttons["PatternButton"].tap()
        XCTAssertTrue(app.buttons["PatternApply"].waitForExistence(timeout: 3))
        app.buttons["PatternApply"].tap()
        app.buttons["Fit View"].tap()
        sleep(1)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.85)).tap()

        // Select mode: status pill + filter chips.
        app.buttons["SelectModeButton"].tap()
        XCTAssertTrue(app.staticTexts["Drag to select"].waitForExistence(timeout: 3))
        snap("20-select-mode-pill-filters")

        // Crossing marquee (right→left), captured MID-DRAG: the finger holds
        // at the stroke end while a background queue grabs the screen — the
        // dashed crossing rect is still up.
        var midDrag: XCUIScreenshot?
        let captured = expectation(description: "mid-drag screenshot")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.8) {
            midDrag = XCUIScreen.main.screenshot()
            captured.fulfill()
        }
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.25))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: .default, thenHoldForDuration: 2.5)
        wait(for: [captured], timeout: 10)
        if let midDrag {
            let attachment = XCTAttachment(screenshot: midDrag)
            attachment.name = "21-marquee-crossing-in-progress"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(app.staticTexts["3 bodies"].waitForExistence(timeout: 3),
                      "The crossing marquee should select every pattern instance")
        snap("22-marquee-multi-selection-info")

        // Material sheet over the selection.
        app.buttons["MaterialButton"].tap()
        XCTAssertTrue(app.staticTexts["MaterialMetallicValue"].waitForExistence(timeout: 3))
        snap("23-material-sheet")
        app.buttons["MaterialCancel"].tap()
    }

    func testWalkthrough08ImageSelected() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED_IMAGE"] = "1"
        app.launch()
        let window = app.windows.firstMatch
        let itemsButton = app.buttons["ItemsButton"]
        XCTAssertTrue(itemsButton.waitForExistence(timeout: 10))
        sleep(1)

        // Tap the seeded reference image: selection outline + image bar.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.sliders["ImageOpacitySlider"].waitForExistence(timeout: 3))

        // The seed camera-fits the quad edge-to-edge; shrink it via the
        // size field so the shot reads as a reference image on the grid
        // (viewport pinches are unreliable under synthesized touches).
        let sizeField = app.textFields["ImageSizeField"]
        XCTAssertTrue(sizeField.exists)
        sizeField.tap()
        sizeField.doubleTap() // select the current value so typing replaces it
        sizeField.typeText("12\n")
        sleep(1)
        snap("24-inserted-image-selected-bar")
    }

    func testWalkthrough09SymbolPlacement() throws {
        let app = launchFresh()
        let window = app.windows.firstMatch

        app.buttons.containing(.staticText, identifier: "Line").firstMatch.tap()
        _ = app.staticTexts["Choose a sketch plane"].waitForExistence(timeout: 3)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.78)).tap()
        _ = app.staticTexts["Sketching on ground plane"].waitForExistence(timeout: 3)
        sleep(2)

        func point(_ dx: CGFloat, _ dy: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        }

        // Two parallel lines, selected, become the "Bracket" symbol.
        point(0.35, 0.40).press(forDuration: 0.15, thenDragTo: point(0.60, 0.40))
        point(0.35, 0.48).press(forDuration: 0.15, thenDragTo: point(0.60, 0.48))
        point(0.47, 0.40).tap()
        sleep(1)
        point(0.47, 0.48).tap()
        sleep(1)
        app.buttons["MakeSymbolButton"].tap()
        let alert = app.alerts["Make Symbol"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        snap("25-make-symbol-prompt")
        let nameField = alert.textFields.firstMatch
        nameField.tap()
        nameField.typeText("Bracket")
        alert.buttons["Create"].tap()

        // Insert arms tap-to-place; two taps stamp two instances.
        let insertMenu = app.buttons["InsertSymbolMenu"]
        XCTAssertTrue(insertMenu.waitForExistence(timeout: 3))
        insertMenu.tap()
        let choice = app.buttons["Bracket"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.tap()
        XCTAssertTrue(app.buttons["InsertSymbolDone"].waitForExistence(timeout: 3))
        point(0.30, 0.66).tap()
        sleep(1)
        point(0.62, 0.66).tap()
        sleep(1)
        snap("26-symbol-placement-two-instances")
        app.buttons["InsertSymbolDone"].tap()
    }
}
