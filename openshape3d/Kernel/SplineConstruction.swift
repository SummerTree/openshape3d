//
//  SplineConstruction.swift
//  openshape3d
//
//  Sketch ▸ Spline (spec §1.4): the two ways the tool places a spline.
//
//  * **Fit** — the curve passes through every tapped point; the tapped points
//    ARE the entity's points (`SketchEntity.spline` interpolates them).
//  * **Control** — the tapped points are a control polygon the curve is
//    pulled toward but (except at an open spline's ends) does not touch: a
//    cubic B-spline, clamped at the ends when open, periodic when closed.
//    The sketch stores splines by their pass-through points, so a control
//    spline is committed as the fit points that reproduce its B-spline
//    (`fitPoints(control:closed:)`), sampled densely enough that the
//    interpolated curve stays within a hair of the B-spline.
//

import Foundation
import simd

nonisolated enum SplineType: String, CaseIterable, Sendable {
    case fit, control

    var title: String {
        switch self {
        case .fit: return "Fit Point"
        case .control: return "Control Point"
        }
    }
}

nonisolated enum SplineConstruction {

    /// Points along the cubic B-spline of `control`, `perSpan` per span.
    /// Fewer than three control points degenerate to the polygon itself
    /// (two points: a straight line, which is what a degree-reduced
    /// B-spline is).
    static func bSpline(
        control: [SIMD2<Double>], closed: Bool, perSpan: Int = 16
    ) -> [SIMD2<Double>] {
        let n = control.count
        guard n >= 3 else { return control }
        let steps = max(2, perSpan)
        if closed {
            // Uniform periodic cubic: one span per control point.
            var out: [SIMD2<Double>] = []
            for span in 0..<n {
                let p0 = control[span], p1 = control[(span + 1) % n]
                let p2 = control[(span + 2) % n], p3 = control[(span + 3) % n]
                for i in 0..<steps {
                    out.append(uniform(p0, p1, p2, p3, Double(i) / Double(steps)))
                }
            }
            return out
        }
        // Open: clamped uniform knots, so the curve starts and ends on the
        // first and last control points and leaves them along the polygon.
        let degree = min(3, n - 1)
        let knots = clampedKnots(count: n, degree: degree)
        let spans = n - degree
        var out: [SIMD2<Double>] = []
        let total = spans * steps
        for i in 0...total {
            let u = Double(i) / Double(total) * Double(spans)
            out.append(deBoor(control, knots: knots, degree: degree, u: u))
        }
        return out
    }

    /// Fit points whose interpolating spline reproduces the B-spline of
    /// `control`: the B-spline sampled at `perSpan` points per span.
    ///
    /// An open fit spline's first and last spans are drawn straight (see
    /// `CatmullRomBezier`, which the kernel mirrors), so the open case adds a
    /// sample a hair inside each end: the straight piece shrinks to a sliver
    /// and the curve leaves its end point along the B-spline's tangent.
    static func fitPoints(control: [SIMD2<Double>], closed: Bool, perSpan: Int = 6) -> [SIMD2<Double>] {
        guard control.count >= 3 else { return control }
        if closed {
            var points = bSpline(control: control, closed: true, perSpan: perSpan)
            if let first = points.first, let last = points.last, simd_length(first - last) < 1e-12 {
                points.removeLast()
            }
            return points
        }
        let degree = min(3, control.count - 1)
        let knots = clampedKnots(count: control.count, degree: degree)
        let spans = Double(control.count - degree)
        let steps = max(2, perSpan) * (control.count - degree)
        var params = (0...steps).map { Double($0) / Double(steps) * spans }
        let sliver = spans / Double(steps) / 16
        params.insert(sliver, at: 1)
        params.insert(spans - sliver, at: params.count - 1)
        return params.map { deBoor(control, knots: knots, degree: degree, u: $0) }
    }

    /// The entity a finished placement commits.
    static func entity(
        id: UUID, type: SplineType, points: [SIMD2<Double>], closed: Bool
    ) -> SketchEntity? {
        guard points.count >= 2 else { return nil }
        if points.count == 2 {
            return .line(id: id, a: points[0], b: points[1])
        }
        let fit = type == .fit ? points : fitPoints(control: points, closed: closed)
        return .spline(id: id, points: fit, closed: closed)
    }

    // MARK: - Evaluation

    private static func uniform(
        _ p0: SIMD2<Double>, _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>, _ t: Double
    ) -> SIMD2<Double> {
        let t2 = t * t, t3 = t2 * t
        let b0 = (1 - t) * (1 - t) * (1 - t) / 6
        let b1 = (3 * t3 - 6 * t2 + 4) / 6
        let b2 = (-3 * t3 + 3 * t2 + 3 * t + 1) / 6
        let b3 = t3 / 6
        return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3
    }

    private static func clampedKnots(count n: Int, degree p: Int) -> [Double] {
        let interior = n - p - 1
        return Array(repeating: 0, count: p + 1)
            + (0..<max(0, interior)).map { Double($0 + 1) }
            + Array(repeating: Double(interior + 1), count: p + 1)
    }

    private static func deBoor(
        _ control: [SIMD2<Double>], knots: [Double], degree p: Int, u: Double
    ) -> SIMD2<Double> {
        let n = control.count
        // The knot span containing u (the last span owns its right end).
        var k = p
        while k < n - 1 && u >= knots[k + 1] { k += 1 }
        var d = (0...p).map { control[$0 + k - p] }
        if p == 0 { return d[0] }
        for r in 1...p {
            for j in stride(from: p, through: r, by: -1) {
                let i = j + k - p
                let denom = knots[i + p - r + 1] - knots[i]
                let alpha = denom > 1e-12 ? (u - knots[i]) / denom : 0
                d[j] = d[j - 1] * (1 - alpha) + d[j] * alpha
            }
        }
        return d[p]
    }
}
