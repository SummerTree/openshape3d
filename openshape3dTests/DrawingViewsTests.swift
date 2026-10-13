//
//  DrawingViewsTests.swift
//  openshape3dTests
//
//  Drawings v2 (spec §15): section views (clip, cut faces, hatching,
//  cutting lines), detail views, dragged views, and drawings saved in the
//  design.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class DrawingViewsTests: XCTestCase {

    /// 10 × 10 × 10 box standing on the ground (x, z −5…5, y 0…10).
    private var box: DrawingBodyInput {
        DrawingBodyInput(body: Body(name: "Box", euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)),
                                    revision: 1))
    }

    /// The box with a vertical Ø4 hole through it, built by OCCT.
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

    private func area(_ loop: [SIMD2<Double>]) -> Double { abs(Profile.signedArea(loop)) }

    private func length(_ segments: [DrawingSegment]) -> Double {
        segments.reduce(0) { $0 + simd_distance($1.a, $1.b) }
    }

    // MARK: - Sections

    func testVerticalCutLooksFromTheSideAtTheCut() {
        let part = boxWithHole
        let front = DrawingProjection.project([part], direction: .front)
        let cut = DrawingViewKit.cut(DrawingSectionView(label: "A"), baseView: front)
        // Through the middle of Front, up its full height, looking left.
        XCTAssertEqual(cut.line.a.x, 0, accuracy: 1e-6)
        XCTAssertEqual(cut.line.b.y - cut.line.a.y, 10, accuracy: 1e-6)
        XCTAssertEqual(cut.sight, SIMD2(-1, 0))
        XCTAssertEqual(simd_dot(cut.basis.right, SIMD3(0, 0, -1)), 1, accuracy: 1e-12, "seen like the Right view")

        let view = DrawingViewKit.section([part], cut: cut)
        XCTAssertEqual(view.size.x, 10, accuracy: 0.01)
        XCTAssertEqual(view.size.y, 10, accuracy: 0.01)
        // The hole splits the cut into two 3 × 10 strips.
        XCTAssertEqual(view.sectionLoops.count, 2)
        XCTAssertEqual(view.sectionLoops.map(area).reduce(0, +), 60, accuracy: 0.05)
    }

    func testHorizontalCutShowsTheHoleAsAHole() {
        var section = DrawingSectionView(label: "A")
        section.cut = .horizontal
        let front = DrawingProjection.project([boxWithHole], direction: .front)
        let cut = DrawingViewKit.cut(section, baseView: front)
        XCTAssertEqual(cut.sight, SIMD2(0, -1), "looking down on the lower half")
        let view = DrawingViewKit.section([boxWithHole], cut: cut)
        // A square with the round hole in it: outer loop plus a hole loop.
        XCTAssertEqual(view.sectionLoops.count, 2)
        let areas = view.sectionLoops.map(area).sorted()
        XCTAssertEqual(areas[1], 100, accuracy: 0.01)
        XCTAssertEqual(areas[0], .pi * 4, accuracy: 0.2)
        // Seen like Top: width across, depth up.
        XCTAssertEqual(view.size.x, 10, accuracy: 0.01)
        XCTAssertEqual(view.size.y, 10, accuracy: 0.01)
    }

    func testFlippedCutKeepsTheOtherSide() {
        // A step: tall on the left (x < 0), short on the right.
        let tall = Euclid.Mesh.primitive(.box(width: 5, depth: 10, height: 10))
            .translated(by: Euclid.Vector(-2.5, 0, 0))
        let short = Euclid.Mesh.primitive(.box(width: 5, depth: 10, height: 4))
            .translated(by: Euclid.Vector(2.5, 0, 0))
        let bodies = [tall, short].map { DrawingBodyInput(body: Body(name: "B", euclidMesh: $0, revision: 1)) }
        let front = DrawingProjection.project(bodies, direction: .front)
        var section = DrawingSectionView(label: "A")
        section.position = 0.25
        let left = DrawingViewKit.section(bodies, cut: DrawingViewKit.cut(section, baseView: front))
        XCTAssertEqual(left.sectionLoops.map(area).reduce(0, +), 100, accuracy: 0.01, "cut through the tall part")
        section.position = 0.75
        section.flipped = true
        let flipped = DrawingViewKit.cut(section, baseView: front)
        XCTAssertEqual(flipped.sight, SIMD2(1, 0))
        let right = DrawingViewKit.section(bodies, cut: flipped)
        XCTAssertEqual(right.sectionLoops.map(area).reduce(0, +), 40, accuracy: 0.01, "cut through the short part")
        XCTAssertEqual(right.size.y, 4, accuracy: 0.01, "only the short part is kept")
    }

    func testClipKeepsTheSideBehindThePlane() {
        let clipped = DrawingViewKit.clip(box, origin: SIMD3(1, 0, 0), toward: SIMD3(1, 0, 0))
        let xs = clipped.positions.map(\.x)
        XCTAssertEqual(xs.max() ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(xs.min() ?? 0, -5, accuracy: 1e-9)
        var i = 0
        while i + 1 < clipped.edges.count {
            XCTAssertLessThanOrEqual(clipped.edges[i].x, 1 + 1e-9)
            XCTAssertLessThanOrEqual(clipped.edges[i + 1].x, 1 + 1e-9)
            i += 2
        }
    }

    func testHatchFillsEvenOdd() {
        let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let lines = DrawingViewKit.hatch([square], spacing: 1)
        let total = lines.reduce(0) { $0 + simd_distance($1.0, $1.1) }
        XCTAssertEqual(total, 100, accuracy: 3, "line length × spacing ≈ the area")
        let hole: [SIMD2<Double>] = [SIMD2(3, 3), SIMD2(7, 3), SIMD2(7, 7), SIMD2(3, 7)]
        let holed = DrawingViewKit.hatch([square, hole], spacing: 1)
        let holedTotal = holed.reduce(0) { $0 + simd_distance($1.0, $1.1) }
        XCTAssertEqual(holedTotal, 84, accuracy: 3)
        for (a, b) in holed {
            let m = (a + b) / 2
            XCTAssertFalse(m.x > 3.01 && m.x < 6.99 && m.y > 3.01 && m.y < 6.99, "no hatch inside the hole")
        }
    }

    // MARK: - Details

    func testDetailClipsTheBaseViewToItsCircle() {
        let front = DrawingProjection.project([box], direction: .front)
        var detail = DrawingDetailView(label: "B")
        detail.center = SIMD2(1, 1)   // the top-right corner
        detail.radius = 0.2           // 2 mm on a 10 mm view
        let view = DrawingViewKit.detail(detail, baseView: front)
        XCTAssertEqual(length(view.visible), 4, accuracy: 1e-6, "two 2 mm stubs of the corner's edges")
        XCTAssertEqual(view.size.x, 4, accuracy: 1e-9)
        XCTAssertEqual(view.size.y, 4, accuracy: 1e-9)

        let inside = DrawingSegment(a: SIMD2(0, 0), b: SIMD2(1, 0))
        XCTAssertEqual(DrawingViewKit.clip(inside, center: .zero, radius: 5), inside)
        let across = DrawingViewKit.clip(DrawingSegment(a: SIMD2(-10, 0), b: SIMD2(10, 0)), center: .zero, radius: 3)
        XCTAssertEqual(across?.a.x ?? 0, -3, accuracy: 1e-9)
        XCTAssertEqual(across?.b.x ?? 0, 3, accuracy: 1e-9)
        XCTAssertNil(DrawingViewKit.clip(DrawingSegment(a: SIMD2(-10, 5), b: SIMD2(10, 5)), center: .zero, radius: 3))
    }

    // MARK: - Sheet

    private func drawingWithViews() -> SavedDrawing {
        var drawing = SavedDrawing()
        drawing.sections = [DrawingSectionView(label: drawing.nextLabel())]
        var detail = DrawingDetailView(label: drawing.nextLabel())
        detail.center = SIMD2(1, 1)
        drawing.details = [detail]
        return drawing
    }

    func testSheetPlacesSectionAndDetailViews() throws {
        let drawing = drawingWithViews()
        XCTAssertEqual(drawing.sections[0].label, "A")
        XCTAssertEqual(drawing.details[0].label, "B")
        let layout = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing)
        let sectionKey = DrawingSheet.viewKey(section: drawing.sections[0].id)
        let detailKey = DrawingSheet.viewKey(detail: drawing.details[0].id)
        XCTAssertNotNil(layout.placedViews[sectionKey])
        XCTAssertNotNil(layout.placedViews[detailKey])
        XCTAssertEqual(layout.placedViews.count, 6)
        XCTAssertTrue(layout.texts.contains { $0.string == "SECTION A-A" })
        let scale = layout.scale
        XCTAssertTrue(layout.texts.contains { $0.string == "DETAIL B (\(DrawingSheet.scaleLabel(scale * 2)))" })
        XCTAssertTrue(layout.lines.contains { $0.style == .chain }, "the cutting line on Front")
        XCTAssertTrue(layout.lines.contains { $0.style == .hatch }, "the cut faces hatched")
        XCTAssertEqual(layout.texts.filter { $0.string == "A" }.count, 2, "the letter at both ends of the cut")

        // Nothing overlaps and everything stays on the sheet.
        let frames = Array(layout.placedViews.values)
        for i in frames.indices {
            let a = frames[i]
            XCTAssertGreaterThanOrEqual(a.min.x, DrawingSheet.margin)
            XCTAssertLessThanOrEqual(a.max.x, layout.size.x - DrawingSheet.margin)
            XCTAssertGreaterThanOrEqual(a.min.y, DrawingSheet.margin)
            XCTAssertLessThanOrEqual(a.max.y, layout.size.y - DrawingSheet.margin)
            for j in frames.indices where j > i {
                let b = frames[j]
                let apart = a.max.x <= b.min.x || b.max.x <= a.min.x || a.max.y <= b.min.y || b.max.y <= a.min.y
                XCTAssertTrue(apart, "views overlap \(a) \(b)")
            }
        }
        // The section view is as big as the part at the sheet scale, the
        // detail its circle at twice that.
        let section = try XCTUnwrap(layout.placedViews[sectionKey])
        XCTAssertEqual(section.max.x - section.min.x, 10 * scale, accuracy: 0.05)
        let detail = try XCTUnwrap(layout.placedViews[detailKey])
        XCTAssertEqual(detail.max.x - detail.min.x, 4 * scale * 2, accuracy: 1e-6)

        let dxf = DrawingExport.dxf(layout)
        XCTAssertTrue(dxf.contains("CUTTING") && dxf.contains("HATCH") && dxf.contains("CENTER"))
        XCTAssertEqual(dxf.components(separatedBy: "\nLINE\n").count - 1, layout.lines.count)
        XCTAssertTrue(DrawingExport.svg(layout).contains("stroke-dasharray=\"8 1.5 0.5 1.5\""))
    }

    func testDraggedViewsMoveAndProjectionsStayAligned() throws {
        var drawing = SavedDrawing()
        let plain = DrawingSheet.layout(bodies: [box], drawing: drawing)
        drawing.viewOffsets = [
            DrawingSheet.viewKey(.front): SIMD2(10, 5),
            DrawingSheet.viewKey(.top): SIMD2(7, 3),
            DrawingSheet.viewKey(.right): SIMD2(4, 9),
            DrawingSheet.viewKey(.isometric): SIMD2(-6, -2),
        ]
        let moved = DrawingSheet.layout(bodies: [box], drawing: drawing)
        func shift(_ d: DrawingViewDirection) throws -> SIMD2<Double> {
            try XCTUnwrap(moved.viewFrames[d]).min - XCTUnwrap(plain.viewFrames[d]).min
        }
        XCTAssertEqual(try shift(.front), SIMD2(10, 5))
        XCTAssertEqual(try shift(.top), SIMD2(10, 8), "Top follows Front and moves only up/down on its own")
        XCTAssertEqual(try shift(.right), SIMD2(14, 5), "the side view moves only sideways on its own")
        XCTAssertEqual(try shift(.isometric), SIMD2(-6, -2))
        XCTAssertEqual(moved.scale, plain.scale)

        // Picking a view to drag: inside a frame, or just outside it.
        let front = try XCTUnwrap(moved.viewFrames[.front])
        XCTAssertEqual(DrawingSheet.view(at: (front.min + front.max) / 2, in: moved), "front")
        XCTAssertEqual(DrawingSheet.view(at: front.min - SIMD2(2, 2), in: moved), "front")
        XCTAssertNil(DrawingSheet.view(at: SIMD2(1, 1), in: moved))
    }

    func testCacheReusesProjections() {
        let cache = DrawingViewCache()
        var drawing = drawingWithViews()
        let first = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing, cache: cache)
        // Laid out again with no bodies at all: everything comes from the cache.
        drawing.viewOffsets[DrawingSheet.viewKey(.front)] = SIMD2(1, 0)
        let again = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing, cache: cache)
        XCTAssertEqual(first.lines.count, again.lines.count)
        cache.removeAll()
        let fresh = DrawingSheet.layout(bodies: [box], drawing: SavedDrawing(), cache: cache)
        XCTAssertFalse(fresh.lines.contains { $0.style == .hatch })
    }

    // MARK: - Saved drawings

    func testSavedDrawingCodableAndForgiving() throws {
        let drawing = drawingWithViews()
        let data = try JSONEncoder().encode(drawing)
        XCTAssertEqual(try JSONDecoder().decode(SavedDrawing.self, from: data), drawing)
        // A drawing written with only an id (or by a build that lacked the
        // newer fields) still loads.
        let id = UUID()
        let minimal = try JSONDecoder().decode(SavedDrawing.self, from: Data("{\"id\":\"\(id.uuidString)\"}".utf8))
        XCTAssertEqual(minimal.id, id)
        XCTAssertEqual(minimal.options, DrawingOptions())
        XCTAssertTrue(minimal.sections.isEmpty)
    }

    func testLabelsSkipConfusableLetters() {
        var drawing = SavedDrawing()
        var labels: [String] = []
        for _ in 0..<25 {
            let label = drawing.nextLabel()
            labels.append(label)
            drawing.details.append(DrawingDetailView(label: label))
        }
        XCTAssertFalse(labels.contains("I") || labels.contains("O") || labels.contains("Q"))
        XCTAssertEqual(labels[8], "J", "I is skipped")
        XCTAssertEqual(labels[23], "AA")
    }

    func testDrawingCommandsUndo() {
        var document = DesignDocument()
        let a = SavedDrawing(options: DrawingOptions(title: "Part"))
        AddDrawingCommand(drawing: a).apply(to: &document)
        XCTAssertEqual(document.uniqueDrawingTitle(base: "Part"), "Part 2")
        XCTAssertEqual(document.uniqueDrawingTitle(base: "Other"), "Other")
        var edited = a
        edited.sections.append(DrawingSectionView(label: "A"))
        let update = UpdateDrawingCommand(old: a, new: edited)
        update.apply(to: &document)
        XCTAssertEqual(document.drawings.first?.sections.count, 1)
        update.revert(in: &document)
        XCTAssertEqual(document.drawings.first, a)
        let delete = DeleteDrawingCommand(drawing: a, index: 0)
        delete.apply(to: &document)
        XCTAssertTrue(document.drawings.isEmpty)
        delete.revert(in: &document)
        XCTAssertEqual(document.drawings, [a])
    }
}
