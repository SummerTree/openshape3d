import XCTest
import SwiftData
@testable import openshape3d

/// G8, second slice: a feature's Boolean options and enum choices are
/// editable in its History row — extrude / draft symmetric, mirror
/// keep-original, a boolean node's kind — through the same edit-and-rebuild
/// path as the scalars.
@MainActor
final class HistoryOptionEditTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "History Option Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    private let profile = ProfileRef(sketchID: SketchID(), entityIDs: [UUID()], holeEntityIDs: [], seedPoint: nil)
    private let plane = PlaneRef(source: .ground)
    private let body = BodyRef(producer: FeatureID(), bodyID: BodyID())
    private let intent = BooleanIntent(op: .newBody, resolvedTargets: [])

    @discardableResult
    private func append(_ vm: EditorViewModel, _ name: String, _ kind: FeatureKind) -> FeatureID {
        let node = FeatureNode(name: name, kind: kind, outputBodyIDs: [])
        vm.session.perform(AppendFeatureCommand(node: node))
        return node.id
    }

    private func options(_ vm: EditorViewModel, _ id: FeatureID) -> [EditorViewModel.FeatureOption] {
        vm.historyRows.first { $0.id == id }?.options ?? []
    }

    private func kind(_ vm: EditorViewModel, _ id: FeatureID) -> FeatureKind? {
        vm.session.document.features.node(id)?.kind
    }

    func testRowsCarryTheirTogglesAndChoices() throws {
        let vm = try makeViewModel()
        let extrude = append(vm, "E", .extrude(profile: profile, plane: plane, distance: Expr(value: 20),
                                               symmetric: true, boolean: intent, extraProfiles: []))
        let draft = append(vm, "D", .draftExtrude(profile: profile, plane: plane, distance: Expr(value: 30),
                                                  taperAngle: Expr(value: 5), symmetric: false, boolean: intent))
        let mirror = append(vm, "M", .mirror(body: body, plane: plane, keepOriginal: false))
        let boolean = append(vm, "B", .boolean(kind: .subtract, target: body, tools: [body]))
        let fillet = append(vm, "F", .fillet(body: body, edges: [], radius: Expr(value: 2)))

        XCTAssertEqual(options(vm, extrude), [
            .init(key: .symmetric, label: "Symmetric", value: .toggle(true)),
        ])
        XCTAssertEqual(options(vm, draft), [
            .init(key: .symmetric, label: "Symmetric", value: .toggle(false)),
        ])
        XCTAssertEqual(options(vm, mirror), [
            .init(key: .keepOriginal, label: "Keep original", value: .toggle(false)),
        ])
        XCTAssertEqual(options(vm, boolean), [
            .init(key: .booleanKind, label: "Type",
                  value: .choice(selected: "Subtract", choices: ["Union", "Subtract", "Intersect"])),
        ])
        XCTAssertEqual(options(vm, fillet), [], "a fillet has no options yet")
    }

    func testTogglesAndChoicesRewriteTheNodeAsOneUndoStep() throws {
        let vm = try makeViewModel()
        let extrude = append(vm, "E", .extrude(profile: profile, plane: plane, distance: Expr(value: 20),
                                               symmetric: false, boolean: intent, extraProfiles: []))
        let draft = append(vm, "D", .draftExtrude(profile: profile, plane: plane, distance: Expr(value: 30),
                                                  taperAngle: Expr(value: 5), symmetric: false, boolean: intent))
        let mirror = append(vm, "M", .mirror(body: body, plane: plane, keepOriginal: true))
        let boolean = append(vm, "B", .boolean(kind: .union, target: body, tools: [body]))

        vm.setFeatureOption(extrude, key: .symmetric, toggle: true)
        guard case let .extrude(_, _, distance, symmetric, _, _)? = kind(vm, extrude) else { return XCTFail("extrude kept") }
        XCTAssertTrue(symmetric)
        XCTAssertEqual(distance.value, 20, "the scalar rides along untouched")

        vm.setFeatureOption(draft, key: .symmetric, toggle: true)
        guard case let .draftExtrude(_, _, _, taper, draftSymmetric, _)? = kind(vm, draft) else { return XCTFail("draft kept") }
        XCTAssertTrue(draftSymmetric)
        XCTAssertEqual(taper.value, 5)

        vm.setFeatureOption(mirror, key: .keepOriginal, toggle: false)
        guard case let .mirror(_, _, keep)? = kind(vm, mirror) else { return XCTFail("mirror kept") }
        XCTAssertFalse(keep)

        vm.setFeatureOption(boolean, key: .booleanKind, choice: "Intersect")
        guard case let .boolean(bk, _, tools)? = kind(vm, boolean) else { return XCTFail("boolean kept") }
        XCTAssertEqual(bk, .intersect)
        XCTAssertEqual(tools.count, 1, "operands untouched")

        // Unknown choice text and a key the kind lacks are ignored.
        vm.setFeatureOption(boolean, key: .booleanKind, choice: "Explode")
        guard case let .boolean(bk2, _, _)? = kind(vm, boolean) else { return XCTFail("boolean kept") }
        XCTAssertEqual(bk2, .intersect)
        vm.setFeatureOption(mirror, key: .symmetric, toggle: true)
        guard case let .mirror(_, _, keep2)? = kind(vm, mirror) else { return XCTFail("mirror kept") }
        XCTAssertFalse(keep2)

        // One undo step per edit.
        vm.session.undo() // the ignored edits pushed nothing; this undoes the Intersect choice
        guard case let .boolean(bk3, _, _)? = kind(vm, boolean) else { return XCTFail("boolean kept") }
        XCTAssertEqual(bk3, .union)
        vm.session.undo()
        guard case let .mirror(_, _, keep3)? = kind(vm, mirror) else { return XCTFail("mirror kept") }
        XCTAssertTrue(keep3)
    }
}
