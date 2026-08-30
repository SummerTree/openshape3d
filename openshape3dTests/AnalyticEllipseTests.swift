//
//  AnalyticEllipseTests.swift
//  openshape3dTests
//
//  The last tessellated profile geometry (`docs/STATUS_AND_NEXT_STEPS.md` §4.2).
//  Circles went analytic with the port, holes and then arcs in the two passes
//  before this one; an ellipse was still flattened to 48 straight segments by
//  `detectProfiles` and reached OCCT as a 48-sided prism.
//
//  An ellipse cannot use the arc side-channel: three points determine a
//  circle, not an ellipse. So `CircleSpec` became `ConicSpec` — centre plus
//  two semi-axes and a rotation — and a circle is now simply the case where
//  the semi-axes are equal. One concept instead of two, since to every caller
//  these are the same thing: "this whole loop is a curve OCCT can build
//  exactly, so ignore the polyline".
//
//  NOTE ON FACE TYPES: extruding an ellipse gives a surface of LINEAR
//  EXTRUSION, which `faceTypeCounts` reports under `other` — only a true
//  cylinder counts as `cylindrical`. So the face-count assertions here pin
//  `other == 1`, and it is the VOLUME that proves the wall is a real ellipse
//  rather than a fine tessellation: a tessellated ellipse is inscribed, so it
//  comes out measurably small.
//

import XCTest
import simd
@testable import openshape3d

final class AnalyticEllipseTests: XCTestCase {

    private let radiusX = 8.0
    private let radiusY = 3.0
    private let thickness = 5.0

    private func ellipseSketch(rotation: Double = 0,
                               rx: Double? = nil, ry: Double? = nil) -> Sketch {
        Sketch(plane: .ground, entities: [
            .ellipse(id: UUID(), center: .zero,
                     radiusX: rx ?? radiusX, radiusY: ry ?? radiusY,
                     rotation: rotation),
        ])
    }

    private func ellipseProfile(rotation: Double = 0,
                                rx: Double? = nil, ry: Double? = nil) throws -> Profile {
        try XCTUnwrap(ProfileDetector.detectProfiles(
            in: ellipseSketch(rotation: rotation, rx: rx, ry: ry)).first)
    }

    private func prism(_ profile: Profile) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: profile.loop,
            outerConic: OCCTKernel.ConicSpec(profile.kind),
            holes: [], zMin: 0, zMax: thickness,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1),
            outerSegments: profile.segments))
    }

    /// Volume is measured on the RENDER MESH, which is a tessellation of the
    /// exact solid and so sits a little under the true figure — about 0.04%
    /// for these axes, or 0.16 mm³. A 48-gon prism (what this code produced
    /// before) sits about 0.27% under, roughly 1.03 mm³. This tolerance is
    /// comfortably between the two, which is what makes these assertions a
    /// test of EXACTNESS rather than of mesh density — a tighter number would
    /// only be measuring the tessellator.
    private let volumeTolerance = 0.4

    private func volume(_ handle: BRepHandle) throws -> Double {
        let body = try XCTUnwrap(STEPKit.body(from: handle, name: "e", revision: 1))
        return MeasureKit.bodyVolume(body.render, scale: 1)
    }

    // MARK: - The detector

    /// The profile must NAME the ellipse it came from. It used to be emitted
    /// as `.polygonal`, which threw the semi-axes away at the first step and
    /// left nothing downstream could have used.
    func testTheDetectorNamesTheEllipse() throws {
        let profile = try ellipseProfile(rotation: .pi / 6)
        guard case let .ellipse(centre, rx, ry, rotation) = profile.kind else {
            return XCTFail("expected .ellipse, got \(profile.kind)")
        }
        XCTAssertEqual(centre.x, 0, accuracy: 1e-12)
        XCTAssertEqual(centre.y, 0, accuracy: 1e-12)
        XCTAssertEqual(rx, radiusX, accuracy: 1e-12)
        XCTAssertEqual(ry, radiusY, accuracy: 1e-12)
        XCTAssertEqual(rotation, .pi / 6, accuracy: 1e-12)
    }

    /// A circle must NOT start reporting as an ellipse with equal axes — the
    /// bridge picks `gp_Circ` from equal semi-axes, and a circle that arrived
    /// as `.ellipse` would still work but would stop being recognisable to
    /// everything that switches on `.circle`.
    func testACircleIsStillACircle() throws {
        let sketch = Sketch(plane: .ground, entities: [
            .circle(id: UUID(), center: .zero, radius: 4),
        ])
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        guard case .circle = profile.kind else {
            return XCTFail("expected .circle, got \(profile.kind)")
        }
    }

    // MARK: - The solid

    /// The headline: ONE elliptical wall, not 48 planes.
    func testAnEllipseExtrudesToOneExactWall() throws {
        let counts = OCCTKernel.faceTypeCounts(try prism(try ellipseProfile()))
        XCTAssertEqual(counts.planar, 2, "the two caps, and nothing else")
        XCTAssertEqual(counts.other, 1, "one surface of extrusion for the wall")
        XCTAssertEqual(counts.cylindrical, 0, "an ellipse is not a cylinder")
    }

    /// …and it is the exact ellipse. A 48-gon inscribed in this ellipse loses
    /// about 0.27% of its area — small enough to look right on screen, which
    /// is exactly why it needs measuring rather than eyeballing.
    func testTheSolidHasTheExactEllipseArea() throws {
        let solid = try prism(try ellipseProfile())
        XCTAssertEqual(try volume(solid),
                       .pi * radiusX * radiusY * thickness, accuracy: volumeTolerance)
    }

    /// Rotation must reach OCCT. A rotated ellipse whose rotation was dropped
    /// has the SAME volume, so only the bounding box catches it.
    func testRotationIsCarriedThrough() throws {
        let solid = try prism(try ellipseProfile(rotation: .pi / 2))
        // Pinned to the exact wall as well: a rotated 48-gon has very nearly
        // the same bounding box, so the extents alone would pass on a faceted
        // solid — this assertion is what stops the test drifting into a check
        // of the tessellator.
        XCTAssertEqual(OCCTKernel.faceTypeCounts(solid).other, 1)
        let body = try XCTUnwrap(STEPKit.body(from: solid, name: "e", revision: 1))
        let xs = body.render.positions.map { Double($0.x) }
        let ys = body.render.positions.map { Double($0.y) }
        // Turned a quarter turn, so the semi-axes have swapped places.
        XCTAssertEqual(xs.max()! - xs.min()!, 2 * radiusY, accuracy: 0.02)
        XCTAssertEqual(ys.max()! - ys.min()!, 2 * radiusX, accuracy: 0.02)
    }

    /// `gp_Elips` refuses a minor radius larger than its major one, and the
    /// sketch's semi-axes are in NO particular order — a tall ellipse is as
    /// ordinary as a wide one. This is the case that throws if the bridge
    /// hands OCCT the axes the way the sketch happened to store them.
    func testATallEllipseIsBuiltAsReadilyAsAWideOne() throws {
        let tall = try prism(try ellipseProfile(rx: radiusY, ry: radiusX))
        XCTAssertEqual(OCCTKernel.faceTypeCounts(tall).other, 1)
        XCTAssertEqual(try volume(tall),
                       .pi * radiusX * radiusY * thickness, accuracy: volumeTolerance)
    }

    /// A near-circular ellipse must not trip the equal-axes shortcut into
    /// building a circle of the wrong size — the tolerance is relative, and
    /// these axes differ by 1%.
    func testANearlyCircularEllipseIsStillAnEllipse() throws {
        let solid = try prism(try ellipseProfile(rx: 5.0, ry: 4.95))
        XCTAssertEqual(try volume(solid), .pi * 5.0 * 4.95 * thickness,
                       accuracy: volumeTolerance)
    }

    /// An ellipse with equal semi-axes IS a circle, and must build as one:
    /// `gp_Elips` is degenerate there, and a hole built that way would stop
    /// reporting as a cylindrical face.
    func testEqualSemiAxesBuildACircle() throws {
        let solid = try prism(try ellipseProfile(rx: 6, ry: 6))
        let counts = OCCTKernel.faceTypeCounts(solid)
        XCTAssertEqual(counts.cylindrical, 1, "equal axes must become a gp_Circ")
        XCTAssertEqual(counts.other, 0)
    }

    // MARK: - As a hole

    /// The hole channel is a separate wire in the bridge, and was a separate
    /// bug when holes were made analytic.
    func testAnEllipticalHoleIsOneExactWall() throws {
        let profile = try ellipseProfile()
        let side = 30.0
        let plate = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: [SIMD2(-side / 2, -side / 2), SIMD2(side / 2, -side / 2),
                        SIMD2(side / 2, side / 2), SIMD2(-side / 2, side / 2)],
            holes: [OCCTKernel.ExtrudeHole(
                loop: profile.loop,
                conic: OCCTKernel.ConicSpec(profile.kind))],
            zMin: 0, zMax: thickness,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))

        let counts = OCCTKernel.faceTypeCounts(plate)
        XCTAssertEqual(counts.other, 1, "the bore, as one exact wall")
        XCTAssertEqual(counts.planar, 6, "four plate walls and two caps")
        XCTAssertEqual(try volume(plate),
                       (side * side - .pi * radiusX * radiusY) * thickness,
                       accuracy: volumeTolerance)
    }

    /// The production entry point: `evalExtrude` calls `extrudeSolid`, which
    /// reads the conic off `Profile.kind` through `ConicSpec(_:)`. If that
    /// mapping is missed, everything above still passes and the app still
    /// ships 48-gons.
    func testExtrudeSolidBuildsTheEllipseAnalytically() throws {
        let profile = try ellipseProfile()
        let solid = try XCTUnwrap(OCCTKernel.extrudeSolid(
            outer: profile, holes: [], extras: [],
            zMin: 0, zMax: thickness,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        XCTAssertEqual(OCCTKernel.faceTypeCounts(solid).other, 1)
        XCTAssertEqual(try volume(solid),
                       .pi * radiusX * radiusY * thickness, accuracy: volumeTolerance)
    }
}
