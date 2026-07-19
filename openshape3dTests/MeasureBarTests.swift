//
//  MeasureBarTests.swift
//  openshape3dTests
//
//  Math added for the selection info bar: closed-loop perimeter.
//

import XCTest
import simd
@testable import openshape3d

final class MeasureBarTests: XCTestCase {

    func testPerimeterOfSquareLoop() {
        let loop: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4),
        ]
        XCTAssertEqual(MeasureKit.perimeter(of: loop), 16, accuracy: 1e-12)
    }

    func testPerimeterOfTriangleLoop() {
        let loop: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(3, 0), SIMD2(0, 4),
        ]
        XCTAssertEqual(MeasureKit.perimeter(of: loop), 12, accuracy: 1e-12)
    }

    func testPerimeterDegenerateLoops() {
        XCTAssertEqual(MeasureKit.perimeter(of: []), 0)
        XCTAssertEqual(MeasureKit.perimeter(of: [SIMD2(1, 1)]), 0)
        // Two points: out and back.
        XCTAssertEqual(
            MeasureKit.perimeter(of: [SIMD2(0, 0), SIMD2(2, 0)]), 4, accuracy: 1e-12
        )
    }
}
