//
//  ExtrudeEndKitTests.swift
//  openshape3dTests
//
//  Through All and Up To Next resolved to distances from the bodies in the
//  document — pure geometry on evaluated bodies, no session.
//

import XCTest
import simd
@testable import openshape3d

final class ExtrudeEndKitTests: XCTestCase {

    private final class RevisionSource {
        var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    /// A box body from the feature graph, placed by translation.
    private func box(_ w: Double, _ d: Double, _ h: Double, at t: SIMD3<Double>) throws -> Body {
        let id = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: FeatureID(), name: "Box",
                        kind: .primitive(spec: .box(width: w, depth: d, height: h),
                                         placement: Transform3D(translation: t)),
                        outputBodyIDs: [id]),
        ])
        let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                                    nextRevision: RevisionSource().next)
        return try XCTUnwrap(result.bodies.first { $0.id == id })
    }

    private func worldBounds(_ body: Body) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        try! XCTUnwrap(MeasureKit.boundingBox(bodies: [body]))
    }

    func testRayTriangleHitsAndMisses() {
        let a = SIMD3(0.0, 0, 0), b = SIMD3(10.0, 0, 0), c = SIMD3(0.0, 10, 0)
        let hit = ExtrudeEndKit.rayTriangle(origin: SIMD3(2, 2, -5), direction: SIMD3(0, 0, 1), a: a, b: b, c: c)
        XCTAssertEqual(try XCTUnwrap(hit), 5, accuracy: 1e-9)
        XCTAssertNil(ExtrudeEndKit.rayTriangle(origin: SIMD3(8, 8, -5), direction: SIMD3(0, 0, 1), a: a, b: b, c: c),
                     "outside the triangle")
        XCTAssertNil(ExtrudeEndKit.rayTriangle(origin: SIMD3(2, 2, 5), direction: SIMD3(0, 0, 1), a: a, b: b, c: c),
                     "behind the ray")
    }

    func testUpToNextStopsAtTheFirstFaceAhead() throws {
        let near = try box(10, 10, 10, at: SIMD3(0, 0, 0))
        let far = try box(10, 10, 10, at: SIMD3(40, 0, 0))
        let nb = worldBounds(near)
        // A sketch on the near box's +x face, extruding along +x: the next
        // face is the far box's -x face.
        let plane = SketchPlane(origin: SIMD3(nb.max.x, 0, 0), xAxis: SIMD3(0, 0, -1), yAxis: SIMD3(0, 1, 0))
        let d = try XCTUnwrap(ExtrudeEndKit.resolve(.upToNext, plane: plane, seed: .zero,
                                                    direction: plane.normal, symmetric: false,
                                                    bodies: [near, far]))
        let fb = worldBounds(far)
        XCTAssertEqual(d, fb.min.x - nb.max.x, accuracy: 1e-6, "up to the far box's near face")
        // Nothing ahead in -x from the far side of the far box → nil.
        let outward = SketchPlane(origin: SIMD3(fb.max.x, 0, 0), xAxis: SIMD3(0, 0, -1), yAxis: SIMD3(0, 1, 0))
        XCTAssertNil(ExtrudeEndKit.resolve(.upToNext, plane: outward, seed: .zero, direction: outward.normal,
                                           symmetric: false, bodies: [near, far]))
    }

    func testUpToNextSkipsTheSketchsOwnFace() throws {
        let body = try box(10, 10, 10, at: .zero)
        let b = worldBounds(body)
        // Sketch on the -x face, cutting into the box (+x): the "next" face
        // is the +x face, not the one the sketch is on.
        let plane = SketchPlane(origin: SIMD3(b.min.x, 0, 0), xAxis: SIMD3(0, 0, -1), yAxis: SIMD3(0, 1, 0))
        let d = try XCTUnwrap(ExtrudeEndKit.resolve(.upToNext, plane: plane, seed: .zero,
                                                    direction: plane.normal, symmetric: false, bodies: [body]))
        XCTAssertEqual(d, b.max.x - b.min.x, accuracy: 1e-6)
    }

    func testThroughAllClearsEveryBodyAhead() throws {
        let near = try box(10, 10, 10, at: .zero)
        let far = try box(10, 10, 10, at: SIMD3(40, 0, 0))
        let nb = worldBounds(near), fb = worldBounds(far)
        let plane = SketchPlane(origin: SIMD3(nb.min.x, 0, 0), xAxis: SIMD3(0, 0, -1), yAxis: SIMD3(0, 1, 0))
        let d = try XCTUnwrap(ExtrudeEndKit.resolve(.throughAll, plane: plane, seed: .zero,
                                                    direction: plane.normal, symmetric: false,
                                                    bodies: [near, far]))
        XCTAssertEqual(d, (fb.max.x - nb.min.x) + ExtrudeEndKit.throughAllMargin, accuracy: 1e-6,
                       "past the farthest face with the margin")
        // Symmetric: reaches the farther side in both directions.
        let mid = SketchPlane(origin: SIMD3(0, 0, 0), xAxis: SIMD3(0, 0, -1), yAxis: SIMD3(0, 1, 0))
        let s = try XCTUnwrap(ExtrudeEndKit.resolve(.throughAll, plane: mid, seed: .zero,
                                                    direction: mid.normal, symmetric: true, bodies: [near, far]))
        XCTAssertEqual(s, fb.max.x + ExtrudeEndKit.throughAllMargin, accuracy: 1e-6)
    }

    /// The rib case: a sketch ON one wall's inner face, extruding across the
    /// gap to the other wall of the SAME body (a base with two walls, as one
    /// union). Up To Next must skip the face the sketch sits on and stop at
    /// the far wall.
    func testUpToNextAcrossAGapInOneBody() throws {
        let base = try box(100, 30, 20, at: SIMD3(50, 10, -15))
        let leftWall = try box(10, 30, 40, at: SIMD3(5, 40, -15))
        let rightWall = try box(10, 30, 40, at: SIMD3(95, 40, -15))
        let lb = worldBounds(leftWall), rb = worldBounds(rightWall)
        let plane = SketchPlane(origin: SIMD3(lb.max.x, 0, 0), xAxis: SIMD3(0, 0, -1), yAxis: SIMD3(0, 1, 0))
        // Seed at the middle of the wall's face (u = -z, v = y on this plane).
        let seed = SIMD2(-(rb.min.z + rb.max.z) / 2, (rb.min.y + rb.max.y) / 2)
        XCTAssertGreaterThan(rb.min.x, lb.max.x, "a gap between the walls")
        let d = try XCTUnwrap(ExtrudeEndKit.resolve(.upToNext, plane: plane, seed: seed,
                                                    direction: plane.normal, symmetric: false,
                                                    bodies: [base, leftWall, rightWall]))
        XCTAssertEqual(d, rb.min.x - lb.max.x, accuracy: 1e-6, "across the gap to the far wall")
    }

    func testBlindResolvesToNothing() throws {
        let body = try box(10, 10, 10, at: .zero)
        XCTAssertNil(ExtrudeEndKit.resolve(.blind, plane: .ground, seed: .zero, direction: SIMD3(0, 1, 0),
                                           symmetric: false, bodies: [body]))
    }
}
