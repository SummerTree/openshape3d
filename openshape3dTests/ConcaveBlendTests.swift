//
//  ConcaveBlendTests.swift
//  openshape3dTests
//
//  Mission 3 item 2 (`docs/STATUS_AND_NEXT_STEPS.md` §4.3): blending a CONCAVE
//  edge — an internal corner — by FILLING it rather than cutting it away.
//
//  Concave edges were classified from the start (`SelectableEdge.isConvex`) and
//  then filtered out at every step: the tap handler discarded them before
//  picking, and replay discarded them again. An internal corner was therefore
//  not merely unsupported, it was unpickable — the tap fell through to the
//  nearest CONVEX edge elsewhere on the body, so it read to the user as a
//  mis-hit rather than as a missing feature.
//
//  The geometry is the same corner tool the convex case builds; what changes is
//  which side of the edge it sits on, and that it is UNIONED instead of
//  subtracted. Volume is the honest test of that: a convex blend can only make
//  the solid smaller, a concave one can only make it bigger.
//
//  Test shape: an L-beam, two 2×2×6 arms sharing a corner. It has exactly ONE
//  concave edge (the inside corner, length 6) and its volume is 2·(2·2·6) −
//  (2·2·6) = 48 for the arms minus the shared cube… computed explicitly below
//  rather than asserted from memory.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class ConcaveBlendTests: XCTestCase {

    private let arm = 6.0        // length of each arm
    private let thick = 2.0      // arm thickness
    private let depth = 6.0      // extent along the concave edge

    private func d3(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)
    }

    /// An L-beam lying along z. Horizontal arm spans x∈[0,arm], y∈[0,thick];
    /// vertical arm spans x∈[0,thick], y∈[0,arm]. The concave edge is the
    /// inside corner at (thick, thick) running the full depth in z.
    private func lBeam() -> Euclid.Mesh {
        func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Euclid.Mesh {
            Euclid.Mesh.cube(
                center: Vector((x0 + x1) / 2, (y0 + y1) / 2, 0),
                size: Vector(x1 - x0, y1 - y0, depth))
        }
        return box(0, 0, arm, thick).union(box(0, 0, thick, arm)).makeWatertight()
    }

    private var lBeamVolume: Double {
        (arm * thick + thick * arm - thick * thick) * depth
    }

    private func concaveEdge(_ mesh: Euclid.Mesh) throws -> SelectableEdge {
        let edges = EdgeTopology.selectableEdges(from: EuclidBridge.renderMesh(from: mesh))
        let concave = edges.filter { !$0.isConvex }
        XCTAssertEqual(concave.count, 1, "an L-beam has exactly one inside corner")
        return try XCTUnwrap(concave.first)
    }

    // MARK: - The shape itself

    /// The fixture must be what the rest of the file assumes: one concave edge,
    /// of the expected length, in a solid of the expected volume.
    func testTheLBeamHasExactlyOneConcaveEdge() throws {
        let mesh = lBeam()
        XCTAssertEqual(volume(mesh), lBeamVolume, accuracy: 1e-6)
        let edge = try concaveEdge(mesh)
        XCTAssertEqual(Double(edge.length), depth, accuracy: 1e-3)
        // It runs along z at the inside corner.
        XCTAssertEqual(Double(edge.midpoint.x), thick, accuracy: 1e-3)
        XCTAssertEqual(Double(edge.midpoint.y), thick, accuracy: 1e-3)
    }

    // MARK: - Filling the corner

    /// A concave fillet ADDS the material between the corner and the arc: for a
    /// right angle, r² − ¼πr² per unit length.
    func testConcaveFilletFillsTheCorner() throws {
        let mesh = lBeam()
        let edge = try concaveEdge(mesh)
        let r = 0.8

        let out = KernelOps.blendEdges(
            mesh: mesh,
            edges: [BlendEdgeSpec(p0: d3(edge.start), p1: d3(edge.end),
                                  normalA: d3(edge.normalA), normalB: d3(edge.normalB),
                                  isConvex: false)],
            amount: r, isFillet: true)

        let added = (r * r - .pi * r * r / 4) * depth
        XCTAssertEqual(volume(out), lBeamVolume + added, accuracy: 0.02,
                       "the fillet fills the corner, so the solid gets BIGGER")
    }

    /// A concave chamfer adds the whole triangle: ½r² per unit length.
    func testConcaveChamferFillsTheWholeTriangle() throws {
        let mesh = lBeam()
        let edge = try concaveEdge(mesh)
        let d = 0.8

        let out = KernelOps.blendEdges(
            mesh: mesh,
            edges: [BlendEdgeSpec(p0: d3(edge.start), p1: d3(edge.end),
                                  normalA: d3(edge.normalA), normalB: d3(edge.normalB),
                                  isConvex: false)],
            amount: d, isFillet: false)

        XCTAssertEqual(volume(out), lBeamVolume + d * d / 2 * depth, accuracy: 0.02)
    }

    /// The filled material must land INSIDE the notch — filling an internal
    /// corner cannot make the solid any bigger.
    ///
    /// Honest scope: this does NOT catch the sign error that actually occurs.
    /// Running these tests against the convex-only rule puts the wedge inside
    /// the solid, so the union is a no-op and the box is unchanged — this test
    /// passes there, and `testConcaveFilletFillsTheCorner` is what fails. It
    /// guards the opposite mistake, a tool that escapes the notch outward.
    func testFillingDoesNotGrowTheBoundingBox() throws {
        let mesh = lBeam()
        let edge = try concaveEdge(mesh)
        let before = EuclidBridge.renderMesh(from: mesh).localAABB

        let out = KernelOps.blendEdges(
            mesh: mesh,
            edges: [BlendEdgeSpec(p0: d3(edge.start), p1: d3(edge.end),
                                  normalA: d3(edge.normalA), normalB: d3(edge.normalB),
                                  isConvex: false)],
            amount: 0.8, isFillet: true)
        let after = EuclidBridge.renderMesh(from: out).localAABB

        for axis in 0..<3 {
            XCTAssertEqual(after.min[axis], before.min[axis], accuracy: 1e-3,
                           "axis \(axis) min moved — the fill landed outside the notch")
            XCTAssertEqual(after.max[axis], before.max[axis], accuracy: 1e-3,
                           "axis \(axis) max moved — the fill landed outside the notch")
        }
    }

    /// A unioned tool must not overshoot the edge's ends the way a subtracted
    /// one deliberately does — the overshoot would stand proud of the end caps
    /// as two small tabs. Covered by the bounding box in z specifically.
    func testTheFillStopsAtTheEndsOfTheEdge() throws {
        let mesh = lBeam()
        let edge = try concaveEdge(mesh)
        let out = KernelOps.blendEdges(
            mesh: mesh,
            edges: [BlendEdgeSpec(p0: d3(edge.start), p1: d3(edge.end),
                                  normalA: d3(edge.normalA), normalB: d3(edge.normalB),
                                  isConvex: false)],
            amount: 0.8, isFillet: true)
        let after = EuclidBridge.renderMesh(from: out).localAABB
        XCTAssertEqual(Double(after.max.z), depth / 2, accuracy: 1e-3)
        XCTAssertEqual(Double(after.min.z), -depth / 2, accuracy: 1e-3)
    }

    // MARK: - Not at the expense of the convex case

    /// The convex path must be untouched: still removes material.
    func testConvexBlendStillCutsTheCornerAway() throws {
        let mesh = lBeam()
        let edges = EdgeTopology.selectableEdges(from: EuclidBridge.renderMesh(from: mesh))
        let convex = try XCTUnwrap(edges.first { $0.isConvex && Double($0.length) > depth - 1e-3 })
        let r = 0.5
        let out = KernelOps.blendEdges(
            mesh: mesh,
            edges: [BlendEdgeSpec(p0: d3(convex.start), p1: d3(convex.end),
                                  normalA: d3(convex.normalA), normalB: d3(convex.normalB),
                                  isConvex: true)],
            amount: r, isFillet: true)
        XCTAssertLessThan(volume(out), lBeamVolume,
                          "a convex blend can only make the solid smaller")
    }

    /// Both senses in ONE call. They must be chained separately — a chain that
    /// mixed them would be swept as one solid and then applied one way for
    /// both — so this is the test that the partition in `blendEdges` holds.
    func testConvexAndConcaveInTheSameCallEachGoTheRightWay() throws {
        let mesh = lBeam()
        let all = EdgeTopology.selectableEdges(from: EuclidBridge.renderMesh(from: mesh))
        let concave = try XCTUnwrap(all.first { !$0.isConvex })
        let convex = try XCTUnwrap(all.first { $0.isConvex && Double($0.length) > depth - 1e-3 })
        let r = 0.5

        func spec(_ e: SelectableEdge) -> BlendEdgeSpec {
            BlendEdgeSpec(p0: d3(e.start), p1: d3(e.end),
                          normalA: d3(e.normalA), normalB: d3(e.normalB),
                          isConvex: e.isConvex)
        }
        let both = KernelOps.blendEdges(mesh: mesh, edges: [spec(concave), spec(convex)],
                                        amount: r, isFillet: true)
        let onlyConcave = KernelOps.blendEdges(mesh: mesh, edges: [spec(concave)],
                                               amount: r, isFillet: true)
        let onlyConvex = KernelOps.blendEdges(mesh: mesh, edges: [spec(convex)],
                                              amount: r, isFillet: true)

        // The two blends are far apart, so their effects simply add.
        let expected = volume(onlyConcave) + volume(onlyConvex) - lBeamVolume
        XCTAssertEqual(volume(both), expected, accuracy: 0.02)
        XCTAssertGreaterThan(volume(onlyConcave), lBeamVolume)
        XCTAssertLessThan(volume(onlyConvex), lBeamVolume)
    }

    // MARK: - Selection

    /// The pick must OFFER concave edges. This is the filter that made an
    /// internal corner unpickable, and it lived in the view model rather than
    /// in the kernel, so no kernel test could have caught it.
    func testEdgeEnumerationOffersTheConcaveEdge() throws {
        let render = EuclidBridge.renderMesh(from: lBeam())
        let edges = EdgeTopology.selectableEdges(from: render)
        XCTAssertTrue(edges.contains { !$0.isConvex },
                      "the inside corner must be among the selectable edges")
    }
}
