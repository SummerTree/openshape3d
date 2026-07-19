//
//  SweepFlowTests.swift
//  openshape3dTests
//
//  Sweep-path chaining math used by the Sweep flow (plan §B1 UI): entity →
//  polyline conversion and spine chaining/orientation.
//

import XCTest
import simd
@testable import openshape3d

final class SweepFlowTests: XCTestCase {

    // MARK: - sweepPathPolyline

    func testLineAndArcBecomePolylinesClosedEntitiesDoNot() {
        let line = SketchEntity.line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(3, 4))
        XCTAssertEqual(EditorViewModel.sweepPathPolyline(of: line), [SIMD2(0, 0), SIMD2(3, 4)])

        let arc = SketchEntity.arc(
            id: UUID(), center: .zero, radius: 2, startAngle: 0, endAngle: .pi / 2
        )
        let arcPoints = EditorViewModel.sweepPathPolyline(of: arc)
        XCTAssertNotNil(arcPoints)
        XCTAssertGreaterThanOrEqual(arcPoints!.count, 2)
        XCTAssertEqual(arcPoints!.first!.x, 2, accuracy: 1e-9)
        XCTAssertEqual(arcPoints!.last!.y, 2, accuracy: 1e-9)

        XCTAssertNil(EditorViewModel.sweepPathPolyline(
            of: .circle(id: UUID(), center: .zero, radius: 1)
        ))
        XCTAssertNil(EditorViewModel.sweepPathPolyline(
            of: .rect(id: UUID(), min: .zero, max: SIMD2(1, 1))
        ))
        XCTAssertNil(EditorViewModel.sweepPathPolyline(
            of: .polygon(id: UUID(), center: .zero, radius: 1, sides: 6, rotation: 0)
        ))
    }

    // MARK: - chainedSpine

    func testChainedSpineAppendsForwardSegment() {
        let spine: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]
        let segment: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(1, 0, 2)]
        let joined = EditorViewModel.chainedSpine(spine, adding: segment)
        XCTAssertEqual(joined, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 2)])
    }

    func testChainedSpineReversesSegmentWhoseEndTouchesTheSpine() {
        let spine: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]
        let segment: [SIMD3<Double>] = [SIMD3(3, 0, 0), SIMD3(1, 0, 0)]
        let joined = EditorViewModel.chainedSpine(spine, adding: segment)
        XCTAssertEqual(joined, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(3, 0, 0)])
    }

    func testChainedSpineAbsorbsSmallJunctionGaps() {
        let spine: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]
        let segment: [SIMD3<Double>] = [SIMD3(1.1, 0, 0), SIMD3(4, 0, 0)]
        let joined = EditorViewModel.chainedSpine(spine, adding: segment)
        // The segment's start (near-duplicate junction) is dropped.
        XCTAssertEqual(joined, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(4, 0, 0)])
    }

    func testChainedSpineRejectsDisconnectedSegment() {
        let spine: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]
        let segment: [SIMD3<Double>] = [SIMD3(5, 0, 0), SIMD3(9, 0, 0)]
        XCTAssertNil(EditorViewModel.chainedSpine(spine, adding: segment))
    }
}
