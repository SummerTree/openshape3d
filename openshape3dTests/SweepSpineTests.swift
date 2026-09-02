//
//  SweepSpineTests.swift
//  openshape3dTests
//
//  A sweep keeps its section NORMAL to the spine and mitres polyline corners,
//  so a polyline sweep encloses exactly area × length. Found 2026-09-02 while
//  building a Helicoil: BRepOffsetAPI_MakePipe along a polyline translated the
//  profile without turning it — every chord a skewed prism — so V/(A·L) was
//  the mean of cos(chord angle): 0.69 for a 9-chord quarter arc, 0.5 for one
//  90° corner, ~0 around a helix, all while BRepCheck called the solid valid.
//  These pin the MakePipeShell replacement.
//

import XCTest
import simd
@testable import openshape3d

final class SweepSpineTests: XCTestCase {

    /// A 1×1 square on the ground plane (normal +Y), so a spine that leaves
    /// the origin along +Y starts normal to the section. Area 1 makes the
    /// volume the polyline length.
    private func square() throws -> Profile {
        let sketch = Sketch(id: SketchID(), plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(-0.5, -0.5), max: SIMD2(0.5, 0.5))])
        return try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
    }

    private func length(_ spine: [SIMD3<Double>]) -> Double {
        zip(spine, spine.dropFirst()).reduce(0) { $0 + simd_length($1.1 - $1.0) }
    }

    /// Quarter arc of radius R in the Y–Z plane, leaving the origin along +Y.
    private func quarterArc(radius r: Double, chords: Int) -> [SIMD3<Double>] {
        (0...chords).map { i in
            let a = Double.pi / 2 * Double(i) / Double(chords)
            return SIMD3(0, r * sin(a), r - r * cos(a))
        }
    }

    private func sweep(_ spine: [SIMD3<Double>]) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.sweepSolid(outer: try square(), holes: [], plane: .ground, spine: spine),
                      "the sweep must build")
    }

    func testStraightSpineIsExact() throws {
        let brep = try sweep([SIMD3(0, 0, 0), SIMD3(0, 12, 0)])
        XCTAssertEqual(OCCTKernel.volume(brep), 12, accuracy: 1e-6)
    }

    /// The case that exposed the bug: nine 10° chords. Mitred, the volume is
    /// exactly the polyline length; MakePipe gave 0.69 of it.
    func testQuarterArcPolylineSweepIsAreaTimesLength() throws {
        let spine = quarterArc(radius: 10, chords: 9)
        let brep = try sweep(spine)
        let want = length(spine)
        XCTAssertEqual(OCCTKernel.volume(brep), want, accuracy: want * 1e-6)
        let counts = OCCTKernel.faceTypeCounts(brep)
        XCTAssertEqual(counts.planar + counts.cylindrical + counts.other, 2 + 4 * 9,
                       "two caps + four quads per chord: \(counts)")
    }

    /// One 90° corner: mitred, exactly A × (20 + 20); translated, it was half.
    func testRightAngleCornerIsMitred() throws {
        let brep = try sweep([SIMD3(0, 0, 0), SIMD3(0, 20, 0), SIMD3(0, 20, 20)])
        XCTAssertEqual(OCCTKernel.volume(brep), 40, accuracy: 40 * 1e-6)
    }

    func testSmallBendIsExactToo() throws {
        let spine = quarterArc(radius: 10, chords: 2).prefix(3).map { $0 }   // two chords, 45° each
        let brep = try sweep(Array(spine))
        let want = length(Array(spine))
        XCTAssertEqual(OCCTKernel.volume(brep), want, accuracy: want * 1e-6)
    }

    /// An EXACT helical spine (`HelixSpec`): four helicoidal walls, and by
    /// Pappus the volume is area × the TRUE helix length — which the sampled
    /// polyline sweep of the same spec falls measurably short of.
    func testExactHelixSweepIsAreaTimesTrueLength() throws {
        let spec = HelixSpec(axisPoint: .zero, axisDirection: SIMD3(0, 1, 0),
                             referenceDirection: SIMD3(1, 0, 0), radius: 10, pitch: 4, turns: 2)
        let start = spec.point(at: 0), t = spec.tangent(at: 0)
        let radial = SIMD3<Double>(1, 0, 0)                                   // ⟂ t at angle 0
        let plane = SketchPlane(origin: start, xAxis: radial, yAxis: simd_cross(t, radial))  // normal = t
        let exact = try XCTUnwrap(OCCTKernel.sweepSolid(
            outer: try square(), holes: [], plane: plane, spine: spec.sampledSpine(), helix: spec))
        let want = spec.length                                              // A = 1
        XCTAssertEqual(OCCTKernel.volume(exact), want, accuracy: want * 1e-5,
                       "helix sweep \(OCCTKernel.volume(exact)) vs A × true length \(want)")
        let counts = OCCTKernel.faceTypeCounts(exact)
        XCTAssertEqual(counts.planar, 2, "two caps: \(counts)")
        XCTAssertEqual(counts.other, 4, "four helicoidal walls: \(counts)")

        let sampled = try XCTUnwrap(OCCTKernel.sweepSolid(
            outer: try square(), holes: [], plane: plane, spine: spec.sampledSpine()))
        XCTAssertLessThan(OCCTKernel.volume(sampled), want, "36 chords per turn cut the corners")
        XCTAssertGreaterThan(OCCTKernel.volume(sampled), want * 0.99)
    }

    /// The section is the SAME size all along: the radius of the arc does not
    /// change V/(A·L) (it did not before either — the flaw was per corner).
    func testRadiusDoesNotMatter() throws {
        for r in [2.0, 50.0] {
            let spine = quarterArc(radius: r, chords: 9)
            let brep = try sweep(spine)
            let want = length(spine)
            XCTAssertEqual(OCCTKernel.volume(brep), want, accuracy: want * 1e-6, "R = \(r)")
        }
    }
}
