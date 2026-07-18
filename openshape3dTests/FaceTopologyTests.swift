//
//  FaceTopologyTests.swift
//  openshape3dTests
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FaceTopologyTests: XCTestCase {

    private func seedTriangle(in mesh: RenderMesh, normal target: SIMD3<Float>) -> Int? {
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            if simd_dot(n, target) > 0.999 {
                return t
            }
        }
        return nil
    }

    func testBoxTopFace() {
        let box = Euclid.Mesh.primitive(.box(width: 4, depth: 4, height: 4))
        let render = EuclidBridge.renderMesh(from: box)
        guard let seed = seedTriangle(in: render, normal: SIMD3(0, 1, 0)) else {
            return XCTFail("No top triangle found")
        }
        guard let face = FaceTopology.planarFace(in: render, seedTriangle: seed) else {
            return XCTFail("Top face should be planar")
        }
        XCTAssertEqual(face.triangles.count, 2, "Box top is two triangles")
        XCTAssertEqual(face.outline.count, 4, "Outline is the four corners")
        XCTAssertTrue(face.holes.isEmpty)
        XCTAssertEqual(face.normal.y, 1, accuracy: 1e-4)
        // Outline spans the 4×4 top.
        let xs = face.outline.map(\.x)
        XCTAssertEqual((xs.max()! - xs.min()!), 4, accuracy: 1e-3)
        XCTAssertGreaterThan(Profile.signedArea(face.outline), 0, "Outline is CCW")
    }

    func testPocketedTopFaceHasHole() {
        let slab = Euclid.Mesh.primitive(.box(width: 8, depth: 8, height: 2))
        let punch = Euclid.Mesh.cylinder(radius: 1.5, height: 4, slices: 32)
            .translated(by: Vector(0, 2, 0)) // pierces the top face
        let cut = slab.subtracting(punch).makeWatertight()
        let render = EuclidBridge.renderMesh(from: cut)

        guard let seed = seedTriangle(in: render, normal: SIMD3(0, 1, 0)) else {
            return XCTFail("No top triangle found")
        }
        guard let face = FaceTopology.planarFace(in: render, seedTriangle: seed) else {
            return XCTFail("Top face should be planar")
        }
        XCTAssertEqual(face.holes.count, 1, "The punched pocket leaves one hole loop")
        XCTAssertEqual(face.outline.count, 4)
    }
}
