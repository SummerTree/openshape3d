//
//  SplineBlendStressTests.swift
//  openshape3dTests
//
//  Spline-as-profile slice 2 (docs/SPLINE_PROFILE_DESIGN.md): blends on a
//  B-spline wall. A fillet or chamfer on the spline extrude's rim must either
//  build a smaller, valid solid or refuse with a typed error — never crash,
//  never hang. Mirrors BlendStressTests' contract on the curved-rim cylinder.
//

import XCTest
import simd
@testable import openshape3d

final class SplineBlendStressTests: XCTestCase {

    private let ring: [SIMD2<Double>] = [
        SIMD2(0, 0), SIMD2(30, 4), SIMD2(38, 22), SIMD2(20, 41), SIMD2(-6, 30), SIMD2(-12, 9)]

    /// The closed-spline extrude's B-rep: 2 caps + 1 B-spline wall, whose
    /// edges are the wall's seam and the two rims.
    private func splineExtrude() throws -> BRepHandle {
        let feature = FeatureID(), bodyID = BodyID(), sketchID = SketchID(), spline = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .spline(id: spline, points: ring, closed: true)])
        let node = FeatureNode(id: feature, name: "E", kind: .extrude(
            profile: ProfileRef(sketchID: sketchID, entityIDs: [spline], holeEntityIDs: [],
                                seedPoint: SIMD2(12, 18)),
            plane: PlaneRef(source: .sketch(sketchID)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [bodyID])
        var rev: UInt64 = 0
        let result = FeatureGraph(nodes: [node]).evaluate(
            sketches: [sketch], planes: [], naming: SignatureNaming(),
            nextRevision: { rev += 1; return rev })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        return try XCTUnwrap(body.brep)
    }

    /// Every edge × every radius: builds a smaller valid solid, or refuses
    /// typed. Reaching the end is most of the assertion.
    func testEveryEdgeAndRadiusBuildsOrRefusesCleanly() throws {
        let brep = try splineExtrude()
        let before = OCCTKernel.volume(brep)
        XCTAssertGreaterThan(before, 0)
        var built = 0, refused = 0
        for edge in 1...3 {
            for radius in [0.5, 2.0, 8.0, 30.0] {
                switch OCCTKernel.filletResultWithAncestry(brep, edgeIndices: [edge], radius: radius) {
                case let .success((handle, _)):
                    built += 1
                    let after = OCCTKernel.volume(handle)
                    XCTAssertGreaterThan(after, 0, "edge \(edge) r \(radius): a real solid")
                    XCTAssertLessThan(after, before, "edge \(edge) r \(radius): a convex fillet removes material")
                    let counts = OCCTKernel.faceTypeCounts(handle)
                    XCTAssertGreaterThanOrEqual(counts.planar + counts.cylindrical + counts.other, 3)
                case .failure:
                    refused += 1
                }
            }
        }
        XCTAssertGreaterThan(built, 0, "the feasible rim fillets must build")
        XCTAssertGreaterThan(refused, 0, "the oversize ones must refuse, not crash")
    }

    /// A feasible rim fillet adds a blend face beside the spline wall; a
    /// chamfer on the same rim builds too.
    func testRimFilletAddsABlendFaceAndChamferBuilds() throws {
        let brep = try splineExtrude()
        let before = OCCTKernel.volume(brep)
        let baseline = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(baseline.planar, 2); XCTAssertEqual(baseline.other, 1)
        var rim: Int?
        for edge in 1...3 {
            if case .success = OCCTKernel.filletResultWithAncestry(brep, edgeIndices: [edge], radius: 2) {
                rim = edge; break
            }
        }
        let edge = try XCTUnwrap(rim, "one of the three edges is a filletable rim")

        guard case let .success((filleted, _)) = OCCTKernel.filletResultWithAncestry(
            brep, edgeIndices: [edge], radius: 2) else { return XCTFail("rim fillet must build") }
        let counts = OCCTKernel.faceTypeCounts(filleted)
        XCTAssertEqual(counts.planar, 2, "both caps survive")
        XCTAssertGreaterThanOrEqual(counts.other, 2, "the wall plus at least one blend face")
        XCTAssertLessThan(OCCTKernel.volume(filleted), before)

        guard case let .success((chamfered, _)) = OCCTKernel.chamferResultWithAncestry(
            brep, edgeIndices: [edge], distance: 1) else { return XCTFail("rim chamfer must build") }
        XCTAssertLessThan(OCCTKernel.volume(chamfered), before)
        XCTAssertGreaterThan(OCCTKernel.volume(chamfered), 0)
    }

    /// `/v1/exec` accepts any edge index ≥ 1 from a script; the bridge must
    /// refuse one past the edge count typed, never index off the end.
    func testOutOfRangeEdgeIndexRefusesTyped() throws {
        let brep = try splineExtrude()
        guard case .failure = OCCTKernel.filletResultWithAncestry(brep, edgeIndices: [99], radius: 1) else {
            return XCTFail("an out-of-range edge index must be a typed refusal")
        }
        guard case .failure = OCCTKernel.chamferResultWithAncestry(brep, edgeIndices: [99], distance: 1) else {
            return XCTFail("an out-of-range edge index must be a typed refusal")
        }
    }

    /// An oversize blend on the spline rim refuses with a typed failure —
    /// what the live app showed for r = 30 ("too large for the local geometry").
    func testOversizeRimBlendRefusesTyped() throws {
        let brep = try splineExtrude()
        var anyRefused = false
        for edge in 1...3 {
            if case .failure = OCCTKernel.filletResultWithAncestry(brep, edgeIndices: [edge], radius: 30) {
                anyRefused = true
            }
        }
        XCTAssertTrue(anyRefused)
    }
}
