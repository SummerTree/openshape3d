//
//  AnalyticArcTests.swift
//  openshape3dTests
//
//  Mission 2's leftover (`docs/STATUS_AND_NEXT_STEPS.md` §4.2): an ARC in a
//  sketch profile must reach OCCT as a real circular edge, not as the polyline
//  it was tessellated into for the mesh path.
//
//  Circles were made analytic when the port landed, and drilled holes in the
//  pass before this one — but a slot or a rounded rectangle went through
//  `arcPoints` inside `ProfileDetector` and arrived as 20-odd straight
//  segments. Same defect as
//  the faceted bore and just as invisible: it renders perfectly round, and
//  then a fillet on the rim has one segment per facet and STEP writes every
//  one of them out as a plane.
//
//  The fix is a side-channel, NOT a change of representation: `Profile.loop`
//  is still the tessellated truth every mesh-side consumer reads, and
//  `Profile.segments` describes the same boundary exactly for the B-rep path.
//  So these tests pin BOTH — the exact face counts, and that the tessellated
//  loop still agrees with them.
//

import XCTest
import simd
@testable import openshape3d

final class AnalyticArcTests: XCTestCase {

    // A slot ("stadium"): straight top and bottom, semicircular caps.
    // Centres at ±halfLength on the x-axis.
    private let halfLength = 10.0
    private let capRadius = 5.0
    private let thickness = 4.0

    /// Exact area: the rectangle between the centres plus the two caps, which
    /// together make one full circle.
    private var exactSlotArea: Double {
        (2 * halfLength) * (2 * capRadius) + .pi * capRadius * capRadius
    }

    private func slotSketch() -> Sketch {
        let r = capRadius, h = halfLength
        return Sketch(plane: .ground, entities: [
            .line(id: UUID(), a: SIMD2(-h, -r), b: SIMD2(h, -r)),
            .arc(id: UUID(), center: SIMD2(h, 0), radius: r,
                 startAngle: -.pi / 2, endAngle: .pi / 2),
            .line(id: UUID(), a: SIMD2(h, r), b: SIMD2(-h, r)),
            .arc(id: UUID(), center: SIMD2(-h, 0), radius: r,
                 startAngle: .pi / 2, endAngle: 3 * .pi / 2),
        ])
    }

    private func slotProfile() throws -> Profile {
        let profiles = ProfileDetector.detectProfiles(in: slotSketch())
        return try XCTUnwrap(profiles.first, "the slot must be detected as a profile")
    }

    private func prism(_ profile: Profile, holes: [OCCTKernel.ExtrudeHole] = [])
        throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: profile.loop, isCircle: false,
            circleCenter: .zero, circleRadius: 0,
            holes: holes, zMin: 0, zMax: thickness,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1),
            outerSegments: profile.segments))
    }

    // MARK: - The detector's side-channel

    /// Four entities in, four exact segments out — two of them arcs.
    func testTheDetectorDescribesTheSlotAsTwoLinesAndTwoArcs() throws {
        let profile = try slotProfile()
        XCTAssertEqual(profile.segments.count, 4,
                       "one segment per sketch entity, in loop order")
        XCTAssertEqual(profile.segments.filter { $0.mid != nil }.count, 2,
                       "the two caps are arcs")
        XCTAssertEqual(profile.segments.filter { $0.mid == nil }.count, 2,
                       "the two flanks are straight")
    }

    /// The segments must be a CLOSED chain in the loop's own order — each
    /// one starting where the last ended. A traversal that reversed a chain
    /// without reversing its endpoints would break exactly here, and OCCT
    /// would report a disconnected wire rather than a wrong shape.
    func testSegmentsFormAClosedChain() throws {
        let segments = try slotProfile().segments
        for (index, segment) in segments.enumerated() {
            let next = segments[(index + 1) % segments.count]
            XCTAssertEqual(simd_distance(segment.end, next.start), 0, accuracy: 1e-9,
                           "segment \(index) must end where segment \(index + 1) starts")
        }
    }

    /// Every arc's three points must lie on one circle of the RADIUS DRAWN.
    /// This is the check that a mid-point taken from the tessellation is a
    /// real point on the arc and not a chord midpoint pulled inside it.
    func testArcSamplesLieOnTheDrawnCircle() throws {
        for segment in try slotProfile().segments {
            guard let mid = segment.mid else { continue }
            // Circumcentre of the three points, then compare the radius.
            let a = segment.start, b = mid, c = segment.end
            let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
            XCTAssertGreaterThan(abs(d), 1e-9, "the three points must not be collinear")
            let ux = ((a.x * a.x + a.y * a.y) * (b.y - c.y)
                      + (b.x * b.x + b.y * b.y) * (c.y - a.y)
                      + (c.x * c.x + c.y * c.y) * (a.y - b.y)) / d
            let uy = ((a.x * a.x + a.y * a.y) * (c.x - b.x)
                      + (b.x * b.x + b.y * b.y) * (a.x - c.x)
                      + (c.x * c.x + c.y * c.y) * (b.x - a.x)) / d
            let centre = SIMD2(ux, uy)
            XCTAssertEqual(simd_distance(centre, a), capRadius, accuracy: 1e-9)
            XCTAssertEqual(abs(centre.x), halfLength, accuracy: 1e-9,
                           "a cap is centred on one of the slot's own centres")
        }
    }

    /// An all-straight loop gets NO segments. Populating them would be a
    /// second description of geometry the polyline already states exactly,
    /// and a second thing to keep in step for no gain.
    func testAPlainPolygonCarriesNoSegments() {
        let sketch = Sketch(plane: .ground, entities: [
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(4, 0)),
            .line(id: UUID(), a: SIMD2(4, 0), b: SIMD2(4, 3)),
            .line(id: UUID(), a: SIMD2(4, 3), b: SIMD2(0, 3)),
            .line(id: UUID(), a: SIMD2(0, 3), b: SIMD2(0, 0)),
        ])
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].segments.isEmpty)
    }

    // MARK: - The solid

    /// The headline: a slot has TWO cylindrical walls, not forty facets.
    func testASlotExtrudesToTwoCylindricalWalls() throws {
        let solid = try prism(try slotProfile())
        let counts = OCCTKernel.faceTypeCounts(solid)
        XCTAssertEqual(counts.cylindrical, 2, "one per cap")
        XCTAssertEqual(counts.planar, 4, "two flanks and two caps of the prism")
        XCTAssertEqual(counts.other, 0)
    }

    /// …and it is the right SIZE. A slot built from the tessellated loop is
    /// INSCRIBED in the true boundary, so it comes out slightly small — this
    /// is the assertion that separates "analytic" from "finely faceted".
    func testTheSlotHasItsExactArea() throws {
        let solid = try prism(try slotProfile())
        let body = try XCTUnwrap(STEPKit.body(from: solid, name: "slot", revision: 1))
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1),
                       exactSlotArea * thickness, accuracy: 1.0)
    }

    /// The same slot punched THROUGH a plate, which exercises the hole path
    /// rather than the outer one — they are separate wires in the bridge and
    /// were separate bugs in the pass before this.
    func testASlotShapedHoleIsTwoCylinders() throws {
        let profile = try slotProfile()
        let plateSide = 40.0
        let plate = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: [SIMD2(-plateSide / 2, -plateSide / 2),
                        SIMD2(plateSide / 2, -plateSide / 2),
                        SIMD2(plateSide / 2, plateSide / 2),
                        SIMD2(-plateSide / 2, plateSide / 2)],
            isCircle: false, circleCenter: .zero, circleRadius: 0,
            holes: [OCCTKernel.ExtrudeHole(loop: profile.loop, segments: profile.segments)],
            zMin: 0, zMax: thickness,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        let counts = OCCTKernel.faceTypeCounts(plate)
        XCTAssertEqual(counts.cylindrical, 2, "the slot's two caps, bored out")
        XCTAssertEqual(counts.planar, 8,
                       "4 plate walls + 2 plate caps + the slot's 2 straight flanks")

        let body = try XCTUnwrap(STEPKit.body(from: plate, name: "plate", revision: 1))
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1),
                       (plateSide * plateSide - exactSlotArea) * thickness, accuracy: 2.0)
    }

    /// A rounded rectangle — four straights and four quarter-turns, drawn the
    /// way a user has to draw one today (Line + Arc; there is no sketch-fillet
    /// tool). Proves the walker handles several arcs that do NOT share a
    /// centre, and arcs shorter than a semicircle.
    func testARoundedRectangleHasFourCylindricalCorners() throws {
        let w = 12.0, h = 8.0, r = 2.0
        var entities: [SketchEntity] = []
        // Corner centres, counter-clockwise from bottom-right.
        let centres = [SIMD2(w - r, r), SIMD2(r, r), SIMD2(r, h - r), SIMD2(w - r, h - r)]
        let startAngles = [-Double.pi / 2, Double.pi, Double.pi / 2, 0.0]
        // Straights run between the tangent points, corners turn 90°.
        entities.append(.line(id: UUID(), a: SIMD2(r, 0), b: SIMD2(w - r, 0)))
        entities.append(.arc(id: UUID(), center: centres[0], radius: r,
                             startAngle: startAngles[0], endAngle: 0))
        entities.append(.line(id: UUID(), a: SIMD2(w, r), b: SIMD2(w, h - r)))
        entities.append(.arc(id: UUID(), center: centres[3], radius: r,
                             startAngle: 0, endAngle: .pi / 2))
        entities.append(.line(id: UUID(), a: SIMD2(w - r, h), b: SIMD2(r, h)))
        entities.append(.arc(id: UUID(), center: centres[2], radius: r,
                             startAngle: .pi / 2, endAngle: .pi))
        entities.append(.line(id: UUID(), a: SIMD2(0, h - r), b: SIMD2(0, r)))
        entities.append(.arc(id: UUID(), center: centres[1], radius: r,
                             startAngle: .pi, endAngle: 3 * .pi / 2))

        let profiles = ProfileDetector.detectProfiles(in: Sketch(plane: .ground, entities: entities))
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.segments.filter { $0.mid != nil }.count, 4)

        let solid = try prism(profile)
        let counts = OCCTKernel.faceTypeCounts(solid)
        XCTAssertEqual(counts.cylindrical, 4, "one per rounded corner")
        XCTAssertEqual(counts.planar, 6, "four flanks and two caps")

        let body = try XCTUnwrap(STEPKit.body(from: solid, name: "rrect", revision: 1))
        let exactArea = w * h - (4 - .pi) * r * r
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1),
                       exactArea * thickness, accuracy: 0.5)
    }

    /// The whole point of carrying three points instead of a centre and an
    /// angle pair: the face traversal may walk a chain BACKWARDS, and an
    /// orientation convention is the thing that silently flips when it does.
    /// Reversing the sketch order must not change the solid.
    func testReversedSketchOrderGivesTheSameSolid() throws {
        let forward = try slotProfile()
        let reversedSketch = Sketch(plane: .ground,
                                    entities: slotSketch().entities.reversed())
        let reversed = try XCTUnwrap(
            ProfileDetector.detectProfiles(in: reversedSketch).first)

        let a = try prism(forward), b = try prism(reversed)
        // Both counts pinned to 2, not merely to each other: a solid that
        // silently went faceted would still match itself.
        XCTAssertEqual(OCCTKernel.faceTypeCounts(a).cylindrical, 2)
        XCTAssertEqual(OCCTKernel.faceTypeCounts(b).cylindrical, 2)
        let bodyA = try XCTUnwrap(STEPKit.body(from: a, name: "a", revision: 1))
        let bodyB = try XCTUnwrap(STEPKit.body(from: b, name: "b", revision: 1))
        XCTAssertEqual(MeasureKit.bodyVolume(bodyA.render, scale: 1),
                       MeasureKit.bodyVolume(bodyB.render, scale: 1), accuracy: 0.01)
    }

    /// The production entry point, not just the wire builder underneath it:
    /// `evalExtrude` calls `extrudeSolid`, which resolves holes through
    /// `extrudeHoles`. A slot with a drilled hole exercises both channels at
    /// once — arc segments on the outer boundary, a circle on the inner one.
    func testExtrudeSolidCarriesSegmentsForTheWholeProfile() throws {
        var entities = slotSketch().entities
        let boreRadius = 2.0
        entities.append(.circle(id: UUID(), center: .zero, radius: boreRadius))
        let sketch = Sketch(plane: .ground, entities: entities)

        let detected = ProfileDetector.detectProfiles(in: sketch)
        let outer = try XCTUnwrap(detected.max(by: { abs($0.area) < abs($1.area) }))
        let holes = ProfileDetector.holes(of: outer, among: detected)
        XCTAssertEqual(holes.count, 1, "the bore is a hole of the slot")

        let solid = try XCTUnwrap(OCCTKernel.extrudeSolid(
            outer: outer, holes: holes, extras: [],
            zMin: 0, zMax: thickness,
            origin: .zero, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))

        let counts = OCCTKernel.faceTypeCounts(solid)
        XCTAssertEqual(counts.cylindrical, 3, "two slot caps and the bore")
        XCTAssertEqual(counts.planar, 4, "two flanks and two caps")

        let body = try XCTUnwrap(STEPKit.body(from: solid, name: "slot", revision: 1))
        let exactArea = exactSlotArea - .pi * boreRadius * boreRadius
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1),
                       exactArea * thickness, accuracy: 1.0)
    }

    /// The tessellated loop must still describe the SAME region — it is what
    /// area, centroid, `contains` and the mesh path all read, and a
    /// side-channel that drifts from it would be worse than no side-channel.
    func testTheTessellatedLoopStillAgreesWithTheExactArea() throws {
        let profile = try slotProfile()
        // Inscribed, so slightly under — but within a facet's worth.
        XCTAssertLessThan(profile.area, exactSlotArea)
        XCTAssertEqual(profile.area, exactSlotArea, accuracy: exactSlotArea * 0.01)
    }
}
