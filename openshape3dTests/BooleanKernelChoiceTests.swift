//
//  BooleanKernelChoiceTests.swift
//  openshape3dTests
//
//  `evalBoolean` used to run the Euclid mesh CSG first and the OCCT boolean
//  second — then `adoptBRep` replaced render, edges AND euclid from OCCT's
//  tessellation, discarding the mesh result entirely.
//
//  It was not a cheap thing to discard. For a 10 mm box minus a Ø4 cylinder the
//  Euclid subtract takes ~4,877 ms against the OCCT boolean's ~1 ms, so a
//  drilled box took ~7 SECONDS to evaluate and every `DeleteFaceEvalTests` case
//  paid it in setup — including the ones that assert an error and do no
//  geometry at all. Trying OCCT first takes the same fixture to ~74 ms.
//
//  Nothing about the resulting body changes; only the work that produces it.
//  These tests pin both halves of that claim, because the speed is worthless if
//  the geometry moved.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class BooleanKernelChoiceTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private let boxFeature = FeatureID()
    private let drillFeature = FeatureID()
    private let boxID = BodyID()
    private let toolID = BodyID()

    /// A 10 mm box with a Ø4 hole drilled through it, both operands analytic.
    private func drilledBox() -> EvalResult {
        let nodes = [
            FeatureNode(id: boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [boxID]),
            FeatureNode(id: drillFeature, name: "Drill",
                        kind: .primitive(spec: .cylinder(radius: 2, height: 30),
                                         placement: .identity),
                        outputBodyIDs: [toolID]),
            FeatureNode(id: FeatureID(), name: "Cut",
                        kind: .boolean(kind: .subtract,
                                       target: BodyRef(producer: boxFeature, bodyID: boxID),
                                       tools: [BodyRef(producer: drillFeature, bodyID: toolID)]),
                        outputBodyIDs: []),
        ]
        return FeatureGraph(nodes: nodes).evaluate(
            sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: RevisionSource().next)
    }

    /// The geometry must be exactly what it was: box minus cylinder, analytic,
    /// with the bore as one cylindrical face. This is the half that matters —
    /// a faster boolean that moved the shape would be a regression, not a fix.
    func testTheDrilledBoxIsUnchanged() throws {
        let body = try XCTUnwrap(drilledBox().bodies.first { $0.id == boxID })
        let brep = try XCTUnwrap(body.brep, "both operands are analytic")

        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.cylindrical, 1, "the bore, as one analytic wall")
        XCTAssertEqual(counts.planar, 6, "the box's own six faces")

        let expected = 1000 - Double.pi * 4 * 10   // box minus the drilled cylinder
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1), expected, accuracy: 1.0)
    }

    /// …and it must not take seconds. A generous ceiling: the point is to catch
    /// a return to running BOTH kernels, which cost ~7 s here.
    func testAnAnalyticBooleanDoesNotAlsoRunTheMeshKernel() {
        let started = ProcessInfo.processInfo.systemUptime
        _ = drilledBox()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 2.0,
                          "a drilled box took ~7 s when the Euclid CSG ran first "
                          + "and was then discarded by adoptBRep")
    }

    /// The Euclid fallback must still work when an operand has NO brep, which
    /// is the case the reordering could most easily have broken: the mesh path
    /// is now only reached if OCCT declines.
    func testAMeshOnlyOperandStillBooleansThroughEuclid() throws {
        // A lofted body with a holed section deliberately has no brep
        // (ThruSections takes one wire per section) — a genuine mesh-only body
        // rather than one contrived for the test.
        let lower = SketchID(), upper = SketchID()
        let outerID = UUID(), innerID = UUID(), upperID = UUID()
        let lowerSketch = Sketch(id: lower, plane: .ground, entities: [
            .circle(id: outerID, center: .zero, radius: 6),
            .circle(id: innerID, center: .zero, radius: 2),
        ])
        var topPlane = SketchPlane.ground
        topPlane.origin = SIMD3(0, 6, 0)
        let upperSketch = Sketch(id: upper, plane: topPlane, entities: [
            .circle(id: upperID, center: .zero, radius: 4),
        ])
        let loftFeature = FeatureID(), loftID = BodyID()
        let cubeFeature = FeatureID(), cubeID = BodyID()
        let nodes = [
            FeatureNode(id: loftFeature, name: "Loft",
                        kind: .loft(sections: [
                            ProfileRef(sketchID: lower, entityIDs: [outerID],
                                       holeEntityIDs: [[innerID]], seedPoint: nil),
                            ProfileRef(sketchID: upper, entityIDs: [upperID],
                                       holeEntityIDs: [], seedPoint: nil),
                        ], boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                        outputBodyIDs: [loftID]),
            FeatureNode(id: cubeFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 4, depth: 4, height: 4),
                                         placement: .identity),
                        outputBodyIDs: [cubeID]),
            FeatureNode(id: FeatureID(), name: "Cut",
                        kind: .boolean(kind: .subtract,
                                       target: BodyRef(producer: loftFeature, bodyID: loftID),
                                       tools: [BodyRef(producer: cubeFeature, bodyID: cubeID)]),
                        outputBodyIDs: []),
        ]
        let result = FeatureGraph(nodes: nodes).evaluate(
            sketches: [lowerSketch, upperSketch], planes: [],
            naming: SignatureNaming(), nextRevision: RevisionSource().next)

        let body = try XCTUnwrap(result.bodies.first { $0.id == loftID })
        XCTAssertFalse(body.render.positions.isEmpty,
                       "a mesh-only operand must still boolean through Euclid")
        XCTAssertGreaterThan(MeasureKit.bodyVolume(body.render, scale: 1), 0)
    }
}
