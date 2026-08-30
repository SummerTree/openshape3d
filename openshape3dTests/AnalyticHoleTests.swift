//
//  AnalyticHoleTests.swift
//  openshape3dTests
//
//  Mission 2 (B-rep follow-through): a CIRCULAR HOLE in an extruded profile
//  must be an analytic cylindrical wall, not the polygon it was tessellated
//  into for the mesh path.
//
//  The outer loop has had that treatment since the port — `extrudeShape` takes
//  `isCircle` and builds a `gp_Circ` — but every hole went through `PolyWire`,
//  so a plate with a Ø8 hole came out with a 64-sided hole. It looks round and
//  is not: a fillet around the rim has 64 segments to chase, STEP exports 64
//  planes, and "OCCT is the source of truth" quietly stops being true at the
//  first hole anyone drills in a sketch.
//

import XCTest
import simd
@testable import openshape3d

final class AnalyticHoleTests: XCTestCase {

    private func squareLoop(side: Double) -> [SIMD2<Double>] {
        let h = side / 2
        return [SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]
    }

    private func circleLoop(radius: Double, segments: Int = 64) -> [SIMD2<Double>] {
        (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return SIMD2(cos(a) * radius, sin(a) * radius)
        }
    }

    /// A 20 × 20 × 5 plate with a Ø8 hole through it.
    private func plateWithHole(holeRadius: Double = 4) -> BRepHandle? {
        OCCTKernel.extrudeShape(
            outerLoop: squareLoop(side: 20), isCircle: false,
            circleCenter: .zero, circleRadius: 0,
            holes: [OCCTKernel.ExtrudeHole(
                loop: circleLoop(radius: holeRadius),
                circle: OCCTKernel.CircleSpec(center: .zero, radius: holeRadius))],
            zMin: 0, zMax: 5,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1))
    }

    /// The headline: the hole is ONE cylindrical face.
    func testACircularHoleIsOneAnalyticCylinder() throws {
        let plate = try XCTUnwrap(plateWithHole())
        let counts = OCCTKernel.faceTypeCounts(plate)
        XCTAssertEqual(counts.cylindrical, 1,
                       "the hole must be a cylinder, not a barrel of facets")
        XCTAssertEqual(counts.planar, 6,
                       "four walls and two caps — the hole contributes no planes")
        XCTAssertEqual(counts.other, 0)
    }

    /// …and it is the right size. A hole built from the tessellated polygon
    /// would be INSCRIBED in the true circle and come out slightly small, so
    /// this catches "analytic but from the wrong geometry" as well.
    func testTheHoleHasTheRadiusItWasDrawnWith() throws {
        let plate = try XCTUnwrap(plateWithHole(holeRadius: 4))
        let mesh = OCCTKernel.renderMesh(from: plate)
        // Points on the hole wall are the ones ~4 from the axis.
        var minRadius = Double.greatestFiniteMagnitude
        var maxRadius = 0.0
        for p in mesh.positions {
            let r = hypot(Double(p.x), Double(p.y))
            guard r < 8 else { continue }   // ignore the 20 mm outer walls
            minRadius = min(minRadius, r)
            maxRadius = max(maxRadius, r)
        }
        XCTAssertEqual(maxRadius, 4, accuracy: 0.02, "the hole is Ø8, not smaller")
        XCTAssertGreaterThan(minRadius, 3.9, "…and round, not a polygon")
    }

    /// A non-circular hole still works — it is simply the polyline it was
    /// drawn as. The analytic path must not become the only path.
    func testAPolygonalHoleStillPunchesThrough() throws {
        let plate = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: squareLoop(side: 20), isCircle: false,
            circleCenter: .zero, circleRadius: 0,
            holes: [OCCTKernel.ExtrudeHole(loop: squareLoop(side: 6))],
            zMin: 0, zMax: 5,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        let counts = OCCTKernel.faceTypeCounts(plate)
        XCTAssertEqual(counts.cylindrical, 0)
        XCTAssertEqual(counts.planar, 10, "4 outer walls + 4 hole walls + 2 caps")
    }

    /// Two circular holes give two cylinders — the analytic path is per-hole,
    /// not a single special case.
    func testTwoCircularHolesGiveTwoCylinders() throws {
        let plate = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: squareLoop(side: 30), isCircle: false,
            circleCenter: .zero, circleRadius: 0,
            holes: [
                OCCTKernel.ExtrudeHole(
                    loop: circleLoop(radius: 3).map { $0 + SIMD2(-8, 0) },
                    circle: OCCTKernel.CircleSpec(center: SIMD2(-8, 0), radius: 3)),
                OCCTKernel.ExtrudeHole(
                    loop: circleLoop(radius: 3).map { $0 + SIMD2(8, 0) },
                    circle: OCCTKernel.CircleSpec(center: SIMD2(8, 0), radius: 3)),
            ],
            zMin: 0, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        XCTAssertEqual(OCCTKernel.faceTypeCounts(plate).cylindrical, 2)
    }

    // MARK: - Through the feature graph, the way the app builds one

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    /// A sketched 20 × 20 plate with a Ø8 circle inside it, extruded 5 —
    /// exactly what a user draws when they want a plate with a hole. The
    /// kernel tests above prove `extrudeShape` CAN build an analytic bore;
    /// this proves the feature path actually asks it to.
    func testASketchedPlateWithAHoleExtrudesToAnAnalyticBore() throws {
        let sketchID = SketchID()
        let rectID = UUID()
        let circleID = UUID()
        let extrudeFeature = FeatureID()
        let bodyID = BodyID()

        let sketch = Sketch(
            id: sketchID, name: "S", plane: .ground,
            entities: [
                .rect(id: rectID, min: SIMD2(-10, -10), max: SIMD2(10, 10)),
                .circle(id: circleID, center: .zero, radius: 4),
            ])

        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: extrudeFeature, name: "Plate",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectID],
                                        holeEntityIDs: [[circleID]], seedPoint: nil),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    distance: Expr(value: 5), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [bodyID]),
        ])

        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[extrudeFeature])
        let body = try XCTUnwrap(result.bodies.first)
        let brep = try XCTUnwrap(body.brep, "an extrude should carry its analytic solid")

        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.cylindrical, 1,
                       "the drilled hole is a cylinder — this is the mission-2 gap")
        XCTAssertEqual(counts.planar, 6, "four walls and two caps")

        // And the solid is the right size: 20·20·5 minus a Ø8 bore.
        let expected = 20.0 * 20.0 * 5.0 - .pi * 16 * 5
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1), expected, accuracy: 1.0)
    }

    /// Mission 2 also listed "extrude-into-target boolean" as Euclid-first.
    /// It is NOT — `evalExtrude`'s boolean branch already composes in OCCT
    /// when the target carries a brep. Pinned here so the claim is checked
    /// rather than believed, and so the path cannot regress unnoticed.
    func testExtrudeCutIntoAnAnalyticBoxStaysAnalytic() throws {
        let sketchID = SketchID()
        let circleID = UUID()
        let boxFeature = FeatureID()
        let cutFeature = FeatureID()
        let boxID = BodyID()

        let sketch = Sketch(id: sketchID, name: "S", plane: .ground,
                            entities: [.circle(id: circleID, center: .zero, radius: 3)])

        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: boxFeature, name: "Box",
                kind: .primitive(spec: .box(width: 20, depth: 20, height: 10),
                                 placement: .identity),
                outputBodyIDs: [boxID]),
            FeatureNode(
                id: cutFeature, name: "Cut",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [circleID],
                                        holeEntityIDs: [], seedPoint: nil),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    distance: Expr(value: 20), symmetric: false,
                    boolean: BooleanIntent(
                        op: .subtract,
                        resolvedTargets: [BodyRef(producer: boxFeature, bodyID: boxID)]),
                    extraProfiles: []),
                outputBodyIDs: []),
        ])

        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[cutFeature])
        let body = try XCTUnwrap(result.bodies.first)
        let brep = try XCTUnwrap(body.brep,
                                 "an extrude-cut into an analytic body must stay analytic")
        XCTAssertEqual(OCCTKernel.faceTypeCounts(brep).cylindrical, 1,
                       "the cut leaves a round bore, not a faceted one")
    }

    /// Multi-profile extrudes used to skip the B-rep path entirely — both
    /// call sites read `extras.isEmpty`, so selecting a SECOND region and
    /// pulling produced a mesh-only body. Two separate circles pulled together
    /// must now give two analytic cylinders in one solid.
    func testAMultiProfileExtrudeStaysAnalytic() throws {
        let sketchID = SketchID()
        let leftID = UUID()
        let rightID = UUID()
        let extrudeFeature = FeatureID()
        let bodyID = BodyID()

        let sketch = Sketch(
            id: sketchID, name: "S", plane: .ground,
            entities: [
                .circle(id: leftID, center: SIMD2(-10, 0), radius: 3),
                .circle(id: rightID, center: SIMD2(10, 0), radius: 3),
            ])

        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: extrudeFeature, name: "Posts",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [leftID],
                                        holeEntityIDs: [], seedPoint: nil),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    distance: Expr(value: 6), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: [ProfileRef(sketchID: sketchID, entityIDs: [rightID],
                                               holeEntityIDs: [], seedPoint: nil)]),
                outputBodyIDs: [bodyID]),
        ])

        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[extrudeFeature])
        let body = try XCTUnwrap(result.bodies.first)
        let brep = try XCTUnwrap(body.brep,
                                 "a multi-profile extrude must still carry its solid")
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.cylindrical, 2, "both posts stay round")
        XCTAssertEqual(counts.planar, 4, "two caps each, no seam faces")

        // Two disjoint Ø6 × 6 posts.
        let expected = 2 * Double.pi * 9 * 6
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1), expected, accuracy: 2.0)
    }

    /// A circular outer AND a circular hole — a washer, which is two
    /// cylinders and two annular caps.
    func testAWasherIsTwoCylinders() throws {
        let washer = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: circleLoop(radius: 10), isCircle: true,
            circleCenter: .zero, circleRadius: 10,
            holes: [OCCTKernel.ExtrudeHole(
                loop: circleLoop(radius: 4),
                circle: OCCTKernel.CircleSpec(center: .zero, radius: 4))],
            zMin: 0, zMax: 2,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        let counts = OCCTKernel.faceTypeCounts(washer)
        XCTAssertEqual(counts.cylindrical, 2, "outer wall and bore, both analytic")
        XCTAssertEqual(counts.planar, 2, "the two annular caps")
    }
}
