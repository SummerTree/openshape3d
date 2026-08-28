//
//  ConstructionAxisDeriveTests.swift
//  openshape3dTests
//
//  `EditorViewModel.deriveAxis` — the Add Axis tool infers which of the five
//  §6.2 constructions to use from what the user tapped, rather than making
//  them pick a type first. That inference is the part worth pinning; the
//  constructions themselves are covered by ConstructionAxisTests.
//
//  Pure statics only, so no `EditorViewModel` is built (gotcha 1: an
//  in-process ModelContainer crashes XCTest).
//

import XCTest
import simd
@testable import openshape3d

final class ConstructionAxisDeriveTests: XCTestCase {

    private typealias Pick = EditorViewModel.AxisPick

    private func assertParallel(_ a: SIMD3<Double>, _ b: SIMD3<Double>,
                                _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        // An axis has no preferred sign, so compare |cos|.
        XCTAssertEqual(abs(simd_dot(simd_normalize(a), simd_normalize(b))), 1,
                       accuracy: 1e-9, message, file: file, line: line)
    }

    func testNoPicksDeriveNothing() {
        XCTAssertNil(EditorViewModel.deriveAxis(from: [], length: 10))
    }

    func testOneEdgeDerivesAlongEdge() throws {
        let axis = try XCTUnwrap(EditorViewModel.deriveAxis(
            from: [.edge(start: SIMD3(0, 0, 0), end: SIMD3(0, 4, 0))], length: 10))
        assertParallel(axis.direction, SIMD3(0, 1, 0), "runs along the edge")
        XCTAssertEqual(axis.distance(to: SIMD3(0, 99, 0)), 0, accuracy: 1e-9)
    }

    func testOnePlanarFaceDerivesPerpendicularThroughIt() throws {
        let axis = try XCTUnwrap(EditorViewModel.deriveAxis(
            from: [.planarFace(origin: SIMD3(2, 3, 0), normal: SIMD3(0, 0, 1))], length: 10))
        assertParallel(axis.direction, SIMD3(0, 0, 1), "runs along the face normal")
        XCTAssertEqual(axis.origin, SIMD3(2, 3, 0), "anchored at the picked face")
    }

    func testOneCylindricalFaceUsesItsOwnFittedAxis() throws {
        let axis = try XCTUnwrap(EditorViewModel.deriveAxis(
            from: [.cylindrical(origin: SIMD3(1, 0, 1), direction: SIMD3(0, 5, 0), length: 7)],
            length: 10))
        assertParallel(axis.direction, SIMD3(0, 1, 0))
        XCTAssertEqual(axis.distance(to: SIMD3(1, 42, 1)), 0, accuracy: 1e-9,
                       "the cylinder's own axis line is preserved")
    }

    func testTwoPlanarFacesDeriveTheirIntersectionLine() throws {
        // z = 0 and x = 0 meet along the Y axis.
        let axis = try XCTUnwrap(EditorViewModel.deriveAxis(from: [
            .planarFace(origin: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1)),
            .planarFace(origin: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0)),
        ], length: 10))
        assertParallel(axis.direction, SIMD3(0, 1, 0))
        XCTAssertEqual(axis.distance(to: SIMD3(0, 9, 0)), 0, accuracy: 1e-9)
    }

    /// Parallel planes have no intersection line — the tool must report that
    /// rather than emit a NaN axis.
    func testTwoParallelFacesDeriveNothing() {
        XCTAssertNil(EditorViewModel.deriveAxis(from: [
            .planarFace(origin: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1)),
            .planarFace(origin: SIMD3(0, 0, 5), normal: SIMD3(0, 0, 1)),
        ], length: 10))
    }

    /// Only the two-planes pairing is a valid 2-pick construction; mixing an
    /// edge in must not silently fall back to using just the first pick.
    func testTwoMixedPicksDeriveNothing() {
        XCTAssertNil(EditorViewModel.deriveAxis(from: [
            .planarFace(origin: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1)),
            .edge(start: SIMD3(0, 0, 0), end: SIMD3(1, 0, 0)),
        ], length: 10))
    }

    /// Length is the display extent only — it must never move or rotate the
    /// axis line itself.
    func testLengthSetsTheDrawnExtentWithoutMovingTheAxis() throws {
        let pick: [Pick] = [.edge(start: SIMD3(0, 0, 0), end: SIMD3(0, 2, 0))]
        let short = try XCTUnwrap(EditorViewModel.deriveAxis(from: pick, length: 5))
        let long = try XCTUnwrap(EditorViewModel.deriveAxis(from: pick, length: 500))

        XCTAssertEqual(short.length, 5, accuracy: 1e-12)
        XCTAssertEqual(long.length, 500, accuracy: 1e-12)
        XCTAssertEqual(short.origin, long.origin)
        assertParallel(short.direction, long.direction)
        // Both still describe the same infinite line.
        XCTAssertEqual(long.distance(to: short.endpoints.start), 0, accuracy: 1e-9)
    }

    func testDegenerateEdgeDerivesNothing() {
        XCTAssertNil(EditorViewModel.deriveAxis(
            from: [.edge(start: SIMD3(1, 1, 1), end: SIMD3(1, 1, 1))], length: 10))
    }

    /// A non-finite reference must be refused, not propagated — the whole
    /// reason `ConstructionAxis.init` is failable.
    func testNonFiniteReferenceDerivesNothing() {
        XCTAssertNil(EditorViewModel.deriveAxis(
            from: [.planarFace(origin: SIMD3(.nan, 0, 0), normal: SIMD3(0, 0, 1))], length: 10))
        XCTAssertNil(EditorViewModel.deriveAxis(
            from: [.planarFace(origin: SIMD3(0, 0, 0), normal: SIMD3(.infinity, 0, 0))], length: 10))
    }

    /// The drawn segment straddles the origin, so an axis stays visible when
    /// the user picks a face in the middle of a part.
    func testDrawnSegmentIsCentredOnTheOrigin() throws {
        let axis = try XCTUnwrap(EditorViewModel.deriveAxis(
            from: [.planarFace(origin: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0))], length: 10))
        let (start, end) = axis.endpoints
        XCTAssertEqual(start.y, -5, accuracy: 1e-9)
        XCTAssertEqual(end.y, 5, accuracy: 1e-9)
    }

    /// Round-trips through the document encoding used by `PersistedAxis`.
    func testAxisSurvivesACodableRoundTrip() throws {
        let axis = try XCTUnwrap(ConstructionAxis(
            origin: SIMD3(1, 2, 3), direction: SIMD3(0, 0, 4),
            length: 12, name: "Spindle", isHidden: true))
        let data = try JSONEncoder().encode(axis)
        let back = try JSONDecoder().decode(ConstructionAxis.self, from: data)

        XCTAssertEqual(back.id, axis.id)
        XCTAssertEqual(back.origin, axis.origin)
        XCTAssertEqual(back.direction, axis.direction)
        XCTAssertEqual(back.length, axis.length)
        XCTAssertEqual(back.name, "Spindle")
        XCTAssertTrue(back.isHidden)
    }
}

/// Circular patterns about a construction axis (spec §5.7 + §6.2). Before
/// axes existed, `PatternSpec` had no centre and every circular pattern spun
/// about the world origin; these pin both the new behaviour and the
/// back-compatibility of the old one.
final class PatternAxisTests: XCTestCase {

    /// A spec written before `center` existed must still decode, and must
    /// still mean "about the origin" — anything else silently moves every
    /// circular pattern in every saved document.
    func testSpecWithoutCenterDecodesToTheOrigin() throws {
        let legacy = """
        {"kind":"circular","axis":[0,1,0],"count":4,
         "spacing":0,"totalAngle":6.283185307179586,"rotateInstances":true}
        """.data(using: .utf8)!
        let spec = try JSONDecoder().decode(PatternSpec.self, from: legacy)

        XCTAssertEqual(spec.center, .zero)
        XCTAssertEqual(spec.count, 4)
        XCTAssertEqual(spec.kind, .circular)
    }

    func testSpecRoundTripsItsCenter() throws {
        let spec = PatternSpec(kind: .circular, axis: SIMD3(0, 1, 0),
                               center: SIMD3(5, 0, -3), count: 6,
                               totalAngle: .pi, rotateInstances: true)
        let back = try JSONDecoder().decode(
            PatternSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(back.center, SIMD3(5, 0, -3))
        XCTAssertEqual(back.axis, SIMD3(0, 1, 0))
    }

    /// An off-origin centre is the whole point: instances must orbit the axis,
    /// not the world origin.
    /// `Transform3D` exposes a matrix, not a point-apply.
    private func apply(_ t: Transform3D, _ p: SIMD3<Double>) -> SIMD3<Double> {
        let v = t.matrix * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    func testInstancesOrbitTheGivenCenterNotTheOrigin() {
        let center = SIMD3<Double>(10, 0, 0)
        let transforms = PatternKit.circularTransforms(
            center: center, axis: SIMD3(0, 1, 0), count: 4,
            totalAngle: 2 * .pi, rotateInstances: true)

        XCTAssertEqual(transforms.count, 4)
        // A point sitting on the centre line stays put under every instance;
        // if the rotation used the origin instead, it would sweep a circle.
        let onAxis = SIMD3<Double>(10, 7, 0)
        for t in transforms {
            let moved = apply(t, onAxis)
            XCTAssertEqual(simd_length(moved - onAxis), 0, accuracy: 1e-9,
                           "a point on the axis must be fixed by the rotation")
        }
    }

    /// Quarter turns about a construction axis land where hand-computation says.
    func testQuarterTurnsAboutAnOffsetAxis() throws {
        let axis = try XCTUnwrap(ConstructionAxis(
            origin: SIMD3(2, 0, 0), direction: SIMD3(0, 1, 0)))
        let transforms = PatternKit.circularTransforms(
            center: axis.origin, axis: axis.direction, count: 4,
            totalAngle: 2 * .pi, rotateInstances: true)

        // Start 1 unit +X of the axis; quarter turns walk it around a radius-1
        // circle centred on (2, 0, 0).
        let start = SIMD3<Double>(3, 0, 0)
        for t in transforms {
            let p = apply(t, start)
            XCTAssertEqual(simd_length(SIMD2(p.x - 2, p.z)), 1, accuracy: 1e-9,
                           "every instance stays on the radius-1 circle")
            XCTAssertEqual(p.y, 0, accuracy: 1e-9, "rotation about Y keeps height")
        }
    }
}
