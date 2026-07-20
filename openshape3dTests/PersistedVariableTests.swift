//
//  PersistedVariableTests.swift
//  openshape3dTests
//
//  Round-trip coverage for the Phase D variable encode/decode helpers
//  (`encodeVariable`/`decodeVariable`, the `Variable` <-> `PersistedVariable`
//  bridge). SwiftData persistence itself (ModelContainer/ModelContext) is
//  intentionally NOT exercised here — only the pure per-column mapping plus an
//  in-memory @Model instance.
//

import XCTest
@testable import openshape3d

final class PersistedVariableTests: XCTestCase {

    /// encodeVariable then decodeVariable reproduces an equal `Variable`, and the
    /// per-column PersistedVariable fields carry the right values incl. orderIndex.
    func testVariableBridgeRoundTrips() throws {
        let v = Variable(
            id: VariableID(),
            name: "width",
            expression: "height * 2",
            value: 42.5)

        let pv = encodeVariable(v, orderIndex: 7)
        XCTAssertEqual(pv.variableID, v.id.raw)
        XCTAssertEqual(pv.orderIndex, 7)
        XCTAssertEqual(pv.name, "width")
        XCTAssertEqual(pv.expression, "height * 2")
        XCTAssertEqual(pv.value, 42.5)

        let back = decodeVariable(pv)
        XCTAssertEqual(back, v)
        XCTAssertEqual(back.id, v.id)
        XCTAssertEqual(back.name, v.name)
        XCTAssertEqual(back.expression, v.expression)
        XCTAssertEqual(back.value, v.value)
    }

    /// Empty name/expression and zero value (the @Model defaults) survive the trip.
    func testEmptyVariableRoundTrips() {
        let v = Variable(id: VariableID(), name: "", expression: "", value: 0)
        let back = decodeVariable(encodeVariable(v, orderIndex: 0))
        XCTAssertEqual(back, v)
    }
}
