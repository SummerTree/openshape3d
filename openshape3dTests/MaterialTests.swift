//
//  MaterialTests.swift
//  openshape3dTests
//
//  Plan §B15 (visualization-lite materials): the preset library, the
//  SetMaterialCommand undo semantics (incl. mixed prior materials), spec
//  clamping, and Codable round-trips for persistence.
//

import XCTest
import simd
@testable import openshape3d

final class MaterialTests: XCTestCase {

    private func makeDocument(bodyCount: Int = 2) -> DesignDocument {
        var document = DesignDocument()
        for i in 0..<bodyCount {
            document.bodies.append(Body(
                name: "Box \(i + 1)",
                euclidMesh: .primitive(.box(width: 1, depth: 1, height: 1)),
                revision: document.nextRevision()
            ))
        }
        return document
    }

    private func preset(_ name: String) -> BodyMaterialSpec {
        guard let preset = MaterialPreset.library.first(where: { $0.name == name }) else {
            XCTFail("Missing preset \(name)")
            return .default
        }
        return preset.spec
    }

    // MARK: - Presets

    func testPresetLibraryContents() {
        let names = MaterialPreset.library.map(\.name)
        XCTAssertEqual(names, [
            "Steel", "Aluminum", "Brass", "Plastic Matte",
            "Plastic Gloss", "Rubber", "Wood",
        ])
        // Metals are metallic, the rest dielectric; every factor is in 0…1.
        for preset in MaterialPreset.library {
            XCTAssertEqual(preset.spec, preset.spec.clamped, "\(preset.name) out of range")
        }
        XCTAssertEqual(preset("Steel").metallic, 1)
        XCTAssertEqual(preset("Rubber").metallic, 0)
    }

    func testDefaultSpecMatchesLegacyLook() {
        // The seeded/default appearance must be value-identical to the
        // pre-material body color and shading (metallic 0, roughness 0
        // keeps the legacy highlight path).
        XCTAssertEqual(BodyMaterialSpec.default.baseColor, SIMD4(0.72, 0.74, 0.78, 1))
        XCTAssertEqual(BodyMaterialSpec.default.metallic, 0)
        XCTAssertEqual(BodyMaterialSpec.default.roughness, 0)
    }

    func testClampedPinsOutOfRangeValues() {
        let wild = BodyMaterialSpec(
            baseColor: SIMD4(-0.5, 1.5, 0.5, 2), metallic: -1, roughness: 7
        ).clamped
        XCTAssertEqual(wild.baseColor, SIMD4(0, 1, 0.5, 1))
        XCTAssertEqual(wild.metallic, 0)
        XCTAssertEqual(wild.roughness, 1)
    }

    // MARK: - SetMaterialCommand

    func testSetMaterialAppliesToAllTargetsAndReverts() {
        var document = makeDocument()
        let ids = Set(document.bodies.map(\.id))
        let steel = preset("Steel")

        let command = SetMaterialCommand(bodyIDs: ids, material: steel, document: document)
        command.apply(to: &document)
        XCTAssertEqual(document.bodies[0].material, steel)
        XCTAssertEqual(document.bodies[1].material, steel)

        command.revert(in: &document)
        XCTAssertNil(document.bodies[0].material)
        XCTAssertNil(document.bodies[1].material)
    }

    func testSetMaterialRevertRestoresMixedPriorMaterials() {
        var document = makeDocument()
        let brass = preset("Brass")
        document.bodies[0].material = brass // body 1 keeps nil

        let ids = Set(document.bodies.map(\.id))
        let rubber = preset("Rubber")
        let command = SetMaterialCommand(bodyIDs: ids, material: rubber, document: document)
        command.apply(to: &document)
        XCTAssertEqual(document.bodies[0].material, rubber)
        XCTAssertEqual(document.bodies[1].material, rubber)

        command.revert(in: &document)
        XCTAssertEqual(document.bodies[0].material, brass)
        XCTAssertNil(document.bodies[1].material)
    }

    func testSetMaterialTargetsOnlySelectedBodies() {
        var document = makeDocument(bodyCount: 3)
        let steel = preset("Steel")
        let command = SetMaterialCommand(
            bodyIDs: [document.bodies[1].id], material: steel, document: document
        )
        command.apply(to: &document)
        XCTAssertNil(document.bodies[0].material)
        XCTAssertEqual(document.bodies[1].material, steel)
        XCTAssertNil(document.bodies[2].material)
    }

    func testSetMaterialNilClearsToDefaultLook() {
        var document = makeDocument(bodyCount: 1)
        let wood = preset("Wood")
        document.bodies[0].material = wood
        let command = SetMaterialCommand(
            bodyIDs: [document.bodies[0].id], material: nil, document: document
        )
        command.apply(to: &document)
        XCTAssertNil(document.bodies[0].material)
        command.revert(in: &document)
        XCTAssertEqual(document.bodies[0].material, wood)
    }

    // MARK: - Persistence

    func testSpecCodableRoundTrip() throws {
        for preset in MaterialPreset.library {
            let data = try JSONEncoder().encode(preset.spec)
            let decoded = try JSONDecoder().decode(BodyMaterialSpec.self, from: data)
            XCTAssertEqual(decoded, preset.spec, "\(preset.name) round-trip")
        }
    }
}
