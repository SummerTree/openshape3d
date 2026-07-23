//
//  OCCTKernelTests.swift
//  openshape3dTests — OCCT B-rep port, Milestone 1
//
//  In-suite promotion of the Milestone-0 spike: proves OCCT is linked into the
//  app and reachable from Swift, and that an extruded circle is ONE analytic
//  cylindrical face (not the 48-gon prism the Euclid mesh path produces).
//

import XCTest
@testable import openshape3d

final class OCCTKernelTests: XCTestCase {

    func testOCCTLinksAndReportsVersion() {
        XCTAssertFalse(OCCTKernel.version.isEmpty, "OCCT must link and report a version")
    }

    func testBoxMeshesWithExactVolume() {
        let box = OCCTKernel.meshBox(size: 10)
        XCTAssertGreaterThan(box.triangles, 0, "box must tessellate")
        XCTAssertEqual(box.volume, 1000, accuracy: 1e-6, "box volume == 10³")
    }

    func testExtrudedCircleIsOneAnalyticCylinder() {
        let c = OCCTKernel.extrudedCircleFaceCounts(radius: 5, height: 20)
        XCTAssertEqual(c.cylindrical, 1, "extruded circle → ONE cylindrical wall, not 48 facets")
        XCTAssertEqual(c.planar, 2, "two planar caps")
        XCTAssertEqual(c.other, 0, "no other surface types")
    }

    /// G1 acceptance: filleting a cylinder's rim must keep the result ANALYTIC —
    /// the wall stays one cylindrical face and the blend becomes a real torus —
    /// instead of collapsing to a faceted mesh blend.
    func testFilletingACylinderRimStaysAnalytic() {
        let radius = 5.0, height = 20.0
        guard let cyl = OCCTKernel.primitiveShape(.cylinder(radius: radius, height: height),
                                                  placement: .identity) else {
            return XCTFail("could not build the cylinder")
        }
        // Pick ONE point on the top rim. The rim is a single analytic circle, so
        // one point must select the whole edge (tangent-chain propagation).
        let rimPoint = SIMD3<Double>(radius, height, 0)
        guard let filleted = OCCTKernel.fillet(cyl, at: [rimPoint], radius: 1.0,
                                               tolerance: 0.5) else {
            return XCTFail("BRepFilletAPI could not round the rim")
        }

        let before = OCCTKernel.faceTypeCounts(cyl)
        let after = OCCTKernel.faceTypeCounts(filleted)
        XCTAssertEqual(before.cylindrical, 1, "a cylinder starts with one curved wall")
        XCTAssertEqual(after.cylindrical, 1, "the wall must SURVIVE as one analytic face")
        XCTAssertGreaterThan(after.other, before.other,
                             "the blend must add a real curved (torus) face")

        // And it must still tessellate round, not faceted.
        let mesh = OCCTKernel.renderMesh(from: filleted)
        XCTAssertGreaterThan(mesh.positions.count, 150,
                             "filleted cylinder still tessellates finely")
    }

    /// G1 (chamfer half) — bevelling a box edge must produce a NEW planar face
    /// and keep the solid valid.
    func testChamferingABoxEdgeAddsAPlanarFace() {
        guard let box = OCCTKernel.primitiveShape(.box(width: 10, depth: 10, height: 10),
                                                  placement: .identity) else {
            return XCTFail("could not build the box")
        }
        let before = OCCTKernel.faceTypeCounts(box)
        guard let chamfered = OCCTKernel.chamfer(box, at: [SIMD3(5, 5, 5)],
                                                 distance: 1.5, tolerance: 1.0) else {
            return XCTFail("BRepFilletAPI_MakeChamfer could not bevel the edge")
        }
        let after = OCCTKernel.faceTypeCounts(chamfered)
        XCTAssertGreaterThan(after.planar, before.planar,
                             "a chamfer replaces an edge with a new flat face")
        XCTAssertFalse(OCCTKernel.renderMesh(from: chamfered).positions.isEmpty)
    }

    /// G2 acceptance — shelling a CYLINDER must give a tube: two concentric
    /// cylindrical faces. This is the case the mesh inset approximation gets
    /// wrong, since it is only honest on prismatic bodies.
    func testShellingACylinderProducesATube() {
        guard let cyl = OCCTKernel.primitiveShape(.cylinder(radius: 5, height: 20),
                                                  placement: .identity) else {
            return XCTFail("could not build the cylinder")
        }
        XCTAssertEqual(OCCTKernel.faceTypeCounts(cyl).cylindrical, 1)

        // Open the top cap (y == height) so the result is a tube.
        guard let tube = OCCTKernel.shell(cyl, openingAt: [SIMD3(0, 20, 0)],
                                          thickness: 1.0, tolerance: 1.0) else {
            return XCTFail("BRepOffsetAPI_MakeThickSolid could not hollow the cylinder")
        }
        let faces = OCCTKernel.faceTypeCounts(tube)
        XCTAssertGreaterThanOrEqual(faces.cylindrical, 2,
                                    "a shelled cylinder has inner AND outer curved walls")
        XCTAssertFalse(OCCTKernel.renderMesh(from: tube).positions.isEmpty,
                       "shelled solid must tessellate")
    }

    /// Spec §4.16 Delete Face — previously ❌ [needs B-rep kernel], now possible
    /// via OCCT defeaturing: removing the blend face of a filleted box must heal
    /// back to a valid closed solid with fewer faces.
    func testDeleteFaceRemovesAFilletAndHealsTheSolid() {
        guard let box = OCCTKernel.primitiveShape(.box(width: 10, depth: 10, height: 10),
                                                  placement: .identity) else {
            return XCTFail("could not build the box")
        }
        // Round one vertical edge, then delete the resulting blend face.
        let edgePoint = SIMD3<Double>(5, 5, 5)
        guard let filleted = OCCTKernel.fillet(box, at: [edgePoint], radius: 2,
                                               tolerance: 1.0) else {
            return XCTFail("could not fillet the box edge")
        }
        let filletedFaces = OCCTKernel.faceTypeCounts(filleted)
        XCTAssertGreaterThan(filletedFaces.cylindrical, 0, "fillet adds a curved face")

        // The blend face sits on the rounded corner; sample a point on it.
        let blendPoint = SIMD3<Double>(5 - 2 + 2 * 0.7071, 5, 5 - 2 + 2 * 0.7071)
        guard let healed = OCCTKernel.removingFaces(filleted, at: [blendPoint],
                                                    tolerance: 1.5) else {
            return XCTFail("defeaturing could not remove the blend face")
        }
        let healedFaces = OCCTKernel.faceTypeCounts(healed)
        XCTAssertEqual(healedFaces.cylindrical, 0,
                       "the curved blend face must be gone after Delete Face")
        XCTAssertGreaterThan(healedFaces.planar, 0, "the solid still has its flat faces")
        XCTAssertFalse(OCCTKernel.renderMesh(from: healed).positions.isEmpty,
                       "healed solid must still tessellate")
    }

    /// A body carries its own transform, so it must be baked into the solid
    /// before two bodies are combined — otherwise a MOVED body would boolean at
    /// its pre-move position while the Euclid path used the correct one.
    func testBodyTransformIsBakedIntoTheBRep() {
        guard let base = OCCTKernel.primitiveShape(.cylinder(radius: 2, height: 4),
                                                   placement: .identity) else {
            return XCTFail("could not build the base solid")
        }
        guard let moved = OCCTKernel.transformed(
            base, by: Transform3D(translation: SIMD3(10, 0, 0))) else {
            return XCTFail("transform returned nil")
        }
        let before = OCCTKernel.renderMesh(from: base)
        let after = OCCTKernel.renderMesh(from: moved)
        guard let x0 = before.positions.map(\.x).min(),
              let x1 = after.positions.map(\.x).min() else {
            return XCTFail("empty tessellation")
        }
        XCTAssertEqual(Double(x1 - x0), 10, accuracy: 1e-3,
                       "the translation must be baked into the analytic solid")

        // Identity must be a cheap no-op that preserves the solid.
        let same = OCCTKernel.transformed(base, by: .identity)
        XCTAssertNotNil(same)
        XCTAssertEqual(OCCTKernel.renderMesh(from: same!).positions.count,
                       before.positions.count)
    }

    /// A body's analytic geometry must survive being written to and read back
    /// from the document, or a reloaded cylinder would silently go faceted.
    func testBRepSerializationRoundTripKeepsGeometryAnalytic() {
        guard let handle = OCCTKernel.primitiveShape(.cylinder(radius: 3, height: 5),
                                                     placement: .identity) else {
            return XCTFail("could not build the primitive B-rep")
        }
        guard let data = OCCTKernel.serialize(handle) else {
            return XCTFail("serialize returned nil")
        }
        XCTAssertGreaterThan(data.count, 0, "serialized B-rep must not be empty")

        guard let restored = OCCTKernel.deserialize(data) else {
            return XCTFail("deserialize returned nil")
        }
        let before = OCCTKernel.renderMesh(from: handle)
        let after = OCCTKernel.renderMesh(from: restored)
        XCTAssertEqual(after.positions.count, before.positions.count,
                       "restored solid must tessellate identically")
        XCTAssertEqual(after.indices.count, before.indices.count)
        XCTAssertGreaterThan(after.positions.count, 100, "restored cylinder is still finely tessellated")

        // Still analytically round after the round-trip.
        var directions = Set<Int>()
        for (p, n) in zip(after.positions, after.normals) where abs(n.y) < 0.05 {
            let radial = simd_normalize(SIMD2<Float>(p.x, p.z))
            let nrm = simd_normalize(SIMD2<Float>(n.x, n.z))
            XCTAssertGreaterThan(simd_dot(radial, nrm), 0.999, "side normal stays radial")
            directions.insert(Int(atan2(n.z, n.x) / (2 * .pi) * 360))
        }
        XCTAssertGreaterThan(directions.count, 40, "restored wall still spans many normal directions")
    }

    /// The render mesh that actually reaches the GPU must be finely tessellated
    /// with SMOOTH radial normals — that's what makes the cylinder look round
    /// (vs the Euclid 48-gon prism with hard per-facet normals).
    func testCylinderRenderMeshIsFinelyTessellatedAndSmooth() {
        let radius = 5.0
        let mesh = OCCTKernel.cylinderRenderMesh(
            center: .zero, radius: radius, zMin: 0, zMax: 20,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1))

        XCTAssertGreaterThan(mesh.positions.count, 150,
                             "cylinder should be finely tessellated, not ~48-gon")

        // Side-wall vertices have horizontal normals; they must point radially
        // outward (smooth surface normal, not a facet normal), and cover many
        // distinct directions around the axis (→ visually round).
        var sideDirections = Set<Int>()
        var checkedSide = 0
        for (p, n) in zip(mesh.positions, mesh.normals) where abs(n.z) < 0.05 {
            let radial = simd_normalize(SIMD2<Float>(p.x, p.y))
            let nrm = simd_normalize(SIMD2<Float>(n.x, n.y))
            XCTAssertGreaterThan(simd_dot(radial, nrm), 0.999,
                                 "side normal must be radial (smooth), not faceted")
            checkedSide += 1
            let bucket = Int(atan2(n.y, n.x) / (2 * .pi) * 360)  // 1° buckets
            sideDirections.insert(bucket)
        }
        XCTAssertGreaterThan(checkedSide, 100, "expected many side-wall vertices")
        XCTAssertGreaterThan(sideDirections.count, 40,
                             "normals must span many directions around the axis (round, not prism)")
    }
}
