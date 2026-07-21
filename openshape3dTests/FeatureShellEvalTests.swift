//
//  FeatureShellEvalTests.swift
//  openshape3dTests
//
//  Phase E tranche 4 proof: Shell as a parametric feature-graph node. Mirrors
//  FeatureBlendEvalTests — build the graph programmatically, evaluate, assert
//  geometry, then EDIT the thickness and re-evaluate to prove the persisted
//  FaceRef re-resolves against the rebuilt input body.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FeatureShellEvalTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private func volume(_ body: Body) -> Double {
        MeasureKit.bodyVolume(body.render, scale: 1)
    }

    private let boxFeature = FeatureID()
    private let shellFeature = FeatureID()
    private let boxID = BodyID()

    private func boxNode() -> FeatureNode {
        FeatureNode(
            id: boxFeature, name: "Box",
            kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                             placement: .identity),
            outputBodyIDs: [boxID])
    }

    /// Evaluate the lone box and mint a FaceRef for its +Z (top) face, the
    /// same way `EditorViewModel.commitShell` pins open faces.
    private func captureTopFaceRef() throws -> FaceRef {
        let graph = FeatureGraph(nodes: [boxNode()])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let body = try XCTUnwrap(result.bodies.first, "box evaluates")
        let render = body.render
        var top: PlanarFace?
        for t in 0..<render.triangleCount {
            let a = render.positions[Int(render.indices[t * 3])]
            let b = render.positions[Int(render.indices[t * 3 + 1])]
            let c = render.positions[Int(render.indices[t * 3 + 2])]
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            guard len > 1e-9, (n / len).z > 0.999 else { continue }
            top = FaceTopology.planarFace(in: render, seedTriangle: t)
            break
        }
        let face = try XCTUnwrap(top, "box has a +Z face")
        let normal = SIMD3<Double>(
            Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        var area = abs(Profile.signedArea(face.outline))
        for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
        let signature = FaceSignature(
            kind: .planar, normal: normal, centroid: face.origin,
            area: max(area, 0), planeOffset: simd_dot(normal, face.origin))
        return FaceRef(
            body: BodyRef(producer: boxFeature, bodyID: boxID),
            creator: boxFeature, role: .derived(index: 0), signature: signature)
    }

    private func shellGraph(openFaces: [FaceRef], thickness: Double) -> FeatureGraph {
        FeatureGraph(nodes: [
            boxNode(),
            FeatureNode(id: shellFeature, name: "Shell",
                        kind: .shell(body: BodyRef(producer: boxFeature, bodyID: boxID),
                                     openFaces: openFaces,
                                     thickness: Expr(value: thickness)),
                        outputBodyIDs: []),
        ])
    }

    // MARK: Closed hollow node

    func testClosedShellNodeHollowsBox() throws {
        let result = shellGraph(openFaces: [], thickness: 1)
            .evaluate(sketches: [], planes: [],
                      naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.errors.isEmpty, "shell must not error: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(body.id, boxID, "the shelled body keeps the box's BodyID")
        // Walls of 1 around an 8³ cavity.
        XCTAssertEqual(volume(body), 1000 - 512, accuracy: 1.0)
    }

    // MARK: Open-face node

    func testOpenTopShellNodeCutsOpening() throws {
        let topRef = try captureTopFaceRef()
        let result = shellGraph(openFaces: [topRef], thickness: 1)
            .evaluate(sketches: [], planes: [],
                      naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.errors.isEmpty, "open shell must not error: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first)
        // Open-top box: 1000 − 8·8·9.
        XCTAssertEqual(volume(body), 424, accuracy: 1.0)
    }

    // MARK: Edit thickness → FaceRef re-resolves against the rebuilt body

    func testEditingThicknessRebuildsAndFaceStillResolves() throws {
        let topRef = try captureTopFaceRef()
        let thin = shellGraph(openFaces: [topRef], thickness: 1)
            .evaluate(sketches: [], planes: [],
                      naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let thick = shellGraph(openFaces: [topRef], thickness: 2)
            .evaluate(sketches: [], planes: [],
                      naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(thick.errors[shellFeature], "edited shell still resolves the face")
        // t=2: 6×6 cavity through 8 of the 10 height → 1000 − 288.
        XCTAssertEqual(volume(try XCTUnwrap(thin.bodies.first)), 424, accuracy: 1.0)
        XCTAssertEqual(volume(try XCTUnwrap(thick.bodies.first)), 712, accuracy: 1.5)
    }

    // MARK: Errors

    func testOverThickShellErrorsNode() throws {
        let result = shellGraph(openFaces: [], thickness: 6)
            .evaluate(sketches: [], planes: [],
                      naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNotNil(result.errors[shellFeature], "an over-thick shell errors the node")
    }

    func testZeroThicknessErrorsNode() throws {
        let result = shellGraph(openFaces: [], thickness: 0)
            .evaluate(sketches: [], planes: [],
                      naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNotNil(result.errors[shellFeature])
    }
}
