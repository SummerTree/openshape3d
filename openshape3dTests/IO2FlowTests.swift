//
//  IO2FlowTests.swift
//  openshape3dTests
//
//  Interchange UI flows (plan §B14 UI half): DXF import lands in a
//  ground-plane sketch (new or existing) as ONE CompositeCommand, DXF export
//  picks the active/ground sketch, and the per-body OBJ/GLB payloads split
//  one file per body. The file importer/exporter dialogs can't be driven
//  from UI tests, so the view-model paths are covered here.
//

import XCTest
import SwiftData
import simd
@testable import openshape3d

@MainActor
final class IO2FlowTests: XCTestCase {

    /// The current simulator's Swift runtime crashes when a MainActor-isolated
    /// class deallocates inside an XCTest invocation (see SelectionTests), so
    /// view models are retained for the process lifetime — deliberate leak.
    private static var retainedViewModels: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self,
            PersistedBody.self,
            PersistedSketch.self,
            PersistedPlane.self,
            PersistedImage.self,
            PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "IO2 Flow Test")
        context.insert(project)
        let viewModel = EditorViewModel(project: project, modelContext: context)
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    private func addBox(
        to viewModel: EditorViewModel, name: String, at translation: SIMD3<Double>
    ) {
        var transform = Transform3D.identity
        transform.translation = translation
        var document = viewModel.session.document // nextRevision is mutating
        let body = Body(
            name: name,
            transform: transform,
            euclidMesh: .primitive(.box(width: 2, depth: 2, height: 2)),
            revision: document.nextRevision()
        )
        viewModel.session.perform(AddBodyCommand(body: body))
    }

    /// Minimal valid DXF: one LINE plus one CIRCLE in the ENTITIES section.
    private var sampleDXF: Data {
        Data("""
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        8
        0
        10
        0.0
        20
        0.0
        11
        10.0
        21
        5.0
        0
        CIRCLE
        8
        0
        10
        3.0
        20
        4.0
        40
        2.0
        0
        ENDSEC
        0
        EOF
        """.utf8)
    }

    // MARK: - DXF import (one CompositeCommand)

    func testImportDXFCreatesGroundSketchAsOneUndoStep() throws {
        let viewModel = try makeViewModel()
        XCTAssertTrue(viewModel.session.document.sketches.isEmpty)

        viewModel.importDXF(data: sampleDXF, fileName: "part.dxf")

        let sketches = viewModel.session.document.sketches
        XCTAssertEqual(sketches.count, 1, "import creates the ground sketch")
        let sketch = try XCTUnwrap(sketches.first)
        XCTAssertTrue(sketch.plane.isCoincident(with: .ground))
        XCTAssertEqual(sketch.entities.count, 2, "LINE + CIRCLE arrive")
        XCTAssertNil(viewModel.errorMessage)

        // ONE undo removes the sketch and the entities together.
        viewModel.undo()
        XCTAssertTrue(
            viewModel.session.document.sketches.isEmpty,
            "single undo step reverts sketch creation + entity insertion"
        )
        viewModel.redo()
        XCTAssertEqual(viewModel.session.document.sketches.first?.entities.count, 2)
    }

    func testImportDXFReusesAndUnhidesExistingGroundSketch() throws {
        let viewModel = try makeViewModel()
        var existing = Sketch(name: "Sketch 1", plane: .ground)
        existing.entities = [.line(id: UUID(), a: SIMD2(-1, 0), b: SIMD2(1, 0))]
        existing.isHidden = true // e.g. auto-hidden by an extrude
        viewModel.session.perform(AddSketchCommand(sketch: existing))

        viewModel.importDXF(data: sampleDXF, fileName: "part.dxf")

        let sketches = viewModel.session.document.sketches
        XCTAssertEqual(sketches.count, 1, "existing ground sketch is reused, not duplicated")
        let sketch = try XCTUnwrap(sketches.first)
        XCTAssertEqual(sketch.id, existing.id)
        XCTAssertEqual(sketch.entities.count, 3, "imported entities append to the sketch")
        XCTAssertFalse(sketch.isHidden, "hidden target sketch is unhidden by the import")

        // One undo restores the pre-import entity list AND the hidden flag.
        viewModel.undo()
        let reverted = try XCTUnwrap(viewModel.session.document.sketches.first)
        XCTAssertEqual(reverted.entities.count, 1)
        XCTAssertTrue(reverted.isHidden)
    }

    func testImportDXFWithNoUsableEntitiesReportsErrorAndAddsNothing() throws {
        let viewModel = try makeViewModel()
        viewModel.importDXF(data: Data("not a dxf at all".utf8), fileName: "junk.dxf")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.session.document.sketches.isEmpty)
        XCTAssertFalse(viewModel.session.undoStack.canUndo, "nothing was committed")
    }

    // MARK: - DXF export (active/ground sketch)

    func testExportDXFUsesGroundSketchAndFailsWhenEmpty() throws {
        let viewModel = try makeViewModel()

        XCTAssertNil(viewModel.exportDXF(), "no sketch → nil")
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.errorMessage = nil

        var sketch = Sketch(name: "Sketch 1", plane: .ground)
        sketch.entities = [.circle(id: UUID(), center: SIMD2(1, 2), radius: 3)]
        viewModel.session.perform(AddSketchCommand(sketch: sketch))

        let data = try XCTUnwrap(viewModel.exportDXF())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("CIRCLE"))
        XCTAssertTrue(text.contains("ENTITIES"))
        XCTAssertNil(viewModel.errorMessage)

        // Round-trip sanity: our own importer reads the export back.
        XCTAssertEqual(DXFKit.importDXF(data).count, 1)
    }

    // MARK: - Per-body payloads (OBJ/GLB options sheet)

    func testPerBodyPayloadsSplitOneFilePerBody() throws {
        let viewModel = try makeViewModel()
        addBox(to: viewModel, name: "Alpha", at: SIMD3(0, 0, 0))
        addBox(to: viewModel, name: "Beta", at: SIMD3(10, 0, 0))

        let obj = try XCTUnwrap(viewModel.exportOBJPerBody())
        XCTAssertEqual(obj.map(\.name), ["Alpha", "Beta"])
        for payload in obj {
            XCTAssertFalse(payload.data.isEmpty)
        }

        let glb = try XCTUnwrap(viewModel.exportGLBPerBody())
        XCTAssertEqual(glb.map(\.name), ["Alpha", "Beta"])
        for payload in glb {
            // Each payload is its own valid GLB container.
            XCTAssertEqual(
                payload.data.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
                },
                GLBExporter.magic
            )
        }
    }

    func testPerBodyPayloadsNilOnEmptyDocument() throws {
        let viewModel = try makeViewModel()
        XCTAssertNil(viewModel.exportOBJPerBody())
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.errorMessage = nil
        XCTAssertNil(viewModel.exportGLBPerBody())
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - GLB / USDZ whole-document exports

    func testExportGLBAndUSDZFollowSupportContract() throws {
        let viewModel = try makeViewModel()
        XCTAssertNil(viewModel.exportGLB(), "empty document → nil")
        viewModel.errorMessage = nil

        addBox(to: viewModel, name: "Box", at: .zero)
        let glb = try XCTUnwrap(viewModel.exportGLB())
        XCTAssertEqual(
            glb.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) },
            GLBExporter.magic
        )

        // USDZ: real data when ModelIO supports it here, nil (with the
        // fallback error) otherwise — the UI hides the entries either way.
        let usdz = viewModel.exportUSDZ()
        if USDZExporter.isSupported {
            // nil is still allowed on runtime export failure; no assert on data.
            if let usdz {
                XCTAssertEqual(usdz.prefix(2), Data([0x50, 0x4B]), "zip magic")
            }
        } else {
            XCTAssertNil(usdz)
            XCTAssertNotNil(viewModel.errorMessage)
        }
    }
}
