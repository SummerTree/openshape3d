//
//  FaceEnumerateTests.swift
//  openshape3dTests
//
//  Whole-mesh face enumeration: FaceTopology.enumerateFaces partitions every
//  triangle of a body into exactly one face — planar patches and cylindrical
//  side surfaces — with no double-claim and no orphan.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FaceEnumerateTests: XCTestCase {

    /// Every triangle index in the mesh appears in exactly one face across both
    /// lists (no double-claim, no orphan).
    private func assertPartition(
        _ result: (planar: [PlanarFace], cylindrical: [CylindricalFace]),
        covers mesh: RenderMesh,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var all: [Int] = []
        for f in result.planar { all.append(contentsOf: f.triangles) }
        for f in result.cylindrical { all.append(contentsOf: f.triangles) }
        let unique = Set(all)
        XCTAssertEqual(all.count, unique.count,
                       "A triangle was claimed by more than one face", file: file, line: line)
        XCTAssertEqual(unique, Set(0..<mesh.triangleCount),
                       "Union of face triangles must equal all triangles (no orphan)",
                       file: file, line: line)
    }

    private func planarArea(_ face: PlanarFace) -> Double {
        abs(Profile.signedArea(face.outline))
    }

    // MARK: - Box → 6 planar faces

    func testBoxEnumeratesSixPlanarFaces() {
        let box = Euclid.Mesh.primitive(.box(width: 4, depth: 4, height: 4))
        let render = EuclidBridge.renderMesh(from: box)

        let faces = FaceTopology.enumerateFaces(in: render)

        XCTAssertEqual(faces.planar.count, 6, "A box has six planar faces")
        XCTAssertTrue(faces.cylindrical.isEmpty, "A box has no cylindrical faces")

        // Six distinct outward normals (±x, ±y, ±z).
        let keys = Set(faces.planar.map { f -> SIMD3<Int> in
            SIMD3(Int((f.normal.x * 100).rounded()),
                  Int((f.normal.y * 100).rounded()),
                  Int((f.normal.z * 100).rounded()))
        })
        XCTAssertEqual(keys.count, 6, "Six distinct face normals")

        // Each face is a 4×4 square → area 16, all ~equal.
        for face in faces.planar {
            XCTAssertEqual(planarArea(face), 16, accuracy: 0.05,
                           "Each box face spans 4×4 = 16")
        }

        assertPartition(faces, covers: render)
    }

    // MARK: - Cylinder → 1 cylindrical side + 2 planar caps

    func testCylinderEnumeratesSideAndTwoCaps() {
        // 48 slices (the primitive's tessellation).
        let cyl = Euclid.Mesh.primitive(.cylinder(radius: 3, height: 8))
        let render = EuclidBridge.renderMesh(from: cyl)

        let faces = FaceTopology.enumerateFaces(in: render)

        XCTAssertEqual(faces.cylindrical.count, 1, "One cylindrical side surface")
        XCTAssertEqual(faces.planar.count, 2, "Two planar caps (top + bottom)")

        let side = faces.cylindrical[0]
        XCTAssertEqual(side.radius, 3, accuracy: 0.05)
        XCTAssertEqual(side.height, 8, accuracy: 0.05)
        XCTAssertEqual(abs(side.axisDir.y), 1, accuracy: 1e-3, "Axis is vertical")

        // Both caps are horizontal discs of radius 3 → area ≈ π·9.
        for cap in faces.planar {
            XCTAssertEqual(abs(cap.normal.y), 1, accuracy: 1e-3, "Cap normal is vertical")
            XCTAssertEqual(planarArea(cap), Double.pi * 9, accuracy: Double.pi * 9 * 0.02,
                           "Cap disc area ≈ π r²")
        }

        assertPartition(faces, covers: render)
    }

    // MARK: - Box with a cylindrical through-hole

    func testBoxWithCylindricalHoleEnumeratesInnerWall() {
        let slab = Euclid.Mesh.primitive(.box(width: 8, depth: 8, height: 2)) // y ∈ [0, 2]
        // Centered cylinder taller than the slab → a clean through-hole.
        let punch = Euclid.Mesh.cylinder(radius: 1.5, height: 6, slices: 48)
            .translated(by: Vector(0, 1, 0)) // y ∈ [-2, 4], spans the slab fully
        let cut = slab.subtracting(punch).makeWatertight()
        let render = EuclidBridge.renderMesh(from: cut)

        let faces = FaceTopology.enumerateFaces(in: render)

        // The inner bore is a single cylindrical wall.
        XCTAssertGreaterThanOrEqual(faces.cylindrical.count, 1,
                                    "The bore is a cylindrical wall")
        let inner = faces.cylindrical.first { abs($0.radius - 1.5) < 0.1 }
        XCTAssertNotNil(inner, "Inner wall radius ≈ 1.5")

        // The six outer box faces survive as planar patches (top & bottom now
        // carry a circular hole); "any exposed faces" are also planar.
        XCTAssertGreaterThanOrEqual(faces.planar.count, 6,
                                    "At least the six outer box faces are planar")

        // Top and bottom each expose a face with exactly one hole (the bore).
        let holed = faces.planar.filter { !$0.holes.isEmpty && abs($0.normal.y) > 0.99 }
        XCTAssertEqual(holed.count, 2, "Top and bottom faces each have one bore hole")
        for f in holed { XCTAssertEqual(f.holes.count, 1) }

        assertPartition(faces, covers: render)
    }

    // MARK: - Empty mesh

    func testEmptyMeshEnumeratesNothing() {
        let empty = RenderMesh(positions: [], normals: [], indices: [])
        let faces = FaceTopology.enumerateFaces(in: empty)
        XCTAssertTrue(faces.planar.isEmpty)
        XCTAssertTrue(faces.cylindrical.isEmpty)
    }
}
