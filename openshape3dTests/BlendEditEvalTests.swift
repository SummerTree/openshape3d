//
//  BlendEditEvalTests.swift
//  openshape3dTests
//
//  Mission 3 item 3 (`docs/STATUS_AND_NEXT_STEPS.md` §4.3): re-opening an
//  existing chamfer/fillet to change WHICH EDGES it blends.
//
//  The whole difficulty is that a blend replaces its body in place. By the time
//  the user asks to edit the feature, the body under that `BodyID` already has
//  the blend on it — so re-picking against it would offer the ROUNDED edges of
//  the result rather than the sharp edges the feature actually names, and the
//  preview would blend an already-blended body a second time.
//
//  `DocumentSession.inputBody(for:bodyID:)` recovers the pre-blend body by
//  replaying a copy of the graph truncated to just before the node. That
//  truncation is the part worth testing as pure values, and it is what these
//  tests cover — the session wrapper adds no geometry of its own, and per repo
//  convention no `DocumentSession` is instantiated here.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class BlendEditEvalTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private let boxFeature = FeatureID()
    private let blendFeature = FeatureID()
    private let boxID = BodyID()
    private let side = 10.0
    private var boxVolume: Double { side * side * side }

    private func volume(_ body: Body) -> Double {
        MeasureKit.bodyVolume(body.render, scale: 1)
    }

    private func boxNode() -> FeatureNode {
        FeatureNode(
            id: boxFeature, name: "Box",
            kind: .primitive(spec: .box(width: side, depth: side, height: side),
                             placement: .identity),
            outputBodyIDs: [boxID])
    }

    private var bodyRef: BodyRef { BodyRef(producer: boxFeature, bodyID: boxID) }

    private func evaluate(_ graph: FeatureGraph) -> EvalResult {
        graph.evaluate(sketches: [], planes: [],
                       naming: SignatureNaming(), nextRevision: RevisionSource().next)
    }

    /// The plain box, and refs for `count` of its convex edges — chosen so no
    /// two of them SHARE A CORNER.
    ///
    /// Adjacent edges matter here: their blends overlap at the corner they
    /// share, so two of them remove measurably less than twice one (9.34 mm³
    /// against 9.67 for this box). That is correct geometry, and it makes the
    /// additivity check below meaningless. Disjoint edges restore it.
    private func edgeRefs(_ count: Int) throws -> [EdgeRef] {
        let body = try XCTUnwrap(evaluate(FeatureGraph(nodes: [boxNode()])).bodies.first)
        let edges = EdgeTopology.selectableEdges(from: body.render).filter(\.isConvex)

        func touches(_ a: SelectableEdge, _ b: SelectableEdge) -> Bool {
            let ends = [a.start, a.end]
            return ends.contains { p in
                simd_length(p - b.start) < 1e-4 || simd_length(p - b.end) < 1e-4
            }
        }
        var picked: [SelectableEdge] = []
        for edge in edges where picked.count < count {
            if picked.allSatisfy({ !touches($0, edge) }) { picked.append(edge) }
        }
        XCTAssertEqual(picked.count, count, "need \(count) mutually disjoint edges")
        return picked.map {
            EdgeRef(body: bodyRef, signature: EdgeTopology.signature(of: $0))
        }
    }

    private func filletGraph(_ refs: [EdgeRef], radius: Double = 1.5) -> FeatureGraph {
        FeatureGraph(nodes: [
            boxNode(),
            FeatureNode(id: blendFeature, name: "Fillet",
                        kind: .fillet(body: bodyRef, edges: refs,
                                      radius: Expr(value: radius)),
                        outputBodyIDs: [boxID]),
        ])
    }

    // MARK: - Recovering the input body

    /// Truncating the graph at the blend node yields the body the blend
    /// CONSUMED — the sharp box, not the rounded result.
    func testTruncatingAtTheBlendYieldsThePreBlendBody() throws {
        var graph = filletGraph(try edgeRefs(1))

        let blended = try XCTUnwrap(evaluate(graph).bodies.first)
        XCTAssertLessThan(volume(blended), boxVolume, "the fillet ran")

        graph.rollbackIndex = 1          // everything before the blend node
        let input = try XCTUnwrap(evaluate(graph).bodies.first)
        XCTAssertEqual(volume(input), boxVolume, accuracy: 1e-6,
                       "the input body must be the box, with no blend on it")
    }

    /// …and its edges are the SHARP ones. This is the difference that matters:
    /// re-picking against the blended body would offer the rounded rim, and
    /// the stored EdgeRefs would not resolve against it at all.
    func testTheInputBodyStillHasItsSharpEdges() throws {
        var graph = filletGraph(try edgeRefs(1))
        let blended = try XCTUnwrap(evaluate(graph).bodies.first)

        graph.rollbackIndex = 1
        let input = try XCTUnwrap(evaluate(graph).bodies.first)

        let inputEdges = EdgeTopology.selectableEdges(from: input.render).filter(\.isConvex)
        let blendedEdges = EdgeTopology.selectableEdges(from: blended.render).filter(\.isConvex)
        XCTAssertEqual(inputEdges.count, 12, "a box has 12 convex edges")
        XCTAssertNotEqual(blendedEdges.count, inputEdges.count,
                          "rounding one edge must change the edge set — otherwise "
                          + "this test proves nothing about which body we picked")
    }

    /// The stored refs must RESOLVE against the recovered body — that is what
    /// lets the panel re-open a blend with its existing edges already selected.
    func testStoredRefsResolveAgainstTheRecoveredBody() throws {
        let refs = try edgeRefs(2)
        var graph = filletGraph(refs)
        graph.rollbackIndex = 1
        let input = try XCTUnwrap(evaluate(graph).bodies.first)

        let aabb = input.render.localAABB
        let scale = Double(simd_length(aabb.max - aabb.min))
        let available = EdgeTopology.selectableEdges(from: input.render)
        let resolved = refs.compactMap {
            EdgeTopology.resolve($0.signature, in: available, sizeScale: scale)
        }
        XCTAssertEqual(resolved.count, refs.count, "every stored edge comes back")
    }

    // MARK: - The edit itself

    /// Editing the node's EDGE LIST re-blends from the same input: two edges
    /// remove strictly more than one, and the box is not blended twice.
    func testEditingTheEdgeListChangesTheResult() throws {
        let one = evaluate(filletGraph(try edgeRefs(1))).bodies.first
        let two = evaluate(filletGraph(try edgeRefs(2))).bodies.first
        let vOne = try XCTUnwrap(one.map(volume))
        let vTwo = try XCTUnwrap(two.map(volume))

        XCTAssertLessThan(vTwo, vOne, "two filleted edges remove more than one")
        XCTAssertLessThan(vOne, boxVolume)
        // The two edges are disjoint and of equal length, so the removals simply
        // add — which also shows each evaluation started from the SHARP box
        // rather than compounding onto the previous result.
        XCTAssertEqual(boxVolume - vTwo, 2 * (boxVolume - vOne), accuracy: 0.05)
    }

    /// Removing every edge is a legitimate edit target in the panel, and it
    /// must surface as an error rather than silently leaving the old geometry:
    /// a blend that names no edge has nothing to replay.
    func testABlendWithNoEdgesErrorsRatherThanSilentlyKeepingTheOldShape() throws {
        let result = evaluate(filletGraph([]))
        XCTAssertNotNil(result.errors[blendFeature],
                        "an edgeless blend must report a broken ref")
    }

    /// Shrinking the radius to zero is likewise refused rather than replayed —
    /// the same guard `canCommitBlend` applies live.
    func testAZeroRadiusBlendErrors() throws {
        let result = evaluate(filletGraph(try edgeRefs(1), radius: 0))
        XCTAssertNotNil(result.errors[blendFeature])
    }
}
