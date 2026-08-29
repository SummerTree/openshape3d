//
//  ReplaceFaceBRepTests.swift
//  openshape3dTests
//
//  Replace Face on the ANALYTIC path (spec §4.12). `ReplaceFaceTests` covers
//  the planning and the Euclid result; what matters here is the thing that is
//  easy to get silently wrong — that a body which arrived with a `brep` still
//  has one afterwards, and that the brep is the same solid the mesh path would
//  have produced.
//
//  Losing the brep here would not look like a bug: the geometry would render
//  correctly and only degrade on the next save, when the tessellation gets
//  written as if it were the truth (2026-08-25 review, C4). So these tests
//  assert on the ANALYTIC face counts, which a mesh round trip cannot fake.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class ReplaceFaceBRepTests: XCTestCase {

    /// A 10 mm analytic cube and its +Y (top) face — `Euclid.Mesh.primitive`
    /// puts a box's base on y = 0, and `primitiveShape` matches it.
    private func cube() throws -> (brep: BRepHandle, render: RenderMesh) {
        let spec = PrimitiveSpec.box(width: 10, depth: 10, height: 10)
        let brep = try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))
        let m = OCCTKernel.renderMesh(from: brep)
        return (brep, RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices))
    }

    private func face(of mesh: RenderMesh, normal axis: SIMD3<Float>) throws -> PlanarFace {
        for t in 0..<mesh.triangleCount {
            let n = mesh.normals[Int(mesh.indices[t * 3])]
            guard simd_dot(n, axis) > 0.999 else { continue }
            if let face = FaceTopology.planarFace(in: mesh, seedTriangle: t) { return face }
        }
        throw XCTSkip("no face with that normal")
    }

    private func bounds(_ handle: BRepHandle) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let m = OCCTKernel.renderMesh(from: handle)
        return RenderMesh(positions: m.positions, normals: m.normals,
                          indices: m.indices).localAABB
    }

    // MARK: - Extending

    /// Extending the top of a cube from y = 10 to y = 16 must leave a taller
    /// cube that is still SIX planar faces — not a fused pair of solids with a
    /// seam, and not a mesh.
    func testExtendingTheTopKeepsSixAnalyticFaces() throws {
        let (brep, render) = try cube()
        let top = try face(of: render, normal: SIMD3(0, 1, 0))
        let plan = try ReplaceFaceKit.plan(
            face: top, targetOrigin: SIMD3(0, 16, 0), targetNormal: SIMD3(0, 1, 0))
        XCTAssertEqual(plan, .extend(distance: 6))

        let result = try XCTUnwrap(ReplaceFaceKit.applyBRep(to: brep, face: top, plan: plan),
                                   "the analytic path must produce a solid")
        let counts = OCCTKernel.faceTypeCounts(result)
        XCTAssertEqual(counts.planar, 6, "a taller box is still six planar faces")
        XCTAssertEqual(counts.cylindrical, 0)
        XCTAssertEqual(counts.other, 0)

        let box = bounds(result)
        XCTAssertEqual(Double(box.max.y), 16, accuracy: 1e-5,
                       "the face ends up ON the target plane")
        XCTAssertEqual(Double(box.min.y), 0, accuracy: 1e-5, "the far side does not move")
    }

    /// Trimming is the same operation in reverse: cut back to y = 4.
    func testTrimmingTheTopCutsBackToTheTargetPlane() throws {
        let (brep, render) = try cube()
        let top = try face(of: render, normal: SIMD3(0, 1, 0))
        let plan = try ReplaceFaceKit.plan(
            face: top, targetOrigin: SIMD3(0, 4, 0), targetNormal: SIMD3(0, 1, 0))
        XCTAssertEqual(plan, .trim(distance: 6))

        let result = try XCTUnwrap(ReplaceFaceKit.applyBRep(to: brep, face: top, plan: plan))
        XCTAssertEqual(OCCTKernel.faceTypeCounts(result).planar, 6)
        XCTAssertEqual(Double(bounds(result).max.y), 4, accuracy: 1e-5)
    }

    // MARK: - The two paths must agree

    /// The analytic and Euclid routes are two implementations of one operation,
    /// and the app picks between them by whether the body happens to carry a
    /// brep. If they disagreed, a body would change shape depending on how it
    /// was built — so they are pinned to each other here.
    func testAnalyticAndMeshPathsProduceTheSameBounds() throws {
        let (brep, render) = try cube()
        let top = try face(of: render, normal: SIMD3(0, 1, 0))
        let plan = try ReplaceFaceKit.plan(
            face: top, targetOrigin: SIMD3(0, 14, 0), targetNormal: SIMD3(0, 1, 0))

        let analytic = try XCTUnwrap(ReplaceFaceKit.applyBRep(to: brep, face: top, plan: plan))
        let meshed = try XCTUnwrap(ReplaceFaceKit.apply(
            to: Euclid.Mesh.primitive(.box(width: 10, depth: 10, height: 10)),
            face: top, plan: plan))

        let a = bounds(analytic)
        let m = EuclidBridge.renderMesh(from: meshed).localAABB
        for k in 0..<3 {
            XCTAssertEqual(Double(a.min[k]), Double(m.min[k]), accuracy: 1e-4)
            XCTAssertEqual(Double(a.max[k]), Double(m.max[k]), accuracy: 1e-4)
        }
    }

    /// The z-range the two paths sweep is shared, so the prism can never point
    /// one way analytically and the other way in Euclid.
    func testSweptRangeSpansFaceToTargetForBothDirections() throws {
        let (_, render) = try cube()
        let top = try face(of: render, normal: SIMD3(0, 1, 0))

        let extend = ReplaceFaceKit.sweptZRange(face: top, plan: .extend(distance: 6))
        XCTAssertEqual(extend.zMax - extend.zMin, 6, accuracy: 1e-9)
        let trim = ReplaceFaceKit.sweptZRange(face: top, plan: .trim(distance: 6))
        XCTAssertEqual(trim.zMax - trim.zMin, 6, accuracy: 1e-9)
        // They span opposite sides of the face.
        XCTAssertNotEqual(extend.zMin, trim.zMin)
    }

    // MARK: - Refusals survive the analytic route

    /// A non-parallel target is refused before any solid is built — the gap
    /// varies across the face, so one prism would be wrong everywhere but a
    /// line, and shipping that quietly is worse than saying no.
    func testANonParallelTargetIsStillRefused() throws {
        let (_, render) = try cube()
        let top = try face(of: render, normal: SIMD3(0, 1, 0))
        XCTAssertThrowsError(try ReplaceFaceKit.plan(
            face: top, targetOrigin: SIMD3(0, 16, 0),
            targetNormal: simd_normalize(SIMD3<Double>(1, 1, 0)))) { error in
            XCTAssertEqual(error as? ReplaceFaceKit.Refusal, .targetNotParallel)
        }
    }

    /// A zero-distance plan builds nothing rather than an empty solid OCCT
    /// would choke on.
    func testADegeneratePlanBuildsNoSolid() throws {
        let (_, render) = try cube()
        let top = try face(of: render, normal: SIMD3(0, 1, 0))
        XCTAssertNil(ReplaceFaceKit.sweptBRep(face: top, plan: .extend(distance: 0)))
    }
}
