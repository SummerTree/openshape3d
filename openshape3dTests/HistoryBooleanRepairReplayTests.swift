import XCTest
import SwiftData
import Euclid
@testable import openshape3d

/// The live repair flow, end to end at the session level: a subtract is
/// evaluated, its tool's node is deleted (the boolean errors), and the tool
/// is re-picked. The rebuilt target must be the TARGET's own geometry minus
/// the new tool — never the stale, already-cut body from before.
@MainActor
final class HistoryBooleanRepairReplayTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "Boolean Repair Replay Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    private func ownedBox(_ vm: EditorViewModel, _ name: String, size: Double, x: Double) -> (body: BodyID, node: FeatureID) {
        var document = vm.session.document
        var placement = Transform3D.identity
        placement.translation = SIMD3(x, 0, 0)
        let mesh = Mesh.primitive(.box(width: size, depth: size, height: size)).transformed(by: placement.euclid)
        let body = Body(name: name, transform: .identity, euclidMesh: mesh, revision: document.nextRevision())
        let node = FeatureNode(name: name,
                               kind: .primitive(spec: .box(width: size, depth: size, height: size), placement: placement),
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

    func testRepickingTheToolAfterItsNodeWasDeletedStartsFromTheTargetsOwnGeometry() throws {
        let vm = try makeViewModel()
        let plate = ownedBox(vm, "Plate", size: 20, x: 0)   // 8000, x −10…10
        let peg = ownedBox(vm, "Peg", size: 4, x: 8)        // 64, x 6…10 — inside the plate
        let spare = ownedBox(vm, "Spare", size: 4, x: 10)   // 64, x 8…12 — half in, half out: tappable from above
        let cut = FeatureNode(name: "Cut", kind: .boolean(
            kind: .subtract,
            target: BodyRef(producer: plate.node, bodyID: plate.body),
            tools: [BodyRef(producer: peg.node, bodyID: peg.body)]), outputBodyIDs: [plate.body])
        vm.session.recordAndRebuild([cut], title: "Cut")
        XCTAssertEqual(volume(try XCTUnwrap(vm.session.document.body(with: plate.body))), 8000 - 64, accuracy: 1)
        XCTAssertNil(vm.session.document.body(with: peg.body), "the peg was consumed")

        // Delete the peg's node: the cut's tool reference goes stale.
        vm.deleteFeature(peg.node)
        XCTAssertNotNil(vm.session.lastEvalErrors[cut.id], "the cut reports its broken tool")
        let afterDelete = try XCTUnwrap(vm.session.document.body(with: plate.body))
        XCTAssertEqual(volume(afterDelete), 8000, accuracy: 1,
                       "with no tool to cut, the target is its own geometry again")

        // Repair: re-pick the spare as the tool (as the History row's Edit Tool does).
        XCTAssertTrue(vm.beginReferenceEdit(cut.id))
        vm.handle(.tap(ray: Ray(origin: SIMD3(11, 30, 0), direction: SIMD3(0, -1, 0)))) // outside the plate's footprint
        XCTAssertNil(vm.session.lastEvalErrors[cut.id], "repaired")
        XCTAssertNil(vm.session.document.body(with: spare.body), "the spare is consumed now")
        let repaired = try XCTUnwrap(vm.session.document.body(with: plate.body))
        XCTAssertEqual(volume(repaired), 8000 - 32, accuracy: 1,
                       "the plate minus the SPARE's overlap only — the deleted peg's pocket must not survive")
    }
}
