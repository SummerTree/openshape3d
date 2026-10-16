//
//  DrawingTitleBlockTests.swift
//  openshape3dTests
//
//  Spec §15 custom title blocks: a logo (JPEG on white, sized from its
//  header, embedded in the PDF as it is and in the SVG), fields of the
//  user's own in rows of four above the layout, both shared by every sheet,
//  and Save as Default — the title block a design's first drawing starts
//  with.
//

import XCTest
import SwiftData
import PDFKit
import simd
import Euclid
@testable import openshape3d

@MainActor
final class DrawingTitleBlockTests: XCTestCase {

    private static var retained: [EditorViewModel] = []

    private var box: DrawingBodyInput {
        DrawingBodyInput(body: Body(name: "Part", euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)), revision: 1))
    }

    /// A 200 × 50 red JPEG.
    private func jpeg(width: Int = 200, height: Int = 50) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { c in
            UIColor.red.setFill()
            c.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func logo() throws -> DrawingTitleLogo { try XCTUnwrap(DrawingTitleLogo(jpeg: jpeg())) }

    func testJPEGHeaderGivesTheSize() throws {
        let info = try XCTUnwrap(JPEGInfo.size(of: jpeg(width: 321, height: 123)))
        XCTAssertEqual(info.width, 321)
        XCTAssertEqual(info.height, 123)
        XCTAssertEqual(info.components, 3)
        XCTAssertNil(JPEGInfo.size(of: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])), "a PNG is not a JPEG")
        XCTAssertNil(DrawingTitleLogo(jpeg: Data()))
    }

    func testPickedPicturesBecomeJPEGOnWhite() throws {
        // A transparent PNG, 2000 px wide: comes back a JPEG of at most 800 px.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 500), format: format).pngData { c in
            UIColor.blue.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
        }
        let prepared = try XCTUnwrap(DrawingLogoImage.prepare(png))
        let logo = try XCTUnwrap(DrawingTitleLogo(jpeg: prepared))
        XCTAssertEqual(logo.pixelWidth, 800)
        XCTAssertEqual(logo.pixelHeight, 200)
        // The transparent half is white, not black.
        let image = try XCTUnwrap(UIImage(data: prepared)?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -790, y: -100, width: 800, height: 200))
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertGreaterThan(pixel[1], 240)
        XCTAssertGreaterThan(pixel[2], 240)
    }

    func testCustomFieldsAddRowsOfFourAboveTheLayout() {
        var options = DrawingOptions(title: "Bracket")
        XCTAssertEqual(options.titleBlockSize, SIMD2(120, 28))
        options.titleCustomFields = (1...5).map { DrawingTitleCustomField(label: "Field \($0)", value: "V\($0)") }
        XCTAssertEqual(options.titleCustomRows, 2)
        XCTAssertEqual(options.titleBlockSize, SIMD2(120, 50))
        options.titleBlock = .detailed
        XCTAssertEqual(options.titleBlockSize, SIMD2(180, 58))
        options.titleBlock = .none
        XCTAssertEqual(options.titleBlockSize, .zero, "no block, no rows")
    }

    func testLayoutDrawsTheFieldsAndTheLogoInsideTheBlock() throws {
        var options = DrawingOptions(title: "Bracket")
        options.titleCustomFields = [DrawingTitleCustomField(label: "Project", value: "Apollo"),
                                     DrawingTitleCustomField(label: "Customer", value: "ACME")]
        options.titleLogo = try logo()
        let layout = DrawingSheet.layout(bodies: [box], drawing: SavedDrawing(options: options))
        let strings = layout.texts.map(\.string)
        for s in ["PROJECT", "Apollo", "CUSTOMER", "ACME", "Bracket"] {
            XCTAssertTrue(strings.contains(s), "\(s) is drawn")
        }
        let image = try XCTUnwrap(layout.images.first)
        XCTAssertEqual(layout.images.count, 1)
        XCTAssertEqual(image.size.y, 9, accuracy: 1e-9, "a 4:1 logo 36 mm wide at most is 9 mm tall")
        XCTAssertEqual(image.size.x, 36, accuracy: 1e-9)
        // Inside the block, in its title row, with the title to its right.
        let size = layout.size, margin = DrawingSheet.margin
        XCTAssertGreaterThanOrEqual(image.origin.x, size.x - margin - 120)
        XCTAssertLessThanOrEqual(image.origin.y + image.size.y, margin + 28)
        let title = try XCTUnwrap(layout.texts.first { $0.string == "Bracket" })
        XCTAssertGreaterThan(title.position.x, image.origin.x + image.size.x)
        // The fields sit above the layout's 28 mm, under the block's top.
        let project = try XCTUnwrap(layout.texts.first { $0.string == "Apollo" })
        XCTAssertGreaterThan(project.position.y, margin + 28)
        XCTAssertLessThan(project.position.y, margin + 39)
    }

    func testDetailedLogoReplacesTheCompanyLabel() throws {
        var options = DrawingOptions(title: "Bracket")
        options.titleBlock = .detailed
        options[.company] = "Laan Labs"
        var layout = DrawingSheet.layout(bodies: [box], drawing: SavedDrawing(options: options))
        XCTAssertTrue(layout.texts.contains { $0.string == "COMPANY" })
        options.titleLogo = try logo()
        layout = DrawingSheet.layout(bodies: [box], drawing: SavedDrawing(options: options))
        XCTAssertFalse(layout.texts.contains { $0.string == "COMPANY" })
        let image = try XCTUnwrap(layout.images.first)
        let company = try XCTUnwrap(layout.texts.first { $0.string == "Laan Labs" })
        XCTAssertGreaterThan(company.position.x, image.origin.x + image.size.x)
    }

    func testPDFEmbedsTheLogoOnEverySheetAndStillOpens() throws {
        var drawing = SavedDrawing(options: DrawingOptions(title: "Bracket"))
        drawing.options.titleLogo = try logo()
        drawing.pages.append(DrawingPage(following: drawing.pages[0]))
        let layouts = (0..<2).map { DrawingSheet.layout(bodies: [box], drawing: drawing, sheet: $0) }
        XCTAssertEqual(layouts.map(\.images.count), [1, 1], "the logo is the drawing's, on every sheet")
        let data = DrawingExport.pdf(layouts)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "/DCTDecode").count - 1, 2)
        XCTAssertTrue(text.contains("/Im1 Do"))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("Bracket") ?? false)

        let svg = DrawingExport.svg(layouts[0])
        XCTAssertTrue(svg.contains("<image "))
        XCTAssertTrue(svg.contains("data:image/jpeg;base64,"))
        XCTAssertFalse(DrawingExport.dxf(layouts[0]).isEmpty)
    }

    func testTheLogoAndFieldsAreTheWholeDrawingsAndSaveWithIt() throws {
        var drawing = SavedDrawing(options: DrawingOptions(title: "Bracket"))
        drawing.pages.append(DrawingPage(following: drawing.pages[0]))
        var shown = drawing.onSheet(1)
        shown.options.titleLogo = try logo()
        shown.options.titleCustomFields = [DrawingTitleCustomField(label: "Project", value: "Apollo")]
        drawing.setSheet(1, from: shown)
        XCTAssertEqual(drawing.options.titleLogo, try logo())
        XCTAssertEqual(drawing.onSheet(1).options.titleCustomFields.map(\.value), ["Apollo"])

        let back = try JSONDecoder().decode(SavedDrawing.self, from: JSONEncoder().encode(drawing))
        XCTAssertEqual(back, drawing)
        // Drawings from before carry neither.
        let old = try JSONDecoder().decode(DrawingOptions.self, from: Data(#"{"title":"Old","titleBlock":"detailed"}"#.utf8))
        XCTAssertNil(old.titleLogo)
        XCTAssertTrue(old.titleCustomFields.isEmpty)
    }

    func testTemplateKeepsTheStyleButNotThePartsOwnFields() throws {
        var options = DrawingOptions(title: "Bracket")
        options.titleBlock = .detailed
        options[.company] = "Laan Labs"
        options[.drawnBy] = "JL"
        options[.partNumber] = "BR-001"
        options[.revision] = "C"
        options.titleLogo = try logo()
        options.titleCustomFields = [DrawingTitleCustomField(label: "Tolerance", value: "±0.1")]
        let template = DrawingTitleTemplate(from: options)
        XCTAssertEqual(template.titleFields, ["company": "Laan Labs", "drawnBy": "JL"])

        var other = DrawingOptions(title: "Hinge")
        other[.partNumber] = "HG-7"
        let applied = template.applied(to: other)
        XCTAssertEqual(applied.title, "Hinge")
        XCTAssertEqual(applied[.partNumber], "HG-7")
        XCTAssertEqual(applied[.company], "Laan Labs")
        XCTAssertEqual(applied.titleBlock, .detailed)
        XCTAssertEqual(applied.titleLogo, template.logo)
        XCTAssertEqual(applied.titleCustomFields.map(\.value), ["±0.1"])
        XCTAssertNotEqual(applied.titleCustomFields[0].id, options.titleCustomFields[0].id)

        let back = try JSONDecoder().decode(DrawingTitleTemplate.self, from: JSONEncoder().encode(template))
        XCTAssertEqual(back, template)
    }

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([Project.self, PersistedBody.self, PersistedSketch.self,
                             PersistedPlane.self, PersistedImage.self, PersistedSymbol.self])
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let project = Project(name: "Title blocks")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    func testADesignsFirstDrawingStartsWithTheDefault() throws {
        let saved = AppSettings.shared.drawingTitleTemplate
        defer { AppSettings.shared.drawingTitleTemplate = saved }
        AppSettings.shared.drawingTitleTemplate = nil

        let vm = try makeViewModel()
        vm.newDrawing(designName: "Bracket")
        XCTAssertFalse(vm.hasDrawingTitleTemplate)
        vm.drawingOptions.titleBlock = .detailed
        vm.drawingOptions[.company] = "Laan Labs"
        XCTAssertTrue(vm.setDrawingLogo(jpeg: jpeg()))
        XCTAssertFalse(vm.setDrawingLogo(jpeg: Data([1, 2, 3])))
        vm.addDrawingTitleField()
        vm.addDrawingTitleField()
        XCTAssertEqual(vm.drawingOptions.titleCustomFields.map(\.label), ["Field 1", "Field 2"])
        let id = vm.drawingOptions.titleCustomFields[0].id
        vm.updateDrawingTitleField(id, label: "Project", value: "Apollo")
        vm.removeDrawingTitleField(vm.drawingOptions.titleCustomFields[1].id)
        XCTAssertFalse(vm.drawingTitleBlockIsDefault)
        vm.saveDrawingTitleTemplate()
        XCTAssertTrue(vm.drawingTitleBlockIsDefault)

        // Another design: its first drawing wears the saved title block.
        let other = try makeViewModel()
        other.newDrawing(designName: "Hinge")
        XCTAssertEqual(other.drawingOptions.titleBlock, .detailed)
        XCTAssertEqual(other.drawingOptions[.company], "Laan Labs")
        XCTAssertNotNil(other.drawingOptions.titleLogo)
        XCTAssertEqual(other.drawingOptions.titleCustomFields.map(\.label), ["Project"])
        XCTAssertTrue(other.drawingTitleBlockIsDefault)

        // Changed by hand, Use Default puts it back.
        other.removeDrawingLogo()
        XCTAssertFalse(other.drawingTitleBlockIsDefault)
        other.applyDrawingTitleTemplate()
        XCTAssertTrue(other.drawingTitleBlockIsDefault)
        XCTAssertEqual(other.drawingOptions.title, "Hinge")
    }
}
