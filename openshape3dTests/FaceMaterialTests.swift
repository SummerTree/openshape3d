//
//  FaceMaterialTests.swift
//  openshape3dTests
//
//  Spec §14 per-face materials: a face is remembered by a point on it and
//  its normal, found again on the body's mesh (following the body as it
//  moves, dropped when an edit moves the face away); setting and clearing
//  face materials; the undoable command; persistence.
//

import XCTest
import simd
@testable import openshape3d

final class FaceMaterialTests: XCTestCase {

    private func box(width: Double = 10, height: Double = 10) -> Body {
        Body(name: "Box", euclidMesh: .primitive(.box(width: width, depth: 10, height: height)), revision: 1)
    }

    /// The triangle of `mesh` whose normal is `normal`, nearest `point`.
    private func triangle(facing normal: SIMD3<Double>, in mesh: RenderMesh) throws -> Int {
        let found = (0..<mesh.triangleCount).first { t in
            FaceMaterialKit.anchor(in: mesh, triangle: t).map { simd_dot($0.normal, normal) > 0.999 } ?? false
        }
        return try XCTUnwrap(found)
    }

    private var steel: BodyMaterialSpec { MaterialPreset.library.first { $0.name == "Steel" }!.spec }
    private var rubber: BodyMaterialSpec { MaterialPreset.library.first { $0.name == "Rubber" }!.spec }

    func testAFaceIsFoundAgainFromWhereItWasPicked() throws {
        let body = box()
        let mesh = body.render
        let top = try triangle(facing: SIMD3(0, 1, 0), in: mesh)
        let region = try XCTUnwrap(FaceMaterialKit.region(in: mesh, seedTriangle: top))
        XCTAssertEqual(region.count, 2, "a box's top is two triangles")
        let anchor = try XCTUnwrap(FaceMaterialKit.anchor(in: mesh, triangle: top))
        let face = FaceMaterial(point: anchor.point, normal: anchor.normal, material: steel)

        XCTAssertEqual(FaceMaterialKit.resolve([face], in: mesh), [region])
        // The same box built again (a new mesh, same place): still found.
        XCTAssertEqual(FaceMaterialKit.resolve([face], in: box().render).first?.count, 2)
        // Taller: the top moved away — the material is dropped, not moved
        // onto another face.
        XCTAssertEqual(FaceMaterialKit.resolve([face], in: box(height: 14).render), [[]])
        // Wider: the top is still there (bigger), and found.
        XCTAssertEqual(FaceMaterialKit.resolve([face], in: box(width: 14).render).first?.count, 2)
    }

    func testSettingReplacesAndClearsFaceMaterials() throws {
        let mesh = box().render
        func target(_ normal: SIMD3<Double>) throws -> (point: SIMD3<Double>, normal: SIMD3<Double>, triangles: [Int]) {
            let t = try triangle(facing: normal, in: mesh)
            let anchor = try XCTUnwrap(FaceMaterialKit.anchor(in: mesh, triangle: t))
            return (anchor.point, anchor.normal, try XCTUnwrap(FaceMaterialKit.region(in: mesh, seedTriangle: t)))
        }
        let top = try target(SIMD3(0, 1, 0)), side = try target(SIMD3(1, 0, 0))
        var faces = FaceMaterialKit.setting(steel, on: [top, side], in: [], mesh: mesh)
        XCTAssertEqual(faces.map(\.material), [steel, steel])
        // Rubber on the top replaces its steel; the side keeps steel.
        faces = FaceMaterialKit.setting(rubber, on: [top], in: faces, mesh: mesh)
        XCTAssertEqual(faces.count, 2)
        let resolved = FaceMaterialKit.resolve(faces, in: mesh)
        XCTAssertEqual(Set(zip(faces, resolved).filter { $0.0.material == rubber }.flatMap(\.1)), Set(top.triangles))
        XCTAssertEqual(Set(zip(faces, resolved).filter { $0.0.material == steel }.flatMap(\.1)), Set(side.triangles))
        // Nil: back to the body's own.
        faces = FaceMaterialKit.setting(nil, on: [top, side], in: faces, mesh: mesh)
        XCTAssertTrue(faces.isEmpty)
    }

    func testACurvedFaceIsPickedWhole() throws {
        let cylinder = Body(name: "Pin", euclidMesh: .primitive(.cylinder(radius: 5, height: 10)), revision: 1)
        let mesh = cylinder.render
        let wall = try XCTUnwrap((0..<mesh.triangleCount).first { t in
            FaceMaterialKit.anchor(in: mesh, triangle: t).map { abs($0.normal.y) < 0.1 } ?? false
        })
        let region = try XCTUnwrap(FaceMaterialKit.region(in: mesh, seedTriangle: wall))
        XCTAssertGreaterThan(region.count, 10, "the whole wall, not one facet")
        let anchor = try XCTUnwrap(FaceMaterialKit.anchor(in: mesh, triangle: wall))
        let face = FaceMaterial(point: anchor.point, normal: anchor.normal, material: steel)
        XCTAssertEqual(Set(FaceMaterialKit.resolve([face], in: mesh)[0]), Set(region))
    }

    func testAFilletedTopIsItsOwnFaceAndAFilletIsAnother() throws {
        // A 20 × 10 × 20 block, its four top edges rounded: top, fillets and
        // sides all meet smoothly — one smooth region.
        let block = try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 20, depth: 20, height: 10), placement: .identity))
        let rounded = try XCTUnwrap(OCCTKernel.fillet(
            block, at: [SIMD3(0, 10, 10), SIMD3(0, 10, -10), SIMD3(10, 10, 0), SIMD3(-10, 10, 0)],
            radius: 2, tolerance: 0.5))
        let m = OCCTKernel.renderMesh(from: rounded)
        let mesh = RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices)
        func normal(_ t: Int) -> SIMD3<Double> { FaceMaterialKit.anchor(in: mesh, triangle: t)!.normal }

        let topTriangles = (0..<mesh.triangleCount).filter { normal($0).y > 0.9999 }
        let top = try XCTUnwrap(FaceMaterialKit.region(in: mesh, seedTriangle: topTriangles[0]))
        XCTAssertEqual(Set(top), Set(topTriangles), "the top alone, not its fillets and sides")

        let fillet = try XCTUnwrap((0..<mesh.triangleCount).first { normal($0).y > 0.5 && normal($0).y < 0.9 })
        let blend = try XCTUnwrap(FaceMaterialKit.region(in: mesh, seedTriangle: fillet))
        XCTAssertTrue(blend.allSatisfy { normal($0).y < 0.9999 && normal($0).y > 1e-3 },
                      "the fillets, short of the top and the sides")
        XCTAssertGreaterThan(blend.count, 8)
        // Its outline: the fillet run's two edges, top and side.
        XCTAssertFalse(FaceMaterialKit.boundary(of: blend, in: mesh).isEmpty)
    }

    func testCommandsUndoAndABodyMaterialTakesTheWholeBody() throws {
        var document = DesignDocument()
        document.bodies.append(box())
        let id = document.bodies[0].id
        let mesh = document.bodies[0].render
        let top = try triangle(facing: SIMD3(0, 1, 0), in: mesh)
        let anchor = try XCTUnwrap(FaceMaterialKit.anchor(in: mesh, triangle: top))
        let faces = [FaceMaterial(point: anchor.point, normal: anchor.normal, material: steel)]

        let set = SetFaceMaterialsCommand(after: [id: faces], document: document)
        set.apply(to: &document)
        XCTAssertEqual(document.bodies[0].faceMaterials, faces)
        set.revert(in: &document)
        XCTAssertTrue(document.bodies[0].faceMaterials.isEmpty)
        set.apply(to: &document)

        // Rubber on the whole body clears its face materials; undo brings them back.
        let whole = SetMaterialCommand(bodyIDs: [id], material: rubber, document: document)
        whole.apply(to: &document)
        XCTAssertEqual(document.bodies[0].material, rubber)
        XCTAssertTrue(document.bodies[0].faceMaterials.isEmpty)
        whole.revert(in: &document)
        XCTAssertNil(document.bodies[0].material)
        XCTAssertEqual(document.bodies[0].faceMaterials, faces)
    }

    func testFaceMaterialsAreSavedInTheArchive() throws {
        let faces = [FaceMaterial(point: SIMD3(0, 5, 0), normal: SIMD3(0, 1, 0), material: steel)]
        let record = ProjectArchive.BodyRecord(
            id: UUID(), name: "Box", transform: Data(), primitive: nil, mesh: Data(), isHidden: false,
            material: nil, faceMaterials: try JSONEncoder().encode(faces), brep: nil)
        let back = try JSONDecoder().decode(ProjectArchive.BodyRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(try JSONDecoder().decode([FaceMaterial].self, from: try XCTUnwrap(back.faceMaterials)), faces)
        // Archives written before face materials still open.
        let old = #"{"id":"\#(UUID().uuidString)","name":"Box","transform":"","mesh":"","isHidden":false}"#
        XCTAssertNil(try JSONDecoder().decode(ProjectArchive.BodyRecord.self, from: Data(old.utf8)).faceMaterials)
    }
}
