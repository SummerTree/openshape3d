//
//  ItemsTests.swift
//  openshape3dTests
//
//  Phase A8: Items Manager model — visibility/rename/delete commands and
//  backward-compatible decoding of the new isHidden/name fields.
//

import XCTest
import simd
@testable import openshape3d

final class ItemsTests: XCTestCase {

    private func makeDocument() -> DesignDocument {
        var document = DesignDocument()
        let body = Body(
            name: "Box",
            euclidMesh: .primitive(.box(width: 1, depth: 1, height: 1)),
            revision: document.nextRevision()
        )
        document.bodies.append(body)
        document.sketches.append(Sketch(name: "Sketch 1", plane: .ground))
        document.planes.append(ConstructionPlane(plane: .ground, size: 4))
        return document
    }

    // MARK: - Visibility

    func testSetItemVisibilityAppliesAndReverts() {
        var document = makeDocument()
        let refs: [DocumentItemRef] = [
            .body(document.bodies[0].id),
            .sketch(document.sketches[0].id),
            .plane(document.planes[0].id),
        ]
        for ref in refs {
            let command = SetItemVisibilityCommand(item: ref, isHidden: true)
            command.apply(to: &document)
        }
        XCTAssertTrue(document.bodies[0].isHidden)
        XCTAssertTrue(document.sketches[0].isHidden)
        XCTAssertTrue(document.planes[0].isHidden)

        for ref in refs {
            SetItemVisibilityCommand(item: ref, isHidden: true).revert(in: &document)
        }
        XCTAssertFalse(document.bodies[0].isHidden)
        XCTAssertFalse(document.sketches[0].isHidden)
        XCTAssertFalse(document.planes[0].isHidden)
    }

    // MARK: - Rename

    func testRenameItemAppliesAndReverts() {
        var document = makeDocument()
        let bodyRename = RenameItemCommand(
            item: .body(document.bodies[0].id), before: "Box", after: "Housing"
        )
        bodyRename.apply(to: &document)
        XCTAssertEqual(document.bodies[0].name, "Housing")
        bodyRename.revert(in: &document)
        XCTAssertEqual(document.bodies[0].name, "Box")

        let sketchRename = RenameItemCommand(
            item: .sketch(document.sketches[0].id), before: "Sketch 1", after: "Base Profile"
        )
        sketchRename.apply(to: &document)
        XCTAssertEqual(document.sketches[0].name, "Base Profile")
        sketchRename.revert(in: &document)
        XCTAssertEqual(document.sketches[0].name, "Sketch 1")
    }

    // MARK: - Delete sketch/plane

    func testDeleteSketchCommandRestoresOrdering() {
        var document = makeDocument()
        document.sketches.append(Sketch(name: "Sketch 2", plane: .worldXY))
        let firstID = document.sketches[0].id

        guard let command = DeleteSketchCommand(id: firstID, document: document) else {
            return XCTFail("Command should resolve the sketch")
        }
        command.apply(to: &document)
        XCTAssertEqual(document.sketches.map(\.name), ["Sketch 2"])
        command.revert(in: &document)
        XCTAssertEqual(document.sketches.map(\.name), ["Sketch 1", "Sketch 2"])
        XCTAssertEqual(document.sketches[0].id, firstID)
    }

    func testDeletePlaneCommandAppliesAndReverts() {
        var document = makeDocument()
        let id = document.planes[0].id
        guard let command = DeletePlaneCommand(id: id, document: document) else {
            return XCTFail("Command should resolve the plane")
        }
        command.apply(to: &document)
        XCTAssertTrue(document.planes.isEmpty)
        command.revert(in: &document)
        XCTAssertEqual(document.planes.first?.id, id)
    }

    // MARK: - Backward-compatible decoding (pre-A8 documents)

    func testSketchDecodesWithoutNameAndHiddenFields() throws {
        let legacy = Sketch(plane: .ground, entities: [
            .circle(id: UUID(), center: .zero, radius: 2),
        ])
        // Strip the new fields to simulate a pre-A8 payload.
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)
        ) as! [String: Any]
        json.removeValue(forKey: "name")
        json.removeValue(forKey: "isHidden")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.name, "Sketch")
        XCTAssertFalse(decoded.isHidden)
        XCTAssertEqual(decoded.entities, legacy.entities)
    }

    func testConstructionPlaneDecodesWithoutHiddenField() throws {
        let legacy = ConstructionPlane(plane: .ground, size: 6)
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)
        ) as! [String: Any]
        json.removeValue(forKey: "isHidden")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ConstructionPlane.self, from: data)
        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.size, 6)
        XCTAssertFalse(decoded.isHidden)
    }

    func testVisibilityRoundTripsThroughCodable() throws {
        var sketch = Sketch(name: "Sketch 3", plane: .ground)
        sketch.isHidden = true
        let decoded = try JSONDecoder().decode(
            Sketch.self, from: JSONEncoder().encode(sketch)
        )
        XCTAssertEqual(decoded.name, "Sketch 3")
        XCTAssertTrue(decoded.isHidden)
    }

    // MARK: - Naming

    func testUniqueSketchNameNumbersFromOne() {
        var document = DesignDocument()
        XCTAssertEqual(document.uniqueSketchName(), "Sketch 1")
        document.sketches.append(Sketch(name: "Sketch 1", plane: .ground))
        XCTAssertEqual(document.uniqueSketchName(), "Sketch 2")
    }
}
