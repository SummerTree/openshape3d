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

    /// The model distance a dimension shows, mm.
    var measured: Double {
        switch orientation {
        case .horizontal: abs(b.x - a.x)
        case .vertical: abs(b.y - a.y)
        case .aligned: simd_distance(a, b)
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
