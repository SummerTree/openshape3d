//
//  KernelSectionTests.swift
//  openshape3dTests
//
//  Plane cuts through real B-reps (`OCCTKernel.sectionPolylines` +
//  `SectionKit`): the loops a drawing would show, with exact areas.
//

import XCTest
import simd
@testable import openshape3d

final class KernelSectionTests: XCTestCase {

    /// A 10×6 rectangle extruded over z ∈ [−4, 4].
    private func box() throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 6), SIMD2(0, 6)],
            holes: [], zMin: -4, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
            normal: SIMD3(0, 0, 1)))
    }

    private func loops(_ handle: BRepHandle, origin: SIMD3<Double>, normal: SIMD3<Double>,
                       hint: SIMD3<Double>? = nil) -> [SectionLoop] {
        let pieces = OCCTKernel.sectionPolylines(handle, origin: origin, normal: normal)
        let frame = SectionKit.frame(normal: normal, xAxisHint: hint)
        return SectionKit.loops(from: pieces, origin: origin, xAxis: frame.xAxis, yAxis: frame.yAxis)
    }

    /// Cut square across: one closed four-point loop of area 60, in the
    /// plane frame's own coordinates (x along world x).
    func testABoxCutAcrossIsOneFourPointLoop() throws {
        let l = loops(try box(), origin: SIMD3(0, 0, 1), normal: SIMD3(0, 0, 1))
        XCTAssertEqual(l.count, 1)
        XCTAssertTrue(l[0].closed)
        XCTAssertEqual(l[0].points.count, 4, "\(l[0].points)")
        XCTAssertEqual(abs(l[0].area), 60, accuracy: 1e-9)
        let xs = l[0].points.map(\.x), ys = l[0].points.map(\.y)
        XCTAssertEqual(xs.min()!, 0, accuracy: 1e-9); XCTAssertEqual(xs.max()!, 10, accuracy: 1e-9)
        XCTAssertEqual(ys.min()!, 0, accuracy: 1e-9); XCTAssertEqual(ys.max()!, 6, accuracy: 1e-9)
    }

    /// A plane tilted 30° about x through the box centre: its in-plane
    /// direction (0, cos 30°, sin 30°) leaves the box through the y = 0 and
    /// y = 6 faces first (z would allow ±8 of travel, y only ±3.46), so the
    /// section is a parallelogram 10 wide and 6/cos 30° long — area 69.282.
    func testAnObliqueCutThroughTheBoxIsAParallelogramOfKnownArea() throws {
        let t = 30 * Double.pi / 180
        let normal = SIMD3(0, -sin(t), cos(t))
        let l = loops(try box(), origin: SIMD3(5, 3, 0), normal: normal)
        XCTAssertEqual(l.count, 1)
        XCTAssertEqual(l[0].points.count, 4, "\(l[0].points)")
        XCTAssertEqual(abs(l[0].area), 10 * 6 / cos(t), accuracy: 1e-6)
    }

    /// A plane that misses the solid cuts nothing.
    func testAPlaneClearOfTheSolidCutsNothing() throws {
        XCTAssertTrue(loops(try box(), origin: SIMD3(0, 0, 9), normal: SIMD3(0, 0, 1)).isEmpty)
    }

    /// A TRUE cylinder (exact conic extrude, r = 5, z ∈ [−4, 4]) cut across
    /// samples its circle at the chord deflection asked for — at 0.002 mm the
    /// polygon's area is π r² to 0.05 % — and cut along the axis is a 10 × 8
    /// rectangle of four points, the curved wall contributing two straight
    /// edges.
    func testATrueCylinderCutAcrossIsACircleAndAlongARectangle() throws {
        let cylinder = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: (0..<48).map { i -> SIMD2<Double> in
                let a = Double(i) / 48 * 2 * Double.pi
                return SIMD2(5 * cos(a), 5 * sin(a))
            },
            outerConic: OCCTKernel.ConicSpec(center: .zero, radiusX: 5, radiusY: 5, rotation: 0),
            holes: [], zMin: -4, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        XCTAssertEqual(OCCTKernel.faceTypeCounts(cylinder).planar, 2, "a real cylinder, not a prism")
        let fine = OCCTKernel.sectionPolylines(cylinder, origin: .zero, normal: SIMD3(0, 0, 1), deflection: 0.002)
        let frame = SectionKit.frame(normal: SIMD3(0, 0, 1), xAxisHint: nil)
        let across = SectionKit.loops(from: fine, origin: .zero, xAxis: frame.xAxis, yAxis: frame.yAxis)
        XCTAssertEqual(across.count, 1)
        XCTAssertTrue(across[0].closed)
        XCTAssertGreaterThan(across[0].points.count, 40, "a sampled circle, not a chord")
        // Uniform sampling: the loop IS the regular N-gon, whose area falls
        // short of π r² by θ²/6 (0.053 % at this chord) — exact, then the bound.
        let n = Double(across[0].points.count)
        XCTAssertEqual(abs(across[0].area), n / 2 * 25 * sin(2 * Double.pi / n), accuracy: 1e-6)
        XCTAssertEqual(abs(across[0].area), Double.pi * 25, accuracy: Double.pi * 25 * 1e-3)
        for p in across[0].points {
            XCTAssertEqual(simd_length(p), 5, accuracy: 1e-6, "every sample sits on the circle")
        }
        let along = loops(cylinder, origin: .zero, normal: SIMD3(0, 1, 0))
        XCTAssertEqual(along.count, 1)
        XCTAssertEqual(along[0].points.count, 4, "\(along[0].points)")
        XCTAssertEqual(abs(along[0].area), 10 * 8, accuracy: 1e-9)
    }

    /// A 96-gon prism (the polygon a sketched circle tessellates to) cut
    /// across is the 96-gon itself — 96 points, its exact area — and cut
    /// along its axis a 10 × 8 rectangle.
    func testAPrismCutAcrossAndAlong() throws {
        let n = 96, r = 5.0
        let circle = (0..<n).map { i -> SIMD2<Double> in
            let a = Double(i) / Double(n) * 2 * Double.pi
            return SIMD2(r * cos(a), r * sin(a))
        }
        let prism = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: circle, holes: [], zMin: -4, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        let across = loops(prism, origin: .zero, normal: SIMD3(0, 0, 1))
        XCTAssertEqual(across.count, 1)
        XCTAssertEqual(across[0].points.count, n)
        XCTAssertEqual(abs(across[0].area), Double(n) / 2 * r * r * sin(2 * Double.pi / Double(n)), accuracy: 1e-9)
        let along = loops(prism, origin: .zero, normal: SIMD3(0, 1, 0))
        XCTAssertEqual(along.count, 1)
        XCTAssertEqual(along[0].points.count, 4, "\(along[0].points)")
        XCTAssertEqual(abs(along[0].area), 2 * r * 8, accuracy: 1e-9)
    }
}
