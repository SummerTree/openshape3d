//
//  SectionCapKitTests.swift
//  openshape3dTests
//
//  Section View caps (spec §16.1): slicing a body's mesh fills the cut,
//  holes stay open, the body's placement is honored, and overlapping bodies
//  (but not touching ones) are flagged as interfering.
//

import XCTest
import simd
@testable import openshape3d

final class SectionCapKitTests: XCTestCase {

    /// An axis-aligned box as a render mesh: 24 split-normal vertices, 12
    /// triangles. `inward` flips the winding (an internal void).
    private func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, inward: Bool = false) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        func corner(_ i: Int) -> SIMD3<Float> {
            SIMD3((i & 1) == 0 ? lo.x : hi.x, (i & 2) == 0 ? lo.y : hi.y, (i & 4) == 0 ? lo.z : hi.z)
        }
        // Faces as corner quads, counter-clockwise from outside.
        let faces = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for face in faces {
            let base = UInt32(positions.count)
            positions += face.map(corner)
            let tris: [UInt32] = inward ? [0, 2, 1, 0, 3, 2] : [0, 1, 2, 0, 2, 3]
            indices += tris.map { base + $0 }
        }
        return (positions, indices)
    }

    private let midZ = SketchPlane(origin: SIMD3(0, 0, 5), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))

    private func cap(_ mesh: (positions: [SIMD3<Float>], indices: [UInt32]),
                     matrix: simd_double4x4 = matrix_identity_double4x4,
                     plane: SketchPlane? = nil) -> SectionCapKit.Cap {
        SectionCapKit.cap(positions: mesh.positions, indices: mesh.indices, matrix: matrix, plane: plane ?? midZ)
    }

    private func triangleArea(_ triangles: [SIMD3<Float>]) -> Double {
        stride(from: 0, to: triangles.count, by: 3).reduce(0) { sum, i in
            let a = SIMD3<Double>(triangles[i]), b = SIMD3<Double>(triangles[i + 1]), c = SIMD3<Double>(triangles[i + 2])
            return sum + simd_length(simd_cross(b - a, c - a)) / 2
        }
    }

    func testBoxCutIsFilledSquare() {
        let result = cap(box(.zero, SIMD3(10, 10, 10)))
        XCTAssertEqual(result.regions.count, 1)
        XCTAssertTrue(result.regions[0].holes.isEmpty)
        XCTAssertEqual(result.area, 100, accuracy: 1e-6)
        XCTAssertEqual(triangleArea(result.triangles), 100, accuracy: 1e-3)
        XCTAssertEqual(result.openChains, 0)
        // Everything lies on the plane.
        for p in result.triangles + result.outline { XCTAssertEqual(p.z, 5, accuracy: 1e-5) }
        XCTAssertEqual(result.outline.count / 2, 8, "four sides, each split across two triangles")
    }

    func testVoidStaysOpen() {
        let outer = box(.zero, SIMD3(10, 10, 10))
        let inner = box(SIMD3(2, 2, 2), SIMD3(8, 8, 8), inward: true)
        let base = UInt32(outer.positions.count)
        let hollow = (outer.positions + inner.positions, outer.indices + inner.indices.map { $0 + base })
        let result = cap(hollow)
        XCTAssertEqual(result.regions.count, 1)
        XCTAssertEqual(result.regions[0].holes.count, 1)
        XCTAssertEqual(result.area, 100 - 36, accuracy: 1e-6)
        XCTAssertEqual(triangleArea(result.triangles), 64, accuracy: 1e-3)
    }

    func testPlacementIsHonored() {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(100, 0, 0, 1)
        let result = cap(box(.zero, SIMD3(10, 10, 10)), matrix: m)
        let xs = result.triangles.map(\.x)
        XCTAssertEqual(xs.min()!, 100, accuracy: 1e-4)
        XCTAssertEqual(xs.max()!, 110, accuracy: 1e-4)
    }

    func testPlaneThatMissesOrGrazesCutsNothing() {
        let away = SketchPlane(origin: SIMD3(0, 0, 50), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        XCTAssertTrue(cap(box(.zero, SIMD3(10, 10, 10)), plane: away).isEmpty)
        // On the bottom face exactly: nothing to fill, and no crash.
        let bottom = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        XCTAssertTrue(cap(box(.zero, SIMD3(10, 10, 10)), plane: bottom).triangles.isEmpty)
    }

    func testTiltedPlaneCutsAWiderSlice() {
        let tilted = SketchPlane(origin: SIMD3(5, 5, 5),
                                 xAxis: SIMD3(1, 0, 0),
                                 yAxis: simd_normalize(SIMD3(0, 1, 1)))
        let result = cap(box(.zero, SIMD3(10, 10, 10)), plane: tilted)
        // A diagonal cut through the cube: 10 × 10√2.
        XCTAssertEqual(result.area, 100 * 2.0.squareRoot(), accuracy: 1e-4)
    }

    func testOverlappingBodiesInterfereButTouchingOnesDoNot() {
        let a = cap(box(.zero, SIMD3(10, 10, 10))).regions
        let overlapping = cap(box(SIMD3(6, 6, 0), SIMD3(16, 16, 10))).regions
        let touching = cap(box(SIMD3(-10, 0, 0), SIMD3(0, 10, 10))).regions
        let inside = cap(box(SIMD3(3, 3, 3), SIMD3(6, 6, 6))).regions
        let apart = cap(box(SIMD3(30, 0, 0), SIMD3(40, 10, 10))).regions

        XCTAssertTrue(SectionCapKit.overlaps(a, overlapping))
        XCTAssertFalse(SectionCapKit.overlaps(a, touching), "a shared face is not interference")
        XCTAssertTrue(SectionCapKit.overlaps(a, inside), "a part buried in another")
        XCTAssertTrue(SectionCapKit.overlaps(inside, a))
        XCTAssertFalse(SectionCapKit.overlaps(a, apart))
        XCTAssertTrue(SectionCapKit.overlaps(a, a), "a copy in place")

        XCTAssertEqual(SectionCapKit.interfering([a, touching, overlapping]), [0, 2])
        XCTAssertEqual(SectionCapKit.interfering([a, touching, apart]), [])
    }

    func testPartInsideAVoidDoesNotInterfere() {
        let outer = box(.zero, SIMD3(10, 10, 10))
        let inner = box(SIMD3(2, 2, 2), SIMD3(8, 8, 8), inward: true)
        let base = UInt32(outer.positions.count)
        let hollow = cap((outer.positions + inner.positions, outer.indices + inner.indices.map { $0 + base })).regions
        let core = cap(box(SIMD3(3, 3, 3), SIMD3(7, 7, 7))).regions
        XCTAssertFalse(SectionCapKit.overlaps(hollow, core), "the core sits in the cavity with clearance")
    }

    func testDefaultColorsAreDistinct() {
        let colors = (0..<8).map(SectionCapKit.defaultColor(index:))
        XCTAssertEqual(Set(colors.map { "\($0)" }).count, 8)
        XCTAssertEqual(SectionCapKit.defaultColor(index: 8), colors[0])
    }
}
