//
//  ConstructionAxisTests.swift
//  openshape3dTests
//
//  Spec §6.2 (Construction axis) — covers all five axis tools the corpus lists,
//  as pure geometry. Axes feed Revolve, circular patterns and transforms.
//

import XCTest
import simd
@testable import openshape3d

final class ConstructionAxisTests: XCTestCase {

    private func assertParallel(_ a: SIMD3<Double>, _ b: SIMD3<Double>,
                                _ message: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        // Direction sign is arbitrary for an axis, so compare |cos|.
        XCTAssertEqual(abs(simd_dot(simd_normalize(a), simd_normalize(b))), 1,
                       accuracy: 1e-6, message, file: file, line: line)
    }

    // MARK: Axis Through 2 Points

    func testAxisThroughTwoPoints() throws {
        let axis = try XCTUnwrap(ConstructionAxisKit.through(SIMD3(1, 2, 3), SIMD3(1, 8, 3)))
        assertParallel(axis.direction, SIMD3(0, 1, 0), "axis runs point-to-point")
        XCTAssertEqual(axis.distance(to: SIMD3(1, 5, 3)), 0, accuracy: 1e-9,
                       "a point between them lies on the axis")
        XCTAssertEqual(axis.distance(to: SIMD3(4, 5, 3)), 3, accuracy: 1e-9)
    }

    func testCoincidentPointsCannotDefineAnAxis() {
        XCTAssertNil(ConstructionAxisKit.through(SIMD3(1, 1, 1), SIMD3(1, 1, 1)),
                     "degenerate selection must be refused, not produce NaNs")
    }

    // MARK: Axis Along Edge

    func testAxisAlongEdgeIsCentredOnTheEdge() throws {
        let start = SIMD3<Double>(0, 0, 0), end = SIMD3<Double>(10, 0, 0)
        let axis = try XCTUnwrap(ConstructionAxisKit.alongEdge(start: start, end: end))
        assertParallel(axis.direction, SIMD3(1, 0, 0), "axis follows the edge")
        XCTAssertEqual(axis.origin.x, 5, accuracy: 1e-9, "centred on the edge midpoint")
        XCTAssertEqual(axis.length, 10, accuracy: 1e-9, "sized to the edge")
    }

    // MARK: Axis Perpendicular to Face at Point

    func testAxisPerpendicularToFace() throws {
        let axis = try XCTUnwrap(ConstructionAxisKit.perpendicular(
            toFaceNormal: SIMD3(0, 0, 5), at: SIMD3(2, 3, 0)))
        assertParallel(axis.direction, SIMD3(0, 0, 1), "axis follows the face normal")
        XCTAssertEqual(axis.origin, SIMD3(2, 3, 0), "anchored at the picked point")
        XCTAssertEqual(simd_length(axis.direction), 1, accuracy: 1e-12, "unit direction")
    }

    // MARK: Axis Through 2 Planes

    func testAxisFromTwoPlaneIntersection() throws {
        // z = 0 and x = 0 meet along the Y axis.
        let axis = try XCTUnwrap(ConstructionAxisKit.intersection(
            planeAOrigin: SIMD3(0, 0, 0), planeANormal: SIMD3(0, 0, 1),
            planeBOrigin: SIMD3(0, 0, 0), planeBNormal: SIMD3(1, 0, 0)))
        assertParallel(axis.direction, SIMD3(0, 1, 0), "intersection line is the Y axis")
        XCTAssertEqual(axis.distance(to: SIMD3(0, 7, 0)), 0, accuracy: 1e-9)
    }

    func testOffsetPlanesStillIntersectAtTheRightLine() throws {
        // z = 4 and x = 2 meet along the line (2, t, 4).
        let axis = try XCTUnwrap(ConstructionAxisKit.intersection(
            planeAOrigin: SIMD3(0, 0, 4), planeANormal: SIMD3(0, 0, 1),
            planeBOrigin: SIMD3(2, 0, 0), planeBNormal: SIMD3(1, 0, 0)))
        assertParallel(axis.direction, SIMD3(0, 1, 0), "still runs along Y")
        XCTAssertEqual(axis.distance(to: SIMD3(2, -5, 4)), 0, accuracy: 1e-9,
                       "the line passes through x=2, z=4")
    }

    func testParallelPlanesHaveNoAxis() {
        XCTAssertNil(ConstructionAxisKit.intersection(
            planeAOrigin: SIMD3(0, 0, 0), planeANormal: SIMD3(0, 0, 1),
            planeBOrigin: SIMD3(0, 0, 5), planeBNormal: SIMD3(0, 0, 1)),
            "parallel planes define no unique line — must be refused")
    }

    // MARK: Axis of Cylinder / Cone

    func testAxisOfCylinderIsRecoveredFromSurfaceSamples() throws {
        // Cylinder of radius 4 about the line x = 3, z = -2, running along Y.
        let centre = SIMD2<Double>(3, -2)
        let radius = 4.0
        var points = [SIMD3<Double>]()
        var normals = [SIMD3<Double>]()
        for i in 0..<8 {
            let t = Double(i) / 8 * 2 * .pi
            let n = SIMD3(cos(t), 0, sin(t))                 // radial, ⟂ to the axis
            points.append(SIMD3(centre.x + cos(t) * radius,
                                Double(i),                    // vary along the axis
                                centre.y + sin(t) * radius))
            normals.append(n)
        }

        let axis = try XCTUnwrap(ConstructionAxisKit.axisOfRevolution(
            points: points, normals: normals))
        assertParallel(axis.direction, SIMD3(0, 1, 0), "cylinder axis runs along Y")

        // Every sample must sit one radius away from the recovered axis.
        for p in points {
            XCTAssertEqual(axis.distance(to: p), radius, accuracy: 1e-6,
                           "axis is centred, so all samples are equidistant")
        }
    }

    func testPlanarFaceHasNoAxisOfRevolution() {
        // All normals parallel — a flat face, not a cylinder.
        let points = (0..<4).map { SIMD3<Double>(Double($0), 0, 0) }
        let normals = [SIMD3<Double>](repeating: SIMD3(0, 1, 0), count: 4)
        XCTAssertNil(ConstructionAxisKit.axisOfRevolution(points: points, normals: normals),
                     "a planar face must not yield an axis")
    }
}
