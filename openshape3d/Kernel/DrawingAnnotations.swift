//
//  DrawingAnnotations.swift
//  openshape3d
//
//  Dimensions and notes placed on a drawing (spec §15). Each belongs to a
//  view and keeps its points in that view's own coordinates (model mm in
//  the view's plane), so it moves and rescales with the view and measures
//  the model, whatever the sheet scale. A dimension snaps to the corners
//  and line ends of the view it is placed on; a note is free text with an
//  optional leader to a point of the view.
//

import Foundation
import simd

nonisolated struct DrawingAnnotation: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A point-to-point distance.
        case linear
        case note
        /// A circle's diameter or an arc's radius: `a` the centre, `b` the
        /// point of the outline the leader touches.
        case diameter, radius
    }

    enum Orientation: String, Codable, CaseIterable, Sendable {
        case horizontal, vertical, aligned

        var title: String {
            switch self {
            case .horizontal: "Horizontal"
            case .vertical: "Vertical"
            case .aligned: "Aligned"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// The view it belongs to (`DrawingSheet.viewKey`).
    var view: String
    /// A dimension's two points; a note's text position (`a`) and leader
    /// tip (`b`). View coordinates.
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var orientation: Orientation = .aligned
    /// How far the dimension line stands off the measured points, sheet mm:
    /// + above / right (along the line's left-hand normal when aligned).
    var offset = 8.0
    /// A note's text (lines split on newlines).
    var text = ""
    /// A note points at `b`.
    var leader = false

    init(kind: Kind, view: String, a: SIMD2<Double>, b: SIMD2<Double>) {
        self.kind = kind
        self.view = view
        self.a = a
        self.b = b
    }

    private enum CodingKeys: String, CodingKey { case id, kind, view, a, b, orientation, offset, text, leader }

    // Tolerant of drawings saved by other builds.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .note
        view = try c.decodeIfPresent(String.self, forKey: .view) ?? ""
        a = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .a) ?? .zero
        b = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .b) ?? a
        orientation = (try? c.decodeIfPresent(Orientation.self, forKey: .orientation)) ?? .aligned
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 8
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        leader = try c.decodeIfPresent(Bool.self, forKey: .leader) ?? false
    }

    /// How the Dimensions & Notes list names it: "40 mm", "Ø8 mm", "R3 mm",
    /// "Note".
    @MainActor var listTitle: String {
        let value = { AppSettings.shared.unit.compactLengthString(fromMM: measured) }
        switch kind {
        case .linear: return value()
        case .diameter: return "Ø" + value()
        case .radius: return "R" + value()
        case .note: return "Note"
        }
    }

    /// The model distance a dimension shows, mm.
    var measured: Double {
        if kind == .diameter { return 2 * simd_distance(a, b) }
        if kind == .radius { return simd_distance(a, b) }
        switch orientation {
        case .horizontal: return abs(b.x - a.x)
        case .vertical: return abs(b.y - a.y)
        case .aligned: return simd_distance(a, b)
        }
    }
}

/// Where a placed view sits on the sheet: sheet = at + (view − min) × k.
nonisolated struct DrawingViewTransform: Equatable, Sendable {
    var at: SIMD2<Double>
    var min: SIMD2<Double>
    var k: Double

    func sheet(_ p: SIMD2<Double>) -> SIMD2<Double> { at + (p - min) * k }
    func view(_ s: SIMD2<Double>) -> SIMD2<Double> { min + (s - at) / k }
}

/// The drawing tools on the preview.
nonisolated enum DrawingTool: String, CaseIterable, Sendable {
    /// Drag views, dimensions and notes; tap one to select it.
    case move
    case dimension
    case note

    var title: String {
        switch self {
        case .move: "Move"
        case .dimension: "Dimension"
        case .note: "Note"
        }
    }
}

nonisolated enum DrawingAnnotationKit {
    /// How close, sheet mm, a tap must be to a corner or line end to snap.
    static let snapRadius = 3.0
    /// How close, sheet mm, a tap must be to an annotation's handle.
    static let handleRadius = 4.0

    /// The view under `point` and the point in it to measure from: the
    /// nearest corner or line end within `snapRadius`, else the point itself.
    /// The isometric is left out of dimensioning — its lengths are
    /// foreshortened — unless `pictorial`.
    static func pick(_ point: SIMD2<Double>, in layout: DrawingLayout, pictorial: Bool = false)
        -> (view: String, point: SIMD2<Double>, snapped: Bool)? {
        // The ends of long lines first; then any line end (a curve's samples).
        for points in [layout.strongSnapPoints, layout.snapPoints] {
            var best: (view: String, point: SIMD2<Double>, distance: Double)?
            for (key, frame) in layout.placedViews {
                guard pictorial || key != DrawingSheet.viewKey(.isometric),
                      let transform = layout.viewTransforms[key],
                      point.x >= frame.min.x - snapRadius, point.x <= frame.max.x + snapRadius,
                      point.y >= frame.min.y - snapRadius, point.y <= frame.max.y + snapRadius else { continue }
                for p in points[key] ?? [] {
                    let d = simd_distance(transform.sheet(p), point)
                    if d <= snapRadius, d < (best?.distance ?? .infinity) { best = (key, p, d) }
                }
            }
            if let best { return (best.view, best.point, true) }
        }
        // No corner near: the point itself, in the smallest view under it.
        guard let key = DrawingSheet.view(at: point, in: layout, slop: 0),
              pictorial || key != DrawingSheet.viewKey(.isometric),
              let transform = layout.viewTransforms[key] else { return nil }
        return (key, transform.view(point), false)
    }

    /// Whether a tap is near the end of a long line — a corner wins over the
    /// circle it may sit on.
    static func isNearStrongSnap(_ point: SIMD2<Double>, in layout: DrawingLayout) -> Bool {
        for (key, points) in layout.strongSnapPoints {
            guard let t = layout.viewTransforms[key] else { continue }
            if points.contains(where: { simd_distance(t.sheet($0), point) <= snapRadius }) { return true }
        }
        return false
    }

    /// Horizontal or vertical when the points nearly line up that way
    /// (within 15°), aligned otherwise.
    static func orientation(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> DrawingAnnotation.Orientation {
        let d = b - a
        let angle = atan2(abs(d.y), abs(d.x)) * 180 / .pi
        if angle <= 15 { return .horizontal }
        if angle >= 75 { return .vertical }
        return .aligned
    }

    /// A dimension's starting offset: 8 mm out from the view, on the side
    /// away from its middle, so it lands outside the part — above it, clear
    /// of the view's name too.
    static func defaultOffset(_ dim: DrawingAnnotation, transform: DrawingViewTransform,
                              frame: (min: SIMD2<Double>, max: SIMD2<Double>)) -> Double {
        let a = transform.sheet(dim.a), b = transform.sheet(dim.b)
        let mid = (a + b) / 2, centre = (frame.min + frame.max) / 2
        switch dim.orientation {
        case .horizontal:
            return mid.y >= centre.y ? 13 + (frame.max.y - Swift.max(a.y, b.y)) : -8 - (Swift.min(a.y, b.y) - frame.min.y)
        case .vertical:
            return mid.x >= centre.x ? 8 + (frame.max.x - Swift.max(a.x, b.x)) : -8 - (Swift.min(a.x, b.x) - frame.min.x)
        case .aligned:
            let u = simd_normalize(b - a), n = SIMD2(-u.y, u.x)
            return simd_dot(mid - centre, n) >= 0 ? 8 : -8
        }
    }

    /// The dimension line's two ends on the sheet (offset applied).
    static func dimensionLine(_ a: SIMD2<Double>, _ b: SIMD2<Double>,
                              orientation: DrawingAnnotation.Orientation, offset: Double)
        -> (SIMD2<Double>, SIMD2<Double>) {
        switch orientation {
        case .horizontal:
            let y = (offset >= 0 ? Swift.max(a.y, b.y) : Swift.min(a.y, b.y)) + offset
            return (SIMD2(a.x, y), SIMD2(b.x, y))
        case .vertical:
            let x = (offset >= 0 ? Swift.max(a.x, b.x) : Swift.min(a.x, b.x)) + offset
            return (SIMD2(x, a.y), SIMD2(x, b.y))
        case .aligned:
            let d = b - a
            guard simd_length(d) > 1e-9 else { return (a, b) }
            let u = simd_normalize(d), n = SIMD2(-u.y, u.x)
            return (a + n * offset, b + n * offset)
        }
    }

    /// The offset that puts the dimension line through `point` (dragging it).
    static func offset(through point: SIMD2<Double>, a: SIMD2<Double>, b: SIMD2<Double>,
                       orientation: DrawingAnnotation.Orientation) -> Double {
        switch orientation {
        case .horizontal:
            let hi = Swift.max(a.y, b.y), lo = Swift.min(a.y, b.y)
            return point.y >= (hi + lo) / 2 ? Swift.max(point.y - hi, 1) : Swift.min(point.y - lo, -1)
        case .vertical:
            let hi = Swift.max(a.x, b.x), lo = Swift.min(a.x, b.x)
            return point.x >= (hi + lo) / 2 ? Swift.max(point.x - hi, 1) : Swift.min(point.x - lo, -1)
        case .aligned:
            let d = b - a
            guard simd_length(d) > 1e-9 else { return 8 }
            let u = simd_normalize(d), n = SIMD2(-u.y, u.x)
            let o = simd_dot(point - a, n)
            return abs(o) < 1 ? (o < 0 ? -1 : 1) : o
        }
    }

    /// Dragging a diameter or radius: the leader swings round the circle to
    /// point at `point`, as long as the drag is from the centre.
    static func circleLeader(through point: SIMD2<Double>, center: SIMD2<Double>, radius: Double,
                             transform: DrawingViewTransform) -> (rim: SIMD2<Double>, offset: Double) {
        let c = transform.sheet(center)
        var d = point - c
        if simd_length(d) < 1e-9 { d = SIMD2(1, 1) }
        let u = simd_normalize(d)
        let offset = Swift.max(3, simd_length(point - c) - radius * transform.k)
        return (center + u * radius, offset)
    }

    /// Where a new diameter or radius points: up at 45°, away from the
    /// middle of its view, carried out until it is clear of the view.
    static func defaultCircleLeader(_ circle: DrawingCircle, transform: DrawingViewTransform,
                                    frame: (min: SIMD2<Double>, max: SIMD2<Double>))
        -> (rim: SIMD2<Double>, offset: Double) {
        let c = transform.sheet(circle.center)
        let away = c.x - (frame.min.x + frame.max.x) / 2
        let u = simd_normalize(SIMD2<Double>(away < 0 ? -1 : 1, 1))
        let rim = c + u * circle.radius * transform.k
        // Distance along u from the outline to the frame's edge.
        var exit = Double.infinity
        if u.x > 0 { exit = Swift.min(exit, (frame.max.x - rim.x) / u.x) }
        if u.x < 0 { exit = Swift.min(exit, (frame.min.x - rim.x) / u.x) }
        if u.y > 0 { exit = Swift.min(exit, (frame.max.y - rim.y) / u.y) }
        let offset = exit.isFinite ? Swift.max(exit, 0) + 4 : 8
        return (circle.center + u * circle.radius, Swift.max(offset, 6))
    }

    /// The annotation whose handle (its text) is under `point`.
    static func annotation(at point: SIMD2<Double>, in layout: DrawingLayout) -> UUID? {
        var best: (id: UUID, distance: Double)?
        for (id, handle) in layout.annotationHandles {
            let d = simd_distance(handle, point)
            if d <= handleRadius, d < (best?.distance ?? .infinity) { best = (id, d) }
        }
        return best?.id
    }
}

// MARK: - Circles

/// A circle or arc found in a view (view coordinates).
nonisolated struct DrawingCircle: Equatable, Sendable {
    var center: SIMD2<Double>
    var radius: Double
    /// All the way round (a hole or boss seen end on), not just an arc.
    var full: Bool
}

/// Finds the circles in a projected view. Views are drawn from meshes, so a
/// circle arrives as a chain of short lines: the lines are joined into
/// chains, a circle is fitted to each long enough chain, and the chains that
/// lie on it — and turn through enough of it — are kept. Pieces of one circle
/// (split where it passes behind something) are merged.
nonisolated enum DrawingCircleKit {

    static func circles(in segments: [DrawingSegment]) -> [DrawingCircle] {
        var found: [(circle: DrawingCircle, sweep: Double)] = []
        for chain in chains(segments) where chain.count >= 6 {
            guard let fit = fit(chain), fit.radius > 1e-4 else { continue }
            // Every vertex on it, within a hair of the radius.
            let tolerance = Swift.max(fit.radius * 0.01, 1e-4)
            guard chain.allSatisfy({ abs(simd_distance($0, fit.center) - fit.radius) <= tolerance }) else { continue }
            // Turning one way only, through the angle it covers.
            var sweep = 0.0
            var sign = 0.0
            var consistent = true
            for (p, q) in zip(chain, chain.dropFirst()) {
                let a0 = atan2(p.y - fit.center.y, p.x - fit.center.x)
                let a1 = atan2(q.y - fit.center.y, q.x - fit.center.x)
                var d = a1 - a0
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                // A chord spanning a quarter turn or more is no sampled curve.
                if abs(d) > .pi / 4 { consistent = false; break }
                if d != 0 {
                    if sign == 0 { sign = d > 0 ? 1 : -1 } else if (d > 0 ? 1.0 : -1.0) != sign { consistent = false; break }
                }
                sweep += abs(d)
            }
            guard consistent, sweep >= .pi / 3 else { continue }
            if let i = found.firstIndex(where: {
                simd_distance($0.circle.center, fit.center) <= tolerance && abs($0.circle.radius - fit.radius) <= tolerance
            }) {
                found[i].sweep += sweep
            } else {
                found.append((DrawingCircle(center: fit.center, radius: fit.radius, full: false), sweep))
            }
        }
        return found.map {
            var circle = $0.circle
            circle.full = $0.sweep >= 2 * .pi * 0.97
            return circle
        }
    }

    /// The segments joined end to end into chains of points (a closed loop
    /// repeats its first point at the end). Chains break where more than two
    /// segments meet.
    static func chains(_ segments: [DrawingSegment]) -> [[SIMD2<Double>]] {
        func cell(_ p: SIMD2<Double>) -> SIMD2<Int64> {
            SIMD2(Int64((p.x * 1e5).rounded()), Int64((p.y * 1e5).rounded()))
        }
        var point: [SIMD2<Int64>: SIMD2<Double>] = [:]
        var neighbours: [SIMD2<Int64>: [SIMD2<Int64>]] = [:]
        for s in segments {
            let a = cell(s.a), b = cell(s.b)
            guard a != b else { continue }
            point[a] = s.a
            point[b] = s.b
            if !(neighbours[a]?.contains(b) ?? false) {
                neighbours[a, default: []].append(b)
                neighbours[b, default: []].append(a)
            }
        }
        struct Edge: Hashable { var a: SIMD2<Int64>; var b: SIMD2<Int64> }
        func edge(_ a: SIMD2<Int64>, _ b: SIMD2<Int64>) -> Edge {
            (a.x, a.y) < (b.x, b.y) ? Edge(a: a, b: b) : Edge(a: b, b: a)
        }
        var used = Set<Edge>()
        var out: [[SIMD2<Double>]] = []
        func walk(from start: SIMD2<Int64>, via next: SIMD2<Int64>) {
            var chain = [point[start]!]
            var previous = start, current = next
            used.insert(edge(start, next))
            while true {
                chain.append(point[current]!)
                let around = neighbours[current] ?? []
                guard around.count == 2, current != start else { break }
                let onward = around[0] == previous ? around[1] : around[0]
                guard used.insert(edge(current, onward)).inserted else { break }
                previous = current
                current = onward
            }
            out.append(chain)
        }
        // Open chains from their ends (and from branch points) first, then
        // what is left: closed loops.
        let keys = neighbours.keys.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        for start in keys where neighbours[start]!.count != 2 {
            for next in neighbours[start]! where !used.contains(edge(start, next)) { walk(from: start, via: next) }
        }
        for start in keys {
            for next in neighbours[start]! where !used.contains(edge(start, next)) { walk(from: start, via: next) }
        }
        return out
    }

    /// Least-squares circle through the points (Kåsa).
    static func fit(_ points: [SIMD2<Double>]) -> (center: SIMD2<Double>, radius: Double)? {
        // Centre the points for conditioning.
        let mean = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sxz = 0.0, syz = 0.0
        for p in points {
            let x = p.x - mean.x, y = p.y - mean.y, z = x * x + y * y
            sxx += x * x; sxy += x * y; syy += y * y; sxz += x * z; syz += y * z
        }
        let det = sxx * syy - sxy * sxy
        guard abs(det) > 1e-18 * Swift.max(sxx * syy, 1) else { return nil }
        let cx = (sxz * syy - syz * sxy) / (2 * det)
        let cy = (syz * sxx - sxz * sxy) / (2 * det)
        let center = SIMD2(cx, cy)
        let r2 = points.reduce(0.0) { $0 + simd_length_squared($1 - mean - center) } / Double(points.count)
        guard r2.isFinite, r2 > 0 else { return nil }
        return (center + mean, r2.squareRoot())
    }

    /// The circle whose outline passes within `tolerance` sheet mm of
    /// `point`, in any view but the isometric.
    static func circle(at point: SIMD2<Double>, in layout: DrawingLayout, tolerance: Double = 2)
        -> (view: String, circle: DrawingCircle)? {
        var best: (view: String, circle: DrawingCircle, distance: Double)?
        for (key, circles) in layout.circles where key != DrawingSheet.viewKey(.isometric) {
            guard let t = layout.viewTransforms[key] else { continue }
            for c in circles {
                let d = abs(simd_distance(t.sheet(c.center), point) - c.radius * t.k)
                if d <= tolerance, d < (best?.distance ?? .infinity) { best = (key, c, d) }
            }
        }
        return best.map { ($0.view, $0.circle) }
    }
}
