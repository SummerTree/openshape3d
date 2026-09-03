//
//  DraftFaceTests.swift
//  openshape3dTests
//
//  Draft of an EXISTING face (SOLIDWORKS "Draft", the "ALL DRAFT 5°" on a cast
//  part) — a face tilt hinged on the line where the face meets the neutral
//  plane. Pure geometry on a mesh; no session.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class DraftFaceTests: XCTestCase {

    /// A box from the origin, width × depth × height along x, y, z.
    private func box(_ w: Double, _ d: Double, _ h: Double) -> Euclid.Mesh {
        Euclid.Mesh.cube(center: Vector(w / 2, d / 2, h / 2), size: Vector(w, d, h))
    }

    /// The planar face of `mesh` whose outward normal is closest to `normal`.
    private func face(of mesh: Euclid.Mesh, facing normal: SIMD3<Double>)
        throws -> FaceTopology.PlanarFace {
        let render = EuclidBridge.renderMesh(from: mesh)
        let faces = FaceTopology.enumerateFaces(in: render).planar
        let wanted = simd_normalize(normal)
        let best = faces.max { a, b in
            let na = simd_normalize(SketchPlane(origin: a.origin, xAxis: a.basisX, yAxis: a.basisY).normal)
            let nb = simd_normalize(SketchPlane(origin: b.origin, xAxis: b.basisX, yAxis: b.basisY).normal)
            return simd_dot(na, wanted) < simd_dot(nb, wanted)
        }
        return try XCTUnwrap(best, "no planar face facing \(normal)")
    }

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        KernelOps.volume(of: mesh)
    }

    /// Drafting ONE side of a box by θ, hinged on the bottom, removes a wedge
    /// of ½ · h² · tanθ · depth — the closed form the sheet's volume implies.
    func testOneDraftedSideRemovesTheWedge() throws {
        let w = 100.0, d = 60.0, h = 20.0, degrees = 5.0
        let mesh = box(w, d, h)
        let side = try face(of: mesh, facing: SIMD3(1, 0, 0))     // the +x wall
        let drafted = KernelOps.draftFace(
            mesh: mesh, face: side,
            neutralOrigin: SIMD3(0, 0, 0), neutralNormal: SIMD3(0, 0, 1), degrees: degrees)
        let wedge = 0.5 * h * h * tan(degrees * .pi / 180) * d
        XCTAssertEqual(volume(drafted), w * d * h - wedge, accuracy: 1.0,
                       "a 5° draft on one wall removes ½h²·tanθ·d")
    }

    /// Positive is the mould sign: the body NARROWS away from the neutral
    /// plane, so the drafted wall moves inward at the top and not at all at
    /// the bottom.
    func testPositiveDraftNarrowsAwayFromTheNeutralPlane() throws {
        let mesh = box(100, 60, 20)
        let side = try face(of: mesh, facing: SIMD3(1, 0, 0))
        let drafted = KernelOps.draftFace(
            mesh: mesh, face: side,
            neutralOrigin: .zero, neutralNormal: SIMD3(0, 0, 1), degrees: 5)
        let render = EuclidBridge.renderMesh(from: drafted)
        var topMaxX = -Double.infinity, bottomMaxX = -Double.infinity
        for p in render.positions {
            if abs(Double(p.z) - 20) < 1e-3 { topMaxX = max(topMaxX, Double(p.x)) }
            if abs(Double(p.z)) < 1e-3 { bottomMaxX = max(bottomMaxX, Double(p.x)) }
        }
        XCTAssertEqual(bottomMaxX, 100, accuracy: 1e-6, "the neutral plane stays put")
        XCTAssertEqual(topMaxX, 100 - 20 * tan(5 * .pi / 180), accuracy: 1e-3,
                       "the top of the wall leans in by h·tanθ")
    }

    /// A negative angle is the other direction: the body widens away from the
    /// neutral plane, and the volume grows by the same wedge.
    func testNegativeDraftWidens() throws {
        let w = 100.0, d = 60.0, h = 20.0
        let mesh = box(w, d, h)
        let side = try face(of: mesh, facing: SIMD3(1, 0, 0))
        let drafted = KernelOps.draftFace(
            mesh: mesh, face: side,
            neutralOrigin: .zero, neutralNormal: SIMD3(0, 0, 1), degrees: -5)
        let wedge = 0.5 * h * h * tan(5 * .pi / 180) * d
        XCTAssertEqual(volume(drafted), w * d * h + wedge, accuracy: 1.0)
    }

    /// A face PARALLEL to the neutral plane has no hinge — the two planes never
    /// meet — so it is returned untouched rather than rotated about nothing.
    func testAFaceParallelToTheNeutralPlaneIsRefused() throws {
        let mesh = box(100, 60, 20)
        let top = try face(of: mesh, facing: SIMD3(0, 0, 1))
        let drafted = KernelOps.draftFace(
            mesh: mesh, face: top,
            neutralOrigin: .zero, neutralNormal: SIMD3(0, 0, 1), degrees: 5)
        XCTAssertEqual(volume(drafted), volume(mesh), accuracy: 1e-9)
    }

    func testZeroDegreesIsANoOp() throws {
        let mesh = box(100, 60, 20)
        let side = try face(of: mesh, facing: SIMD3(1, 0, 0))
        let drafted = KernelOps.draftFace(
            mesh: mesh, face: side,
            neutralOrigin: .zero, neutralNormal: SIMD3(0, 0, 1), degrees: 0)
        XCTAssertEqual(volume(drafted), volume(mesh), accuracy: 1e-9)
    }

    /// Four walls drafted off the same neutral plane give the frustum the
    /// sheets' "ALL DRAFT" callouts describe.
    func testAllFourWallsDraftedGiveAFrustum() throws {
        let w = 100.0, d = 60.0, h = 20.0, degrees = 5.0
        var mesh = box(w, d, h)
        for normal in [SIMD3(1.0, 0, 0), SIMD3(-1.0, 0, 0), SIMD3(0, 1.0, 0), SIMD3(0, -1.0, 0)] {
            let wall = try face(of: mesh, facing: normal)
            mesh = KernelOps.draftFace(mesh: mesh, face: wall,
                                       neutralOrigin: .zero, neutralNormal: SIMD3(0, 0, 1),
                                       degrees: degrees)
        }
        // Prismatoid: ∫ (w - 2z tanθ)(d - 2z tanθ) dz over 0…h.
        let t = tan(degrees * .pi / 180)
        let expected = w * d * h - (w + d) * t * h * h + (4.0 / 3.0) * t * t * h * h * h
        XCTAssertEqual(volume(mesh), expected, accuracy: 5.0)
    }
}
