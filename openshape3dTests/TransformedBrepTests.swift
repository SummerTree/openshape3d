//
//  TransformedBrepTests.swift
//  openshape3dTests
//
//  A body derived from another by PLACEMENT must keep its analytic solid.
//
//  Pattern and mirror both used to hand back mesh-only bodies. That is a
//  quieter loss than it sounds: pattern a filleted bracket ten times and every
//  copy silently leaves the OCCT path, so a later fillet on a copy runs on the
//  mesh approximation, a boolean against one goes faceted, and STEP export
//  skips all ten. The source keeps its brep, so the model looks analytic right
//  up until you touch a copy.
//
//  Two different fixes, because they are two different transforms:
//
//  - A PATTERN copy is the same body-local solid at a different placement, and
//    `brep` is body-local exactly like `render` (the placement lives in
//    `Body.transform`). So the copy shares the source's handle — no OCCT call.
//  - A MIRROR is a reflection, which `Transform3D` cannot represent at all: it
//    is translation + a rotation quaternion + one uniform scale, and a negative
//    uniform scale is a POINT reflection, not a plane one. That needs
//    `gp_Trsf::SetMirror`, via `OCCTKernel.mirrored`.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class TransformedBrepTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private let cylFeature = FeatureID()
    private let derivedFeature = FeatureID()
    private let cylID = BodyID()
    private let radius = 3.0
    private let height = 8.0

    /// A CYLINDER, not a box: its analytic-ness is measurable. A box has the
    /// same face counts whether or not it came from OCCT, so it could not tell
    /// a shared brep from a dropped one.
    private func cylinderNode() -> FeatureNode {
        FeatureNode(
            id: cylFeature, name: "Cylinder",
            kind: .primitive(spec: .cylinder(radius: radius, height: height),
                             placement: .identity),
            outputBodyIDs: [cylID])
    }

    private func evaluate(_ graph: FeatureGraph) -> EvalResult {
        graph.evaluate(sketches: [], planes: [],
                       naming: SignatureNaming(), nextRevision: RevisionSource().next)
    }

    private var bodyRef: BodyRef { BodyRef(producer: cylFeature, bodyID: cylID) }

    // MARK: - The fixture

    /// The source must be analytic, or nothing below means anything.
    func testTheSourceCylinderIsAnalytic() throws {
        let body = try XCTUnwrap(evaluate(FeatureGraph(nodes: [cylinderNode()])).bodies.first)
        let brep = try XCTUnwrap(body.brep, "a cylinder primitive carries a brep")
        XCTAssertEqual(OCCTKernel.faceTypeCounts(brep).cylindrical, 1)
    }

    // MARK: - Pattern

    private func patternGraph(count: Int) -> FeatureGraph {
        FeatureGraph(nodes: [
            cylinderNode(),
            FeatureNode(
                id: derivedFeature, name: "Pattern",
                kind: .pattern(body: bodyRef,
                               spec: PatternSpec(kind: .linear,
                                                 axis: SIMD3(1, 0, 0),
                                                 count: count,
                                                 spacing: 20)),
                outputBodyIDs: (1..<count).map { _ in BodyID() }),
        ])
    }

    /// Every copy carries a brep — and it is the SAME analytic cylinder.
    func testPatternCopiesKeepTheAnalyticSolid() throws {
        let bodies = evaluate(patternGraph(count: 4)).bodies
        XCTAssertEqual(bodies.count, 4, "source plus three copies")
        for body in bodies {
            let brep = try XCTUnwrap(body.brep, "\(body.name) lost its brep")
            XCTAssertEqual(OCCTKernel.faceTypeCounts(brep).cylindrical, 1,
                           "\(body.name) must still be one analytic cylinder")
        }
    }

    /// The copies must be PLACED, not stacked on the source. The brep is
    /// shared, so the separation lives entirely in `transform` — which is the
    /// thing that would be wrong if someone "fixed" this by baking the pattern
    /// transform into the shared solid instead.
    func testPatternCopiesAreSeparatedByTheirTransformNotTheirSolid() throws {
        let bodies = evaluate(patternGraph(count: 3)).bodies
        let xs = bodies.map(\.transform.translation.x).sorted()
        XCTAssertEqual(xs.count, 3)
        XCTAssertEqual(xs[1] - xs[0], 20, accuracy: 1e-6)
        XCTAssertEqual(xs[2] - xs[1], 20, accuracy: 1e-6)
        // Shared solid: every brep sits at the same local origin.
        for body in bodies {
            let brep = try XCTUnwrap(body.brep)
            let placed = try XCTUnwrap(STEPKit.body(from: brep, name: "b", revision: 1))
            let aabb = placed.render.localAABB
            XCTAssertEqual(Double((aabb.min.x + aabb.max.x) / 2), 0, accuracy: 1e-3,
                           "the shared solid must stay body-local")
        }
    }

    // MARK: - Mirror

    /// `SketchPlane` is origin + two in-plane axes; its normal is their cross
    /// product, so a mirror plane is specified by the axes that span it.
    private func mirrorGraph(xAxis: SIMD3<Double>, yAxis: SIMD3<Double>,
                             origin: SIMD3<Double> = .zero) -> FeatureGraph {
        let plane = SketchPlane(origin: origin, xAxis: xAxis, yAxis: yAxis)
        return FeatureGraph(nodes: [
            cylinderNode(),
            FeatureNode(
                id: derivedFeature, name: "Mirror",
                kind: .mirror(body: bodyRef,
                              plane: PlaneRef(source: .explicit(plane)),
                              keepOriginal: true),
                outputBodyIDs: [BodyID()]),
        ])
    }

    /// A mirrored body keeps an analytic solid — the case `Transform3D` cannot
    /// express, so it exercises `gp_Trsf::SetMirror` rather than the ordinary
    /// transform path.
    func testMirroredBodyKeepsTheAnalyticSolid() throws {
        let bodies = evaluate(mirrorGraph(xAxis: SIMD3(0, 1, 0), yAxis: SIMD3(0, 0, 1),
                                          origin: SIMD3(10, 0, 0))).bodies
        let mirroredBody = try XCTUnwrap(bodies.first { $0.name == "Mirror" })
        let brep = try XCTUnwrap(mirroredBody.brep, "the mirror lost its brep")
        XCTAssertEqual(OCCTKernel.faceTypeCounts(brep).cylindrical, 1,
                       "the reflection of a cylinder is still a cylinder")
    }

    /// …and it is reflected to the RIGHT PLACE. A mirror that silently fell
    /// back to copying the source's solid would pass the face-count test above
    /// and fail this one: reflecting across x = 10 must put the copy on the
    /// far side, centred at x = 20.
    func testTheMirroredSolidIsActuallyReflected() throws {
        let bodies = evaluate(mirrorGraph(xAxis: SIMD3(0, 1, 0), yAxis: SIMD3(0, 0, 1),
                                          origin: SIMD3(10, 0, 0))).bodies
        let mirroredBody = try XCTUnwrap(bodies.first { $0.name == "Mirror" })
        let brep = try XCTUnwrap(mirroredBody.brep)
        let placed = try XCTUnwrap(STEPKit.body(from: brep, name: "m", revision: 1))
        let aabb = placed.render.localAABB
        let centreX = Double((aabb.min.x + aabb.max.x) / 2)
        XCTAssertEqual(centreX, 20, accuracy: 1e-2,
                       "a cylinder at x=0 mirrored across x=10 sits at x=20")
    }

    /// The reflected solid must agree with the reflected MESH. They are
    /// computed by different kernels — Euclid mirrors the mesh, OCCT mirrors
    /// the solid — so a sign or plane-convention slip in either shows up as
    /// the two disagreeing rather than as either one looking wrong alone.
    func testTheMirroredSolidAgreesWithTheMirroredMesh() throws {
        let bodies = evaluate(mirrorGraph(xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
                                          origin: SIMD3(0, 0, 5))).bodies
        let mirroredBody = try XCTUnwrap(bodies.first { $0.name == "Mirror" })
        let brep = try XCTUnwrap(mirroredBody.brep)
        let fromBrep = try XCTUnwrap(STEPKit.body(from: brep, name: "m", revision: 1))

        let meshBox = mirroredBody.render.localAABB
        let brepBox = fromBrep.render.localAABB
        for axis in 0..<3 {
            XCTAssertEqual(Double(brepBox.min[axis]), Double(meshBox.min[axis]), accuracy: 0.05,
                           "axis \(axis) min: solid and mesh disagree")
            XCTAssertEqual(Double(brepBox.max[axis]), Double(meshBox.max[axis]), accuracy: 0.05,
                           "axis \(axis) max: solid and mesh disagree")
        }
    }

    /// Mirroring twice across the same plane returns the original placement —
    /// the cheapest check that the reflection is a true involution and not,
    /// say, a rotation that happens to land right for one test case.
    func testMirroringIsAnInvolution() throws {
        let cyl = try XCTUnwrap(evaluate(FeatureGraph(nodes: [cylinderNode()])).bodies.first)
        let brep = try XCTUnwrap(cyl.brep)
        let plane = (origin: SIMD3<Double>(7, 0, 0), normal: SIMD3<Double>(1, 0, 0))

        let once = try XCTUnwrap(OCCTKernel.mirrored(brep, origin: plane.origin,
                                                     normal: plane.normal))
        let twice = try XCTUnwrap(OCCTKernel.mirrored(once, origin: plane.origin,
                                                      normal: plane.normal))
        let back = try XCTUnwrap(STEPKit.body(from: twice, name: "b", revision: 1))
        let aabb = back.render.localAABB
        XCTAssertEqual(Double((aabb.min.x + aabb.max.x) / 2), 0, accuracy: 1e-2)
    }
}
