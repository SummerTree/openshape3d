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
    /// Undo title: the tool that produced the transform ("Move" default;
    /// Scale/Rotate/Translate/Align pass their own).
    var title: String = "Move"
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

/// Groups several commands into one undo step (e.g. a cut that subtracts
/// from every intersected body commits one ReplaceBodyCommand per body).
struct CompositeCommand: DocumentCommand {
    let title: String
    let commands: [DocumentCommand]

    func apply(to document: inout DesignDocument) {
        for command in commands {
            command.apply(to: &document)
        }
    }

    func revert(in document: inout DesignDocument) {
        for command in commands.reversed() {
            command.revert(in: &document)
        }
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

/// Bulk entity insertion in one undo step (Text glyph outlines, projected
/// body edges); optionally arrives flagged as construction geometry.
struct AddSketchEntitiesCommand: DocumentCommand {
    let title: String
    let sketchID: SketchID
    let entities: [SketchEntity]
    let asConstruction: Bool

    init(
        sketchID: SketchID, entities: [SketchEntity],
        title: String = "Sketch", asConstruction: Bool = false
    ) {
        self.sketchID = sketchID
        self.entities = entities
        self.title = title
        self.asConstruction = asConstruction
    }

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].entities.append(contentsOf: entities)
        if asConstruction {
            document.sketches[index].setConstruction(true, forEntityIDs: entities.map(\.id))
        }
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let ids = Set(entities.map(\.id))
        document.sketches[index].entities.removeAll { ids.contains($0.id) }
        if asConstruction {
            document.sketches[index].setConstruction(false, forEntityIDs: ids)
        }
    }
}

/// Make Construction / Make Regular (spec §3.3): flips the construction flag
/// on a batch of sketch entities. Only IDs whose flag actually changes are
/// stored, so revert restores exactly the prior state.
struct SetConstructionCommand: DocumentCommand {
    let title: String
    let sketchID: SketchID
    let isConstruction: Bool
    let changedIDs: Set<UUID>

    init(sketchID: SketchID, entityIDs: Set<UUID>, isConstruction: Bool, sketch: Sketch) {
        self.sketchID = sketchID
        self.isConstruction = isConstruction
        self.changedIDs = entityIDs.filter { sketch.isConstruction($0) != isConstruction }
        self.title = isConstruction ? "Make Construction" : "Make Regular"
    }

    private func set(_ flag: Bool, in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].setConstruction(flag, forEntityIDs: changedIDs)
    }

    func apply(to document: inout DesignDocument) {
        set(isConstruction, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        set(!isConstruction, in: &document)
    }
}

/// Add a symbolic geometric constraint to a sketch (plan §C3). Applied
/// together with any solver-moved entity updates inside a `CompositeCommand`,
/// so one undo removes the constraint AND restores the pre-solve geometry.
struct AddSketchConstraintCommand: DocumentCommand {
    let title = "Constraint"
    let sketchID: SketchID
    let constraint: SketchConstraint

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].constraints.append(constraint)
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].constraints.removeAll { $0.id == constraint.id }
    }
}

/// Add a driving dimension to a sketch (plan §C2). Like a constraint, it is
/// applied together with any solver-moved entity updates in a
/// `CompositeCommand`, so one undo removes the dimension AND restores the
/// pre-solve geometry.
struct AddSketchDimensionCommand: DocumentCommand {
    let title = "Dimension"
    let sketchID: SketchID
    let dimension: SketchDimension

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].dimensions.append(dimension)
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].dimensions.removeAll { $0.id == dimension.id }
    }
}

/// Change a driving dimension's value (plan §C2). Paired with the solver-moved
/// entity updates in a `CompositeCommand` so editing a label is one undo step.
struct UpdateSketchDimensionCommand: DocumentCommand {
    let title = "Edit Dimension"
    let sketchID: SketchID
    let before: SketchDimension
    let after: SketchDimension

    private func replace(_ dimension: SketchDimension, in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }),
              let dimIndex = document.sketches[sketchIndex].dimensions.firstIndex(where: {
                  $0.id == dimension.id
              })
        else { return }
        document.sketches[sketchIndex].dimensions[dimIndex] = dimension
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

/// Remove a symbolic constraint from a sketch (plan §C, constraint delete).
/// Undo re-appends it at its original position so the relationship (and any
/// re-solve it drove) is restored exactly.
struct RemoveSketchConstraintCommand: DocumentCommand {
    let title = "Delete Constraint"
    let sketchID: SketchID
    let constraint: SketchConstraint
    /// Original index so undo restores ordering.
    let index: Int

    func apply(to document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[s].constraints.removeAll { $0.id == constraint.id }
    }

    func revert(in document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let clamped = min(max(index, 0), document.sketches[s].constraints.count)
        document.sketches[s].constraints.insert(constraint, at: clamped)
    }
}

/// Remove a driving dimension from a sketch (plan §C2). Undo re-appends it at
/// its original position.
struct RemoveSketchDimensionCommand: DocumentCommand {
    let title = "Delete Dimension"
    let sketchID: SketchID
    let dimension: SketchDimension
    let index: Int

    func apply(to document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[s].dimensions.removeAll { $0.id == dimension.id }
    }

    func revert(in document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let clamped = min(max(index, 0), document.sketches[s].dimensions.count)
        document.sketches[s].dimensions.insert(dimension, at: clamped)
    }
}

/// Drag-edit of a sketch entity (endpoint/center/body moves). Coalesced with
/// `session.amend` during the drag, like TransformBodiesCommand.
struct UpdateSketchEntityCommand: DocumentCommand {
    let title = "Move"
    let sketchID: SketchID
    let before: SketchEntity
    let after: SketchEntity

    private func replace(_ entity: SketchEntity, in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }),
              let entityIndex = document.sketches[sketchIndex].entities.firstIndex(where: {
                  $0.id == entity.id
              })
        else { return }
        document.sketches[sketchIndex].entities[entityIndex] = entity
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

/// Solve-on-edit multi-entity update (plan §C1): a constraint solve during a
/// drag moves several entities at once. `before`/`after` are full snapshots
/// keyed by ID and applied ABSOLUTELY (set-by-ID, not delta), so the command
/// amend-coalesces cleanly across drag frames — every frame re-applies the
/// complete solved state, leaving no stale intermediate positions behind.
struct UpdateSketchEntitiesCommand: DocumentCommand {
    let title = "Move"
    let sketchID: SketchID
    let before: [SketchEntity]
    let after: [SketchEntity]

    private func replace(_ entities: [SketchEntity], in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID })
        else { return }
        var byID = [UUID: SketchEntity](minimumCapacity: entities.count)
        for entity in entities { byID[entity.id] = entity }
        for i in document.sketches[sketchIndex].entities.indices {
            if let replacement = byID[document.sketches[sketchIndex].entities[i].id] {
                document.sketches[sketchIndex].entities[i] = replacement
            }
        }
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

struct RemoveSketchEntitiesCommand: DocumentCommand {
    let title = "Delete"
    let sketchID: SketchID
    /// Snapshots with original array indices so undo restores ordering.
    let removed: [(index: Int, entity: SketchEntity)]

    init(ids: Set<UUID>, sketch: Sketch) {
        sketchID = sketch.id
        removed = sketch.entities.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { (index: $0.offset, entity: $0.element) }
    }

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let ids = Set(removed.map(\.entity.id))
        document.sketches[index].entities.removeAll { ids.contains($0.id) }
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            let at = min(entry.index, document.sketches[index].entities.count)
            document.sketches[index].entities.insert(entry.entity, at: at)
        }
    }
}

/// Trim: replace one entity with the fragments left after deleting a span
/// (may be empty — the whole entity goes away).
struct TrimCommand: DocumentCommand {
    let title = "Trim"
    let sketchID: SketchID
    let index: Int
    let removed: SketchEntity
    let fragments: [SketchEntity]

    func apply(to document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[sketchIndex].entities.removeAll { $0.id == removed.id }
        let at = min(index, document.sketches[sketchIndex].entities.count)
        document.sketches[sketchIndex].entities.insert(contentsOf: fragments, at: at)
    }

    func revert(in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let ids = Set(fragments.map(\.id))
        document.sketches[sketchIndex].entities.removeAll { ids.contains($0.id) }
        let at = min(index, document.sketches[sketchIndex].entities.count)
        document.sketches[sketchIndex].entities.insert(removed, at: at)
    }
}

// MARK: - Items Manager (spec §11)

/// A row in the Items Manager: any document item addressable by ID.
enum DocumentItemRef: Hashable {
    case body(BodyID)
    case sketch(SketchID)
    case plane(ConstructionPlaneID)
}

struct SetItemVisibilityCommand: DocumentCommand {
    let title: String
    /// Body/sketch/plane target; nil when the target is an inserted image.
    let item: DocumentItemRef?
    /// Inserted-image target (plan §B10). Images sit outside DocumentItemRef
    /// so the exhaustive switches over it across the app stay untouched.
    let imageID: InsertedImageID?
    let isHidden: Bool

    init(item: DocumentItemRef, isHidden: Bool) {
        self.item = item
        self.imageID = nil
        self.isHidden = isHidden
        self.title = isHidden ? "Hide" : "Show"
    }

    init(imageID: InsertedImageID, isHidden: Bool) {
        self.item = nil
        self.imageID = imageID
        self.isHidden = isHidden
        self.title = isHidden ? "Hide" : "Show"
    }

    private func setHidden(_ hidden: Bool, in document: inout DesignDocument) {
        if let imageID, let index = document.imageIndex(of: imageID) {
            document.images[index].isHidden = hidden
        }
        guard let item else { return }
        switch item {
        case .body(let id):
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].isHidden = hidden
            }
        case .sketch(let id):
            if let index = document.sketches.firstIndex(where: { $0.id == id }) {
                document.sketches[index].isHidden = hidden
            }
        case .plane(let id):
            if let index = document.planes.firstIndex(where: { $0.id == id }) {
                document.planes[index].isHidden = hidden
            }
        }
    }

    func apply(to document: inout DesignDocument) {
        setHidden(isHidden, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        setHidden(!isHidden, in: &document)
    }
}

struct RenameItemCommand: DocumentCommand {
    let title = "Rename"
    /// Body/sketch/plane target; nil when the target is an inserted image.
    let item: DocumentItemRef?
    /// Inserted-image target (plan §B10), mirroring SetItemVisibilityCommand.
    let imageID: InsertedImageID?
    let before: String
    let after: String

    init(item: DocumentItemRef, before: String, after: String) {
        self.item = item
        self.imageID = nil
        self.before = before
        self.after = after
    }

    init(imageID: InsertedImageID, before: String, after: String) {
        self.item = nil
        self.imageID = imageID
        self.before = before
        self.after = after
    }

    private func setName(_ name: String, in document: inout DesignDocument) {
        if let imageID, let index = document.imageIndex(of: imageID) {
            document.images[index].name = name
        }
        guard let item else { return }
        switch item {
        case .body(let id):
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].name = name
            }
        case .sketch(let id):
            if let index = document.sketches.firstIndex(where: { $0.id == id }) {
                document.sketches[index].name = name
            }
        case .plane:
            break // planes are unnamed in v1
        }
    }

    func apply(to document: inout DesignDocument) {
        setName(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        setName(before, in: &document)
    }
}

/// DXF import (plan §B14): creates the target sketch when no ground-plane
/// sketch exists yet, composed with AddSketchEntitiesCommand in one
/// CompositeCommand so the whole import is a single undo step.
struct AddSketchCommand: DocumentCommand {
    let title: String
    let sketch: Sketch

    init(sketch: Sketch, title: String = "Add Sketch") {
        self.sketch = sketch
        self.title = title
    }

    func apply(to document: inout DesignDocument) {
        document.sketches.append(sketch)
    }

    func revert(in document: inout DesignDocument) {
        document.sketches.removeAll { $0.id == sketch.id }
    }
}

struct DeleteSketchCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let sketch: Sketch

    init?(id: SketchID, document: DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == id }) else { return nil }
        self.index = index
        self.sketch = document.sketches[index]
    }

    func apply(to document: inout DesignDocument) {
        document.sketches.removeAll { $0.id == sketch.id }
    }

    func revert(in document: inout DesignDocument) {
        document.sketches.insert(sketch, at: min(index, document.sketches.count))
    }
}

struct DeletePlaneCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let plane: ConstructionPlane

    init?(id: ConstructionPlaneID, document: DesignDocument) {
        guard let index = document.planes.firstIndex(where: { $0.id == id }) else { return nil }
        self.index = index
        self.plane = document.planes[index]
    }

    func apply(to document: inout DesignDocument) {
        document.planes.removeAll { $0.id == plane.id }
    }

    func revert(in document: inout DesignDocument) {
        document.planes.insert(plane, at: min(index, document.planes.count))
    }
}

struct AddConstructionPlaneCommand: DocumentCommand {
    let title = "Offset Plane"
    let plane: ConstructionPlane

    func apply(to document: inout DesignDocument) {
        document.planes.append(plane)
    }

    func revert(in document: inout DesignDocument) {
        document.planes.removeAll { $0.id == plane.id }
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

// MARK: - Materials (plan §B15)

/// Assigns one material to a set of bodies (Material sheet Apply). Per-body
/// before-snapshots restore mixed prior materials on undo.
struct SetMaterialCommand: DocumentCommand {
    let title = "Material"
    /// Prior material per body (nil value = legacy default look).
    let before: [BodyID: BodyMaterialSpec?]
    /// The material applied to every targeted body.
    let after: BodyMaterialSpec?

    init(bodyIDs: Set<BodyID>, material: BodyMaterialSpec?, document: DesignDocument) {
        var snapshots: [BodyID: BodyMaterialSpec?] = [:]
        for body in document.bodies where bodyIDs.contains(body.id) {
            snapshots[body.id] = body.material
        }
        self.before = snapshots
        self.after = material
    }

    func apply(to document: inout DesignDocument) {
        for id in before.keys {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].material = after
            }
        }
    }

    func revert(in document: inout DesignDocument) {
        for (id, material) in before {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].material = material
            }
        }
    }
}

// MARK: - Inserted images (plan §B10)

struct AddImageCommand: DocumentCommand {
    let title = "Insert Image"
    let image: InsertedImage

    func apply(to document: inout DesignDocument) {
        document.images.append(image)
    }

    func revert(in document: inout DesignDocument) {
        document.images.removeAll { $0.id == image.id }
    }
}

/// Gizmo move/resize and opacity-slider edits. Full value snapshots both ways
/// so `session.amend` coalesces a live drag into one undo step (same pattern
/// as UpdateSketchEntityCommand).
struct UpdateImageCommand: DocumentCommand {
    let title: String
    let before: InsertedImage
    let after: InsertedImage

    init(before: InsertedImage, after: InsertedImage, title: String = "Edit Image") {
        self.before = before
        self.after = after
        self.title = title
    }

    private func replace(_ image: InsertedImage, in document: inout DesignDocument) {
        if let index = document.imageIndex(of: before.id) {
            document.images[index] = image
        }
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

struct RemoveImageCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let image: InsertedImage

    init?(id: InsertedImageID, document: DesignDocument) {
        guard let index = document.imageIndex(of: id) else { return nil }
        self.index = index
        self.image = document.images[index]
    }

    func apply(to document: inout DesignDocument) {
        document.images.removeAll { $0.id == image.id }
    }

    func revert(in document: inout DesignDocument) {
        document.images.insert(image, at: min(index, document.images.count))
    }
}

// MARK: - Symbols (plan §B16, spec §1.16)

struct AddSymbolCommand: DocumentCommand {
    let title = "Create Symbol"
    let symbol: Symbol

    func apply(to document: inout DesignDocument) {
        document.symbols.append(symbol)
    }

    func revert(in document: inout DesignDocument) {
        document.symbols.removeAll { $0.id == symbol.id }
    }
}

struct RenameSymbolCommand: DocumentCommand {
    let title = "Rename"
    let symbolID: SymbolID
    let before: String
    let after: String

    init?(id: SymbolID, to name: String, document: DesignDocument) {
        guard let symbol = document.symbols.first(where: { $0.id == id }) else { return nil }
        self.symbolID = id
        self.before = symbol.name
        self.after = name
    }

    private func setName(_ name: String, in document: inout DesignDocument) {
        guard let index = document.symbols.firstIndex(where: { $0.id == symbolID }) else { return }
        document.symbols[index].name = name
    }

    func apply(to document: inout DesignDocument) {
        setName(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        setName(before, in: &document)
    }
}

struct RemoveSymbolCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let symbol: Symbol

    init?(id: SymbolID, document: DesignDocument) {
        guard let index = document.symbols.firstIndex(where: { $0.id == id }) else { return nil }
        self.index = index
        self.symbol = document.symbols[index]
    }

    func apply(to document: inout DesignDocument) {
        document.symbols.removeAll { $0.id == symbol.id }
    }

    func revert(in document: inout DesignDocument) {
        document.symbols.insert(symbol, at: min(index, document.symbols.count))
    }
}
