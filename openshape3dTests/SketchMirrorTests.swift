//
//  SketchMirrorTests.swift
//  openshape3dTests
//
//  Task A3: sketch mirroring geometry (mirroredSketchEntity) and the
//  MirrorSketchEntitiesCommand apply/revert round-trip with linking
//  .symmetric constraints.
//

import XCTest
import simd
@testable import openshape3d

final class SketchMirrorTests: XCTestCase {

    private let eps = 1e-9

    private func assertClose(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ msg: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, msg, file: file, line: line)
    }

    // MARK: - Line reflection

    func testLineMirroredAcrossYAxisNegatesX() {
        // Y axis: the vertical line x = 0.
        let e = SketchEntity.line(id: UUID(), a: SIMD2(2, 3), b: SIMD2(5, -1))
        guard case let .line(newID, a, b) =
            mirroredSketchEntity(e, acrossA: SIMD2(0, 0), b: SIMD2(0, 1))
        else { return XCTFail("expected a line") }

        assertClose(a, SIMD2(-2, 3), "x negates, y preserved")
        assertClose(b, SIMD2(-5, -1))
        XCTAssertNotEqual(newID, e.id, "mirror gets a fresh UUID")
    }

    func testLineMirroredAcross45DegreeAxisSwapsCoords() {
        // 45° axis through the origin (y = x) reflects (x, y) → (y, x).
        let e = SketchEntity.line(id: UUID(), a: SIMD2(2, 3), b: SIMD2(-1, 4))
        guard case let .line(_, a, b) =
            mirroredSketchEntity(e, acrossA: SIMD2(0, 0), b: SIMD2(1, 1))
        else { return XCTFail("expected a line") }

        assertClose(a, SIMD2(3, 2))
        assertClose(b, SIMD2(4, -1))
    }

    func testLineMirroredAcrossOffset45DegreeAxis() {
        // Axis y = x + 1 through (0,1)->(1,2). Reflect (x,y) → (y-1, x+1).
        let e = SketchEntity.line(id: UUID(), a: SIMD2(2, 3), b: SIMD2(4, 0))
        guard case let .line(_, a, b) =
            mirroredSketchEntity(e, acrossA: SIMD2(0, 1), b: SIMD2(1, 2))
        else { return XCTFail("expected a line") }

        assertClose(a, SIMD2(2, 3), "(2,3) is on the axis → fixed")
        assertClose(b, SIMD2(-1, 5), "(4,0) → (0-1, 4+1)")
    }

    // MARK: - Rect stays valid

    func testRectMirroredStaysValidLoLessThanHi() {
        // Mirror across an arbitrary 45° axis; reflected corners may swap, so
        // the command must recompute lo = min, hi = max component-wise.
        let e = SketchEntity.rect(id: UUID(), min: SIMD2(1, 2), max: SIMD2(4, 6))
        guard case let .rect(_, mn, mx) =
            mirroredSketchEntity(e, acrossA: SIMD2(0, 0), b: SIMD2(1, 1))
        else { return XCTFail("expected a rect") }

        XCTAssertLessThanOrEqual(mn.x, mx.x, "rect stays valid on x")
        XCTAssertLessThanOrEqual(mn.y, mx.y, "rect stays valid on y")
        // Across y = x the corners (1,2),(4,6) reflect to (2,1),(6,4).
        assertClose(mn, SIMD2(2, 1))
        assertClose(mx, SIMD2(6, 4))
    }

    // MARK: - Circle

    func testCircleMirrorReflectsCenterKeepsRadius() {
        let e = SketchEntity.circle(id: UUID(), center: SIMD2(3, 5), radius: 2.5)
        guard case let .circle(_, c, r) =
            mirroredSketchEntity(e, acrossA: SIMD2(0, 0), b: SIMD2(0, 1))
        else { return XCTFail("expected a circle") }
        assertClose(c, SIMD2(-3, 5))
        XCTAssertEqual(r, 2.5, accuracy: eps)
    }

    // MARK: - Arc midpoint reflects to the correct side

    func testArcMidpointReflectsCorrectly() {
        // Arbitrary axis so orientation flip matters.
        let a = SIMD2<Double>(-1, 0.5)
        let b = SIMD2<Double>(2, 3)
        let center = SIMD2<Double>(4, 1)
        let radius = 2.0
        let startAngle = 0.3
        let endAngle = 0.3 + 1.7  // CCW sweep of 1.7 rad

        let e = SketchEntity.arc(
            id: UUID(), center: center, radius: radius,
            startAngle: startAngle, endAngle: endAngle
        )
        guard case let .arc(_, mc, mr, ms, me) =
            mirroredSketchEntity(e, acrossA: a, b: b)
        else { return XCTFail("expected an arc") }

        XCTAssertEqual(mr, radius, accuracy: eps)
        assertClose(mc, reflectPoint(center, acrossA: a, b: b))

        // Original arc midpoint.
        let sweep = SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle)
        let origMid = SketchEntity.arcPoint(
            center: center, radius: radius, angle: startAngle + sweep / 2
        )
        // Mirrored arc midpoint, sampled on the MIRRORED arc's own sweep.
        let mSweep = SketchEntity.arcSweep(startAngle: ms, endAngle: me)
        let mirrorMid = SketchEntity.arcPoint(
            center: mc, radius: mr, angle: ms + mSweep / 2
        )

        XCTAssertEqual(mSweep, sweep, accuracy: eps, "sweep magnitude preserved")
        assertClose(mirrorMid, reflectPoint(origMid, acrossA: a, b: b),
                    "mirrored arc midpoint is the reflection of the original midpoint")
    }

    // MARK: - Ellipse & polygon (center + a sample vertex)

    func testEllipseMirrorCenterAndSampleVertex() {
        let a = SIMD2<Double>(0, 0), b = SIMD2<Double>(1, 2)  // arbitrary axis
        let center = SIMD2<Double>(3, -1)
        let rx = 4.0, ry = 1.5, rot = 0.6
        let e = SketchEntity.ellipse(
            id: UUID(), center: center, radiusX: rx, radiusY: ry, rotation: rot
        )
        guard case let .ellipse(_, mc, mrx, mry, mrot) =
            mirroredSketchEntity(e, acrossA: a, b: b)
        else { return XCTFail("expected an ellipse") }

        XCTAssertEqual(mrx, rx, accuracy: eps)
        XCTAssertEqual(mry, ry, accuracy: eps)
        assertClose(mc, reflectPoint(center, acrossA: a, b: b))

        // Parametric vertex at t = 0: center + R(rot)·(rx, 0).
        let origV = center + SIMD2(cos(rot), sin(rot)) * rx
        let mirrorV = mc + SIMD2(cos(mrot), sin(mrot)) * mrx
        assertClose(mirrorV, reflectPoint(origV, acrossA: a, b: b),
                    "reflected major-axis vertex matches")
    }

    func testPolygonMirrorCenterAndSampleVertex() {
        let a = SIMD2<Double>(0, 0), b = SIMD2<Double>(-1, 3)
        let center = SIMD2<Double>(2, 2)
        let radius = 3.0, sides = 5, rot = 0.4
        let e = SketchEntity.polygon(
            id: UUID(), center: center, radius: radius, sides: sides, rotation: rot
        )
        guard case let .polygon(_, mc, mr, msides, mrot) =
            mirroredSketchEntity(e, acrossA: a, b: b)
        else { return XCTFail("expected a polygon") }

        XCTAssertEqual(mr, radius, accuracy: eps)
        XCTAssertEqual(msides, sides)
        assertClose(mc, reflectPoint(center, acrossA: a, b: b))

        // First vertex at angle rotation.
        let origV0 = center + SIMD2(cos(rot), sin(rot)) * radius
        let mirrorV0 = mc + SIMD2(cos(mrot), sin(mrot)) * mr
        assertClose(mirrorV0, reflectPoint(origV0, acrossA: a, b: b),
                    "reflected first vertex matches")
    }

    // MARK: - MirrorSketchEntitiesCommand apply / revert

    private func documentWithMirrorSketch()
        -> (DesignDocument, SketchID, UUID, UUID, UUID) {
        var document = DesignDocument()
        let axisID = UUID(), lineID = UUID(), circleID = UUID()
        let sketch = Sketch(plane: .ground, entities: [
            .line(id: axisID, a: SIMD2(0, 0), b: SIMD2(0, 1)),      // Y-axis
            .line(id: lineID, a: SIMD2(2, 1), b: SIMD2(4, 3)),
            .circle(id: circleID, center: SIMD2(3, 2), radius: 1),
        ])
        document.sketches.append(sketch)
        return (document, sketch.id, axisID, lineID, circleID)
    }

    func testMirrorCommandAddsCopiesAndSymmetricConstraints() {
        var (document, sketchID, axisID, lineID, circleID) = documentWithMirrorSketch()

        guard let command = MirrorSketchEntitiesCommand(
            sketchID: sketchID,
            sourceEntityIDs: [lineID, circleID],
            axisEntityID: axisID,
            sketch: document.sketches[0]
        ) else { return XCTFail("command should build") }

        // 2 mirrored entities; symmetric constraints = 2 (line) + 1 (circle) = 3.
        XCTAssertEqual(command.addedEntities.count, 2)
        XCTAssertEqual(command.addedConstraints.count, 3)

        command.apply(to: &document)
        XCTAssertEqual(document.sketches[0].entities.count, 5, "3 originals + 2 mirrors")
        XCTAssertEqual(document.sketches[0].constraints.count, 3)

        // Every symmetric constraint: [sourcePoint, mirrorPoint, axis .whole].
        let mirrorIDs = Set(command.addedEntities.map(\.id))
        for c in document.sketches[0].constraints {
            XCTAssertEqual(c.kind, .symmetric)
            XCTAssertEqual(c.refs.count, 3)
            XCTAssertTrue([lineID, circleID].contains(c.refs[0].entityID),
                          "refs[0] addresses a source entity point")
            XCTAssertTrue(mirrorIDs.contains(c.refs[1].entityID),
                          "refs[1] addresses the mirror entity point")
            XCTAssertEqual(c.refs[0].role, c.refs[1].role, "paired point roles match")
            XCTAssertEqual(c.refs[2].entityID, axisID)
            XCTAssertEqual(c.refs[2].role, .whole, "axis is the .whole third ref")
        }

        // Mirror of the line reflects across Y: x negates.
        let mirrorLine = document.sketches[0].entities.first { entity in
            if case .line(let id, _, _) = entity { return mirrorIDs.contains(id) }
            return false
        }
        guard case let .line(_, ma, mb)? = mirrorLine else { return XCTFail("mirror line missing") }
        assertClose(ma, SIMD2(-2, 1))
        assertClose(mb, SIMD2(-4, 3))
    }

    func testMirrorCommandRevertRestoresExactSketch() {
        var (document, sketchID, axisID, lineID, circleID) = documentWithMirrorSketch()
        let original = document.sketches[0]

        guard let command = MirrorSketchEntitiesCommand(
            sketchID: sketchID,
            sourceEntityIDs: [lineID, circleID],
            axisEntityID: axisID,
            sketch: document.sketches[0]
        ) else { return XCTFail("command should build") }

        command.apply(to: &document)
        XCTAssertNotEqual(document.sketches[0], original)

        command.revert(in: &document)
        XCTAssertEqual(document.sketches[0], original,
                       "revert restores the exact original sketch (Equatable round-trip)")
    }

    func testMirrorCommandRejectsNonLineAxisAndEmptySources() {
        let (document, sketchID, _, lineID, circleID) = documentWithMirrorSketch()

        // Axis that is a circle → nil.
        XCTAssertNil(MirrorSketchEntitiesCommand(
            sketchID: sketchID, sourceEntityIDs: [lineID],
            axisEntityID: circleID, sketch: document.sketches[0]
        ))

        // Only the axis itself in the source set → no copies → nil.
        XCTAssertNil(MirrorSketchEntitiesCommand(
            sketchID: sketchID, sourceEntityIDs: [lineID],
            axisEntityID: lineID, sketch: document.sketches[0]
        ))
    }

    /// A rect mirror places the copy but emits NO `.symmetric` constraints:
    /// reflection re-sorts the corners into min/max, so `.endpointA`↔`.endpointA`
    /// is not a true reflection and would deform BOTH rects on the next solve.
    /// A line in the same batch keeps its two consistent links — proving the
    /// per-pair consistency guard skips only the inconsistent (rect) pairs.
    func testMirrorSkipsInconsistentRectSymmetricConstraints() {
        var document = DesignDocument()
        let axisID = UUID(), lineID = UUID(), rectID = UUID()
        let sketch = Sketch(plane: .ground, entities: [
            .line(id: axisID, a: SIMD2(10, 0), b: SIMD2(10, 1)),   // vertical axis at x=10
            .line(id: lineID, a: SIMD2(0, 0), b: SIMD2(2, 3)),
            .rect(id: rectID, min: SIMD2(0, 0), max: SIMD2(2, 1)),
        ])
        document.sketches.append(sketch)

        guard let command = MirrorSketchEntitiesCommand(
            sketchID: sketch.id,
            sourceEntityIDs: [lineID, rectID],
            axisEntityID: axisID,
            sketch: document.sketches[0]
        ) else { return XCTFail("command should build") }

        // Both copies placed; only the line's two endpoints reflect
        // role-for-role, so exactly its 2 symmetric constraints survive.
        XCTAssertEqual(command.addedEntities.count, 2)
        XCTAssertEqual(command.addedConstraints.count, 2,
                       "only the line's consistent point pairs are linked")
        for c in command.addedConstraints {
            XCTAssertEqual(c.refs[0].entityID, lineID,
                           "every emitted link addresses the line, not the re-sorted rect")
        }
    }
}
