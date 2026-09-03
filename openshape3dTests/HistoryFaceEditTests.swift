import XCTest
import SwiftData
@testable import openshape3d

/// G8 reference rows, first slice: "Edit Faces" on a shell (and delete-face)
/// row re-enters the face pick seeded with the faces the node has, resolved
/// against the body the feature CONSUMED, and commits by rewriting the node
/// in place — the additive edit mode blends already had as "Edit Edges".
@MainActor
final class HistoryFaceEditTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "History Face Edit Test")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    /// A 10 mm box the feature graph OWNS (a primitive node with the body as
    /// its output — the resize path's arrangement), so a shell on it records
    /// a node and `inputBody` can replay the box back.
    private func ownedBox(_ vm: EditorViewModel) -> BodyID {
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
        return body.id
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

    private func tap(_ vm: EditorViewModel, from origin: SIMD3<Float>, toward direction: SIMD3<Float>) {
        vm.handle(.tap(ray: Ray(origin: origin, direction: simd_normalize(direction))))
    }

    func testEditFacesReopensAShellSeededAndCommitsInPlace() throws {
        let vm = try makeViewModel()
        let boxID = ownedBox(vm)

        // Shell the box with its top open, the way the tool does it.
        vm.toggleSelection(of: boxID)
        vm.beginShell()
        XCTAssertEqual(vm.mode, .pickingShellFaces)
        tap(vm, from: SIMD3(0, 20, 0), toward: SIMD3(0, -1, 0)) // top face (y = 10)
        XCTAssertEqual(vm.shellSelectedFaces.count, 1)
        vm.commitShell()
        let shellNode = try XCTUnwrap(vm.session.document.features.nodes.last)
        guard case let .shell(_, faces1, thickness) = shellNode.kind else { return XCTFail("shell node recorded") }
        XCTAssertEqual(faces1.count, 1)
        XCTAssertEqual(thickness.value, 2, accuracy: 1e-9)
        XCTAssertEqual(vm.session.document.features.nodes.count, 2)
        XCTAssertEqual(vm.referenceEditLabel(shellNode.id), "Edit Faces")
        XCTAssertEqual(volume(try XCTUnwrap(vm.session.document.body(with: boxID))), 1000 - 6 * 6 * 8, accuracy: 1)

        // Edit Faces: the pick reopens on the CONSUMED box, seeded.
        XCTAssertTrue(vm.beginReferenceEdit(shellNode.id))
        XCTAssertEqual(vm.mode, .pickingShellFaces)
        XCTAssertEqual(vm.shellEditingFeature, shellNode.id)
        XCTAssertEqual(vm.shellSelectedFaces.count, 1, "seeded with the open face it has")
        XCTAssertEqual(vm.shellThickness, 2, accuracy: 1e-9)
        XCTAssertNotNil(vm.shellPreview, "previewing the input re-shelled")

        // Add the +x side; the document's copy is hollow, the pick is not fooled.
        tap(vm, from: SIMD3(20, 5, 0), toward: SIMD3(-1, 0, 0))
        XCTAssertEqual(vm.shellSelectedFaces.count, 2)
        vm.commitShell()
        XCTAssertEqual(vm.session.document.features.nodes.count, 2, "edited in place — no second shell")
        guard case let .shell(_, faces2, _)? = vm.session.document.features.node(shellNode.id)?.kind else {
            return XCTFail("shell node kept")
        }
        XCTAssertEqual(faces2.count, 2)
        XCTAssertEqual(vm.mode, .selected(boxID))
        XCTAssertNil(vm.shellEditingFeature)
        // Two open faces: the cavity runs 8 (x, open side) × 8 (y, open top) × 6.
        XCTAssertEqual(volume(try XCTUnwrap(vm.session.document.body(with: boxID))), 1000 - 8 * 8 * 6, accuracy: 1)

        // One undo step back to the single-face shell.
        vm.session.undo()
        guard case let .shell(_, faces3, _)? = vm.session.document.features.node(shellNode.id)?.kind else {
            return XCTFail("shell node kept")
        }
        XCTAssertEqual(faces3.count, 1)
    }

    func testCancelLeavesTheNodeAloneAndTapsElsewhereAreIgnoredWhileEditing() throws {
        let vm = try makeViewModel()
        let boxID = ownedBox(vm)
        vm.toggleSelection(of: boxID)
        vm.beginShell()
        tap(vm, from: SIMD3(0, 20, 0), toward: SIMD3(0, -1, 0))
        vm.commitShell()
        let shellNode = try XCTUnwrap(vm.session.document.features.nodes.last)

        XCTAssertTrue(vm.beginReferenceEdit(shellNode.id))
        // A tap that hits nothing (or another body) does not re-target the edit.
        tap(vm, from: SIMD3(100, 100, 100), toward: SIMD3(0, -1, 0))
        XCTAssertEqual(vm.shellSelectedFaces.count, 1)
        vm.cancelShell()
        XCTAssertNil(vm.shellEditingFeature)
        guard case let .shell(_, faces, _)? = vm.session.document.features.node(shellNode.id)?.kind else {
            return XCTFail("shell node kept")
        }
        XCTAssertEqual(faces.count, 1)
        XCTAssertEqual(vm.session.document.features.nodes.count, 2)
    }

    func testReferenceLabelsPerKindAndAnUnreplayableInputRefuses() throws {
        let vm = try makeViewModel()
        let body = BodyRef(producer: FeatureID(), bodyID: BodyID())
        let fillet = FeatureNode(name: "F", kind: .fillet(body: body, edges: [], radius: Expr(value: 1)), outputBodyIDs: [])
        let delete = FeatureNode(name: "D", kind: .deleteFace(body: body, faces: []), outputBodyIDs: [])
        let mirror = FeatureNode(name: "M", kind: .mirror(body: body, plane: PlaneRef(source: .ground), keepOriginal: true), outputBodyIDs: [])
        let box = FeatureNode(name: "Box", kind: .primitive(spec: .box(width: 1, depth: 1, height: 1), placement: .identity), outputBodyIDs: [])
        for node in [fillet, delete, mirror, box] { vm.session.perform(AppendFeatureCommand(node: node)) }
        XCTAssertEqual(vm.referenceEditLabel(fillet.id), "Edit Edges")
        XCTAssertEqual(vm.referenceEditLabel(delete.id), "Edit Faces")
        XCTAssertEqual(vm.referenceEditLabel(mirror.id), "Edit Body")
        XCTAssertNil(vm.referenceEditLabel(box.id), "a primitive has no reference to re-pick")
        // Dangling body refs: the input cannot be replayed, so the edit refuses
        // with a message instead of arming a pick on nothing.
        XCTAssertFalse(vm.beginReferenceEdit(delete.id))
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.mode, .idle)
        XCTAssertFalse(vm.beginReferenceEdit(box.id))
    }
}
