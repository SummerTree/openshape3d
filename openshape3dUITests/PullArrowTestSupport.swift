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

    // MARK: - Sketch camera

    /// Square the camera up to the active sketch plane.
    ///
    /// Entering a sketch KEEPS the camera where the user left it (Shapr3D
    /// behaviour — you draw on the plane from whatever view you were in), so a
    /// test that drives a sketch by normalized screen coordinates has to face
    /// the plane first; otherwise its taps land somewhere else entirely on the
    /// plane and the geometry it thinks it drew is not the geometry it drew.
    ///
    /// The Look at Sketch button only exists while the camera is off-axis, so
    /// its absence means we are already head-on and there is nothing to do.
    func lookAtSketch(_ app: XCUIApplication, settle: UInt32 = 2) {
        let button = app.buttons["Look at Sketch"]
        if button.waitForExistence(timeout: 3), button.isHittable {
            button.tap()
        }
        sleep(settle) // camera flight
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

    /// Tapping a profile arms Extrude at ZERO height (arrow only, no default
    /// pull) — type a height into the bar's Distance field; submitting
    /// commits the tool.
    func typeExtrudeHeight(_ app: XCUIApplication, _ value: String = "2") {
        let field = app.textFields["Distance"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "Extrude Distance field should be visible")
        field.tap()
        field.typeText("\(value)\n") // onSubmit commits the extrude
    }

    /// Replace a text field's whole contents and submit.
    ///
    /// The rename tests used to do `tap()` + `doubleTap()` + `typeText`,
    /// relying on the double tap to select the existing word so the typed text
    /// replaced it. On this simulator (iOS 26.2) the double tap no longer
    /// selects, so the text was APPENDED — the body really was renamed, just
    /// to "ExtrudeMyPart" instead of "MyPart", and the assertion on the new
    /// name failed while the app was behaving correctly.
    ///
    /// Cmd-A is the deterministic replacement for the double tap, but focus is
    /// asynchronous: sent too close behind the tap it can land before the field
    /// is first responder, and the append comes back (that one still bit the
    /// symbol rename). So this VERIFIES what actually landed and repairs it
    /// with backspaces — the caret is at the end after typing, so deleting
    /// `value.count` characters always empties the field, whatever the
    /// selection did.
    func replaceText(_ field: XCUIElement, with text: String, submit: Bool = true) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)   // select the old value
        field.typeText(text)
        if let landed = field.value as? String, landed != text {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: landed.count))
            field.typeText(text)
        }
        if submit { field.typeText("\n") }
    }
}
