//
//  FeatureBlendEvalTests.swift
//  openshape3dTests
//
//  Phase E tranche 1 proof: chamfer / fillet as parametric feature-graph nodes.
//  Mirrors FeatureGraphEvalTests — build the graph programmatically, evaluate,
//  assert geometry, then EDIT the blend amount and re-evaluate to prove the
//  persisted EdgeRef re-resolves against the rebuilt input body.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FeatureBlendEvalTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private func volume(_ body: Body) -> Double {
        MeasureKit.bodyVolume(body.render, scale: 1)
    }

    private let boxFeature = FeatureID()
    private let blendFeature = FeatureID()
    private let boxID = BodyID()

    private func boxNode() -> FeatureNode {
        FeatureNode(
            id: boxFeature, name: "Box",
            kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                             placement: .identity),
            outputBodyIDs: [boxID])
    }

    /// Evaluate the lone box and mint an EdgeRef for its first convex edge.
    private func captureFirstEdgeRef() throws -> (EdgeRef, Double) {
        let graph = FeatureGraph(nodes: [boxNode()])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let body = try XCTUnwrap(result.bodies.first, "box evaluates")
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let edge = try XCTUnwrap(edges.first { $0.isConvex }, "box has a convex edge")
        let ref = EdgeRef(
            body: BodyRef(producer: boxFeature, bodyID: boxID),
            signature: EdgeTopology.signature(of: edge))
        return (ref, Double(edge.length))
    }

    // MARK: Chamfer node

    func testChamferNodeRemovesTriangularPrism() throws {
        let (edgeRef, edgeLen) = try captureFirstEdgeRef()
        let d = 2.0
        let graph = FeatureGraph(nodes: [
            boxNode(),
            FeatureNode(id: blendFeature, name: "Chamfer",
                        kind: .chamfer(body: BodyRef(producer: boxFeature, bodyID: boxID),
                                       edges: [edgeRef], setback: Expr(value: d)),
                        outputBodyIDs: []),
        ])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        XCTAssertTrue(result.errors.isEmpty, "chamfer must not error: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(body.id, boxID, "the blended body keeps the box's BodyID")
        XCTAssertTrue(body.euclidMesh().isWatertight, "blended solid is watertight")
        // Removed ≈ ½·d²·edgeLen.
        XCTAssertEqual(volume(body), 1000 - 0.5 * d * d * edgeLen, accuracy: 0.05)
    }

    // MARK: Fillet node

    func testFilletNodeRoundsEdge() throws {
        let (edgeRef, edgeLen) = try captureFirstEdgeRef()
        let r = 2.0
        let graph = FeatureGraph(nodes: [
            boxNode(),
            FeatureNode(id: blendFeature, name: "Fillet",
                        kind: .fillet(body: BodyRef(producer: boxFeature, bodyID: boxID),
                                      edges: [edgeRef], radius: Expr(value: r)),
                        outputBodyIDs: []),
        ])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        XCTAssertTrue(result.errors.isEmpty, "fillet must not error: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first)
        XCTAssertTrue(body.euclidMesh().isWatertight, "filleted solid is watertight")
        // Removed ≈ r²(1 − π/4)·edgeLen — strictly less than the chamfer.
        XCTAssertEqual(volume(body), 1000 - r * r * (1 - .pi / 4) * edgeLen, accuracy: 0.5)
        XCTAssertGreaterThan(volume(body), 1000 - 0.5 * r * r * edgeLen,
                             "fillet keeps more material than the equal-setback chamfer")
    }

    // MARK: Edit the amount → re-resolve against the rebuilt body

    func testEditingSetbackRebuildsAndEdgeStillResolves() throws {
        let (edgeRef, edgeLen) = try captureFirstEdgeRef()
        func chamferGraph(_ d: Double) -> FeatureGraph {
            FeatureGraph(nodes: [
                boxNode(),
                FeatureNode(id: blendFeature, name: "Chamfer",
                            kind: .chamfer(body: BodyRef(producer: boxFeature, bodyID: boxID),
                                           edges: [edgeRef], setback: Expr(value: d)),
                            outputBodyIDs: []),
            ])
        }
        let small = chamferGraph(1).evaluate(sketches: [], planes: [],
                                             naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let big = chamferGraph(3).evaluate(sketches: [], planes: [],
                                           naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(big.errors[blendFeature], "edited chamfer still resolves the edge")
        let vSmall = volume(try XCTUnwrap(small.bodies.first))
        let vBig = volume(try XCTUnwrap(big.bodies.first))
        XCTAssertEqual(vSmall, 1000 - 0.5 * 1 * 1 * edgeLen, accuracy: 0.05)
        XCTAssertEqual(vBig, 1000 - 0.5 * 9 * edgeLen, accuracy: 0.1)
        XCTAssertLessThan(vBig, vSmall, "a bigger setback removes more material")
    }

    // MARK: Multi-edge blend (one feature, shared setback)

    func testChamferTwoParallelEdgesIsAdditive() throws {
        // Evaluate the box, pick an edge AND its parallel far-side twin — their
        // corner wedges are disjoint, so the removed volume is exactly 2×.
        let graph0 = FeatureGraph(nodes: [boxNode()])
        let result0 = graph0.evaluate(sketches: [], planes: [],
                                      naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let body0 = try XCTUnwrap(result0.bodies.first)
        let edges = EdgeTopology.selectableEdges(from: body0.render).filter { $0.isConvex }
        let first = try XCTUnwrap(edges.first)
        let twin = try XCTUnwrap(edges.first {
            abs(simd_dot($0.direction, first.direction)) > 0.99
                && simd_length($0.midpoint - first.midpoint) > 9   // opposite side
        }, "a box has a parallel edge on the far side")

        let bodyRef = BodyRef(producer: boxFeature, bodyID: boxID)
        let refs = [first, twin].map {
            EdgeRef(body: bodyRef, signature: EdgeTopology.signature(of: $0))
        }
        let d = 2.0
        let graph = FeatureGraph(nodes: [
            boxNode(),
            FeatureNode(id: blendFeature, name: "Chamfer",
                        kind: .chamfer(body: bodyRef, edges: refs, setback: Expr(value: d)),
                        outputBodyIDs: []),
        ])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.errors.isEmpty, "two-edge chamfer must not error: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first)
        XCTAssertTrue(body.euclidMesh().isWatertight)
        let edgeLen = Double(first.length)
        XCTAssertEqual(volume(body), 1000 - 2 * 0.5 * d * d * edgeLen, accuracy: 0.1,
                       "disjoint wedges remove exactly twice one edge's material")
    }

    // MARK: Unresolvable / empty edge set errors (History badge)

    func testEmptyEdgeSetErrors() throws {
        let graph = FeatureGraph(nodes: [
            boxNode(),
            FeatureNode(id: blendFeature, name: "Chamfer",
                        kind: .chamfer(body: BodyRef(producer: boxFeature, bodyID: boxID),
                                       edges: [], setback: Expr(value: 2)),
                        outputBodyIDs: []),
        ])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNotNil(result.errors[blendFeature], "a blend with no resolvable edge must error")
    }
}
