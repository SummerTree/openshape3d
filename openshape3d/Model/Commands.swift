//
//  Commands.swift
//  openshape3d
//
//  Undoable document mutations. Payloads are value snapshots — cheap because
//  mesh storage is copy-on-write.
//

import Foundation

protocol DocumentCommand {
    var title: String { get }
    func apply(to document: inout DesignDocument)
    func revert(in document: inout DesignDocument)
}

struct AddBodyCommand: DocumentCommand {
    let title: String
    let body: Body

    init(body: Body, title: String? = nil) {
        self.body = body
        self.title = title ?? "Add \(body.name)"
    }

    func apply(to document: inout DesignDocument) {
        document.bodies.append(body)
    }

    func revert(in document: inout DesignDocument) {
        document.bodies.removeAll { $0.id == body.id }
    }
}

struct DeleteBodiesCommand: DocumentCommand {
    let title = "Delete"
    /// Snapshots with original array indices so undo restores ordering.
    let removed: [(index: Int, body: Body)]

    init(ids: Set<BodyID>, document: DesignDocument) {
        removed = document.bodies.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { (index: $0.offset, body: $0.element) }
    }

    func apply(to document: inout DesignDocument) {
        let ids = Set(removed.map(\.body.id))
        document.bodies.removeAll { ids.contains($0.id) }
    }

    func revert(in document: inout DesignDocument) {
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            let index = min(entry.index, document.bodies.count)
            document.bodies.insert(entry.body, at: index)
        }
    }
}

struct TransformBodiesCommand: DocumentCommand {
    let title = "Move"
    let before: [BodyID: Transform3D]
    var after: [BodyID: Transform3D]

    func apply(to document: inout DesignDocument) {
        for (id, transform) in after {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].transform = transform
            }
        }
    }

    func revert(in document: inout DesignDocument) {
        for (id, transform) in before {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].transform = transform
            }
        }
    }
}

/// Swap a body's geometry/transform for a new version (face extrude,
/// push/pull results). Value snapshots both ways.
struct ReplaceBodyCommand: DocumentCommand {
    let title: String
    let before: Body
    let after: Body

    func apply(to document: inout DesignDocument) {
        if let index = document.bodyIndex(of: before.id) {
            var updated = after
            updated.meshRevision = document.nextRevision()
            document.bodies[index] = updated
        }
    }

    func revert(in document: inout DesignDocument) {
        if let index = document.bodyIndex(of: before.id) {
            var restored = before
            restored.meshRevision = document.nextRevision()
            document.bodies[index] = restored
        }
    }
}

/// Replace the target body's geometry with the boolean result and consume the
/// tool body. Both originals are snapshotted for undo.
struct BooleanCommand: DocumentCommand {
    let title: String
    let targetBefore: Body
    let toolIndex: Int
    let toolBefore: Body
    /// Result body — same ID as the target, world-space mesh, identity transform.
    let result: Body

    init(kind: BooleanKind, targetBefore: Body, toolIndex: Int, toolBefore: Body, result: Body) {
        self.title = kind.rawValue.capitalized
        self.targetBefore = targetBefore
        self.toolIndex = toolIndex
        self.toolBefore = toolBefore
        self.result = result
    }

    func apply(to document: inout DesignDocument) {
        if let index = document.bodyIndex(of: targetBefore.id) {
            var updated = result
            updated.meshRevision = document.nextRevision()
            document.bodies[index] = updated
        }
        document.bodies.removeAll { $0.id == toolBefore.id }
    }

    func revert(in document: inout DesignDocument) {
        if let index = document.bodyIndex(of: targetBefore.id) {
            var restored = targetBefore
            restored.meshRevision = document.nextRevision()
            document.bodies[index] = restored
        }
        let index = min(toolIndex, document.bodies.count)
        var restoredTool = toolBefore
        restoredTool.meshRevision = document.nextRevision()
        document.bodies.insert(restoredTool, at: index)
    }
}

struct AddSketchEntityCommand: DocumentCommand {
    let title = "Sketch"
    let sketchID: SketchID
    let entity: SketchEntity

    func apply(to document: inout DesignDocument) {
        if let index = document.sketches.firstIndex(where: { $0.id == sketchID }) {
            document.sketches[index].entities.append(entity)
        }
    }

    func revert(in document: inout DesignDocument) {
        if let index = document.sketches.firstIndex(where: { $0.id == sketchID }) {
            document.sketches[index].entities.removeAll { $0.id == entity.id }
        }
    }
}

struct ResizePrimitiveCommand: DocumentCommand {
    let title: String
    let bodyID: BodyID
    let beforeSpec: PrimitiveSpec
    let afterSpec: PrimitiveSpec

    init(bodyID: BodyID, beforeSpec: PrimitiveSpec, afterSpec: PrimitiveSpec) {
        self.bodyID = bodyID
        self.beforeSpec = beforeSpec
        self.afterSpec = afterSpec
        self.title = "Edit \(afterSpec.displayName)"
    }

    private func rebuild(_ document: inout DesignDocument, spec: PrimitiveSpec) {
        guard let index = document.bodyIndex(of: bodyID) else { return }
        let old = document.bodies[index]
        var rebuilt = Body(
            id: old.id,
            name: old.name,
            transform: old.transform,
            primitive: spec,
            euclidMesh: .primitive(spec),
            revision: document.nextRevision()
        )
        rebuilt.name = old.name
        document.bodies[index] = rebuilt
    }

    func apply(to document: inout DesignDocument) {
        rebuild(&document, spec: afterSpec)
    }

    func revert(in document: inout DesignDocument) {
        rebuild(&document, spec: beforeSpec)
    }
}
