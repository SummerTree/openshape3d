//
//  DXFKit.swift
//  openshape3d
//
//  DXF R12 sketch interchange. Export writes plane-local 2D coordinates as
//  ASCII DXF (LINE/CIRCLE/ARC; rect/ellipse/polygon become POLYLINE, the
//  polyline form R12 defines). Import parses the R12/R2000-common subset —
//  LINE, CIRCLE, ARC, LWPOLYLINE, POLYLINE/VERTEX/SEQEND — with a group-code
//  state machine, ignoring unknown entities; polylines arrive as line
//  segments because SketchEntity has no polyline case. Angles: DXF uses
//  degrees CCW from +X, matching the sketch arc convention in radians.
//  Convention: 1 model unit = 1 mm = 1 drawing unit.
//

import Foundation
import simd

nonisolated enum DXFKit {

    // MARK: - Export

    /// R12 ASCII DXF of the sketch entities in plane-local coordinates.
    /// `plane` documents the source; DXF output is 2D so it does not affect
    /// the emitted coordinates.
    static func exportSketch(entities: [SketchEntity], plane: SketchPlane) -> String {
        var out = """
        999
        openshape3d DXF export (units: mm)
        0
        SECTION
        2
        HEADER
        9
        $ACADVER
        1
        AC1009
        9
        $INSUNITS
        70
        4
        9
        $MEASUREMENT
        70
        1
        0
        ENDSEC
        0
        SECTION
        2
        ENTITIES

        """
        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                out += "0\nLINE\n8\n0\n"
                out += pair(10, 20, a) + code(30, 0) + pair(11, 21, b) + code(31, 0)
            case let .rect(_, min, max):
                appendPolyline(
                    [min, SIMD2(max.x, min.y), max, SIMD2(min.x, max.y)],
                    closed: true, to: &out
                )
            case let .circle(_, center, radius):
                out += "0\nCIRCLE\n8\n0\n"
                out += pair(10, 20, center) + code(30, 0) + code(40, radius)
            case let .arc(_, center, radius, startAngle, endAngle):
                out += "0\nARC\n8\n0\n"
                out += pair(10, 20, center) + code(30, 0) + code(40, radius)
                out += code(50, startAngle * 180 / .pi) + code(51, endAngle * 180 / .pi)
            case let .ellipse(_, center, radiusX, radiusY, rotation):
                appendPolyline(
                    SketchEntity.ellipsePoints(
                        center: center, radiusX: radiusX, radiusY: radiusY,
                        rotation: rotation, segments: ellipseSegments
                    ),
                    closed: true, to: &out
                )
            case let .polygon(_, center, radius, sides, rotation):
                appendPolyline(
                    SketchEntity.polygonPoints(
                        center: center, radius: radius, sides: sides, rotation: rotation
                    ),
                    closed: true, to: &out
                )
            case let .spline(_, points, closed):
                // Exported as a tessellated POLYLINE rather than a DXF SPLINE:
                // it round-trips through every reader (the R12 subset we target
                // has no SPLINE entity) at the cost of exact curvature.
                appendPolyline(
                    SketchEntity.splinePoints(points, closed: closed),
                    closed: closed, to: &out
                )
            }
        }
        out += "0\nENDSEC\n0\nEOF\n"
        return out
    }

    /// Tessellation density for ellipse export (closed POLYLINE vertex count).
    static let ellipseSegments = 64

    private static func appendPolyline(
        _ points: [SIMD2<Double>], closed: Bool, to out: inout String
    ) {
        guard points.count >= 2 else { return }
        out += "0\nPOLYLINE\n8\n0\n66\n1\n70\n\(closed ? 1 : 0)\n"
        for p in points {
            out += "0\nVERTEX\n8\n0\n" + pair(10, 20, p) + code(30, 0)
        }
        out += "0\nSEQEND\n8\n0\n"
    }

    private static func code(_ groupCode: Int, _ value: Double) -> String {
        "\(groupCode)\n\(format(value))\n"
    }

    private static func pair(_ xCode: Int, _ yCode: Int, _ p: SIMD2<Double>) -> String {
        code(xCode, p.x) + code(yCode, p.y)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.9f", value)
    }

    // MARK: - Import

    /// Millimetres per drawing unit for a `$INSUNITS` header value. The
    /// codes are AutoCAD's: 1 inches, 2 feet, 4 mm, 5 cm, 6 m; 0 is
    /// "unitless" and anything unknown reads as mm, the app's own unit —
    /// the CAD test pack's IO cases import an inch drawing 25.4× too small
    /// without this.
    static func millimetresPerUnit(insunits: Int) -> Double {
        switch insunits {               // $INSUNITS codes, DXF reference
        case 1: return 25.4             // inches
        case 2: return 304.8            // feet
        case 3: return 1_609_344        // miles
        case 5: return 10               // centimetres
        case 6: return 1000             // metres
        case 7: return 1_000_000        // kilometres
        case 8: return 0.0000254        // microinches
        case 9: return 0.0254           // mils, a thousandth of an inch
        case 10: return 914.4           // yards
        case 11: return 1e-7            // ångströms
        case 12: return 1e-6            // nanometres
        case 13: return 0.001           // microns
        case 14: return 100             // decimetres
        case 15: return 10_000          // decametres
        case 16: return 100_000         // hectometres
        default: return 1               // 0 unitless, 4 millimetres, and anything else
        }
    }

    /// Parses LINE, CIRCLE, ARC, ELLIPSE, LWPOLYLINE and POLYLINE/VERTEX/
    /// SEQEND from R12/R2000-common ASCII DXF, scaled to millimetres by the
    /// header's `$INSUNITS`. Unknown entities and malformed input are skipped
    /// gracefully; garbage yields an empty array, never a crash.
    static func importDXF(_ data: Data) -> [SketchEntity] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Group-code / value pairs; a dangling last code is dropped.
        var pairs = [(code: Int, value: String)]()
        pairs.reserveCapacity(lines.count / 2)
        var i = 0
        while i + 1 < lines.count {
            guard let groupCode = Int(lines[i]) else { i += 1; continue }
            pairs.append((groupCode, lines[i + 1]))
            i += 2
        }

        var entities = [SketchEntity]()
        var inEntitiesSection = false
        var inHeaderSection = false
        var expectingSectionName = false      // the `2 NAME` right after `0 SECTION`
        var headerVariable: String?
        var scale = 1.0                        // mm per drawing unit ($INSUNITS)
        var currentType: String?
        var values = [Int: Double]()          // last value per group code
        var vertices = [SIMD2<Double>]()      // LWPOLYLINE inline vertices
        var pendingX: Double?
        // POLYLINE state: vertices collected from VERTEX entities until SEQEND.
        var polylineClosed: Bool?
        var polylineVertices = [SIMD2<Double>]()

        func finishEntity() {
            defer {
                currentType = nil
                values = [:]
                vertices = []
                pendingX = nil
            }
            guard inEntitiesSection, let type = currentType else { return }
            let s = scale
            switch type {
            case "LINE":
                guard let x1 = values[10], let y1 = values[20],
                      let x2 = values[11], let y2 = values[21] else { return }
                entities.append(.line(id: UUID(), a: SIMD2(x1, y1) * s, b: SIMD2(x2, y2) * s))
            case "CIRCLE":
                guard let x = values[10], let y = values[20],
                      let r = values[40], r > 0 else { return }
                entities.append(.circle(id: UUID(), center: SIMD2(x, y) * s, radius: r * s))
            case "ARC":
                guard let x = values[10], let y = values[20],
                      let r = values[40], r > 0,
                      let start = values[50], let end = values[51] else { return }
                entities.append(.arc(
                    id: UUID(), center: SIMD2(x, y) * s, radius: r * s,
                    startAngle: start * .pi / 180, endAngle: end * .pi / 180
                ))
            case "ELLIPSE":
                // 10/20 centre, 11/21 the major-axis END POINT relative to the
                // centre, 40 minor/major ratio, 41/42 start and end parameters
                // in radians (0 … 2π is the whole ellipse). A whole ellipse is
                // the sketch's own ellipse entity; an elliptical arc has no
                // sketch primitive and arrives as a polyline, the way export
                // already tessellates ellipses for readers without one.
                guard let cx = values[10], let cy = values[20],
                      let mx = values[11], let my = values[21],
                      let ratio = values[40], ratio > 0 else { return }
                let major = simd_length(SIMD2(mx, my))
                guard major > 1e-9 else { return }
                let start = values[41] ?? 0, end = values[42] ?? 2 * .pi
                let center = SIMD2(cx, cy) * s
                let rotation = atan2(my, mx)
                if abs((end - start).truncatingRemainder(dividingBy: 2 * .pi)) < 1e-6 && end != start {
                    entities.append(.ellipse(
                        id: UUID(), center: center, radiusX: major * s,
                        radiusY: major * ratio * s, rotation: rotation))
                } else {
                    let sweep = end > start ? end - start : end - start + 2 * .pi
                    let segments = max(8, Int((sweep / (2 * .pi) * Double(ellipseSegments)).rounded(.up)))
                    let u = SIMD2(cos(rotation), sin(rotation)), v = SIMD2(-sin(rotation), cos(rotation))
                    let points = (0...segments).map { i -> SIMD2<Double> in
                        let t = start + sweep * Double(i) / Double(segments)
                        return center + (u * (major * cos(t)) + v * (major * ratio * sin(t))) * s
                    }
                    entities.append(contentsOf: polylineSegments(points, closed: false))
                }
            case "LWPOLYLINE":
                let closed = (Int((values[70] ?? 0).clampedToInt) & 1) != 0
                entities.append(contentsOf: polylineSegments(vertices.map { $0 * s }, closed: closed))
            case "VERTEX":
                if polylineClosed != nil, let x = values[10], let y = values[20] {
                    polylineVertices.append(SIMD2(x, y) * s)
                }
            case "SEQEND":
                if let closed = polylineClosed {
                    entities.append(contentsOf: polylineSegments(polylineVertices, closed: closed))
                }
                polylineClosed = nil
                polylineVertices = []
            default:
                break  // unknown entity: ignore gracefully
            }
        }

        for (groupCode, value) in pairs {
            if groupCode == 0 {
                finishEntity()
                switch value {
                case "SECTION", "ENDSEC", "EOF":
                    currentType = nil
                    expectingSectionName = (value == "SECTION")
                    if value != "SECTION" { inEntitiesSection = false; inHeaderSection = false }
                case "POLYLINE":
                    currentType = "POLYLINE"
                    polylineClosed = false  // may be updated by its 70 flag
                    polylineVertices = []
                default:
                    currentType = value
                }
                continue
            }
            if groupCode == 2, currentType == nil, expectingSectionName {
                // The section name right after a SECTION marker — and only
                // there: inside HEADER, `$DIMSTYLE` and `$UCSNAME` carry
                // their values on group 2 too, and reading those as a
                // section name ended the header before `$INSUNITS`, which
                // AutoCAD writes after them (an inch drawing then imported
                // 25.4× too small; 2026-10-21 review).
                expectingSectionName = false
                inEntitiesSection = (value == "ENTITIES")
                inHeaderSection = (value == "HEADER")
                continue
            }
            if inHeaderSection {
                // Header variables are `9 $NAME` followed by typed values;
                // `$INSUNITS` (70) decides the drawing unit. The header comes
                // before ENTITIES, so the scale is known before any entity.
                if groupCode == 9 { headerVariable = value; continue }
                if groupCode == 70, headerVariable == "$INSUNITS", let code = Int(value) {
                    scale = millimetresPerUnit(insunits: code)
                }
                continue
            }
            guard currentType != nil else { continue }
            // `Double("nan")`, `Double("inf")` and `Double("1e999")` all
            // SUCCEED. Those values then trap in `Int(_: Double)` just below,
            // and — if they reach the sketch — in the profile/offset welds.
            // A malformed DXF is user-reachable through the file picker, so
            // drop non-finite values here (2026-08-25 review round 3).
            guard let number = Double(value), number.isFinite else { continue }
            if currentType == "POLYLINE", groupCode == 70 {
                // Clamp before Int(): a huge finite value traps too.
                polylineClosed = (Int(number.clampedToInt) & 1) != 0
                continue
            }
            if currentType == "LWPOLYLINE" {
                // Vertex coordinates repeat; pair each 10 with the next 20.
                if groupCode == 10 {
                    pendingX = number
                    continue
                }
                if groupCode == 20 {
                    if let x = pendingX {
                        vertices.append(SIMD2(x, number))
                        pendingX = nil
                    }
                    continue
                }
            }
            values[groupCode] = number
        }
        finishEntity()
        return entities
    }

    /// Consecutive-point line segments (plus the closing segment when closed),
    /// skipping degenerate zero-length edges.
    private static func polylineSegments(
        _ points: [SIMD2<Double>], closed: Bool
    ) -> [SketchEntity] {
        guard points.count >= 2 else { return [] }
        var segments = [SketchEntity]()
        for i in 0..<(points.count - 1) {
            appendSegment(points[i], points[i + 1], to: &segments)
        }
        if closed {
            appendSegment(points[points.count - 1], points[0], to: &segments)
        }
        return segments
    }

    private static func appendSegment(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, to segments: inout [SketchEntity]
    ) {
        guard simd_length(b - a) > 1e-9 else { return }
        segments.append(.line(id: UUID(), a: a, b: b))
    }
}
