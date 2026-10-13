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

    // MARK: - Circles

    private func polygon(center: SIMD2<Double>, radius: Double, sides: Int,
                         from start: Double = 0, sweep: Double = 2 * .pi) -> [DrawingSegment] {
        (0..<sides).map { i in
            let a0 = start + sweep * Double(i) / Double(sides), a1 = start + sweep * Double(i + 1) / Double(sides)
            return DrawingSegment(a: center + SIMD2(cos(a0), sin(a0)) * radius,
                                  b: center + SIMD2(cos(a1), sin(a1)) * radius)
        }
    }

    func testChainsJoinSegmentsEndToEnd() {
        let square = [DrawingSegment(a: SIMD2(0, 0), b: SIMD2(1, 0)), DrawingSegment(a: SIMD2(1, 1), b: SIMD2(1, 0)),
                      DrawingSegment(a: SIMD2(1, 1), b: SIMD2(0, 1)), DrawingSegment(a: SIMD2(0, 1), b: SIMD2(0, 0))]
        let chains = DrawingCircleKit.chains(square)
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains[0].count, 5, "a closed loop ends where it starts")
        XCTAssertEqual(chains[0].first, chains[0].last)
    }

    func testCirclesAreFoundAndOtherShapesAreNot() throws {
        let full = DrawingCircleKit.circles(in: polygon(center: SIMD2(3, -2), radius: 5, sides: 64))
        XCTAssertEqual(full.count, 1)
        let c = try XCTUnwrap(full.first)
        XCTAssertEqual(c.center.x, 3, accuracy: 1e-6)
        XCTAssertEqual(c.center.y, -2, accuracy: 1e-6)
        XCTAssertEqual(c.radius, 5, accuracy: 1e-6)
        XCTAssertTrue(c.full)

        let arc = DrawingCircleKit.circles(in: polygon(center: .zero, radius: 2, sides: 16, sweep: .pi / 2))
        XCTAssertEqual(arc.map(\.full), [false], "a quarter round: an arc, dimensioned by its radius")

        // Split in two (behind something), it is still one full circle.
        let halves = polygon(center: .zero, radius: 3, sides: 24, sweep: .pi)
            + polygon(center: .zero, radius: 3, sides: 24, from: .pi, sweep: .pi).map {
                DrawingSegment(a: $0.a * 1.0, b: $0.b) }
        XCTAssertEqual(DrawingCircleKit.circles(in: halves).filter(\.full).count, 1)

        XCTAssertTrue(DrawingCircleKit.circles(in: polygon(center: .zero, radius: 5, sides: 6)).isEmpty,
                      "a hexagon is not a circle")
        let line = (0..<10).map { DrawingSegment(a: SIMD2(Double($0), 0), b: SIMD2(Double($0 + 1), 0)) }
        XCTAssertTrue(DrawingCircleKit.circles(in: line).isEmpty)
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

    func testTheHoleIsACircleWithACentreMarkAndADiameter() throws {
        let part = boxWithHole
        var drawing = SavedDrawing()
        drawing.options.showDimensions = false
        let marked = DrawingSheet.layout(bodies: [part], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
        let top = DrawingSheet.viewKey(.top)
        let hole = try XCTUnwrap(marked.circles[top]?.first { $0.full })
        XCTAssertEqual(hole.radius, 2, accuracy: 0.05)

        drawing.options.showCenterMarks = false
        let plain = DrawingSheet.layout(bodies: [part], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
        let fullCircles = marked.circles.filter { $0.key != DrawingSheet.viewKey(.isometric) }
            .values.reduce(0) { $0 + $1.filter(\.full).count }
        XCTAssertGreaterThanOrEqual(fullCircles, 1)
        XCTAssertEqual(marked.lines.filter { $0.style == .chain }.count
                       - plain.lines.filter { $0.style == .chain }.count, 2 * fullCircles, "a cross on each")

        // Tapping the outline places its diameter.
        let t = try XCTUnwrap(marked.viewTransforms[top])
        let onRim = t.sheet(hole.center + SIMD2(hole.radius, 0))
        let hit = try XCTUnwrap(DrawingCircleKit.circle(at: onRim + SIMD2(0.3, 0), in: marked))
        XCTAssertEqual(hit.view, top)
        var dia = DrawingAnnotation(kind: .diameter, view: top, a: hole.center, b: hole.center + SIMD2(0, hole.radius))
        dia.offset = 8
        XCTAssertEqual(dia.measured, 4, accuracy: 0.1)
        drawing.annotations = [dia]
        let l = DrawingSheet.layout(bodies: [part], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
        XCTAssertTrue(l.texts.contains { $0.string == "Ø4.0" }, l.texts.map(\.string).description)
        drawing.annotations[0].kind = .radius
        let r = DrawingSheet.layout(bodies: [part], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
        XCTAssertTrue(r.texts.contains { $0.string == "R2.0" })
    }

    func testDraggingACircleDimensionSwingsItsLeader() {
        let t = DrawingViewTransform(at: .zero, min: .zero, k: 2)
        let leader = DrawingAnnotationKit.circleLeader(through: SIMD2(0, 30), center: .zero, radius: 5, transform: t)
        XCTAssertEqual(leader.rim.x, 0, accuracy: 1e-9)
        XCTAssertEqual(leader.rim.y, 5, accuracy: 1e-9)
        XCTAssertEqual(leader.offset, 20, accuracy: 1e-9, "30 mm out on the sheet, less the 10 mm radius there")
    }

    func testANewCircleDimensionLeavesTheViewUpAndAway() {
        let t = DrawingViewTransform(at: .zero, min: .zero, k: 1)
        let frame = (min: SIMD2<Double>(0, 0), max: SIMD2<Double>(100, 50))
        let left = DrawingAnnotationKit.defaultCircleLeader(DrawingCircle(center: SIMD2(20, 25), radius: 5, full: true),
                                                           transform: t, frame: frame)
        XCTAssertLessThan(left.rim.x, 20, "away from the middle: to the left")
        XCTAssertGreaterThan(left.rim.y, 25, "and up")
        let u = simd_normalize(left.rim - SIMD2(20, 25))
        let outside = left.rim + u * left.offset
        XCTAssertTrue(outside.x < 0 || outside.y > 50, "clear of the view: \(outside)")
        let right = DrawingAnnotationKit.defaultCircleLeader(DrawingCircle(center: SIMD2(80, 25), radius: 5, full: true),
                                                            transform: t, frame: frame)
        XCTAssertGreaterThan(right.rim.x, 80)
    }

    func testOptionsSavedBeforeCentreMarksStillOpen() throws {
        let old = #"{"title":"Part","sheet":"a3","standard":"ansi","includeIsometric":false,"showHiddenLines":true,"showDimensions":true}"#
        let options = try JSONDecoder().decode(DrawingOptions.self, from: Data(old.utf8))
        XCTAssertEqual(options.title, "Part")
        XCTAssertEqual(options.sheet, .a3)
        XCTAssertFalse(options.includeIsometric)
        XCTAssertTrue(options.showCenterMarks)
        XCTAssertNil(options.scale)
    }
}
