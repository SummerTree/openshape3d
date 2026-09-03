import XCTest
import SwiftData
@testable import openshape3d

/// G8, first slice: every scalar a feature has is an editable field in its
/// History row — not only extrude's distance and the pattern trio. The row
/// model carries the scalars (label, unit, value); an edit by key rewrites
/// the node's `Expr` and rebuilds.
@MainActor
final class HistoryScalarEditTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "History Scalar Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    // Dummy references: the nodes never need to evaluate cleanly (a broken
    // ref badges the row); the edit rewrites the KIND, which is what is pinned.
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

    private func scalars(_ vm: EditorViewModel, _ id: FeatureID) -> [EditorViewModel.FeatureScalar] {
        vm.historyRows.first { $0.id == id }?.scalars ?? []
    }

    private func kind(_ vm: EditorViewModel, _ id: FeatureID) -> FeatureKind? {
        vm.session.document.features.node(id)?.kind
    }

    func testEveryScalarKindShowsLabelledUnitFields() throws {
        let vm = try makeViewModel()
        let extrude = append(vm, "E", .extrude(profile: profile, plane: plane, distance: Expr(value: 20),
                                               symmetric: false, boolean: intent, extraProfiles: []))
        let draft = append(vm, "D", .draftExtrude(profile: profile, plane: plane, distance: Expr(value: 30),
                                                  taperAngle: Expr(value: 5), symmetric: false, boolean: intent))
        let revolve = append(vm, "R", .revolve(profile: profile, plane: plane,
                                               axis: AxisRef(source: .sketchLine(SketchID(), UUID())),
                                               angle: Expr(value: 270), boolean: intent))
        let chamfer = append(vm, "C", .chamfer(body: body, edges: [], setback: Expr(value: 1.5)))
        let fillet = append(vm, "F", .fillet(body: body, edges: [], radius: Expr(value: 2.5)))
        let shell = append(vm, "S", .shell(body: body, openFaces: [], thickness: Expr(value: 1.2)))
        let mirror = append(vm, "M", .mirror(body: body, plane: plane, keepOriginal: true))

        func one(_ id: FeatureID, _ label: String, _ unit: String, _ value: Double,
                 file: StaticString = #filePath, line: UInt = #line) {
            let s = scalars(vm, id)
            XCTAssertEqual(s.count, 1, file: file, line: line)
            XCTAssertEqual(s.first?.key, .primary, file: file, line: line)
            XCTAssertEqual(s.first?.label, label, file: file, line: line)
            XCTAssertEqual(s.first?.unit, unit, file: file, line: line)
            XCTAssertEqual(s.first?.value ?? .nan, value, accuracy: 1e-12, file: file, line: line)
        }
        one(extrude, "Distance", "mm", 20)
        one(revolve, "Angle", "°", 270)
        one(chamfer, "Setback", "mm", 1.5)
        one(fillet, "Radius", "mm", 2.5)
        one(shell, "Thickness", "mm", 1.2)
        XCTAssertEqual(scalars(vm, mirror), [], "a mirror has no scalar")

        let d = scalars(vm, draft)
        XCTAssertEqual(d.map(\.key), [.primary, .taperAngle])
        XCTAssertEqual(d.map(\.label), ["Distance", "Draft"])
        XCTAssertEqual(d.map(\.unit), ["mm", "°"])
        XCTAssertEqual(d.map(\.value), [30, 5])
    }

    func testEditingByKeyRewritesTheNodeAndTheRowFollows() throws {
        let vm = try makeViewModel()
        let draft = append(vm, "D", .draftExtrude(profile: profile, plane: plane, distance: Expr(value: 30),
                                                  taperAngle: Expr(value: 5), symmetric: true, boolean: intent))
        let revolve = append(vm, "R", .revolve(profile: profile, plane: plane,
                                               axis: AxisRef(source: .sketchLine(SketchID(), UUID())),
                                               angle: Expr(value: 270), boolean: intent))
        let fillet = append(vm, "F", .fillet(body: body, edges: [], radius: Expr(value: 2.5)))
        let shell = append(vm, "S", .shell(body: body, openFaces: [], thickness: Expr(value: 1.2)))

        vm.editFeatureScalar(draft, key: .taperAngle, value: 12)
        vm.editFeatureScalar(draft, key: .primary, value: 45)
        guard case let .draftExtrude(_, _, distance, taper, symmetric, _)? = kind(vm, draft) else {
            return XCTFail("draft extrude kind kept")
        }
        XCTAssertEqual(distance.value, 45)
        XCTAssertEqual(taper.value, 12)
        XCTAssertTrue(symmetric, "the other options ride along untouched")
        XCTAssertEqual(scalars(vm, draft).map(\.value), [45, 12])

        vm.editFeatureScalar(revolve, key: .primary, value: 90)
        guard case let .revolve(_, _, _, angle, _)? = kind(vm, revolve) else { return XCTFail("revolve kept") }
        XCTAssertEqual(angle.value, 90)

        vm.editFeatureScalar(fillet, key: .primary, value: 4)
        guard case let .fillet(_, _, radius)? = kind(vm, fillet) else { return XCTFail("fillet kept") }
        XCTAssertEqual(radius.value, 4)

        vm.editFeatureScalar(shell, key: .primary, value: 0.8)
        guard case let .shell(_, _, thickness)? = kind(vm, shell) else { return XCTFail("shell kept") }
        XCTAssertEqual(thickness.value, 0.8)

        // A key the kind does not have is ignored.
        vm.editFeatureScalar(fillet, key: .taperAngle, value: 99)
        guard case let .fillet(_, _, radius2)? = kind(vm, fillet) else { return XCTFail("fillet kept") }
        XCTAssertEqual(radius2.value, 4)
    }

    func testAScalarEditIsOneUndoStep() throws {
        let vm = try makeViewModel()
        let shell = append(vm, "S", .shell(body: body, openFaces: [], thickness: Expr(value: 1.2)))
        vm.editFeatureScalar(shell, key: .primary, value: 3)
        guard case let .shell(_, _, t1)? = kind(vm, shell) else { return XCTFail("shell kept") }
        XCTAssertEqual(t1.value, 3)
        vm.session.undo()
        guard case let .shell(_, _, t0)? = kind(vm, shell) else { return XCTFail("shell kept") }
        XCTAssertEqual(t0.value, 1.2, "undo restores the previous thickness")
        vm.session.redo()
        guard case let .shell(_, _, t2)? = kind(vm, shell) else { return XCTFail("shell kept") }
        XCTAssertEqual(t2.value, 3)
    }
}
