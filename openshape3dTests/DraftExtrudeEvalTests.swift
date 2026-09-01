//
//  DraftExtrudeEvalTests.swift
//  openshape3dTests
//
//  Draft/taper extrude at the graph level (playbook M1, slice 1): the
//  acceptance test from the design doc — an angle in, the analytic frustum
//  volume out — plus the honest refusals (holes, over-taper).
//

import XCTest
import simd
@testable import openshape3d

final class DraftExtrudeEvalTests: XCTestCase {

    private func evaluate(_ nodes: [FeatureNode], _ sketches: [Sketch]) -> EvalResult {
        var rev: UInt64 = 0
        return FeatureGraph(nodes: nodes).evaluate(
            sketches: sketches, planes: [], naming: SignatureNaming(),
            nextRevision: { rev += 1; return rev })
    }

    private func draftNode(_ feature: FeatureID, _ bodyID: BodyID,
                           sketch: SketchID, rect: UUID,
                           distance: Double, taper: Double) -> FeatureNode {
        FeatureNode(
            id: feature, name: "Draft",
            kind: .draftExtrude(
                profile: ProfileRef(sketchID: sketch, entityIDs: [rect],
                                    holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(sketch)),
                distance: Expr(value: distance),
                taperAngle: Expr(value: taper),
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [bodyID])
    }

    /// The design-doc acceptance test: a 40×40 square drafted 10° over 20 mm
    /// tapers to a 32.946 mm top and encloses the analytic square-frustum
    /// volume `h/3·(A₁+A₂+√(A₁A₂))` = 26,689 mm³. Planar walls, so the mesh
    /// volume is exact.
    func testADraftExtrudeTapersToTheAnalyticFrustum() throws {
        let feature = FeatureID(), bodyID = BodyID()
        let sketchID = SketchID(), rect = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rect, min: SIMD2(-20, -20), max: SIMD2(20, 20))])
        let result = evaluate(
            [draftNode(feature, bodyID, sketch: sketchID, rect: rect,
                       distance: 20, taper: 10)], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertNotNil(body.brep, "a draft extrude is a real B-rep")

        let d = 20 * tan(10 * Double.pi / 180)
        let topSide = 40 - 2 * d
        let A1 = 40.0 * 40, A2 = topSide * topSide
        let want = 20.0 / 3 * (A1 + A2 + (A1 * A2).squareRoot())   // 26,689
        let vol = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(vol, want, accuracy: max(1, want * 0.005),
                       "drafted frustum volume \(vol) vs analytic \(want)")
    }

    /// A negative angle EXPANDS the section — the reverse taper. Volume is the
    /// larger frustum.
    func testANegativeAngleExpandsTheSection() throws {
        let feature = FeatureID(), bodyID = BodyID()
        let sketchID = SketchID(), rect = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rect, min: SIMD2(-20, -20), max: SIMD2(20, 20))])
        let result = evaluate(
            [draftNode(feature, bodyID, sketch: sketchID, rect: rect,
                       distance: 20, taper: -10)], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        let d = 20 * tan(10 * Double.pi / 180)
        let topSide = 40 + 2 * d
        let want = 20.0 / 3 * (1600 + topSide * topSide
                               + (1600 * topSide * topSide).squareRoot())
        let vol = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(vol, want, accuracy: max(1, want * 0.005), "\(vol) vs \(want)")
        XCTAssertGreaterThan(vol, 40 * 40 * 20, "expanded frustum exceeds the straight prism")
    }

    /// A taper steep enough to offset the profile into itself is refused —
    /// never a self-intersected section.
    func testAnOverSteepTaperErrorsTheNode() throws {
        let feature = FeatureID(), bodyID = BodyID()
        let sketchID = SketchID(), rect = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rect, min: SIMD2(-10, -10), max: SIMD2(10, 10))])
        // over 20 mm, 45° inward offsets by 20 — the half-width is 10, so the
        // section collapses well before the top.
        let result = evaluate(
            [draftNode(feature, bodyID, sketch: sketchID, rect: rect,
                       distance: 20, taper: 45)], [sketch])
        XCTAssertNotNil(result.errors[feature], "an over-steep taper must error")
        XCTAssertNil(result.bodies.first { $0.id == bodyID },
                     "no body ships from a collapsed section")
    }

    /// Slice 1 is hole-free: a profile that declares a hole is refused (a hole
    /// needs the opposite offset + its own lofted subtraction — deferred), not
    /// silently drafted as a solid.
    func testADraftOnAHoledProfileIsRefusedForNow() throws {
        let draft = FeatureID(), draftID = BodyID()
        let sketchID = SketchID(), outerRect = UUID(), holeRect = UUID()
        let sketch = Sketch(id: sketchID, name: "H", plane: .ground, entities: [
            .rect(id: outerRect, min: SIMD2(-20, -20), max: SIMD2(20, 20)),
            .rect(id: holeRect, min: SIMD2(-5, -5), max: SIMD2(5, 5))])
        let node = FeatureNode(
            id: draft, name: "Draft",
            kind: .draftExtrude(
                profile: ProfileRef(sketchID: sketchID, entityIDs: [outerRect],
                                    holeEntityIDs: [[holeRect]], seedPoint: SIMD2(12, 0)),
                plane: PlaneRef(source: .sketch(sketchID)),
                distance: Expr(value: 10), taperAngle: Expr(value: 5),
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [draftID])
        let result = evaluate([node], [sketch])
        XCTAssertNotNil(result.errors[draft],
                        "draft on a holed profile is deferred, not silently solid")
        XCTAssertNil(result.bodies.first { $0.id == draftID })
    }
}
