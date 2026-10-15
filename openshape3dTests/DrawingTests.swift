//
//  DrawingTests.swift
//  openshape3dTests
//
//  Drawings (spec §15): hidden-line projection of standard views, the sheet
//  layout (projection standard, scale, dimensions, title block) and the
//  PDF / SVG / DXF writers.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class DrawingTests: XCTestCase {

    private func body(_ mesh: Euclid.Mesh) -> DrawingBodyInput {
        DrawingBodyInput(body: Body(name: "Part", euclidMesh: mesh, revision: 1))
    }

    /// 10 × 10 × 10 box standing on the ground (y 0…10).
    private var box: DrawingBodyInput { body(.primitive(.box(width: 10, depth: 10, height: 10))) }

    /// The same box with a vertical Ø4 hole through it, built by OCCT like
    /// the app's own holes (watertight tessellation).
    private var boxWithHole: DrawingBodyInput {
        let block = OCCTKernel.primitiveShape(.box(width: 10, depth: 10, height: 10), placement: .identity)!
        var below = Transform3D()
        below.translation = SIMD3(0, -2, 0)
        let pin = OCCTKernel.primitiveShape(.cylinder(radius: 2, height: 14), placement: below)!
        let part = OCCTKernel.boolean(block, pin, op: 1)!
        let mesh = OCCTKernel.renderMesh(from: part)
        let render = RenderMesh(positions: mesh.positions, normals: mesh.normals, indices: mesh.indices)
        let edges = FeatureEdgeExtractor.edges(from: render)
        return DrawingBodyInput(positions: render.positions.map { SIMD3<Double>($0) }, indices: render.indices,
                                edges: edges.segments.map { SIMD3<Double>($0) })
    }

    private func length(_ segments: [DrawingSegment]) -> Double {
        segments.reduce(0) { $0 + simd_distance($1.a, $1.b) }
    }

    func testBoxFrontViewIsItsOutline() {
        let view = DrawingProjection.project([box], direction: .front)
        XCTAssertEqual(view.size.x, 10, accuracy: 1e-6)
        XCTAssertEqual(view.size.y, 10, accuracy: 1e-6)
        XCTAssertEqual(length(view.visible), 40, accuracy: 1e-3)
        XCTAssertEqual(length(view.hidden), 0, accuracy: 1e-6, "the back edges hide behind the front ones")
    }

    func testHoleShowsHiddenInFrontAndRoundOnTop() {
        let front = DrawingProjection.project([boxWithHole], direction: .front)
        XCTAssertEqual(length(front.visible), 40, accuracy: 0.05)
        // The hole's two sides run the full 10 mm height, dashed.
        XCTAssertEqual(length(front.hidden), 20, accuracy: 0.2)
        let top = DrawingProjection.project([boxWithHole], direction: .top)
        XCTAssertEqual(length(top.hidden), 0, accuracy: 1e-6)
        // Square outline + the hole's rim (2π·2, tessellated).
        XCTAssertEqual(length(top.visible), 40 + 2 * .pi * 2, accuracy: 0.2)
    }

    func testIsometricShowsTheBackCornerHidden() {
        let iso = DrawingProjection.project([box], direction: .isometric)
        // Three edges meet at the hidden corner; each projects to 10·√(2/3).
        XCTAssertEqual(length(iso.hidden), 3 * 10 * (2.0 / 3).squareRoot(), accuracy: 0.05)
        XCTAssertEqual(length(iso.visible), 9 * 10 * (2.0 / 3).squareRoot(), accuracy: 0.05)
    }

    func testViewsMatchTheViewportsStandardViews() {
        // A long bar along X, deep along Z: Front shows width × height, Right
        // shows depth × height, Top shows width × depth.
        let bar = body(.primitive(.box(width: 40, depth: 10, height: 4)))
        let front = DrawingProjection.project([bar], direction: .front).size
        let right = DrawingProjection.project([bar], direction: .right).size
        let top = DrawingProjection.project([bar], direction: .top).size
        XCTAssertEqual(front.x, 40, accuracy: 1e-6); XCTAssertEqual(front.y, 4, accuracy: 1e-6)
        XCTAssertEqual(right.x, 10, accuracy: 1e-6); XCTAssertEqual(right.y, 4, accuracy: 1e-6)
        XCTAssertEqual(top.x, 40, accuracy: 1e-6); XCTAssertEqual(top.y, 10, accuracy: 1e-6)
    }

    func testThirdAngleAndFirstAngleArrangement() throws {
        var options = DrawingOptions()
        options.standard = .ansi
        let ansi = DrawingSheet.layout(bodies: [box], options: options)
        let f = try XCTUnwrap(ansi.viewFrames[.front]), t = try XCTUnwrap(ansi.viewFrames[.top])
        let r = try XCTUnwrap(ansi.viewFrames[.right])
        XCTAssertGreaterThan(t.min.y, f.max.y, "third angle: Top above Front")
        XCTAssertGreaterThan(r.min.x, f.max.x, "and Right to its right")
        XCTAssertEqual(t.min.x, f.min.x, accuracy: 1e-9, "Top lines up with Front")
        XCTAssertEqual(r.min.y, f.min.y, accuracy: 1e-9, "Right lines up with Front")

        options.standard = .iso
        let iso = DrawingSheet.layout(bodies: [box], options: options)
        let f2 = try XCTUnwrap(iso.viewFrames[.front]), t2 = try XCTUnwrap(iso.viewFrames[.top])
        let r2 = try XCTUnwrap(iso.viewFrames[.right])
        XCTAssertLessThan(t2.max.y, f2.min.y, "first angle: Top below Front")
        XCTAssertLessThan(r2.max.x, f2.min.x, "and Right to its left")
        XCTAssertNotNil(iso.viewFrames[.isometric])
    }

    func testNoViewsOverlap() throws {
        // A long, flat part: its isometric is much wider than its side view.
        let plate = body(.primitive(.box(width: 60, depth: 30, height: 8)))
        for standard in DrawingStandard.allCases {
            var options = DrawingOptions()
            options.standard = standard
            let layout = DrawingSheet.layout(bodies: [plate], options: options)
            let frames = Array(layout.viewFrames.values)
            XCTAssertEqual(frames.count, 4)
            for i in frames.indices {
                for j in frames.indices where j > i {
                    let a = frames[i], b = frames[j]
                    let apart = a.max.x <= b.min.x || b.max.x <= a.min.x || a.max.y <= b.min.y || b.max.y <= a.min.y
                    XCTAssertTrue(apart, "\(standard): views overlap \(a) \(b)")
                }
            }
        }
    }

    func testScaleIsTheLargestStandardThatFits() throws {
        let small = DrawingSheet.layout(bodies: [box], options: DrawingOptions())
        // 10 mm cube on A4: the views and the isometric's cell fit at 3.9:1,
        // so the standard step below is 2:1.
        XCTAssertEqual(small.scale, 2, "a 10 mm cube is drawn 2:1 on A4")
        let big = body(.primitive(.box(width: 800, depth: 300, height: 400)))
        let layout = DrawingSheet.layout(bodies: [big], options: DrawingOptions())
        XCTAssertEqual(layout.scale, 0.05)
        for frame in layout.viewFrames.values {
            XCTAssertGreaterThanOrEqual(frame.min.x, DrawingSheet.margin)
            XCTAssertLessThanOrEqual(frame.max.x, layout.size.x - DrawingSheet.margin)
            XCTAssertGreaterThanOrEqual(frame.min.y, DrawingSheet.margin)
            XCTAssertLessThanOrEqual(frame.max.y, layout.size.y - DrawingSheet.margin)
        }
        XCTAssertTrue(layout.texts.contains { $0.string == "1:20" }, "the title block names the scale")
        XCTAssertEqual(DrawingSheet.scaleLabel(2), "2:1")
        XCTAssertEqual(DrawingSheet.scaleLabel(0.02), "1:50")
    }

    func testDimensionsAndOptions() {
        var options = DrawingOptions()
        options.title = "Bracket"
        let layout = DrawingSheet.layout(bodies: [boxWithHole], options: options) { String(format: "%.1f", $0) }
        XCTAssertEqual(layout.texts.filter { $0.string == "10.0" }.count, 3, "width, height, depth")
        XCTAssertTrue(layout.texts.contains { $0.string == "Bracket" })
        XCTAssertTrue(layout.lines.contains { $0.style == .hidden })

        options.showHiddenLines = false
        options.showDimensions = false
        options.includeIsometric = false
        let plain = DrawingSheet.layout(bodies: [boxWithHole], options: options)
        XCTAssertFalse(plain.lines.contains { $0.style == .hidden })
        XCTAssertFalse(plain.texts.contains { $0.string == "10.00" })
        XCTAssertNil(plain.viewFrames[.isometric])
    }

    func testTitleBlockLayouts() throws {
        var options = DrawingOptions(title: "Bracket")
        options.titleBlock = .detailed
        options[.company] = "Laan Labs"
        options[.partNumber] = "BR-1042"
        options[.revision] = "C"
        options[.material] = "6061-T6 Aluminium, anodised black, all edges broken 0.2 mm max"
        options[.drawnBy] = "JL"
        let detailed = DrawingSheet.layout(bodies: [box], options: options)
        for word in ["COMPANY", "Laan Labs", "PART NO.", "BR-1042", "REV", "C", "DRAWN BY", "JL", "CHECKED BY",
                     "MATERIAL", "SCALE", "DATE", "Bracket"] {
            XCTAssertTrue(detailed.texts.contains { $0.string == word }, word)
        }
        // A long value shrinks, then is cut short, to stay in its cell.
        let material = try XCTUnwrap(detailed.texts.first { $0.string.hasPrefix("6061") })
        XCTAssertTrue(material.string.hasSuffix("..."))
        XCTAssertLessThan(material.height, 2.5)
        XCTAssertLessThanOrEqual(DrawingAnnotationKit.textWidth(material.string, height: material.height), 46 + 1e-9)
        // The block is 180 × 36 in the corner; the views keep above it.
        let right = detailed.size.x - DrawingSheet.margin
        XCTAssertTrue(detailed.lines.contains { $0.style == .border && $0.a.x == right - 180 && $0.b.x == right - 180 })
        for frame in detailed.viewFrames.values { XCTAssertGreaterThan(frame.min.y, DrawingSheet.margin + 36) }

        // An empty field writes nothing; setting one empty clears it.
        XCTAssertFalse(detailed.texts.contains { $0.string.isEmpty })
        options[.drawnBy] = ""
        XCTAssertNil(options.titleFields["drawnBy"])

        // None: the border alone, and the views may use the space.
        options.titleBlock = .none
        let bare = DrawingSheet.layout(bodies: [box], options: options)
        XCTAssertFalse(bare.texts.contains { $0.string == "SCALE" || $0.string == "Bracket" || $0.string == "openshape3d" })
        XCTAssertEqual(bare.lines.filter { $0.style == .border }.count, 4)
        let simple = DrawingSheet.layout(bodies: [box], options: DrawingOptions())
        XCTAssertLessThan(bare.viewFrames.values.map(\.min.y).min()!, simple.viewFrames.values.map(\.min.y).min()!)
        XCTAssertFalse(simple.texts.contains { $0.string == "COMPANY" }, "Simple is the block it always was")

        // Saved with the drawing; older drawings open with the simple block.
        options.titleBlock = .detailed
        let back = try JSONDecoder().decode(DrawingOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(back, options)
        let old = try JSONDecoder().decode(DrawingOptions.self, from: Data(#"{"title":"Old"}"#.utf8))
        XCTAssertEqual(old.titleBlock, .simple)
        XCTAssertTrue(old.titleFields.isEmpty)
    }

    func testEmptyDesignIsAnEmptySheet() {
        let layout = DrawingSheet.layout(bodies: [], options: DrawingOptions())
        XCTAssertTrue(layout.isEmpty)
        XCTAssertFalse(layout.lines.isEmpty, "the border and title block still draw")
    }

    func testWritersProduceWellFormedFiles() throws {
        var options = DrawingOptions()
        options.title = "Part (A)"
        let layout = DrawingSheet.layout(bodies: [boxWithHole], options: options)

        let svg = DrawingExport.svg(layout)
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("width=\"297mm\""))
        XCTAssertTrue(svg.contains("stroke-dasharray"), "hidden lines are dashed")
        XCTAssertTrue(svg.hasSuffix("</svg>\n"))

        let pdf = DrawingExport.pdf(layout)
        let text = try XCTUnwrap(String(data: pdf, encoding: .isoLatin1))
        XCTAssertTrue(text.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(text.hasSuffix("%%EOF\n"))
        XCTAssertTrue(text.contains("/MediaBox [0 0 841.89 595.276]"), "A4 landscape in points")
        XCTAssertTrue(text.contains("(Part \\(A\\)) Tj"), "parentheses are escaped")
        // Every xref offset points at its object.
        let xrefStart = try XCTUnwrap(text.range(of: "xref\n"))
        let entries = text[xrefStart.upperBound...].split(separator: "\n").dropFirst(2).prefix(5)
        for (i, entry) in entries.enumerated() {
            let offset = try XCTUnwrap(Int(entry.prefix(10)))
            let at = text.index(text.startIndex, offsetBy: offset)
            XCTAssertTrue(text[at...].hasPrefix("\(i + 1) 0 obj"), "object \(i + 1) at \(offset)")
        }

        let dxf = DrawingExport.dxf(layout)
        XCTAssertTrue(dxf.contains("HIDDEN"))
        XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        func count(_ entity: String) -> Int { dxf.components(separatedBy: "\n\(entity)\n").count - 1 }
        XCTAssertEqual(count("LINE") + count("VERTEX") - count("POLYLINE"), layout.lines.count,
                       "every line, alone or in a polyline's run")
    }

    func testIsoDate() {
        XCTAssertEqual(DrawingSheet.isoDate(Date(timeIntervalSince1970: 0), utcOffset: 0), "1970-01-01")
        XCTAssertEqual(DrawingSheet.isoDate(Date(timeIntervalSince1970: 1_791_763_200), utcOffset: 0), "2026-10-12")
        XCTAssertEqual(DrawingSheet.isoDate(Date(timeIntervalSince1970: 951_782_400), utcOffset: 0), "2000-02-29")
        // 23:50 on the 12th in UTC−5 is already the 13th in UTC.
        XCTAssertEqual(DrawingSheet.isoDate(Date(timeIntervalSince1970: 1_791_763_200 + 86_400 + 4 * 3600),
                                            utcOffset: -5 * 3600), "2026-10-12")
    }
}
