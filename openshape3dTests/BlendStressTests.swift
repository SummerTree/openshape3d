//
//  BlendStressTests.swift
//  openshape3dTests
//
//  Regression cover for two blend bugs reported from the app ("chamfer/fillet
//  do not work like Shapr3D and crash a lot"), both found by walking the space
//  a USER walks rather than the one edge existing tests picked.
//
//  1. CRASH — mesh path. A blend larger than the curve it sits on makes the
//     swept tool fold through itself, and the CSG that follows dies on an
//     assertion inside Euclid's BSP clipper (SIGTRAP in `Polygon.clip`), which
//     takes the process with it. Measured on a Ø10 cylinder rim: 3 mm builds,
//     6 mm killed the test runner. Verified PRE-EXISTING — it reproduces at
//     6e589aa, before concave-edge support went in.
//
//  2. SILENT NO-OP — OCCT path. `OS3DNearestEdges` sampled each edge at 16
//     points to decide which edge a tap meant. Ample for a straight edge;
//     badly wrong for a circle, where on a Ø10 rim the samples sit ~2 mm apart
//     while the match tolerance is 1% of the body diagonal (0.185 mm). Most
//     taps on a cylinder's rim were therefore rejected as "no edge near here"
//     and the fillet did nothing at all — which is exactly what "doesn't work
//     like Shapr3D" looks like from the outside.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class BlendStressTests: XCTestCase {

    private let cylRadius = 5.0
    private let cylHeight = 12.0

    private func d3(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }
    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)
    }
    private func spec(_ e: SelectableEdge) -> BlendEdgeSpec {
        BlendEdgeSpec(p0: d3(e.start), p1: d3(e.end),
                      normalA: d3(e.normalA), normalB: d3(e.normalB),
                      isConvex: e.isConvex)
    }
    private func cylinderBrep() throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: cylRadius, height: cylHeight), placement: .identity))
    }
    private func cylinderBody() throws -> Body {
        try XCTUnwrap(STEPKit.body(from: try cylinderBrep(), name: "c", revision: 1))
    }
    private func point(_ e: SelectableEdge) -> SIMD3<Double> {
        SIMD3(Double(e.midpoint.x), Double(e.midpoint.y), Double(e.midpoint.z))
    }
    /// The tolerance the app uses: 1% of the body's AABB diagonal.
    private func appTolerance(_ body: Body) -> Double {
        let aabb = body.render.localAABB
        return max(Double(simd_length(aabb.max - aabb.min)) * 0.01, 1e-6)
    }

    // MARK: - 1. The crash

    /// An over-large blend on a curved rim must FAIL, not take the process
    /// down. Reaching this line at all is most of the assertion.
    func testAnOversizeRimBlendFailsInsteadOfCrashing() throws {
        let body = try cylinderBody()
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let rim = EdgeTopology.smoothChain(containing: edges[0], in: edges)
        XCTAssertGreaterThan(rim.count, 100, "a tessellated rim is one long chain")

        for r in [3.6, 6.0, 20.0] {
            let out = KernelOps.blendEdges(
                mesh: body.euclidMesh(), edges: rim.map(spec), amount: r, isFillet: true)
            XCTAssertTrue(out.polygons.isEmpty,
                          "r=\(r) exceeds what the swept tool can build; it must "
                          + "report failure so the UI can show the blend invalid")
        }
    }

    /// …while a blend that DOES fit still works. The guard must not simply
    /// refuse every curved chain.
    func testAFeasibleRimBlendStillWorks() throws {
        let body = try cylinderBody()
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let rim = EdgeTopology.smoothChain(containing: edges[0], in: edges)
        let before = volume(body.euclidMesh())

        for r in [0.5, 2.0, 3.0] {
            let out = KernelOps.blendEdges(
                mesh: body.euclidMesh(), edges: rim.map(spec), amount: r, isFillet: true)
            XCTAssertFalse(out.polygons.isEmpty, "r=\(r) fits and must build")
            XCTAssertLessThan(volume(out), before, "a convex fillet removes material")
        }
    }

    /// Straight edges have no curvature limit, so a cube must stay blendable
    /// at every radius the guard sees — including ones far too big to be
    /// sensible, which simply produce a degenerate-but-safe result.
    func testEveryCubeEdgeSurvivesEveryRadius() {
        let mesh = Euclid.Mesh.cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10))
        let edges = EdgeTopology.selectableEdges(from: EuclidBridge.renderMesh(from: mesh))
        XCTAssertEqual(edges.count, 12)
        for edge in edges {
            for r in [0.01, 0.5, 2.0, 4.9, 6.0, 12.0] {
                for isFillet in [true, false] {
                    _ = KernelOps.blendEdges(
                        mesh: mesh, edges: [spec(edge)], amount: r, isFillet: isFillet)
                }
            }
        }
    }

    /// Both rims at once, oversize — the case that first crashed the runner.
    func testBothRimsOversizeFailsCleanly() throws {
        let body = try cylinderBody()
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let out = KernelOps.blendEdges(
            mesh: body.euclidMesh(), edges: edges.map(spec), amount: 6.0, isFillet: true)
        XCTAssertTrue(out.polygons.isEmpty)
    }

    // MARK: - 2. The silent no-op

    /// EVERY point on a rim must resolve to that rim's edge at the tolerance
    /// the app actually uses. With 16-sample matching only 2 of these 8 did.
    func testEveryRimPointResolvesAtTheAppsOwnTolerance() throws {
        let brep = try cylinderBrep()
        let body = try cylinderBody()
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let tolerance = appTolerance(body)

        var unresolved: [Int] = []
        for i in 0..<min(edges.count, 24) {
            if OCCTKernel.fillet(brep, at: [point(edges[i])],
                                 radius: 1.0, tolerance: tolerance) == nil {
                unresolved.append(i)
            }
        }
        XCTAssertEqual(unresolved, [],
                       "a tap anywhere on the rim must find the rim; coarse "
                       + "sampling made most taps miss it entirely")
    }

    /// A tap selects the whole tangent chain, so the app hands OCCT ~158
    /// points at once. They must collapse to the one circular edge they all
    /// name, and the fillet must build.
    func testAWholeRimChainFilletsAsOneEdge() throws {
        let brep = try cylinderBrep()
        let body = try cylinderBody()
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let rim = EdgeTopology.smoothChain(containing: edges[0], in: edges)
        let points = rim.map(point)

        let out = try XCTUnwrap(
            OCCTKernel.fillet(brep, at: points, radius: 1.0, tolerance: appTolerance(body)),
            "the whole-rim pick the UI produces must fillet")
        // One rim rounded: still one cylindrical wall, plus the fillet's own
        // toroidal surface, and the caps stay planar.
        let counts = OCCTKernel.faceTypeCounts(out)
        XCTAssertEqual(counts.planar, 2, "both caps survive")
        XCTAssertGreaterThanOrEqual(counts.cylindrical, 1)
    }

    /// Points on BOTH rims must round both, not fail outright — the two-point
    /// case that returned nil before the fix.
    func testPointsOnBothRimsRoundBoth() throws {
        let brep = try cylinderBrep()
        let body = try cylinderBody()
        let edges = EdgeTopology.selectableEdges(from: body.render)
        let top = try XCTUnwrap(edges.first { $0.midpoint.y > Float(cylHeight) - 0.01 })
        let bottom = try XCTUnwrap(edges.first { $0.midpoint.y < 0.01 })

        XCTAssertNotNil(
            OCCTKernel.fillet(brep, at: [point(top), point(bottom)],
                              radius: 1.0, tolerance: appTolerance(body)),
            "selecting both rims must round both")
    }

    /// The same matcher serves chamfer, so it must be fixed there too.
    func testChamferResolvesRimPointsAsWell() throws {
        let brep = try cylinderBrep()
        let body = try cylinderBody()
        let edges = EdgeTopology.selectableEdges(from: body.render)
        XCTAssertNotNil(
            OCCTKernel.chamfer(brep, at: [point(edges[0])],
                               distance: 1.0, tolerance: appTolerance(body)),
            "chamfer shares OS3DNearestEdges and had the same blind spot")
    }

    /// A straight edge must not have regressed: the projection replaces
    /// sampling for every edge type, not just curved ones.
    func testBoxEdgesStillResolveThroughOCCT() throws {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10), placement: .identity))
        let body = try XCTUnwrap(STEPKit.body(from: box, name: "b", revision: 1))
        let edges = EdgeTopology.selectableEdges(from: body.render)
        var unresolved = 0
        for edge in edges {
            if OCCTKernel.fillet(box, at: [point(edge)], radius: 1.0,
                                 tolerance: appTolerance(body)) == nil { unresolved += 1 }
        }
        XCTAssertEqual(unresolved, 0, "all 12 cube edges must still resolve")
    }
}
