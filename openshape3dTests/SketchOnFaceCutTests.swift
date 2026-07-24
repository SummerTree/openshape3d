//
//  SketchOnFaceCutTests.swift
//  openshape3dTests
//
//  The Shapr3D "draw on a face, extrude through, get a pass-through" flow:
//  sketch a profile on a solid's face, build the SAME overlap tool the live
//  extrude commit uses (`KernelOps.overlapExtrudeTool`), and subtract it. The
//  result must be a genuine through-hole — not a shallow pocket — so the checks
//  are volumetric and topological rather than visual.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class SketchOnFaceCutTests: XCTestCase {

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)
    }

    /// 10 × 10 × 10 box, y ∈ [0, 10] (ground-plane extrude, +Y up).
    private func makeBox() -> Euclid.Mesh {
        Euclid.Mesh.primitive(.box(width: 10, depth: 10, height: 10))
    }

    /// The box's TOP face as a sketch plane, normal pointing OUT (+Y) — the
    /// orientation a real face pick produces. (xAxis × yAxis must be +Y, so
    /// yAxis is -Z; the mirror pair points the normal into the solid and the
    /// tool would extrude away from the box, cutting nothing.)
    private func topFacePlane(of mesh: Euclid.Mesh) -> SketchPlane {
        let top = EuclidBridge.renderMesh(from: mesh).localAABB.max.y
        let plane = SketchPlane(origin: SIMD3(0, Double(top), 0),
                                xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1))
        XCTAssertEqual(plane.normal.y, 1, accuracy: 1e-9, "plane normal points out of the box")
        return plane
    }

    private func square(_ half: Double) -> Profile {
        Profile(loop: [SIMD2(-half, -half), SIMD2(half, -half),
                       SIMD2(half, half), SIMD2(-half, half)],
                kind: .polygonal, sourceEntityIDs: [])
    }

    /// Drawing a 4×4 square on the top face and extruding it DOWN past the far
    /// side must punch a hole clean through: volume drops by exactly the prism
    /// that fits inside the box (4 × 4 × 10 = 160), and the solid stays closed.
    func testSketchOnFaceExtrudedThroughMakesAPassThroughHole() throws {
        let box = makeBox()
        let plane = topFacePlane(of: box)
        let before = volume(box)

        // Negative distance = into the solid; deeper than the box so it exits.
        let tool = KernelOps.overlapExtrudeTool(
            profile: square(2), holes: [], extraProfiles: [],
            in: plane, distance: -12, symmetric: false)
        let result = box.subtracting(tool).makeWatertight()

        XCTAssertFalse(result.polygons.isEmpty, "the cut produced geometry")
        XCTAssertTrue(result.isWatertight, "a box with a through-hole is still closed")
        XCTAssertEqual(volume(result), before - 4 * 4 * 10, accuracy: before * 0.01,
                       "a THROUGH cut removes the full 4×4×10 prism, not a pocket")

        // Topological proof it goes THROUGH rather than stopping inside: the
        // hole must break BOTH the top and the bottom face. Sample the solid
        // just inside each: the centre of the hole is empty at both ends.
        let aabb = EuclidBridge.renderMesh(from: result).localAABB
        XCTAssertEqual(Double(aabb.max.y - aabb.min.y), 10, accuracy: 0.05,
                       "the box keeps its full height — the cut didn't shave the top")
        XCTAssertFalse(pointIsInside(result, SIMD3(0, Double(aabb.min.y) + 0.2, 0)),
                       "the hole is open at the BOTTOM (a pocket would be solid here)")
        XCTAssertFalse(pointIsInside(result, SIMD3(0, Double(aabb.max.y) - 0.2, 0)),
                       "the hole is open at the TOP")
        XCTAssertTrue(pointIsInside(result, SIMD3(4, Double(aabb.min.y) + 0.2, 4)),
                       "material away from the hole is untouched")
    }

    /// A shallower cut must NOT break through — the counter-case, so the test
    /// above can't pass just because the inside test is broken.
    func testShallowCutMakesAPocketNotAHole() throws {
        let box = makeBox()
        let plane = topFacePlane(of: box)

        let tool = KernelOps.overlapExtrudeTool(
            profile: square(2), holes: [], extraProfiles: [],
            in: plane, distance: -3, symmetric: false)
        let result = box.subtracting(tool).makeWatertight()
        let aabb = EuclidBridge.renderMesh(from: result).localAABB

        XCTAssertTrue(pointIsInside(result, SIMD3(0, Double(aabb.min.y) + 0.2, 0)),
                      "a 3mm cut into a 10mm box leaves material at the bottom")
        XCTAssertFalse(pointIsInside(result, SIMD3(0, Double(aabb.max.y) - 0.2, 0)),
                       "but it IS open at the top")
    }

    /// Ray-cast parity test: count crossings of a ray from the point outward.
    private func pointIsInside(_ mesh: Euclid.Mesh, _ p: SIMD3<Double>) -> Bool {
        let render = EuclidBridge.renderMesh(from: mesh)
        let origin = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        let dir = simd_normalize(SIMD3<Float>(0.3128, 0.5471, 0.7761)) // irrational-ish
        var crossings = 0
        for t in 0..<render.triangleCount {
            let a = render.positions[Int(render.indices[t * 3])]
            let b = render.positions[Int(render.indices[t * 3 + 1])]
            let c = render.positions[Int(render.indices[t * 3 + 2])]
            let e1 = b - a, e2 = c - a
            let h = simd_cross(dir, e2)
            let det = simd_dot(e1, h)
            guard abs(det) > 1e-9 else { continue }
            let f = 1 / det
            let s = origin - a
            let u = f * simd_dot(s, h)
            guard u >= 0, u <= 1 else { continue }
            let q = simd_cross(s, e1)
            let v = f * simd_dot(dir, q)
            guard v >= 0, u + v <= 1 else { continue }
            if f * simd_dot(e2, q) > 1e-6 { crossings += 1 }
        }
        return crossings % 2 == 1
    }
}
