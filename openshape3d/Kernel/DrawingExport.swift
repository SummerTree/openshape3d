//
//  DrawingExport.swift
//  openshape3d
//
//  Drawings (spec §15): a laid-out sheet written as PDF, SVG or DXF. All
//  three are plain text the app writes itself (no platform PDF or font
//  APIs), so the iPad, the Mac and the web produce identical files.
//
//  Line weights follow the usual drafting set: visible 0.5 mm, hidden 0.35
//  mm dashed, thin (dimensions, title-block rules) 0.18 mm, border 0.7 mm.
//

import Foundation
import simd

nonisolated enum DrawingFileFormat: String, CaseIterable, Sendable {
    case pdf, svg, dxf

    var title: String { rawValue.uppercased() }
}

nonisolated enum DrawingExport {

    static func width(_ style: DrawingLineStyle) -> Double {
        switch style {
        case .visible: 0.5
        case .hidden: 0.35
        case .thin: 0.18
        case .border: 0.7
        case .chain: 0.25
        case .hatch: 0.18
        }
    }

    /// Hidden lines: 3 mm dashes, 1.5 mm gaps.
    static let hiddenDash: [Double] = [3, 1.5]
    /// Chain lines: 8 mm dashes split by dots.
    static let chainDash: [Double] = [8, 1.5, 0.5, 1.5]

    /// The dash pattern of `style` (sheet mm), empty for solid lines.
    static func dash(_ style: DrawingLineStyle) -> [Double] {
        switch style {
        case .hidden: hiddenDash
        case .chain: chainDash
        default: []
        }
    }

    // MARK: - SVG

    static func svg(_ layout: DrawingLayout) -> String {
        let w = layout.size.x, h = layout.size.y
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(num(w))mm" height="\(num(h))mm" viewBox="0 0 \(num(w)) \(num(h))">
        <rect width="\(num(w))" height="\(num(h))" fill="#ffffff"/>
        <g fill="none" stroke="#000000" stroke-linecap="round">

        """
        for style in DrawingLineStyle.drawOrder {
            let lines = layout.lines.filter { $0.style == style }
            guard !lines.isEmpty else { continue }
            let pattern = dash(style)
            let dash = pattern.isEmpty ? "" : " stroke-dasharray=\"\(pattern.map(num).joined(separator: " "))\""
            out += "<path stroke-width=\"\(num(width(style)))\"\(dash) d=\""
            for line in lines {
                out += "M\(num(line.a.x)) \(num(h - line.a.y))L\(num(line.b.x)) \(num(h - line.b.y))"
            }
            out += "\"/>\n"
        }
        out += "</g>\n<g font-family=\"Helvetica, Arial, sans-serif\" fill=\"#000000\">\n"
        for text in layout.texts {
            let anchor = text.anchor == .start ? "start" : text.anchor == .middle ? "middle" : "end"
            let x = num(text.position.x), y = num(h - text.position.y)
            let rotate = text.rotation == 0 ? "" : " transform=\"rotate(\(num(-text.rotation * 180 / .pi)) \(x) \(y))\""
            out += "<text x=\"\(x)\" y=\"\(y)\" font-size=\"\(num(text.height * 1.4))\" text-anchor=\"\(anchor)\"\(rotate)>\(xmlEscaped(text.string))</text>\n"
        }
        out += "</g>\n</svg>\n"
        return out
    }

    // MARK: - PDF

    /// A one-page PDF 1.4: vector lines and Helvetica text.
    static func pdf(_ layout: DrawingLayout) -> Data {
        let k = 72 / 25.4 // mm → points
        var content = "q\n1 J 1 j\n"
        for style in DrawingLineStyle.drawOrder {
            let lines = layout.lines.filter { $0.style == style }
            guard !lines.isEmpty else { continue }
            content += "\(num(width(style) * k)) w\n"
            content += "[\(dash(style).map { num($0 * k) }.joined(separator: " "))] 0 d\n"
            for line in lines {
                content += "\(num(line.a.x * k)) \(num(line.a.y * k)) m \(num(line.b.x * k)) \(num(line.b.y * k)) l\n"
            }
            content += "S\n"
        }
        content += "Q\n"
        for text in layout.texts {
            let size = text.height * 1.4 * k
            let width = estimatedWidth(text.string, size: size)
            let shift = text.anchor == .start ? 0 : text.anchor == .middle ? -width / 2 : -width
            let c = cos(text.rotation), s = sin(text.rotation)
            let x = text.position.x * k + shift * c, y = text.position.y * k + shift * s
            content += "BT /F1 \(num(size)) Tf \(num(c)) \(num(s)) \(num(-s)) \(num(c)) \(num(x)) \(num(y)) Tm (\(pdfEscaped(text.string))) Tj ET\n"
        }

        let page = layout.size * k
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(num(page.x)) \(num(page.y))] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(data.count)
            data += Data("\(i + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let xref = data.count
        var trailer = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        data += Data(trailer.utf8)
        return data
    }

    /// Helvetica's average advance is about half the point size.
    static func estimatedWidth(_ string: String, size: Double) -> Double {
        Double(string.count) * size * 0.55
    }

    // MARK: - DXF

    /// DXF R12, in millimetres at sheet scale: layers VISIBLE, HIDDEN (dashed
    /// HIDDEN linetype), CUTTING (CENTER linetype), HATCH, DIMENSIONS, BORDER
    /// and TEXT.
    static func dxf(_ layout: DrawingLayout) -> String {
        var out = ""
        func pair(_ code: Int, _ value: String) { out += "\(code)\n\(value)\n" }
        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1009")
        pair(9, "$INSUNITS"); pair(70, "4")
        pair(9, "$EXTMIN"); pair(10, "0"); pair(20, "0")
        pair(9, "$EXTMAX"); pair(10, num(layout.size.x)); pair(20, num(layout.size.y))
        pair(0, "ENDSEC")

        pair(0, "SECTION"); pair(2, "TABLES")
        pair(0, "TABLE"); pair(2, "LTYPE"); pair(70, "3")
        pair(0, "LTYPE"); pair(2, "CONTINUOUS"); pair(70, "0"); pair(3, "Solid line")
        pair(72, "65"); pair(73, "0"); pair(40, "0.0")
        pair(0, "LTYPE"); pair(2, "HIDDEN"); pair(70, "0"); pair(3, "Hidden __ __ __")
        pair(72, "65"); pair(73, "2"); pair(40, num(hiddenDash[0] + hiddenDash[1]))
        pair(49, num(hiddenDash[0])); pair(49, num(-hiddenDash[1]))
        pair(0, "LTYPE"); pair(2, "CENTER"); pair(70, "0"); pair(3, "Center ____ _ ____ _")
        pair(72, "65"); pair(73, "\(chainDash.count)"); pair(40, num(chainDash.reduce(0, +)))
        for (i, length) in chainDash.enumerated() { pair(49, num(i.isMultiple(of: 2) ? length : -length)) }
        pair(0, "ENDTAB")
        let layers: [(String, String)] = [("VISIBLE", "CONTINUOUS"), ("HIDDEN", "HIDDEN"),
                                          ("CUTTING", "CENTER"), ("HATCH", "CONTINUOUS"),
                                          ("DIMENSIONS", "CONTINUOUS"), ("BORDER", "CONTINUOUS"),
                                          ("TEXT", "CONTINUOUS")]
        pair(0, "TABLE"); pair(2, "LAYER"); pair(70, "\(layers.count)")
        for (name, ltype) in layers {
            pair(0, "LAYER"); pair(2, name); pair(70, "0"); pair(62, "7"); pair(6, ltype)
        }
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")

        pair(0, "SECTION"); pair(2, "ENTITIES")
        for line in layout.lines {
            let layer: String
            switch line.style {
            case .visible: layer = "VISIBLE"
            case .hidden: layer = "HIDDEN"
            case .thin: layer = "DIMENSIONS"
            case .border: layer = "BORDER"
            case .chain: layer = "CUTTING"
            case .hatch: layer = "HATCH"
            }
            pair(0, "LINE"); pair(8, layer)
            pair(10, num(line.a.x)); pair(20, num(line.a.y)); pair(30, "0")
            pair(11, num(line.b.x)); pair(21, num(line.b.y)); pair(31, "0")
        }
        for text in layout.texts {
            pair(0, "TEXT"); pair(8, "TEXT")
            pair(10, num(text.position.x)); pair(20, num(text.position.y)); pair(30, "0")
            pair(40, num(text.height)); pair(1, text.string)
            if text.rotation != 0 { pair(50, num(text.rotation * 180 / .pi)) }
            if text.anchor != .start {
                // Horizontal justification needs the alignment point too.
                pair(72, text.anchor == .middle ? "1" : "2")
                pair(11, num(text.position.x)); pair(21, num(text.position.y)); pair(31, "0")
            }
        }
        pair(0, "ENDSEC")
        pair(0, "EOF")
        return out
    }

    // MARK: - Helpers

    static func num(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.3f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    private static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// PDF literal string: escape the delimiters, and keep to the font's
    /// Latin range (anything else becomes "?").
    private static func pdfEscaped(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "(", ")", "\\": out += "\\" + String(ch)
            default: out += ch.value < 0x80 && ch.value >= 0x20 ? String(ch) : "?"
            }
        }
        return out
    }
}
