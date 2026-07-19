//
//  CylinderFaceTests.swift
//  openshape3dTests
//
//  Curved-face recognition: a cylinder's side is one cylindrical surface with a
//  fitted axis/radius (not 48 separate facets), and a box side is NOT a
//  cylinder. Growing the diameter rebuilds a clean larger cylinder.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class CylinderFaceTests: XCTestCase {

    private func sideSeedTriangle(_ mesh: RenderMesh) -> Int {
        // A triangle whose normal is horizontal (radial) → on the wall.
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            if abs(n.y) < 0.2 { return t }
        }
        return 0
    }

    func testCylinderSideRecognized() {
        let cyl = Euclid.Mesh.primitive(.cylinder(radius: 3, height: 8))
        let render = EuclidBridge.renderMesh(from: cyl)
        let seed = sideSeedTriangle(render)

        guard let face = FaceTopology.cylindricalFace(in: render, seedTriangle: seed) else {
            return XCTFail("Cylinder side should be recognized as a cylindrical face")
        }
        XCTAssertEqual(face.radius, 3, accuracy: 0.05)
        XCTAssertEqual(face.height, 8, accuracy: 0.05)
        XCTAssertEqual(abs(face.axisDir.y), 1, accuracy: 1e-3, "Axis is vertical")
        XCTAssertGreaterThan(face.triangles.count, 40, "Whole wall, not one facet")
        XCTAssertTrue(face.matchesWholeBody, "A plain cylinder is safe to grow")
    }

    func testBoxSideNotACylinder() {
        let box = Euclid.Mesh.primitive(.box(width: 4, depth: 4, height: 6))
        let render = EuclidBridge.renderMesh(from: box)
        // Any side triangle.
        let seed = sideSeedTriangle(render)
        XCTAssertNil(FaceTopology.cylindricalFace(in: render, seedTriangle: seed),
                     "A flat box face is not a cylinder")
    }

    func testGrowDiameterRebuildsLargerCylinder() {
        let cyl = Euclid.Mesh.primitive(.cylinder(radius: 3, height: 8))
        let render = EuclidBridge.renderMesh(from: cyl)
        let face = FaceTopology.cylindricalFace(in: render, seedTriangle: sideSeedTriangle(render))!

        let grown = KernelOps.cylinderAlongAxis(
            baseCenter: face.baseCenter, axisDir: face.axisDir,
            radius: face.radius + 2, height: face.height, slices: 48
        )
        XCTAssertTrue(grown.isWatertight)
        let aabb = EuclidBridge.renderMesh(from: grown).localAABB
        XCTAssertEqual(Double(aabb.max.x - aabb.min.x), 10, accuracy: 0.1, "Diameter 3+2 → 5, ⌀10")
        XCTAssertEqual(Double(aabb.max.y - aabb.min.y), 8, accuracy: 0.1, "Height unchanged")
        // Volume ≈ π r² h = π·25·8.
        let vol = MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: grown), scale: 1)
        XCTAssertEqual(vol, Double.pi * 25 * 8, accuracy: Double.pi * 25 * 8 * 0.03)
    }

    func testTubeNotWholeBody() {
        // A tube (cylinder with a coaxial bore) is compound — growing the outer
        // wall must not rebuild it as a solid cylinder and fill the bore.
        let outer = Euclid.Mesh.primitive(.cylinder(radius: 3, height: 8))
        let bore = Euclid.Mesh.primitive(.cylinder(radius: 1.5, height: 10))
        let tube = outer.subtracting(bore).makeWatertight()
        let render = EuclidBridge.renderMesh(from: tube)
        // Seed on the OUTER wall (radius ~3).
        var seed = 0
        for t in 0..<render.triangleCount {
            let a = render.positions[Int(render.indices[t * 3])]
            let n = simd_normalize(simd_cross(
                render.positions[Int(render.indices[t * 3 + 1])] - a,
                render.positions[Int(render.indices[t * 3 + 2])] - a))
            if abs(n.y) < 0.2, simd_length(SIMD2(a.x, a.z)) > 2.5 { seed = t; break }
        }
        let face = FaceTopology.cylindricalFace(in: render, seedTriangle: seed)
        if let face { XCTAssertFalse(face.matchesWholeBody, "A tube is not a plain cylinder") }
    }
}
