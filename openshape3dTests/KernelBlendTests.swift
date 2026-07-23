//
//  KernelBlendTests.swift
//  openshape3dTests
//
//  Phase E tranche 1 proof: the pure mesh-kernel edge blends (chamfer/fillet)
//  and the edge enumeration that feeds them. Everything here operates on plain
//  Euclid meshes + RenderMesh — no DocumentSession — per repo convention.
//
//  A unit cube (side 2, volume 8) has 12 right-angle convex edges of length 2.
//  Chamfering one edge by setback d removes a triangular prism of cross-section
//  ½·d² over the edge length → ½·d²·2 = d². Filleting keeps the quarter-round,
//  so it removes strictly LESS material than the equal-setback chamfer.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class KernelBlendTests: XCTestCase {

    private func cube(side: Double) -> Euclid.Mesh {
        Euclid.Mesh.cube(center: Vector(0, 0, 0), size: Vector(side, side, side))
    }

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)
    }

    private func d3(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    // MARK: Edge enumeration

    func testCubeYields12ConvexEdges() {
        let render = EuclidBridge.renderMesh(from: cube(side: 2))
        let edges = EdgeTopology.selectableEdges(from: render)
        XCTAssertEqual(edges.count, 12, "a cube has 12 feature edges")
        XCTAssertTrue(edges.allSatisfy { $0.isConvex }, "every cube edge is convex")
        XCTAssertTrue(edges.allSatisfy { abs($0.length - 2) < 1e-3 }, "each edge is length 2")
    }

    // MARK: Chamfer

    func testChamferRemovesTriangularPrism() {
        let mesh = cube(side: 2)
        let render = EuclidBridge.renderMesh(from: mesh)
        let edge = EdgeTopology.selectableEdges(from: render).first { $0.isConvex }!

        let d = 0.4
        let out = KernelOps.chamferEdge(
            mesh: mesh, p0: d3(edge.start), p1: d3(edge.end),
            normalA: d3(edge.normalA), normalB: d3(edge.normalB), setback: d)

        // Removed ≈ ½·d²·edgeLen = ½·0.16·2 = 0.16.
        XCTAssertEqual(volume(out), 8 - d * d, accuracy: 5e-3,
                       "chamfer removes a d²·(edgeLen/2)·… triangular prism")
        XCTAssertFalse(out.polygons.isEmpty)
    }

    func testChamferDegenerateSetbackIsNoOp() {
        let mesh = cube(side: 2)
        let edge = EdgeTopology.selectableEdges(
            from: EuclidBridge.renderMesh(from: mesh)).first!
        let out = KernelOps.chamferEdge(
            mesh: mesh, p0: d3(edge.start), p1: d3(edge.end),
            normalA: d3(edge.normalA), normalB: d3(edge.normalB), setback: 0)
        XCTAssertEqual(volume(out), 8, accuracy: 1e-6, "zero setback leaves the body")
    }

    // MARK: Fillet

    func testFilletRemovesLessThanChamfer() {
        let mesh = cube(side: 2)
        let render = EuclidBridge.renderMesh(from: mesh)
        let edge = EdgeTopology.selectableEdges(from: render).first { $0.isConvex }!

        let r = 0.4
        let chamfered = KernelOps.chamferEdge(
            mesh: mesh, p0: d3(edge.start), p1: d3(edge.end),
            normalA: d3(edge.normalA), normalB: d3(edge.normalB), setback: r)
        let filleted = KernelOps.filletEdge(
            mesh: mesh, p0: d3(edge.start), p1: d3(edge.end),
            normalA: d3(edge.normalA), normalB: d3(edge.normalB), radius: r)

        let vChamfer = volume(chamfered)
        let vFillet = volume(filleted)
        XCTAssertFalse(filleted.polygons.isEmpty, "fillet produced geometry")
        XCTAssertLessThan(vFillet, 8, "fillet removes some material")
        XCTAssertGreaterThan(vFillet, vChamfer,
                             "a round keeps more material than the flat chamfer")
        // The rounded corner removes area = r²(1 − π/4) ≈ 0.2146·r² over the edge
        // length; loose bound guards against a wildly wrong tool.
        XCTAssertEqual(vFillet, 8 - r * r * (1 - .pi / 4) * 2, accuracy: 0.05)
    }

    // MARK: Smooth chains (curved rims)

    func testCubeEdgeChainStaysSingle() {
        let render = EuclidBridge.renderMesh(from: cube(side: 2))
        let edges = EdgeTopology.selectableEdges(from: render)
        let chain = EdgeTopology.smoothChain(containing: edges[0], in: edges)
        XCTAssertEqual(chain.count, 1, "90° corners never chain")
    }

    func testCylinderRimChainsIntoFullCircle() {
        let slices = 48
        let mesh = Euclid.Mesh.cylinder(radius: 1, height: 2, slices: slices)
        let render = EuclidBridge.renderMesh(from: mesh)
        let edges = EdgeTopology.selectableEdges(from: render).filter { $0.isConvex }
        XCTAssertEqual(edges.count, slices * 2,
                       "each rim tessellates into one segment per slice")

        let chain = EdgeTopology.smoothChain(containing: edges[0], in: edges)
        XCTAssertEqual(chain.count, slices,
                       "one tap expands to the segment's whole rim, not the other rim")
        // Every chained segment lies on ONE cap plane (all same y).
        let ys = Set(chain.map { Int(($0.midpoint.y * 1e4).rounded()) })
        XCTAssertEqual(ys.count, 1, "the chain stays on a single rim")
    }

    func testFilletWholeCylinderRimCutsEverySegment() {
        let slices = 16
        let mesh = Euclid.Mesh.cylinder(radius: 1, height: 2, slices: slices)
        let render = EuclidBridge.renderMesh(from: mesh)
        let edges = EdgeTopology.selectableEdges(from: render).filter { $0.isConvex }
        // At 16 slices the wall facets themselves pass the crease threshold, so
        // the VERTICAL seams are selectable too — seed from a top-rim segment
        // (borders the +y cap) like a user tapping the rim.
        let seed = edges.first {
            max($0.normalA.y, $0.normalB.y) > 0.9
        }!
        let rim = EdgeTopology.smoothChain(containing: seed, in: edges)
        XCTAssertEqual(rim.count, slices,
                       "the chain covers the rim and never leaks down a seam")

        let r = 0.3
        let specs = rim.map {
            BlendEdgeSpec(p0: d3($0.start), p1: d3($0.end),
                          normalA: d3($0.normalA), normalB: d3($0.normalB))
        }
        let out = KernelOps.blendEdges(mesh: mesh, edges: specs, amount: r, isFillet: true)
        XCTAssertFalse(out.polygons.isEmpty, "rim fillet produced geometry")

        // Removed ≈ circumference · r²(1 − π/4) ≈ 2π·0.09·0.2146 ≈ 0.12; the
        // faceted approximation is loose, but a one-segment cut (the bug this
        // guards against) removes only 1/16 of that.
        let removed = volume(mesh) - volume(out)
        let analytic = 2 * Double.pi * r * r * (1 - .pi / 4)
        XCTAssertGreaterThan(removed, analytic * 0.5,
                             "the whole rim is rounded, not one segment")
        XCTAssertLessThan(removed, analytic * 3, "the cut stays a rim-sized ring")
    }
}
