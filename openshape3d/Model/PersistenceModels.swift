//
//  PersistenceModels.swift
//  openshape3d
//

import Foundation
import SwiftData

@Model
final class Project {
    var name: String = "Untitled"
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    @Attribute(.externalStorage) var thumbnail: Data?

    @Relationship(deleteRule: .cascade, inverse: \PersistedBody.project)
    var bodies: [PersistedBody] = []

    @Relationship(deleteRule: .cascade, inverse: \PersistedSketch.project)
    var sketches: [PersistedSketch] = []

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}

@Model
final class PersistedBody {
    @Attribute(.unique) var bodyID: UUID = UUID()
    var name: String = "Body"
    /// JSON-encoded Transform3D (tiny).
    var transformData: Data = Data()
    /// JSON-encoded PrimitiveSpec, nil once the body is baked (extruded/booleaned).
    var primitiveData: Data?
    /// Compact binary mesh blob ("OS3D" format) — exactly the RenderMesh buffers.
    @Attribute(.externalStorage) var meshData: Data = Data()
    var project: Project?

    init(bodyID: UUID, name: String, transformData: Data, primitiveData: Data?, meshData: Data) {
        self.bodyID = bodyID
        self.name = name
        self.transformData = transformData
        self.primitiveData = primitiveData
        self.meshData = meshData
    }
}

@Model
final class PersistedSketch {
    @Attribute(.unique) var sketchID: UUID = UUID()
    /// JSON-encoded Sketch (plane + entities, tiny).
    @Attribute(.externalStorage) var sketchData: Data = Data()
    var project: Project?

    init(sketchID: UUID, sketchData: Data) {
        self.sketchID = sketchID
        self.sketchData = sketchData
    }
}
