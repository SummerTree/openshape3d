//
//  DeleteFaceEvalTests.swift
//  openshape3dTests
//
//  Spec §4.16 Delete Face (direct modeling). The behaviour that matters is
//  HEALING: removing a hole's wall must leave a clean solid box, not a box with
//  a gap. That is only checkable on real B-rep geometry, so these tests build a
//  drilled box through the OCCT path and assert on the healed result.
//

import XCTest
import simd
@testable import openshape3d

final class DeleteFaceEvalTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private let boxFeature = FeatureID()
    private let drillFeature = FeatureID()
    private let deleteFeature = FeatureID()
    private let boxID = BodyID()
    private let toolID = BodyID()

    private var boxRef: BodyRef { BodyRef(producer: boxFeature, bodyID: boxID) }

    private func volume(_ body: Body) -> Double {
        MeasureKit.bodyVolume(body.render, scale: 1)
    }

    // MARK: Fixture — a 10 box with a Ø4 through-hole up the middle

    private func drilledNodes() -> [FeatureNode] {
        [
            FeatureNode(
                id: boxFeature, name: "Box",
                kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                 placement: .identity),
                outputBodyIDs: [boxID]),
            FeatureNode(
                id: drillFeature, name: "Drill",
                kind: .primitive(spec: .cylinder(radius: 2, height: 30),
                                 placement: .identity),
                outputBodyIDs: [toolID]),
            FeatureNode(
                id: FeatureID(), name: "Cut",
                kind: .boolean(kind: .subtract, target: boxRef,
                               tools: [BodyRef(producer: drillFeature, bodyID: toolID)]),
                outputBodyIDs: []),
        ]
    }

    private func evaluate(_ nodes: [FeatureNode]) -> EvalResult {
        FeatureGraph(nodes: nodes).evaluate(
            sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: RevisionSource().next)
    }

    /// Mint a FaceRef for the hole's cylindrical wall, the way a face tap would.
    private func holeFaceRef(in body: Body) throws -> FaceRef {
        let render = body.render
        var found: FaceTopology.CylindricalFace?
        for t in 0..<render.triangleCount {
            if let cyl = FaceTopology.cylindricalFace(in: render, seedTriangle: t),
               abs(cyl.radius - 2) < 0.1 {
                found = cyl
                break
            }
        }
        let cyl = try XCTUnwrap(found, "the drilled box has a Ø4 cylindrical wall")
        let mid = (cyl.minT + cyl.maxT) / 2
        let axis = simd_normalize(cyl.axisDir)
        let centroid = cyl.axisPoint + axis * (mid - simd_dot(cyl.axisPoint, axis))
        let signature = FaceSignature(
            kind: .cylindrical(radius: cyl.radius),
            normal: axis, centroid: centroid,
            area: 2 * .pi * cyl.radius * cyl.height,
            planeOffset: simd_dot(axis, centroid))
        return FaceRef(body: boxRef, creator: boxFeature,
                       role: .derived(index: 0), signature: signature)
    }

    // MARK: The headline behaviour

    func testDeletingAHolesWallHealsTheBodyBackToASolid() throws {
        try XCTSkipUnless(OCCTKernel.useOCCTAsSourceOfTruth,
                          "delete face is B-rep only")
        let drilled = try XCTUnwrap(evaluate(drilledNodes()).bodies.first)
        let drilledVolume = volume(drilled)
        XCTAssertLessThan(drilledVolume, 1000,
                          "the drill removed material")

        var nodes = drilledNodes()
        nodes.append(FeatureNode(
            id: deleteFeature, name: "Delete Face",
            kind: .deleteFace(body: boxRef, faces: [try holeFaceRef(in: drilled)]),
            outputBodyIDs: []))
        let result = evaluate(nodes)

        XCTAssertNil(result.errors[deleteFeature], "the hole's neighbours can heal")
        let healed = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(volume(healed), 1000, accuracy: 5,
                       "the hole is gone — the box is solid again")
        XCTAssertGreaterThan(volume(healed), drilledVolume,
                             "healing ADDS the drilled material back")
    }

    func testHealedBodyHasNoCylindricalFaceLeft() throws {
        try XCTSkipUnless(OCCTKernel.useOCCTAsSourceOfTruth,
                          "delete face is B-rep only")
        let drilled = try XCTUnwrap(evaluate(drilledNodes()).bodies.first)
        var nodes = drilledNodes()
        nodes.append(FeatureNode(
            id: deleteFeature, name: "Delete Face",
            kind: .deleteFace(body: boxRef, faces: [try holeFaceRef(in: drilled)]),
            outputBodyIDs: []))
        let healed = try XCTUnwrap(evaluate(nodes).bodies.first)
        let brep = try XCTUnwrap(healed.brep, "the healed body stays analytic")
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.cylindrical, 0, "the hole's wall is gone")
        XCTAssertEqual(counts.planar, 6, "a plain box: six planar faces")
    }

    // MARK: Failure modes are reported, not swallowed

    func testEmptyFaceListIsRejected() throws {
        var nodes = drilledNodes()
        nodes.append(FeatureNode(
            id: deleteFeature, name: "Delete Face",
            kind: .deleteFace(body: boxRef, faces: []),
            outputBodyIDs: []))
        let result = evaluate(nodes)
        XCTAssertNotNil(result.errors[deleteFeature],
                        "deleting nothing is an error, not a silent no-op")
    }

    func testUnresolvableFaceErrorsAndLeavesTheBodyAlone() throws {
        let drilled = try XCTUnwrap(evaluate(drilledNodes()).bodies.first)
        let before = volume(drilled)

        // A face far outside the body, with a mismatched area — nothing scores
        // above the resolve threshold.
        let bogus = FaceRef(
            body: boxRef, creator: boxFeature, role: .derived(index: 99),
            signature: FaceSignature(
                kind: .planar, normal: SIMD3(0, 0, 1),
                centroid: SIMD3(500, 500, 500), area: 12345,
                planeOffset: 500))
        var nodes = drilledNodes()
        nodes.append(FeatureNode(
            id: deleteFeature, name: "Delete Face",
            kind: .deleteFace(body: boxRef, faces: [bogus]), outputBodyIDs: []))
        let result = evaluate(nodes)

        XCTAssertNotNil(result.errors[deleteFeature])
        let body = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(volume(body), before, accuracy: 1e-6,
                       "a failed delete must not mutate the body")
    }

    func testUnknownBodyRefIsABrokenRefNotACrash() {
        var nodes = drilledNodes()
        nodes.append(FeatureNode(
            id: deleteFeature, name: "Delete Face",
            kind: .deleteFace(body: BodyRef(producer: boxFeature, bodyID: BodyID()),
                              faces: []),
            outputBodyIDs: []))
        XCTAssertNotNil(evaluate(nodes).errors[deleteFeature])
    }

    // MARK: Schema

    func testDeleteFaceSurvivesACodableRoundTrip() throws {
        let kind = FeatureKind.deleteFace(body: boxRef, faces: [])
        let data = try JSONEncoder().encode(kind)
        let back = try JSONDecoder().decode(FeatureKind.self, from: data)
        guard case let .deleteFace(body, faces) = back else {
            return XCTFail("expected a deleteFace node")
        }
        XCTAssertEqual(body, boxRef)
        XCTAssertTrue(faces.isEmpty)
    }
}
