//
//  DrawingAnnotations.swift
//  openshape3d
//
//  Dimensions and notes placed on a drawing (spec §15). Each belongs to a
//  view and keeps its points in that view's own coordinates (model mm in
//  the view's plane), so it moves and rescales with the view and measures
//  the model, whatever the sheet scale. A dimension snaps to the corners
//  and line ends of the view it is placed on, or measures between its
//  straight edges (the angle between two, the gap between parallel ones);
//  a note is free text with an optional leader to a point of the view.
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
        /// The angle between two edges: `a`→`b` and `c`→`d` run out from
        /// where the edges meet, each along the part of its edge measured.
        case angle
        /// A chain line from `a` to `b`, carried a little past each end: the
        /// axis between two parallel edges, or through two points (circle centres).
        case centerline
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

    /// How a dimension's value carries its tolerance (spec §15).
    enum Tolerance: String, Codable, CaseIterable, Sendable {
        case none
        /// "40 ±0.1 mm" — `upper` either way.
        case symmetrical
        /// The value with the deviations stacked after it.
        case deviation
        /// The two limits stacked in place of the value.
        case limits
        /// The theoretically exact value, boxed.
        case basic

        var title: String {
            switch self {
            case .none: "None"
            case .symmetrical: "Symmetrical"
            case .deviation: "Deviation"
            case .limits: "Limits"
            case .basic: "Basic"
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
    /// An angle's second edge (view coordinates).
    var c = SIMD2<Double>.zero
    var d = SIMD2<Double>.zero
    var orientation: Orientation = .aligned
    /// How far the dimension line stands off the measured points, sheet mm:
    /// + above / right (along the line's left-hand normal when aligned); an
    /// angle's arc radius (negative: the arc sits across the corner, between
    /// the edges carried on past it — for a corner too small to hold it).
    var offset = 8.0
    /// A note's text (lines split on newlines).
    var text = ""
    /// A note points at `b`.
    var leader = false
    /// A dimension's text before and after its value ("2×", "THRU").
    var prefix = ""
    var suffix = ""
    var tolerance: Tolerance = .none
    /// The deviations from the value, signed: mm, an angle's degrees.
    var upper = 0.1
    var lower = -0.1

    init(kind: Kind, view: String, a: SIMD2<Double>, b: SIMD2<Double>) {
        self.kind = kind
        self.view = view
        self.a = a
        self.b = b
    }

    private enum CodingKeys: String, CodingKey { case id, kind, view, a, b, c, d, orientation, offset, text, leader,
                                                    prefix, suffix, tolerance, upper, lower }

    // Tolerant of drawings saved by other builds.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .note
        view = try c.decodeIfPresent(String.self, forKey: .view) ?? ""
        a = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .a) ?? .zero
        b = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .b) ?? a
        self.c = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .c) ?? a
        d = try c.decodeIfPresent(SIMD2<Double>.self, forKey: .d) ?? b
        orientation = (try? c.decodeIfPresent(Orientation.self, forKey: .orientation)) ?? .aligned
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 8
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        leader = try c.decodeIfPresent(Bool.self, forKey: .leader) ?? false
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        tolerance = (try? c.decodeIfPresent(Tolerance.self, forKey: .tolerance)) ?? .none
        upper = try c.decodeIfPresent(Double.self, forKey: .upper) ?? 0.1
        lower = try c.decodeIfPresent(Double.self, forKey: .lower) ?? -0.1
    }

    /// How the Dimensions & Notes list names it: "40 mm", "Ø8 mm ±0.1",
    /// "R3 mm", "45°", "Note".
    @MainActor var listTitle: String {
        guard kind != .note else { return "Note" }
        guard kind != .centerline else { return "Centreline" }
        let unit = AppSettings.shared.unit
        return DrawingAnnotationKit.valueString(self, format: { unit.compactLengthString(fromMM: $0) })
    }

    /// What goes before a dimension's number: "Ø" for a diameter, "R" for a radius.
    var symbol: String {
        switch kind {
        case .diameter: "Ø"
        case .radius: "R"
        default: ""
        }
    }

    /// The model distance a dimension shows, mm; an angle's degrees.
    var measured: Double {
        if kind == .angle {
            let u = b - a, v = d - c
            guard simd_length(u) > 1e-12, simd_length(v) > 1e-12 else { return 0 }
            return acos(Swift.min(1, Swift.max(-1, simd_dot(simd_normalize(u), simd_normalize(v))))) * 180 / .pi
        }
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
    /// Two parallel edges (visible or hidden): the axis between them; two
    /// points or circles: the line through them.
    case centerline

    var title: String {
        switch self {
        case .move: "Move"
        case .dimension: "Dimension"
        case .note: "Note"
        case .centerline: "Centreline"
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

    // MARK: Edges

    /// How close, sheet mm, a tap must be to a straight edge to pick it.
    static let edgeRadius = 1.5

    /// The straight edge (a long visible line — or hidden, when `hidden`)
    /// under `point`, in the smallest view there; the isometric is left
    /// out, as for `pick`.
    static func edge(at point: SIMD2<Double>, in layout: DrawingLayout, hidden: Bool = false) -> DrawingEdgePick? {
        var best: (pick: DrawingEdgePick, distance: Double, area: Double)?
        var all = layout.edges
        if hidden { all.merge(layout.hiddenEdges) { $0 + $1 } }
        for (key, segments) in all where key != DrawingSheet.viewKey(.isometric) {
            guard let t = layout.viewTransforms[key], let frame = layout.placedViews[key] else { continue }
            let area = (frame.max.x - frame.min.x) * (frame.max.y - frame.min.y)
            for s in segments {
                let a = t.sheet(s.a), b = t.sheet(s.b), ab = b - a
                let along = Swift.min(1, Swift.max(0, simd_dot(point - a, ab) / simd_length_squared(ab)))
                let distance = simd_distance(a + ab * along, point)
                guard distance <= edgeRadius else { continue }
                if let best, best.area < area - 1e-9 || (abs(best.area - area) <= 1e-9 && best.distance <= distance) { continue }
                best = (DrawingEdgePick(view: key, a: s.a, b: s.b, foot: s.a + (s.b - s.a) * along), distance, area)
            }
        }
        return best?.pick
    }

    /// What a Dimension tap means: the corner `pick` snapped to, unless the
    /// tap is on a straight edge well along from that corner (on an edge
    /// shorter than the snap reach every tap is near a corner); else the
    /// edge under it, over a bare point.
    static func edge(at point: SIMD2<Double>, in layout: DrawingLayout,
                     over pick: (view: String, point: SIMD2<Double>, snapped: Bool)?,
                     hidden: Bool = false) -> DrawingEdgePick? {
        guard let edge = edge(at: point, in: layout, hidden: hidden) else { return nil }
        guard let pick, pick.snapped else { return edge }
        guard let te = layout.viewTransforms[edge.view], let tp = layout.viewTransforms[pick.view] else { return nil }
        let foot = te.sheet(edge.foot)
        let along = simd_distance(foot, tp.sheet(pick.point)), off = simd_distance(foot, point)
        return along >= 1.2 && along > 2 * off ? edge : nil
    }

    /// The dimension two picked edges make: the angle between them, or the
    /// distance between them when they are parallel. Nil for one line.
    static func dimension(_ first: DrawingEdgePick, _ second: DrawingEdgePick) -> DrawingAnnotation? {
        guard first.view == second.view else { return nil }
        let d1 = first.b - first.a, d2 = second.b - second.a
        let l1 = simd_length(d1), l2 = simd_length(d2)
        guard l1 > 1e-9, l2 > 1e-9 else { return nil }
        let cross = d1.x * d2.y - d1.y * d2.x
        if abs(cross) / (l1 * l2) < sin(0.5 * .pi / 180) {
            // Parallel: from the first tap straight across to the second edge.
            let u = d2 / l2
            let across = second.a + u * simd_dot(first.foot - second.a, u)
            guard simd_distance(across, first.foot) > 1e-6 else { return nil }
            var dimension = DrawingAnnotation(kind: .linear, view: first.view, a: first.foot, b: across)
            dimension.orientation = axisOrientation(d1)
            return dimension
        }
        // Where the two lines meet, and each edge's run out from there,
        // on the side that was tapped.
        let w = second.a - first.a
        let vertex = first.a + d1 * ((w.x * d2.y - w.y * d2.x) / cross)
        func ray(_ e: DrawingEdgePick) -> (SIMD2<Double>, SIMD2<Double>)? {
            var u = e.foot - vertex
            if simd_length(u) < 1e-6 {
                u = simd_distance(e.a, vertex) > simd_distance(e.b, vertex) ? e.a - vertex : e.b - vertex
            }
            guard simd_length(u) > 1e-9 else { return nil }
            u = simd_normalize(u)
            let ta = simd_dot(e.a - vertex, u), tb = simd_dot(e.b - vertex, u)
            let t0 = Swift.max(0, Swift.min(ta, tb)), t1 = Swift.max(ta, tb)
            guard t1 > 1e-9 else { return nil }
            return (vertex + u * t0, vertex + u * t1)
        }
        guard let r1 = ray(first), let r2 = ray(second) else { return nil }
        var dimension = DrawingAnnotation(kind: .angle, view: first.view, a: r1.0, b: r1.1)
        dimension.c = r2.0
        dimension.d = r2.1
        return dimension
    }

    // MARK: Centrelines

    /// How far, sheet mm, a centreline runs on past what it was drawn between.
    static let centerlineOverrun = 3.0

    /// The centreline midway between two parallel edges, along the length
    /// of both. Nil unless they are parallel and apart, on one view.
    static func centerline(_ first: DrawingEdgePick, _ second: DrawingEdgePick) -> DrawingAnnotation? {
        guard first.view == second.view else { return nil }
        let d1 = first.b - first.a, d2 = second.b - second.a
        let l1 = simd_length(d1), l2 = simd_length(d2)
        guard l1 > 1e-9, l2 > 1e-9, abs(d1.x * d2.y - d1.y * d2.x) / (l1 * l2) < sin(0.5 * .pi / 180) else { return nil }
        let u = d1 / l1
        let w = second.a - first.a
        let gap = w - u * simd_dot(w, u)
        guard simd_length(gap) > 1e-6 else { return nil }
        let origin = first.a + gap / 2
        let ts = [first.a, first.b, second.a, second.b].map { simd_dot($0 - origin, u) }
        return DrawingAnnotation(kind: .centerline, view: first.view,
                                 a: origin + u * ts.min()!, b: origin + u * ts.max()!)
    }

    /// The centreline through two points of one view.
    static func centerline(view: String, _ p: SIMD2<Double>, _ q: SIMD2<Double>) -> DrawingAnnotation? {
        simd_distance(p, q) > 1e-6 ? DrawingAnnotation(kind: .centerline, view: view, a: p, b: q) : nil
    }

    /// The distance from `point` straight across to an edge's line.
    static func dimension(_ edge: DrawingEdgePick, point: SIMD2<Double>) -> DrawingAnnotation? {
        let d = edge.b - edge.a
        guard simd_length(d) > 1e-9 else { return nil }
        let u = simd_normalize(d)
        let foot = edge.a + u * simd_dot(point - edge.a, u)
        guard simd_distance(foot, point) > 1e-6 else { return nil }
        var dimension = DrawingAnnotation(kind: .linear, view: edge.view, a: foot, b: point)
        dimension.orientation = axisOrientation(d)
        return dimension
    }

    /// Square across an edge: vertical from a horizontal edge, horizontal
    /// from a vertical one, aligned from a sloping one (so the value is
    /// always the true gap).
    private static func axisOrientation(_ edge: SIMD2<Double>) -> DrawingAnnotation.Orientation {
        let u = simd_normalize(edge)
        if abs(u.y) < 1e-6 { return .vertical }
        if abs(u.x) < 1e-6 { return .horizontal }
        return .aligned
    }

    /// Where an angle's edges meet (view coordinates).
    static func vertex(_ angle: DrawingAnnotation) -> SIMD2<Double> {
        let d1 = angle.b - angle.a, d2 = angle.d - angle.c
        let cross = d1.x * d2.y - d1.y * d2.x
        guard abs(cross) > 1e-12 else { return angle.a }
        let w = angle.c - angle.a
        return angle.a + d1 * ((w.x * d2.y - w.y * d2.x) / cross)
    }

    /// A new angle's arc radius, sheet mm: inside the shorter edge, 8–25 mm
    /// — or, when the edges are too short to hold that, 8 mm across the corner.
    static func defaultAngleRadius(_ angle: DrawingAnnotation, transform: DrawingViewTransform) -> Double {
        let v = vertex(angle)
        let reach = Swift.min(simd_distance(v, angle.b), simd_distance(v, angle.d)) * transform.k
        return reach * 0.6 < 8 ? -8 : Swift.min(25, reach * 0.6)
    }

    /// Dragging an angle: its arc passes through `point` — across the
    /// corner when the point is.
    static func angleRadius(through point: SIMD2<Double>, _ angle: DrawingAnnotation,
                            transform: DrawingViewTransform) -> Double {
        let c = transform.sheet(vertex(angle))
        let r = Swift.max(3, simd_distance(point, c))
        let inside = simd_normalize(angle.b - angle.a) + simd_normalize(angle.d - angle.c)
        return simd_dot(point - c, inside) < 0 ? -r : r
    }

    /// "45°", "22.5°".
    static func angleString(_ degrees: Double) -> String {
        let tenths = (degrees * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0
            ? "\(Int(tenths / 10))°" : String(format: "%.1f°", tenths / 10)
    }

    // MARK: Values

    /// A piece of a dimension's value, written left to right.
    enum ValuePiece: Equatable, Sendable {
        case text(String)
        /// Two smaller lines, one over the other (deviations, limits).
        case stack(String, String)
        /// Text in a box (a basic dimension).
        case boxed(String)
    }

    /// A dimension's value as written: prefix, symbol and number (or its two
    /// limits), tolerance, unit and suffix. `format` writes a length (or an
    /// angle) with its unit — "40 mm", "1.5\"", "63.4°".
    static func valuePieces(_ dim: DrawingAnnotation, format: (Double) -> String) -> [ValuePiece] {
        let value = dim.measured
        let angle = dim.kind == .angle
        func write(_ v: Double) -> String { angle ? angleString(v) : format(v) }
        // A deviation's own precision: an angle's to hundredths of a degree.
        func deviation(_ v: Double) -> String {
            angle ? String(format: "%g", (v * 100).rounded() / 100) + "°" : format(v)
        }
        let prefix = dim.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = dim.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = (prefix.isEmpty ? "" : prefix + " ") + dim.symbol
        let tail = suffix.isEmpty ? "" : " " + suffix
        let (number, unit) = splitUnit(write(value))
        func signed(_ d: Double) -> String {
            let n = splitUnit(deviation(abs(d))).number
            return n == "0" ? "0" : (d > 0 ? "+" : "-") + n
        }
        var pieces: [ValuePiece]
        switch dim.tolerance {
        case .none:
            pieces = [.text(lead + number + unit + tail)]
        case .symmetrical:
            pieces = [.text(lead + number + " ±" + splitUnit(deviation(abs(dim.upper))).number + unit + tail)]
        case .deviation:
            pieces = [.text(lead + number), .stack(signed(dim.upper), signed(dim.lower)), .text(unit + tail)]
        case .limits:
            pieces = [.text(lead), .stack(splitUnit(write(value + dim.upper)).number,
                                          splitUnit(write(value + dim.lower)).number), .text(unit + tail)]
        case .basic:
            pieces = [.text(prefix.isEmpty ? "" : prefix + " "), .boxed(dim.symbol + number + unit), .text(tail)]
        }
        return pieces.filter { $0 != .text("") }
    }

    /// The value on one line, for lists: stacks as "upper/lower", a box in brackets.
    static func valueString(_ dim: DrawingAnnotation, format: (Double) -> String) -> String {
        valuePieces(dim, format: format).map {
            switch $0 {
            case .text(let s): s
            case .stack(let u, let l): " \(u)/\(l)"
            case .boxed(let s): "[\(s)]"
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// "40 mm" → ("40", " mm"); "63.4°" → ("63.4", "°"): the unit is what
    /// follows the last digit.
    static func splitUnit(_ s: String) -> (number: String, unit: String) {
        guard let i = s.lastIndex(where: \.isNumber) else { return (s, "") }
        let next = s.index(after: i)
        return (String(s[..<next]), String(s[next...]))
    }

    /// About how wide a line of text is, sheet mm, at `height` (the text's
    /// size, drawn at 1.4× in Helvetica): its character widths, per 1000 em.
    static func textWidth(_ s: String, height: Double) -> Double {
        let em = height * 1.4 / 1000
        return s.reduce(0) { sum, ch in
            let w: Double
            switch ch {
            case " ", ".", ",", "/", "f", "t", "I": w = 278
            case "i", "j", "l": w = 222
            case "-", "r", "(", ")": w = 333
            case "+", "±", "×", "=": w = 584
            case "°": w = 400
            case "\"": w = 355
            case "'": w = 191
            case "m", "M": w = 833
            case "w": w = 722
            case "Ø", "O", "Q", "G": w = 778
            default: w = ch.isUppercase ? 667 : 556
            }
            return sum + w * em
        }
    }
}

/// A straight edge picked on a view: its ends and the point of it nearest
/// the tap (view coordinates).
nonisolated struct DrawingEdgePick: Equatable, Sendable {
    var view: String
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var foot: SIMD2<Double>
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
    /// The straight lines a view is drawn with, each joined from the
    /// collinear pieces it arrives in (a circle seen edge-on is a row of
    /// short lines), with the points where the pieces met.
    static func straightRuns(_ segments: [DrawingSegment], tolerance: Double = 1e-4)
        -> [(line: DrawingSegment, joins: [SIMD2<Double>])] {
        var out: [(line: DrawingSegment, joins: [SIMD2<Double>])] = []
        for chain in chains(segments) {
            var start = 0
            while start < chain.count - 1 {
                // Grow the run while every point stays on the line from its
                // start to its newest point, running the same way.
                var end = start + 1
                while end + 1 < chain.count {
                    let a = chain[start], b = chain[end + 1]
                    let d = b - a, length = simd_length(d)
                    guard length > 1e-12 else { break }
                    let u = d / length, n = SIMD2(-u.y, u.x)
                    var straight = true
                    var along = 0.0
                    for p in chain[(start + 1)...end] {
                        let t = simd_dot(p - a, u)
                        if abs(simd_dot(p - a, n)) > tolerance || t < along - tolerance { straight = false; break }
                        along = t
                    }
                    guard straight, simd_dot(b - a, u) >= along - tolerance else { break }
                    end += 1
                }
                out.append((DrawingSegment(a: chain[start], b: chain[end]), Array(chain[(start + 1)..<end])))
                start = end
            }
        }
        return out
    }

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
