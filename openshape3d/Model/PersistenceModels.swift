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

    @Relationship(deleteRule: .cascade, inverse: \PersistedPlane.project)
    var planes: [PersistedPlane] = []

    @Relationship(deleteRule: .cascade, inverse: \PersistedImage.project)
    var images: [PersistedImage] = []

    @Relationship(deleteRule: .cascade, inverse: \PersistedSymbol.project)
    var symbols: [PersistedSymbol] = []

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
    /// Items Manager visibility (spec §11). Defaulted so pre-A8 stores migrate.
    var isHidden: Bool = false
    /// JSON-encoded BodyMaterialSpec (plan §B15); nil (pre-B15 stores) keeps
    /// the legacy default look.
    var materialData: Data?
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

@Model
final class PersistedImage {
    @Attribute(.unique) var imageID: UUID = UUID()
    /// JSON-encoded InsertedImage with the picture blob stripped (tiny);
    /// reassembled with `imageData` on load.
    var infoData: Data = Data()
    /// Original PNG/JPEG bytes exactly as picked.
    @Attribute(.externalStorage) var imageData: Data = Data()
    var project: Project?

    init(imageID: UUID, infoData: Data, imageData: Data) {
        self.imageID = imageID
        self.infoData = infoData
        self.imageData = imageData
    }
}

@Model
final class PersistedSymbol {
    @Attribute(.unique) var symbolID: UUID = UUID()
    /// JSON-encoded Symbol (entities in symbol-local coordinates).
    @Attribute(.externalStorage) var symbolData: Data = Data()
    var project: Project?

    init(symbolID: UUID, symbolData: Data) {
        self.symbolID = symbolID
        self.symbolData = symbolData
    }
}

@Model
final class PersistedPlane {
    @Attribute(.unique) var planeID: UUID = UUID()
    /// JSON-encoded ConstructionPlane (tiny).
    var planeData: Data = Data()
    var project: Project?

    init(planeID: UUID, planeData: Data) {
        self.planeID = planeID
        self.planeData = planeData
    }
}
