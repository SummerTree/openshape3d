//
//  ConstraintPolishTests.swift
//  openshape3dTests
//
//  Phase C tranche-1 polish (plan §C): constraint/dimension DELETE (undoable),
//  OVER-CONSTRAINT refusal (never corrupt the sketch), PERSISTENCE round-trip
//  (constraints/dimensions ride Sketch Codable — the reopen path), and survival
//  of a sketch's constraints through EXTRUDE (which only hides the sketch).
//

import XCTest
import SwiftData
import simd
@testable import openshape3d

@MainActor
final class ConstraintPolishTests: XCTestCase {

    // Retain view models for the process lifetime (MainActor dealloc inside an
    // XCTest invocation crashes the simulator runtime — see ConstraintApplyTests).
    private static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "Constraint Polish Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    private func openSketch(_ vm: EditorViewModel, entities: [SketchEntity]) -> Sketch {
        let sketch = Sketch(plane: .ground, entities: entities)
        vm.session.perform(AddSketchCommand(sketch: sketch))
        vm.mode = .sketching(sketch.id, tool: .line)
        return sketch
    }

    private func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SketchEntity {
        .line(id: UUID(), a: a, b: b)
    }

    private func sketch(in vm: EditorViewModel, _ id: SketchID) -> Sketch? {
        vm.session.document.sketches.first { $0.id == id }
    }

    // MARK: - Persistence round-trip (the reopen path)

    /// `DocumentSession.save` encodes each `Sketch` with `JSONEncoder`, and load
    /// decodes `Sketch.self` — so a Codable round-trip is exactly the reopen
    /// path. Constraints and dimensions must survive it.
    func testConstraintsAndDimensionsSurviveCodableReload() throws {
        let l0 = line(SIMD2(0, 0), SIMD2(10, 0))
        let l1 = line(SIMD2(10, 0), SIMD2(10, 8))
        let circle = SketchEntity.circle(id: UUID(), center: SIMD2(4, 4), radius: 3)
        var original = Sketch(plane: .ground, entities: [l0, l1, circle])
        original.constraints = [
            SketchConstraint(kind: .coincident, refs: [
                ConstraintRef(entityID: l0.id, role: .endpointB),
                ConstraintRef(entityID: l1.id, role: .endpointA),
            ]),
            SketchConstraint(kind: .perpendicular, refs: [
                ConstraintRef(entityID: l0.id, role: .whole),
                ConstraintRef(entityID: l1.id, role: .whole),
            ]),
        ]
        original.dimensions = [
            SketchDimension(kind: .distance, refs: [
                ConstraintRef(entityID: l0.id, role: .endpointA),
                ConstraintRef(entityID: l0.id, role: .endpointB),
            ], value: 10),
            SketchDimension(kind: .radius, refs: [
                ConstraintRef(entityID: circle.id, role: .whole),
            ], value: 3),
        ]

        let data = try JSONEncoder().encode(original)
        let reloaded = try JSONDecoder().decode(Sketch.self, from: data)

        XCTAssertEqual(reloaded.constraints, original.constraints,
                       "Constraints must survive the persistence round-trip")
        XCTAssertEqual(reloaded.dimensions, original.dimensions,
                       "Dimensions must survive the persistence round-trip")
    }

    /// A legacy sketch encoded WITHOUT the constraints/dimensions keys still
    /// decodes (backward-compatible `decodeIfPresent`). Simulated by stripping
    /// those keys from a real encoding.
    func testLegacySketchWithoutConstraintKeysDecodes() throws {
        let sketch = Sketch(plane: .ground, entities: [line(SIMD2(0, 0), SIMD2(5, 0))])
        let data = try JSONEncoder().encode(sketch)
        var dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        dict.removeValue(forKey: "constraints")
        dict.removeValue(forKey: "dimensions")
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(Sketch.self, from: stripped)
        XCTAssertEqual(decoded.constraints, [])
        XCTAssertEqual(decoded.dimensions, [])
        XCTAssertEqual(decoded.entities.count, 1)
    }

    // MARK: - Delete constraint / dimension (undoable, re-solves)

    func testDeleteConstraintIsUndoable() throws {
        let vm = try makeViewModel()
        let l0 = line(SIMD2(0, 0), SIMD2(10, 0.5))
        let s = openSketch(vm, entities: [l0])
        vm.selectedSketchEntityIDs = [l0.id]
        vm.applyConstraint(.horizontal)
        XCTAssertEqual(sketch(in: vm, s.id)?.constraints.count, 1)

        let cid = try XCTUnwrap(sketch(in: vm, s.id)?.constraints.first?.id)
        vm.selectConstraint(cid)
        XCTAssertEqual(vm.selectedConstraintID, cid)
        vm.deleteSelection()
        XCTAssertEqual(sketch(in: vm, s.id)?.constraints.count, 0,
                       "Deleting the selected constraint removes it")
        XCTAssertNil(vm.selectedConstraintID)

        vm.undo()
        XCTAssertEqual(sketch(in: vm, s.id)?.constraints.count, 1,
                       "Undo restores the deleted constraint")
    }

    func testDeleteDimensionIsUndoable() throws {
        let vm = try makeViewModel()
        let l0 = line(SIMD2(0, 0), SIMD2(10, 0))
        let s = openSketch(vm, entities: [l0])
        let dim = SketchDimension(kind: .distance, refs: [
            ConstraintRef(entityID: l0.id, role: .endpointA),
            ConstraintRef(entityID: l0.id, role: .endpointB),
        ], value: 10)
        vm.session.perform(AddSketchDimensionCommand(sketchID: s.id, dimension: dim))

        vm.selectDimension(dim.id)
        vm.deleteSelection()
        XCTAssertEqual(sketch(in: vm, s.id)?.dimensions.count, 0)
        vm.undo()
        XCTAssertEqual(sketch(in: vm, s.id)?.dimensions.count, 1,
                       "Undo restores the deleted dimension")
    }

    // MARK: - Over-constraint refusal (never corrupt the sketch)

    /// Locking both endpoints of a sloped line pins them; a subsequent
    /// Horizontal cannot level a pinned line, so the solver conflicts. The
    /// constraint must be REFUSED (not added) and an error surfaced.
    func testOverConstrainingHorizontalIsRefused() throws {
        let vm = try makeViewModel()
        let l0 = line(SIMD2(0, 0), SIMD2(10, 5))
        let s = openSketch(vm, entities: [l0])

        vm.selectedSketchEntityIDs = [l0.id]
        vm.applyConstraint(.fixed)          // Lock both endpoints (pins positions)
        XCTAssertEqual(sketch(in: vm, s.id)?.constraints.count, 1)

        vm.selectedSketchEntityIDs = [l0.id]
        vm.errorMessage = nil
        vm.applyConstraint(.horizontal)     // conflicts with the pinned, sloped line

        XCTAssertEqual(sketch(in: vm, s.id)?.constraints.count, 1,
                       "An over-constraining Horizontal must NOT be added")
        XCTAssertNotNil(vm.errorMessage,
                        "Over-constraint should surface a non-blocking message")
        // The geometry is untouched.
        let after = sketch(in: vm, s.id)
        if case let .line(_, a, b)? = after?.entities.first {
            XCTAssertEqual(a, SIMD2(0, 0))
            XCTAssertEqual(b, SIMD2(10, 5))
        } else {
            XCTFail("Line missing after refusal")
        }
    }

    // MARK: - Constraints survive extrude (extrude only hides the sketch)

    /// Extrude commits `SetItemVisibilityCommand(item:.sketch, isHidden:true)`
    /// — it never removes the sketch. Its constraints/dimensions stay attached
    /// and reload with it.
    func testConstraintsSurviveSketchHideAndReload() throws {
        let vm = try makeViewModel()
        let l0 = line(SIMD2(0, 0), SIMD2(10, 0.5))
        let s = openSketch(vm, entities: [l0])
        vm.selectedSketchEntityIDs = [l0.id]
        vm.applyConstraint(.horizontal)
        XCTAssertEqual(sketch(in: vm, s.id)?.constraints.count, 1)

        // Mimic what extrude does to the source sketch.
        vm.session.perform(SetItemVisibilityCommand(item: .sketch(s.id), isHidden: true))
        let hidden = try XCTUnwrap(sketch(in: vm, s.id))
        XCTAssertTrue(hidden.isHidden, "Extrude hides the sketch")
        XCTAssertEqual(hidden.constraints.count, 1,
                       "Hiding the sketch keeps its constraints")

        // And they persist through the reopen path.
        let data = try JSONEncoder().encode(hidden)
        let reloaded = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertTrue(reloaded.isHidden)
        XCTAssertEqual(reloaded.constraints.count, 1)
    }
}
