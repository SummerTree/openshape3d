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

    // MARK: Edges and angles

    /// A 10-wide block whose top slopes from 10 high at the left to 5 at
    /// the right — seen from the front, its top meets the sides at 63.4°
    /// and 116.6°, and runs down to meet the line of the bottom at 26.6°.
    private var wedge: DrawingBodyInput {
        let outline = Path([.point(0, 0), .point(10, 0), .point(10, 5), .point(0, 10), .point(0, 0)])
        return DrawingBodyInput(body: Body(name: "Wedge", euclidMesh: Mesh.extrude(outline, depth: 4), revision: 1))
    }

    private func wedgeLayout(_ drawing: SavedDrawing = SavedDrawing()) -> DrawingLayout {
        DrawingSheet.layout(bodies: [wedge], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
    }

    /// The front view's edges: the slope, the bottom, the left and right sides.
    private func wedgeEdges(_ l: DrawingLayout) throws
        -> (slope: DrawingSegment, bottom: DrawingSegment, left: DrawingSegment, right: DrawingSegment) {
        let edges = try XCTUnwrap(l.edges[front])
        let slope = try XCTUnwrap(edges.first { abs($0.a.x - $0.b.x) > 1e-6 && abs($0.a.y - $0.b.y) > 1e-6 })
        let flat = edges.filter { abs($0.a.y - $0.b.y) < 1e-6 }
        let upright = edges.filter { abs($0.a.x - $0.b.x) < 1e-6 }.sorted { $0.a.x < $1.a.x }
        let bottom = try XCTUnwrap(flat.min { $0.a.y < $1.a.y })
        return (slope, bottom, try XCTUnwrap(upright.first), try XCTUnwrap(upright.last))
    }

    /// Pick an edge by tapping `fraction` of the way along it, just off it.
    private func tap(_ s: DrawingSegment, at fraction: Double = 0.5, in l: DrawingLayout) throws -> DrawingEdgePick {
        let t = try XCTUnwrap(l.viewTransforms[front])
        let p = t.sheet(s.a + (s.b - s.a) * fraction) + SIMD2(0.4, 0.4)
        return try XCTUnwrap(DrawingAnnotationKit.edge(at: p, in: l))
    }

    func testAnEdgeIsPickedByTappingIt() throws {
        let l = wedgeLayout()
        let e = try wedgeEdges(l)
        let pick = try tap(e.slope, in: l)
        XCTAssertEqual(pick.view, front)
        XCTAssertEqual(simd_normalize(pick.b - pick.a).y.magnitude, simd_normalize(e.slope.b - e.slope.a).y.magnitude,
                       accuracy: 1e-6)
        let frame = l.placedViews[front]!
        XCTAssertNil(DrawingAnnotationKit.edge(at: (frame.min + frame.max) / 2, in: l), "not in the middle of a face")
        XCTAssertNil(DrawingAnnotationKit.edge(at: SIMD2(1, 1), in: l))
    }

    /// A corner wins near it; a tap right on a short edge, along from its
    /// corners, takes the edge.
    func testACornerWinsUnlessTheTapIsAlongAShortEdge() throws {
        var l = DrawingLayout(size: SIMD2(100, 100))
        l.placedViews[front] = (SIMD2(0, 0), SIMD2(50, 50))
        l.viewTransforms[front] = DrawingViewTransform(at: .zero, min: .zero, k: 1)
        l.snapPoints[front] = [SIMD2(10, 10), SIMD2(10, 13)]
        l.strongSnapPoints[front] = l.snapPoints[front]
        l.edges[front] = [DrawingSegment(a: SIMD2(10, 10), b: SIMD2(10, 13)), DrawingSegment(a: SIMD2(10, 10), b: SIMD2(40, 10))]
        func target(_ p: SIMD2<Double>) -> DrawingEdgePick? {
            DrawingAnnotationKit.edge(at: p, in: l, over: DrawingAnnotationKit.pick(p, in: l))
        }
        XCTAssertNil(target(SIMD2(10.2, 10.3)), "at the corner")
        XCTAssertNil(target(SIMD2(10.8, 10.9)), "off both edges near the corner")
        XCTAssertEqual(target(SIMD2(10.2, 11.5))?.b, SIMD2(10, 13), "on the 3 mm edge, halfway up")
        XCTAssertEqual(target(SIMD2(25, 10.5))?.b, SIMD2(40, 10), "along the long edge, far from its corners")
        XCTAssertNil(target(SIMD2(25, 20)), "a bare point")
    }

    @MainActor
    func testTwoEdgesGiveTheAngleBetweenThem() throws {
        var drawing = SavedDrawing()
        let l = wedgeLayout(drawing)
        let e = try wedgeEdges(l)
        let left = try XCTUnwrap(DrawingAnnotationKit.dimension(try tap(e.slope, in: l), try tap(e.left, in: l)))
        XCTAssertEqual(left.kind, .angle)
        XCTAssertEqual(left.measured, 63.435, accuracy: 0.01)
        let right = try XCTUnwrap(DrawingAnnotationKit.dimension(try tap(e.slope, in: l), try tap(e.right, in: l)))
        XCTAssertEqual(right.measured, 116.565, accuracy: 0.01)
        XCTAssertEqual(DrawingAnnotationKit.vertex(right).x, l.edges[front]!.map { Swift.max($0.a.x, $0.b.x) }.max()!,
                       accuracy: 1e-6, "they meet at the top right corner")

        // Drawn as an arc with its value; the value is its handle.
        var angle = right
        angle.offset = DrawingAnnotationKit.defaultAngleRadius(angle, transform: l.viewTransforms[front]!)
        XCTAssertGreaterThanOrEqual(abs(angle.offset), 8)
        drawing.annotations = [angle]
        let drawn = wedgeLayout(drawing)
        XCTAssertTrue(drawn.texts.contains { $0.string == "116.6°" }, drawn.texts.map(\.string).description)
        XCTAssertGreaterThan(drawn.lines.count, l.lines.count + 8, "an arc and two arrowheads")
        let handle = try XCTUnwrap(drawn.annotationHandles[angle.id])
        XCTAssertEqual(DrawingAnnotationKit.annotation(at: handle, in: drawn), angle.id)
        XCTAssertEqual(angle.listTitle, "116.6°")
    }

    /// The bottom and the slope meet past the end of the part: the arc is
    /// drawn round that point, the edges carried out to it.
    func testEdgesThatMeetPastThePart() throws {
        var drawing = SavedDrawing()
        drawing.options.showDimensions = false
        let l = wedgeLayout(drawing)
        let e = try wedgeEdges(l)
        var angle = try XCTUnwrap(DrawingAnnotationKit.dimension(try tap(e.bottom, in: l), try tap(e.slope, in: l)))
        XCTAssertEqual(angle.measured, 26.565, accuracy: 0.01)
        XCTAssertEqual(DrawingAnnotationKit.vertex(angle).x - e.left.a.x, 20, accuracy: 1e-6, "20 mm along from the left")
        let t = l.viewTransforms[front]!
        angle.offset = 8
        drawing.annotations = [angle]
        let near = wedgeLayout(drawing)
        angle.offset = DrawingAnnotationKit.angleRadius(through: t.sheet(DrawingAnnotationKit.vertex(angle)) + SIMD2(0, 30),
                                                       angle, transform: t)
        XCTAssertEqual(angle.offset, 30, accuracy: 1e-9, "dragging sets the arc's radius")
        let behind = DrawingAnnotationKit.angleRadius(
            through: t.sheet(DrawingAnnotationKit.vertex(angle)) + SIMD2(20, 0), angle, transform: t)
        XCTAssertEqual(behind, -20, accuracy: 1e-9, "dragged across the corner, the arc goes with it")
        drawing.annotations = [angle]
        let far = wedgeLayout(drawing)
        XCTAssertTrue(near.texts.contains { $0.string == "26.6°" })
        // Short of the part, the edges are carried in to the arc; past it, out.
        let thin = { (l: DrawingLayout) in l.lines.filter { $0.style == .thin }.count }
        XCTAssertGreaterThan(thin(near), thin(l))
        XCTAssertGreaterThan(thin(far), thin(l))
    }

    func testParallelEdgesGiveTheGapBetweenThem() throws {
        let l = wedgeLayout()
        let e = try wedgeEdges(l)
        let gap = try XCTUnwrap(DrawingAnnotationKit.dimension(try tap(e.left, at: 0.3, in: l), try tap(e.right, in: l)))
        XCTAssertEqual(gap.kind, .linear)
        XCTAssertEqual(gap.orientation, .horizontal)
        XCTAssertEqual(gap.measured, 10, accuracy: 1e-6)
        XCTAssertNil(DrawingAnnotationKit.dimension(try tap(e.left, at: 0.3, in: l), try tap(e.left, at: 0.7, in: l)),
                     "one line twice is nothing")
    }

    func testAnEdgeAndAPointGiveTheDistanceSquareAcross() throws {
        let l = wedgeLayout()
        let e = try wedgeEdges(l)
        let top = e.left.a.y > e.left.b.y ? e.left.a : e.left.b
        let height = try XCTUnwrap(DrawingAnnotationKit.dimension(try tap(e.bottom, in: l), point: top))
        XCTAssertEqual(height.orientation, .vertical)
        XCTAssertEqual(height.measured, 10, accuracy: 1e-6)
        let corner = e.right.a.y > e.right.b.y ? e.right.a : e.right.b
        let slant = try XCTUnwrap(DrawingAnnotationKit.dimension(try tap(e.slope, in: l), point: e.bottom.a.x < e.bottom.b.x ? e.bottom.a : e.bottom.b))
        XCTAssertEqual(slant.orientation, .aligned)
        XCTAssertEqual(slant.measured, 10 * 10 / sqrt(125), accuracy: 1e-6, "the bottom-left corner's true gap to the slope")
        XCTAssertNil(DrawingAnnotationKit.dimension(try tap(e.slope, in: l), point: corner), "a point on the line")
    }

    func testAnglesFormatAndSave() throws {
        XCTAssertEqual(DrawingAnnotationKit.angleString(45), "45°")
        XCTAssertEqual(DrawingAnnotationKit.angleString(22.5), "22.5°")
        XCTAssertEqual(DrawingAnnotationKit.angleString(89.96), "90°")
        var angle = DrawingAnnotation(kind: .angle, view: front, a: .zero, b: SIMD2(10, 0))
        angle.c = .zero
        angle.d = SIMD2(0, 5)
        let back = try JSONDecoder().decode(DrawingAnnotation.self, from: JSONEncoder().encode(angle))
        XCTAssertEqual(back, angle)
        XCTAssertEqual(back.measured, 90, accuracy: 1e-9)
        // Saved before angles: no second edge.
        let old = #"{"kind":"linear","view":"front","a":[0,0],"b":[3,4]}"#
        let linear = try JSONDecoder().decode(DrawingAnnotation.self, from: Data(old.utf8))
        XCTAssertEqual(linear.measured, 5, accuracy: 1e-9)
    }

    /// A straight line that arrives in pieces is one edge.
    func testCollinearPiecesJoinIntoOneEdge() {
        var segments = (0..<10).map { DrawingSegment(a: SIMD2(Double($0), 0), b: SIMD2(Double($0 + 1), 0)) }
        segments.append(DrawingSegment(a: SIMD2(10, 0), b: SIMD2(10, 5)))
        let runs = DrawingCircleKit.straightRuns(segments)
        XCTAssertEqual(runs.count, 2)
        let flat = runs.first { $0.line.a.y == $0.line.b.y }
        XCTAssertEqual(Set([flat?.line.a, flat?.line.b]), Set([SIMD2<Double>(0, 0), SIMD2<Double>(10, 0)]))
        XCTAssertEqual(flat?.joins.count, 9)
    }

    /// A cylinder standing up: from the front its top circle is seen edge on,
    /// a row of short lines — tapping it picks the whole top edge, and it has
    /// no points to snap to along it.
    func testACircleSeenEdgeOnIsAnEdge() throws {
        let cylinder = DrawingBodyInput(body: Body(name: "Pin", euclidMesh: .primitive(.cylinder(radius: 5, height: 10)),
                                                   revision: 1))
        let l = DrawingSheet.layout(bodies: [cylinder], drawing: SavedDrawing(), formatLength: { String(format: "%.1f", $0) })
        let t = try XCTUnwrap(l.viewTransforms[front])
        let top = try XCTUnwrap(l.edges[front]?.filter { abs($0.a.y - $0.b.y) < 1e-6 }.max { $0.a.y < $1.a.y })
        XCTAssertEqual(abs(top.b.x - top.a.x), 10, accuracy: 1e-6, "the full width")
        let inside = (l.snapPoints[front] ?? []).filter {
            abs($0.y - top.a.y) < 1e-6 && $0.x > Swift.min(top.a.x, top.b.x) + 1e-6 && $0.x < Swift.max(top.a.x, top.b.x) - 1e-6
        }
        XCTAssertEqual(inside, [])
        let middle = t.sheet((top.a + top.b) / 2) + SIMD2(0, -0.3)
        let pick = DrawingAnnotationKit.pick(middle, in: l)
        XCTAssertEqual(DrawingAnnotationKit.edge(at: middle, in: l, over: pick)?.a, top.a)
    }

    /// A corner too small for the arc gets it across the corner, the edges
    /// carried on through it.
    func testASmallCornersArcGoesAcrossIt() throws {
        let t = DrawingViewTransform(at: .zero, min: .zero, k: 1)
        var angle = DrawingAnnotation(kind: .angle, view: front, a: .zero, b: SIMD2(4, 0))
        angle.c = .zero
        angle.d = SIMD2(0, 3)
        XCTAssertEqual(DrawingAnnotationKit.defaultAngleRadius(angle, transform: t), -8)
        angle.b = SIMD2(40, 0)
        angle.d = SIMD2(0, 30)
        XCTAssertEqual(DrawingAnnotationKit.defaultAngleRadius(angle, transform: t), 18, accuracy: 1e-9)

        var drawing = SavedDrawing()
        angle.b = SIMD2(4, 0)
        angle.d = SIMD2(0, 3)
        angle.offset = -8
        drawing.annotations = [angle]
        let placed = DrawingSheet.layout(bodies: [box], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
        let handle = try XCTUnwrap(placed.annotationHandles[angle.id])
        let corner = try XCTUnwrap(placed.viewTransforms[front]).sheet(.zero)
        XCTAssertLessThan(handle.x, corner.x, "the value sits down and left of the corner, away from both edges")
        XCTAssertLessThan(handle.y, corner.y)
    }

    // MARK: - Tolerances, prefix and suffix

    private func format(_ mm: Double) -> String { String(format: "%g mm", (mm * 1000).rounded() / 1000) }

    func testValuesCarryTheirTolerance() {
        var dim = DrawingAnnotation(kind: .linear, view: front, a: .zero, b: SIMD2(40, 0))
        func pieces() -> [DrawingAnnotationKit.ValuePiece] { DrawingAnnotationKit.valuePieces(dim, format: format) }
        XCTAssertEqual(pieces(), [.text("40 mm")])
        dim.tolerance = .symmetrical
        dim.upper = 0.1
        XCTAssertEqual(pieces(), [.text("40 ±0.1 mm")])
        dim.tolerance = .deviation
        dim.lower = -0.05
        XCTAssertEqual(pieces(), [.text("40"), .stack("+0.1", "-0.05"), .text(" mm")])
        dim.lower = 0
        XCTAssertEqual(pieces(), [.text("40"), .stack("+0.1", "0"), .text(" mm")])
        dim.lower = -0.05
        dim.tolerance = .limits
        XCTAssertEqual(pieces(), [.stack("40.1", "39.95"), .text(" mm")])
        dim.tolerance = .basic
        XCTAssertEqual(pieces(), [.boxed("40 mm")])

        // Prefix and suffix, round a diameter's symbol.
        var hole = DrawingAnnotation(kind: .diameter, view: front, a: .zero, b: SIMD2(3, 0))
        hole.prefix = " 2× "
        hole.suffix = "THRU"
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(hole, format: format), [.text("2× Ø6 mm THRU")])
        hole.tolerance = .basic
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(hole, format: format),
                       [.text("2× "), .boxed("Ø6 mm"), .text(" THRU")])
        hole.tolerance = .deviation
        XCTAssertEqual(DrawingAnnotationKit.valueString(hole, format: format), "2× Ø6 +0.1/-0.1 mm THRU")

        // An angle's deviations are degrees.
        var angle = DrawingAnnotation(kind: .angle, view: front, a: .zero, b: SIMD2(10, 0))
        angle.c = .zero
        angle.d = SIMD2(0, 5)
        angle.tolerance = .symmetrical
        angle.upper = 0.25
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(angle, format: format), [.text("90 ±0.25°")])
    }

    func testPrecisionFixesTheDecimals() throws {
        var dim = DrawingAnnotation(kind: .linear, view: front, a: .zero, b: SIMD2(40, 0))
        func pieces() -> [DrawingAnnotationKit.ValuePiece] { DrawingAnnotationKit.valuePieces(dim, format: format) }
        dim.precision = 2
        XCTAssertEqual(pieces(), [.text("40.00")], "trailing zeros kept (no unit from the bare default)")
        let mm: (Double, Int) -> String = { DisplayUnit.millimeters.fixedLengthString(fromMM: $0, decimals: $1) }
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(dim, format: format, fixed: mm), [.text("40.00 mm")])
        dim.tolerance = .symmetrical
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(dim, format: format, fixed: mm), [.text("40.00 ±0.10 mm")],
                       "the tolerance to the same places")
        dim.tolerance = .deviation
        dim.lower = 0
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(dim, format: format, fixed: mm),
                       [.text("40.00"), .stack("+0.10", "0"), .text(" mm")], "a zero deviation stays bare")
        dim.tolerance = .limits
        dim.precision = 0
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(dim, format: format, fixed: mm),
                       [.stack("40", "40"), .text(" mm")])

        // Inches, and an angle's degrees.
        XCTAssertEqual(DisplayUnit.inches.fixedLengthString(fromMM: 25.4, decimals: 3), "1.000\"")
        var angle = DrawingAnnotation(kind: .angle, view: front, a: .zero, b: SIMD2(10, 0))
        angle.c = .zero
        angle.d = SIMD2(10, 5)
        angle.precision = 3
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(angle, format: format), [.text("26.565°")])
        angle.precision = nil
        XCTAssertEqual(DrawingAnnotationKit.valuePieces(angle, format: format), [.text("26.6°")])

        XCTAssertEqual(DrawingAnnotationKit.precisionChoices.map(DrawingAnnotationKit.precisionTitle),
                       ["Auto", "1", "0.1", "0.01", "0.001", "0.0001"])
        XCTAssertEqual(DrawingAnnotationKit.fixedNumber(-0.0001, 2), "0.00", "never -0")

        // Saved with the drawing; out-of-range values clamped on load.
        dim.precision = 3
        let back = try JSONDecoder().decode(DrawingAnnotation.self, from: JSONEncoder().encode(dim))
        XCTAssertEqual(back.precision, 3)
        let wild = Data(#"{"kind":"linear","view":"front","a":[0,0],"b":[1,0],"precision":9}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DrawingAnnotation.self, from: wild).precision, 4)
        let old = Data(#"{"kind":"linear","view":"front","a":[0,0],"b":[1,0]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(DrawingAnnotation.self, from: old).precision)

        // The sheet writes it.
        var drawing = SavedDrawing()
        drawing.options.showDimensions = false
        let (a, b) = bottomCorners(layout(drawing))
        var placed = DrawingAnnotation(kind: .linear, view: front, a: a, b: b)
        placed.precision = 3
        drawing.annotations = [placed]
        XCTAssertTrue(layout(drawing).texts.contains { $0.string == "10.000" })
    }

    @MainActor func testTheListShowsTheTolerance() {
        var dim = DrawingAnnotation(kind: .radius, view: front, a: .zero, b: SIMD2(3, 0))
        XCTAssertFalse(dim.listTitle.contains("±"))
        dim.tolerance = .symmetrical
        XCTAssertTrue(dim.listTitle.hasPrefix("R"))
        XCTAssertTrue(dim.listTitle.contains(" ±"))
        XCTAssertEqual(DrawingAnnotation(kind: .note, view: "", a: .zero, b: .zero).listTitle, "Note")
    }

    func testToleranceIsDrawnStackedOrBoxed() throws {
        var drawing = SavedDrawing()
        drawing.options.showDimensions = false
        let (a, b) = bottomCorners(layout(drawing))
        var dim = DrawingAnnotation(kind: .linear, view: front, a: a, b: b)
        dim.orientation = .horizontal
        dim.offset = -8
        dim.tolerance = .deviation
        dim.upper = 0.2
        dim.lower = -0.1
        drawing.annotations = [dim]
        var l = layout(drawing)
        let value = try XCTUnwrap(l.texts.first { $0.string == "10.0" })
        let up = try XCTUnwrap(l.texts.first { $0.string == "+0.2" })
        let down = try XCTUnwrap(l.texts.first { $0.string == "-0.1" })
        XCTAssertLessThan(up.height, value.height, "deviations are smaller")
        XCTAssertGreaterThan(up.position.x, value.position.x, "after the value")
        XCTAssertEqual(up.position.x, down.position.x, accuracy: 1e-9, "one over the other")
        XCTAssertGreaterThan(up.position.y, down.position.y)
        // Still centred on the dimension line.
        let t = try XCTUnwrap(l.viewTransforms[front])
        let mid = (t.sheet(a).x + t.sheet(b).x) / 2
        let end = up.position.x + DrawingAnnotationKit.textWidth("+0.2", height: up.height)
        XCTAssertEqual((value.position.x + end) / 2, mid, accuracy: 1)

        // Basic: a box round the value.
        drawing.annotations[0].tolerance = .basic
        let before = layout({ var d = drawing; d.annotations[0].tolerance = .none; return d }()).lines.count
        l = layout(drawing)
        XCTAssertEqual(l.lines.count, before + 4)
        XCTAssertNotNil(l.texts.first { $0.string == "10.0" })

        // Exports carry the symbols the PDF font has.
        drawing.annotations[0].tolerance = .symmetrical
        let pdf = String(decoding: DrawingExport.pdf(layout(drawing)), as: UTF8.self)
        XCTAssertTrue(pdf.contains("(10.0 \\2610.2)"), "± as its WinAnsi code")
    }

    func testPDFTextKeepsLatinSymbols() {
        XCTAssertEqual(DrawingExport.pdfEscaped("Ø6 ±0.1 90° (a)"), "\\3306 \\2610.1 90\\260 \\(a\\)")
        XCTAssertEqual(DrawingExport.pdfEscaped("√"), "?")
    }

    func testTolerancesSave() throws {
        var dim = DrawingAnnotation(kind: .linear, view: front, a: .zero, b: SIMD2(3, 4))
        dim.prefix = "2×"
        dim.suffix = "TYP"
        dim.tolerance = .limits
        dim.upper = 0.3
        dim.lower = -0.2
        XCTAssertEqual(try JSONDecoder().decode(DrawingAnnotation.self, from: JSONEncoder().encode(dim)), dim)
        // Saved before tolerances.
        let old = #"{"kind":"linear","view":"front","a":[0,0],"b":[3,4]}"#
        let plain = try JSONDecoder().decode(DrawingAnnotation.self, from: Data(old.utf8))
        XCTAssertEqual(plain.tolerance, .none)
        XCTAssertEqual(plain.prefix, "")
        XCTAssertEqual(plain.upper, 0.1)
        XCTAssertEqual(plain.lower, -0.1)
    }

    // MARK: - Centrelines

    func testAHiddenHoleGetsTheCentrelineBetweenItsSides() throws {
        var drawing = SavedDrawing()
        drawing.options.showDimensions = false
        drawing.options.showCenterMarks = false
        let l = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
        let t = try XCTUnwrap(l.viewTransforms[front])
        // The hole's sides, dashed in the front view: two vertical hidden lines 4 apart.
        let sides = try XCTUnwrap(l.hiddenEdges[front]).filter { abs($0.a.x - $0.b.x) < 1e-6 }
        XCTAssertEqual(sides.count, 2, "\(l.hiddenEdges[front] ?? [])")
        XCTAssertEqual(abs(sides[0].a.x - sides[1].a.x), 4, accuracy: 0.05)
        XCTAssertNil(DrawingAnnotationKit.edge(at: t.sheet((sides[0].a + sides[0].b) / 2), in: l),
                     "a Dimension tap does not pick hidden lines")
        func pick(_ s: DrawingSegment) throws -> DrawingEdgePick {
            try XCTUnwrap(DrawingAnnotationKit.edge(at: t.sheet((s.a + s.b) / 2) + SIMD2(0.4, 0), in: l, hidden: true))
        }
        let line = try XCTUnwrap(DrawingAnnotationKit.centerline(try pick(sides[0]), try pick(sides[1])))
        XCTAssertEqual(line.kind, .centerline)
        XCTAssertEqual(line.a.x, (sides[0].a.x + sides[1].a.x) / 2, accuracy: 1e-6, "midway")
        XCTAssertEqual(line.b.x, line.a.x, accuracy: 1e-6)
        XCTAssertEqual(abs(line.b.y - line.a.y), 10, accuracy: 0.05, "the length of the hole")

        // Drawn as a chain line carried 3 mm past each end.
        drawing.annotations = [line]
        let drawn = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing, formatLength: { String(format: "%.1f", $0) })
        let chain = drawn.lines.filter { $0.style == .chain }
        XCTAssertEqual(chain.count, l.lines.filter { $0.style == .chain }.count + 1)
        let mine = try XCTUnwrap(chain.last)
        XCTAssertEqual(simd_distance(mine.a, mine.b), simd_distance(t.sheet(line.a), t.sheet(line.b)) + 6, accuracy: 1e-6)
        XCTAssertNotNil(drawn.annotationHandles[line.id])
        XCTAssertEqual(DrawingAnnotationKit.annotation(at: (mine.a + mine.b) / 2, in: drawn), line.id)
    }

    func testCentrelinesNeedParallelEdgesOrTwoPoints() throws {
        let l = wedgeLayout()
        let edges = try wedgeEdges(l)
        // The wedge's slope and its base are not parallel.
        XCTAssertNil(DrawingAnnotationKit.centerline(try tap(edges.slope, in: l), try tap(edges.bottom, in: l)))
        // One line tapped twice is not two.
        XCTAssertNil(DrawingAnnotationKit.centerline(try tap(edges.bottom, in: l), try tap(edges.bottom, at: 0.3, in: l)))
        // Its two sides: upright, midway, as long as the taller.
        let middle = try XCTUnwrap(DrawingAnnotationKit.centerline(try tap(edges.left, in: l), try tap(edges.right, in: l)))
        XCTAssertEqual(middle.a.x, (edges.left.a.x + edges.right.a.x) / 2, accuracy: 1e-6)
        XCTAssertEqual(middle.b.x, middle.a.x, accuracy: 1e-6)
        let tallest = Swift.max(abs(edges.left.b.y - edges.left.a.y), abs(edges.right.b.y - edges.right.a.y))
        XCTAssertEqual(abs(middle.b.y - middle.a.y), tallest, accuracy: 1e-6)
        let through = try XCTUnwrap(DrawingAnnotationKit.centerline(view: front, SIMD2(1, 1), SIMD2(5, 1)))
        XCTAssertEqual(through.a, SIMD2(1, 1))
        XCTAssertEqual(through.b, SIMD2(5, 1))
        XCTAssertNil(DrawingAnnotationKit.centerline(view: front, SIMD2(1, 1), SIMD2(1, 1)))
        let back = try JSONDecoder().decode(DrawingAnnotation.self, from: JSONEncoder().encode(through))
        XCTAssertEqual(back, through)
    }

    func testThroughAlignedViewsCarriesACentrelineOnThroughTopAndTheSide() throws {
        var drawing = SavedDrawing()
        drawing.options.showDimensions = false
        drawing.options.showCenterMarks = false
        let plain = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing)
        let t = try XCTUnwrap(plain.viewTransforms[front])
        let f = try XCTUnwrap(plain.placedViews[front])
        let top = try XCTUnwrap(plain.placedViews[DrawingSheet.viewKey(.top)])
        let side = try XCTUnwrap(plain.placedViews[DrawingSheet.viewKey(.right)])
        // Up the middle of the front view (the hole's axis), and across it.
        let mid = t.view((f.min + f.max) / 2)
        let up = try XCTUnwrap(DrawingAnnotationKit.centerline(view: front, mid - SIMD2(0, 2), mid + SIMD2(0, 2)))
        let across = try XCTUnwrap(DrawingAnnotationKit.centerline(view: front, mid - SIMD2(2, 0), mid + SIMD2(2, 0)))
        let slant = try XCTUnwrap(DrawingAnnotationKit.centerline(view: front, mid, mid + SIMD2(2, 2)))
        drawing.annotations = [up, across, slant]
        var l = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing)
        XCTAssertEqual(l.spannableCenterlines, [up.id, across.id], "a slanted line lines up with nothing")
        let before = l.lines.filter { $0.style == .chain }

        for i in 0..<2 { drawing.annotations[i].span = true }
        l = DrawingSheet.layout(bodies: [boxWithHole], drawing: drawing)
        let after = l.lines.filter { $0.style == .chain }
        XCTAssertEqual(after.count, before.count, "still one line each")
        let over = DrawingAnnotationKit.centerlineOverrun
        // Up: from the front's own short line on through the whole top view.
        let vertical = try XCTUnwrap(after.first { abs($0.a.x - $0.b.x) < 1e-9 && abs($0.b.y - $0.a.y) > 20 })
        let ys = [vertical.a.y, vertical.b.y].sorted()
        let topBelow = top.max.y < f.min.y
        XCTAssertEqual(topBelow ? ys[0] : ys[1], topBelow ? top.min.y - over : top.max.y + over, accuracy: 1e-6)
        XCTAssertEqual(topBelow ? ys[1] : ys[0], t.sheet(topBelow ? up.b : up.a).y + (topBelow ? over : -over), accuracy: 1e-6,
                       "the front end stays where it was drawn")
        // Across: on through the side view.
        let horizontal = try XCTUnwrap(after.first { abs($0.a.y - $0.b.y) < 1e-9 && abs($0.b.x - $0.a.x) > 20 })
        let xs = [horizontal.a.x, horizontal.b.x].sorted()
        if side.max.x < f.min.x {
            XCTAssertEqual(xs[0], side.min.x - over, accuracy: 1e-6)
        } else {
            XCTAssertEqual(xs[1], side.max.x + over, accuracy: 1e-6)
        }
        // Its handle stays on its own view, for selecting it there.
        XCTAssertEqual(try XCTUnwrap(l.annotationHandles[up.id]), t.sheet(mid), "\(l.annotationHandles[up.id]!)")

        // Saved, and older drawings read as not spanning.
        let back = try JSONDecoder().decode(DrawingAnnotation.self, from: JSONEncoder().encode(drawing.annotations[0]))
        XCTAssertTrue(back.span)
        let old = try JSONDecoder().decode(DrawingAnnotation.self, from: Data(#"{"kind":"centerline","view":"front","a":[0,0],"b":[0,1]}"#.utf8))
        XCTAssertFalse(old.span)
        XCTAssertEqual(DrawingAnnotationKit.alignedViews(of: DrawingSheet.viewKey(.isometric), along: SIMD2(0, 1)), [])
    }

    @MainActor func testACentrelineIsListedByName() {
        XCTAssertEqual(DrawingAnnotation(kind: .centerline, view: front, a: .zero, b: SIMD2(1, 0)).listTitle, "Centreline")
        XCTAssertEqual(DrawingAnnotation(kind: .boltCircle, view: front, a: .zero, b: SIMD2(1, 0)).listTitle, "Bolt Circle")
    }

    // MARK: - Bolt circles

    func testABoltCirclePassesThroughItsThreePoints() throws {
        let p = SIMD2(30.0, 20), q = SIMD2(20.0, 30), r = SIMD2(10.0, 20)
        let circle = try XCTUnwrap(DrawingAnnotationKit.boltCircle(view: front, p, q, r))
        XCTAssertEqual(circle.kind, .boltCircle)
        XCTAssertEqual(circle.a.x, 20, accuracy: 1e-9)
        XCTAssertEqual(circle.a.y, 20, accuracy: 1e-9)
        for point in [p, q, r] { XCTAssertEqual(simd_distance(circle.a, point), 10, accuracy: 1e-9) }
        XCTAssertTrue(circle.isCenterline)

        // In a line, or a point twice: no circle.
        XCTAssertNil(DrawingAnnotationKit.boltCircle(view: front, .zero, SIMD2(5, 0), SIMD2(10, 0.01)))
        XCTAssertNil(DrawingAnnotationKit.boltCircle(view: front, .zero, SIMD2(5, 5), SIMD2(5, 5)))
    }

    func testABoltCircleIsDrawnAsOneChainRun() throws {
        var drawing = SavedDrawing()
        drawing.options.showDimensions = false
        drawing.options.showCenterMarks = false
        let plain = layout(drawing)
        let t = try XCTUnwrap(plain.viewTransforms[front])
        let circle = try XCTUnwrap(DrawingAnnotationKit.boltCircle(view: front, SIMD2(1, 5), SIMD2(5, 9), SIMD2(9, 5)))
        drawing.annotations = [circle]
        let l = layout(drawing)
        let chain = l.lines.filter { $0.style == .chain }
        XCTAssertEqual(chain.count, 72)
        let radius = 4 * t.k
        for line in chain { XCTAssertEqual(simd_distance(line.a, t.sheet(SIMD2(5, 5))), radius, accuracy: 1e-6) }
        let handle = try XCTUnwrap(l.annotationHandles[circle.id])
        XCTAssertEqual(handle.y, t.sheet(SIMD2(5, 5)).y + radius, accuracy: 1e-6, "selected at its top")

        // One run, so the dashes carry on round it: one subpath in the SVG,
        // one polyline in the DXF.
        XCTAssertEqual(DrawingExport.runs(chain).count, 1)
        XCTAssertEqual(DrawingExport.runs(chain).first?.count, 73)
        let svg = DrawingExport.svg(l)
        let chainPath = try XCTUnwrap(svg.components(separatedBy: "\n").first { $0.contains("8 1.5 0.5 1.5") })
        XCTAssertEqual(chainPath.filter { $0 == "M" }.count, 1)
        let dxf = DrawingExport.dxf(l)
        XCTAssertEqual(dxf.components(separatedBy: "\nPOLYLINE\n8\nCUTTING\n").count - 1, 1)
        XCTAssertTrue(dxf.contains("POLYLINE\n8\nCUTTING\n66\n1\n10\n0\n20\n0\n30\n0\n70\n128\n"))
    }
}
