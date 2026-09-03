import XCTest
import SwiftData
import Euclid
@testable import openshape3d

/// G8 reference rows: "Edit Body" on a mirror / pattern / transform row
/// re-enters a body pick; the next tapped body becomes the node's operand
/// and the rebuild replays it in place.
@MainActor
final class HistoryBodyEditTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "History Body Edit Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    private func ownedBox(_ vm: EditorViewModel, _ name: String, x: Double) -> (body: BodyID, node: FeatureID) {
        var document = vm.session.document
        var placement = Transform3D.identity
        placement.translation = SIMD3(x, 0, 0)
        let mesh = Mesh.primitive(.box(width: 10, depth: 10, height: 10)).transformed(by: placement.euclid)
        let body = Body(name: name, transform: .identity, euclidMesh: mesh, revision: document.nextRevision())
        let node = FeatureNode(name: name,
                               kind: .primitive(spec: .box(width: 10, depth: 10, height: 10), placement: placement),
                               outputBodyIDs: [body.id])
        vm.session.perform(CompositeCommand(title: name, commands: [
            AddBodyCommand(body: body), AppendFeatureCommand(node: node),
        ]))
        return (body.id, node.id)
    }

    private func tap(_ vm: EditorViewModel, x: Float) {
        vm.handle(.tap(ray: Ray(origin: SIMD3(x, 30, 0), direction: SIMD3(0, -1, 0))))
    }

    func testEditBodyRePicksAMirrorsSourceAndReplaysIt() throws {
        let vm = try makeViewModel()
        let a = ownedBox(vm, "A", x: 0)
        let b = ownedBox(vm, "B", x: 40)
        let mirror = FeatureNode(name: "Mirror", kind: .mirror(
            body: BodyRef(producer: a.node, bodyID: a.body),
            plane: PlaneRef(source: .explicit(SketchPlane(origin: SIMD3(0, 0, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)))),
            keepOriginal: true), outputBodyIDs: [BodyID()]) // the mirrored copy's id
        vm.session.recordAndRebuild([mirror], title: "Mirror")
        XCTAssertNil(vm.session.lastEvalErrors[mirror.id])
        let before = vm.session.document.bodies.count
        XCTAssertEqual(vm.referenceEditLabel(mirror.id), "Edit Body")

        XCTAssertTrue(vm.beginReferenceEdit(mirror.id))
        XCTAssertEqual(vm.mode, .pickingFeatureBody(mirror.id))
        XCTAssertEqual(vm.selection, [a.body], "the current operand is shown selected")
        XCTAssertEqual(vm.featureBodyPickPrompt, "Tap the body for Mirror")

        tap(vm, x: 40) // B
        guard case let .mirror(body, _, keep)? = vm.session.document.features.node(mirror.id)?.kind else {
            return XCTFail("mirror node kept")
        }
        XCTAssertEqual(body.bodyID, b.body)
        XCTAssertEqual(body.producer, b.node)
        XCTAssertTrue(keep, "options untouched")
        XCTAssertNil(vm.session.lastEvalErrors[mirror.id], "replays cleanly on the new source")
        XCTAssertEqual(vm.session.document.bodies.count, before, "still one mirrored copy")
        XCTAssertEqual(vm.session.document.features.nodes.count, 3, "rewritten, not appended")
        XCTAssertEqual(vm.mode, .selected(b.body))
        // The mirrored copy now lies across the plane from B, at x ≈ 40.
        let mirrored = try XCTUnwrap(vm.session.document.bodies.first { $0.id != a.body && $0.id != b.body })
        let aabb = mirrored.render.localAABB
        XCTAssertEqual(Double((aabb.min.x + aabb.max.x) / 2), 40, accuracy: 1e-3)

        vm.session.undo()
        guard case let .mirror(body0, _, _)? = vm.session.document.features.node(mirror.id)?.kind else {
            return XCTFail("mirror node kept")
        }
        XCTAssertEqual(body0.bodyID, a.body, "one undo step back to A")
    }

    func testTransformRowRePicksItsBodyAndLateBodiesAreRefused() throws {
        let vm = try makeViewModel()
        let a = ownedBox(vm, "A", x: 0)
        let b = ownedBox(vm, "B", x: 40)
        var delta = Transform3D.identity
        delta.translation = SIMD3(0, 0, 5)
        let move = FeatureNode(name: "Move", kind: .transform(
            body: BodyRef(producer: a.node, bodyID: a.body), delta: delta), outputBodyIDs: [a.body])
        vm.session.recordAndRebuild([move], title: "Move")
        let late = ownedBox(vm, "Late", x: 80)
        XCTAssertEqual(vm.referenceEditLabel(move.id), "Edit Body")

        XCTAssertTrue(vm.beginReferenceEdit(move.id))
        tap(vm, x: 80) // created after the transform: refused, still picking
        XCTAssertEqual(vm.mode, .pickingFeatureBody(move.id))
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNotNil(vm.session.document.body(with: late.body))

        tap(vm, x: 40) // B: accepted
        guard case let .transform(body, d)? = vm.session.document.features.node(move.id)?.kind else {
            return XCTFail("transform node kept")
        }
        XCTAssertEqual(body.bodyID, b.body)
        XCTAssertEqual(d.translation.z, 5, accuracy: 1e-12, "the delta rides along")
        XCTAssertNil(vm.session.lastEvalErrors[move.id])

        // Cancel from the pick leaves everything alone.
        XCTAssertTrue(vm.beginReferenceEdit(move.id))
        vm.cancelFeatureBodyPick()
        XCTAssertEqual(vm.mode, .idle)
        guard case let .transform(body2, _)? = vm.session.document.features.node(move.id)?.kind else {
            return XCTFail("transform node kept")
        }
        XCTAssertEqual(body2.bodyID, b.body)
    }
}
