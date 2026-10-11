//
//  PushPullBRepTests.swift
//  openshape3dTests
//
//  A planar-face push/pull on an analytic body stays analytic
//  (`OCCTKernel.pushPullResult`). Until 2026-10 every face push/pull produced
//  a mesh, and everything downstream of it — booleans, fillets, sketches on
//  its faceted faces — ran on the mesh path (bug report a6fea315, covered end
//  to end in `FilletHolesBugReportTests`).
//

import XCTest
import simd
@testable import openshape3d

final class PushPullBRepTests: XCTestCase {

    private func body(_ spec: PrimitiveSpec) throws -> Body {
        let brep = try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))
        return try XCTUnwrap(STEPKit.body(from: brep, name: "b", revision: 1))
    }

    /// The planar face whose outward normal is `normal` and whose plane sits
    /// furthest along it — "the top" for +Z.
    private func face(_ normal: SIMD3<Float>, of body: Body) throws -> PlanarFace {
        let mesh = body.render
        var best: (offset: Float, triangle: Int)?
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[3 * t])]
            let b = mesh.positions[Int(mesh.indices[3 * t + 1])]
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            guard simd_dot(n, normal) > 0.999 else { continue }
            let offset = simd_dot(a, normal)
            if offset > (best?.offset ?? -.infinity) { best = (offset, t) }
        }
        let seed = try XCTUnwrap(best?.triangle, "no face facing \(normal)")
        return try XCTUnwrap(FaceTopology.planarFace(in: mesh, seedTriangle: seed))
    }

    private func pushPull(_ body: Body, _ normal: SIMD3<Float>, by distance: Double) throws
        -> Result<BRepHandle, OCCTOpError> {
        OCCTKernel.pushPullResult(try XCTUnwrap(body.brep), face: try face(normal, of: body),
                                  render: body.render, distance: distance)
    }

    func testPullingABoxFaceExtendsTheSolid() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let handle = try pushPull(box, SIMD3(0, 0, 1), by: 5).get()
        XCTAssertTrue(OCCTKernel.healthReport(for: handle).isValid)
        XCTAssertEqual(OCCTKernel.volume(handle), 1500, accuracy: 1e-6)
        // The pulled walls merge with the old ones: still a six-faced box.
        XCTAssertEqual(OCCTKernel.faceTypeCounts(handle).planar, 6)
    }

    func testPushingABoxFaceTruncatesTheSolid() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let handle = try pushPull(box, SIMD3(1, 0, 0), by: -4).get()
        XCTAssertTrue(OCCTKernel.healthReport(for: handle).isValid)
        XCTAssertEqual(OCCTKernel.volume(handle), 600, accuracy: 1e-6)
        XCTAssertEqual(OCCTKernel.faceTypeCounts(handle).planar, 6)
    }

    /// The point of keeping the B-rep: a pulled cylinder cap extends a TRUE
    /// cylinder wall, where the mesh path extruded the cap's 48-gon outline.
    func testPullingACylinderCapKeepsTheWallRound() throws {
        let cylinder = try body(.cylinder(radius: 5, height: 12))   // axis +Y
        let handle = try pushPull(cylinder, SIMD3(0, 1, 0), by: 3).get()
        XCTAssertTrue(OCCTKernel.healthReport(for: handle).isValid)
        XCTAssertEqual(OCCTKernel.volume(handle), .pi * 25 * 15, accuracy: 1e-3)
        let faces = OCCTKernel.faceTypeCounts(handle)
        XCTAssertEqual(faces.planar, 2, "two caps, no faceted wall strips")
        XCTAssertGreaterThanOrEqual(faces.cylindrical, 1)
        XCTAssertEqual(faces.other, 0)
    }

    /// Same semantics as the mesh path, both ways, so a body keeps its shape
    /// whether it replays through OCCT or not. (A box: the mesh path on a
    /// cylinder's dense tessellation takes tens of seconds. The bug-report
    /// fixture checks a curved case and agrees to 12 digits.)
    func testBothDirectionsMatchTheMeshPath() throws {
        let box = try body(.box(width: 10, depth: 6, height: 8))
        for (normal, distance) in [(SIMD3<Float>(0, 0, 1), -2.5), (SIMD3<Float>(1, 0, 0), 3.0)] {
            let handle = try pushPull(box, normal, by: distance).get()
            let mesh = KernelOps.pushPullPlanarFace(
                mesh: box.euclidMesh(), face: try face(normal, of: box), distance: distance)
            XCTAssertEqual(OCCTKernel.volume(handle),
                           MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1),
                           accuracy: 1e-6, "\(normal) by \(distance)")
        }
    }

    /// The render mesh has flat facets on a curved wall; growing a "planar
    /// face" from one must not push the cylinder's real, curved face. The
    /// kernel refuses, and the caller falls back to the mesh path as before.
    func testAFacetOfACurvedWallIsRefused() throws {
        let cylinder = try body(.cylinder(radius: 5, height: 12))   // axis +Y
        guard case .failure = try pushPull(cylinder, SIMD3(0, 0, 1), by: 2) else {
            return XCTFail("a wall facet is not a planar kernel face")
        }
    }

    /// Pushing a face through the whole body leaves nothing; the kernel says
    /// so, and the callers fall back to the mesh path, which reports it.
    func testPushingThroughTheWholeBodyFails() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        guard case .failure = try pushPull(box, SIMD3(0, 0, 1), by: -12) else {
            return XCTFail("a push past the far face must not return a solid")
        }
    }
}
