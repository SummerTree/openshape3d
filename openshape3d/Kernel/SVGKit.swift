//
//  SVGKit.swift
//  openshape3d
//
//  File ▸ Export ▸ SVG from Sketch: a sketch's geometry as an SVG drawing in
//  millimetres — for laser cutters, plotters and vector editors. The sketch's
//  own 2D coordinates are written with Y flipped (SVG's Y runs down), so the
//  drawing reads the way the sketch does looking at it head-on. Lines,
//  circles and arcs stay exact; ellipses are rotated <ellipse>s; polygons,
//  rectangles and splines are polylines (splines tessellated, as in DXF).
//

import Foundation
import simd

nonisolated enum SVGKit {

    static func exportSketch(entities: [SketchEntity], strokeWidth: Double = 0.25) -> String {
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        func grow(_ p: SIMD2<Double>) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        for entity in entities {
            switch entity {
            case let .circle(_, c, r), let .arc(_, c, r, _, _):
                grow(c - SIMD2(r, r)); grow(c + SIMD2(r, r))
            case let .ellipse(_, c, rx, ry, _):
                let r = max(rx, ry); grow(c - SIMD2(r, r)); grow(c + SIMD2(r, r))
            default:
                outline(entity).forEach(grow)
            }
        }
        guard lo.x.isFinite else {
            return #"<svg xmlns="http://www.w3.org/2000/svg" width="0mm" height="0mm"/>"#
        }
        let margin = max(1, simd_length(hi - lo) * 0.02)
        lo -= SIMD2(margin, margin); hi += SIMD2(margin, margin)
        let size = hi - lo
        // Sketch → SVG: shift into the box, flip Y.
        func x(_ p: SIMD2<Double>) -> String { num(p.x - lo.x) }
        func y(_ p: SIMD2<Double>) -> String { num(hi.y - p.y) }

        var body = ""
        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                body += #"<line x1="\#(x(a))" y1="\#(y(a))" x2="\#(x(b))" y2="\#(y(b))"/>"# + "\n"
            case let .circle(_, c, r):
                body += #"<circle cx="\#(x(c))" cy="\#(y(c))" r="\#(num(r))"/>"# + "\n"
            case let .arc(_, c, r, start, end):
                let sweep = SketchEntity.arcSweep(startAngle: start, endAngle: end)
                let a = c + SIMD2(cos(start), sin(start)) * r
                let b = c + SIMD2(cos(start + sweep), sin(start + sweep)) * r
                // CCW in the sketch is clockwise once Y flips: sweep-flag 0.
                let large = sweep > .pi ? 1 : 0
                body += #"<path d="M \#(x(a)) \#(y(a)) A \#(num(r)) \#(num(r)) 0 \#(large) 0 \#(x(b)) \#(y(b))"/>"# + "\n"
            case let .ellipse(_, c, rx, ry, rotation):
                // Y flips, so the rotation flips sign.
                body += #"<ellipse cx="\#(x(c))" cy="\#(y(c))" rx="\#(num(rx))" ry="\#(num(ry))" transform="rotate(\#(num(-rotation * 180 / .pi)) \#(x(c)) \#(y(c)))"/>"# + "\n"
            default:
                let points = outline(entity)
                guard points.count >= 2 else { continue }
                let closed: Bool
                switch entity {
                case .rect, .polygon: closed = true
                case let .spline(_, _, isClosed): closed = isClosed
                default: closed = false
                }
                let list = points.map { "\(x($0)),\(y($0))" }.joined(separator: " ")
                body += "<\(closed ? "polygon" : "polyline") points=\"\(list)\"/>\n"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(num(size.x))mm" height="\(num(size.y))mm" viewBox="0 0 \(num(size.x)) \(num(size.y))">
        <g fill="none" stroke="black" stroke-width="\(num(strokeWidth))" stroke-linecap="round" stroke-linejoin="round">
        \(body)</g>
        </svg>

        """
    }

    /// Polyline points for the entities written as polylines.
    private static func outline(_ entity: SketchEntity) -> [SIMD2<Double>] {
        switch entity {
        case let .line(_, a, b): return [a, b]
        case let .rect(_, lo, hi): return [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
        case let .polygon(_, c, r, sides, rotation):
            return SketchEntity.polygonPoints(center: c, radius: r, sides: sides, rotation: rotation)
        case let .spline(_, points, closed):
            return SketchEntity.splinePoints(points, closed: closed)
        case let .circle(_, c, r): return [c - SIMD2(r, r), c + SIMD2(r, r)]
        case let .arc(_, c, r, _, _): return [c - SIMD2(r, r), c + SIMD2(r, r)]
        case let .ellipse(_, c, rx, ry, _): return [c - SIMD2(rx, ry), c + SIMD2(rx, ry)]
        }
    }

    private static func num(_ v: Double) -> String {
        let rounded = (v * 10_000).rounded() / 10_000
        return rounded == 0 ? "0" : String(format: "%g", rounded)
    }
}
