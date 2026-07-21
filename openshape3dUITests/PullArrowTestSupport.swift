//
//  PullArrowTestSupport.swift
//  openshape3dUITests
//
//  Shapr3D face push/pull is driven ONLY by the floating pull-arrow handle now
//  (dragging the face itself orbits). These helpers grab that handle by its
//  accessibility identifier so tests stay robust to the camera angle.
//

import XCTest

extension XCUIApplication {
    /// The extrude / push-pull arrow handle overlay (`arrow.up.and.down`).
    var pullArrowHandle: XCUIElement {
        descendants(matching: .any).matching(identifier: "PullArrowHandle").firstMatch
    }
}

extension XCTestCase {
    /// Grab the pull-arrow handle and drag it to `end` to push/pull the selected
    /// face. Only the arrow moves a face, so this replaces face-center drags.
    func dragPullArrow(_ app: XCUIApplication, to end: XCUICoordinate,
                       duration: TimeInterval = 0.15) {
        let handle = app.pullArrowHandle
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "pull-arrow handle should be visible")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: duration, thenDragTo: end)
    }

    // MARK: - Context-sensitive palette (Shapr3D-style)
    //
    // Tools now live in flyout groups (Sketch/Modify/Transform/Combine in body
    // mode; Constrain/Symbol while sketching) and sketch tools are hidden outside
    // a sketch. These helpers open the owning group first if the tool isn't
    // already directly reachable, so tests don't care whether a tool is top-level
    // or behind a flyout.

    /// Tap a palette tool found by its visible label (Line/Rect/Circle/Union/…),
    /// opening `group` first if it isn't directly hittable.
    func tapPaletteTool(_ app: XCUIApplication, group: String, label: String) {
        let query = app.buttons.containing(.staticText, identifier: label)
        if !query.firstMatch.isHittable {
            app.buttons[group + "Group"].tap()
            _ = query.firstMatch.waitForExistence(timeout: 2)
        }
        query.firstMatch.tap()
    }

    /// Tap a palette tool found by its accessibility id (TranslateButton,
    /// DimensionButton, …), opening `group` first if needed.
    func tapPaletteTool(_ app: XCUIApplication, group: String, id: String) {
        let btn = app.buttons[id]
        if !btn.isHittable {
            app.buttons[group + "Group"].tap()
            _ = btn.waitForExistence(timeout: 2)
        }
        btn.tap()
    }

    /// Start a sketch by choosing a draw tool from the body-mode Sketch flyout.
    func startSketchTool(_ app: XCUIApplication, _ label: String) {
        tapPaletteTool(app, group: "Sketch", label: label)
    }
}
