//
//  ReplaceFaceEvalTests.swift
//  openshape3dTests
//
//  Spec §4.12 Replace Face as a FEATURE — the parametric replay, not the kit.
//  Two things are being pinned here that the kit tests cannot see:
//
//    1. The node re-resolves its `FaceRef` against the rebuilt body, so a
//       replace still lands on the right face after an upstream edit.
//    2. A body that arrived analytic stays analytic. That is the failure that
//       would not look like one: the shape renders correctly and only degrades
//       at the next save.
//

import XCTest
import simd
@testable import openshape3d

final class ReplaceFaceEvalTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private let boxFeature = FeatureID()
    private let replaceFeature = FeatureID()
    private let boxID = BodyID()

    private var boxRef: BodyRef { BodyRef(producer: boxFeature, bodyID: boxID) }

    private func boxNodes(height: Double = 10) -> [FeatureNode] {
        [FeatureNode(
            id: boxFeature, name: "Box",
            kind: .primitive(spec: .box(width: 10, depth: 10, height: height),
                             placement: .identity),
            outputBodyIDs: [boxID])]
    }

    private func evaluate(_ nodes: [FeatureNode]) -> EvalResult {
        FeatureGraph(nodes: nodes).evaluate(
            sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: RevisionSource().next)
    }

    /// A `FaceRef` for the box's top face, minted the way the live tool does.
    private func topFaceRef(in body: Body) throws -> FaceRef {
        let render = body.render
        var top: PlanarFace?
        for t in 0..<render.triangleCount {
            let n = render.normals[Int(render.indices[t * 3])]
            guard n.y > 0.999 else { continue }
            top = FaceTopology.planarFace(in: render, seedTriangle: t)
            if top != nil { break }
        }
        let face = try XCTUnwrap(top, "the box has a top face")
        return FaceRef(body: boxRef, creator: boxFeature, role: .derived(index: 0),
                       signature: SignatureNaming.signature(planar: face))
    }

    private func replaceNode(_ ref: FaceRef, toY y: Double, flip: Bool = false) -> FeatureNode {
        FeatureNode(
            id: replaceFeature, name: "Replace Face",
            kind: .replaceFace(
                face: ref,
                targetOrigin: PointWrapper(SIMD3(0, y, 0)),
                targetNormal: PointWrapper(SIMD3(0, 1, 0)),
                flip: flip),
            outputBodyIDs: [])
    }

    private func height(_ body: Body) -> Double {
        let aabb = body.render.localAABB
        return Double(aabb.max.y - aabb.min.y)
    }

    // MARK: The headline behaviour

    func testReplacingTheTopFaceMovesItOntoTheTargetPlane() throws {
        let box = try XCTUnwrap(evaluate(boxNodes()).bodies.first)
        XCTAssertEqual(height(box), 10, accuracy: 1e-4)

        var nodes = boxNodes()
        nodes.append(replaceNode(try topFaceRef(in: box), toY: 17))
        let result = evaluate(nodes)

        XCTAssertNil(result.errors[replaceFeature])
        let replaced = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(height(replaced), 17, accuracy: 1e-3,
                       "the top now sits on the target plane")
    }

    func testTrimmingBackIsTheSameOperationInReverse() throws {
        let box = try XCTUnwrap(evaluate(boxNodes()).bodies.first)
        var nodes = boxNodes()
        nodes.append(replaceNode(try topFaceRef(in: box), toY: 6))
        let replaced = try XCTUnwrap(evaluate(nodes).bodies.first)
        XCTAssertEqual(height(replaced), 6, accuracy: 1e-3)
    }

    /// The point of the analytic branch: a box in, a box out, still six
    /// analytic planar faces. A mesh result would have no `brep` at all.
    func testAnAnalyticBodyStaysAnalytic() throws {
        try XCTSkipUnless(OCCTKernel.useOCCTAsSourceOfTruth, "analytic path off")
        let box = try XCTUnwrap(evaluate(boxNodes()).bodies.first)
        XCTAssertNotNil(box.brep, "the primitive arrives analytic")

        var nodes = boxNodes()
        nodes.append(replaceNode(try topFaceRef(in: box), toY: 17))
        let replaced = try XCTUnwrap(evaluate(nodes).bodies.first)

        let brep = try XCTUnwrap(replaced.brep,
                                 "replace face must not silently drop the B-rep")
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar, 6, "a taller box is still six planar faces")
        XCTAssertEqual(counts.other, 0, "no stray seam faces from the fuse")
    }

    // MARK: Associativity — the ref re-resolves after an upstream edit

    /// The node stores a FaceRef, not a triangle list. Make the box taller
    /// upstream and the replace must still find the TOP face and put it on the
    /// same target plane — a stale reference would either error or move a side.
    func testTheReplacedFaceFollowsAnUpstreamEdit() throws {
        let box = try XCTUnwrap(evaluate(boxNodes(height: 10)).bodies.first)
        let ref = try topFaceRef(in: box)

        var taller = boxNodes(height: 14)
        taller.append(replaceNode(ref, toY: 17))
        let result = evaluate(taller)

        XCTAssertNil(result.errors[replaceFeature],
                     "the ref must still resolve against the rebuilt box")
        let replaced = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(height(replaced), 17, accuracy: 1e-3,
                       "the target plane is absolute, so the answer is the same height")
    }

    // MARK: Refusals surface as feature errors

    /// A target that is not parallel is a real geometric refusal, and it has to
    /// reach the History panel as an error rather than silently doing nothing.
    func testANonParallelTargetErrorsTheNode() throws {
        let box = try XCTUnwrap(evaluate(boxNodes()).bodies.first)
        var nodes = boxNodes()
        nodes.append(FeatureNode(
            id: replaceFeature, name: "Replace Face",
            kind: .replaceFace(
                face: try topFaceRef(in: box),
                targetOrigin: PointWrapper(SIMD3(0, 17, 0)),
                targetNormal: PointWrapper(simd_normalize(SIMD3<Double>(1, 1, 0))),
                flip: false),
            outputBodyIDs: []))

        let result = evaluate(nodes)
        guard case .kernelFailure(let message)? = result.errors[replaceFeature] else {
            return XCTFail("a non-parallel target must error, got \(String(describing: result.errors[replaceFeature]))")
        }
        XCTAssertTrue(message.contains("parallel"), "the message should say why: \(message)")
    }

    /// A target plane that passes through the face itself is "no change" —
    /// also an error, not a no-op that leaves the user wondering.
    func testATargetOnTheFaceItselfErrorsTheNode() throws {
        let box = try XCTUnwrap(evaluate(boxNodes()).bodies.first)
        var nodes = boxNodes()
        nodes.append(replaceNode(try topFaceRef(in: box), toY: 10))
        XCTAssertNotNil(evaluate(nodes).errors[replaceFeature])
    }
}
