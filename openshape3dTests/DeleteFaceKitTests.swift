//
//  DeleteFaceKitTests.swift
//  openshape3dTests
//
//  Delete Face (spec §4.16) at the pick level. `DeleteFaceEvalTests` already
//  covers the parametric replay; what is untested until here is the step that
//  turns a TAP into something OCCT can act on — the sample point.
//
//  That point is the whole ballgame. It has to lie ON the picked face: a
//  centroid-of-triangles lands on a cylinder's axis, inside the solid, and
//  OCCT then removes nothing or removes the wrong face. So the tests below
//  do not check the point's coordinates in isolation — they feed it to the
//  real defeaturing call and assert the hole is gone.
//

import XCTest
import simd
@testable import openshape3d

final class DeleteFaceKitTests: XCTestCase {

    /// A 20 mm box with a Ø6 through-hole up the middle: 6 planar faces plus
    /// ONE cylindrical wall, which is the face these tests delete.
    private func boxWithHole() throws -> BRepHandle {
        let box = try XCTUnwrap(
            OCCTKernel.primitiveShape(.box(width: 20, depth: 20, height: 20),
                                      placement: .identity),
            "box")
        // The drill is taller than the box and centred on it, so it punches
        // clean through and leaves exactly one cylindrical face.
        var placement = Transform3D.identity
        placement.translation = SIMD3<Double>(0, -5, 0)
        let drill = try XCTUnwrap(
            OCCTKernel.primitiveShape(.cylinder(radius: 3, height: 30),
                                      placement: placement),
            "drill")
        let drilled = try XCTUnwrap(OCCTKernel.boolean(box, drill, op: 1), "subtract")
        let counts = OCCTKernel.faceTypeCounts(drilled)
        XCTAssertEqual(counts.cylindrical, 1, "the hole contributes one cylindrical wall")
        return drilled
    }

    private func renderMesh(_ handle: BRepHandle) -> RenderMesh {
        let m = OCCTKernel.renderMesh(from: handle)
        return RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices)
    }

    /// The triangle a user would hit by tapping the inside of the hole: pick
    /// one whose centroid sits at the drill radius from the axis.
    private func triangleOnHoleWall(_ mesh: RenderMesh) -> Int? {
        for t in 0..<mesh.triangleCount {
            var c = SIMD3<Double>.zero
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[t * 3 + k])]
                c += SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
            }
            c /= 3
            let radial = hypot(c.x, c.z)
            if abs(radial - 3) < 0.35 { return t }
        }
        return nil
    }

    // MARK: - The point has to land on the face

    /// The end-to-end claim: tap the hole wall, and the hole goes away while
    /// the box stays a box. If the sample point were the face's triangle
    /// centroid (on the axis), this is the test that would fail.
    func testDeletingTheHoleWallHealsTheBoxShut() throws {
        let drilled = try boxWithHole()
        let mesh = renderMesh(drilled)
        let seed = try XCTUnwrap(triangleOnHoleWall(mesh), "a triangle on the hole wall")
        let target = try XCTUnwrap(DeleteFaceKit.target(in: mesh, seedTriangle: seed))

        let healed = try XCTUnwrap(
            OCCTKernel.removingFaces(drilled, at: [target.samplePoint],
                                     tolerance: DeleteFaceKit.tolerance(for: mesh)),
            "the neighbouring faces must close over the deleted hole")

        let counts = OCCTKernel.faceTypeCounts(healed)
        XCTAssertEqual(counts.cylindrical, 0, "the hole's wall is gone")
        XCTAssertEqual(counts.planar, 6, "…leaving a plain six-faced box")
    }

    /// A tap on the hole wall must resolve to the CYLINDER, not to the
    /// coplanar sliver `planarFace` finds there — no two facets of a curved
    /// surface are coplanar, so that sliver is one tessellation triangle and
    /// deleting it is meaningless.
    func testATapOnACurvedWallPicksTheWholeCylinder() throws {
        let mesh = renderMesh(try boxWithHole())
        let seed = try XCTUnwrap(triangleOnHoleWall(mesh))
        let target = try XCTUnwrap(DeleteFaceKit.target(in: mesh, seedTriangle: seed))

        guard case .cylindrical = target.signature.kind else {
            return XCTFail("a hole wall must pick as cylindrical, got \(target.signature.kind)")
        }
        XCTAssertGreaterThan(target.triangles.count, 8,
                             "the whole wall, not the one facet under the finger")
    }

    /// A tap on the top face picks a planar face, and its sample point lies
    /// on that plane.
    func testATapOnAFlatFacePicksThePlaneAndSamplesOnIt() throws {
        let mesh = renderMesh(try boxWithHole())
        var topTriangle: Int?
        for t in 0..<mesh.triangleCount {
            let n = mesh.normals[Int(mesh.indices[t * 3])]
            if n.y > 0.99 { topTriangle = t; break }
        }
        let seed = try XCTUnwrap(topTriangle, "a triangle on the top face")
        let target = try XCTUnwrap(DeleteFaceKit.target(in: mesh, seedTriangle: seed))

        XCTAssertEqual(target.signature.kind, .planar)
        XCTAssertEqual(target.samplePoint.y, 20, accuracy: 1e-6,
                       "the sample point sits ON the top plane")
    }

    // MARK: - Cylinder sampling, directly

    /// The sample point for a cylindrical face is at the radius, at mid-height
    /// — never on the axis.
    func testCylinderSampleSitsOnTheSurfaceAtMidHeight() throws {
        let cyl = FaceTopology.CylindricalFace(
            triangles: Array(0..<24),
            axisPoint: SIMD3<Double>(0, 0, 0),
            axisDir: SIMD3<Double>(0, 1, 0),
            radius: 4,
            minT: 0, maxT: 10,
            segments: 24,
            matchesWholeBody: false)
        let target = try XCTUnwrap(DeleteFaceKit.target(cylindrical: cyl))

        XCTAssertEqual(target.samplePoint.y, 5, accuracy: 1e-9, "mid-height")
        let radial = hypot(target.samplePoint.x, target.samplePoint.z)
        XCTAssertEqual(radial, 4, accuracy: 1e-9, "on the surface, not the axis")
    }

    /// A degenerate pick yields nothing rather than a point OCCT would chase.
    func testDegenerateFacesAreRefused() {
        XCTAssertNil(DeleteFaceKit.target(cylindrical: FaceTopology.CylindricalFace(
            triangles: [], axisPoint: .zero, axisDir: SIMD3(0, 1, 0),
            radius: 4, minT: 0, maxT: 10, segments: 24, matchesWholeBody: false)))
        XCTAssertNil(DeleteFaceKit.target(cylindrical: FaceTopology.CylindricalFace(
            triangles: [0], axisPoint: .zero, axisDir: SIMD3(0, 1, 0),
            radius: 0, minT: 0, maxT: 10, segments: 24, matchesWholeBody: false)))
    }

    // MARK: - Toggling

    /// Two picks of the same face compare equal, which is what makes a second
    /// tap un-pick it.
    func testSameFaceComparesEqualRegardlessOfTriangleOrder() throws {
        let mesh = renderMesh(try boxWithHole())
        let seed = try XCTUnwrap(triangleOnHoleWall(mesh))
        let a = try XCTUnwrap(DeleteFaceKit.target(in: mesh, seedTriangle: seed))
        var b = a
        b.triangles.reverse()
        XCTAssertEqual(a, b, "pick order must not make it a different face")
    }

    /// Tolerance scales with the body, so the same 2% rule the parametric
    /// replay uses covers the sagitta on a large part as well as a small one.
    func testToleranceScalesWithTheBody() {
        let small = RenderMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2])
        let large = RenderMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(100, 0, 0), SIMD3(0, 100, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2])
        XCTAssertLessThan(DeleteFaceKit.tolerance(for: small),
                          DeleteFaceKit.tolerance(for: large))
        XCTAssertGreaterThan(DeleteFaceKit.tolerance(for: small), 0)
    }
}
