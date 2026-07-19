//
//  ExpressionEvaluatorTests.swift
//  openshape3dTests
//
//  Dimension-field arithmetic evaluator (plan §C2, spec §18).
//

import XCTest
@testable import openshape3d

final class ExpressionEvaluatorTests: XCTestCase {

    func testPlainNumbers() {
        XCTAssertEqual(ExpressionEvaluator.evaluate("20"), 20)
        XCTAssertEqual(ExpressionEvaluator.evaluate("25.4"), 25.4)
        XCTAssertEqual(ExpressionEvaluator.evaluate("  7  "), 7)
    }

    func testArithmetic() {
        XCTAssertEqual(ExpressionEvaluator.evaluate("25.4/2"), 12.7)
        XCTAssertEqual(ExpressionEvaluator.evaluate("10 + 5"), 15)
        XCTAssertEqual(ExpressionEvaluator.evaluate("3*4"), 12)
        XCTAssertEqual(ExpressionEvaluator.evaluate("100 - 30 - 20"), 50)
        XCTAssertEqual(ExpressionEvaluator.evaluate("(1+2)*3"), 9)
        XCTAssertEqual(ExpressionEvaluator.evaluate("2 + 3 * 4"), 14) // precedence
    }

    func testUnaryAndUnits() {
        XCTAssertEqual(ExpressionEvaluator.evaluate("-5 + 8"), 3)
        XCTAssertEqual(ExpressionEvaluator.evaluate("20 mm"), 20)
        XCTAssertEqual(ExpressionEvaluator.evaluate("=42"), 42)
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(ExpressionEvaluator.evaluate(""))
        XCTAssertNil(ExpressionEvaluator.evaluate("abc"))
        XCTAssertNil(ExpressionEvaluator.evaluate("5 +"))
        XCTAssertNil(ExpressionEvaluator.evaluate("(1+2"))
        XCTAssertNil(ExpressionEvaluator.evaluate("1/0"))
        XCTAssertNil(ExpressionEvaluator.evaluate("* 3"))
    }
}
