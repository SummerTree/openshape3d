//
//  ProfileSeedResolveTests.swift
//  openshape3dTests
//
//  The seed a profile reference records must lie INSIDE its region, and it
//  must decide between candidates when entity ids alone cannot. The vertex
//  average (`centroid`) is not inside a C, an L or a ring — found while
//  chasing a touch-committed counterbore that replayed wrong (practice
//  problem 4.38, 2026-09-04).
//

import XCTest
import simd
@testable import openshape3d

final class ProfileSeedResolveTests: XCTestCase {

    private func evaluate(_ nodes: [FeatureNode], _ sketches: [Sketch]) -> EvalResult {
        var rev: UInt64 = 0
        return FeatureGraph(nodes: nodes).evaluate(
            sketches: sketches, planes: [], naming: SignatureNaming(),
            nextRevision: { rev += 1; return rev })
    }

    /// A "C": 10 × 10 with a 6 × 8 mouth on the right. Its vertex average
    /// sits in the mouth, outside the material.
    private func cShape() -> [SIMD2<Double>] {
        [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 1), SIMD2(2, 1), SIMD2(2, 9),
         SIMD2(10, 9), SIMD2(10, 10), SIMD2(0, 10)]
    }

    func testInteriorPointOfACIsInsideWhereTheCentroidIsNot() {
        let profile = Profile(loop: cShape(), kind: .polygonal, sourceEntityIDs: [])
        XCTAssertFalse(profile.contains(profile.centroid), "the vertex average is in the mouth")
        XCTAssertTrue(profile.contains(profile.interiorPoint))
    }

    func testInteriorPointOfAConvexRegionIsItsCentroid() {
        let square = Profile(loop: [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4)],
                             kind: .polygonal, sourceEntityIDs: [])
        XCTAssertEqual(square.interiorPoint, square.centroid)
    }

    /// With no entity ids recorded the seed alone picks the region; the
    /// interior point of the C picks the C, not the rectangle beside it.
    func testSeedAloneResolvesTheRegionItLiesIn() throws {
        let sid = SketchID()
        let pts = cShape()
        var entities: [SketchEntity] = []
        for i in 0..<pts.count {
            entities.append(.line(id: UUID(), a: pts[i], b: pts[(i + 1) % pts.count]))
        }
        entities.append(.rect(id: UUID(), min: SIMD2(20, 0), max: SIMD2(30, 10)))
        let sketch = Sketch(id: sid, name: "S", plane: .ground, entities: entities)
        let c = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first { $0.loop.count == 8 })
        let body = BodyID()
        let node = FeatureNode(
            name: "Extrude",
            kind: .extrude(
                profile: ProfileRef(sketchID: sid, entityIDs: [], holeEntityIDs: [],
                                    seedPoint: c.interiorPoint),
                plane: PlaneRef(source: .sketch(sid)),
                distance: Expr(value: 5), symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []),
            outputBodyIDs: [body])
        let result = evaluate([node], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let volume = MeasureKit.volume(of: try XCTUnwrap(result.bodies.first { $0.id == body }))
        XCTAssertEqual(volume, (100 - 64) * 5, accuracy: 1e-6, "the C, 36 mm² × 5")
    }
}
