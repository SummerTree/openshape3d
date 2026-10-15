//
//  DecalTests.swift
//  openshape3dTests
//
//  Spec §14 decals: the decal's axes (upright on a wall, sensible on a top
//  face, turned by its rotation), where points fall on it, its first size,
//  the undoable command, and that decals follow their bodies through a
//  merge and an archive's ID remap and still decode when fields are missing.
//

import XCTest
import simd
@testable import openshape3d

final class DecalTests: XCTestCase {

    private func decal(normal: SIMD3<Double>, rotation: Double = 0) -> Decal {
        var d = Decal(bodyID: BodyID(), name: "Logo", image: Data([1]), center: .zero, normal: normal,
                      width: 20, aspect: 0.5)
        d.rotation = rotation
        return d
    }

    private func assertClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), 1e-9, "\(a) ≠ \(b)", file: file, line: line)
    }

    func testAWallDecalStandsUprightAndATopDecalFacesAway() {
        let wall = DecalKit.frame(decal(normal: SIMD3(0, 0, 1)))
        assertClose(wall.v, SIMD3(0, 1, 0))
        assertClose(wall.u, SIMD3(1, 0, 0))
        assertClose(simd_cross(wall.u, wall.v), wall.n)
        // Looking down on a top face: up the decal is away from the viewer (-Z).
        let top = DecalKit.frame(decal(normal: SIMD3(0, 1, 0)))
        assertClose(top.v, SIMD3(0, 0, -1))
        assertClose(simd_cross(top.u, top.v), top.n)
    }

    func testRotationTurnsTheDecalCounterClockwise() {
        let turned = DecalKit.frame(decal(normal: SIMD3(0, 0, 1), rotation: 90))
        assertClose(turned.u, SIMD3(0, 1, 0))
        assertClose(turned.v, SIMD3(-1, 0, 0))
    }

    func testPointsFallOnTheDecalByItsSize() {
        let d = decal(normal: SIMD3(0, 0, 1))
        XCTAssertEqual(d.height, 10)
        let corner = DecalKit.decalCoordinates(of: SIMD3(10, 5, 0), in: d)
        XCTAssertEqual(corner.x, 1, accuracy: 1e-12)
        XCTAssertEqual(corner.y, 1, accuracy: 1e-12)
        let outside = DecalKit.decalCoordinates(of: SIMD3(12, 0, 0), in: d)
        XCTAssertGreaterThan(outside.x, 1)
    }

    func testFirstSizeIsATidyThirdOfTheBody() {
        let body = Body(name: "Plate", euclidMesh: .primitive(.box(width: 60, depth: 30, height: 5)), revision: 1)
        XCTAssertEqual(DecalKit.defaultWidth(for: body), 20)
        XCTAssertEqual(DecalKit.tidyWidth(14.2801), 14.3, accuracy: 1e-9)
        XCTAssertEqual(DecalKit.tidyWidth(0.123456), 0.123, accuracy: 1e-12)
    }

    func testCommandUndoes() {
        var document = DesignDocument()
        let d = decal(normal: SIMD3(0, 1, 0))
        let add = SetDecalsCommand(title: "Add Decal", old: [], new: [d])
        add.apply(to: &document)
        XCTAssertEqual(document.decals, [d])
        add.revert(in: &document)
        XCTAssertTrue(document.decals.isEmpty)
    }

    func testDecalsFollowTheirBodiesIntoAMerge() {
        var guest = DesignDocument()
        let body = Body(name: "Box", euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)), revision: 1)
        guest.bodies = [body]
        guest.decals = [Decal(bodyID: body.id, name: "Logo", image: Data([1]), center: SIMD3(0, 10, 0),
                              normal: SIMD3(0, 1, 0), width: 4, aspect: 1)]
        let merged = ProjectMergeKit.insert(guest, into: DesignDocument()).document
        XCTAssertEqual(merged.decals.count, 1)
        XCTAssertEqual(merged.decals[0].bodyID, merged.bodies[0].id, "the copy names the copied body")
        XCTAssertNotEqual(merged.decals[0].id, guest.decals[0].id)
    }

    func testArchivesCarryDecalsUnderTheNewBodyIDs() throws {
        let bodyID = BodyID()
        let decals = [Decal(bodyID: bodyID, name: "Logo", image: Data(repeating: 0xAB, count: 300),
                            center: SIMD3(1, 2, 3), normal: SIMD3(0, 0, 1), width: 5, aspect: 2)]
        var archive = ProjectArchive(name: "D")
        archive.bodies = [.init(id: bodyID.raw, name: "Box", transform: Data(), primitive: nil, mesh: Data(),
                                isHidden: false, material: nil)]
        archive.decals = try JSONEncoder().encode(decals)
        let remapped = archive.remappingAllUUIDs()
        let back = try JSONDecoder().decode([Decal].self, from: try XCTUnwrap(remapped.decals))
        XCTAssertEqual(back[0].bodyID.raw, remapped.bodies[0].id)
        XCTAssertEqual(back[0].image, decals[0].image, "the image passes through untouched")
        XCTAssertEqual(back[0].center, decals[0].center)
    }

    func testDecalsDecodeWithFieldsMissing() throws {
        let json = #"{"id":"\#(UUID().uuidString)","bodyID":{"raw":"\#(UUID().uuidString)"},"image":"AQ==","center":[0,1,0],"normal":[0,2,0]}"#
        let d = try JSONDecoder().decode(Decal.self, from: Data(json.utf8))
        XCTAssertEqual(d.opacity, 1)
        XCTAssertEqual(d.rotation, 0)
        XCTAssertEqual(d.normal, SIMD3(0, 1, 0), "normalised")
    }
}
