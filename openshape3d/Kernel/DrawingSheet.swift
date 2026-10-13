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
    /// Thin chain line: cutting planes.
    case chain
    /// Thin hatching across cut faces.
    case hatch

    /// Back to front: what is drawn last sits on top.
    static let drawOrder: [DrawingLineStyle] = [.border, .thin, .hatch, .chain, .hidden, .visible]
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
    /// Where each standard view landed (sheet mm), for tests and labels.
    var viewFrames: [DrawingViewDirection: (min: SIMD2<Double>, max: SIMD2<Double>)] = [:]
    /// Every placed view — standard, section and detail — by
    /// `DrawingSheet.viewKey`, for dragging views on the sheet.
    var placedViews: [String: (min: SIMD2<Double>, max: SIMD2<Double>)] = [:]
    /// How each placed view maps onto the sheet, and the corners and line
    /// ends a dimension snaps to (view coordinates) — for placing
    /// annotations on the preview.
    var viewTransforms: [String: DrawingViewTransform] = [:]
    var snapPoints: [String: [SIMD2<Double>]] = [:]
    /// The ends of a view's long lines — true corners and where a straight
    /// edge meets a curve — which win over the points a curve is sampled at.
    var strongSnapPoints: [String: [SIMD2<Double>]] = [:]
    /// Each annotation's handle (its text), sheet mm — to select or drag it.
    var annotationHandles: [UUID: SIMD2<Double>] = [:]

    var isEmpty: Bool { viewFrames.isEmpty }
}

/// Projected views kept between layouts of the same model, so changing a
/// sheet option or dragging a view does not project the bodies again. The
/// owner empties it whenever the bodies change.
nonisolated final class DrawingViewCache {
    private var views: [String: ProjectedView] = [:]

    init() {}

    func view(_ key: String, _ make: () -> ProjectedView) -> ProjectedView {
        if let hit = views[key] { return hit }
        let view = make()
        views[key] = view
        return view
    }

    func removeAll() { views.removeAll() }
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
        layout(bodies: bodies, drawing: SavedDrawing(options: options), formatLength: formatLength, date: date)
    }

    /// The key a view's frame and drag offset are stored under.
    static func viewKey(_ direction: DrawingViewDirection) -> String { direction.rawValue }
    static func viewKey(section id: UUID) -> String { "section:\(id.uuidString)" }
    static func viewKey(detail id: UUID) -> String { "detail:\(id.uuidString)" }

    /// The view under `point` (sheet mm) for dragging: the smallest frame
    /// within `slop` mm of it, so a detail inside a big view's box wins.
    static func view(at point: SIMD2<Double>, in layout: DrawingLayout, slop: Double = 3) -> String? {
        layout.placedViews
            .filter { point.x >= $0.value.min.x - slop && point.x <= $0.value.max.x + slop
                && point.y >= $0.value.min.y - slop && point.y <= $0.value.max.y + slop }
            .min { a, b in
                let areaA = (a.value.max.x - a.value.min.x) * (a.value.max.y - a.value.min.y)
                let areaB = (b.value.max.x - b.value.min.x) * (b.value.max.y - b.value.min.y)
                return areaA != areaB ? areaA < areaB : a.key < b.key
            }?
            .key
    }

    /// A section or detail view, stacked in a column beside the main views.
    private struct ExtraView {
        var key: String
        var label: String
        var view: ProjectedView
        /// Times the sheet scale (detail views).
        var magnification: Double
        var isSection: Bool
        var showHidden: Bool
        var detailMagnification: Double?
    }

    /// Lay out `drawing` for `bodies`: the standard views, then its section
    /// and detail views in a column to the right, each moved by the drawing's
    /// view offsets.
    static func layout(
        bodies: [DrawingBodyInput], drawing: SavedDrawing,
        formatLength: (Double) -> String = { String(format: "%.2f", $0) },
        date: String = "", cache: DrawingViewCache = DrawingViewCache()
    ) -> DrawingLayout {
        let options = drawing.options
        let paper = options.sheet.size
        var out = DrawingLayout(size: paper)
        guard !bodies.isEmpty else {
            appendFrame(into: &out, options: options, scale: "", date: date)
            return out
        }

        func project(_ direction: DrawingViewDirection) -> ProjectedView {
            cache.view(direction.rawValue) { DrawingProjection.project(bodies, direction: direction) }
        }
        let front = project(.front)
        guard !front.isEmpty else {
            appendFrame(into: &out, options: options, scale: "", date: date)
            return out
        }
        let top = project(.top)
        let side = project(.right)
        let iso = options.includeIsometric ? project(.isometric) : nil
        var baseViews: [DrawingViewDirection: ProjectedView] = [.front: front, .top: top, .right: side]
        if let iso { baseViews[.isometric] = iso }
        func baseView(_ direction: DrawingViewDirection) -> ProjectedView {
            if let view = baseViews[direction] { return view }
            let view = project(direction)
            baseViews[direction] = view
            return view
        }

        // Section and detail views.
        var extras: [ExtraView] = []
        var cuts: [(section: DrawingSectionView, cut: DrawingViewKit.SectionCut)] = []
        for section in drawing.sections where DrawingSectionView.bases.contains(section.base) {
            let base = baseView(section.base)
            guard !base.isEmpty else { continue }
            let cut = DrawingViewKit.cut(section, baseView: base)
            cuts.append((section, cut))
            let cutKey = "section:\(section.base.rawValue):\(section.cut.rawValue):\(section.position):\(section.flipped)"
            let view = cache.view(cutKey) { DrawingViewKit.section(bodies, cut: cut) }
            guard !view.isEmpty else { continue }
            extras.append(ExtraView(key: viewKey(section: section.id),
                                    label: "SECTION \(section.label)-\(section.label)", view: view,
                                    magnification: 1, isSection: true, showHidden: false))
        }
        var circles: [(detail: DrawingDetailView, center: SIMD2<Double>, radius: Double)] = []
        for detail in drawing.details where DrawingDetailView.bases.contains(detail.base) {
            let base = baseView(detail.base)
            guard !base.isEmpty else { continue }
            let circle = DrawingViewKit.detailCircle(detail, baseView: base)
            circles.append((detail, circle.center, circle.radius))
            let magnification = Swift.max(1, detail.magnification)
            extras.append(ExtraView(key: viewKey(detail: detail.id), label: "DETAIL \(detail.label)",
                                    view: DrawingViewKit.detail(detail, baseView: base),
                                    magnification: magnification, isSection: false,
                                    showHidden: options.showHiddenLines && detail.base != .isometric,
                                    detailMagnification: magnification))
        }

        // Drawing area: inside the border, above the title block's height.
        let areaMin = SIMD2(margin + 6, margin + titleBlockSize.y + 6)
        // A vertical cutting line lifts its view's name (see below): keep
        // room for it under the border.
        let liftRoom = cuts.contains { $0.section.cut == .vertical } ? 5.0 : 0
        let areaMax = paper - SIMD2(margin + 6, margin + 6 + liftRoom)
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
        // The extra column: as wide as its widest view, as tall as its views
        // stacked with a label gap between them.
        let extraColumn = extras.map { $0.view.size.x * $0.magnification }.max() ?? 0
        let extraHeight = extras.reduce(0) { $0 + $1.view.size.y * $1.magnification }
        let extraGaps = Double(Swift.max(0, extras.count - 1)) * viewGap
        let extraRoom = extras.isEmpty ? 0 : viewGap
        let scale: Double
        if let fixed = options.scale, fixed > 0 {
            scale = fixed
        } else {
            var fit = Swift.min((area.x - gap - dimRoom - extraRoom) / Swift.max(frontColumn + sideColumn + extraColumn, 1e-6),
                                (area.y - gap - dimRoom) / Swift.max(frontRow + topRow, 1e-6))
            if !extras.isEmpty {
                fit = Swift.min(fit, (area.y - extraGaps) / Swift.max(extraHeight, 1e-6))
            }
            scale = standardScales.first { $0 <= fit } ?? standardScales.last!
        }
        out.scale = scale

        let mainBlock = SIMD2((frontColumn + sideColumn) * scale + gap + dimRoom,
                              (frontRow + topRow) * scale + gap + dimRoom)
        let extraBlock = SIMD2(extraColumn * scale, extraHeight * scale + extraGaps)
        let block = SIMD2(mainBlock.x + (extras.isEmpty ? 0 : extraRoom + extraBlock.x),
                          Swift.max(mainBlock.y, extraBlock.y))
        let origin = areaMin + simd_max((area - block) / 2, .zero)

        // Third angle: Front bottom-left, Top above it, Right to its right.
        // First angle: Front top-right, Top below it, Right to its left.
        let third = options.standard == .ansi
        let frontX = third ? origin.x + dimRoom : origin.x + dimRoom + sideColumn * scale + gap
        let sideX = third ? frontX + frontColumn * scale + gap : origin.x + dimRoom
        let frontY = third ? origin.y + dimRoom : origin.y + dimRoom + topRow * scale + gap
        let topY = third ? frontY + frontRow * scale + gap : origin.y + dimRoom

        // Dragged views. Top and the side view stay lined up with Front: they
        // move with it, and on their own only along their shared axis.
        func offset(_ key: String) -> SIMD2<Double> { drawing.viewOffsets[key] ?? .zero }
        let frontShift = offset(viewKey(.front))
        var origins: [DrawingViewDirection: SIMD2<Double>] = [:]
        func placeStandard(_ view: ProjectedView, at: SIMD2<Double>, direction: DrawingViewDirection) {
            place(view, at: at, scale: scale, key: viewKey(direction), label: direction.title.uppercased(),
                  hidden: options.showHiddenLines && direction != .isometric, into: &out)
            out.viewFrames[direction] = out.placedViews[viewKey(direction)]
            origins[direction] = at
        }
        placeStandard(front, at: SIMD2(frontX, frontY) + frontShift, direction: .front)
        // Projected views line up with the front: Top shares its x, the side
        // view its y.
        placeStandard(top, at: SIMD2(frontX, topY) + frontShift + SIMD2(0, offset(viewKey(.top)).y), direction: .top)
        placeStandard(side, at: SIMD2(sideX, frontY) + frontShift + SIMD2(offset(viewKey(.right)).x, 0),
                      direction: .right)
        if let iso, !iso.isEmpty {
            // Centred in the free cell.
            let isoPos = SIMD2(sideX + (sideColumn - iso.size.x) * scale / 2,
                               topY + (topRow - iso.size.y) * scale / 2)
            placeStandard(iso, at: isoPos + offset(viewKey(.isometric)), direction: .isometric)
        }
        /// A point of a placed standard view on the sheet.
        func sheet(_ direction: DrawingViewDirection, _ p: SIMD2<Double>) -> SIMD2<Double>? {
            guard let at = origins[direction], let view = baseViews[direction] else { return nil }
            return at + (p - view.min) * scale
        }

        // The extra column, top down.
        var y = origin.y + block.y
        let columnX = origin.x + mainBlock.x + extraRoom
        for extra in extras {
            let k = scale * extra.magnification
            let size = extra.view.size * k
            y -= size.y
            let at = SIMD2(columnX + (extraColumn * scale - size.x) / 2, y) + offset(extra.key)
            var label = extra.label
            if let m = extra.detailMagnification { label += " (\(scaleLabel(scale * m)))" }
            place(extra.view, at: at, scale: k, key: extra.key, label: label, hidden: extra.showHidden, into: &out)
            if extra.isSection {
                let loops = extra.view.sectionLoops.map { $0.map { at + ($0 - extra.view.min) * k } }
                for (a, b) in DrawingViewKit.hatch(loops, spacing: 2.5) {
                    out.lines.append(DrawingLine(a: a, b: b, style: .hatch))
                }
            }
            if extra.detailMagnification != nil, let frame = out.placedViews[extra.key] {
                // The detail's own boundary.
                circle(center: (frame.min + frame.max) / 2, radius: (frame.max.x - frame.min.x) / 2,
                       style: .thin, into: &out)
            }
            y -= viewGap
        }

        // Cutting lines and detail circles on their base views.
        for (section, cut) in cuts {
            guard let a = sheet(section.base, cut.line.a), let b = sheet(section.base, cut.line.b) else { continue }
            cuttingLine(from: a, to: b, sight: cut.sight, label: section.label, into: &out)
            if section.cut == .vertical, let frame = out.viewFrames[section.base] {
                // The line's top end and its arrow sit where the view's name
                // does: lift the name clear of them.
                let title = section.base.title.uppercased()
                for i in out.texts.indices where out.texts[i].string == title
                    && abs(out.texts[i].position.y - (frame.max.y + 3)) < 1e-9 {
                    out.texts[i].position.y = frame.max.y + 8
                }
            }
        }
        for (detail, center, radius) in circles {
            guard let c = sheet(detail.base, center), let frame = out.viewFrames[detail.base] else { continue }
            let r = radius * scale
            circle(center: c, radius: r, style: .thin, into: &out)
            // The letter sits outside the circle, on the side away from the
            // middle of the view (where there is room).
            var away = c - (frame.min + frame.max) / 2
            away = simd_length(away) > 1e-6 ? simd_normalize(away) : simd_normalize(SIMD2(1, 1))
            let at = c + away * (r + 2.5)
            out.texts.append(DrawingText(position: at - SIMD2(0, 1.75), height: 3.5, string: detail.label,
                                         anchor: away.x > 0.3 ? .start : away.x < -0.3 ? .end : .middle))
        }

        if options.showDimensions {
            let f = out.viewFrames[.front]!, s = out.viewFrames[.right]!
            // A cutting line ends where a dimension would sit: move the
            // dimension further out, past the line's arrow and letter.
            func offset(_ view: DrawingViewDirection, _ cut: DrawingSectionView.Cut) -> Double {
                cuts.contains { $0.section.base == view && $0.section.cut == cut } ? -12 : -8
            }
            // Width under the front view, height to its left, depth under the
            // side view.
            dimension(from: SIMD2(f.min.x, f.min.y), to: SIMD2(f.max.x, f.min.y), offset: offset(.front, .vertical),
                      value: formatLength(front.size.x), into: &out)
            dimension(from: SIMD2(f.min.x, f.min.y), to: SIMD2(f.min.x, f.max.y), offset: offset(.front, .horizontal),
                      value: formatLength(front.size.y), into: &out)
            dimension(from: SIMD2(s.min.x, s.min.y), to: SIMD2(s.max.x, s.min.y), offset: offset(.right, .vertical),
                      value: formatLength(side.size.x), into: &out)
        }
        // Notes on the bare sheet are kept in sheet mm.
        out.viewTransforms[""] = DrawingViewTransform(at: .zero, min: .zero, k: 1)
        for annotation in drawing.annotations {
            guard let transform = out.viewTransforms[annotation.view] else { continue }
            switch annotation.kind {
            case .linear:
                out.annotationHandles[annotation.id] = linear(
                    from: transform.sheet(annotation.a), to: transform.sheet(annotation.b),
                    orientation: annotation.orientation, offset: annotation.offset,
                    value: formatLength(annotation.measured), into: &out)
            case .note:
                out.annotationHandles[annotation.id] = note(annotation, transform: transform, into: &out)
            }
        }
        appendFrame(into: &out, options: options, scale: scaleLabel(scale), date: date)
        return out
    }

    /// A placed dimension between two sheet points; returns where its value
    /// sits (the handle that drags it).
    private static func linear(from a: SIMD2<Double>, to b: SIMD2<Double>,
                               orientation: DrawingAnnotation.Orientation, offset: Double,
                               value: String, into out: inout DrawingLayout) -> SIMD2<Double> {
        let (l0, l1) = DrawingAnnotationKit.dimensionLine(a, b, orientation: orientation, offset: offset)
        let mid = (l0 + l1) / 2
        let length = simd_distance(l0, l1)
        guard length > 1e-6 else { return mid }
        // Extension lines: a small gap at the part, 2 mm past the line.
        for (p, q) in [(a, l0), (b, l1)] {
            let d = q - p, len = simd_length(d)
            guard len > 1e-6 else { continue }
            let u = d / len
            out.lines.append(DrawingLine(a: p + u * Swift.min(1.5, len), b: q + u * 2, style: .thin))
        }
        out.lines.append(DrawingLine(a: l0, b: l1, style: .thin))
        let dir = (l1 - l0) / length
        let arrow = Swift.min(2.5, length / 4), side = SIMD2(-dir.y, dir.x)
        for (tip, back) in [(l0, dir), (l1, -dir)] {
            out.lines.append(DrawingLine(a: tip, b: tip + back * arrow + side * arrow * 0.35, style: .thin))
            out.lines.append(DrawingLine(a: tip, b: tip + back * arrow - side * arrow * 0.35, style: .thin))
        }
        // The value reads along the line, never upside down, just off it.
        var angle = atan2(dir.y, dir.x)
        if angle > .pi / 2 + 1e-9 { angle -= .pi } else if angle <= -.pi / 2 + 1e-9 { angle += .pi }
        let up = SIMD2(-sin(angle), cos(angle))
        out.texts.append(DrawingText(position: mid + up, height: 2.5, string: value, anchor: .middle, rotation: angle))
        return mid + up * 2
    }

    /// A note: its lines of text at `a`, and a leader with an arrowhead to
    /// `b`. Returns the text's position (its handle).
    private static func note(_ note: DrawingAnnotation, transform: DrawingViewTransform,
                             into out: inout DrawingLayout) -> SIMD2<Double> {
        let at = transform.sheet(note.a)
        let height = 3.5
        let tip = transform.sheet(note.b)
        let pointsLeft = note.leader && tip.x < at.x
        let lines = note.text.isEmpty ? ["Note"] : note.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() {
            out.texts.append(DrawingText(position: at - SIMD2(0, Double(i) * height * 1.4), height: height,
                                         string: line, anchor: pointsLeft || !note.leader ? .start : .end))
        }
        if note.leader, simd_distance(at, tip) > 1 {
            let start = at + SIMD2(pointsLeft ? -1 : 1, height * 0.35)
            out.lines.append(DrawingLine(a: start, b: tip, style: .thin))
            let d = start - tip, u = d / simd_length(d), side = SIMD2(-u.y, u.x)
            out.lines.append(DrawingLine(a: tip, b: tip + u * 2.5 + side * 0.9, style: .thin))
            out.lines.append(DrawingLine(a: tip, b: tip + u * 2.5 - side * 0.9, style: .thin))
        }
        return at + SIMD2(0, height / 2)
    }

    /// Draw a projected view with its lower-left corner at `at`, `scale`
    /// sheet mm per model mm, labelled above.
    private static func place(_ view: ProjectedView, at: SIMD2<Double>, scale: Double, key: String,
                              label: String, hidden: Bool, into out: inout DrawingLayout) {
        func map(_ p: SIMD2<Double>) -> SIMD2<Double> { at + (p - view.min) * scale }
        for s in view.visible { out.lines.append(DrawingLine(a: map(s.a), b: map(s.b), style: .visible)) }
        // Pictorial views are drawn without hidden lines, as drafting does.
        if hidden {
            for s in view.hidden { out.lines.append(DrawingLine(a: map(s.a), b: map(s.b), style: .hidden)) }
        }
        let frame = (min: at, max: at + view.size * scale)
        out.placedViews[key] = frame
        out.viewTransforms[key] = DrawingViewTransform(at: at, min: view.min, k: scale)
        // Line ends (corners, and the vertices of curves), each once.
        var seen = Set<SIMD2<Int64>>(), seenStrong = Set<SIMD2<Int64>>()
        var snaps: [SIMD2<Double>] = [], strong: [SIMD2<Double>] = []
        // A curve is sampled into lines well under 2 sheet mm long.
        let long = 2 / Swift.max(scale, 1e-9)
        for s in view.visible {
            let isLong = simd_distance(s.a, s.b) >= long
            for p in [s.a, s.b] {
                let cell = SIMD2<Int64>(Int64((p.x * 1e4).rounded()), Int64((p.y * 1e4).rounded()))
                if seen.insert(cell).inserted { snaps.append(p) }
                if isLong, seenStrong.insert(cell).inserted { strong.append(p) }
            }
        }
        out.snapPoints[key] = snaps
        out.strongSnapPoints[key] = strong
        out.texts.append(DrawingText(position: SIMD2((frame.min.x + frame.max.x) / 2, frame.max.y + 3),
                                     height: 2.5, string: label, anchor: .middle))
    }

    /// A circle as a 72-sided polygon.
    private static func circle(center: SIMD2<Double>, radius: Double, style: DrawingLineStyle,
                               into out: inout DrawingLayout) {
        let n = 72
        for i in 0..<n {
            let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
            out.lines.append(DrawingLine(a: center + SIMD2(cos(a0), sin(a0)) * radius,
                                         b: center + SIMD2(cos(a1), sin(a1)) * radius, style: style))
        }
    }

    /// A cutting-plane line: chain line across the view, thick ends, arrows
    /// pointing the way the section looks, and the section letter just past
    /// each arrow's tip.
    private static func cuttingLine(from a: SIMD2<Double>, to b: SIMD2<Double>, sight: SIMD2<Double>,
                                    label: String, into out: inout DrawingLayout) {
        let length = simd_distance(a, b)
        guard length > 1e-9 else { return }
        let dir = (b - a) / length
        let overshoot = 3.0
        let ends = [a - dir * overshoot, b + dir * overshoot]
        out.lines.append(DrawingLine(a: ends[0], b: ends[1], style: .chain))
        for (end, inward) in [(ends[0], dir), (ends[1], -dir)] {
            out.lines.append(DrawingLine(a: end, b: end + inward * Swift.min(6, length / 3), style: .visible))
            let tip = end + sight * 6
            out.lines.append(DrawingLine(a: end, b: tip, style: .visible))
            let side = SIMD2(-sight.y, sight.x)
            out.lines.append(DrawingLine(a: tip, b: tip - sight * 2.5 + side * 0.9, style: .visible))
            out.lines.append(DrawingLine(a: tip, b: tip - sight * 2.5 - side * 0.9, style: .visible))
            // Beside a sideways arrow; under (or over) an up/down one.
            let height = 3.5
            let at: SIMD2<Double>
            let anchor: DrawingText.Anchor
            if abs(sight.x) > abs(sight.y) {
                at = tip + sight * 1.5 - SIMD2(0, height / 2)
                anchor = sight.x > 0 ? .start : .end
            } else {
                at = tip + SIMD2(0, sight.y > 0 ? 1.5 : -1.5 - height * 1.4)
                anchor = .middle
            }
            out.texts.append(DrawingText(position: at, height: height, string: label, anchor: anchor))
        }
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
