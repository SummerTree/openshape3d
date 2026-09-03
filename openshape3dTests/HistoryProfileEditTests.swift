import XCTest
import SwiftData
@testable import openshape3d

/// G8 reference rows: "Edit Profile" on an extrude row re-enters a profile
/// pick; the tapped sketch fill becomes the node's profile (its sketch the
/// plane) and the rebuild replays it in place.
@MainActor
final class HistoryProfileEditTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "History Profile Edit Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    /// A rectangle sketch on the ground plane spanning `x0…x1` × `−10…10`.
    private func rectSketch(_ vm: EditorViewModel, name: String, x0: Double, x1: Double) -> Sketch {
        let p = [SIMD2(x0, -10), SIMD2(x1, -10), SIMD2(x1, 10), SIMD2(x0, 10)]
        let entities: [SketchEntity] = (0..<4).map { .line(id: UUID(), a: p[$0], b: p[($0 + 1) % 4]) }
        let sketch = Sketch(name: name, plane: .ground, entities: entities)
        vm.session.perform(AddSketchCommand(sketch: sketch))
        return sketch
    }

    func testEditProfilePointsAnExtrudeAtAnotherFillAndReplaysIt() throws {
        let vm = try makeViewModel()
        let a = rectSketch(vm, name: "A", x0: -5, x1: 5)
        let b = rectSketch(vm, name: "B", x0: 20, x1: 30)
        let bodyID = BodyID()
        let extrude = FeatureNode(name: "Extrude", kind: .extrude(
            profile: ProfileRef(sketchID: a.id, entityIDs: a.entities.map(\.id), holeEntityIDs: [], seedPoint: SIMD2(0, 0)),
            plane: PlaneRef(source: .sketch(a.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []),
            outputBodyIDs: [bodyID])
        vm.session.recordAndRebuild([extrude], title: "Extrude")
        XCTAssertNil(vm.session.lastEvalErrors[extrude.id])
        let first = try XCTUnwrap(vm.session.document.body(with: bodyID))
        XCTAssertEqual(Double(first.render.localAABB.max.x), 5, accuracy: 1e-3)
        XCTAssertEqual(vm.referenceEditLabel(extrude.id), "Edit Profile")

        XCTAssertTrue(vm.beginReferenceEdit(extrude.id))
        XCTAssertEqual(vm.mode, .pickingFeatureProfile(extrude.id))
        XCTAssertEqual(vm.featureProfilePickPrompt, "Tap the profile for Extrude")

        // Tap inside B's fill from above (the ground plane's fill at x = 25).
        vm.handle(.tap(ray: Ray(origin: SIMD3(25, 30, 0), direction: SIMD3(0, -1, 0))))
        guard case let .extrude(profile, plane, distance, _, _, extras)? = vm.session.document.features.node(extrude.id)?.kind else {
            return XCTFail("extrude node kept")
        }
        XCTAssertEqual(profile.sketchID, b.id)
        XCTAssertEqual(Set(profile.entityIDs), Set(b.entities.map(\.id)))
        XCTAssertEqual(plane, PlaneRef(source: .sketch(b.id)))
        XCTAssertEqual(distance.value, 10, "the distance rides along")
        XCTAssertTrue(extras.isEmpty)
        XCTAssertNil(vm.session.lastEvalErrors[extrude.id])
        XCTAssertEqual(vm.session.document.features.nodes.count, 1, "rewritten, not appended")
        let moved = try XCTUnwrap(vm.session.document.body(with: bodyID))
        XCTAssertEqual(Double(moved.render.localAABB.min.x), 20, accuracy: 1e-3)
        XCTAssertEqual(Double(moved.render.localAABB.max.x), 30, accuracy: 1e-3)
        XCTAssertEqual(vm.mode, .selected(bodyID))

        vm.session.undo()
        guard case let .extrude(profile0, _, _, _, _, _)? = vm.session.document.features.node(extrude.id)?.kind else {
            return XCTFail("extrude node kept")
        }
        XCTAssertEqual(profile0.sketchID, a.id, "one undo step back to A")
    }

    func testAMissKeepsThePickAndTheSameFillEndsIt() throws {
        let vm = try makeViewModel()
        let a = rectSketch(vm, name: "A", x0: -5, x1: 5)
        let bodyID = BodyID()
        let extrude = FeatureNode(name: "Extrude", kind: .extrude(
            profile: ProfileRef(sketchID: a.id, entityIDs: a.entities.map(\.id), holeEntityIDs: [], seedPoint: SIMD2(0, 0)),
            plane: PlaneRef(source: .sketch(a.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []),
            outputBodyIDs: [bodyID])
        vm.session.recordAndRebuild([extrude], title: "Extrude")
        XCTAssertTrue(vm.beginReferenceEdit(extrude.id))
        vm.handle(.tap(ray: Ray(origin: SIMD3(100, 30, 100), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(vm.mode, .pickingFeatureProfile(extrude.id), "nothing under the tap: still picking")
        vm.handle(.tap(ray: Ray(origin: SIMD3(0, 30, 0), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(vm.mode, .idle, "the profile it already has: the pick just ends")
        XCTAssertEqual(vm.session.document.features.nodes.count, 1)
    }
}
