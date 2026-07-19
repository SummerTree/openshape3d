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

        project.modifiedAt = Date()
        try? modelContext.save()
    }
}
