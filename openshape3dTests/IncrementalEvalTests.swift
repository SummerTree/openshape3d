//
//  IncrementalEvalTests.swift
//  openshape3dTests
//
//  Memoised replay (docs/INCREMENTAL_EVAL_DESIGN.md), slice 1: a second replay
//  with a cache runs no kernel work for unchanged nodes, an edit re-runs only
//  the node and its dependents, and a cached replay is body-for-body the
//  uncached one. Pure values: FeatureGraph + sketches, no session.
//

import XCTest
import simd
@testable import openshape3d

final class IncrementalEvalTests: XCTestCase {

    /// Two boxes on their own sketches, and a union of them (A ∪ B → A's slot).
    private struct Fixture {
        let sketchA = SketchID(), sketchB = SketchID()
        let rectA = UUID(), rectB = UUID()
        let nodeA = FeatureID(), nodeB = FeatureID(), nodeU = FeatureID()
        let bodyA = BodyID(), bodyB = BodyID()

        func sketches(sizeA: Double = 10) -> [Sketch] {
            [Sketch(id: sketchA, name: "A", plane: .ground, entities: [
                .rect(id: rectA, min: SIMD2(0, 0), max: SIMD2(sizeA, sizeA))]),
             Sketch(id: sketchB, name: "B", plane: .ground, entities: [
                .rect(id: rectB, min: SIMD2(5, 5), max: SIMD2(15, 15))])]
        }

        func extrude(_ id: FeatureID, sketch: SketchID, rect: UUID, body: BodyID,
                     distance: Double, seed: SIMD2<Double>) -> FeatureNode {
            FeatureNode(id: id, name: "E", kind: .extrude(
                profile: ProfileRef(sketchID: sketch, entityIDs: [rect],
                                    holeEntityIDs: [], seedPoint: seed),
                plane: PlaneRef(source: .sketch(sketch)), distance: Expr(value: distance),
                symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []), outputBodyIDs: [body])
        }

        func graph(distanceA: Double = 10, distanceB: Double = 10,
                   withUnion: Bool = true, suppressB: Bool = false) -> FeatureGraph {
            var b = extrude(nodeB, sketch: sketchB, rect: rectB, body: bodyB,
                            distance: distanceB, seed: SIMD2(10, 10))
            b.suppressed = suppressB
            var nodes = [extrude(nodeA, sketch: sketchA, rect: rectA, body: bodyA,
                                 distance: distanceA, seed: SIMD2(2, 2)), b]
            if withUnion {
                nodes.append(FeatureNode(id: nodeU, name: "U", kind: .boolean(
                    kind: .union, target: BodyRef(producer: nodeA, bodyID: bodyA),
                    tools: [BodyRef(producer: nodeB, bodyID: bodyB)]), outputBodyIDs: [bodyA]))
            }
            return FeatureGraph(nodes: nodes)
        }
    }

    private var counter: UInt64 = 0

    private func replay(_ graph: FeatureGraph, _ sketches: [Sketch],
                        cache: inout EvalCache) -> EvalResult {
        graph.evaluate(sketches: sketches, planes: [], naming: SignatureNaming(),
                       nextRevision: { self.counter += 1; return self.counter }, cache: &cache)
    }

    private func revisions(_ r: EvalResult) -> [BodyID: UInt64] {
        Dictionary(uniqueKeysWithValues: r.bodies.map { ($0.id, $0.meshRevision) })
    }

    func testSecondReplayRunsNothingAndKeepsRevisions() {
        let f = Fixture(); var cache = EvalCache()
        let first = replay(f.graph(), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.lastRan, 3); XCTAssertEqual(cache.lastSkipped, 0)
        let second = replay(f.graph(), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.lastRan, 0, "nothing changed: no kernel work at all")
        XCTAssertEqual(cache.lastSkipped, 3)
        XCTAssertEqual(revisions(second), revisions(first), "unchanged nodes keep their revisions")
        XCTAssertTrue(second.errors.isEmpty)
    }

    func testEditingTheToolRerunsItAndTheUnionOnly() {
        let f = Fixture(); var cache = EvalCache()
        let first = replay(f.graph(), f.sketches(), cache: &cache)
        let second = replay(f.graph(distanceB: 20), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.lastSkipped, 1, "A is untouched")
        XCTAssertEqual(cache.lastRan, 2, "B, and the union that consumes it")
        let v1 = try! XCTUnwrap(first.bodies.first { $0.id == f.bodyA })
        let v2 = try! XCTUnwrap(second.bodies.first { $0.id == f.bodyA })
        XCTAssertNotEqual(v1.meshRevision, v2.meshRevision, "the union re-emitted")
        XCTAssertGreaterThan(MeasureKit.volume(of: v2), MeasureKit.volume(of: v1),
                             "a taller tool grows the union")
        _ = replay(f.graph(distanceB: 20), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.lastRan, 0, "and an identical third replay skips everything")
        XCTAssertEqual(cache.lastSkipped, 3)
    }

    func testEditingTheTargetRerunsItAndTheUnionNotTheTool() {
        let f = Fixture(); var cache = EvalCache()
        _ = replay(f.graph(), f.sketches(), cache: &cache)
        _ = replay(f.graph(distanceA: 20), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.lastSkipped, 1, "B is untouched")
        XCTAssertEqual(cache.lastRan, 2, "A and the union")
    }

    func testSketchEditInvalidatesOnlyItsConsumers() {
        let f = Fixture(); var cache = EvalCache()
        _ = replay(f.graph(), f.sketches(), cache: &cache)
        _ = replay(f.graph(), f.sketches(sizeA: 12), cache: &cache)
        XCTAssertEqual(cache.lastSkipped, 1, "B reads sketch B only")
        XCTAssertEqual(cache.lastRan, 2, "A (its sketch changed) and the union downstream")
    }

    /// The memo must be invisible in the result: a replay that spliced A and
    /// ran B + U is body-for-body what a from-scratch replay produces.
    func testCachedReplayMatchesUncachedBodyForBody() {
        let f = Fixture(); var cache = EvalCache()
        _ = replay(f.graph(), f.sketches(), cache: &cache)
        let cached = replay(f.graph(distanceB: 20), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.lastSkipped, 1)
        var fresh: UInt64 = 0
        let uncached = f.graph(distanceB: 20).evaluate(
            sketches: f.sketches(), planes: [], naming: SignatureNaming(),
            nextRevision: { fresh += 1; return fresh })
        XCTAssertEqual(cached.bodies.map(\.id), uncached.bodies.map(\.id), "same bodies, same order")
        for (c, u) in zip(cached.bodies, uncached.bodies) {
            XCTAssertEqual(MeasureKit.volume(of: c), MeasureKit.volume(of: u), accuracy: 1e-9)
            XCTAssertEqual(c.render.positions.count, u.render.positions.count)
            XCTAssertEqual(c.brep != nil, u.brep != nil)
        }
        XCTAssertEqual(cached.faceTables.count, uncached.faceTables.count)
        XCTAssertEqual(cached.kernelNames.count, uncached.kernelNames.count)
        XCTAssertEqual(cached.errors, uncached.errors)
    }

    func testSuppressingTheToolInvalidatesTheUnionAndDropsItsEntry() {
        let f = Fixture(); var cache = EvalCache()
        _ = replay(f.graph(), f.sketches(), cache: &cache)
        let r = replay(f.graph(suppressB: true), f.sketches(), cache: &cache)
        XCTAssertNil(cache.entries[f.nodeB], "a suppressed node has no entry")
        XCTAssertEqual(cache.lastSkipped, 1, "A")
        XCTAssertEqual(cache.lastRan, 1, "the union re-ran: its tool vanished")
        XCTAssertNil(r.bodies.first { $0.id == f.bodyB })
        _ = replay(f.graph(), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.lastRan, 2, "un-suppressed: B runs, and so does the union")
        XCTAssertEqual(cache.lastSkipped, 1)
    }

    func testRemovedNodeIsPrunedFromTheCache() {
        let f = Fixture(); var cache = EvalCache()
        _ = replay(f.graph(), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.entries.count, 3)
        _ = replay(f.graph(withUnion: false), f.sketches(), cache: &cache)
        XCTAssertEqual(cache.entries.count, 2)
        XCTAssertNil(cache.entries[f.nodeU])
        XCTAssertEqual(cache.lastSkipped, 2, "both extrudes untouched")
    }

    /// The fingerprint is stable for equal content and differs for different
    /// content — the property the whole memo rests on.
    func testFingerprintIsDeterministicAndContentSensitive() {
        let f = Fixture()
        let a = EvalFingerprint.hash(f.sketches()[0]), b = EvalFingerprint.hash(f.sketches()[0])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, EvalFingerprint.hash(f.sketches(sizeA: 12)[0]))
    }
}
