//
//  ShapeAncestryTests.swift
//  openshape3dTests
//
//  Kernel-history ancestry for booleans (docs/TOPO_NAMING_HISTORY_DESIGN.md
//  step 1): result faces know WHICH input sub-shape they came from, via
//  OCCT's own history — including across the UnifySameDomain seam-merge hop.
//  Nothing consumes ancestry in production yet; these tests pin the contract
//  element naming will build on. Pure values over OCCTKernel.
//

import XCTest
import simd
@testable import openshape3d

final class ShapeAncestryTests: XCTestCase {

    private func box(_ w: Double, _ d: Double, _ h: Double,
                     at t: SIMD3<Double> = .zero) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: w, depth: d, height: h),
            placement: t == .zero ? .identity : Transform3D(translation: t)))
    }

    private func faceCount(_ handle: BRepHandle) -> Int {
        let counts = OCCTKernel.faceTypeCounts(handle)
        return counts.planar + counts.cylindrical + counts.other
    }

    // MARK: - Geometry parity

    /// Ancestry is observation only: the history variant must hand back the
    /// exact same solid as the plain one.
    func testAncestryVariantMatchesThePlainBooleanExactly() throws {
        let plate = try box(10, 10, 6)
        let drill = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 2, height: 20),
            placement: Transform3D(translation: SIMD3(0, -1, 0))))
        let plain = try OCCTKernel.booleanResult(plate, drill, op: 1).get()
        let traced = try OCCTKernel.booleanResultWithAncestry(plate, drill, op: 1).get()
        XCTAssertEqual(OCCTKernel.volume(plain.handle),
                       OCCTKernel.volume(traced.outcome.handle), accuracy: 1e-9)
        XCTAssertEqual(faceCount(plain.handle), faceCount(traced.outcome.handle))
    }

    // MARK: - Cut: the bore wall knows it came from the tool

    func testACutBoreWallDescendsFromTheToolAlone() throws {
        let plate = try box(10, 10, 6)
        let drill = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 2, height: 20),
            placement: Transform3D(translation: SIMD3(0, -1, 0))))
        let (outcome, ancestry) = try OCCTKernel
            .booleanResultWithAncestry(plate, drill, op: 1).get()
        XCTAssertFalse(ancestry.rows.isEmpty)
        XCTAssertFalse(ancestry.truncatedByHeal)
        // Prove the geometry is the through-hole this test reasons about
        // (the box is CENTERED in x/z): V = 600 − π·2²·6.
        XCTAssertEqual(OCCTKernel.volume(outcome.handle),
                       600 - .pi * 4 * 6, accuracy: 1e-6)

        let faces = faceCount(outcome.handle)
        // Every result face carries ancestry — a box-minus-cylinder is the
        // benign case; if history has holes HERE, it has holes everywhere.
        XCTAssertTrue(ancestry.unknownFaces(resultFaceCount: faces).isEmpty,
                      "unknown faces: \(ancestry.unknownFaces(resultFaceCount: faces))")

        // Exactly one face descends from the TOOL alone: the bore wall.
        let toolOnly = (1...faces).filter { face in
            let ancestors = ancestry.ancestors(ofResultFace: face)
            return !ancestors.isEmpty
                && ancestors.allSatisfy { $0.inputOrdinal == 1 }
        }
        XCTAssertEqual(toolOnly.count, 1,
                       "expected exactly the bore wall, got faces \(toolOnly)")
    }

    // MARK: - Fuse across the unify hop

    /// Two stacked boxes fuse into one solid whose side walls are MERGED by
    /// UnifySameDomain — each merged face must list ancestors from BOTH
    /// inputs, which only works if ancestry composes across the unifier's
    /// own history (the two-hop case).
    func testAFusedMergedWallListsBothParents() throws {
        let lower = try box(4, 4, 4)
        let upper = try box(4, 4, 4, at: SIMD3(0, 4, 0))
        let (outcome, ancestry) = try OCCTKernel
            .booleanResultWithAncestry(lower, upper, op: 0).get()

        // The fused tower is a single 4×8×4 box: 6 faces after the merge.
        XCTAssertEqual(faceCount(outcome.handle), 6)
        XCTAssertEqual(OCCTKernel.volume(outcome.handle), 128, accuracy: 1e-9)

        let mergedWalls = (1...6).filter { face in
            let ordinals = Set(ancestry.ancestors(ofResultFace: face)
                .map(\.inputOrdinal))
            return ordinals.contains(0) && ordinals.contains(1)
        }
        XCTAssertEqual(mergedWalls.count, 4,
                       "the four side walls are merged from both boxes; "
                       + "got \(mergedWalls) — rows: \(ancestry.rows.count)")
    }

    /// The un-merged end caps of the fused tower belong to one input each.
    func testTheFusedTowerCapsKeepSingleParents() throws {
        let lower = try box(4, 4, 4)
        let upper = try box(4, 4, 4, at: SIMD3(0, 4, 0))
        let (_, ancestry) = try OCCTKernel
            .booleanResultWithAncestry(lower, upper, op: 0).get()
        let singleParent = (1...6).filter { face in
            let ordinals = Set(ancestry.ancestors(ofResultFace: face)
                .map(\.inputOrdinal))
            return ordinals.count == 1
        }
        XCTAssertEqual(singleParent.count, 2, "the bottom and top caps")
    }

    // MARK: - Extrude ancestry

    private func rectAncestry() throws
        -> (handle: BRepHandle, ancestry: ShapeAncestry) {
        try XCTUnwrap(OCCTKernel.extrudeShapeWithAncestry(
            outerLoop: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 6), SIMD2(0, 6)],
            holes: [], zMin: -4, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
            normal: SIMD3(0, 0, 1)))
    }

    func testARectExtrudeNamesEveryFaceOnce() throws {
        let (handle, ancestry) = try rectAncestry()
        XCTAssertEqual(faceCount(handle), 6)
        XCTAssertTrue(ancestry.unknownFaces(resultFaceCount: 6).isEmpty,
                      "every extrude face must carry ancestry: \(ancestry.rows)")
        // Exactly one row per face: 2 caps + 4 walls, no double-claims.
        XCTAssertEqual(ancestry.rows.count, 6)
        let caps = ancestry.rows.filter { $0.inputKind == .face }
        XCTAssertEqual(Set(caps.map(\.inputSubshape)), [1, 2])
        XCTAssertTrue(caps.allSatisfy { $0.relation == .modified })
        let walls = ancestry.rows.filter { $0.inputKind == .edge }
        XCTAssertEqual(Set(walls.map(\.inputSubshape)), [1, 2, 3, 4])
        XCTAssertTrue(walls.allSatisfy {
            $0.relation == .generated && $0.inputOrdinal == 0
        })
    }

    /// The convention's load-bearing claims, checked against GEOMETRY via the
    /// face channel: cap subIndex 1 is the zMin face, and wall edge ordinal i
    /// is the wall through loop points i-1 → i (wire order = construction
    /// order). If OCCT's wire iteration ever stops matching construction
    /// order, this is the test that says so.
    func testExtrudeRowsPointAtTheGeometricallyRightFaces() throws {
        let loop = [SIMD2<Double>(0, 0), SIMD2<Double>(10, 0),
                    SIMD2<Double>(10, 6), SIMD2<Double>(0, 6)]
        let (handle, ancestry) = try rectAncestry()
        let channel = OCCTKernel.renderMeshFaceChannel(from: handle)
        let mesh = OCCTKernel.renderMesh(from: handle)

        // Vertex positions of every triangle labelled with a face index.
        func vertices(ofFace face: Int) -> [SIMD3<Float>] {
            var out: [SIMD3<Float>] = []
            for (triangle, label) in channel.enumerated() where label == face {
                for corner in 0..<3 {
                    out.append(mesh.positions[Int(mesh.indices[3 * triangle + corner])])
                }
            }
            return out
        }
        func spansZ(_ face: Int, at z: Float) -> Bool {
            let zs = vertices(ofFace: face).map(\.z)
            return !zs.isEmpty && zs.allSatisfy { abs($0 - z) < 1e-4 }
        }
        func containsColumn(_ face: Int, at p: SIMD2<Double>) -> Bool {
            vertices(ofFace: face).contains {
                abs(Double($0.x) - p.x) < 1e-4 && abs(Double($0.y) - p.y) < 1e-4
            }
        }

        for row in ancestry.rows where row.inputKind == .face {
            let z: Float = row.inputSubshape == 1 ? -4 : 4
            XCTAssertTrue(spansZ(row.resultFace, at: z),
                          "cap subIndex \(row.inputSubshape) must lie at z=\(z)")
        }
        for row in ancestry.rows where row.inputKind == .edge {
            let a = loop[row.inputSubshape - 1]
            let b = loop[row.inputSubshape % loop.count]
            XCTAssertTrue(containsColumn(row.resultFace, at: a)
                          && containsColumn(row.resultFace, at: b),
                          "wall edge \(row.inputSubshape) must span "
                          + "\(a) → \(b), face \(row.resultFace)")
        }
    }

    /// A circle extrudes to one analytic wall from ONE wire edge, and a hole
    /// loop's wall carries the hole's ordinal — the outer/hole split element
    /// naming keys on.
    func testAHoledCircleExtrudeSeparatesLoopOrdinals() throws {
        let outerRadius = 6.0, holeRadius = 2.0
        let circle = { (r: Double) -> [SIMD2<Double>] in
            (0..<32).map { i -> SIMD2<Double> in
                let a = Double(i) / 32 * 2 * .pi
                return SIMD2(r * cos(a), r * sin(a))
            }
        }
        let (handle, ancestry) = try XCTUnwrap(OCCTKernel.extrudeShapeWithAncestry(
            outerLoop: circle(outerRadius),
            outerConic: .init(center: .zero, radius: outerRadius),
            holes: [.init(loop: circle(holeRadius),
                          conic: .init(center: .zero, radius: holeRadius))],
            zMin: 0, zMax: 5,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
            normal: SIMD3(0, 0, 1)))
        XCTAssertEqual(faceCount(handle), 4)  // 2 caps + 2 cylindrical walls
        XCTAssertTrue(ancestry.unknownFaces(resultFaceCount: 4).isEmpty)
        let walls = ancestry.rows.filter { $0.inputKind == .edge }
        XCTAssertEqual(walls.count, 2)
        XCTAssertEqual(Set(walls.map(\.inputOrdinal)), [0, 1],
                       "outer wall is loop 0, the hole's wall loop 1")
    }

    // MARK: - Same-face survival

    /// A cut far from a face leaves it untouched — relation `.same`, the
    /// strongest identity history can assert.
    func testAnUntouchedFaceSurvivesAsSame() throws {
        let slab = try box(20, 4, 20)
        let nibble = try box(2, 2, 2, at: SIMD3(9, 3, 9))
        let (_, ancestry) = try OCCTKernel
            .booleanResultWithAncestry(slab, nibble, op: 1).get()
        XCTAssertTrue(ancestry.rows.contains {
            $0.relation == .same && $0.inputOrdinal == 0
        }, "at least one slab face must survive the corner nibble untouched")
    }
}
