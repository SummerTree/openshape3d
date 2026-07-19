//
//  SectionDisplayTests.swift
//  openshape3dTests
//
//  Section View + Display modes + Isolate (plan §B11/§B12, spec §16):
//  view-model state must reach the ViewportScene render contract — display
//  flags mirror, Isolate filters drawables without touching persisted
//  visibility, and the section plane pick/flip/drag/off lifecycle drives
//  scene.sectionPlane.
//

import XCTest
import SwiftData
import simd
@testable import openshape3d

@MainActor
final class SectionDisplayTests: XCTestCase {

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
        let project = Project(name: "Section Display Test")
        context.insert(project)
        let viewModel = EditorViewModel(project: project, modelContext: context)
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    @discardableResult
    private func addBox(
        to viewModel: EditorViewModel, name: String, at translation: SIMD3<Double>
    ) -> Body {
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
        return body
    }

    // MARK: - Display modes (spec §16.4)

    func testDisplayFlagsReachScene() throws {
        let viewModel = try makeViewModel()
        XCTAssertEqual(viewModel.scene.displayMode, .shaded)
        XCTAssertFalse(viewModel.scene.showHiddenEdges)

        viewModel.displayMode = .xray
        viewModel.showHiddenEdges = true
        XCTAssertEqual(viewModel.scene.displayMode, .xray)
        XCTAssertTrue(viewModel.scene.showHiddenEdges)

        viewModel.displayMode = .shaded
        viewModel.showHiddenEdges = false
        XCTAssertEqual(viewModel.scene.displayMode, .shaded)
        XCTAssertFalse(viewModel.scene.showHiddenEdges)
    }

    // MARK: - Isolate (spec §16.2)

    func testIsolateFiltersSceneAndRestores() throws {
        let viewModel = try makeViewModel()
        let a = addBox(to: viewModel, name: "A", at: .zero)
        let b = addBox(to: viewModel, name: "B", at: SIMD3(10, 0, 0))

        viewModel.selection = [a.id]
        viewModel.enterIsolate()
        XCTAssertTrue(viewModel.isIsolateActive)
        XCTAssertEqual(viewModel.scene.bodies.map(\.id), [a.id])
        // Persisted visibility is untouched — Isolate is a transient override.
        XCTAssertFalse(viewModel.session.document.body(with: b.id)?.isHidden ?? true)

        viewModel.exitIsolate()
        XCTAssertFalse(viewModel.isIsolateActive)
        XCTAssertEqual(Set(viewModel.scene.bodies.map(\.id)), [a.id, b.id])
    }

    func testIsolateRequiresSelectionAndDropsUndoneBodies() throws {
        let viewModel = try makeViewModel()
        viewModel.enterIsolate()
        XCTAssertFalse(viewModel.isIsolateActive, "Isolate with nothing selected is a no-op")

        let a = addBox(to: viewModel, name: "A", at: .zero)
        viewModel.selection = [a.id]
        viewModel.enterIsolate()
        XCTAssertTrue(viewModel.isIsolateActive)

        // Undoing the isolated body away must drop the override, not blank
        // the scene forever.
        viewModel.undo()
        XCTAssertFalse(viewModel.isIsolateActive)
    }

    // MARK: - Section View (spec §16.1)

    /// Ray straight down through the ground (ZX) tile center.
    private var groundTileRay: Ray {
        Ray(origin: SIMD3(1.3, 5, -1.3), direction: SIMD3(0, -1, 0))
    }

    func testSectionPickViaGroundTileSetsClipPlane() throws {
        let viewModel = try makeViewModel()
        XCTAssertNil(viewModel.scene.sectionPlane)

        viewModel.beginSectionPlanePick()
        XCTAssertEqual(viewModel.mode, .pickingSectionPlane)
        XCTAssertFalse(viewModel.scene.planePickers.isEmpty,
                       "The plane tiles should show while Section waits for a plane")

        viewModel.handle(.tap(ray: groundTileRay))
        XCTAssertEqual(viewModel.mode, .idle)
        let section = try XCTUnwrap(viewModel.sectionState)
        XCTAssertTrue(section.basePlane.isCoincident(with: .ground))

        let clip = try XCTUnwrap(viewModel.scene.sectionPlane)
        XCTAssertTrue(clip.enabled)
        // Ground normal +Y: the kept side is above the plane.
        XCTAssertEqual(clip.normal.y, 1, accuracy: 1e-5)
        XCTAssertEqual(clip.point.y, 0, accuracy: 1e-5)
    }

    func testSectionMissedPickKeepsPickerArmedAndCancelRestores() throws {
        let viewModel = try makeViewModel()
        viewModel.beginSectionPlanePick()
        // A ray that misses every tile keeps the picker armed.
        viewModel.handle(.tap(ray: Ray(origin: SIMD3(50, 5, 50), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(viewModel.mode, .pickingSectionPlane)
        XCTAssertNil(viewModel.sectionState)

        viewModel.cancelSectionPlanePick()
        XCTAssertEqual(viewModel.mode, .idle)
        XCTAssertNil(viewModel.scene.sectionPlane)
    }

    func testFlipAndOffLifecycle() throws {
        let viewModel = try makeViewModel()
        viewModel.beginSectionPlanePick()
        viewModel.handle(.tap(ray: groundTileRay))

        viewModel.flipSection()
        var clip = try XCTUnwrap(viewModel.scene.sectionPlane)
        XCTAssertEqual(clip.normal.y, -1, accuracy: 1e-5,
                       "Flip keeps the other side of the plane")
        viewModel.flipSection()
        clip = try XCTUnwrap(viewModel.scene.sectionPlane)
        XCTAssertEqual(clip.normal.y, 1, accuracy: 1e-5)

        viewModel.endSection()
        XCTAssertNil(viewModel.sectionState)
        XCTAssertNil(viewModel.scene.sectionPlane)
    }

    func testSectionArrowDragMovesPlaneAlongNormal() throws {
        let viewModel = try makeViewModel()
        viewModel.beginSectionPlanePick()
        viewModel.handle(.tap(ray: groundTileRay))

        // Ground section: pull axis is +Y at the origin. A horizontal ray
        // aimed at (0, 1, 0) grabs the arrow (gap 0, param 1 within the
        // claim window at the 0.01 default worldPerPoint... window scales by
        // 220pt → 2.2 world units).
        let grab = Ray(origin: SIMD3(2, 1, 0), direction: SIMD3(-1, 0, 0))
        XCTAssertTrue(viewModel.beginSectionDrag(ray: grab))

        // Drag up 1 world unit: the plane follows along +Y (snapped steps).
        viewModel.updateSectionDrag(
            ray: Ray(origin: SIMD3(2, 2, 0), direction: SIMD3(-1, 0, 0)),
            screenDeltaWorld: 0
        )
        viewModel.endSectionDrag()
        let section = try XCTUnwrap(viewModel.sectionState)
        XCTAssertEqual(section.offset, 1.0, accuracy: 1e-6)
        let clip = try XCTUnwrap(viewModel.scene.sectionPlane)
        XCTAssertEqual(clip.point.y, 1, accuracy: 1e-4)

        // A drag nowhere near the arrow is not claimed (it should orbit).
        XCTAssertFalse(viewModel.beginSectionDrag(
            ray: Ray(origin: SIMD3(30, 1, 0), direction: simd_normalize(SIMD3(-1, 0, 1)))
        ))
    }
}
