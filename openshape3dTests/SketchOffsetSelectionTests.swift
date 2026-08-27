//
//  SketchOffsetSelectionTests.swift
//  openshape3dTests
//
//  `SketchOffset.entitiesToOffset` — the Single/Chain seed expansion behind
//  the Offset Edge tool's Type menu (spec §1.9). The offsetting itself is
//  covered by SplitOffsetTests; this is only about which entities get fed in.
//

import XCTest
import simd
@testable import openshape3d

final class SketchOffsetSelectionTests: XCTestCase {

    /// Unit square as four connected lines, walked CCW.
    private func square() -> [SketchEntity] {
        let corners: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ]
        return corners.indices.map { i in
            .line(id: UUID(), a: corners[i], b: corners[(i + 1) % corners.count])
        }
    }

    func testEmptySeedsOffsetNothing() {
        XCTAssertTrue(SketchOffset.entitiesToOffset(
            seedIDs: [], type: .chain, in: square()
        ).isEmpty)
    }

    func testSingleTakesOnlyTheTappedEntity() {
        let entities = square()
        let picked = SketchOffset.entitiesToOffset(
            seedIDs: [entities[1].id], type: .single, in: entities
        )
        XCTAssertEqual(picked.map(\.id), [entities[1].id])
    }

    /// The point of Chain: one tap on a wall offsets the whole loop.
    func testChainExpandsOneTapToTheWholeConnectedLoop() {
        let entities = square()
        let picked = SketchOffset.entitiesToOffset(
            seedIDs: [entities[1].id], type: .chain, in: entities
        )
        XCTAssertEqual(Set(picked.map(\.id)), Set(entities.map(\.id)))
    }

    /// Ordering is load-bearing — `offset(entities:by:)` walks line chains to
    /// mitre their joins, so a shuffled chain would mitre wrongly.
    func testChainResultKeepsSketchOrderNotSeedOrder() {
        let entities = square()
        let picked = SketchOffset.entitiesToOffset(
            seedIDs: [entities[3].id, entities[0].id], type: .chain, in: entities
        )
        XCTAssertEqual(picked.map(\.id), entities.map(\.id))
    }

    /// A circle has no endpoints to chain through, so Chain cannot drag in
    /// unrelated geometry that merely sits nearby.
    func testChainOnAClosedEntityStaysAlone() {
        let circle = SketchEntity.circle(id: UUID(), center: SIMD2(5, 5), radius: 1)
        let entities = square() + [circle]
        let picked = SketchOffset.entitiesToOffset(
            seedIDs: [circle.id], type: .chain, in: entities
        )
        XCTAssertEqual(picked.map(\.id), [circle.id])
    }

    /// Two seeds on disjoint shapes stay disjoint under Chain.
    func testChainDoesNotBridgeDisconnectedShapes() {
        let entities = square()
        let far: [SketchEntity] = [
            .line(id: UUID(), a: SIMD2(10, 10), b: SIMD2(11, 10)),
            .line(id: UUID(), a: SIMD2(11, 10), b: SIMD2(11, 11)),
        ]
        let all = entities + far
        let picked = SketchOffset.entitiesToOffset(
            seedIDs: [far[0].id], type: .chain, in: all
        )
        XCTAssertEqual(Set(picked.map(\.id)), Set(far.map(\.id)))
    }

    /// End to end through the facade the view model actually calls: pick the
    /// loop, offset inward, get a smaller square back.
    func testChainedSquareOffsetsInwardAsALoop() {
        let entities = square()
        let picked = SketchOffset.entitiesToOffset(
            seedIDs: [entities[0].id], type: .chain, in: entities
        )
        let offset = KernelOps.offsetSketchEntities(picked, by: -0.25)
        XCTAssertEqual(offset.count, 4)
        let points = offset.flatMap { entity -> [SIMD2<Double>] in
            guard case let .line(_, a, b) = entity else { return [] }
            return [a, b]
        }
        XCTAssertFalse(points.isEmpty)
        for p in points {
            XCTAssertGreaterThanOrEqual(p.x, 0.25 - 1e-9)
            XCTAssertLessThanOrEqual(p.x, 0.75 + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, 0.25 - 1e-9)
            XCTAssertLessThanOrEqual(p.y, 0.75 + 1e-9)
        }
    }
}
