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
                           distance: Double, taper: Double,
                           symmetric: Bool = false) -> FeatureNode {
        FeatureNode(
            id: feature, name: "Draft",
            kind: .draftExtrude(
                profile: ProfileRef(sketchID: sketch, entityIDs: [rect],
                                    holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(sketch)),
                distance: Expr(value: distance),
                taperAngle: Expr(value: taper),
                symmetric: symmetric,
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

    /// Symmetric draft tapers BOTH ways from the sketch plane: the base is the
    /// widest section in the middle and both ends contract, so the solid is two
    /// frustums back to back (each of height `distance`).
    func testSymmetricDraftIsTwoFrustumsBackToBack() throws {
        let feature = FeatureID(), bodyID = BodyID()
        let sketchID = SketchID(), rect = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rect, min: SIMD2(-20, -20), max: SIMD2(20, 20))])
        let result = evaluate(
            [draftNode(feature, bodyID, sketch: sketchID, rect: rect,
                       distance: 10, taper: 10, symmetric: true)], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertNotNil(body.brep)
        let off = 10 * tan(10 * Double.pi / 180)           // each half height 10
        let endSide = 40 - 2 * off
        let A1 = 40.0 * 40, A2 = endSide * endSide
        let half = 10.0 / 3 * (A1 + A2 + (A1 * A2).squareRoot())
        let want = 2 * half                                 // two frustums
        let vol = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(vol, want, accuracy: max(1, want * 0.005),
                       "symmetric draft \(vol) vs two frustums \(want)")
    }

    /// Slice 3: a CIRCLE drafts to an exact cone frustum — ONE conical wall,
    /// not a 48-facet approximation. A circle's offset is a concentric circle
    /// (radius ± offset), so the loft stays conic→conic and the wall is a
    /// single curved face: two planar caps + one non-planar wall, never ~50
    /// planar facets. Volume matches the analytic cone frustum.
    func testADraftedCircleIsAnExactConeFrustum() throws {
        let feature = FeatureID(), bodyID = BodyID()
        let sketchID = SketchID(), circle = UUID()
        let sketch = Sketch(id: sketchID, name: "C", plane: .ground, entities: [
            .circle(id: circle, center: .zero, radius: 20)])
        let result = evaluate(
            [draftNode(feature, bodyID, sketch: sketchID, rect: circle,
                       distance: 20, taper: 10)], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        let brep = try XCTUnwrap(body.brep, "a drafted circle is a real B-rep")

        // The wall is ONE curved face, not tessellated planar facets.
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar, 2, "just the two circular caps are planar")
        XCTAssertEqual(counts.other, 1, "a single non-planar (cone) wall")
        XCTAssertEqual(counts.cylindrical, 0, "a draft is a cone, not a cylinder")

        // Faceted 48-gon render mesh → a ~0.3% inscribed deficit is expected.
        let off = 20 * tan(10 * Double.pi / 180)
        let r0 = 20.0, r1 = 20.0 - off
        let want = Double.pi * 20 / 3 * (r0 * r0 + r1 * r1 + r0 * r1)
        let vol = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(vol, want, accuracy: want * 0.01,
                       "cone frustum \(want) vs \(vol)")
    }

    /// Slice 3 remainder: a SLOT (two lines, two semicircles) drafts exactly —
    /// the arc walls are true cones, not facet ribbons, and the volume is the
    /// closed form for a linearly offset rounded profile. For a fully rounded
    /// convex section an inward offset obeys Steiner, A(δ) = A₀ + P₀δ + πδ²,
    /// so with δ(z) = −tanθ·z the drafted volume is
    /// A₀h − P₀·tanθ·h²/2 + π·tan²θ·h³/3. Read from the B-rep, so this is a
    /// tight check, not a tessellation-tolerant one.
    func testADraftedSlotIsExactWithConicalEnds() throws {
        let feature = FeatureID(), bodyID = BodyID(), sketchID = SketchID()
        let top = UUID(), right = UUID(), bottom = UUID(), left = UUID()
        let r = 10.0, half = 15.0
        let sketch = Sketch(id: sketchID, name: "Slot", plane: .ground, entities: [
            .line(id: top, a: SIMD2(-half, r), b: SIMD2(half, r)),
            .arc(id: right, center: SIMD2(half, 0), radius: r,
                 startAngle: -Double.pi / 2, endAngle: Double.pi / 2),      // CCW through (25, 0)
            .line(id: bottom, a: SIMD2(half, -r), b: SIMD2(-half, -r)),
            .arc(id: left, center: SIMD2(-half, 0), radius: r,
                 startAngle: Double.pi / 2, endAngle: 3 * Double.pi / 2)])   // CCW through (−25, 0)
        let node = FeatureNode(
            id: feature, name: "Draft",
            kind: .draftExtrude(
                profile: ProfileRef(sketchID: sketchID, entityIDs: [top, right, bottom, left],
                                    holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(sketchID)),
                distance: Expr(value: 20), taperAngle: Expr(value: 10),
                symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [bodyID])
        let result = evaluate([node], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        let brep = try XCTUnwrap(body.brep)

        // A handful of exact faces: 2 caps + 2 flat walls + 2 conical ends,
        // never the ~50 of a tessellated arc.
        let counts = OCCTKernel.faceTypeCounts(brep)
        let total = counts.planar + counts.cylindrical + counts.other
        XCTAssertLessThan(total, 10, "exact faces only: \(counts)")
        XCTAssertGreaterThanOrEqual(counts.other, 2, "the two drafted arc walls are conical")

        let h = 20.0, t = tan(10 * Double.pi / 180)
        let a0 = 2 * r * (2 * half) + Double.pi * r * r          // 914.16
        let p0 = 2 * (2 * half) + 2 * Double.pi * r               // 122.83
        let want = a0 * h - p0 * t * h * h / 2 + Double.pi * t * t * h * h * h / 3
        let vol = MeasureKit.volume(of: body)
        XCTAssertEqual(vol, want, accuracy: want * 1e-4,
                       "drafted slot \(vol) vs Steiner closed form \(want)")
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

    /// Slice 3, the other single-edge-wire case FreeCAD flags: a CIRCULAR bore
    /// drafts the opposite way and stays an exact cone — the subtracted bore is
    /// ONE conical wall, not 48 facets. Result = square frustum − cone bore.
    func testADraftedCircularBoreStaysConic() throws {
        let draft = FeatureID(), draftID = BodyID()
        let sketchID = SketchID(), outerRect = UUID(), bore = UUID()
        let sketch = Sketch(id: sketchID, name: "HB", plane: .ground, entities: [
            .rect(id: outerRect, min: SIMD2(-20, -20), max: SIMD2(20, 20)),
            .circle(id: bore, center: .zero, radius: 8)])
        let node = FeatureNode(
            id: draft, name: "Draft",
            kind: .draftExtrude(
                profile: ProfileRef(sketchID: sketchID, entityIDs: [outerRect],
                                    holeEntityIDs: [[bore]], seedPoint: SIMD2(14, 0)),
                plane: PlaneRef(source: .sketch(sketchID)),
                distance: Expr(value: 20), taperAngle: Expr(value: 10),
                symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [draftID])
        let result = evaluate([node], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == draftID })
        let brep = try XCTUnwrap(body.brep, "a drafted holed pad is a real B-rep")

        // The whole solid is a HANDFUL of exact faces — 2 caps, 4 ruled outer
        // walls, 1 conical bore. A faceted bore would instead blow the count
        // past 50, so the total is the robust "stayed exact" discriminator
        // (drafted walls are ruled BSplines, so they bucket as `other` too and
        // an `other == 1` check would be representation-fragile).
        let counts = OCCTKernel.faceTypeCounts(brep)
        let total = counts.planar + counts.cylindrical + counts.other
        XCTAssertLessThan(total, 12, "exact faces only, not a tessellated bore: \(counts)")
        XCTAssertGreaterThanOrEqual(counts.other, 1, "at least the conical bore wall is curved")
        XCTAssertEqual(counts.cylindrical, 0, "a drafted bore is a cone, not a cylinder")

        func squareFrustum(_ s0: Double, _ s1: Double, _ h: Double) -> Double {
            let a = s0 * s0, b = s1 * s1
            return h / 3 * (a + b + (a * b).squareRoot())
        }
        let off = 20 * tan(10 * Double.pi / 180)
        let outer = squareFrustum(40, 40 - 2 * off, 20)
        let r0 = 8.0, r1 = 8.0 + off                        // bore widens
        let coneBore = Double.pi * 20 / 3 * (r0 * r0 + r1 * r1 + r0 * r1)
        let want = outer - coneBore
        let vol = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(vol, want, accuracy: want * 0.01,
                       "square frustum \(outer) − cone bore \(coneBore) = \(want), got \(vol)")
    }

    /// Slice 2: a hole drafts the OPPOSITE way (the bore widens toward the far
    /// end, for core release) and is subtracted — so the result is the outer
    /// frustum minus the outward-drafted bore frustum.
    func testADraftOnAHoledProfileCutsADraftedBore() throws {
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
                distance: Expr(value: 20), taperAngle: Expr(value: 10),
                symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [draftID])
        let result = evaluate([node], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == draftID })
        XCTAssertNotNil(body.brep, "a drafted holed pad is a real B-rep")

        func frustum(_ side0: Double, _ side1: Double, _ h: Double) -> Double {
            let a = side0 * side0, b = side1 * side1
            return h / 3 * (a + b + (a * b).squareRoot())
        }
        let off = 20 * tan(10 * Double.pi / 180)
        let outer = frustum(40, 40 - 2 * off, 20)          // contracts
        let bore = frustum(10, 10 + 2 * off, 20)           // opposite → widens
        let want = outer - bore
        let vol = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(vol, want, accuracy: max(1, want * 0.01),
                       "outer frustum \(outer) − bore frustum \(bore) = \(want), got \(vol)")

        // Composed hole-wall naming: the bore's four walls carry the HOLE
        // entity's identity and the outer's four carry the outer's — composed
        // through the subtraction, not relabelled by geometry afterwards.
        let names = try XCTUnwrap(result.kernelNames[draftID], "a drafted holed pad is named")
        func walls(of entity: UUID) -> Int {
            names.values.filter {
                if case let .profileWall(e, _) = $0.source { return e == entity }
                return false
            }.count
        }
        XCTAssertEqual(walls(of: holeRect), 4, "the drafted bore's walls are named by the hole entity")
        XCTAssertEqual(walls(of: outerRect), 4, "the outer walls keep the outer entity")
        XCTAssertTrue(names.values.allSatisfy { $0.creator == draft })
    }
}
