//
//  BRepVolumeReadbackTests.swift
//  openshape3dTests
//
//  The volume the app REPORTS must be the B-rep's exact volume, not the
//  render mesh's. Every curved catalogue part in the real-part validation
//  read ~0.3% low because the mesh is an inscribed tessellation; the
//  geometry was exact, the ruler was faceted. These pin the fix.
//

import XCTest
import simd
@testable import openshape3d

final class BRepVolumeReadbackTests: XCTestCase {

    private func evaluate(_ nodes: [FeatureNode], _ sketches: [Sketch]) -> EvalResult {
        var rev: UInt64 = 0
        return FeatureGraph(nodes: nodes).evaluate(
            sketches: sketches, planes: [], naming: SignatureNaming(),
            nextRevision: { rev += 1; return rev })
    }

    /// A drafted profile: the same node the draft tests use, because it
    /// gives a curved body (a circle → cone frustum) with a closed-form
    /// volume and no new signatures.
    private func draftBody(entity: SketchEntity, entityID: UUID,
                           distance: Double, taper: Double) throws -> Body {
        let feature = FeatureID(), bodyID = BodyID(), sketchID = SketchID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [entity])
        let node = FeatureNode(
            id: feature, name: "Draft",
            kind: .draftExtrude(
                profile: ProfileRef(sketchID: sketchID, entityIDs: [entityID],
                                    holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(sketchID)),
                distance: Expr(value: distance), taperAngle: Expr(value: taper),
                symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [bodyID])
        let result = evaluate([node], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        return try XCTUnwrap(result.bodies.first { $0.id == bodyID })
    }

    /// Curved body: the reported volume is the analytic cone frustum to
    /// better than 1e-6, while the mesh reads measurably low — the exact
    /// deficit the catalogue parts showed.
    func testCurvedBodyReportsTheExactBRepVolumeNotTheMesh() throws {
        let circle = UUID()
        let body = try draftBody(entity: .circle(id: circle, center: .zero, radius: 20),
                                 entityID: circle, distance: 20, taper: 10)
        XCTAssertNotNil(body.brep)
        let off = 20 * tan(10 * Double.pi / 180)
        let r0 = 20.0, r1 = 20.0 - off
        let want = Double.pi * 20 / 3 * (r0 * r0 + r1 * r1 + r0 * r1)

        let reported = MeasureKit.volume(of: body)
        let mesh = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(reported, want, accuracy: want * 1e-6,
                       "reported volume is the exact frustum: \(reported) vs \(want)")
        XCTAssertLessThan(mesh, want, "the faceted mesh reads LOW on a curved body")
        XCTAssertGreaterThan((want - mesh) / want, 1e-4,
                             "…by a measurable margin (\((want - mesh) / want * 100)%)")
        XCTAssertLessThan((want - mesh) / want, 0.01, "…but under 1% (it is only faceting)")
    }

    /// Planar body: mesh and B-rep are both exact, so the two agree — the
    /// helper changes nothing where nothing was wrong.
    func testPlanarBodyAgreesBetweenBRepAndMesh() throws {
        let rect = UUID()
        let body = try draftBody(
            entity: .rect(id: rect, min: SIMD2(-20, -20), max: SIMD2(20, 20)),
            entityID: rect, distance: 20, taper: 10)
        let d = 20 * tan(10 * Double.pi / 180)
        let top = 40 - 2 * d
        let a1 = 40.0 * 40, a2 = top * top
        let want = 20.0 / 3 * (a1 + a2 + (a1 * a2).squareRoot())   // 26,689

        let reported = MeasureKit.volume(of: body)
        let mesh = MeasureKit.bodyVolume(body.render, scale: 1)
        XCTAssertEqual(reported, want, accuracy: want * 1e-6)
        XCTAssertEqual(mesh, want, accuracy: want * 1e-6, "planar mesh is already exact")
    }

    /// The scale is applied cubically to the exact volume, exactly as it was
    /// to the mesh volume.
    func testScaleAppliesCubically() throws {
        let circle = UUID()
        var body = try draftBody(entity: .circle(id: circle, center: .zero, radius: 20),
                                 entityID: circle, distance: 20, taper: 10)
        let unit = MeasureKit.volume(of: body)
        body.transform.scale = 2
        XCTAssertEqual(MeasureKit.volume(of: body), unit * 8, accuracy: unit * 8 * 1e-9)
    }
}
