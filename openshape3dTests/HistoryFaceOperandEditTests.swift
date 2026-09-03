import XCTest
import SwiftData
import Euclid
@testable import openshape3d

/// G8 reference rows: "Edit Face" on a push/pull (and the face tools) row
/// re-enters a face pick on the body the feature CONSUMED; the tapped planar
/// face becomes the node's operand and the rebuild replays it in place.
@MainActor
final class HistoryFaceOperandEditTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "History Face Operand Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    private func ownedBox(_ vm: EditorViewModel) -> (body: BodyID, node: FeatureID) {
        var document = vm.session.document
        let body = Body(name: "Box", transform: .identity,
                        euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)),
                        revision: document.nextRevision())
        let node = FeatureNode(name: "Box",
                               kind: .primitive(spec: .box(width: 10, depth: 10, height: 10), placement: .identity),
                               outputBodyIDs: [body.id])
        vm.session.perform(CompositeCommand(title: "Box", commands: [
            AddBodyCommand(body: body), AppendFeatureCommand(node: node),
        ]))
        return (body.id, node.id)
    }

    /// The top face of the box as the app's push/pull would reference it.
    private func topFaceRef(_ vm: EditorViewModel, box: (body: BodyID, node: FeatureID)) throws -> FaceRef {
        let body = try XCTUnwrap(vm.session.document.body(with: box.body))
        let seed = try XCTUnwrap((0..<body.render.triangleCount).first { t in
            guard let face = FaceTopology.planarFace(in: body.render, seedTriangle: t) else { return false }
            return face.normal.y > 0.99
        })
        let face = try XCTUnwrap(FaceTopology.planarFace(in: body.render, seedTriangle: seed))
        let n = SIMD3<Double>(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let signature = FaceSignature(kind: .planar, normal: n, centroid: face.origin,
                                      area: abs(Profile.signedArea(face.outline)),
                                      planeOffset: simd_dot(n, face.origin))
        return FaceRef(body: BodyRef(producer: box.node, bodyID: box.body), creator: box.node,
                       role: .derived(index: 0), signature: signature)
    }

    private func bounds(_ body: Body) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let aabb = body.render.localAABB
        return (aabb.min, aabb.max)
    }

    func testEditFaceRePicksAPushPullsFaceOnTheConsumedBody() throws {
        let vm = try makeViewModel()
        let box = ownedBox(vm)
        let push = FeatureNode(name: "Push/Pull", kind: .pushPull(
            face: try topFaceRef(vm, box: box), distance: Expr(value: 5), mode: .planarAxial),
            outputBodyIDs: [box.body])
        vm.session.recordAndRebuild([push], title: "Push")
        XCTAssertNil(vm.session.lastEvalErrors[push.id])
        let pushed = try XCTUnwrap(vm.session.document.body(with: box.body))
        XCTAssertEqual(Double(bounds(pushed).max.y), 15, accuracy: 1e-3, "the top went up 5")
        XCTAssertEqual(Double(bounds(pushed).max.x), 5, accuracy: 1e-3)
        XCTAssertEqual(vm.referenceEditLabel(push.id), "Edit Face")

        XCTAssertTrue(vm.beginReferenceEdit(push.id))
        XCTAssertEqual(vm.mode, .pickingFeatureFace(push.id))
        XCTAssertEqual(vm.featureFacePickPrompt, "Tap the face for Push/Pull")

        // Tap the +x side. The document's body is the pushed one; the pick
        // resolves on the consumed box, whose +x face coincides.
        vm.handle(.tap(ray: Ray(origin: SIMD3(30, 5, 0), direction: SIMD3(-1, 0, 0))))
        XCTAssertEqual(vm.mode, .selected(box.body))
        guard case let .pushPull(face, distance, pushMode)? = vm.session.document.features.node(push.id)?.kind else {
            return XCTFail("push/pull node kept")
        }
        XCTAssertEqual(face.signature.normal.x, 1, accuracy: 1e-6, "the +x face now")
        XCTAssertEqual(distance.value, 5, "the distance rides along")
        XCTAssertEqual(pushMode, .planarAxial)
        XCTAssertNil(vm.session.lastEvalErrors[push.id])
        XCTAssertEqual(vm.session.document.features.nodes.count, 2, "rewritten, not appended")
        let repicked = try XCTUnwrap(vm.session.document.body(with: box.body))
        XCTAssertEqual(Double(bounds(repicked).max.x), 10, accuracy: 1e-3, "the +x side went out 5")
        XCTAssertEqual(Double(bounds(repicked).max.y), 10, accuracy: 1e-3, "and the top is back where it was")

        vm.session.undo()
        guard case let .pushPull(face0, _, _)? = vm.session.document.features.node(push.id)?.kind else {
            return XCTFail("push/pull node kept")
        }
        XCTAssertEqual(face0.signature.normal.y, 1, accuracy: 1e-6, "one undo step back to the top face")
    }

    func testTapsOffTheBodyAreIgnoredAndCancelIsInert() throws {
        let vm = try makeViewModel()
        let box = ownedBox(vm)
        let push = FeatureNode(name: "Push/Pull", kind: .pushPull(
            face: try topFaceRef(vm, box: box), distance: Expr(value: 5), mode: .planarAxial),
            outputBodyIDs: [box.body])
        vm.session.recordAndRebuild([push], title: "Push")
        XCTAssertTrue(vm.beginReferenceEdit(push.id))
        vm.handle(.tap(ray: Ray(origin: SIMD3(100, 100, 100), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(vm.mode, .pickingFeatureFace(push.id), "a miss keeps the pick armed")
        vm.cancelFeatureFacePick()
        XCTAssertEqual(vm.mode, .idle)
        guard case let .pushPull(face, _, _)? = vm.session.document.features.node(push.id)?.kind else {
            return XCTFail("push/pull node kept")
        }
        XCTAssertEqual(face.signature.normal.y, 1, accuracy: 1e-6, "untouched")
    }
}
