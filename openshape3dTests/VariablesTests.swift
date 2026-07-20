//
//  VariablesTests.swift
//  openshape3dTests
//
//  Phase D (task A1): document variable table resolution + name validation.
//

import XCTest
@testable import openshape3d

final class VariablesTests: XCTestCase {

    private func v(_ name: String, _ expr: String) -> Variable {
        Variable(name: name, expression: expr)
    }

    // MARK: - resolve

    func testResolveChain() {
        let (resolved, values, errors) = VariableTable.resolve([
            v("a", "2"),
            v("b", "a * 3"),
            v("c", "b + a"),
        ])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(values["a"], 2)
        XCTAssertEqual(values["b"], 6)
        XCTAssertEqual(values["c"], 8)
        XCTAssertEqual(resolved.map(\.value), [2, 6, 8])
    }

    func testForwardReferenceIsError() {
        // a references b, which is defined LATER -> creation-order rule fails a,
        // but b itself resolves fine.
        let a = v("a", "b + 1")
        let b = v("b", "2")
        let (resolved, values, errors) = VariableTable.resolve([a, b])

        XCTAssertNotNil(errors[a.id])
        XCTAssertNil(errors[b.id])
        XCTAssertNil(values["a"])            // not published
        XCTAssertEqual(values["b"], 2)

        let ra = resolved.first { $0.id == a.id }!
        let rb = resolved.first { $0.id == b.id }!
        XCTAssertEqual(ra.value, 0)          // errored -> 0
        XCTAssertEqual(rb.value, 2)
    }

    func testSelfReferenceIsError() {
        let a = v("a", "a + 1")
        let (_, values, errors) = VariableTable.resolve([a])
        XCTAssertNotNil(errors[a.id])
        XCTAssertNil(values["a"])
    }

    func testCyclicReferenceIsError() {
        // Front-to-back: a can't see b (later) -> a errors; b sees the failed a
        // (not published) -> b also errors.
        let a = v("a", "b + 1")
        let b = v("b", "a + 1")
        let (_, values, errors) = VariableTable.resolve([a, b])
        XCTAssertNotNil(errors[a.id])
        XCTAssertNotNil(errors[b.id])
        XCTAssertTrue(values.isEmpty)
    }

    func testDownstreamRefToFailedVariableAlsoFails() {
        // b fails (bad expr); c references b -> c fails because b was not
        // published to the running map.
        let a = v("a", "5")
        let b = v("b", "nope")           // unknown identifier -> fails
        let c = v("c", "b + 1")
        let (_, values, errors) = VariableTable.resolve([a, b, c])
        XCTAssertEqual(values["a"], 5)
        XCTAssertNotNil(errors[b.id])
        XCTAssertNotNil(errors[c.id])
        XCTAssertNil(values["b"])
        XCTAssertNil(values["c"])
    }

    func testFunctionsAndUnitsInVariableExpressions() {
        let (_, values, errors) = VariableTable.resolve([
            v("side", "10 mm"),
            v("diag", "sqrt(side * side * 2)"),
        ])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(values["side"], 10)
        XCTAssertEqual(values["diag"]!, sqrt(200), accuracy: 1e-9)
    }

    func testInvalidNameIsError() {
        let bad = v("2w", "5")
        let (_, values, errors) = VariableTable.resolve([bad])
        XCTAssertNotNil(errors[bad.id])
        XCTAssertNil(values["2w"])
    }

    func testDuplicateNameIsFlagged() {
        let a1 = v("a", "1")
        let a2 = v("a", "2")
        let (_, values, errors) = VariableTable.resolve([a1, a2])
        XCTAssertNil(errors[a1.id])
        XCTAssertNotNil(errors[a2.id])
        XCTAssertEqual(values["a"], 1)       // first definition wins
    }

    // MARK: - isValidName

    func testIsValidNameAccepts() {
        XCTAssertTrue(VariableTable.isValidName("cap_height"))
        XCTAssertTrue(VariableTable.isValidName("W2"))
        XCTAssertTrue(VariableTable.isValidName("w"))
        XCTAssertTrue(VariableTable.isValidName("_private"))
        XCTAssertTrue(VariableTable.isValidName(String(repeating: "a", count: 100)))
    }

    func testIsValidNameRejects() {
        XCTAssertFalse(VariableTable.isValidName("2w"))            // leading digit
        XCTAssertFalse(VariableTable.isValidName("__x"))          // reserved prefix
        XCTAssertFalse(VariableTable.isValidName("has space"))    // space
        XCTAssertFalse(VariableTable.isValidName("a-b"))          // hyphen
        XCTAssertFalse(VariableTable.isValidName(""))             // empty
        XCTAssertFalse(VariableTable.isValidName(String(repeating: "a", count: 101)))
    }
}
