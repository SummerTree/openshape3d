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
