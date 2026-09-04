//
//  FaceMovePerfTests.swift
//  openshape3dTests
//
//  What a face drag costs PER FRAME. `EditorViewModel.updateMove` calls
//  `KernelOps.moveFace` on every gesture update, and moveFace walks every
//  polygon running a point-in-polygon test per vertex — so the cost scales
//  with tessellation density, which is exactly what a fillet adds.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FaceMovePerfTests: XCTestCase {

    private func mesh(_ handle: BRepHandle) -> Euclid.Mesh {
        let r = OCCTKernel.renderMesh(from: handle)
        return EuclidBridge.euclidMesh(from: RenderMesh(
            positions: r.positions, normals: r.normals, indices: r.indices))
    }

    private func topFace(of mesh: Euclid.Mesh) throws -> FaceTopology.PlanarFace {
        let render = EuclidBridge.renderMesh(from: mesh)
        var seed: Int?
        for t in 0..<render.triangleCount {
            let a = render.positions[Int(render.indices[t * 3])]
            let b = render.positions[Int(render.indices[t * 3 + 1])]
            let c = render.positions[Int(render.indices[t * 3 + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            if simd_dot(n, SIMD3<Float>(0, 1, 0)) > 0.999 { seed = t; break }
        }
        return try XCTUnwrap(FaceTopology.planarFace(
            in: render, seedTriangle: try XCTUnwrap(seed, "no +Y face")))
    }

    /// A preview frame the way a drag runs it now: indices resolved at
    /// touch-down, each frame translating those vertices of a flat array.
    private func msPreviewFrame(_ render: RenderMesh,
                                _ moved: [Int],
                                iterations: Int = 20) -> Double {
        var sink = 0
        let start = Date()
        for i in 0..<iterations {
            var positions = render.positions
            let d = SIMD3<Float>(0.01 * Float(i + 1), 0, 0)
            for j in moved { positions[j] += d }
            sink &+= positions.count
        }
        let ms = Date().timeIntervalSince(start) / Double(iterations) * 1000
        XCTAssertGreaterThan(sink, 0)
        return ms
    }

    /// A preview frame the OLD way: the full Euclid deform, which rebuilds
    /// every polygon, welds it watertight and copies it again to re-pivot.
    private func msEuclidFrame(_ mesh: Euclid.Mesh,
                               _ face: FaceTopology.PlanarFace,
                               iterations: Int = 5) -> Double {
        let start = Date()
        for i in 0..<iterations {
            let moved = KernelOps.moveFace(mesh: mesh, face: face,
                                           delta: SIMD3(0.01 * Double(i + 1), 0, 0))
            _ = moved.translated(by: Vector(-1, 0, 0))
        }
        return Date().timeIntervalSince(start) / Double(iterations) * 1000
    }

    /// THE regression this guards. A face drag on a blended body previewed
    /// itself by deforming through Euclid every frame — ~370 ms/frame on this
    /// shape, roughly 3 fps, which is what a face drag felt like on anything
    /// curved. The preview now translates render-buffer vertices instead.
    func testFaceDragPreviewFrameFitsTheBudget() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 8, height: 10), placement: .identity))
        // Both rims rounded — a dense blend band, the shape that was unusable.
        let filleted = try XCTUnwrap(try? OCCTKernel.filletResult(
            cyl, edgeIndices: [2, 3], radius: 1).get())
        let mesh = self.mesh(filleted)
        let face = try topFace(of: mesh)
        let render = EuclidBridge.renderMesh(from: mesh)
        let moved = KernelOps.faceVertexIndices(in: render.positions, face: face)
        XCTAssertFalse(moved.isEmpty, "the top face must claim some vertices")

        let euclidMs = msEuclidFrame(mesh, face)
        let previewMs = msPreviewFrame(render, moved)
        print(String(format: """
            FACE-DRAG PREVIEW FRAME (%d polygons, %d verts, %d moved)
              deform through Euclid   %.2f ms
              translate render verts  %.3f ms  (%.0fx faster)
              60 fps budget           16.67 ms
            """, mesh.polygons.count, render.positions.count, moved.count,
            euclidMs, previewMs, euclidMs / max(previewMs, 0.0001)))

        XCTAssertLessThan(previewMs, 16.67,
                          "a face-drag preview frame must fit the 60 fps budget")
    }

    /// The render-buffer classification must pick the same vertices as the
    /// Euclid one — a preview that moved a different set than the commit
    /// would snap on release.
    func testRenderAndEuclidClassificationAgree() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 8, height: 10), placement: .identity))
        let mesh = self.mesh(cyl)
        let face = try topFace(of: mesh)
        let render = EuclidBridge.renderMesh(from: mesh)
        let indices = Set(KernelOps.faceVertexIndices(in: render.positions, face: face))

        // Every render vertex the mask claims, and no others.
        let mask = KernelOps.faceVertexMask(mesh: mesh, face: face)
        var euclidOnFace = Set<SIMD3<Float>>()
        for (i, polygon) in mesh.polygons.enumerated() {
            for (j, vertex) in polygon.vertices.enumerated() where mask.moves(polygon: i, vertex: j) {
                euclidOnFace.insert(SIMD3(Float(vertex.position.x),
                                          Float(vertex.position.y),
                                          Float(vertex.position.z)))
            }
        }
        for (i, p) in render.positions.enumerated() {
            XCTAssertEqual(indices.contains(i), euclidOnFace.contains(p),
                           "vertex \(i) at \(p) classified differently")
        }
    }

    /// The mask is only an optimisation — it must deform identically.
    func testMaskedMoveMatchesTheClassifyingPath() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 8, height: 10), placement: .identity))
        let mesh = self.mesh(cyl)
        let face = try topFace(of: mesh)
        let mask = KernelOps.faceVertexMask(mesh: mesh, face: face)
        let delta = SIMD3<Double>(1.5, 0, -0.75)

        let classified = KernelOps.moveFace(mesh: mesh, face: face, delta: delta)
        let masked = KernelOps.moveFace(mesh: mesh, mask: mask, delta: delta)
        XCTAssertEqual(masked.polygons.count, classified.polygons.count)
        XCTAssertEqual(MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: masked), scale: 1),
                       MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: classified), scale: 1),
                       accuracy: 1e-6)
    }

    /// A mask built for ANOTHER mesh must not deform the wrong vertices — it
    /// rebuilds itself instead.
    func testStaleMaskRebuildsRatherThanMisapplying() throws {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 16, depth: 16, height: 10), placement: .identity))
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 8, height: 10), placement: .identity))
        let boxMesh = mesh(box), cylMesh = mesh(cyl)
        let cylFace = try topFace(of: cylMesh)
        let wrongMask = KernelOps.faceVertexMask(mesh: cylMesh, face: cylFace)
        let delta = SIMD3<Double>(0, 2, 0)

        let viaStaleMask = KernelOps.moveFace(mesh: boxMesh, mask: wrongMask, delta: delta)
        let direct = KernelOps.moveFace(mesh: boxMesh, face: cylFace, delta: delta)
        XCTAssertEqual(
            MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: viaStaleMask), scale: 1),
            MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: direct), scale: 1),
            accuracy: 1e-6,
            "a mask that does not describe the mesh must be rebuilt, not misapplied")
    }
}
