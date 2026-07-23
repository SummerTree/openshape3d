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
