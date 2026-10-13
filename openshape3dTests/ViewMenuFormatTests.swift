//
//  ViewMenuFormatTests.swift
//  openshape3dTests
//
//  View menu (spec §7.3–7.4): Degree Format, architectural Foot & Inch
//  Format, the grid spacing Lock Grid Size freezes, and the grid planes.
//

import XCTest
import simd
@testable import openshape3d

final class ViewMenuFormatTests: XCTestCase {

    func testDegreeFormats() {
        XCTAssertEqual(DegreeFormat.decimal.string(27.25), "27.25°")
        XCTAssertEqual(DegreeFormat.fractional.string(27.25), "27°15'")
        XCTAssertEqual(DegreeFormat.fractional.string(90), "90°")
        XCTAssertEqual(DegreeFormat.fractional.string(44.9999), "45°", "59.99' rounds up into the next degree")
        XCTAssertEqual(DegreeFormat.fractional.string(-30.5), "-30°30'")
    }

    func testArchitecturalFeetAndInches() {
        // 1' 4 1/2" = 16.5" = 419.1 mm
        XCTAssertEqual(DisplayUnit.feet.architecturalString(fromMM: 419.1), "1' - 4 1/2\"")
        XCTAssertEqual(DisplayUnit.inches.architecturalString(fromMM: 419.1), "16 1/2\"")
        XCTAssertEqual(DisplayUnit.feet.architecturalString(fromMM: 304.8), "1' - 0\"")
        // Nearest 1/16", reduced: 3/16 stays, 4/16 → 1/4.
        XCTAssertEqual(DisplayUnit.inches.architecturalString(fromMM: 25.4 * 3 / 16), "0 3/16\"")
        XCTAssertEqual(DisplayUnit.inches.architecturalString(fromMM: 25.4 / 4), "0 1/4\"")
    }

    func testGridSpacingStepsByDecades() {
        var camera = TurntableCamera()
        camera.distance = 12
        let near = camera.gridMinorSpacing
        camera.distance = 1200
        let far = camera.gridMinorSpacing
        XCTAssertEqual(far / near, 100, accuracy: 1e-9, "100× farther → two decades coarser")
        XCTAssertEqual(log10(near).rounded(), log10(near), accuracy: 1e-9, "always a power of ten")
    }

    func testGridPositionPlanes() {
        typealias Grid = EditorViewModel.GridPosition
        XCTAssertEqual(abs(simd_dot(Grid.zx.plane.normal, SIMD3(0, 1, 0))), 1, accuracy: 1e-12)
        XCTAssertEqual(abs(simd_dot(Grid.xy.plane.normal, SIMD3(0, 0, 1))), 1, accuracy: 1e-12)
        XCTAssertEqual(abs(simd_dot(Grid.yz.plane.normal, SIMD3(1, 0, 0))), 1, accuracy: 1e-12)
    }
}
