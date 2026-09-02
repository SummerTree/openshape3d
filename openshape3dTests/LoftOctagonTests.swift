//
//  LoftOctagonTests.swift
//  openshape3dTests
//
//  Regression for the BEG 55 motor end cap (2026-09-02): `feature.loft`
//  through two similar octagons on parallel planes, unioned into the
//  octagonal motor body whose bottom face is the loft's top section, KILLED
//  the app — the agent connection closed with no response, no crash report,
//  nothing in the log. The same octagons as a draft extrude built fine.
//
//  These build the exact reproduction as pure values, bisected: the kernel
//  loft alone, the graph loft as a new body, then the union — and finally
//  the Euclid fallback the union used to take, which is where it died.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class LoftOctagonTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private func evaluate(_ graph: FeatureGraph, sketches: [Sketch]) -> EvalResult {
        graph.evaluate(sketches: sketches, planes: [],
                       naming: SignatureNaming(), nextRevision: RevisionSource().next)
    }

    // MARK: - The BEG 55 small-motor octagon (scripts/rebuild_beg55.py)

    /// Half across-flats 75, corner chamfer 25, centred on x = 0, y = 165.7.
    private static let cy = 165.7
    private static let half = 75.0
    private static let chamfer = 25.0
    /// The end-cap section: the same octagon scaled about (0, cy).
    private static let capScale = 54.5 / 75.0

    private static func octagon(scale s: Double = 1) -> [SIMD2<Double>] {
        let h = half, c = chamfer
        let pts: [SIMD2<Double>] = [
            SIMD2(h, cy - (h - c)), SIMD2(h, cy + (h - c)),
            SIMD2(h - c, cy + h), SIMD2(-(h - c), cy + h),
            SIMD2(-h, cy + (h - c)), SIMD2(-h, cy - (h - c)),
            SIMD2(-(h - c), cy - h), SIMD2(h - c, cy - h),
        ]
        return pts.map { SIMD2($0.x * s, cy + ($0.y - cy) * s) }
    }

    /// Area of the octagon: the 2h square less four chamfer triangles.
    private static func octagonArea(scale s: Double = 1) -> Double {
        (4 * half * half - 2 * chamfer * chamfer) * s * s
    }

    /// Plane z = `z` with the agent's `XY` basis: local (u, v) = (x, y).
    private static func plane(z: Double) -> SketchPlane {
        SketchPlane(origin: SIMD3(0, 0, z), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
    }

    /// The agent's `poly(...)`: one `.line` per side, closing back to the start.
    private static func lineLoopSketch(id: SketchID, z: Double,
                                       points: [SIMD2<Double>]) -> Sketch {
        Sketch(id: id, plane: plane(z: z), entities: points.indices.map { i in
            .line(id: UUID(), a: points[i], b: points[(i + 1) % points.count])
        })
    }

    private static let seed = SIMD2(0.0, cy)

    /// Frustum between two parallel similar sections: h/3·(A0 + √(A0·A1) + A1).
    private static func frustumVolume(height: Double) -> Double {
        let a0 = octagonArea(scale: capScale), a1 = octagonArea()
        return height / 3 * (a0 + (a0 * a1).squareRoot() + a1)
    }

    // MARK: - 1. Kernel loft alone

    func testKernelLoftOfTwoOctagonsBuildsAFrustum() throws {
        let lower = Self.lineLoopSketch(id: SketchID(), z: 73,
                                        points: Self.octagon(scale: Self.capScale))
        let upper = Self.lineLoopSketch(id: SketchID(), z: 98, points: Self.octagon())
        let lowerProfile = try XCTUnwrap(ProfileDetector.profiles(at: Self.seed, in: lower).first)
        let upperProfile = try XCTUnwrap(ProfileDetector.profiles(at: Self.seed, in: upper).first)
        XCTAssertEqual(lowerProfile.loop.count, 8, "a line loop is packed as a polyline")
        XCTAssertEqual(upperProfile.loop.count, 8)

        let history = OCCTShapeHistory()
        let brep = try XCTUnwrap(OCCTKernel.loftSolid(
            sections: [(lowerProfile, lower.plane), (upperProfile, upper.plane)],
            history: history), "two octagons on parallel planes must loft")
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar + counts.cylindrical + counts.other, 10,
                       "eight walls and two caps")
        XCTAssertEqual(OCCTKernel.volume(brep), Self.frustumVolume(height: 25),
                       accuracy: Self.frustumVolume(height: 25) * 0.01)
        XCTAssertGreaterThan(history.rowCount, 0, "the loft must report its ancestry")
    }

    // MARK: - 2. Graph loft as a NEW body

    func testGraphLoftOfTwoOctagonsAsANewBody() throws {
        let lowerID = SketchID(), upperID = SketchID()
        let lower = Self.lineLoopSketch(id: lowerID, z: 73,
                                        points: Self.octagon(scale: Self.capScale))
        let upper = Self.lineLoopSketch(id: upperID, z: 98, points: Self.octagon())
        let feature = FeatureID(), bodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: feature, name: "Loft",
                kind: .loft(
                    sections: [
                        ProfileRef(sketchID: lowerID, entityIDs: [], holeEntityIDs: [],
                                   seedPoint: Self.seed),
                        ProfileRef(sketchID: upperID, entityIDs: [], holeEntityIDs: [],
                                   seedPoint: Self.seed),
                    ],
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])

        let result = evaluate(graph, sketches: [lower, upper])
        XCTAssertNil(result.errors[feature], "\(String(describing: result.errors[feature]))")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertNotNil(body.brep, "a hole-free polyline loft is analytic")
        let expected = Self.frustumVolume(height: 25)
        XCTAssertEqual(MeasureKit.volume(of: body), expected, accuracy: expected * 0.01)
    }

    // MARK: - 3. Graph loft UNIONED into the motor body (the live crash)

    func testGraphLoftOfTwoOctagonsUnionedIntoTheExtrudeSurvives() throws {
        let bodySketchID = SketchID(), lowerID = SketchID(), upperID = SketchID()
        // The motor body: the unscaled octagon at z = 98 extruded 180 along +Z.
        let bodySketch = Self.lineLoopSketch(id: bodySketchID, z: 98, points: Self.octagon())
        let lower = Self.lineLoopSketch(id: lowerID, z: 73,
                                        points: Self.octagon(scale: Self.capScale))
        let upper = Self.lineLoopSketch(id: upperID, z: 98, points: Self.octagon())

        let extrudeFeature = FeatureID(), loftFeature = FeatureID()
        let motorID = BodyID(), loftBodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: extrudeFeature, name: "Motor Body",
                kind: .extrude(
                    profile: ProfileRef(sketchID: bodySketchID, entityIDs: [],
                                        holeEntityIDs: [], seedPoint: Self.seed),
                    plane: PlaneRef(source: .sketch(bodySketchID)),
                    distance: Expr(value: 180), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [motorID]),
            FeatureNode(
                id: loftFeature, name: "Loft",
                kind: .loft(
                    sections: [
                        ProfileRef(sketchID: lowerID, entityIDs: [], holeEntityIDs: [],
                                   seedPoint: Self.seed),
                        ProfileRef(sketchID: upperID, entityIDs: [], holeEntityIDs: [],
                                   seedPoint: Self.seed),
                    ],
                    boolean: BooleanIntent(
                        op: .union,
                        resolvedTargets: [BodyRef(producer: extrudeFeature, bodyID: motorID)])),
                outputBodyIDs: [loftBodyID]),
        ])

        let result = evaluate(graph, sketches: [bodySketch, lower, upper])
        XCTAssertNil(result.errors[extrudeFeature])
        XCTAssertNil(result.errors[loftFeature], "\(String(describing: result.errors[loftFeature]))")
        let motor = try XCTUnwrap(result.bodies.first { $0.id == motorID })
        XCTAssertNotNil(motor.brep, "an analytic union of two analytic solids stays analytic")
        let expected = Self.octagonArea() * 180 + Self.frustumVolume(height: 25)
        XCTAssertEqual(MeasureKit.volume(of: motor), expected, accuracy: expected * 0.01)
        XCTAssertFalse(result.kernelNames[motorID, default: [:]].isEmpty,
                       "the fused result keeps kernel-face names, like every other boolean")
    }

    // MARK: - 4. The Euclid fallback must never trap on its way to a render mesh

    /// What actually killed the app. A target whose CSG mesh is rebuilt from
    /// its Float32 render buffers (every adopted body, and every body on
    /// document load) unioned with a Double-precision tool whose top cap
    /// coincides with the target's bottom face: the union leaves a wall
    /// polygon with four vertices ~5e-7 mm apart, its triangulation drops the
    /// sliver, and converting THAT mesh to a render mesh trapped inside
    /// Euclid's watertight assertion — no crash report, connection closed.
    /// The fallback still exists for mesh-only operands, so it must convert.
    func testAMeshUnionWithCoincidentCapsConvertsToARenderMeshWithoutTrapping() throws {
        let bodySketchID = SketchID()
        let bodySketch = Self.lineLoopSketch(id: bodySketchID, z: 98, points: Self.octagon())
        let lower = Self.lineLoopSketch(id: SketchID(), z: 73,
                                        points: Self.octagon(scale: Self.capScale))
        let upper = Self.lineLoopSketch(id: SketchID(), z: 98, points: Self.octagon())
        let extrudeFeature = FeatureID(), motorID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: extrudeFeature, name: "Motor Body",
                kind: .extrude(
                    profile: ProfileRef(sketchID: bodySketchID, entityIDs: [],
                                        holeEntityIDs: [], seedPoint: Self.seed),
                    plane: PlaneRef(source: .sketch(bodySketchID)),
                    distance: Expr(value: 180), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [motorID]),
        ])
        let motor = try XCTUnwrap(evaluate(graph, sketches: [bodySketch]).bodies.first)
        // The render-buffer init: the CSG mesh comes back from Float32.
        let target = Body(id: motor.id, name: motor.name, transform: .identity,
                          primitive: nil, render: motor.render, revision: 1)

        let lowerProfile = try XCTUnwrap(ProfileDetector.profiles(at: Self.seed, in: lower).first)
        let upperProfile = try XCTUnwrap(ProfileDetector.profiles(at: Self.seed, in: upper).first)
        let loftMesh = SweepLoftKit.loft(profiles: [
            (lowerProfile, [], lower.plane), (upperProfile, [], upper.plane)])
        let tool = Body(id: BodyID(), name: "tool", transform: .identity, primitive: nil,
                        euclidMesh: loftMesh, revision: 0)

        let union = KernelOps.boolean(.union, target: target, tool: tool)
        XCTAssertFalse(union.polygons.isEmpty)
        let body = Body(id: BodyID(), name: "union", transform: .identity, primitive: nil,
                        euclidMesh: union, revision: 2)
        XCTAssertGreaterThan(body.render.triangleCount, 0)
        let expected = Self.octagonArea() * 180 + Self.frustumVolume(height: 25)
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1), expected,
                       accuracy: expected * 0.01)
    }
}
