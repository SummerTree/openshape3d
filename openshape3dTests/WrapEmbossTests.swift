//
//  WrapEmbossTests.swift
//  openshape3dTests
//
//  Spec §4.15 Wrap & Emboss. The property that separates Wrap from Project is
//  NO STRETCH: a 40 mm-wide profile stays 40 mm of material after wrapping,
//  whatever the cylinder's radius. That is the first thing tested here; the
//  rest pins the emboss solid's volume, its sign (raised vs engraved), and the
//  alignment controls.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class WrapEmbossTests: XCTestCase {

    /// A cylinder of radius 20 about the world Y axis.
    private func target(radius: Double = 20) -> WrapKit.Target {
        WrapKit.Target(
            axisPoint: .zero, axisDir: SIMD3(0, 1, 0),
            reference: SIMD3(1, 0, 0), radius: radius)
    }

    /// A `width` x `height` rectangle centred on the origin, CCW.
    private func rect(width: Double, height: Double) -> [SIMD2<Double>] {
        let w = width / 2, h = height / 2
        return [SIMD2(-w, -h), SIMD2(w, -h), SIMD2(w, h), SIMD2(-w, h)]
    }

    private func polylineLength(_ points: [SIMD3<Double>]) -> Double {
        guard points.count >= 2 else { return 0 }
        return (1..<points.count).reduce(0.0) {
            $0 + simd_length(points[$1] - points[$1 - 1])
        }
    }

    // MARK: No stretch — the defining property

    func testWrappedLengthEqualsFlatLengthRegardlessOfRadius() {
        // A straight 40-long run along local x, sampled densely so the wrapped
        // polyline follows the arc rather than chording it.
        let flat = (0...400).map { SIMD2<Double>(-20 + Double($0) * 0.1, 0) }

        for radius in [8.0, 20.0, 100.0] {
            let wrapped = WrapKit.wrap(loop: flat, onto: target(radius: radius))
            XCTAssertEqual(polylineLength(wrapped), 40, accuracy: 0.01,
                           "40 mm of profile is 40 mm of surface at radius \(radius)")
        }
    }

    func testWrappedPointsLieOnTheCylinder() {
        let points = WrapKit.wrap(loop: rect(width: 30, height: 10), onto: target())
        for p in points {
            // Distance from the Y axis must be the radius.
            XCTAssertEqual(simd_length(SIMD2(p.x, p.z)), 20, accuracy: 1e-9)
        }
    }

    func testAxialCoordinateIsUnscaled() {
        // Local y maps straight to distance along the axis.
        let p = WrapKit.wrap(SIMD2(0, 7), onto: target())
        XCTAssertEqual(p.y, 7, accuracy: 1e-9)
    }

    func testProfileWiderThanTheCircumferenceWrapsAllTheWayRound() {
        // Circumference at r = 20 is ~125.7; a 125.66-wide profile closes on itself.
        let circumference: Double = 2 * Double.pi * 20.0
        let a = WrapKit.wrap(SIMD2(0, 0), onto: target())
        let b = WrapKit.wrap(SIMD2(circumference, 0), onto: target())
        XCTAssertEqual(simd_length(b - a), 0, accuracy: 1e-9,
                       "a full circumference of profile returns to its start")
    }

    // MARK: Alignment controls

    func testCenterOffsetsTheProfileOnTheSurface() {
        let plain = WrapKit.wrap(SIMD2(5, 5), onto: target())
        let shifted = WrapKit.wrap(
            SIMD2(5, 5), onto: target(),
            settings: WrapKit.Settings(depth: 1, center: SIMD2(5, 5)))
        XCTAssertNotEqual(plain.y, shifted.y, accuracy: 1e-9)
        // With center == the point, it lands on the alignment origin itself.
        XCTAssertEqual(simd_length(shifted - SIMD3(20, 0, 0)), 0, accuracy: 1e-9)
    }

    func testRotationTurnsTheProfileAboutItsOwnCentre() {
        // A point on local +x, rotated 90°, must end up on local +y — i.e. it
        // stops running around the circumference and runs along the axis.
        let rotated = WrapKit.wrap(
            SIMD2(6, 0), onto: target(),
            settings: WrapKit.Settings(depth: 1, rotation: .pi / 2))
        XCTAssertEqual(rotated.y, 6, accuracy: 1e-9,
                       "the profile's x now runs along the axis")
    }

    func testAFaceFromThePickerBecomesAUsableTarget() {
        let face = FaceTopology.CylindricalFace(
            triangles: [], axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 1, 0),
            radius: 12, minT: 0, maxT: 10, segments: 48, matchesWholeBody: true)
        let built = WrapKit.Target(face: face)
        XCTAssertEqual(built.radius, 12)
        XCTAssertEqual(built.axisPoint.y, 5, accuracy: 1e-9,
                       "the alignment origin sits at the face's mid-height")
        XCTAssertEqual(simd_dot(built.reference, built.axisDir), 0, accuracy: 1e-12,
                       "the reference direction is perpendicular to the axis")
    }

    // MARK: The emboss solid

    /// Exact volume of a wrapped slab of flat area `A` and depth `d` at radius
    /// `r`. Arc length is preserved AT the surface, so a raised slab's outer
    /// face is longer than its base and an engraved one's inner face is
    /// shorter: the volume is A·|d|·(1 + d/2r) with d SIGNED, never A·|d|.
    private func expectedVolume(area: Double, depth: Double, radius: Double) -> Double {
        area * abs(depth) * (1 + depth / (2 * radius))
    }

    func testRaisedEmbossHasTheWrappedSlabVolume() throws {
        let profile = rect(width: 30, height: 8)   // area 240
        let solid = try XCTUnwrap(WrapKit.embossSolid(
            loop: profile, onto: target(), settings: WrapKit.Settings(depth: 2)))
        XCTAssertEqual(KernelOps.volume(of: solid),
                       expectedVolume(area: 240, depth: 2, radius: 20),
                       accuracy: 240 * 2 * 0.01,
                       "within 1% — banding keeps the facets off the chord")
    }

    func testEngravedEmbossHasTheSameMagnitudeOfVolume() throws {
        let profile = rect(width: 30, height: 8)
        let raised = try XCTUnwrap(WrapKit.embossSolid(
            loop: profile, onto: target(), settings: WrapKit.Settings(depth: 2)))
        let engraved = try XCTUnwrap(WrapKit.embossSolid(
            loop: profile, onto: target(), settings: WrapKit.Settings(depth: -2)))
        // Engraved sits INSIDE the surface, so it is slightly smaller.
        XCTAssertEqual(KernelOps.volume(of: engraved),
                       expectedVolume(area: 240, depth: -2, radius: 20),
                       accuracy: 240 * 2 * 0.02)
        XCTAssertLessThan(KernelOps.volume(of: engraved), KernelOps.volume(of: raised))
    }

    func testRaisedSolidSitsOutsideTheSurfaceAndEngravedInside() throws {
        let profile = rect(width: 20, height: 6)
        let raised = try XCTUnwrap(WrapKit.embossSolid(
            loop: profile, onto: target(), settings: WrapKit.Settings(depth: 3)))
        let engraved = try XCTUnwrap(WrapKit.embossSolid(
            loop: profile, onto: target(), settings: WrapKit.Settings(depth: -3)))

        func radialRange(_ mesh: Euclid.Mesh) -> (min: Double, max: Double) {
            var lo = Double.infinity, hi = -Double.infinity
            for polygon in mesh.polygons {
                for vertex in polygon.vertices {
                    let r = (vertex.position.x * vertex.position.x
                             + vertex.position.z * vertex.position.z).squareRoot()
                    lo = min(lo, r); hi = max(hi, r)
                }
            }
            return (lo, hi)
        }
        let out = radialRange(raised), into = radialRange(engraved)
        XCTAssertEqual(out.min, 20, accuracy: 0.05)
        XCTAssertEqual(out.max, 23, accuracy: 0.05, "raised reaches r + depth")
        XCTAssertEqual(into.min, 17, accuracy: 0.05, "engraved reaches r - depth")
        XCTAssertEqual(into.max, 20, accuracy: 0.05)
    }

    func testEmbossSolidBooleansIntoACylinderBody() throws {
        // The real workflow: build the cylinder, fuse the raised profile.
        let cylinder = KernelOps.cylinderAlongAxis(
            baseCenter: SIMD3(0, -20, 0), axisDir: SIMD3(0, 1, 0),
            radius: 20, height: 40)
        let boss = try XCTUnwrap(WrapKit.embossSolid(
            loop: rect(width: 24, height: 6), onto: target(),
            settings: WrapKit.Settings(depth: 1.5)))

        let before = KernelOps.volume(of: cylinder)
        let after = KernelOps.volume(of: cylinder.union(boss))
        XCTAssertEqual(after - before,
                       expectedVolume(area: 144, depth: 1.5, radius: 20),
                       accuracy: Double(144 * 1.5 * 0.05),
                       "the fused boss adds its own volume, nothing more")
    }

    // MARK: Refusals

    func testZeroDepthProducesNoSolid() {
        XCTAssertNil(WrapKit.embossSolid(
            loop: rect(width: 10, height: 10), onto: target(),
            settings: WrapKit.Settings(depth: 0)))
    }

    func testADegenerateProfileProducesNoSolid() {
        XCTAssertNil(WrapKit.embossSolid(
            loop: [SIMD2(0, 0), SIMD2(1, 0)], onto: target(),
            settings: WrapKit.Settings(depth: 1)),
            "two points are not a profile")
    }

    func testAZeroWidthProfileProducesNoSolid() {
        // Vertical line segment thickened into a zero-area loop.
        XCTAssertNil(WrapKit.embossSolid(
            loop: [SIMD2(0, 0), SIMD2(0, 5), SIMD2(0, 10)], onto: target(),
            settings: WrapKit.Settings(depth: 1)),
            "no extent around the circumference means nothing to wrap")
    }
}
