//
//  VariablesPanelUITests.swift
//  openshape3dUITests
//
//  Phase D tranche 3: the Variables panel defines document variables whose
//  expressions evaluate (and can then drive feature params / sketch dimensions).
//  This drives the live app: open the panel, add a variable, type an arithmetic
//  expression, and confirm it evaluates. (Formula resolution + the variable-change
//  fan-out are covered by pure unit tests.)
//

import XCTest

final class VariablesPanelUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testAddVariableAndEvaluateExpression() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launch()
        // Editor is up when the sketch palette exists.
        XCTAssertTrue(app.buttons["SketchGroup"].waitForExistence(timeout: 10))

        // Open the Variables panel and add a variable.
        let varsButton = app.buttons["VariablesButton"]
        XCTAssertTrue(varsButton.waitForExistence(timeout: 5), "Variables button exists")
        varsButton.tap()
        let add = app.buttons["AddVariableButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 3), "Variables panel opens with an Add button")
        add.tap()

        // A new variable row shows an editable expression field.
        let exprField = app.textFields
            .matching(NSPredicate(format: "identifier BEGINSWITH 'VariableExprField-'")).firstMatch
        XCTAssertTrue(exprField.waitForExistence(timeout: 3), "the added variable shows an expression field")

        // Type an arithmetic expression and commit.
        exprField.tap()
        if let existing = exprField.value as? String, !existing.isEmpty {
            exprField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        }
        exprField.typeText("6*7\n")
        sleep(1)

        // The evaluated value reads 42.
        let value = app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH 'VariableValue-'")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 3), "the variable shows an evaluated value")
        XCTAssertTrue(value.label.contains("42"), "6*7 evaluates to 42 (got \"\(value.label)\")")
    }
}
