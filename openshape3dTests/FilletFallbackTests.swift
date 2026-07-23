//
//  FilletFallbackTests.swift
//  openshape3dTests
//
//  Regression for "some facets are distorted after filleting". A body OCCT
//  owns (a `brep` is present) must be filleted BY OCCT or not at all: the
//  Euclid mesh-blend fallback produces malformed polygons on the curved
//  analytic solids that now flow through OCCT (it trips a Euclid polygon
//  assertion in debug and ships spiky facets in release). So a too-large
//  radius errors cleanly instead of degrading to that path.
//

import XCTest
import simd
@testable import openshape3d

final class FilletFallbackTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private let extrudeFeature = FeatureID()
    private let filletFeature = FeatureID()
    private let bodyID = BodyID()

    /// A D-shape (semicircle) extruded — a curved analytic wall plus a flat
    /// back, exactly the shape whose fillet showed the distortion.
    private func dshapeSketch() -> Sketch {
        var pts = [SIMD2<Double>]()
        let r = 20.0, seg = 10
        for k in 0...seg {
            let t = Double.pi * Double(k) / Double(seg)
            pts.append(SIMD2(r * cos(t), r * sin(t)))
        }
        let ids = pts.indices.map { _ in UUID() }
        var entities = [SketchEntity]()
        for i in 0..<pts.count {
            entities.append(.line(id: ids[i], a: pts[i], b: pts[(i + 1) % pts.count]))
        }
        return Sketch(id: SketchID(), plane: .ground, entities: entities)
    }

    private func graph(radius: Double, sketch: Sketch) -> FeatureGraph {
        let profile = ProfileRef(
            sketchID: sketch.id, entityIDs: sketch.entities.map(\.id),
            holeEntityIDs: [], seedPoint: SIMD2(0, 1))
        return FeatureGraph(nodes: [
            FeatureNode(
                id: extrudeFeature, name: "Extrude",
                kind: .extrude(profile: profile, plane: PlaneRef(source: .ground),
                               distance: Expr(value: 15), symmetric: false,
                               boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []),
                outputBodyIDs: [bodyID]),
        ])
    }

    private func topRimEdgeRefs(of body: Body) -> [EdgeRef] {
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let ref = BodyRef(producer: extrudeFeature, bodyID: bodyID)
        var refs = [EdgeRef]()
        for e in edges where e.isConvex {
            let mid = (e.start + e.end) * 0.5
            guard abs(mid.y - 15) < 0.5 else { continue }
            refs.append(EdgeRef(body: ref, signature: EdgeSignature(
                midpoint: SIMD3(Double(mid.x), Double(mid.y), Double(mid.z)),
                direction: simd_normalize(SIMD3(
                    Double(e.end.x - e.start.x), Double(e.end.y - e.start.y),
                    Double(e.end.z - e.start.z))),
                length: Double(simd_length(e.end - e.start)),
                normalA: SIMD3(Double(e.normalA.x), Double(e.normalA.y), Double(e.normalA.z)),
                normalB: SIMD3(Double(e.normalB.x), Double(e.normalB.y), Double(e.normalB.z)))))
        }
        return refs
    }

    private func evaluate(_ g: FeatureGraph, _ sketch: Sketch) -> EvalResult {
        g.evaluate(sketches: [sketch], planes: [], naming: SignatureNaming(),
                   nextRevision: RevisionSource().next)
    }

    /// A radius OCCT can build stays analytic and produces NO distorted facets.
    func testAModestFilletStaysAnalyticAndClean() throws {
        try XCTSkipUnless(OCCTKernel.useOCCTAsSourceOfTruth, "OCCT path only")
        let sketch = dshapeSketch()
        var g = graph(radius: 3, sketch: sketch)
        let extruded = try XCTUnwrap(evaluate(g, sketch).bodies.first)

        g.nodes.append(FeatureNode(
            id: filletFeature, name: "Fillet",
            kind: .fillet(body: BodyRef(producer: extrudeFeature, bodyID: bodyID),
                          edges: topRimEdgeRefs(of: extruded), radius: Expr(value: 3)),
            outputBodyIDs: []))
        let result = evaluate(g, sketch)

        XCTAssertNil(result.errors[filletFeature], "a modest fillet builds")
        let body = try XCTUnwrap(result.bodies.first)
        XCTAssertNotNil(body.brep, "the filleted body stays analytic (no mesh fallback)")

        // No inverted / degenerate-normal facets on the render mesh.
        let m = body.render
        var inverted = 0, total = 0
        for t in 0..<m.triangleCount {
            let ia = Int(m.indices[t*3]), ib = Int(m.indices[t*3+1]), ic = Int(m.indices[t*3+2])
            let a = m.positions[ia], b = m.positions[ib], c = m.positions[ic]
            let gn = simd_cross(b - a, c - a)
            guard simd_length(gn) > 1e-9 else { continue }
            let s = m.normals[ia] + m.normals[ib] + m.normals[ic]
            guard simd_length(s) > 1e-9 else { continue }
            total += 1
            if simd_dot(simd_normalize(gn), simd_normalize(s)) < -0.5 { inverted += 1 }
        }
        XCTAssertEqual(inverted, 0, "no inverted-normal facets (the distortion)")
        XCTAssertGreaterThan(total, 100)
    }

    /// A radius too large for OCCT ERRORS instead of shipping the mesh-blend
    /// garbage that caused the distortion.
    func testATooLargeFilletErrorsRatherThanDistorts() throws {
        try XCTSkipUnless(OCCTKernel.useOCCTAsSourceOfTruth, "OCCT path only")
        let sketch = dshapeSketch()
        var g = graph(radius: 8, sketch: sketch)
        let extruded = try XCTUnwrap(evaluate(g, sketch).bodies.first)

        g.nodes.append(FeatureNode(
            id: filletFeature, name: "Fillet",
            kind: .fillet(body: BodyRef(producer: extrudeFeature, bodyID: bodyID),
                          edges: topRimEdgeRefs(of: extruded), radius: Expr(value: 8)),
            outputBodyIDs: []))
        let result = evaluate(g, sketch)

        let error = try XCTUnwrap(result.errors[filletFeature],
                                  "a radius OCCT can't build must error, not distort")
        if case let .kernelFailure(message) = error {
            XCTAssertTrue(message.contains("too large"), "actionable message: \(message)")
        } else {
            XCTFail("expected a kernelFailure, got \(error)")
        }
    }
}
