//
//  DrawingSheet.swift
//  openshape3d
//
//  Drawings (spec §15): a sheet laid out from projected views — Front as
//  the base view with Top and the side view placed by the projection
//  standard (ANSI third angle: Top above, Right to the right; ISO first
//  angle: Top below, Right to the left), an optional isometric in the
//  free corner, overall dimensions, a border and a title block. Everything
//  is in sheet millimetres with the origin at the bottom-left corner, ready
//  for the PDF / SVG / DXF writers in `DrawingExport`.
//

import Foundation
import simd

nonisolated enum DrawingSheetSize: String, CaseIterable, Codable, Sendable {
    case a4, a3, letter, tabloid

    var title: String {
        switch self {
        case .a4: "A4"
        case .a3: "A3"
        case .letter: "Letter"
        case .tabloid: "Tabloid"
        }
    }

    /// Landscape width × height, mm.
    var size: SIMD2<Double> {
        switch self {
        case .a4: SIMD2(297, 210)
        case .a3: SIMD2(420, 297)
        case .letter: SIMD2(279.4, 215.9)
        case .tabloid: SIMD2(431.8, 279.4)
        }
    }
}

nonisolated enum DrawingStandard: String, CaseIterable, Codable, Sendable {
    /// Third-angle projection (US).
    case ansi
    /// First-angle projection (Europe and most of the world).
    case iso

    var title: String { self == .ansi ? "ANSI (third angle)" : "ISO (first angle)" }
}

nonisolated struct DrawingOptions: Equatable, Codable, Sendable {
    var title = "Drawing"
    var sheet: DrawingSheetSize = .a4
    var standard: DrawingStandard = .iso
    var includeIsometric = true
    var showHiddenLines = true
    var showDimensions = true
    /// Sheet scale as drawn ÷ real (0.5 = 1:2); nil picks the largest
    /// standard scale that fits.
    var scale: Double?
}

nonisolated enum DrawingLineStyle: String, Sendable {
    case visible, hidden, thin, border
}

nonisolated struct DrawingLine: Equatable, Sendable {
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var style: DrawingLineStyle
}

nonisolated struct DrawingText: Equatable, Sendable {
    enum Anchor: String, Sendable { case start, middle, end }
    var position: SIMD2<Double>
    var height: Double
    var string: String
    var anchor: Anchor = .start
    /// Counter-clockwise, radians (vertical dimension values read upward).
    var rotation: Double = 0
}

nonisolated struct DrawingLayout: Sendable {
    var size: SIMD2<Double>
    var lines: [DrawingLine] = []
    var texts: [DrawingText] = []
    /// Drawn ÷ real.
    var scale: Double = 1
    /// Where each view landed (sheet mm), for tests and labels.
    var viewFrames: [DrawingViewDirection: (min: SIMD2<Double>, max: SIMD2<Double>)] = [:]

    var isEmpty: Bool { viewFrames.isEmpty }
}

nonisolated enum DrawingSheet {

    /// Standard scales, largest first.
    static let standardScales: [Double] = [10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001]

    /// "1:2", "2:1", "1:1".
    static func scaleLabel(_ scale: Double) -> String {
        if scale >= 1 { return "\(Int(scale.rounded())):1" }
        return "1:\(Int((1 / scale).rounded()))"
    }

    /// "2026-10-12" in the given offset from UTC (seconds) — plain
    /// arithmetic, so it needs no locale data.
    static func isoDate(_ date: Date, utcOffset: Int = TimeZone.current.secondsFromGMT()) -> String {
        let days = Int(((date.timeIntervalSince1970 + Double(utcOffset)) / 86_400).rounded(.down))
        // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static let margin = 10.0
    static let titleBlockSize = SIMD2<Double>(120, 28)
    static let viewGap = 18.0

    /// Lay out a sheet for `bodies`. `formatLength` writes a dimension value
    /// (mm in, display text out); `date` fills the title block.
    static func layout(
        bodies: [DrawingBodyInput], options: DrawingOptions,
        formatLength: (Double) -> String = { String(format: "%.2f", $0) },
        date: String = ""
    ) -> DrawingLayout {
        let paper = options.sheet.size
        var out = DrawingLayout(size: paper)
        guard !bodies.isEmpty else {
            appendFrame(into: &out, options: options, scale: "", date: date)
            return out
        }

        let front = DrawingProjection.project(bodies, direction: .front)
        guard !front.isEmpty else {
            appendFrame(into: &out, options: options, scale: "", date: date)
            return out
        }
        let top = DrawingProjection.project(bodies, direction: .top)
        let side = DrawingProjection.project(bodies, direction: .right)
        let iso = options.includeIsometric ? DrawingProjection.project(bodies, direction: .isometric) : nil

        // Drawing area: inside the border, above the title block's height.
        let areaMin = SIMD2(margin + 6, margin + titleBlockSize.y + 6)
        let areaMax = paper - SIMD2(margin + 6, margin + 6)
        let area = areaMax - areaMin
        let dimRoom = options.showDimensions ? 14.0 : 0
        // A 2×2 grid: Front's column also holds Top, the side view's column
        // the isometric; each column / row is as big as its larger view.
        let isoReal = iso.map(\.size) ?? .zero
        let frontColumn = Swift.max(front.size.x, top.size.x)
        let sideColumn = Swift.max(side.size.x, isoReal.x)
        let frontRow = Swift.max(front.size.y, side.size.y)
        let topRow = Swift.max(top.size.y, isoReal.y)
        let gap = viewGap + dimRoom
        let scale: Double
        if let fixed = options.scale, fixed > 0 {
            scale = fixed
        } else {
            let fit = Swift.min((area.x - gap - dimRoom) / Swift.max(frontColumn + sideColumn, 1e-6),
                                (area.y - gap - dimRoom) / Swift.max(frontRow + topRow, 1e-6))
            scale = standardScales.first { $0 <= fit } ?? standardScales.last!
        }
        out.scale = scale

        let block = SIMD2((frontColumn + sideColumn) * scale + gap + dimRoom,
                          (frontRow + topRow) * scale + gap + dimRoom)
        let origin = areaMin + simd_max((area - block) / 2, .zero)

        // Third angle: Front bottom-left, Top above it, Right to its right.
        // First angle: Front top-right, Top below it, Right to its left.
        let third = options.standard == .ansi
        let frontX = third ? origin.x + dimRoom : origin.x + dimRoom + sideColumn * scale + gap
        let sideX = third ? frontX + frontColumn * scale + gap : origin.x + dimRoom
        let frontY = third ? origin.y + dimRoom : origin.y + dimRoom + topRow * scale + gap
        let topY = third ? frontY + frontRow * scale + gap : origin.y + dimRoom

        place(front, at: SIMD2(frontX, frontY), scale: scale, direction: .front, options: options, into: &out)
        // Projected views line up with the front: Top shares its x, the side
        // view its y.
        place(top, at: SIMD2(frontX, topY), scale: scale, direction: .top, options: options, into: &out)
        place(side, at: SIMD2(sideX, frontY), scale: scale, direction: .right, options: options, into: &out)
        if let iso, !iso.isEmpty {
            // Centred in the free cell.
            let isoPos = SIMD2(sideX + (sideColumn - iso.size.x) * scale / 2,
                               topY + (topRow - iso.size.y) * scale / 2)
            place(iso, at: isoPos, scale: scale, direction: .isometric, options: options, into: &out)
        }

        if options.showDimensions {
            let f = out.viewFrames[.front]!, s = out.viewFrames[.right]!
            // Width under the front view, height to its left, depth under the
            // side view.
            dimension(from: SIMD2(f.min.x, f.min.y), to: SIMD2(f.max.x, f.min.y), offset: -8,
                      value: formatLength(front.size.x), into: &out)
            dimension(from: SIMD2(f.min.x, f.min.y), to: SIMD2(f.min.x, f.max.y), offset: -8,
                      value: formatLength(front.size.y), into: &out)
            dimension(from: SIMD2(s.min.x, s.min.y), to: SIMD2(s.max.x, s.min.y), offset: -8,
                      value: formatLength(side.size.x), into: &out)
        }
        appendFrame(into: &out, options: options, scale: scaleLabel(scale), date: date)
        return out
    }

    /// Draw a projected view with its lower-left corner at `at`.
    private static func place(_ view: ProjectedView, at: SIMD2<Double>, scale: Double,
                              direction: DrawingViewDirection, options: DrawingOptions,
                              into out: inout DrawingLayout) {
        func map(_ p: SIMD2<Double>) -> SIMD2<Double> { at + (p - view.min) * scale }
        for s in view.visible { out.lines.append(DrawingLine(a: map(s.a), b: map(s.b), style: .visible)) }
        // Pictorial views are drawn without hidden lines, as drafting does.
        if options.showHiddenLines, direction != .isometric {
            for s in view.hidden { out.lines.append(DrawingLine(a: map(s.a), b: map(s.b), style: .hidden)) }
        }
        let frame = (min: at, max: at + view.size * scale)
        out.viewFrames[direction] = frame
        out.texts.append(DrawingText(position: SIMD2((frame.min.x + frame.max.x) / 2, frame.max.y + 3),
                                     height: 2.5, string: direction.title.uppercased(), anchor: .middle))
    }

    /// A linear dimension between two points, its line `offset` mm off to the
    /// right of a→b (negative: below a horizontal span, left of a vertical).
    private static func dimension(from a: SIMD2<Double>, to b: SIMD2<Double>, offset: Double,
                                  value: String, into out: inout DrawingLayout) {
        let d = b - a
        let length = simd_length(d)
        guard length > 1e-6 else { return }
        let dir = d / length
        // Normal pointing to the side the dimension sits on.
        let normal = abs(dir.x) > abs(dir.y) ? SIMD2<Double>(0, offset < 0 ? -1 : 1)
                                              : SIMD2<Double>(offset < 0 ? -1 : 1, 0)
        let dist = abs(offset)
        let a1 = a + normal * dist, b1 = b + normal * dist
        // Extension lines (with a small gap at the part), the dimension line,
        // and two arrowheads.
        out.lines.append(DrawingLine(a: a + normal * 1.5, b: a1 + normal * 2, style: .thin))
        out.lines.append(DrawingLine(a: b + normal * 1.5, b: b1 + normal * 2, style: .thin))
        out.lines.append(DrawingLine(a: a1, b: b1, style: .thin))
        let arrow = Swift.min(2.5, length / 4)
        let side = SIMD2(-dir.y, dir.x)
        for (tip, back) in [(a1, dir), (b1, -dir)] {
            out.lines.append(DrawingLine(a: tip, b: tip + back * arrow + side * arrow * 0.35, style: .thin))
            out.lines.append(DrawingLine(a: tip, b: tip + back * arrow - side * arrow * 0.35, style: .thin))
        }
        let mid = (a1 + b1) / 2
        let vertical = abs(dir.y) > abs(dir.x)
        // The value sits just off the line: above a horizontal one, to the
        // left of a vertical one (rotated to read upward).
        out.texts.append(DrawingText(
            position: mid + (vertical ? SIMD2(-1, 0) : SIMD2(0, 1)),
            height: 2.5, string: value, anchor: .middle, rotation: vertical ? .pi / 2 : 0))
    }

    /// Border and title block.
    private static func appendFrame(into out: inout DrawingLayout, options: DrawingOptions,
                                    scale: String, date: String) {
        let size = out.size
        let lo = SIMD2(margin, margin), hi = size - SIMD2(margin, margin)
        func rect(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ style: DrawingLineStyle) {
            out.lines.append(DrawingLine(a: a, b: SIMD2(b.x, a.y), style: style))
            out.lines.append(DrawingLine(a: SIMD2(b.x, a.y), b: b, style: style))
            out.lines.append(DrawingLine(a: b, b: SIMD2(a.x, b.y), style: style))
            out.lines.append(DrawingLine(a: SIMD2(a.x, b.y), b: a, style: style))
        }
        rect(lo, hi, .border)
        let tbLo = SIMD2(hi.x - titleBlockSize.x, lo.y), tbHi = SIMD2(hi.x, lo.y + titleBlockSize.y)
        rect(tbLo, tbHi, .border)
        // Rows: title (14 mm) over a row of four fields (14 mm).
        let split = tbLo.y + 14
        out.lines.append(DrawingLine(a: SIMD2(tbLo.x, split), b: SIMD2(tbHi.x, split), style: .thin))
        let fieldWidth = titleBlockSize.x / 4
        for i in 1..<4 {
            let x = tbLo.x + fieldWidth * Double(i)
            out.lines.append(DrawingLine(a: SIMD2(x, tbLo.y), b: SIMD2(x, split), style: .thin))
        }
        out.texts.append(DrawingText(position: SIMD2(tbLo.x + 3, split + 5), height: 5, string: options.title))
        let fields = [("SCALE", scale), ("SHEET", options.sheet.title),
                      ("PROJECTION", options.standard == .ansi ? "Third angle" : "First angle"), ("DATE", date)]
        for (i, field) in fields.enumerated() {
            let x = tbLo.x + fieldWidth * Double(i) + 2
            out.texts.append(DrawingText(position: SIMD2(x, tbLo.y + 9.5), height: 1.8, string: field.0))
            out.texts.append(DrawingText(position: SIMD2(x, tbLo.y + 3.5), height: 3, string: field.1))
        }
        out.texts.append(DrawingText(position: SIMD2(tbHi.x - 2, tbHi.y + 2), height: 1.8,
                                     string: "openshape3d", anchor: .end))
    }
}
