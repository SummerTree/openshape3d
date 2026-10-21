//
//  AccuracyKitTests.swift
//  openshape3dTests
//
//  One body measured against another — pure values, no kernel: silhouette
//  rasters and their overlap, outline distance, marching-squares loops,
//  nearest points on a triangle soup, and the report's wire form.
//

import XCTest
import UIKit
import simd
@testable import openshape3d

final class AccuracyKitTests: XCTestCase {

    // MARK: Fixtures

    /// A closed box as 12 triangles, outward-facing, corner at `origin`.
    private func box(_ size: SIMD3<Double>, at origin: SIMD3<Double> = .zero) -> AccuracyMesh {
        let o = origin, s = size
        let p: [SIMD3<Double>] = [
            o, o + SIMD3(s.x, 0, 0), o + SIMD3(s.x, s.y, 0), o + SIMD3(0, s.y, 0),
            o + SIMD3(0, 0, s.z), o + SIMD3(s.x, 0, s.z), o + SIMD3(s.x, s.y, s.z), o + SIMD3(0, s.y, s.z),
        ]
        let quads: [[UInt32]] = [
            [0, 3, 2, 1],  // back (−Z)
            [4, 5, 6, 7],  // front (+Z)
            [0, 1, 5, 4],  // bottom (−Y)
            [3, 7, 6, 2],  // top (+Y)
            [0, 4, 7, 3],  // left (−X)
            [1, 2, 6, 5],  // right (+X)
        ]
        var indices: [UInt32] = []
        for q in quads { indices += [q[0], q[1], q[2], q[0], q[2], q[3]] }
        return AccuracyMesh(positions: p, indices: indices)
    }

    private func options(_ views: [DrawingViewDirection] = [.front, .top, .right],
                         tolerance: Double = 1, alignment: AccuracyAlignment = .none) -> AccuracyOptions {
        AccuracyOptions(views: views, resolution: 256, toleranceMM: tolerance, maxSamples: 2000, alignment: alignment)
    }

    // MARK: The deviation preview

    func testDeviationPreviewColoursAVertexInsideTheModelAsExcess() throws {
        // A 20 mm cube inside a 24 mm cube centred on it: every vertex of
        // the small cube sits 2 mm inside the model — excess, orange side.
        let reference = box(SIMD3(20, 20, 20))
        let model = box(SIMD3(24, 24, 24), at: SIMD3(-2, -2, -2))
        let signed = try XCTUnwrap(DeviationPreview.signedDistances(reference: reference, model: model))
        XCTAssertEqual(signed.count, 8)
        for d in signed { XCTAssertEqual(d, -2, accuracy: 1e-6) }
        let stats = DeviationPreview.stats(of: signed, toleranceMM: 1)
        XCTAssertEqual(stats.excess, 1, accuracy: 1e-9)
        XCTAssertEqual(stats.missing, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.withinTolerance, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.meanSignedMM, -2, accuracy: 1e-6)
        // On the ramp: below the middle, and at the middle for a perfect match.
        XCTAssertLessThan(DeviationPreview.rampCoordinate(-2, maxMM: 5), 0.5)
        XCTAssertEqual(DeviationPreview.rampCoordinate(0, maxMM: 5), 0.5)
        XCTAssertEqual(DeviationPreview.rampCoordinate(50, maxMM: 5), 1, "clamped at full colour")
        let same = try XCTUnwrap(DeviationPreview.signedDistances(reference: reference, model: reference))
        XCTAssertEqual(DeviationPreview.stats(of: same, toleranceMM: 1).withinTolerance, 1, accuracy: 1e-9)
        // The ramp is grey exactly within the tolerance and coloured beyond it.
        let grey = DeviationPreview.rampColor(at: 0.5, toleranceMM: 1, maxMM: 5)
        let justInside = DeviationPreview.rampColor(at: 0.5 + 0.9 / 10, toleranceMM: 1, maxMM: 5)
        let justOutside = DeviationPreview.rampColor(at: 0.5 + 1.1 / 10, toleranceMM: 1, maxMM: 5)
        XCTAssertEqual(grey.r, justInside.r, accuracy: 1e-9)
        XCTAssertGreaterThan(justOutside.b, justOutside.r, "missing material reads blue")
        let excess = DeviationPreview.rampColor(at: 0.5 - 1.1 / 10, toleranceMM: 1, maxMM: 5)
        XCTAssertGreaterThan(excess.r, excess.b, "excess material reads orange")
        let preview = try XCTUnwrap(DeviationPreview.make(reference: reference, model: model, referenceID: BodyID(), modelID: BodyID(),
                                                          meshRevision: 1, toleranceMM: 1, maxMM: 5))
        XCTAssertEqual(preview.texcoords.count, 8)
        XCTAssertFalse(preview.ramp.isEmpty, "a PNG for the texture cache")
        // The hand-written PNG decodes: signature, IHDR of 256 × 1, and an
        // image framework reads it back pixel for pixel.
        XCTAssertEqual(Array(preview.ramp.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try XCTUnwrap(UIImage(data: preview.ramp)?.cgImage)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 1)
    }

    // MARK: Whole comparisons

    func testABodyAgainstItselfIsAPerfectMatch() throws {
        let b = box(SIMD3(20, 30, 10))
        let report = try XCTUnwrap(AccuracyKit.compare(reference: b, model: b, options: options()))
        XCTAssertEqual(report.overlays.count, 3)
        for overlay in report.overlays {
            XCTAssertEqual(overlay.iou, 1, accuracy: 1e-12, overlay.view.title)
            XCTAssertEqual(overlay.boundaryMaxMM, 0, accuracy: 1e-12)
            XCTAssertEqual(overlay.referenceAreaMM2, overlay.modelAreaMM2)
        }
        XCTAssertEqual(report.overallIoU, 1, accuracy: 1e-12)
        XCTAssertEqual(report.referenceToModel.maxMM, 0, accuracy: 1e-9)
        XCTAssertEqual(report.modelToReference.maxMM, 0, accuracy: 1e-9)
        XCTAssertEqual(report.referenceToModel.withinTolerance, 1)
        XCTAssertTrue(report.referenceWatertight)
        XCTAssertEqual(report.referenceVolumeMM3, 6000, accuracy: 1e-9)
        XCTAssertEqual(report.extentDeltaMM, .zero)
    }

    /// A 22 mm cube over a 20 mm cube, both centred: every view overlaps by
    /// 400 / 484, the outlines sit 1 mm apart at most, and the deviation is
    /// at most 1 mm with the reference INSIDE the model (negative bias).
    func testALargerCubeOverlapsByTheAreaRatioAndSitsOneMillimetreOut() throws {
        let reference = box(SIMD3(repeating: 20), at: SIMD3(repeating: -10))
        let model = box(SIMD3(repeating: 22), at: SIMD3(repeating: -11))
        let report = try XCTUnwrap(AccuracyKit.compare(reference: reference, model: model, options: options()))
        for overlay in report.overlays {
            XCTAssertEqual(overlay.iou, 400.0 / 484.0, accuracy: 0.02, overlay.view.title)
            XCTAssertEqual(overlay.referenceAreaMM2, 400, accuracy: 8)
            XCTAssertEqual(overlay.modelAreaMM2, 484, accuracy: 8)
            XCTAssertEqual(overlay.excessAreaMM2, 84, accuracy: 8)
            XCTAssertEqual(overlay.missingAreaMM2, 0, accuracy: 2)
            XCTAssertEqual(overlay.boundaryMeanMM, 1, accuracy: 0.2)
            XCTAssertLessThan(overlay.boundaryMaxMM, 1.5)
        }
        let r = report.referenceToModel
        XCTAssertEqual(r.maxMM, 1, accuracy: 1e-9)
        XCTAssertLessThan(r.meanSignedMM, 0, "reference points lie inside the model")
        XCTAssertEqual(r.withinTolerance, 1, "everything is within the 1 mm tolerance")
        let m = report.modelToReference
        XCTAssertGreaterThan(m.meanSignedMM, 0, "model points lie outside the reference")
        XCTAssertGreaterThan(m.maxMM, 1, "a model corner is √3 mm from the reference")
        XCTAssertEqual(m.maxMM, 3.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(report.extentDeltaMM, SIMD3(repeating: 2))
        XCTAssertEqual(report.modelVolumeMM3 / report.referenceVolumeMM3, 1.331, accuracy: 1e-9)
    }

    func testBaseAlignmentStandsTheModelOnTheReference() throws {
        let reference = box(SIMD3(20, 30, 10))
        let model = box(SIMD3(20, 30, 10), at: SIMD3(5, 7, -3))
        let unaligned = try XCTUnwrap(AccuracyKit.compare(reference: reference, model: model, options: options()))
        XCTAssertLessThan(unaligned.overallIoU, 0.8)
        let aligned = try XCTUnwrap(AccuracyKit.compare(reference: reference, model: model,
                                                        options: options(alignment: .base)))
        XCTAssertEqual(aligned.appliedTranslation, SIMD3(-5, -7, 3))
        XCTAssertEqual(aligned.overallIoU, 1, accuracy: 1e-12)
        XCTAssertEqual(aligned.referenceToModel.maxMM, 0, accuracy: 1e-9)
        let centred = try XCTUnwrap(AccuracyKit.compare(reference: reference, model: model,
                                                        options: options(alignment: .boundsCenter)))
        XCTAssertEqual(centred.appliedTranslation, SIMD3(-5, -7, 3))
    }

    func testTheOutlineOfACubeIsOneLoopWithItsArea() throws {
        let b = box(SIMD3(repeating: 20))
        let report = try XCTUnwrap(AccuracyKit.compare(reference: b, model: b, options: options([.front])))
        let overlay = try XCTUnwrap(report.overlays.first)
        XCTAssertEqual(overlay.referenceOutlines.count, 1)
        let outline = try XCTUnwrap(overlay.referenceOutlines.first)
        XCTAssertEqual(abs(outline.area), 400, accuracy: 6)
        // Collinear runs merged: a square is four corners, give or take the
        // 45° cuts marching squares makes at them.
        XCTAssertLessThan(outline.points.count, 12)
    }

    /// A square frame (hole through the middle) seen from above: two loops,
    /// the hole traversed the other way, and the area is the ring's.
    func testAHoleBecomesItsOwnLoop() throws {
        // Top and bottom faces of a 20 mm frame with a 10 mm square hole.
        func ring(y: Double, flip: Bool) -> ([SIMD3<Double>], [UInt32]) {
            let o: [SIMD3<Double>] = [SIMD3(0, y, 0), SIMD3(20, y, 0), SIMD3(20, y, 20), SIMD3(0, y, 20)]
            let i: [SIMD3<Double>] = [SIMD3(5, y, 5), SIMD3(15, y, 5), SIMD3(15, y, 15), SIMD3(5, y, 15)]
            var idx: [UInt32] = []
            for k in 0..<4 {
                let a = UInt32(k), b = UInt32((k + 1) % 4), c = UInt32(4 + (k + 1) % 4), d = UInt32(4 + k)
                idx += flip ? [a, c, b, a, d, c] : [a, b, c, a, c, d]
            }
            return (o + i, idx)
        }
        let (p0, i0) = ring(y: 0, flip: true), (p1, i1) = ring(y: 4, flip: false)
        let mesh = AccuracyMesh(positions: p0 + p1, indices: i0 + i1.map { $0 + 8 })
        let report = try XCTUnwrap(AccuracyKit.compare(reference: mesh, model: mesh, options: options([.top])))
        let overlay = try XCTUnwrap(report.overlays.first)
        XCTAssertEqual(overlay.referenceAreaMM2, 300, accuracy: 6)
        XCTAssertEqual(overlay.referenceOutlines.count, 2)
        let areas = overlay.referenceOutlines.map(\.area)
        XCTAssertEqual(abs(areas.first ?? 0), 400, accuracy: 6)
        XCTAssertEqual(abs(areas.last ?? 0), 100, accuracy: 4)
        XCTAssertGreaterThan(areas.first ?? 0, 0, "the outer loop runs counter-clockwise")
        XCTAssertLessThan(areas.last ?? 0, 0, "the hole runs the other way round")
        XCTAssertFalse(mesh.isWatertight, "no walls — an open mesh")
    }

    // MARK: Pieces

    func testWatertightnessWeldsSeamSplitVertices() {
        // The same box with every face carrying its own four vertices (24),
        // as a textured import keeps them: welded, still closed.
        let b = box(SIMD3(10, 10, 10))
        var positions: [SIMD3<Double>] = []
        var indices: [UInt32] = []
        for i in stride(from: 0, to: b.indices.count, by: 3) {
            for k in 0..<3 {
                indices.append(UInt32(positions.count))
                positions.append(b.positions[Int(b.indices[i + k])])
            }
        }
        let split = AccuracyMesh(positions: positions, indices: indices)
        XCTAssertTrue(split.isWatertight)
        XCTAssertEqual(split.volume, 1000, accuracy: 1e-9)
        let holed = AccuracyMesh(positions: positions, indices: Array(indices.dropLast(3)))
        XCTAssertEqual(holed.openEdgeCount, 3)
        XCTAssertFalse(holed.isWatertight)
    }

    func testDistanceTransformIsExactEuclidean() {
        var set = [UInt8](repeating: 0, count: 25)
        set[2 * 5 + 2] = 1
        let d = AccuracyKit.distanceTransform(set, width: 5, height: 5)
        XCTAssertEqual(d[0], 8.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(d[2 * 5 + 4], 2, accuracy: 1e-12)
        XCTAssertEqual(d[2 * 5 + 2], 0)
        XCTAssertEqual(d[4 * 5 + 3], 5.0.squareRoot(), accuracy: 1e-12)
        let empty = AccuracyKit.distanceTransform([UInt8](repeating: 0, count: 6), width: 3, height: 2)
        XCTAssertTrue(empty.allSatisfy { $0 == .infinity })
    }

    func testNearestPointOnATriangleAndItsSign() {
        let mesh = AccuracyMesh(positions: [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 10, 0)], indices: [0, 1, 2])
        let grid = SurfaceGrid(mesh: mesh)
        let above = grid.nearest(to: SIMD3(2, 2, 3))!
        XCTAssertEqual(above.distance, 3, accuracy: 1e-12)
        XCTAssertEqual(above.signedDistance, 3, accuracy: 1e-12, "along +Z, the triangle's normal")
        XCTAssertEqual(above.point, SIMD3(2, 2, 0))
        let below = grid.nearest(to: SIMD3(2, 2, -4))!
        XCTAssertEqual(below.signedDistance, -4, accuracy: 1e-12)
        let beyond = grid.nearest(to: SIMD3(13, -4, 0))!
        XCTAssertEqual(beyond.point, SIMD3(10, 0, 0), "the nearest vertex")
        XCTAssertEqual(beyond.distance, 5, accuracy: 1e-12)
        let edge = grid.nearest(to: SIMD3(5, -2, 0))!
        XCTAssertEqual(edge.point, SIMD3(5, 0, 0), "the nearest edge")
    }

    func testRasterCoversExactlyTheTriangle() {
        // A right triangle over the lower-left half of a 4×4 grid: the six
        // centres (x+0.5, y+0.5) with x + y < 3 are inside, and the four
        // exactly on the hypotenuse (x + y = 3) count too — a centre on a
        // shared edge belongs to both neighbours, never to neither.
        let mask = AccuracyKit.rasterize(points: [SIMD2(0, 0), SIMD2(4, 0), SIMD2(0, 4)], indices: [0, 1, 2],
                                         origin: .zero, pixelMM: 1, width: 4, height: 4)
        XCTAssertEqual(mask.reduce(0) { $0 + Int($1) }, 10)
        XCTAssertEqual(mask[0], 1)
        XCTAssertEqual(mask[3 * 4 + 3], 0)
        XCTAssertEqual(mask[1 * 4 + 1], 1)
        XCTAssertEqual(mask[2 * 4 + 1], 1, "on the hypotenuse")
        XCTAssertEqual(mask[2 * 4 + 2], 0)
        // Edge-on triangles fill nothing.
        let flat = AccuracyKit.rasterize(points: [SIMD2(0, 0), SIMD2(4, 0), SIMD2(2, 0)], indices: [0, 1, 2],
                                         origin: .zero, pixelMM: 1, width: 4, height: 4)
        XCTAssertEqual(flat.reduce(0) { $0 + Int($1) }, 0)
    }

    func testTheWireFormCarriesEverythingAndASummary() throws {
        let reference = box(SIMD3(20, 30, 10))
        let model = box(SIMD3(21, 30, 10))
        let report = try XCTUnwrap(AccuracyKit.compare(reference: reference, model: model, options: options()))
        let wire = report.wire
        XCTAssertEqual(wire.overlays.count, 3)
        XCTAssertEqual(wire.overlays.map(\.view), ["front", "top", "right"])
        XCTAssertEqual(wire.referenceBounds.sizeMM, [20, 30, 10])
        XCTAssertEqual(wire.extentDeltaMM, [1, 0, 0])
        XCTAssertFalse(wire.overlays[0].referenceOutlines.isEmpty)
        XCTAssertEqual(wire.options.alignment, "none")
        XCTAssertTrue(wire.summary.contains("IoU"), wire.summary)
        XCTAssertTrue(wire.summary.contains("+1.0 × +0.0 × +0.0 mm"), wire.summary)
        let data = try JSONEncoder().encode(wire)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["referenceToModel"])
        XCTAssertNil(object["masks"], "pixel masks never travel")
    }

    func testOptionsClampToSaneRanges() {
        let o = AccuracyOptions(views: [], resolution: 1, toleranceMM: -3, maxSamples: 1)
        XCTAssertEqual(o.views, [.front, .top, .right])
        XCTAssertEqual(o.resolution, 32)
        XCTAssertEqual(o.toleranceMM, 0)
        XCTAssertEqual(o.maxSamples, 100)
    }
}
