//
//  GizmoFlowUITests.swift
//  openshape3dUITests
//
//  Verifies the move gizmo: place a box, drag the Y arrow upward, and confirm
//  a second undoable command exists (place + move). If the drag had orbited
//  the camera instead of claiming the gizmo, only one undo would exist.
//

import XCTest

final class GizmoFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGizmoDragCreatesUndoableMove() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_AUTO_OPEN"] = "1"
        app.launch()

        // Place a box at a known viewport spot.
        let boxButton = app.buttons.containing(.staticText, identifier: "Box").firstMatch
        XCTAssertTrue(boxButton.waitForExistence(timeout: 10))
        boxButton.tap()

        let window = app.windows.firstMatch
        let placePoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        placePoint.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))

        // The gizmo sits at the placed pivot. Its green Y arrow always points
        // straight up on screen: press just above the pivot and drag upward.
        let arrowStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.455))
        let arrowEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.33))
        arrowStart.press(forDuration: 0.1, thenDragTo: arrowEnd)

        // Two commands should now be undoable: Add and Move.
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(undo.isEnabled, "Move should undo first, leaving Add undoable")
        undo.tap()
        XCTAssertFalse(undo.isEnabled, "Both commands undone — stack should be empty")
    }
}
