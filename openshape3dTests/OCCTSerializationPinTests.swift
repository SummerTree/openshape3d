//
//  OCCTSerializationPinTests.swift
//  openshape3dTests
//
//  The brep persistence contract (docs/FREECAD_PLAYBOOK.md P1 / review
//  R4-O5): blobs carry NO derived triangulation and are written at a PINNED
//  TopTools format version, so a future OCCT upgrade can't silently change
//  what saved documents contain.
//

import XCTest
import simd
@testable import openshape3d

final class OCCTSerializationPinTests: XCTestCase {

    func testBlobExcludesTriangulationAndStaysStable() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 5, height: 20), placement: .identity))
        let before = try XCTUnwrap(OCCTKernel.serialize(cyl))
        // Tessellating stores triangulations into the shape's faces…
        _ = OCCTKernel.renderMesh(from: cyl)
        let after = try XCTUnwrap(OCCTKernel.serialize(cyl))
        // …but the blob must not balloon with them: derived state is rebuilt
        // on load, not persisted. (With triangles the same blob grows ~10×.)
        XCTAssertLessThan(Double(after.count), Double(before.count) * 1.5,
                          "triangulation leaked into the persisted blob")
    }

    func testPinnedFormatRoundTripsAnalytic() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 5, height: 20), placement: .identity))
        let blob = try XCTUnwrap(OCCTKernel.serialize(cyl))
        let restored = try XCTUnwrap(OCCTKernel.deserialize(blob))
        let counts = OCCTKernel.faceTypeCounts(restored)
        XCTAssertEqual(counts.cylindrical, 1)
        XCTAssertEqual(counts.planar, 2)
        XCTAssertEqual(OCCTKernel.volume(restored), OCCTKernel.volume(cyl),
                       accuracy: 1e-6)
    }

    func testGarbageBlobIsRefusedNotCrashed() {
        XCTAssertNil(OCCTKernel.deserialize(Data("not a brep".utf8)))
        XCTAssertNil(OCCTKernel.deserialize(Data()))
    }
}
