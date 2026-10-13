//
//  ConstructionPlaneKitTests.swift
//  openshape3dTests
//
//  Construct ▸ Plane (spec §6.1): each of the seven constructions as pure
//  geometry, the slot checks `derive` applies, and the polyline helpers the
//  On Curve construction samples. Plus the explicit Construct ▸ Axis entries
//  `EditorViewModel.deriveAxis` gained alongside it.
//

import XCTest
import simd
@testable import openshape3d

final class ConstructionPlaneKitTests: XCTestCase {

    private let up = SIMD3<Double>(0, 1, 0)

    private func assertParallel(_ a: SIMD3<Double>, _ b: SIMD3<Double>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(abs(simd_dot(simd_normalize(a), simd_normalize(b))), 1, accuracy: 1e-9, file: file, line: line)
    }

    private func assertOnPlane(_ p: SIMD3<Double>, _ plane: SketchPlane, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(simd_dot(p - plane.origin, simd_normalize(plane.normal)), 0, accuracy: 1e-9, file: file, line: line)
    }

    func testOffsetMovesAlongTheNormal() throws {
        let plane = try XCTUnwrap(ConstructionPlaneKit.offset(origin: SIMD3(1, 2, 3), normal: up * 4, distance: 5))
        assertParallel(plane.normal, up)
        XCTAssertEqual(plane.origin.y, 7, accuracy: 1e-12)
        XCTAssertNil(ConstructionPlaneKit.offset(origin: .zero, normal: .zero, distance: 1))
    }

    func testMidplaneOfParallelFacesSitsHalfway() throws {
        // The top and bottom of a 10 mm slab, facing away from each other.
        let plane = try XCTUnwrap(ConstructionPlaneKit.midplane(
            aOrigin: SIMD3(0, 10, 0), aNormal: up,
            bOrigin: SIMD3(4, 0, 2), bNormal: -up))
        assertParallel(plane.normal, up)
        XCTAssertEqual(plane.origin.y, 5, accuracy: 1e-9)
        XCTAssertNil(ConstructionPlaneKit.midplane(
            aOrigin: .zero, aNormal: up, bOrigin: SIMD3(3, 0, 0), bNormal: up),
            "Coincident planes have nothing between them")
    }

    func testMidplaneOfACornerIsItsMirrorPlane() throws {
        // Two faces of a box corner along the Z axis: +X and +Y.
        let plane = try XCTUnwrap(ConstructionPlaneKit.midplane(
            aOrigin: SIMD3(5, 2, 1), aNormal: SIMD3(1, 0, 0),
            bOrigin: SIMD3(2, 5, 1), bNormal: SIMD3(0, 1, 0)))
        // The symmetry plane contains the corner line (x = y = 0)…
        assertOnPlane(SIMD3(0, 0, 7), plane)
        // …and swaps the two faces' normals.
        let n = simd_normalize(plane.normal)
        let mirroredX = SIMD3<Double>(1, 0, 0) - 2 * simd_dot(SIMD3(1, 0, 0), n) * n
        XCTAssertEqual(simd_length(mirroredX - SIMD3(0, 1, 0)), 0, accuracy: 1e-9)
    }

    func testThreePoints() throws {
        let a = SIMD3<Double>(0, 0, 0), b = SIMD3<Double>(10, 0, 0), c = SIMD3<Double>(0, 0, 10)
        let plane = try XCTUnwrap(ConstructionPlaneKit.throughPoints(a, b, c))
        assertParallel(plane.normal, up)
        for p in [a, b, c] { assertOnPlane(p, plane) }
        XCTAssertNil(ConstructionPlaneKit.throughPoints(a, b, SIMD3(20, 0, 0)), "Collinear")
        XCTAssertNil(ConstructionPlaneKit.throughPoints(a, a, c), "Coincident")
    }

    func testOnCurveIsNormalToTheTangent() throws {
        // A quarter circle of radius 10 in the ground plane, as a polyline.
        let points = (0...64).map { i -> SIMD3<Double> in
            let t = Double(i) / 64 * .pi / 2
            return SIMD3(10 * cos(t), 0, 10 * sin(t))
        }
        let plane = try XCTUnwrap(ConstructionPlaneKit.onCurve(points, fraction: 0.5))
        // Halfway along, at 45°: the tangent is (-1, 0, 1)/√2.
        XCTAssertEqual(simd_length(plane.origin - SIMD3(10 * cos(.pi / 4), 0, 10 * sin(.pi / 4))), 0, accuracy: 0.05)
        assertParallel(plane.normal, SIMD3(-1, 0, 1))
        let start = try XCTUnwrap(ConstructionPlaneKit.onCurve(points, fraction: 0))
        XCTAssertEqual(simd_length(start.origin - SIMD3(10, 0, 0)), 0, accuracy: 1e-9)
        XCTAssertNil(ConstructionPlaneKit.onCurve([SIMD3(1, 1, 1)], fraction: 0.5))
    }

    func testPerpendicularToEdgeAtPoint() throws {
        let plane = try XCTUnwrap(ConstructionPlaneKit.perpendicular(
            toEdgeFrom: SIMD3(0, 0, 0), to: SIMD3(0, 0, 20), at: SIMD3(3, 4, 5)))
        assertParallel(plane.normal, SIMD3(0, 0, 1))
        assertOnPlane(SIMD3(3, 4, 5), plane)
    }

    func testThroughEdgeAtAngle() throws {
        // The edge along X on top of a box; reference face is the top (+Y).
        let start = SIMD3<Double>(0, 10, 0), end = SIMD3<Double>(20, 10, 0)
        let flat = try XCTUnwrap(ConstructionPlaneKit.throughEdge(
            from: start, to: end, referenceNormal: up, degrees: 0))
        assertParallel(flat.normal, up)
        let tilted = try XCTUnwrap(ConstructionPlaneKit.throughEdge(
            from: start, to: end, referenceNormal: up, degrees: 90))
        assertParallel(tilted.normal, SIMD3(0, 0, 1))
        let thirty = try XCTUnwrap(ConstructionPlaneKit.throughEdge(
            from: start, to: end, referenceNormal: up, degrees: 30))
        XCTAssertEqual(abs(simd_dot(simd_normalize(thirty.normal), up)), cos(.pi / 6), accuracy: 1e-9)
        for plane in [flat, tilted, thirty] {
            assertOnPlane(start, plane)
            assertOnPlane(end, plane)
        }
        XCTAssertNil(ConstructionPlaneKit.throughEdge(
            from: .zero, to: SIMD3(0, 5, 0), referenceNormal: up, degrees: 10),
            "An edge along the reference normal can't lie in the reference plane")
    }

    func testParallelToFaceAtPoint() throws {
        let plane = try XCTUnwrap(ConstructionPlaneKit.parallel(toFaceNormal: SIMD3(1, 0, 0), at: SIMD3(7, 1, 1)))
        assertParallel(plane.normal, SIMD3(1, 0, 0))
        XCTAssertEqual(plane.origin.x, 7, accuracy: 1e-12)
    }

    func testDeriveChecksEverySlot() throws {
        let face = ConstructionPick.face(origin: SIMD3(0, 10, 0), normal: up)
        let point = ConstructionPick.point(SIMD3(1, 2, 3))
        XCTAssertNotNil(ConstructionPlaneKit.derive(.parallelToFaceAtPoint, picks: [face, point],
                                                     offset: 0, degrees: 0, curveFraction: 0))
        XCTAssertNil(ConstructionPlaneKit.derive(.parallelToFaceAtPoint, picks: [point, face],
                                                  offset: 0, degrees: 0, curveFraction: 0),
                     "Slots are typed and ordered")
        XCTAssertNil(ConstructionPlaneKit.derive(.midplane, picks: [face],
                                                  offset: 0, degrees: 0, curveFraction: 0),
                     "Not every slot filled yet")
        let offset = try XCTUnwrap(ConstructionPlaneKit.derive(.offset, picks: [face],
                                                               offset: -4, degrees: 0, curveFraction: 0))
        XCTAssertEqual(offset.origin.y, 6, accuracy: 1e-12)
        for construction in PlaneConstruction.allCases {
            XCTAssertFalse(construction.slots.isEmpty)
            XCTAssertFalse(construction.title.isEmpty)
        }
    }

    func testPolylineOrdersScatteredSegments() throws {
        let p = (0...4).map { SIMD3<Double>(Double($0), 0, 0) }
        let segments = [(p[2], p[3]), (p[1], p[0]), (p[3], p[4]), (p[2], p[1])]
        let line = try XCTUnwrap(ConstructionPlaneKit.polyline(from: segments))
        XCTAssertEqual(line.count, 5)
        XCTAssertEqual(ConstructionPlaneKit.length(line), 4, accuracy: 1e-12)
        // The chain may come back in either direction.
        let fraction = ConstructionPlaneKit.fraction(of: SIMD3(3, 5, 0), along: line)
        XCTAssertEqual(line.first!.x == 0 ? fraction : 1 - fraction, 0.75, accuracy: 1e-12)
        XCTAssertNil(ConstructionPlaneKit.polyline(from: [(p[0], p[1]), (p[3], p[4])]), "Two separate pieces")
    }

    // MARK: - Construct ▸ Axis entries

    func testAxisThroughTwoPoints() throws {
        let picks: [EditorViewModel.AxisPick] = [.point(SIMD3(0, 0, 0)), .point(SIMD3(0, 0, 10))]
        let axis = try XCTUnwrap(EditorViewModel.deriveAxis(from: picks, construction: .twoPoints, length: 50))
        assertParallel(axis.direction, SIMD3(0, 0, 1))
        XCTAssertEqual(axis.length, 50)
        XCTAssertNil(EditorViewModel.deriveAxis(from: Array(picks.prefix(1)), construction: .twoPoints, length: 50))
        XCTAssertNil(EditorViewModel.deriveAxis(from: [picks[0], picks[0]], construction: .twoPoints, length: 50))
    }

    func testExplicitAxisNeedsExactlyItsReferences() {
        let face = EditorViewModel.AxisPick.planarFace(origin: .zero, normal: up)
        // Automatic reads one flat face as "perpendicular to face"; Through 2
        // Planes must wait for the second.
        XCTAssertNotNil(EditorViewModel.deriveAxis(from: [face], construction: .automatic, length: 10))
        XCTAssertNil(EditorViewModel.deriveAxis(from: [face], construction: .twoPlanes, length: 10))
        XCTAssertNotNil(EditorViewModel.deriveAxis(
            from: [face, .planarFace(origin: .zero, normal: SIMD3(1, 0, 0))],
            construction: .twoPlanes, length: 10))
        XCTAssertEqual(AxisConstruction.allCases.count, 6)
    }
}
