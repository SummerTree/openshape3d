//
//  DrawingAnnotationsTests.swift
//  openshape3dTests
//
//  Drawings (spec §15): dimensions and notes placed on a view — snapping
//  to its corners, measuring the model whatever the sheet scale, moving
//  with the view, dragging, and saving with the drawing.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class DrawingAnnotationsTests: XCTestCase {

    /// 10 × 10 × 10 box standing on the ground.
    private var box: DrawingBodyInput {
        DrawingBodyInput(body: Body(name: "Box", euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)),
                                    revision: 1))
    }

    private let front = DrawingSheet.viewKey(.front)

    private func layout(_ drawing: SavedDrawing) -> DrawingLayout {
        DrawingSheet.layout(bodies: [box], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
    }

    /// The front view's bottom-left and bottom-right corners (view coordinates).
    private func bottomCorners(_ l: DrawingLayout) -> (SIMD2<Double>, SIMD2<Double>) {
        let points = l.snapPoints[front]!
        let lo = points.map(\.y).min()!
        let bottom = points.filter { abs($0.y - lo) < 1e-6 }
        return (bottom.min { $0.x < $1.x }!, bottom.max { $0.x < $1.x }!)
    }

    func testPickSnapsToACornerOfTheViewUnderTheTap() throws {
        let l = layout(SavedDrawing())
        let t = try XCTUnwrap(l.viewTransforms[front])
        let (corner, _) = bottomCorners(l)
        let near = t.sheet(corner) + SIMD2(1, 1)
        let pick = try XCTUnwrap(DrawingAnnotationKit.pick(near, in: l))
        XCTAssertEqual(pick.view, front)
        XCTAssertTrue(pick.snapped)
        XCTAssertEqual(pick.point, corner)

        // Inside the view, away from any corner: the point itself.
        let frame = l.placedViews[front]!
        let middle = (frame.min + frame.max) / 2
        let free = try XCTUnwrap(DrawingAnnotationKit.pick(middle, in: l))
        XCTAssertFalse(free.snapped)
        XCTAssertEqual(t.sheet(free.point).x, middle.x, accuracy: 1e-9)

        // Off every view: nothing.
        XCTAssertNil(DrawingAnnotationKit.pick(SIMD2(1, 1), in: l))
    }

    /// A rounded corner is sampled into short lines; a tap near where the
    /// straight edge meets it takes the edge's true end, not a sample.
    func testTheEndsOfLongLinesWinOverCurveSamples() throws {
        var l = DrawingLayout(size: SIMD2(100, 100))
        l.placedViews[front] = (SIMD2(0, 0), SIMD2(50, 50))
        l.viewTransforms[front] = DrawingViewTransform(at: .zero, min: .zero, k: 1)
        l.snapPoints[front] = [SIMD2(10, 10), SIMD2(10.6, 10.4)]
        l.strongSnapPoints[front] = [SIMD2(10, 10)]
        XCTAssertEqual(DrawingAnnotationKit.pick(SIMD2(10.7, 10.5), in: l)?.point, SIMD2(10, 10))
        l.strongSnapPoints[front] = []
        XCTAssertEqual(DrawingAnnotationKit.pick(SIMD2(10.7, 10.5), in: l)?.point, SIMD2(10.6, 10.4))
    }

    func testTheIsometricIsNotDimensioned() throws {
        let l = layout(SavedDrawing())
        let iso = DrawingSheet.viewKey(.isometric)
        let frame = try XCTUnwrap(l.placedViews[iso])
        let middle = (frame.min + frame.max) / 2
        XCTAssertNil(DrawingAnnotationKit.pick(middle, in: l), "foreshortened lengths")
        XCTAssertEqual(DrawingAnnotationKit.pick(middle, in: l, pictorial: true)?.view, iso, "notes may point at it")
    }

    func testOrientationFollowsThePoints() {
        XCTAssertEqual(DrawingAnnotationKit.orientation(.zero, SIMD2(10, 1)), .horizontal)
        XCTAssertEqual(DrawingAnnotationKit.orientation(.zero, SIMD2(-1, 10)), .vertical)
        XCTAssertEqual(DrawingAnnotationKit.orientation(.zero, SIMD2(10, 10)), .aligned)
    }

    func testADimensionMeasuresTheModelAtAnyScale() throws {
        var drawing = SavedDrawing()
        let (a, b) = bottomCorners(layout(drawing))
        var dim = DrawingAnnotation(kind: .linear, view: front, a: a, b: b)
        dim.orientation = .horizontal
        dim.offset = -8
        drawing.annotations = [dim]
        XCTAssertEqual(dim.measured, 10, accuracy: 1e-9)

        for scale in [1.0, 2.0] {
            drawing.options.scale = scale
            drawing.options.showDimensions = false   // only ours on the sheet
            let l = layout(drawing)
            XCTAssertEqual(l.texts.filter { $0.string == "10.0" }.count, 1, "at \(scale):1")
            let handle = try XCTUnwrap(l.annotationHandles[dim.id])
            let t = l.viewTransforms[front]!
            // Below the part by the offset, centred under it.
            XCTAssertEqual(handle.x, (t.sheet(a).x + t.sheet(b).x) / 2, accuracy: 1e-9)
            XCTAssertLessThan(handle.y, t.sheet(a).y - 5)
        }
    }

    func testItMovesWithItsView() throws {
        var drawing = SavedDrawing()
        let (a, b) = bottomCorners(layout(drawing))
        let dim = DrawingAnnotation(kind: .linear, view: front, a: a, b: b)
        drawing.annotations = [dim]
        let before = try XCTUnwrap(layout(drawing).annotationHandles[dim.id])
        drawing.viewOffsets[front] = SIMD2(7, -3)
        let after = try XCTUnwrap(layout(drawing).annotationHandles[dim.id])
        XCTAssertEqual(after.x - before.x, 7, accuracy: 1e-9)
        XCTAssertEqual(after.y - before.y, -3, accuracy: 1e-9)
        // A view that is gone takes its annotations with it.
        drawing.annotations[0].view = DrawingSheet.viewKey(section: UUID())
        XCTAssertNil(layout(drawing).annotationHandles[dim.id])
    }

    func testDraggingSetsTheOffset() {
        let a = SIMD2<Double>(0, 0), b = SIMD2<Double>(20, 0)
        XCTAssertEqual(DrawingAnnotationKit.offset(through: SIMD2(5, 12), a: a, b: b, orientation: .horizontal), 12)
        XCTAssertEqual(DrawingAnnotationKit.offset(through: SIMD2(5, -6), a: a, b: b, orientation: .horizontal), -6)
        XCTAssertEqual(DrawingAnnotationKit.offset(through: SIMD2(5, 0.2), a: a, b: b, orientation: .horizontal), 1,
                       "never onto the part")
        let (l0, l1) = DrawingAnnotationKit.dimensionLine(a, b, orientation: .aligned, offset: 5)
        XCTAssertEqual(l0, SIMD2(0, 5))
        XCTAssertEqual(l1, SIMD2(20, 5))
        let (v0, v1) = DrawingAnnotationKit.dimensionLine(SIMD2(0, 0), SIMD2(4, 9), orientation: .vertical, offset: -3)
        XCTAssertEqual(v0, SIMD2(-3, 0))
        XCTAssertEqual(v1, SIMD2(-3, 9))
    }

    func testANoteWithALeader() throws {
        var drawing = SavedDrawing()
        let (corner, _) = bottomCorners(layout(drawing))
        var note = DrawingAnnotation(kind: .note, view: front, a: corner + SIMD2(4, 4), b: corner)
        note.text = "BREAK EDGES\nDEBURR"
        note.leader = true
        drawing.annotations = [note]
        drawing.options.showDimensions = false
        let plain = layout(SavedDrawing(options: drawing.options))
        let l = layout(drawing)
        XCTAssertTrue(l.texts.contains { $0.string == "BREAK EDGES" })
        XCTAssertTrue(l.texts.contains { $0.string == "DEBURR" })
        XCTAssertEqual(l.lines.count - plain.lines.count, 3, "the leader and its arrowhead")
        XCTAssertNotNil(l.annotationHandles[note.id])

        // On the bare sheet: sheet millimetres.
        let free = DrawingAnnotation(kind: .note, view: "", a: SIMD2(30, 60), b: SIMD2(30, 60))
        drawing.annotations = [free]
        XCTAssertEqual(layout(drawing).annotationHandles[free.id]?.x, 30)
        XCTAssertEqual(DrawingAnnotationKit.annotation(at: SIMD2(31, 61.5), in: layout(drawing)), free.id)
    }

    func testSavedWithTheDrawing() throws {
        var drawing = SavedDrawing()
        var dim = DrawingAnnotation(kind: .linear, view: front, a: SIMD2(1, 2), b: SIMD2(3, 4))
        dim.orientation = .vertical
        dim.offset = -11
        drawing.annotations = [dim]
        let decoded = try JSONDecoder().decode(SavedDrawing.self, from: JSONEncoder().encode(drawing))
        XCTAssertEqual(decoded, drawing)
        // Drawings saved before annotations existed still open.
        let old = #"{"id":"\#(UUID().uuidString)"}"#
        XCTAssertTrue(try JSONDecoder().decode(SavedDrawing.self, from: Data(old.utf8)).annotations.isEmpty)
    }

    func testExportsCarryThem() throws {
        var drawing = SavedDrawing()
        let (a, b) = bottomCorners(layout(drawing))
        drawing.annotations = [DrawingAnnotation(kind: .linear, view: front, a: a, b: b)]
        let svg = DrawingExport.svg(layout(drawing))
        XCTAssertTrue(svg.contains(">10.0<"))
    }
}
