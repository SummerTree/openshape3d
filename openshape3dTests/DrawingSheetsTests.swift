//
//  DrawingSheetsTests.swift
//  openshape3dTests
//
//  Spec §15 multiple sheets: a drawing's first sheet lives in its own
//  fields and the rest in `moreSheets`; each sheet has its own paper,
//  scale, bodies, views and annotations while the title, standard and title
//  block are shared; the title block numbers the sheets; a PDF has a page
//  per sheet.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class DrawingSheetsTests: XCTestCase {

    private var box: DrawingBodyInput {
        DrawingBodyInput(body: Body(name: "Part", euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)), revision: 1))
    }

    /// A two-sheet drawing: sheet 1 A4 with a section, sheet 2 A3 at 1:1
    /// without the isometric, with a note.
    private func twoSheets() -> SavedDrawing {
        var drawing = SavedDrawing(options: DrawingOptions(title: "Bracket"))
        drawing.sections = [DrawingSectionView(label: "A")]
        var second = DrawingPage(following: drawing.pages[0])
        second.sheet = .a3
        second.scale = 1
        second.includeIsometric = false
        var note = DrawingAnnotation(kind: .note, view: "", a: SIMD2(40, 60), b: SIMD2(40, 60))
        note.text = "SEE SHEET 1"
        second.annotations = [note]
        drawing.pages.append(second)
        return drawing
    }

    func testSheetsKeepTheirOwnPaperViewsAndAnnotations() {
        let drawing = twoSheets()
        XCTAssertEqual(drawing.sheetCount, 2)
        XCTAssertEqual(drawing.options.sheet, .a4, "sheet 1 stays in the drawing's own fields")
        XCTAssertEqual(drawing.sections.count, 1)

        let second = drawing.onSheet(1)
        XCTAssertEqual(second.options.sheet, .a3)
        XCTAssertEqual(second.options.scale, 1)
        XCTAssertFalse(second.options.includeIsometric)
        XCTAssertTrue(second.sections.isEmpty)
        XCTAssertEqual(second.annotations.map(\.text), ["SEE SHEET 1"])
        XCTAssertEqual(second.options.title, "Bracket", "the title is the drawing's")
        XCTAssertEqual(drawing.onSheet(0), drawing)
        XCTAssertEqual(drawing.onSheet(7), drawing, "out of range shows the first sheet")
    }

    func testEditingASheetWritesBackToThatSheetAndSharedFieldsToTheDrawing() {
        var drawing = twoSheets()
        var shown = drawing.onSheet(1)
        shown.options.title = "Bracket Assembly"
        shown.options.standard = .ansi
        shown.options.sheet = .tabloid
        shown.viewOffsets["front"] = SIMD2(5, 0)
        drawing.setSheet(1, from: shown)

        XCTAssertEqual(drawing.options.title, "Bracket Assembly")
        XCTAssertEqual(drawing.options.standard, .ansi)
        XCTAssertEqual(drawing.options.sheet, .a4, "sheet 1's paper is untouched")
        XCTAssertTrue(drawing.viewOffsets.isEmpty)
        XCTAssertEqual(drawing.moreSheets[0].sheet, .tabloid)
        XCTAssertEqual(drawing.moreSheets[0].viewOffsets["front"], SIMD2(5, 0))
        XCTAssertEqual(drawing.moreSheets[0].annotations.count, 1)
        XCTAssertEqual(drawing.onSheet(1).options.title, "Bracket Assembly")
    }

    func testRemovingTheFirstSheetPromotesTheNext() {
        var drawing = twoSheets()
        drawing.pages.removeFirst()
        XCTAssertEqual(drawing.sheetCount, 1)
        XCTAssertEqual(drawing.options.sheet, .a3)
        XCTAssertTrue(drawing.sections.isEmpty)
        XCTAssertEqual(drawing.annotations.count, 1)
        XCTAssertEqual(drawing.options.title, "Bracket")
        drawing.pages = []
        XCTAssertEqual(drawing.sheetCount, 1, "a drawing always has a sheet")
    }

    func testViewLettersAreUniqueAcrossSheets() {
        var drawing = twoSheets()
        drawing.moreSheets[0].details = [DrawingDetailView(label: "B")]
        XCTAssertEqual(drawing.nextLabel(), "C")
    }

    func testTitleBlockNumbersTheSheets() {
        let drawing = twoSheets()
        let first = DrawingSheet.layout(bodies: [box], drawing: drawing, sheet: 0)
        let second = DrawingSheet.layout(bodies: [box], drawing: drawing, sheet: 1)
        XCTAssertTrue(first.texts.contains { $0.string == "A4, 1 of 2" })
        XCTAssertTrue(second.texts.contains { $0.string == "A3, 2 of 2" })
        XCTAssertEqual(second.size, DrawingSheetSize.a3.size)
        XCTAssertEqual(second.scale, 1)
        XCTAssertNil(second.viewFrames[.isometric])
        XCTAssertNotNil(first.placedViews[DrawingSheet.viewKey(section: drawing.sections[0].id)])
        XCTAssertTrue(second.texts.contains { $0.string == "SEE SHEET 1" })
        // A one-sheet drawing just names its paper.
        let single = DrawingSheet.layout(bodies: [box], drawing: SavedDrawing())
        XCTAssertTrue(single.texts.contains { $0.string == "A4" })
    }

    func testPDFHasAPagePerSheet() {
        let drawing = twoSheets()
        let pages = (0..<2).map { DrawingSheet.layout(bodies: [box], drawing: drawing, sheet: $0) }
        let pdf = String(decoding: DrawingExport.pdf(pages), as: UTF8.self)
        XCTAssertTrue(pdf.contains("/Kids [4 0 R 6 0 R] /Count 2"))
        XCTAssertTrue(pdf.contains("/MediaBox [0 0 841.89 595.276]"), "A4 landscape")
        XCTAssertTrue(pdf.contains("/MediaBox [0 0 1190.551 841.89]"), "A3 landscape")
        XCTAssertTrue(pdf.hasSuffix("%%EOF\n"))
        // Every object the xref lists is where it says.
        let data = DrawingExport.pdf(pages)
        let text = String(decoding: data, as: UTF8.self)
        let xref = text.range(of: "xref\n")!
        let rows = text[xref.upperBound...].split(separator: "\n").dropFirst(2).prefix(7)
        for (i, row) in rows.enumerated() {
            let offset = Int(row.prefix(10))!
            XCTAssertTrue(String(decoding: data[offset...].prefix(12), as: UTF8.self).hasPrefix("\(i + 1) 0 obj"))
        }
    }

    func testSheetsAreSavedAndOldDrawingsOpenAsOneSheet() throws {
        let drawing = twoSheets()
        let back = try JSONDecoder().decode(SavedDrawing.self, from: JSONEncoder().encode(drawing))
        XCTAssertEqual(back, drawing)
        let old = #"{"id":"\#(UUID().uuidString)","options":{"title":"Old"}}"#
        let opened = try JSONDecoder().decode(SavedDrawing.self, from: Data(old.utf8))
        XCTAssertEqual(opened.sheetCount, 1)
        XCTAssertEqual(opened.name, "Old")
    }
}
