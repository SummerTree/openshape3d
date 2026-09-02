//
//  PolygonTriangulatorTests.swift
//  openshape3dTests
//
//  The sketch fill's triangulation: exact areas, the right triangle counts,
//  holes honoured, and a thousand-vertex outline in milliseconds — the case
//  that wedged the app when it was a mesh CSG.
//

import XCTest
import simd
@testable import openshape3d

final class PolygonTriangulatorTests: XCTestCase {

    private func area(_ v: [SIMD2<Double>], _ t: [Int]) -> Double {
        var a = 0.0
        for i in stride(from: 0, to: t.count - 2, by: 3) {
            let p = v[t[i]], q = v[t[i + 1]], r = v[t[i + 2]]
            a += ((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)) / 2
        }
        return a
    }

    private func square(_ c: SIMD2<Double>, _ half: Double, cw: Bool = false) -> [SIMD2<Double>] {
        let s = [SIMD2(c.x - half, c.y - half), SIMD2(c.x + half, c.y - half),
                 SIMD2(c.x + half, c.y + half), SIMD2(c.x - half, c.y + half)]
        return cw ? s.reversed() : s
    }

    func testASquareIsTwoCounterClockwiseTriangles() {
        let (v, t) = PolygonTriangulator.triangulate(outer: square(.zero, 5), holes: [])
        XCTAssertEqual(t.count, 6)
        XCTAssertEqual(area(v, t), 100, accuracy: 1e-12, "signed area is positive: every triangle CCW")
    }

    /// A clockwise outer loop is normalised; the answer is the same.
    func testWindingIsNormalised() {
        let (v, t) = PolygonTriangulator.triangulate(outer: square(.zero, 5, cw: true), holes: [])
        XCTAssertEqual(area(v, t), 100, accuracy: 1e-12)
    }

    /// Outer 20×20 with a 4×4 hole: n + 2h − 2 = 8 + 2 − 2 = 8 triangles whose
    /// areas sum to 400 − 16, none of them inside the hole.
    func testAHoleIsCutOut() {
        let (v, t) = PolygonTriangulator.triangulate(outer: square(.zero, 10), holes: [square(.zero, 2)])
        XCTAssertEqual(t.count / 3, 8, "n + 2h − 2 triangles")
        XCTAssertEqual(area(v, t), 400 - 16, accuracy: 1e-9)
        for i in stride(from: 0, to: t.count - 2, by: 3) {
            let c = (v[t[i]] + v[t[i + 1]] + v[t[i + 2]]) / 3
            XCTAssertFalse(abs(c.x) < 2 && abs(c.y) < 2, "a triangle's centroid lies in the hole: \(c)")
        }
    }

    /// Two holes, the right one bridged first; a concave (L-shaped) outer.
    func testTwoHolesInAConcaveOutline() {
        let L: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 10), SIMD2(10, 10), SIMD2(10, 30), SIMD2(0, 30)]
        let holes = [square(SIMD2(5, 20), 2), square(SIMD2(20, 5), 2, cw: true)]
        let (v, t) = PolygonTriangulator.triangulate(outer: L, holes: holes)
        XCTAssertEqual(area(v, t), 500 - 16 - 16, accuracy: 1e-9)
        XCTAssertEqual(t.count / 3, (6 + 4 + 4) + 2 * 2 - 2, "n + 2h − 2 over all 14 vertices")
    }

    /// The case that hung the app: a 1,152-vertex smooth outline (a cycloidal
    /// cam sampled the way a 72-point spline tessellates) with a 64-gon bore.
    /// Area exact to the polygon, and fast.
    func testAThousandVertexOutlineWithABoreIsFast() {
        var outer: [SIMD2<Double>] = []
        let n = 1152
        for i in 0..<n {
            let phi = Double(i) / Double(n) * 2 * .pi
            let r = phi <= .pi ? 20 + 10 * (phi / .pi - sin(2 * phi) / (2 * .pi)) : (phi <= 1.5 * .pi ? 30 : 30 - 10 * ((phi - 1.5 * .pi) / (0.5 * .pi) - sin(2 * .pi * (phi - 1.5 * .pi) / (0.5 * .pi)) / (2 * .pi)))
            outer.append(SIMD2(r * cos(phi), r * sin(phi)))
        }
        let bore = (0..<64).map { i -> SIMD2<Double> in
            let a = Double(i) / 64 * 2 * .pi
            return SIMD2(5 * cos(a), 5 * sin(a))
        }
        let start = Date()
        let (v, t) = PolygonTriangulator.triangulate(outer: outer, holes: [bore])
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(t.count / 3, n + 64 + 2 - 2)
        XCTAssertEqual(area(v, t), Profile.signedArea(outer) - Profile.signedArea(bore), accuracy: 1e-6)
        XCTAssertLessThan(seconds, 0.5, "triangulated in \(seconds) s")
    }
}
