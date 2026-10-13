//
//  EditorClipboard.swift
//  openshape3d
//
//  Edit ▸ Cut / Copy / Paste: the app's own clipboard. It holds bodies, or —
//  while sketching — sketch entities, and lives as long as the app does, so
//  a part copied in one design pastes into another. Bodies keep their exact
//  solid (the B-rep handle is shared read-only, as the Copy badge does).
//

import Foundation

@MainActor
enum EditorClipboard {
    enum Content {
        case bodies([Body])
        case sketchEntities([SketchEntity])
    }

    static var content: Content?
}

extension EditorViewModel {

    var canCopySelection: Bool {
        if mode.isSketching { return !selectedSketchEntityIDs.isEmpty }
        return !selection.isEmpty
    }

    /// Paste needs what's on the clipboard to fit where you are: bodies in
    /// the model, sketch geometry inside a sketch.
    var canPaste: Bool {
        switch EditorClipboard.content {
        case .bodies(let bodies)?: return !mode.isSketching && !bodies.isEmpty
        case .sketchEntities(let entities)?: return mode.isSketching && !entities.isEmpty
        case nil: return false
        }
    }

    @discardableResult
    func copySelection() -> Bool {
        if mode.isSketching {
            guard let sketch = activeSketch else { return false }
            let entities = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
            guard !entities.isEmpty else { return false }
            EditorClipboard.content = .sketchEntities(entities)
            showNotice(entities.count == 1 ? "Copied 1 sketch item" : "Copied \(entities.count) sketch items")
            return true
        }
        let bodies = session.document.bodies.filter { selection.contains($0.id) }
        guard !bodies.isEmpty else { return false }
        EditorClipboard.content = .bodies(bodies)
        showNotice(bodies.count == 1 ? "Copied \(bodies[0].name)" : "Copied \(bodies.count) bodies")
        return true
    }

    @discardableResult
    func cutSelection() -> Bool {
        guard copySelection() else { return false }
        deleteSelection()
        return true
    }

    /// Paste in place: the copies land where the originals were, selected, so
    /// Move can take them from there. One undo step.
    @discardableResult
    func paste() -> Bool {
        guard canPaste else { return false }
        switch EditorClipboard.content {
        case .bodies(let bodies)?:
            var commands: [DocumentCommand] = []
            var pasted: Set<BodyID> = []
            var names = session.document
            for body in bodies {
                var clone = Body(
                    id: BodyID(),
                    name: names.uniqueBodyName(base: body.name),
                    transform: body.transform,
                    primitive: body.primitive,
                    render: body.render,
                    revision: body.meshRevision
                )
                clone.euclid = body.euclid
                clone.brep = body.brep
                clone.material = body.material
                clone.edges = body.edges
                names.bodies.append(clone) // so the next name is unique too
                commands.append(AddBodyCommand(body: clone, title: "Paste"))
                pasted.insert(clone.id)
            }
            cancelTool()
            session.perform(commands.count == 1 ? commands[0] : CompositeCommand(title: "Paste", commands: commands))
            selection = pasted
            mode = pasted.count == 1 ? .selected(pasted.first!) : .idle
            session.save()
            return true
        case .sketchEntities(let entities)?:
            guard case .sketching(let sketchID, _) = mode else { return false }
            var commands: [DocumentCommand] = []
            var ids: Set<UUID> = []
            for entity in entities {
                for copy in PatternKit.transformed(entity, by: .identity) {
                    commands.append(AddSketchEntityCommand(sketchID: sketchID, entity: copy))
                    ids.insert(copy.id)
                }
            }
            guard !commands.isEmpty else { return false }
            session.perform(CompositeCommand(title: "Paste", commands: commands))
            selectedSketchEntityIDs = ids
            selectedSketchPoints.removeAll()
            return true
        case nil:
            return false
        }
    }
}
