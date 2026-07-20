//
//  DocumentSession.swift
//  openshape3d
//
//  Owns the in-memory DesignDocument for one open project, routes commands
//  through the undo stack, and mirrors changes back to SwiftData with a
//  debounced autosave.
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class DocumentSession {
    let project: Project
    private let modelContext: ModelContext

    private(set) var document = DesignDocument()
    let undoStack = UndoStack()

    /// Topological-naming strategy used when replaying the feature graph
    /// (labels faces, propagates labels through booleans/push-pull, re-resolves
    /// persisted `FaceRef`s against rebuilt geometry). Phase D, Task C1.
    let naming: TopoNaming = SignatureNaming()

    /// Per-node errors from the most recent `rebuildFrom` evaluation, surfaced
    /// to the editor/history panel (broken-ref / empty-geometry / kernel-failure
    /// badges). Empty when the last rebuild was clean.
    private(set) var lastEvalErrors: [FeatureID: FeatureError] = [:]

    /// Bumped on every document mutation; the editor observes this to rebuild
    /// the viewport scene.
    private(set) var changeCount = 0

    private var saveTask: Task<Void, Never>?

    init(project: Project, modelContext: ModelContext) {
        self.project = project
        self.modelContext = modelContext
        load()
    }

    // MARK: - Mutations

    func perform(_ command: DocumentCommand) {
        undoStack.perform(command, on: &document)
        didChange()
    }

    /// Coalesce with the previous command (live drags, slider edits).
    func amend(_ command: DocumentCommand) {
        undoStack.amendLast(command, on: &document)
        didChange()
    }

    /// Transient (non-undoable) document update, e.g. live transform during a
    /// drag before the final command is pushed on gesture end.
    func preview(_ mutate: (inout DesignDocument) -> Void) {
        mutate(&document)
        didChange(autosave: false)
    }

    func undo() {
        undoStack.undo(on: &document)
        didChange()
    }

    func redo() {
        undoStack.redo(on: &document)
        didChange()
    }

    private func didChange(autosave: Bool = true) {
        changeCount += 1
        if autosave {
            scheduleAutosave()
        }
    }

    // MARK: - Feature graph (Phase D, Task C1)

    /// Record a new feature node in the history as its own undoable step.
    ///
    /// Recording/undo approach: the undoable primitive is `AppendFeatureCommand`.
    /// When a feature is born alongside geometry (a primitive box, a new-body
    /// extrude), the editor bundles `AppendFeatureCommand` into the SAME
    /// `CompositeCommand` as the geometry command (`AddBodyCommand`,
    /// `BooleanCommand`, …) and performs that — so one undo drops both the mesh
    /// and the node. `record(_:)` is the standalone convenience for a node that
    /// has no paired geometry command; routing it through `perform` keeps it
    /// undoable and never leaves an orphan node behind on undo.
    func record(_ node: FeatureNode) {
        perform(AppendFeatureCommand(node: node))
    }

    /// Re-evaluate the feature graph and commit the resulting mesh changes as a
    /// single undo step, optionally applying a pending parameter edit first.
    ///
    /// Flow: apply `edit` to a graph copy so `evaluate` sees the new parameters →
    /// replay → diff the produced bodies against the current feature-owned bodies
    /// → build `ReplaceBody` (changed) / `AddBody` (new) / `DeleteBodies`
    /// (consumed) commands → bundle them with `edit` into one
    /// `CompositeCommand("Edit Feature")` and `perform` it, so a single undo
    /// reverts BOTH the parameter change and every downstream mesh.
    ///
    /// Non-feature bodies (imported meshes, copies) are untouched — only IDs a
    /// node minted (`FeatureNode.outputBodyIDs`, reused across rebuilds) are
    /// diffed. User-owned metadata evaluate doesn't model (name, transform,
    /// visibility, material) is carried forward onto rebuilt bodies so a param
    /// edit doesn't clobber a rename / gizmo move / hide / material.
    ///
    /// The `id` names the edited node for callers/telemetry; the replay itself is
    /// whole-graph (tranche 1 has no partial/rollback replay). Any evaluation
    /// errors are stored in `lastEvalErrors`; the good bodies are still applied.
    func rebuildFrom(_ id: FeatureID, edit: EditFeatureCommand? = nil) {
        // Graph with the pending parameter edit applied, so replay sees the new
        // parameters without mutating the live document yet.
        var editedGraph = document.features
        if let edit, let index = editedGraph.index(of: edit.featureID) {
            editedGraph.nodes[index].kind = edit.after
        }
        let leading: [DocumentCommand] = edit.map { [$0] } ?? []
        performRebuild(editedGraph, leadingCommands: leading, title: "Edit Feature")
    }

    /// Suppress / un-suppress a node and rebuild everything downstream in one
    /// undo step (History panel eye toggle). No-op if the flag is unchanged.
    func setSuppressed(_ id: FeatureID, _ value: Bool) {
        guard let node = document.features.node(id), node.suppressed != value else { return }
        var edited = document.features
        if let index = edited.index(of: id) { edited.nodes[index].suppressed = value }
        let cmd = SetFeatureSuppressedCommand(featureID: id, before: node.suppressed, after: value)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Delete a node from the history and rebuild everything downstream in one
    /// undo step (History panel delete). The node's exclusively-owned bodies are
    /// removed; bodies still produced by surviving nodes are replaced.
    func deleteFeature(_ id: FeatureID) {
        guard let node = document.features.node(id),
              let index = document.features.index(of: id) else { return }
        var edited = document.features
        edited.nodes.removeAll { $0.id == id }
        let cmd = RemoveFeatureCommand(index: index, node: node)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Core of every graph-driven rebuild: replay `editedGraph`, diff the
    /// produced bodies against the current feature-owned bodies, and commit the
    /// mesh changes plus `leadingCommands` (the graph mutation itself) as ONE
    /// undoable `CompositeCommand`. Shared by `rebuildFrom`, `setSuppressed`, and
    /// `deleteFeature` so all three stay a single undo step.
    private func performRebuild(
        _ editedGraph: FeatureGraph, leadingCommands: [DocumentCommand], title: String
    ) {
        // Replay. `nextRevision` advances the REAL document counter so every
        // emitted revision is globally unique (added bodies keep theirs; replaced
        // bodies get a fresh one again in ReplaceBodyCommand.apply).
        let result = editedGraph.evaluate(
            sketches: document.sketches,
            planes: document.planes,
            naming: naming,
            nextRevision: { self.document.nextRevision() }
        )
        lastEvalErrors = result.errors

        // Every BodyID any node owns — the pre-edit graph too, so a node removed
        // in `editedGraph` still has its now-orphaned body diffed (and deleted).
        let ownedIDs = Set(document.features.nodes.flatMap(\.outputBodyIDs))
            .union(editedGraph.nodes.flatMap(\.outputBodyIDs))

        var resultByID: [BodyID: Body] = [:]
        for body in result.bodies { resultByID[body.id] = body }

        var currentOwned: [BodyID: Body] = [:]
        for body in document.bodies where ownedIDs.contains(body.id) {
            currentOwned[body.id] = body
        }

        var commands: [DocumentCommand] = leadingCommands

        // Replace bodies that still exist; add ones the graph newly produced.
        // Preserve user-owned metadata the replay doesn't carry.
        //
        // NOTE: the transform is intentionally NOT preserved. `evaluate()` emits
        // world-space meshes with an identity transform; carrying the live body's
        // pivot transform (extrude/boolean/push-pull store a localized mesh +
        // pivot translation) would double-offset the body by its pivot on every
        // rebuild. So a rebuilt feature body adopts the replay's identity
        // transform. Tranche-1 limitation: a post-creation gizmo MOVE on a
        // feature body is reset when you edit that feature's parameters —
        // transform-as-a-recorded-feature (which preserves moves through the
        // graph) is tranche 2.
        for body in result.bodies where ownedIDs.contains(body.id) {
            if let existing = currentOwned[body.id] {
                var after = body
                after.name = existing.name
                after.isHidden = existing.isHidden
                after.material = existing.material
                commands.append(ReplaceBodyCommand(title: title, before: existing, after: after))
            } else {
                commands.append(AddBodyCommand(body: body, title: title))
            }
        }

        // Feature-owned bodies the replay no longer produces were consumed
        // (e.g. a boolean tool) or belonged to a deleted node — remove them.
        let toDelete = Set(currentOwned.keys.filter { resultByID[$0] == nil })
        if !toDelete.isEmpty {
            commands.append(DeleteBodiesCommand(ids: toDelete, document: document))
        }

        guard !commands.isEmpty else { return }
        perform(CompositeCommand(title: title, commands: commands))
    }

    /// Convenience for the editor/VM: change a feature node's parameters and
    /// rebuild everything downstream in one undo step. Builds the
    /// `EditFeatureCommand` (capturing the current kind as `before`) and defers
    /// to `rebuildFrom`. No-op if the node is gone.
    func editFeature(_ id: FeatureID, to newKind: FeatureKind) {
        guard let node = document.features.node(id) else { return }
        let edit = EditFeatureCommand(featureID: id, before: node.kind, after: newKind)
        rebuildFrom(id, edit: edit)
    }

    // MARK: - Persistence

    private func load() {
        var loaded = DesignDocument()
        for persisted in project.bodies {
            guard let render = try? MeshBlob.decode(persisted.meshData),
                  let transform = try? JSONDecoder().decode(Transform3D.self, from: persisted.transformData)
            else { continue }
            let primitive = persisted.primitiveData.flatMap {
                try? JSONDecoder().decode(PrimitiveSpec.self, from: $0)
            }
            var body = Body(
                id: BodyID(raw: persisted.bodyID),
                name: persisted.name,
                transform: transform,
                primitive: primitive,
                render: render,
                revision: loaded.nextRevision()
            )
            body.isHidden = persisted.isHidden
            body.material = persisted.materialData.flatMap {
                try? JSONDecoder().decode(BodyMaterialSpec.self, from: $0)
            }
            loaded.bodies.append(body)
        }
        for persisted in project.sketches {
            if let sketch = try? JSONDecoder().decode(Sketch.self, from: persisted.sketchData) {
                loaded.sketches.append(sketch)
            }
        }
        for persisted in project.planes {
            if let plane = try? JSONDecoder().decode(ConstructionPlane.self, from: persisted.planeData) {
                loaded.planes.append(plane)
            }
        }
        for persisted in project.images {
            if var image = try? JSONDecoder().decode(InsertedImage.self, from: persisted.infoData) {
                image.imageData = persisted.imageData
                loaded.images.append(image)
            }
        }
        for persisted in project.symbols {
            if let symbol = try? JSONDecoder().decode(Symbol.self, from: persisted.symbolData) {
                loaded.symbols.append(symbol)
            }
        }
        // Phase D feature graph: replay order is `orderIndex` (SwiftData
        // relationships are unordered). A node whose kind blob won't decode is
        // skipped (decodeFeature -> nil), not fatal. Pre-Phase-D projects have no
        // PersistedFeature rows -> empty graph, and render from their baked
        // PersistedBody meshes until the first parametric edit.
        for persisted in project.features.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            if let node = decodeFeature(persisted) {
                loaded.features.nodes.append(node)
            }
        }
        document = loaded
        changeCount += 1
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil

        // Diff by ID against the persisted objects.
        var persistedByID = [UUID: PersistedBody]()
        for persisted in project.bodies {
            persistedByID[persisted.bodyID] = persisted
        }

        var liveIDs = Set<UUID>()
        for body in document.bodies {
            liveIDs.insert(body.id.raw)
            let transformData = (try? JSONEncoder().encode(body.transform)) ?? Data()
            let primitiveData = body.primitive.flatMap { try? JSONEncoder().encode($0) }
            let meshData = MeshBlob.encode(body.render)
            let materialData = body.material.flatMap { try? JSONEncoder().encode($0) }

            if let persisted = persistedByID[body.id.raw] {
                persisted.name = body.name
                persisted.transformData = transformData
                persisted.primitiveData = primitiveData
                persisted.meshData = meshData
                persisted.isHidden = body.isHidden
                persisted.materialData = materialData
            } else {
                let persisted = PersistedBody(
                    bodyID: body.id.raw,
                    name: body.name,
                    transformData: transformData,
                    primitiveData: primitiveData,
                    meshData: meshData
                )
                persisted.isHidden = body.isHidden
                persisted.materialData = materialData
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.bodies where !liveIDs.contains(persisted.bodyID) {
            modelContext.delete(persisted)
        }

        var persistedSketchByID = [UUID: PersistedSketch]()
        for persisted in project.sketches {
            persistedSketchByID[persisted.sketchID] = persisted
        }
        var liveSketchIDs = Set<UUID>()
        for sketch in document.sketches {
            liveSketchIDs.insert(sketch.id.raw)
            let data = (try? JSONEncoder().encode(sketch)) ?? Data()
            if let persisted = persistedSketchByID[sketch.id.raw] {
                persisted.sketchData = data
            } else {
                let persisted = PersistedSketch(sketchID: sketch.id.raw, sketchData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.sketches where !liveSketchIDs.contains(persisted.sketchID) {
            modelContext.delete(persisted)
        }

        var persistedPlaneByID = [UUID: PersistedPlane]()
        for persisted in project.planes {
            persistedPlaneByID[persisted.planeID] = persisted
        }
        var livePlaneIDs = Set<UUID>()
        for plane in document.planes {
            livePlaneIDs.insert(plane.id.raw)
            let data = (try? JSONEncoder().encode(plane)) ?? Data()
            if let persisted = persistedPlaneByID[plane.id.raw] {
                persisted.planeData = data
            } else {
                let persisted = PersistedPlane(planeID: plane.id.raw, planeData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.planes where !livePlaneIDs.contains(persisted.planeID) {
            modelContext.delete(persisted)
        }

        var persistedImageByID = [UUID: PersistedImage]()
        for persisted in project.images {
            persistedImageByID[persisted.imageID] = persisted
        }
        var liveImageIDs = Set<UUID>()
        for image in document.images {
            liveImageIDs.insert(image.id.raw)
            // Blob lives in the externalStorage column; strip it from the JSON.
            var info = image
            info.imageData = Data()
            let infoData = (try? JSONEncoder().encode(info)) ?? Data()
            if let persisted = persistedImageByID[image.id.raw] {
                persisted.infoData = infoData
                persisted.imageData = image.imageData
            } else {
                let persisted = PersistedImage(
                    imageID: image.id.raw, infoData: infoData, imageData: image.imageData
                )
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.images where !liveImageIDs.contains(persisted.imageID) {
            modelContext.delete(persisted)
        }

        var persistedSymbolByID = [UUID: PersistedSymbol]()
        for persisted in project.symbols {
            persistedSymbolByID[persisted.symbolID] = persisted
        }
        var liveSymbolIDs = Set<UUID>()
        for symbol in document.symbols {
            liveSymbolIDs.insert(symbol.id.raw)
            let data = (try? JSONEncoder().encode(symbol)) ?? Data()
            if let persisted = persistedSymbolByID[symbol.id.raw] {
                persisted.symbolData = data
            } else {
                let persisted = PersistedSymbol(symbolID: symbol.id.raw, symbolData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.symbols where !liveSymbolIDs.contains(persisted.symbolID) {
            modelContext.delete(persisted)
        }

        // Phase D feature graph: diff by featureID, mirroring the PersistedBody
        // block. `orderIndex` is the node's array position so replay order
        // survives the round-trip; kind/outputBodyIDs go through the A4 helpers.
        var persistedFeatureByID = [UUID: PersistedFeature]()
        for persisted in project.features {
            persistedFeatureByID[persisted.featureID] = persisted
        }
        var liveFeatureIDs = Set<UUID>()
        for (index, node) in document.features.nodes.enumerated() {
            liveFeatureIDs.insert(node.id.raw)
            let kindData = encodeFeatureKind(node.kind)
            let outputBodyIDData = encodeBodyIDs(node.outputBodyIDs)
            if let persisted = persistedFeatureByID[node.id.raw] {
                persisted.orderIndex = index
                persisted.name = node.name
                persisted.suppressed = node.suppressed
                persisted.kindData = kindData
                persisted.outputBodyIDData = outputBodyIDData
            } else {
                let persisted = encodeFeature(node, orderIndex: index)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.features where !liveFeatureIDs.contains(persisted.featureID) {
            modelContext.delete(persisted)
        }

        project.modifiedAt = Date()
        try? modelContext.save()
    }
}
