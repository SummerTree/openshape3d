//
//  OBJImportTests.swift
//  openshape3dTests
//
//  Spec §12.1 — OBJ import. The load-bearing case is the ROUND TRIP: geometry
//  exported by `OBJExporter` must come back in with the same volume and bounds,
//  because that is the path a user actually takes (export, edit elsewhere,
//  re-import). The rest pins the format details that bite in the wild —
//  1-based and negative indices, `v/vt/vn` face refs, polygon faces, and
//  multi-group files.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class OBJImportTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// A unit cube written the plainest way OBJ allows.
    private let unitCube = """
    v 0 0 0
    v 1 0 0
    v 1 1 0
    v 0 1 0
    v 0 0 1
    v 1 0 1
    v 1 1 1
    v 0 1 1
    f 1 4 3 2
    f 5 6 7 8
    f 1 2 6 5
    f 2 3 7 6
    f 3 4 8 7
    f 4 1 5 8
    """

    // MARK: Round trip — the path users take

    func testExportedBodyReImportsWithTheSameVolume() throws {
        let box = Euclid.Mesh.primitive(.box(width: 10, depth: 4, height: 6))
        let body = Body(name: "Box", euclidMesh: box, revision: 1)
        let text = OBJExporter.obj(bodies: [body])

        let mesh = try OBJImporter.importSingleMesh(data(text))
        XCTAssertEqual(MeasureKit.bodyVolume(mesh, scale: 1),
                       MeasureKit.bodyVolume(body.render, scale: 1),
                       accuracy: 1e-3,
                       "a round trip must not change the solid's volume")
    }

    func testRoundTripPreservesBounds() throws {
        let box = Euclid.Mesh.primitive(.box(width: 10, depth: 4, height: 6))
        let body = Body(name: "Box", euclidMesh: box, revision: 1)
        let mesh = try OBJImporter.importSingleMesh(data(OBJExporter.obj(bodies: [body])))

        let before = body.render.localAABB, after = mesh.localAABB
        XCTAssertEqual(simd_length(after.min - before.min), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_length(after.max - before.max), 0, accuracy: 1e-4)
    }

    func testMultiBodyExportImportsAsSeparateGroups() throws {
        let a = Body(name: "Alpha", euclidMesh: Euclid.Mesh.primitive(
            .box(width: 2, depth: 2, height: 2)), revision: 1)
        let b = Body(name: "Beta", euclidMesh: Euclid.Mesh.primitive(
            .box(width: 3, depth: 3, height: 3)), revision: 2)
        let groups = try OBJImporter.importOBJ(data(OBJExporter.obj(bodies: [a, b])))

        XCTAssertEqual(groups.count, 2, "each body keeps its own group")
        XCTAssertEqual(MeasureKit.bodyVolume(groups[0].mesh, scale: 1), 8, accuracy: 1e-6)
        XCTAssertEqual(MeasureKit.bodyVolume(groups[1].mesh, scale: 1), 27, accuracy: 1e-6)
    }

    // MARK: Format details

    func testPolygonFacesAreTriangulated() throws {
        let mesh = try OBJImporter.importSingleMesh(data(unitCube))
        XCTAssertEqual(mesh.triangleCount, 12, "six quads fan into twelve triangles")
        XCTAssertEqual(MeasureKit.bodyVolume(mesh, scale: 1), 1, accuracy: 1e-9)
    }

    func testFaceReferencesWithTextureAndNormalIndicesParse() throws {
        let text = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vt 0 0
        vn 0 0 1
        f 1/1/1 2/1/1 3/1/1
        """
        let mesh = try OBJImporter.importSingleMesh(data(text))
        XCTAssertEqual(mesh.triangleCount, 1, "v/vt/vn refs use only the position index")
    }

    func testDoubleSlashFaceReferencesParse() throws {
        let text = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1//1 2//1 3//1
        """
        XCTAssertEqual(try OBJImporter.importSingleMesh(data(text)).triangleCount, 1)
    }

    func testNegativeIndicesAreRelativeToTheEnd() throws {
        let text = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f -3 -2 -1
        """
        let mesh = try OBJImporter.importSingleMesh(data(text))
        XCTAssertEqual(mesh.triangleCount, 1)
        XCTAssertEqual(mesh.localAABB.max.x, 1, accuracy: 1e-6,
                       "-3 resolved to the FIRST vertex, not the last")
    }

    func testVertexIndicesAreFileGlobalAcrossGroups() throws {
        // The second group's face indexes vertices declared under the first —
        // legal OBJ, and the most common way naive per-group parsers break.
        let text = """
        o first
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        o second
        v 0 0 5
        f 1 2 4
        """
        let groups = try OBJImporter.importOBJ(data(text))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "first")
        XCTAssertEqual(groups[1].name, "second")
    }

    func testCommentsAndUnknownKeywordsAreIgnored() throws {
        let text = """
        # exported by something
        mtllib scene.mtl
        usemtl steel
        s off
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """
        XCTAssertEqual(try OBJImporter.importSingleMesh(data(text)).triangleCount, 1)
    }

    func testUnitScaleConvertsFileUnits() throws {
        // The same cube read as if the file were in centimetres.
        let mesh = try OBJImporter.importSingleMesh(data(unitCube), unitScale: 10)
        XCTAssertEqual(MeasureKit.bodyVolume(mesh, scale: 1), 1000, accuracy: 1e-6)
    }

    func testEmptyGroupsDoNotFailTheImport() throws {
        let text = """
        o empty
        o real
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """
        let groups = try OBJImporter.importOBJ(data(text))
        XCTAssertEqual(groups.count, 1, "the empty group is dropped, not fatal")
        XCTAssertEqual(groups[0].name, "real")
    }

    // MARK: Failure modes

    func testAFileWithNoFacesThrows() {
        XCTAssertThrowsError(try OBJImporter.importOBJ(data("v 0 0 0\nv 1 0 0\n")))
    }

    func testAnOutOfRangeIndexThrowsRatherThanCrashing() {
        XCTAssertThrowsError(
            try OBJImporter.importOBJ(data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 99\n")))
    }

    func testAMalformedVertexThrows() {
        XCTAssertThrowsError(try OBJImporter.importOBJ(data("v 0 0\nf 1 1 1\n")))
    }
}
