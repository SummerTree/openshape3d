//
//  GeometryOracleTests.swift
//  openshape3dTests
//
//  Exact-value oracles for the kernel (docs/FREECAD_PLAYBOOK.md S5, review
//  R3-D): every case asserts an ANALYTICALLY DERIVED volume (and face-type
//  counts where they add signal), so a wrong-but-non-empty result can no
//  longer pass as success. Scenario selection follows the hard cases
//  FreeCAD's Part regression suites exercise (coplanar fuse/cut, thin walls,
//  tangent rims, defeature-heal); every expected number below is re-derived
//  from first principles in its comment — no values or code are taken from
//  FreeCAD (LGPL; see the playbook's licensing rules).
//
//  Pure values over OCCTKernel; no DocumentSession/ModelContainer.
//

import XCTest
import simd
@testable import openshape3d

final class GeometryOracleTests: XCTestCase {

    private func box(_ w: Double, _ d: Double, _ h: Double,
                     at t: SIMD3<Double> = .zero) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: w, depth: d, height: h),
            placement: t == .zero ? .identity : Transform3D(translation: t)))
    }
    private func cylinder(_ r: Double, _ h: Double,
                          at t: SIMD3<Double> = .zero) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: r, height: h),
            placement: t == .zero ? .identity : Transform3D(translation: t)))
    }
    private func tol(_ h: BRepHandle) -> Double { OCCTKernel.matchTolerance(for: h) }

    // MARK: - Creation ops

    /// Symmetric extrude of a 10×6 rectangle over z ∈ [−4, 4]:
    /// V = 10 · 6 · 8 = 480, six planar faces.
    func testSymmetricExtrudeVolume() throws {
        let solid = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 6), SIMD2(0, 6)],
            holes: [], zMin: -4, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
            normal: SIMD3(0, 0, 1)))
        XCTAssertEqual(OCCTKernel.volume(solid), 480, accuracy: 1e-9)
        let counts = OCCTKernel.faceTypeCounts(solid)
        XCTAssertEqual(counts.planar, 6)
        XCTAssertEqual(counts.other, 0)
    }

    /// Full revolve of the rectangle x ∈ [4, 6], y ∈ [0, 3] about the world
    /// Y axis — a washer: V = π (6² − 4²) · 3 = 60π ≈ 188.4955592.
    func testRevolveWasherVolume() throws {
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        let profile = Profile(
            loop: [SIMD2(4, 0), SIMD2(6, 0), SIMD2(6, 3), SIMD2(4, 3)],
            kind: .polygonal, sourceEntityIDs: [])
        let solid = try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: profile, holes: [], plane: plane,
            axisOrigin: .zero, axisDirection: SIMD3(0, 1, 0),
            angleRadians: 2 * .pi))
        XCTAssertEqual(OCCTKernel.volume(solid), 60 * .pi, accuracy: 1e-6)
    }

    // MARK: - Booleans on hard configurations

    /// Concentric cylinder cut (a tube): V = π (5² − 3²) · 10 = 160π
    /// ≈ 502.6548246. The bore wall must stay ONE analytic cylinder.
    func testConcentricCylinderCutMakesATube() throws {
        let outer = try cylinder(5, 10)
        let bore = try cylinder(3, 12, at: SIMD3(0, -1, 0))
        let tube = try OCCTKernel.booleanResult(outer, bore, op: 1).get().handle
        XCTAssertEqual(OCCTKernel.volume(tube), 160 * .pi, accuracy: 1e-6)
        let counts = OCCTKernel.faceTypeCounts(tube)
        XCTAssertEqual(counts.cylindrical, 2, "outer wall + bore, both analytic")
        XCTAssertEqual(counts.planar, 2, "two annular caps")
    }

    /// A pocket whose walls share the target's top surface exactly — the
    /// coplanar-cut case that punishes weak fuzzy handling:
    /// V = 10³ − 4·4·4 = 936.
    func testCoplanarTopPocketCut() throws {
        let block = try box(10, 10, 10)
        // 4×4 pocket, 4 deep, entered exactly through the top face y = 10.
        let tool = try box(4, 4, 4, at: SIMD3(0, 6, 0))
        let outcome = try OCCTKernel.booleanResult(block, tool, op: 1).get()
        XCTAssertEqual(outcome.solidCount, 1)
        XCTAssertEqual(OCCTKernel.volume(outcome.handle), 936, accuracy: 1e-9)
    }

    /// Thin-wall picture frame: 20×20×2 minus a through 18×18 core leaves
    /// 1 mm walls — V = (400 − 324) · 2 = 152. Near-coincident parallel
    /// faces at every wall exercise the auto-fuzzy path.
    func testThinWallFrameCut() throws {
        let slab = try box(20, 20, 2)
        let core = try box(18, 18, 4, at: SIMD3(0, -1, 0))
        let frame = try OCCTKernel.booleanResult(slab, core, op: 1).get().handle
        XCTAssertEqual(OCCTKernel.volume(frame), 152, accuracy: 1e-9)
    }

    /// Intersection of two 10-boxes offset 5 in x: V = 5 · 10 · 10 = 500.
    func testBoxIntersectionVolume() throws {
        let a = try box(10, 10, 10)
        let b = try box(10, 10, 10, at: SIMD3(5, 0, 0))
        let common = try OCCTKernel.booleanResult(a, b, op: 2).get().handle
        XCTAssertEqual(OCCTKernel.volume(common), 500, accuracy: 1e-9)
    }

    // MARK: - Dress-up ops

    /// Fillet r=2 along ONE vertical edge of a 10-box. Removed material per
    /// unit length is the corner square minus the quarter disk:
    /// a = r² − πr²/4 = 4(1 − π/4); over the 10 edge:
    /// V = 1000 − 40(1 − π/4) = 960 + 10π ≈ 991.4159265.
    func testFilletVolumeOnBoxEdge() throws {
        let b = try box(10, 10, 10)
        let edge = SIMD3<Double>(5, 5, 5)  // mid-height of the x=5,z=5 edge
        let filleted = try OCCTKernel.filletResult(
            b, at: [edge], radius: 2, tolerance: tol(b)).get()
        XCTAssertEqual(OCCTKernel.volume(filleted), 960 + 10 * .pi, accuracy: 1e-6)
    }

    /// Chamfer d=2 on the same edge removes a right-triangle prism:
    /// V = 1000 − (2·2/2)·10 = 980 exactly.
    func testChamferVolumeOnBoxEdge() throws {
        let b = try box(10, 10, 10)
        let edge = SIMD3<Double>(5, 5, 5)
        let chamfered = try OCCTKernel.chamferResult(
            b, at: [edge], distance: 2, tolerance: tol(b)).get()
        XCTAssertEqual(OCCTKernel.volume(chamfered), 980, accuracy: 1e-9)
    }

    /// Fillet r=1 on a cylinder's top rim (R=5, h=10) — one tap must round
    /// the WHOLE rim (tangent chain), and the removed ring's volume follows
    /// from Pappus: the (radial, z) cross-section is the r×r corner square
    /// minus the quarter disk centred at (R−r, h−r);
    ///   area   a  = r²(1 − π/4)                            = 0.2146018…
    ///   ρ̄·a       = r²(R − r/2) − (πr²·(R−r)/4 + r³/3)     = 1.0250740…
    ///   V_removed = 2π·(ρ̄·a)                               = 6.4407300…
    /// V = 250π − 6.4407300 ≈ 778.9574345.
    func testRimFilletVolumeViaPappus() throws {
        let cyl = try cylinder(5, 10)
        let rim = SIMD3<Double>(5, 10, 0)
        let filleted = try OCCTKernel.filletResult(
            cyl, at: [rim], radius: 1, tolerance: tol(cyl)).get()
        let expected = 250 * Double.pi - 2 * Double.pi * (4.5 - (Double.pi + 1.0 / 3))
        XCTAssertEqual(OCCTKernel.volume(filleted), expected, accuracy: 1e-4)
    }

    /// Delete-face heal: drilling a Ø4 bore removes 10π·4 of material;
    /// deleting the bore wall heals the box back to EXACTLY 1000.
    func testDefeatureHealRestoresExactVolume() throws {
        let block = try box(10, 10, 10)
        let drill = try cylinder(2, 12, at: SIMD3(0, -1, 0))
        let drilled = try OCCTKernel.booleanResult(block, drill, op: 1).get().handle
        XCTAssertEqual(OCCTKernel.volume(drilled), 1000 - 40 * .pi, accuracy: 1e-6)
        let healed = try OCCTKernel.removingFacesResult(
            drilled, at: [SIMD3(2, 5, 0)], tolerance: tol(drilled)).get()
        XCTAssertEqual(OCCTKernel.volume(healed), 1000, accuracy: 1e-6)
        XCTAssertEqual(OCCTKernel.faceTypeCounts(healed).cylindrical, 0)
    }

    /// Shell contract on a curved wall: hollowing a cylinder (R=5, h=10,
    /// t=1) open at the top leaves V = π(5²·10 − 4²·9) = 106π ≈ 333.0088.
    func testOpenTopCylinderShellVolume() throws {
        let cyl = try cylinder(5, 10)
        let cup = try OCCTKernel.shellResult(
            cyl, openingAt: [SIMD3(0, 10, 0)], thickness: 1,
            tolerance: tol(cyl)).get()
        XCTAssertEqual(OCCTKernel.volume(cup), 106 * .pi, accuracy: 1e-6)
    }
}
