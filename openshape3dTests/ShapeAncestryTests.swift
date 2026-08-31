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
