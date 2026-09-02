//
//  SectionKitTests.swift
//  openshape3dTests
//
//  Chaining a plane cut's unordered pieces into the loops a drawing shows —
//  pure values, no kernel.
//

import XCTest
import simd
@testable import openshape3d

final class SectionKitTests: XCTestCase {

    /// A 4×2 rectangle delivered as five pieces: the bottom split in two with
    /// the second half reversed, the top reversed — one closed loop of four
    /// points, area 8.
    func testPiecesChainIntoOneClosedLoopAndCollinearRunsMerge() {
        let pieces: [[SIMD3<Double>]] = [
            [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], [SIMD3(4, 0, 0), SIMD3(2, 0, 0)],
            [SIMD3(4, 0, 0), SIMD3(4, 2, 0)], [SIMD3(0, 2, 0), SIMD3(4, 2, 0)],
            [SIMD3(0, 2, 0), SIMD3(0, 0, 0)]]
        let loops = SectionKit.loops(from: pieces, origin: .zero,
                                     xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        XCTAssertEqual(loops.count, 1)
        XCTAssertTrue(loops[0].closed)
        XCTAssertEqual(loops[0].points.count, 4, "\(loops[0].points)")
        XCTAssertEqual(abs(loops[0].area), 8, accuracy: 1e-12)
    }

    /// Two separate squares and a dangling piece: three results, largest area
    /// first, the open chain flagged with no area.
    func testSeparateLoopsSortLargestFirstAndAnOpenChainHasNoArea() {
        func square(_ c: Double, _ s: Double) -> [[SIMD3<Double>]] {
            let p = [SIMD3(c, c, 5), SIMD3(c + s, c, 5), SIMD3(c + s, c + s, 5), SIMD3(c, c + s, 5)]
            return (0..<4).map { [p[$0], p[($0 + 1) % 4]] }
        }
        let pieces = square(0, 10) + square(20, 2) + [[SIMD3(40, 0, 5), SIMD3(41, 1, 5), SIMD3(42, 3, 5)]]
        let loops = SectionKit.loops(from: pieces, origin: SIMD3(0, 0, 5),
                                     xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        XCTAssertEqual(loops.count, 3)
        XCTAssertEqual(abs(loops[0].area), 100, accuracy: 1e-12)
        XCTAssertEqual(abs(loops[1].area), 4, accuracy: 1e-12)
        XCTAssertFalse(loops[2].closed)
        XCTAssertEqual(loops[2].area, 0)
        XCTAssertEqual(loops[2].points.count, 3)
    }

    /// The frame is orthonormal and right-handed about the normal; a hint in
    /// the plane is taken as is, a hint along the normal falls back.
    func testFrameHonoursAnInPlaneHintAndFallsBackOtherwise() {
        let f = SectionKit.frame(normal: SIMD3(0, 0, 2), xAxisHint: SIMD3(0, 3, 0))
        XCTAssertEqual(simd_distance(f.xAxis, SIMD3(0, 1, 0)), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_distance(f.yAxis, SIMD3(-1, 0, 0)), 0, accuracy: 1e-12)
        let g = SectionKit.frame(normal: SIMD3(0, 0, 1), xAxisHint: SIMD3(0, 0, 5))
        XCTAssertEqual(simd_length(g.xAxis), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(g.xAxis, SIMD3(0, 0, 1)), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(g.xAxis, g.yAxis), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_distance(simd_cross(g.xAxis, g.yAxis), SIMD3(0, 0, 1)), 0, accuracy: 1e-12)
    }
}
