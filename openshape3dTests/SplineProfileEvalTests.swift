//
//  SplineProfileEvalTests.swift
//  openshape3dTests
//
//  Spline as an exact profile (docs/SPLINE_PROFILE_DESIGN.md, slice 1): a
//  spline extrudes to ONE smooth B-spline wall, its B-rep volume equals the
//  Gauss-exact area × height (which is also the cross-language pin — the
//  kernel's C++ Bézier conversion against the Swift one), the wall is named
//  by the spline entity, and a drafted spline falls back without error.
//

import XCTest
import simd
@testable import openshape3d

final class SplineProfileEvalTests: XCTestCase {

    private func evaluate(_ nodes: [FeatureNode], _ sketches: [Sketch]) -> EvalResult {
        var rev: UInt64 = 0
        return FeatureGraph(nodes: nodes).evaluate(
            sketches: sketches, planes: [], naming: SignatureNaming(),
            nextRevision: { rev += 1; return rev })
    }

    private func extrude(_ feature: FeatureID, sketch: SketchID, entities: [UUID],
                         seed: SIMD2<Double>, body: BodyID, distance: Double) -> FeatureNode {
        FeatureNode(id: feature, name: "E", kind: .extrude(
            profile: ProfileRef(sketchID: sketch, entityIDs: entities, holeEntityIDs: [], seedPoint: seed),
            plane: PlaneRef(source: .sketch(sketch)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
    }

    private func wallCount(_ names: [Int: ElementName], entity: UUID) -> Int {
        names.values.filter {
            if case let .profileWall(e, _) = $0.source { return e == entity }
            return false
        }.count
    }

    /// Unevenly spaced ring — the same points `CatmullRomBezierTests` pins.
    private let ring: [SIMD2<Double>] = [
        SIMD2(0, 0), SIMD2(30, 4), SIMD2(38, 22), SIMD2(20, 41), SIMD2(-6, 30), SIMD2(-12, 9)]

    /// The cross-language pin at its most direct: the kernel's B-spline poles
    /// are the Swift Bézier chain's control points, pole for pole.
    func testKernelSplinePolesMatchTheSwiftConversion() throws {
        for closed in [true, false] {
            let spans = CatmullRomBezier.spans(ring, closed: closed)
            var expected: [SIMD2<Double>] = [spans[0].p0]
            for s in spans { expected.append(contentsOf: [s.p1, s.p2, s.p3]) }
            let poles = try XCTUnwrap(OCCTKernel.splineEdgePoles(ring, closed: closed))
            XCTAssertEqual(poles.count, expected.count, "3·spans + 1 poles (closed: \(closed))")
            for (i, (got, want)) in zip(poles, expected).enumerated() {
                XCTAssertEqual(simd_length(got - want), 0, accuracy: 1e-9,
                               "pole \(i) (closed: \(closed)): kernel \(got) vs Swift \(want)")
            }
        }
    }

    func testClosedSplineExtrudesToOneSmoothWall() throws {
        let feature = FeatureID(), bodyID = BodyID(), sketchID = SketchID(), spline = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .spline(id: spline, points: ring, closed: true)])
        let result = evaluate([extrude(feature, sketch: sketchID, entities: [spline],
                                       seed: SIMD2(12, 18), body: bodyID, distance: 10)], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        let brep = try XCTUnwrap(body.brep, "a spline extrude is a real B-rep")

        // 2 caps + ONE B-spline wall — not one facet per sample.
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar, 2, "two caps: \(counts)")
        XCTAssertEqual(counts.other, 1, "one smooth spline wall: \(counts)")
        XCTAssertEqual(counts.cylindrical, 0)

        // Exact volume = height × the Gauss-exact area of the SAME curve. This
        // is the cross-language pin: the kernel built its Béziers in C++, the
        // area comes from the Swift conversion.
        let spans = CatmullRomBezier.spans(ring, closed: true)
        let want = 10 * abs(CatmullRomBezier.signedArea(spans))
        let vol = MeasureKit.volume(of: body)
        XCTAssertEqual(vol, want, accuracy: want * 1e-6, "B-rep \(vol) vs Gauss-exact \(want)")

        // Named by the spline entity, once.
        let names = try XCTUnwrap(result.kernelNames[bodyID])
        XCTAssertEqual(wallCount(names, entity: spline), 1, "one wall, owned by the spline")

        // Face AREAS are identity signatures, so they must be exact too: the
        // spline wall is perimeter × height, the perimeter integrated here
        // with 16 × 5-point Gauss–Legendre per Bézier span (≈1e-10). Before
        // the adaptive integrator the kernel read this 0.4–1.3 % off.
        let gl: [(x: Double, w: Double)] = [
            (0, 0.5688888888888889),
            (0.5384693101056831, 0.4786286704993665), (-0.5384693101056831, 0.4786286704993665),
            (0.906179845938664, 0.2369268850561891), (-0.906179845938664, 0.2369268850561891)]
        var perimeter = 0.0
        for span in spans {
            let sub = 16
            for k in 0..<sub {
                let a = Double(k) / Double(sub), b = Double(k + 1) / Double(sub)
                for node in gl {
                    let u = (a + b) / 2 + node.x * (b - a) / 2
                    perimeter += node.w * (b - a) / 2 * simd_length(CatmullRomBezier.derivative(span, u))
                }
            }
        }
        let faces = OCCTKernel.faceInfo(brep)
        let wall = try XCTUnwrap(faces.first { $0.signature == nil }, "the one non-planar face")
        // Third estimate, independent of both integrals: the tessellation's
        // triangle area less the two caps (a chordal mesh reads a curved wall
        // slightly LOW, never 4 % off).
        let mesh = body.render
        var meshArea = 0.0
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[t])])
            let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[t + 1])])
            let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[t + 2])])
            meshArea += simd_length(simd_cross(b - a, c - a)) / 2
        }
        let meshWall = meshArea - 2 * want / 10
        XCTAssertEqual(wall.area, perimeter * 10, accuracy: perimeter * 10 * 1e-6,
                       "wall area \(wall.area) vs perimeter × height \(perimeter * 10); tessellated wall \(meshWall)")
        for cap in faces where cap.signature != nil {
            XCTAssertEqual(cap.area, want / 10, accuracy: want / 10 * 1e-6, "each cap is the profile's area")
        }
    }

    /// An open spline closes a loop with lines: three planar walls, one spline
    /// wall, and Green's theorem over the mixed boundary gives the volume.
    func testOpenSplineJoinsLinesIntoOneExactLoop() throws {
        let feature = FeatureID(), bodyID = BodyID(), sketchID = SketchID()
        let spline = UUID(), right = UUID(), bottom = UUID(), left = UUID()
        let top: [SIMD2<Double>] = [SIMD2(0, 20), SIMD2(10, 26), SIMD2(20, 22), SIMD2(30, 28), SIMD2(40, 20)]
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .spline(id: spline, points: top, closed: false),
            .line(id: right, a: SIMD2(40, 20), b: SIMD2(40, 0)),
            .line(id: bottom, a: SIMD2(40, 0), b: SIMD2(0, 0)),
            .line(id: left, a: SIMD2(0, 0), b: SIMD2(0, 20))])
        let result = evaluate([extrude(feature, sketch: sketchID, entities: [spline, right, bottom, left],
                                       seed: SIMD2(20, 10), body: bodyID, distance: 10)], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        let brep = try XCTUnwrap(body.brep)

        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar, 5, "2 caps + 3 straight walls: \(counts)")
        XCTAssertEqual(counts.other, 1, "one spline wall: \(counts)")

        // Traversed spline left→right along the top, then down, left, up (CW):
        // ½∮(x dy − y dx) = spline Gauss term + ½ Σ cross over the three lines.
        let spans = CatmullRomBezier.spans(top, closed: false)
        let lines: [(SIMD2<Double>, SIMD2<Double>)] = [
            (SIMD2(40, 20), SIMD2(40, 0)), (SIMD2(40, 0), SIMD2(0, 0)), (SIMD2(0, 0), SIMD2(0, 20))]
        let lineTerm = lines.reduce(0.0) { $0 + ($1.0.x * $1.1.y - $1.0.y * $1.1.x) } / 2
        let area = abs(CatmullRomBezier.signedArea(spans) + lineTerm)
        let want = 10 * area
        let vol = MeasureKit.volume(of: body)
        XCTAssertEqual(vol, want, accuracy: want * 1e-6, "B-rep \(vol) vs Green's \(want)")

        let names = try XCTUnwrap(result.kernelNames[bodyID])
        XCTAssertEqual(wallCount(names, entity: spline), 1)
        for line in [right, bottom, left] { XCTAssertEqual(wallCount(names, entity: line), 1) }
    }

    /// A drafted spline profile takes the polygon path (a cubic's offset is
    /// not a cubic) — valid geometry, no error.
    func testDraftOfASplineProfileFallsBackWithoutError() throws {
        let feature = FeatureID(), bodyID = BodyID(), sketchID = SketchID(), spline = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .spline(id: spline, points: ring, closed: true)])
        let node = FeatureNode(id: feature, name: "D", kind: .draftExtrude(
            profile: ProfileRef(sketchID: sketchID, entityIDs: [spline], holeEntityIDs: [],
                                seedPoint: SIMD2(12, 18)),
            plane: PlaneRef(source: .sketch(sketchID)),
            distance: Expr(value: 10), taperAngle: Expr(value: 5), symmetric: false,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: [])), outputBodyIDs: [bodyID])
        let result = evaluate([node], [sketch])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertNotNil(body.brep)
        XCTAssertGreaterThan(MeasureKit.volume(of: body), 0)
    }
}
