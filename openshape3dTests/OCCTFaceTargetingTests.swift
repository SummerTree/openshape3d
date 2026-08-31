//
//  OCCTFaceTargetingTests.swift
//  openshape3dTests
//
//  Point→face targeting is exact distance to the TRIMMED face
//  (`BRepExtrema_DistShapeShape`), not to samples on the surface's UV
//  bounding box (docs/FREECAD_PLAYBOOK.md FT1, review R4-O2). The old 5×5 UV
//  grid missed non-rectangular faces entirely: on a right-triangle cap the
//  centroid sits ~11.8 mm from the nearest of 25 samples spread over the
//  square UV box, so the pick was rejected.
//

import XCTest
import simd
@testable import openshape3d

final class OCCTFaceTargetingTests: XCTestCase {

    /// A triangular prism: right triangle (0,0)-(40,0)-(0,40) extruded 5 up.
    private func triangularPrism() throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: [SIMD2(0, 0), SIMD2(40, 0), SIMD2(0, 40)],
            holes: [], zMin: 0, zMax: 5,
            origin: SIMD3(0, 0, 0), xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
    }

    func testTriangularCapCentroidPickOpensIt() throws {
        let prism = try triangularPrism()
        // The top cap's centroid, in world space.
        let centroid = SIMD3<Double>(40.0 / 3, 40.0 / 3, 5)
        let hollow = try OCCTKernel.shellResult(
            prism, openingAt: [centroid], thickness: 1,
            tolerance: OCCTKernel.matchTolerance(for: prism)).get()
        // Solid: 800 mm² × 5 = 4000. An open-top shell must remove most of
        // it; a sealed hollow (the old silent failure) or a no-op would not.
        let volume = OCCTKernel.volume(hollow)
        XCTAssertLessThan(volume, 3000, "the cap opened — material removed")
        XCTAssertGreaterThan(volume, 0)
    }

    func testDeleteFaceOnATriangularCapResolves() throws {
        let prism = try triangularPrism()
        let centroid = SIMD3<Double>(40.0 / 3, 40.0 / 3, 5)
        // Deleting a planar cap can't heal a prism shut, so OCCT refuses —
        // but it must refuse at the HEALING stage, not because the pick
        // missed the face (the R4-O2 failure).
        let result = OCCTKernel.removingFacesResult(
            prism, at: [centroid], tolerance: OCCTKernel.matchTolerance(for: prism))
        if case let .failure(error) = result, case .noTargetMatched = error {
            XCTFail("the centroid pick must LAND on the trimmed face")
        }
    }
}
