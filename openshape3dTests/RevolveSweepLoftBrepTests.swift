//
//  RevolveSweepLoftBrepTests.swift
//  openshape3dTests
//
//  Revolve, sweep and loft used to produce MESH-ONLY bodies. That was the
//  largest remaining hole in "OCCT is the source of truth", and it was
//  expensive in a way that did not announce itself: a revolved body could not
//  be exported to STEP at all, every fillet on one ran on the mesh
//  approximation (~170× slower than the analytic path, and the site of the
//  over-radius crash), and a boolean against one went faceted.
//
//  These build on the exact profile wires the extrude path uses — the same
//  `OS3DProfileFace` in the bridge — so a circle revolved is a torus rather
//  than 48 flat strips. That shared face is the point: a circle that stayed
//  round when extruded and went faceted when revolved would be exactly the
//  quiet inconsistency this work exists to remove.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class RevolveSweepLoftBrepTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private func evaluate(_ graph: FeatureGraph, sketches: [Sketch]) -> EvalResult {
        graph.evaluate(sketches: sketches, planes: [],
                       naming: SignatureNaming(), nextRevision: RevisionSource().next)
    }

    private func volume(_ body: Body) -> Double {
        MeasureKit.bodyVolume(body.render, scale: 1)
    }

    // MARK: - Revolve

    /// A circle revolved about an axis that misses it is a TORUS. Its wall is
    /// one analytic toroidal surface, which `faceTypeCounts` reports under
    /// `other` — the telling number is that there is ONE of them rather than
    /// dozens of planar strips.
    ///
    /// Deliberately exercised through `OCCTKernel` rather than the feature
    /// graph. The graph route additionally runs the naming pass, and that pass
    /// takes ~65 SECONDS on this shape (see the note on `evalRevolve`); routing
    /// this assertion through it would buy nothing and cost a minute of suite
    /// time. `testAPartialRevolveKeepsItsAngle` covers the graph wiring.
    func testRevolvingACircleGivesAnAnalyticTorus() throws {
        let sketchID = SketchID(), circleID = UUID()
        let ringRadius = 10.0, tubeRadius = 2.0
        let sketch = Sketch(id: sketchID, plane: .ground, entities: [
            .circle(id: circleID, center: SIMD2(ringRadius, 0), radius: tubeRadius),
        ])
        let plane = SketchPlane.ground
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)

        let brep = try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: profile, holes: [], plane: plane,
            axisOrigin: .zero, axisDirection: SIMD3(0, 0, -1),
            angleRadians: 2 * Double.pi), "a revolved circle must build")
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar, 0, "a full torus has no flat faces at all")
        XCTAssertEqual(counts.other, 1, "one toroidal wall, not a strip per facet")

        // Pappus: V = 2π·R·πr². The mesh path's 48-gon approximation lands
        // ~1% low, so this tolerance also separates exact from faceted.
        let exact = 2 * Double.pi * ringRadius * Double.pi * tubeRadius * tubeRadius
        let solidBody = try XCTUnwrap(STEPKit.body(from: brep, name: "t", revision: 1))
        XCTAssertEqual(volume(solidBody), exact, accuracy: exact * 0.004)
    }

    /// A rectangle revolved a quarter turn: the swept walls are cylindrical,
    /// and the two end caps are planar. Checks a PARTIAL angle reaches OCCT.
    func testAPartialRevolveKeepsItsAngle() throws {
        let sketchID = SketchID(), rectID = UUID()
        let sketch = Sketch(id: sketchID, plane: .ground, entities: [
            .rect(id: rectID, min: SIMD2(4, 0), max: SIMD2(6, 3)),
        ])
        let feature = FeatureID(), bodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: feature, name: "Revolve",
                kind: .revolve(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectID], holeEntityIDs: [], seedPoint: nil),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    axis: AxisRef(source: .explicit(
                        RevolveAxis(point: .zero, direction: SIMD2(0, 1)))),
                    angle: Expr(value: 90),
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])

        let body = try XCTUnwrap(evaluate(graph, sketches: [sketch]).bodies.first)
        let brep = try XCTUnwrap(body.brep)
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.cylindrical, 2, "inner and outer swept walls")
        XCTAssertGreaterThanOrEqual(counts.planar, 4, "two caps plus top and bottom")

        // A quarter of the full revolution: ¼·2π·R̄·A, R̄ = 5, A = 2×3.
        let exact = 0.25 * 2 * Double.pi * 5 * 6
        let solidBody = try XCTUnwrap(STEPKit.body(from: brep, name: "r", revision: 1))
        XCTAssertEqual(volume(solidBody), exact, accuracy: exact * 0.004)
    }

    /// The analytic result must AGREE with the mesh one the same node also
    /// produces. They come from different kernels, so a basis or axis slip in
    /// either shows up as the two disagreeing rather than as either looking
    /// plausible alone.
    func testTheAnalyticRevolveAgreesWithTheMeshRevolve() throws {
        let sketchID = SketchID(), rectID = UUID()
        let sketch = Sketch(id: sketchID, plane: .ground, entities: [
            .rect(id: rectID, min: SIMD2(3, 0), max: SIMD2(5, 4)),
        ])
        let plane = SketchPlane.ground
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        let axis = RevolveAxis(point: .zero, direction: SIMD2(0, 1))

        let mesh = KernelOps.revolve(profile: profile, holes: [], in: plane,
                                     axis: axis, angle: 360)
        let meshVolume = MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)

        let origin = plane.origin + plane.xAxis * axis.point.x + plane.yAxis * axis.point.y
        let direction = plane.xAxis * axis.direction.x + plane.yAxis * axis.direction.y
        let brep = try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: profile, holes: [], plane: plane,
            axisOrigin: origin, axisDirection: direction, angleRadians: 2 * Double.pi))
        let analytic = try XCTUnwrap(STEPKit.body(from: brep, name: "r", revision: 1))

        // The mesh is a 48-gon approximation, so it sits slightly UNDER the
        // exact figure — agreeing to ~1% is agreement, and the analytic one
        // must be the larger of the two.
        XCTAssertEqual(volume(analytic), meshVolume, accuracy: meshVolume * 0.02)
        XCTAssertGreaterThan(volume(analytic), meshVolume,
                             "the tessellated revolve is inscribed, so it loses volume")
    }

    // MARK: - Loft

    /// Two circles lofted give a cone frustum: one analytic wall, two caps.
    func testLoftingTwoCirclesGivesAnAnalyticFrustum() throws {
        let lower = SketchID(), upper = SketchID()
        let lowerID = UUID(), upperID = UUID()
        let r0 = 5.0, r1 = 2.0, height = 8.0
        let lowerSketch = Sketch(id: lower, plane: .ground, entities: [
            .circle(id: lowerID, center: .zero, radius: r0),
        ])
        var topPlane = SketchPlane.ground
        topPlane.origin = SIMD3(0, height, 0)
        let upperSketch = Sketch(id: upper, plane: topPlane, entities: [
            .circle(id: upperID, center: .zero, radius: r1),
        ])

        let feature = FeatureID(), bodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: feature, name: "Loft",
                kind: .loft(
                    sections: [ProfileRef(sketchID: lower, entityIDs: [lowerID], holeEntityIDs: [], seedPoint: nil),
                               ProfileRef(sketchID: upper, entityIDs: [upperID], holeEntityIDs: [], seedPoint: nil)],
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])

        let body = try XCTUnwrap(
            evaluate(graph, sketches: [lowerSketch, upperSketch]).bodies.first)
        let brep = try XCTUnwrap(body.brep, "a loft of circles must be analytic")
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar, 2, "the two circular caps")
        XCTAssertEqual(counts.cylindrical + counts.other, 1, "ONE swept wall")

        // Frustum: (h/3)·π·(r0² + r0·r1 + r1²).
        let exact = (height / 3) * Double.pi * (r0 * r0 + r0 * r1 + r1 * r1)
        let solidBody = try XCTUnwrap(STEPKit.body(from: brep, name: "l", revision: 1))
        XCTAssertEqual(volume(solidBody), exact, accuracy: exact * 0.01)
    }

    /// A loft whose section has HOLES cannot be expressed by ThruSections, so
    /// it must keep the mesh result rather than silently lose the inner loop.
    func testALoftWithHolesStaysOnTheMeshPathRatherThanLosingTheHole() throws {
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
        let feature = FeatureID(), bodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: feature, name: "Loft",
                kind: .loft(
                    sections: [
                        ProfileRef(sketchID: lower, entityIDs: [outerID],
                                   holeEntityIDs: [[innerID]], seedPoint: nil),
                        ProfileRef(sketchID: upper, entityIDs: [upperID], holeEntityIDs: [], seedPoint: nil),
                    ],
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])

        let body = try XCTUnwrap(
            evaluate(graph, sketches: [lowerSketch, upperSketch]).bodies.first)
        XCTAssertNil(body.brep,
                     "a holed section has no ThruSections equivalent; the mesh "
                     + "result must stand rather than a solid missing its hole")
        XCTAssertFalse(body.render.positions.isEmpty, "but the body still exists")
    }

    // MARK: - Sweep

    /// A circle swept along a straight spine is a cylinder — analytic wall.
    func testSweepingACircleAlongALineIsAnalytic() throws {
        let sketchID = SketchID(), circleID = UUID()
        let radius = 2.0
        let sketch = Sketch(id: sketchID, plane: .ground, entities: [
            .circle(id: circleID, center: .zero, radius: radius),
        ])
        let plane = SketchPlane.ground
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        let spine: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0, 12, 0)]

        let brep = try XCTUnwrap(
            OCCTKernel.sweepSolid(outer: profile, holes: [], plane: plane, spine: spine),
            "a straight sweep of a circle must build")
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.cylindrical, 1, "one analytic wall")

        let body = try XCTUnwrap(STEPKit.body(from: brep, name: "s", revision: 1))
        XCTAssertEqual(volume(body), Double.pi * radius * radius * 12, accuracy: 0.5)
    }
}
