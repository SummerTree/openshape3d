//
//  DraftFaceBRepTests.swift
//  openshape3dTests
//
//  The exact face draft (BRepOffsetAPI_DraftAngle through the bridge). The
//  mesh path in DraftFaceTests pins the geometry a draft means — a wedge of
//  ½·h²·tanθ·d off one wall, hinged on the neutral plane; this pins that the
//  B-rep path builds the SAME solid analytically, with the same sign, so a
//  drafted casting can go on to be filleted, shelled and exported.
//

import XCTest
import simd
@testable import openshape3d

final class DraftFaceBRepTests: XCTestCase {

    private let w = 100.0, d = 60.0, h = 20.0

    /// The box's world AABB from its render mesh — the primitive's placement
    /// is whatever the kernel chooses, so the test reads it back.
    private func bounds(_ handle: BRepHandle) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        let r = OCCTKernel.renderMesh(from: handle)
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in r.positions {
            let q = SIMD3(Double(p.x), Double(p.y), Double(p.z))
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        return (lo, hi)
    }

    func testOneDraftedWallRemovesTheWedgeAndStaysAnalytic() throws {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: w, depth: d, height: h), placement: .identity))
        // The scene is Y-up: the box's height runs along y, so the neutral
        // plane is the y = min face and the draft pulls along +y.
        let b = bounds(box)
        let bottom = SIMD3(b.min.x, b.min.y, b.min.z)
        let wallPoint = SIMD3(b.max.x, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2)
        let degrees = 5.0
        let drafted = try OCCTKernel.draftResult(
            box, facesAt: [wallPoint], degrees: degrees,
            neutralOrigin: bottom, neutralNormal: SIMD3(0, 1, 0),
            tolerance: OCCTKernel.matchTolerance(for: box)).get()

        let wedge = 0.5 * h * h * tan(degrees * .pi / 180) * d  // d runs along z here
        XCTAssertEqual(OCCTKernel.volume(drafted), w * d * h - wedge, accuracy: 1e-3,
                       "a 5° draft on one wall removes ½h²·tanθ·d, to the mm³")
        // Positive narrows away from the neutral plane: the wall's top edge
        // moved in by h·tanθ, its bottom edge did not move.
        let after = bounds(drafted)
        XCTAssertEqual(after.max.x, b.max.x, accuracy: 1e-6, "the hinge edge on the base stays put")
        XCTAssertEqual(after.min.y, b.min.y, accuracy: 1e-9)
        XCTAssertEqual(after.max.y, b.max.y, accuracy: 1e-9, "the top face is not carried down")
        let counts = OCCTKernel.faceTypeCounts(drafted)
        XCTAssertEqual(counts.planar, 6, "still a six-plane solid, one plane now tilted")
    }

    func testAWallParallelToTheNeutralPlaneIsRefused() throws {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: w, depth: d, height: h), placement: .identity))
        let b = bounds(box)
        let top = SIMD3((b.min.x + b.max.x) / 2, b.max.y, (b.min.z + b.max.z) / 2)
        let result = OCCTKernel.draftResult(
            box, facesAt: [top], degrees: 5,
            neutralOrigin: SIMD3(b.min.x, b.min.y, b.min.z), neutralNormal: SIMD3(0, 1, 0),
            tolerance: OCCTKernel.matchTolerance(for: box))
        if case .success = result {
            XCTFail("a face parallel to the neutral plane has no hinge line to draft about")
        }
    }
}

final class DraftCylinderBRepTests: XCTestCase {
    /// A Ø40 × 30 boss drafted 10° about its base becomes a cone frustum:
    /// R20 at the base, R20 − 30·tan10° at the top.
    func testCylindricalWallDraftsToAFrustum() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 20, height: 30), placement: .identity))
        let r = OCCTKernel.renderMesh(from: cyl)
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in r.positions {
            let q = SIMD3(Double(p.x), Double(p.y), Double(p.z)); lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let center = (lo + hi) / 2
        let base = SIMD3(center.x, lo.y, center.z)
        let wallPoint = SIMD3(center.x + 20, center.y, center.z)
        let result = OCCTKernel.draftResult(
            cyl, facesAt: [wallPoint], degrees: 10,
            neutralOrigin: base, neutralNormal: SIMD3(0, 1, 0),
            tolerance: OCCTKernel.matchTolerance(for: cyl))
        switch result {
        case .failure(let error):
            XCTFail("cylinder draft refused: \(error)")
        case .success(let drafted):
            let r1 = 20.0, r2 = 20 - 30 * tan(10 * Double.pi / 180)
            let frustum = Double.pi * 30 / 3 * (r1 * r1 + r1 * r2 + r2 * r2)
            XCTAssertEqual(OCCTKernel.volume(drafted), frustum, accuracy: 1e-2)
        }
    }
}
