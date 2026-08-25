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

    /// Phase D feature graph. Defaulted so pre-Phase-D stores migrate: an old
    /// project loads with an empty graph and renders from its baked
    /// `PersistedBody` meshes until the first parametric edit.
    @Relationship(deleteRule: .cascade, inverse: \PersistedFeature.project)
    var features: [PersistedFeature] = []

    /// Phase D parametric variables. Defaulted so pre-Phase-D stores migrate: an
    /// old project loads with no variables.
    @Relationship(deleteRule: .cascade, inverse: \PersistedVariable.project)
    var variables: [PersistedVariable] = []

    /// Phase D (Tranche 5) feature-graph rollback marker: the number of ACTIVE
    /// (leading) feature nodes. `nil` means all nodes are active (no rollback).
    /// A scalar column, defaulted so pre-Tranche-5 stores migrate without a
    /// `VersionedSchema` (repo convention) — an old project loads with
    /// `rollbackIndex == nil`. Load/save wiring into/out of
    /// `document.features.rollbackIndex` lives in task B1.
    var rollbackIndex: Int? = nil

    /// Store format version, bumped ONLY on a non-additive change to any
    /// persisted payload (the JSON kind/sketch blobs, `MeshBlob`, the brep
    /// blob). Defaulted so every pre-versioning store reads as v1 (repo
    /// convention). A store whose version is NEWER than this build's
    /// `Project.currentFormatVersion` opens for viewing but `save()` refuses
    /// to touch it — an older app must never rewrite (or diff-delete) rows it
    /// can't fully decode. 2026-08-25 review, finding C2.
    var formatVersion: Int = 1

    /// The newest store format this build reads AND writes.
    static let currentFormatVersion = 1

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
    /// OCCT BRep blob for bodies built through the B-rep path, so analytic
    /// geometry (round cylinders, boolean composability) survives a reload.
    /// Nil for Euclid-only bodies and every pre-OCCT store — those keep the
    /// persisted render mesh exactly as before.
    @Attribute(.externalStorage) var brepData: Data?
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

/// One node of the Phase D feature graph (`FeatureNode`), persisted.
///
/// All properties are defaulted so pre-Phase-D stores migrate without a
/// `VersionedSchema` (repo convention). `kindData` is the JSON-encoded
/// `FeatureKind` and `outputBodyIDData` the JSON-encoded `[BodyID]`; both are
/// produced/consumed by `encodeFeature`/`decodeFeature` below. `orderIndex`
/// records the node's position in `FeatureGraph.nodes` so replay order survives
/// a store round-trip (SwiftData relationships are unordered).
@Model
final class PersistedFeature {
    @Attribute(.unique) var featureID: UUID = UUID()
    var orderIndex: Int = 0
    var name: String = "Feature"
    var suppressed: Bool = false
    /// JSON-encoded `FeatureKind`.
    @Attribute(.externalStorage) var kindData: Data = Data()
    /// JSON-encoded `[BodyID]` (the node's minted-once output body IDs).
    var outputBodyIDData: Data = Data()
    var project: Project?

    init(featureID: UUID,
         orderIndex: Int,
         name: String,
         suppressed: Bool,
         kindData: Data,
         outputBodyIDData: Data) {
        self.featureID = featureID
        self.orderIndex = orderIndex
        self.name = name
        self.suppressed = suppressed
        self.kindData = kindData
        self.outputBodyIDData = outputBodyIDData
    }
}

/// One Phase D parametric `Variable`, persisted.
///
/// All properties are defaulted so pre-Phase-D stores migrate without a
/// `VersionedSchema` (repo convention). Columns map directly to `Variable`'s
/// fields (no JSON blob needed); `orderIndex` records the variable's position in
/// `DesignDocument.variables` so creation order — which drives resolution —
/// survives a store round-trip (SwiftData relationships are unordered).
@Model
final class PersistedVariable {
    @Attribute(.unique) var variableID: UUID = UUID()
    var orderIndex: Int = 0
    var name: String = ""
    var expression: String = ""
    var value: Double = 0
    var project: Project?

    init(variableID: UUID,
         orderIndex: Int,
         name: String,
         expression: String,
         value: Double) {
        self.variableID = variableID
        self.orderIndex = orderIndex
        self.name = name
        self.expression = expression
        self.value = value
    }
}

// MARK: - Variable encode/decode helpers
//
// Free functions bridging `Variable` (A1 model) <-> `PersistedVariable`. Called
// by `DocumentSession.save`/`load` (wired in task B1). Per-column, no JSON blob:
// id/name/expression/value map directly. Context insertion + `project` wiring are
// the caller's job (mirrors `DocumentSession.save`'s PersistedFeature path).

/// Build a fresh `PersistedVariable` from a `Variable`. `orderIndex` is the
/// variable's position in `DesignDocument.variables`.
func encodeVariable(_ v: Variable, orderIndex: Int) -> PersistedVariable {
    PersistedVariable(
        variableID: v.id.raw,
        orderIndex: orderIndex,
        name: v.name,
        expression: v.expression,
        value: v.value
    )
}

/// Rebuild a `Variable` from a persisted row.
func decodeVariable(_ pv: PersistedVariable) -> Variable {
    Variable(
        id: VariableID(raw: pv.variableID),
        name: pv.name,
        expression: pv.expression,
        value: pv.value
    )
}

// MARK: - Feature encode/decode helpers
//
// Free functions bridging `FeatureNode` (B1 graph model) <-> `PersistedFeature`.
// Called by `DocumentSession.save`/`load` (wired in a later step). The pure JSON
// helpers are `nonisolated` so they can be exercised off the main actor and unit
// tested without touching SwiftData.

/// JSON-encode a `FeatureKind`; `Data()` on failure (empty decodes back to nil).
nonisolated func encodeFeatureKind(_ kind: FeatureKind) -> Data {
    (try? JSONEncoder().encode(kind)) ?? Data()
}

/// JSON-decode a `FeatureKind`; nil if the blob is empty/corrupt.
nonisolated func decodeFeatureKind(_ data: Data) -> FeatureKind? {
    try? JSONDecoder().decode(FeatureKind.self, from: data)
}

/// JSON-encode a node's `[BodyID]`; `Data()` on failure.
nonisolated func encodeBodyIDs(_ ids: [BodyID]) -> Data {
    (try? JSONEncoder().encode(ids)) ?? Data()
}

/// JSON-decode `[BodyID]`; nil if the blob is empty/corrupt (caller uses `?? []`).
nonisolated func decodeBodyIDs(_ data: Data) -> [BodyID]? {
    try? JSONDecoder().decode([BodyID].self, from: data)
}

/// Build a fresh `PersistedFeature` from a graph node. `orderIndex` is the node's
/// position in `FeatureGraph.nodes`. Context insertion + `project` wiring are the
/// caller's job (mirrors `DocumentSession.save`'s PersistedBody path).
func encodeFeature(_ node: FeatureNode, orderIndex: Int) -> PersistedFeature {
    PersistedFeature(
        featureID: node.id.raw,
        orderIndex: orderIndex,
        name: node.name,
        suppressed: node.suppressed,
        kindData: encodeFeatureKind(node.kind),
        outputBodyIDData: encodeBodyIDs(node.outputBodyIDs)
    )
}

/// Rebuild a `FeatureNode` from a persisted row; nil if the kind blob won't
/// decode (a broken/forward-incompatible node is skipped rather than crashing).
func decodeFeature(_ pf: PersistedFeature) -> FeatureNode? {
    guard let kind = decodeFeatureKind(pf.kindData) else { return nil }
    return FeatureNode(
        id: FeatureID(raw: pf.featureID),
        name: pf.name,
        kind: kind,
        suppressed: pf.suppressed,
        outputBodyIDs: decodeBodyIDs(pf.outputBodyIDData) ?? []
    )
}
