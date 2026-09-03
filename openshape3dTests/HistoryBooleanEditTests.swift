import XCTest
import SwiftData
import Euclid
@testable import openshape3d

/// G8 reference rows: "Edit Tool" on a boolean row re-enters the tool pick on
/// the node's target; the next tapped body becomes the tool and the rebuild
/// does the CSG — the node is rewritten in place.
@MainActor
final class HistoryBooleanEditTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "History Boolean Edit Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    /// A feature-owned 10 mm box at `x`: the primitive node carries the
    /// PLACEMENT (a rebuild drops document-level transforms by design — moves
    /// are `.transform` nodes), and the body's mesh is baked the same way
    /// `evalPrimitive` bakes it, so the tap before any rebuild lands too.
    private func ownedBox(_ vm: EditorViewModel, _ name: String, x: Double) -> (body: BodyID, node: FeatureID) {
        var document = vm.session.document
        var placement = Transform3D.identity
        placement.translation = SIMD3(x, 0, 0)
        let mesh = Mesh.primitive(.box(width: 10, depth: 10, height: 10)).transformed(by: placement.euclid)
        let body = Body(name: name, transform: .identity, euclidMesh: mesh,
                        revision: document.nextRevision())
        let node = FeatureNode(name: name,
                               kind: .primitive(spec: .box(width: 10, depth: 10, height: 10), placement: placement),
                               outputBodyIDs: [body.id])
        vm.session.perform(CompositeCommand(title: name, commands: [
            AddBodyCommand(body: body), AppendFeatureCommand(node: node),
        ]))
        return (body.id, node.id)
    }

    private func volume(_ body: Body) -> Double {
        let p = body.render.positions, idx = body.render.indices
        var six = 0.0
        var i = 0
        while i + 2 < idx.count {
            let a = SIMD3<Double>(p[Int(idx[i])]), b = SIMD3<Double>(p[Int(idx[i + 1])]), c = SIMD3<Double>(p[Int(idx[i + 2])])
            six += simd_dot(a, simd_cross(b, c))
            i += 3
        }
        return abs(six) / 6
    }

    private func tap(_ vm: EditorViewModel, x: Float) {
        vm.handle(.tap(ray: Ray(origin: SIMD3(x, 30, 0), direction: SIMD3(0, -1, 0))))
    }

    func testEditToolRePicksTheToolBodyAndRebuildsInPlace() throws {
        let vm = try makeViewModel()
        let a = ownedBox(vm, "A", x: 0)     // x −5…5
        let b = ownedBox(vm, "B", x: 40)    // x 35…45, the original tool
        let c = ownedBox(vm, "C", x: 5)     // x 0…10, overlaps A by half
        let union = FeatureNode(name: "Union", kind: .boolean(
            kind: .union,
            target: BodyRef(producer: a.node, bodyID: a.body),
            tools: [BodyRef(producer: b.node, bodyID: b.body)]), outputBodyIDs: [a.body])
        vm.session.perform(AppendFeatureCommand(node: union))
        XCTAssertEqual(vm.referenceEditLabel(union.id), "Edit Tool")

        XCTAssertTrue(vm.beginReferenceEdit(union.id))
        XCTAssertEqual(vm.mode, .pickingBooleanTool(.union, target: a.body))
        XCTAssertEqual(vm.booleanEditingFeature, union.id)

        // Tapping the target itself is not a tool.
        tap(vm, x: -3)
        XCTAssertEqual(vm.booleanEditingFeature, union.id)

        // Tap C: the node's tool becomes C, the rebuild unions A with C.
        tap(vm, x: 8)
        XCTAssertNil(vm.booleanEditingFeature)
        XCTAssertEqual(vm.mode, .selected(a.body))
        guard case let .boolean(kind, target, tools)? = vm.session.document.features.node(union.id)?.kind else {
            return XCTFail("boolean node kept")
        }
        XCTAssertEqual(kind, .union)
        XCTAssertEqual(target.bodyID, a.body)
        XCTAssertEqual(tools.map(\.bodyID), [c.body])
        XCTAssertEqual(vm.session.document.features.nodes.count, 4, "rewritten, not appended")
        XCTAssertNil(vm.session.document.body(with: c.body), "C was consumed as the tool")
        XCTAssertNotNil(vm.session.document.body(with: b.body), "B is a plain body again")
        let result = try XCTUnwrap(vm.session.document.body(with: a.body))
        XCTAssertEqual(volume(result), 1500, accuracy: 1, "two 1000 boxes overlapping by 500")

        // One undo step back to B as the tool.
        vm.session.undo()
        guard case let .boolean(_, _, tools0)? = vm.session.document.features.node(union.id)?.kind else {
            return XCTFail("boolean node kept")
        }
        XCTAssertEqual(tools0.map(\.bodyID), [b.body])
    }

    func testABodyCreatedAfterTheBooleanIsRefusedAndCancelDropsTheEdit() throws {
        let vm = try makeViewModel()
        let a = ownedBox(vm, "A", x: 0)
        let b = ownedBox(vm, "B", x: 40)
        let union = FeatureNode(name: "Union", kind: .boolean(
            kind: .union,
            target: BodyRef(producer: a.node, bodyID: a.body),
            tools: [BodyRef(producer: b.node, bodyID: b.body)]), outputBodyIDs: [a.body])
        vm.session.perform(AppendFeatureCommand(node: union))
        let late = ownedBox(vm, "Late", x: 20) // after the boolean in history

        XCTAssertTrue(vm.beginReferenceEdit(union.id))
        tap(vm, x: 20)
        XCTAssertEqual(vm.booleanEditingFeature, union.id, "still editing — the late body was refused")
        XCTAssertNotNil(vm.errorMessage)
        guard case let .boolean(_, _, tools)? = vm.session.document.features.node(union.id)?.kind else {
            return XCTFail("boolean node kept")
        }
        XCTAssertEqual(tools.map(\.bodyID), [b.body])
        XCTAssertNotNil(vm.session.document.body(with: late.body))

        vm.cancelBooleanPicking()
        XCTAssertNil(vm.booleanEditingFeature)
        XCTAssertEqual(vm.mode, .idle)
    }
}
