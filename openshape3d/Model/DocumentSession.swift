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

    /// IDs of persisted rows this build could not decode at `load()` — an
    /// unknown feature kind written by a newer build, a newer `MeshBlob`
    /// version, or a corrupt blob. They are absent from `document`, but
    /// `save()` MUST treat them as live: skipping a row is recoverable, while
    /// letting the save diff delete it is permanent data loss (2026-08-25
    /// review, finding C1). A preserved feature row's `orderIndex` can drift
    /// relative to renumbered live rows; a fuzzy position on later recovery
    /// beats deletion.
    private var unreadableRows = UnreadableRows()

    private struct UnreadableRows {
        var bodies: Set<UUID> = []
        var sketches: Set<UUID> = []
        var planes: Set<UUID> = []
        var axes: Set<UUID> = []
        var images: Set<UUID> = []
        var symbols: Set<UUID> = []
        var features: Set<UUID> = []
        /// Bodies whose row decoded but one COLUMN did not — the column's
        /// blob must not be overwritten by the nil we decoded to.
        var bodyPrimitive: Set<UUID> = []
        var bodyMaterial: Set<UUID> = []
        var bodyBrep: Set<UUID> = []
        /// Whole rows that could not be decoded (absent from the document).
        var rowCount: Int {
            bodies.count + sketches.count + planes.count + axes.count
                + images.count + symbols.count + features.count
        }
        /// Bodies present in the document but missing some detail.
        var partialBodyCount: Int {
            bodyPrimitive.union(bodyMaterial).union(bodyBrep).count
        }
        var count: Int { rowCount + partialBodyCount }
    }

    /// True when the store's `formatVersion` is newer than this build writes.
    /// The document still opens for viewing, but `save()` refuses to run —
    /// an older app must never rewrite a newer store.
    private(set) var storeIsNewerThanApp = false

    /// One-shot user-facing warning from `load()` (newer-format store, or
    /// "N items couldn't be read"); the editor surfaces it once on open.
    private(set) var loadWarning: String?

    /// Most recent `modelContext.save()` failure, nil after a clean save.
    /// Swallowing these silently was part of review finding C1.
    private(set) var lastSaveError: String?

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

    /// Move (or clear, `nil`) the feature-graph rollback marker and rebuild
    /// everything downstream in one undo step (History panel roll-back). Nodes
    /// at/after the marker are no longer replayed, so their bodies are removed by
    /// the diff; returning to `nil` (latest) replays and restores them. Mirrors
    /// `setSuppressed`: no-op if the marker is unchanged.
    func setRollback(_ newIndex: Int?) {
        guard document.features.rollbackIndex != newIndex else { return }
        var edited = document.features
        edited.rollbackIndex = newIndex
        let cmd = SetRollbackCommand(before: document.features.rollbackIndex, after: newIndex)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Delete a node from the history and rebuild everything downstream in one
    /// undo step (History panel delete). The node's exclusively-owned bodies are
    /// removed; bodies still produced by surviving nodes are replaced.
    func deleteFeature(_ id: FeatureID) {
        guard let node = document.features.node(id),
              let index = document.features.index(of: id) else { return }
        let beforeRollback = document.features.rollbackIndex
        var edited = document.features
        edited.nodes.removeAll { $0.id == id }
        // Keep the evaluation graph's marker consistent with what
        // RemoveFeatureCommand.apply will set the live marker to: deleting an
        // ACTIVE node shortens the active prefix. Without this, `evaluate`'s
        // `prefix(rollbackIndex)` would pull a rolled-back node into the active
        // set and spuriously re-add its body while the real marker drops.
        if let cut = beforeRollback, index < cut { edited.rollbackIndex = cut - 1 }
        let cmd = RemoveFeatureCommand(index: index, node: node, beforeRollback: beforeRollback)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Reorder a node to `newIndex` and rebuild everything downstream in one undo
    /// step (History panel drag-to-reorder). `evaluate` replays nodes in array
    /// order, so moving a node before one it references breaks that reference and
    /// surfaces a `.brokenRef` error on the dependent node (Shapr3D-style — the
    /// reorder is allowed, the error is shown). The rollback marker is a positional
    /// count and is left unchanged. No-op if the position doesn't actually change.
    func moveFeature(_ id: FeatureID, to newIndex: Int) {
        guard let from = document.features.index(of: id) else { return }
        var edited = document.features
        let node = edited.nodes.remove(at: from)
        let clamped = min(max(newIndex, 0), edited.nodes.count)
        guard clamped != from else { return }
        edited.nodes.insert(node, at: clamped)
        let cmd = MoveFeatureCommand(featureID: id, from: from, to: clamped)
        performRebuild(edited, leadingCommands: [cmd], title: cmd.title)
    }

    /// Guards `performRebuild` against re-entrancy. `performRebuild` ends by
    /// `perform`ing one internal `CompositeCommand`; that document mutation must
    /// never start a nested replay (e.g. via a sketch-driven rebuild). Set for
    /// the duration of `performRebuild`'s body (see the `defer` there).
    private var isRebuilding = false

    /// Sketch-edit hook: after a sketch-mutating command has already run (so
    /// `document.sketches` holds the NEW geometry), replay the feature graph if —
    /// and only if — some node references `sketchID`. A node's
    /// `referencedSketchIDs` union covers its profile / extra-profile / loft-section
    /// / plane / revolve-axis references, so this fires exactly when the edited
    /// sketch feeds a downstream feature.
    ///
    /// Because `performRebuild` evaluates against the current (already-mutated)
    /// `document.sketches`, the replay picks up the new geometry with NO graph
    /// edit and `leadingCommands` is empty. Skips entirely when nothing depends on
    /// the sketch (no undo noise) and when a rebuild is already in flight.
    ///
    /// This DOES land as its own undo step, so it is now only for paths that
    /// can't compose: live entity drags (the move command was amended per
    /// tick) and finishSketch's belt-and-suspenders pass. Everything else
    /// goes through `performWithSketchRebuild` for one atomic step (S6).
    func rebuildForSketchChange(_ sketchID: SketchID) {
        guard !isRebuilding else { return }
        guard document.features.nodes.contains(where: {
            $0.referencedSketchIDs.contains(sketchID)
        }) else { return }
        performRebuild(document.features, leadingCommands: [], title: "Update Sketch")
    }

    /// Perform a sketch-mutating command AND the downstream feature rebuild as
    /// ONE undo step (2026-08-25 review, S6 — as separate steps, one undo
    /// reverted only the rebuild, leaving new sketch geometry with old solids,
    /// permanently desynced once the redo stack cleared). The command becomes
    /// the composite's first entry; evaluation runs against a preview copy
    /// that already has it applied, since the live document is only mutated
    /// when the composite performs. Falls back to a plain `perform` when no
    /// feature references any of the touched sketches.
    ///
    /// Residual (documented): live entity DRAGS amend their move command per
    /// tick and rebuild at the drag-end boundary, so that path still lands as
    /// two steps.
    func performWithSketchRebuild(_ command: DocumentCommand, sketchIDs: Set<SketchID>) {
        guard !isRebuilding,
              document.features.nodes.contains(where: {
                  !$0.referencedSketchIDs.isDisjoint(with: sketchIDs)
              })
        else {
            perform(command)
            return
        }
        var preview = document
        command.apply(to: &preview)
        performRebuild(
            document.features,
            leadingCommands: [command],
            title: command.title,
            sketches: preview.sketches
        )
    }

    func performWithSketchRebuild(_ command: DocumentCommand, sketchID: SketchID) {
        performWithSketchRebuild(command, sketchIDs: [sketchID])
    }

    /// Core of every graph-driven rebuild: replay `editedGraph`, diff the
    /// produced bodies against the current feature-owned bodies, and commit the
    /// mesh changes plus `leadingCommands` (the graph mutation itself) as ONE
    /// undoable `CompositeCommand`. Shared by `rebuildFrom`, `setSuppressed`, and
    /// `deleteFeature` so all three stay a single undo step.
    private func performRebuild(
        _ editedGraph: FeatureGraph, leadingCommands: [DocumentCommand], title: String,
        sketches: [Sketch]? = nil
    ) {
        // Re-entrancy guard: this method ends by `perform`ing one internal
        // `CompositeCommand`; if that mutation ever routes back into a rebuild
        // (e.g. a sketch-change hook observing the change), we must NOT start a
        // nested replay. Normal callers — rebuildFrom / setSuppressed /
        // deleteFeature / rebuildForSketchChange — are unaffected: the flag is
        // false on entry, so each performs exactly as before; the guard only
        // short-circuits a RE-ENTRANT (nested) call.
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        // Replay. `nextRevision` advances the REAL document counter so every
        // emitted revision is globally unique (added bodies keep theirs; replaced
        // bodies get a fresh one again in ReplaceBodyCommand.apply).
        // `sketches` override: performWithSketchRebuild evaluates against a
        // preview that already contains its (not-yet-performed) sketch edit.
        let result = editedGraph.evaluate(
            sketches: sketches ?? document.sketches,
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

    /// Edit a pattern feature's `PatternSpec` and rebuild everything downstream in
    /// one undo step. Unlike `editFeature`, a pattern edit can change how many
    /// instance bodies the node owns (its `count`), so this resizes the node's
    /// `outputBodyIDs` alongside the spec:
    ///
    /// - `desiredCopies = max(0, spec.count - 1)` (the original is the source body,
    ///   not an emitted copy — see `evalPattern`, which emits ids `1..<count`).
    /// - GROW: append fresh `BodyID()`s to the node's current `outputBodyIDs` until
    ///   it holds `desiredCopies`. The extra ids aren't in the live graph's owned
    ///   set, so `performRebuild`'s diff sees them only in the produced bodies →
    ///   `AddBody`.
    /// - SHRINK: `prefix(desiredCopies)` the current ids; the dropped tail ids stay
    ///   in the live node's `outputBodyIDs`, so `performRebuild` unions them into
    ///   `ownedIDs`, finds the replay no longer produces them → `DeleteBodies`.
    ///
    /// The `EditFeatureOutputsCommand` (swapping BOTH kind and outputBodyIDs) rides
    /// the SAME `performRebuild` as the mesh diff — so one undo reverts the spec,
    /// the ownership change, and every instance mesh. The graph copy handed to
    /// `performRebuild` has both the new spec and the resized ids, so `evaluate`
    /// has exactly enough ids to emit `desiredCopies` instances. No-op unless the
    /// node exists and is a `.pattern`.
    func editPatternFeature(_ id: FeatureID, spec: PatternSpec) {
        guard let node = document.features.node(id),
              case let .pattern(bodyRef, _) = node.kind else { return }

        let desiredCopies = max(0, spec.count - 1)
        var afterOutputs = node.outputBodyIDs
        if afterOutputs.count > desiredCopies {
            afterOutputs = Array(afterOutputs.prefix(desiredCopies))
        } else {
            while afterOutputs.count < desiredCopies { afterOutputs.append(BodyID()) }
        }

        let afterKind = FeatureKind.pattern(body: bodyRef, spec: spec)
        let cmd = EditFeatureOutputsCommand(
            featureID: id,
            beforeKind: node.kind,
            afterKind: afterKind,
            beforeOutputs: node.outputBodyIDs,
            afterOutputs: afterOutputs
        )

        // Graph copy with the new spec AND resized ids so `evaluate` sees the new
        // parameters and has exactly enough ids to emit `desiredCopies` copies —
        // mirroring `rebuildFrom`'s edited-graph pattern.
        var editedGraph = document.features
        if let index = editedGraph.index(of: id) {
            editedGraph.nodes[index].kind = afterKind
            editedGraph.nodes[index].outputBodyIDs = afterOutputs
        }
        performRebuild(editedGraph, leadingCommands: [cmd], title: cmd.title)
    }

    // MARK: - Variables (Phase D, Task B1 / spec §6.6)

    /// The current `[name: value]` map of successfully-resolved document
    /// variables (creation-order rule; failed/forward refs are absent). Feature
    /// `Expr` formulas and sketch `SketchDimension` formulas evaluate against this.
    func variableValues() -> [String: Double] {
        VariableTable.resolve(document.variables).values
    }

    /// Re-evaluate every formula-bearing `Expr` on `kind` against `values`,
    /// returning a new kind if ANY of its values changed, or `nil` when nothing
    /// changed (so callers only emit an edit for genuinely affected nodes).
    /// `FeatureKind` is not Equatable, so change detection is per-`Expr` value.
    /// The `formula` is always preserved on the rebuilt `Expr`.
    static func reevaluatedKind(
        _ kind: FeatureKind, with values: [String: Double]
    ) -> FeatureKind? {
        func updated(_ expr: Expr) -> Expr? {
            guard let formula = expr.formula else { return nil }  // not variable-driven
            // A formula that no longer resolves — its variable was deleted or
            // renamed — errors to 0 (spec §6.6). Propagate the 0 so the breakage
            // surfaces (the step goes empty/errored) rather than silently keeping
            // the last resolved value with a now-dangling formula.
            let v = ExpressionEvaluator.evaluate(formula, variables: values) ?? 0
            guard v != expr.value else { return nil }
            return Expr(value: v, formula: formula)
        }
        switch kind {
        case let .extrude(profile, plane, distance, symmetric, boolean, extras):
            guard let d = updated(distance) else { return nil }
            return .extrude(
                profile: profile, plane: plane, distance: d,
                symmetric: symmetric, boolean: boolean, extraProfiles: extras)
        case let .revolve(profile, plane, axis, angle, boolean):
            guard let a = updated(angle) else { return nil }
            return .revolve(profile: profile, plane: plane, axis: axis, angle: a, boolean: boolean)
        case let .pushPull(face, distance, mode):
            guard let d = updated(distance) else { return nil }
            return .pushPull(face: face, distance: d, mode: mode)
        case let .scaleFace(face, factor):
            guard let f = updated(factor) else { return nil }
            return .scaleFace(face: face, factor: f)
        case let .rotateFace(face, angle, axis):
            guard let a = updated(angle) else { return nil }
            return .rotateFace(face: face, angle: a, axis: axis)
        default:
            return nil
        }
    }

    /// Pre-resolve feature `Expr` formulas against the current variable values,
    /// writing the fresh `.value` into `document.features` IN PLACE. Optional hook
    /// for a rebuild triggered by means OTHER than a variable edit (so it still
    /// honours current variable values): `evaluate()` reads `Expr.value`, never
    /// `.formula`, so the graph must already hold the resolved values before any
    /// `performRebuild`. Not undoable — `.value` is a derived cache of `.formula`.
    func resolveExprFormulas() {
        let values = variableValues()
        for index in document.features.nodes.indices {
            if let newKind = Self.reevaluatedKind(document.features.nodes[index].kind, with: values) {
                document.features.nodes[index].kind = newKind
            }
        }
    }

    /// Fan-out after any variable add/edit/delete (the VM performs the mutating
    /// command, then calls this):
    ///
    /// (a) Re-resolve `document.variables` (creation-order rule) and write the
    ///     resolved `.value` back into each variable — a derived cache, updated in
    ///     place (not a separate undo step; undoing the triggering command restores
    ///     the prior snapshots).
    /// (b) FEATURE fan-out: recompute every feature `Expr` that carries a `formula`;
    ///     the changed nodes' `EditFeatureCommand`s ride the SAME `performRebuild`
    ///     as the downstream mesh diff, so one undo reverts the whole feature
    ///     rebuild. The edited graph is pre-resolved so `evaluate()` reads the new
    ///     `.value`.
    /// (c) SKETCH fan-out: recompute every `SketchDimension` that carries a
    ///     `formula`; each affected sketch re-solves (SketchSolverBridge) and
    ///     rebuilds its dependents via `rebuildForSketchChange` — as its OWN undo
    ///     step, SEPARATE from the feature rebuild (atomic bundling is a later
    ///     tranche).
    ///
    /// Guarded by `isRebuilding` so a rebuild already in flight never re-enters.
    func variablesDidChange() {
        guard !isRebuilding else { return }

        // (a) Resolve + cache values back into the variables.
        let resolved = VariableTable.resolve(document.variables)
        let values = resolved.values
        for index in document.variables.indices where index < resolved.resolved.count {
            document.variables[index].value = resolved.resolved[index].value
        }
        didChange()

        // (b) Feature formulas -> one rebuild step.
        var editedGraph = document.features
        var editCommands: [DocumentCommand] = []
        for (index, node) in document.features.nodes.enumerated() {
            guard let newKind = Self.reevaluatedKind(node.kind, with: values) else { continue }
            editCommands.append(EditFeatureCommand(
                featureID: node.id, before: node.kind, after: newKind))
            editedGraph.nodes[index].kind = newKind
        }
        if !editCommands.isEmpty {
            performRebuild(editedGraph, leadingCommands: editCommands, title: "Variables")
        }

        // (c) Sketch dimension formulas -> one re-solve + rebuild step per sketch.
        for sketchIndex in document.sketches.indices {
            let sketch = document.sketches[sketchIndex]
            var proposed = sketch
            var dimCommands: [DocumentCommand] = []
            for dimIndex in sketch.dimensions.indices {
                let before = sketch.dimensions[dimIndex]
                guard let formula = before.formula else { continue }
                // Broken formula (deleted/renamed variable) errors to 0 — surface
                // it rather than silently keeping the stale dimension value.
                let v = ExpressionEvaluator.evaluate(formula, variables: values) ?? 0
                guard v != before.value else { continue }
                var after = before
                after.value = v
                proposed.dimensions[dimIndex] = after
                dimCommands.append(UpdateSketchDimensionCommand(
                    sketchID: sketch.id, before: before, after: after))
            }
            guard !dimCommands.isEmpty else { continue }

            let (solvedEntities, _) = SketchSolverBridge.solve(
                proposed, movingEntity: nil, dragTarget: nil)
            var commands = dimCommands
            for (before, after) in zip(sketch.entities, solvedEntities) where before != after {
                commands.append(UpdateSketchEntityCommand(
                    sketchID: sketch.id, before: before, after: after))
            }
            perform(CompositeCommand(title: "Variables", commands: commands))
            rebuildForSketchChange(sketch.id)
        }
    }

    // MARK: - Persistence

    private func load() {
        storeIsNewerThanApp = project.formatVersion > Project.currentFormatVersion
        var loaded = DesignDocument()
        for persisted in project.bodies {
            guard let render = try? MeshBlob.decode(persisted.meshData),
                  let transform = try? JSONDecoder().decode(Transform3D.self, from: persisted.transformData)
            else {
                unreadableRows.bodies.insert(persisted.bodyID)
                continue
            }
            // Per-COLUMN decode failures need the same protection as whole
            // rows: the row itself is fine, so it isn't in `unreadableRows`,
            // and save() would happily write the decoded `nil` back over a
            // blob it merely failed to read — losing an analytic brep, a
            // material or a primitive spec permanently (2026-08-25 review
            // round 2). Record them so save() leaves those columns alone.
            let primitive = persisted.primitiveData.flatMap { data -> PrimitiveSpec? in
                let decoded = try? JSONDecoder().decode(PrimitiveSpec.self, from: data)
                if decoded == nil { unreadableRows.bodyPrimitive.insert(persisted.bodyID) }
                return decoded
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
            body.material = persisted.materialData.flatMap { data -> BodyMaterialSpec? in
                let decoded = try? JSONDecoder().decode(BodyMaterialSpec.self, from: data)
                if decoded == nil { unreadableRows.bodyMaterial.insert(persisted.bodyID) }
                return decoded
            }
            // Restore the analytic B-rep so a reloaded cylinder stays round and
            // can still compose booleans. An unreadable blob (truncated, or
            // written by a newer OCCT) leaves the body Euclid-only for this
            // session — the persisted render mesh is already correct — but the
            // stored blob is PRESERVED rather than overwritten with nil.
            body.brep = persisted.brepData.flatMap { data -> BRepHandle? in
                let decoded = OCCTKernel.deserialize(data)
                if decoded == nil { unreadableRows.bodyBrep.insert(persisted.bodyID) }
                return decoded
            }
            loaded.bodies.append(body)
        }
        for persisted in project.sketches {
            if let sketch = try? JSONDecoder().decode(Sketch.self, from: persisted.sketchData) {
                loaded.sketches.append(sketch)
            } else {
                unreadableRows.sketches.insert(persisted.sketchID)
            }
        }
        for persisted in project.planes {
            if let plane = try? JSONDecoder().decode(ConstructionPlane.self, from: persisted.planeData) {
                loaded.planes.append(plane)
            } else {
                unreadableRows.planes.insert(persisted.planeID)
            }
        }
        for persisted in project.axes {
            if let axis = try? JSONDecoder().decode(ConstructionAxis.self, from: persisted.axisData) {
                loaded.axes.append(axis)
            } else {
                unreadableRows.axes.insert(persisted.axisID)
            }
        }
        for persisted in project.images {
            if var image = try? JSONDecoder().decode(InsertedImage.self, from: persisted.infoData) {
                image.imageData = persisted.imageData
                loaded.images.append(image)
            } else {
                unreadableRows.images.insert(persisted.imageID)
            }
        }
        for persisted in project.symbols {
            if let symbol = try? JSONDecoder().decode(Symbol.self, from: persisted.symbolData) {
                loaded.symbols.append(symbol)
            } else {
                unreadableRows.symbols.insert(persisted.symbolID)
            }
        }
        // Phase D feature graph: replay order is `orderIndex` (SwiftData
        // relationships are unordered). A node whose kind blob won't decode is
        // skipped (decodeFeature -> nil), not fatal. Pre-Phase-D projects have no
        // PersistedFeature rows -> empty graph, and render from their baked
        // PersistedBody meshes until the first parametric edit.
        // The rollback marker is a positional count of active leading nodes. If a
        // node that sat BEFORE the marker fails to decode and is skipped, the
        // active prefix shrinks, so shift the marker down by the number of such
        // skips to keep it on the same logical boundary.
        let savedMarker = project.rollbackIndex
        var skippedBeforeMarker = 0
        for (position, persisted) in project.features
            .sorted(by: { $0.orderIndex < $1.orderIndex }).enumerated() {
            if let node = decodeFeature(persisted) {
                loaded.features.nodes.append(node)
            } else {
                unreadableRows.features.insert(persisted.featureID)
                if let marker = savedMarker, position < marker {
                    skippedBeforeMarker += 1
                }
            }
        }
        // Phase D (Tranche 5) rollback marker: a scalar column on Project. Pre-
        // rollback stores have `rollbackIndex == nil` (all nodes active).
        loaded.features.rollbackIndex = savedMarker.map {
            max(0, min($0 - skippedBeforeMarker, loaded.features.nodes.count))
        }
        // Phase D variables (spec §6.6): ordered by `orderIndex` (SwiftData
        // relationships are unordered) so the creation-order resolution rule
        // survives the round-trip. Pre-tranche-3 projects have no PersistedVariable
        // rows -> empty list. `try?`-per-item is defensive symmetry with the other
        // decode loops (decodeVariable itself is non-throwing).
        for persisted in project.variables.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            loaded.variables.append(decodeVariable(persisted))
        }
        document = loaded
        if storeIsNewerThanApp {
            loadWarning = """
            This project was saved by a newer version of the app. It opens \
            read-only here — changes will not be saved. Update the app to \
            edit it.
            """
        } else {
            // Both conditions can hold at once — report each, rather than
            // letting the row message hide which shapes lost detail.
            var parts: [String] = []
            if unreadableRows.rowCount > 0 {
                parts.append("""
                \(unreadableRows.rowCount) item(s) in this project couldn't be \
                read by this version of the app. They stay safely stored and \
                are hidden from the editor; nothing has been deleted.
                """)
            }
            if unreadableRows.partialBodyCount > 0 {
                parts.append("""
                \(unreadableRows.partialBodyCount) shape(s) opened without some \
                detail this version couldn't read. The stored data is kept \
                untouched, so nothing is lost.
                """)
            }
            loadWarning = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
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

        // A store written by a NEWER format must never be rewritten by this
        // build — the diffs below would delete every row it couldn't decode.
        // The user was warned at load (`loadWarning`).
        guard !storeIsNewerThanApp else { return }

        // Diff by ID against the persisted objects. Every deletion loop
        // excludes `unreadableRows` — rows load() couldn't decode are not in
        // `document`, but deleting them would turn a recoverable skip into
        // permanent data loss. Encode failures likewise skip the row update
        // (keeping the old blob) rather than writing empty Data; the ID is
        // recorded as live FIRST so the row survives the deletion diff.
        var persistedByID = [UUID: PersistedBody]()
        for persisted in project.bodies {
            persistedByID[persisted.bodyID] = persisted
        }

        var liveIDs = Set<UUID>()
        for body in document.bodies {
            liveIDs.insert(body.id.raw)
            guard let transformData = try? JSONEncoder().encode(body.transform) else { continue }
            let primitiveData = body.primitive.flatMap { try? JSONEncoder().encode($0) }
            let meshData = MeshBlob.encode(body.render)
            let materialData = body.material.flatMap { try? JSONEncoder().encode($0) }
            // Analytic geometry, when this body has it — so roundness and boolean
            // composability survive a reload instead of degrading to triangles.
            let brepData = body.brep.flatMap { OCCTKernel.serialize($0) }

            if let persisted = persistedByID[body.id.raw] {
                let id = body.id.raw
                // Columns load() couldn't decode keep their stored blob: we
                // decoded them to nil, so writing that nil back would destroy
                // data this build merely couldn't read.
                //
                // But the GEOMETRY-tied columns (primitive spec, brep) may only
                // be preserved while the mesh they describe is UNCHANGED. If the
                // user reshaped the body, the preserved blob describes geometry
                // that no longer exists, and a newer build would load a stale
                // analytic solid alongside the new mesh — precisely the
                // mesh/brep divergence the B-rep work exists to prevent. So a
                // changed mesh drops them. This also covers the inverse case:
                // a body that GAINED a brep this session (rebuild composed one)
                // has a changed mesh too, so the new brep is written, not
                // discarded by the preservation rule.
                // Preserve a column ONLY while there is nothing real to put in
                // its place. Keying purely on "load couldn't decode it" would
                // freeze the column for the whole session and silently discard
                // the user's own later edits — applying a material to such a
                // body would never reach disk.
                func preserve(_ unreadable: Set<UUID>, _ encoded: Data?) -> Bool {
                    encoded == nil && unreadable.contains(id)
                }
                let preservesGeometry = unreadableRows.bodyPrimitive.contains(id)
                    || unreadableRows.bodyBrep.contains(id)
                // Only faults in the stored blob for the rare preserved rows.
                let meshUnchanged = preservesGeometry && persisted.meshData == meshData

                persisted.name = body.name
                persisted.transformData = transformData
                if !(preserve(unreadableRows.bodyPrimitive, primitiveData) && meshUnchanged) {
                    persisted.primitiveData = primitiveData
                }
                persisted.meshData = meshData
                persisted.isHidden = body.isHidden
                // Material is independent of geometry — no mesh condition.
                if !preserve(unreadableRows.bodyMaterial, materialData) {
                    persisted.materialData = materialData
                }
                if !(preserve(unreadableRows.bodyBrep, brepData) && meshUnchanged) {
                    persisted.brepData = brepData
                }
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
                persisted.brepData = brepData
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.bodies
        where !liveIDs.contains(persisted.bodyID)
            && !unreadableRows.bodies.contains(persisted.bodyID) {
            modelContext.delete(persisted)
        }

        var persistedSketchByID = [UUID: PersistedSketch]()
        for persisted in project.sketches {
            persistedSketchByID[persisted.sketchID] = persisted
        }
        var liveSketchIDs = Set<UUID>()
        for sketch in document.sketches {
            liveSketchIDs.insert(sketch.id.raw)
            guard let data = try? JSONEncoder().encode(sketch) else { continue }
            if let persisted = persistedSketchByID[sketch.id.raw] {
                persisted.sketchData = data
            } else {
                let persisted = PersistedSketch(sketchID: sketch.id.raw, sketchData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.sketches
        where !liveSketchIDs.contains(persisted.sketchID)
            && !unreadableRows.sketches.contains(persisted.sketchID) {
            modelContext.delete(persisted)
        }

        var persistedPlaneByID = [UUID: PersistedPlane]()
        for persisted in project.planes {
            persistedPlaneByID[persisted.planeID] = persisted
        }
        var livePlaneIDs = Set<UUID>()
        for plane in document.planes {
            livePlaneIDs.insert(plane.id.raw)
            guard let data = try? JSONEncoder().encode(plane) else { continue }
            if let persisted = persistedPlaneByID[plane.id.raw] {
                persisted.planeData = data
            } else {
                let persisted = PersistedPlane(planeID: plane.id.raw, planeData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.planes
        where !livePlaneIDs.contains(persisted.planeID)
            && !unreadableRows.planes.contains(persisted.planeID) {
            modelContext.delete(persisted)
        }

        var persistedAxisByID = [UUID: PersistedAxis]()
        for persisted in project.axes {
            persistedAxisByID[persisted.axisID] = persisted
        }
        var liveAxisIDs = Set<UUID>()
        for axis in document.axes {
            liveAxisIDs.insert(axis.id.raw)
            guard let data = try? JSONEncoder().encode(axis) else { continue }
            if let persisted = persistedAxisByID[axis.id.raw] {
                persisted.axisData = data
            } else {
                let persisted = PersistedAxis(axisID: axis.id.raw, axisData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.axes
        where !liveAxisIDs.contains(persisted.axisID)
            && !unreadableRows.axes.contains(persisted.axisID) {
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
            guard let infoData = try? JSONEncoder().encode(info) else { continue }
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
        for persisted in project.images
        where !liveImageIDs.contains(persisted.imageID)
            && !unreadableRows.images.contains(persisted.imageID) {
            modelContext.delete(persisted)
        }

        var persistedSymbolByID = [UUID: PersistedSymbol]()
        for persisted in project.symbols {
            persistedSymbolByID[persisted.symbolID] = persisted
        }
        var liveSymbolIDs = Set<UUID>()
        for symbol in document.symbols {
            liveSymbolIDs.insert(symbol.id.raw)
            guard let data = try? JSONEncoder().encode(symbol) else { continue }
            if let persisted = persistedSymbolByID[symbol.id.raw] {
                persisted.symbolData = data
            } else {
                let persisted = PersistedSymbol(symbolID: symbol.id.raw, symbolData: data)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.symbols
        where !liveSymbolIDs.contains(persisted.symbolID)
            && !unreadableRows.symbols.contains(persisted.symbolID) {
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
        for persisted in project.features
        where !liveFeatureIDs.contains(persisted.featureID)
            && !unreadableRows.features.contains(persisted.featureID) {
            modelContext.delete(persisted)
        }
        // Phase D (Tranche 5) rollback marker: mirror the in-memory graph's marker
        // onto the Project scalar column (nil = all nodes active).
        project.rollbackIndex = document.features.rollbackIndex

        // Phase D variables (spec §6.6): diff by variableID, mirroring the
        // PersistedFeature block. `orderIndex` is the variable's array position so
        // creation order survives the round-trip; name/expression/value map per
        // column via the A2 helpers.
        var persistedVariableByID = [UUID: PersistedVariable]()
        for persisted in project.variables {
            persistedVariableByID[persisted.variableID] = persisted
        }
        var liveVariableIDs = Set<UUID>()
        for (index, variable) in document.variables.enumerated() {
            liveVariableIDs.insert(variable.id.raw)
            if let persisted = persistedVariableByID[variable.id.raw] {
                persisted.orderIndex = index
                persisted.name = variable.name
                persisted.expression = variable.expression
                persisted.value = variable.value
            } else {
                let persisted = encodeVariable(variable, orderIndex: index)
                persisted.project = project
                modelContext.insert(persisted)
            }
        }
        for persisted in project.variables where !liveVariableIDs.contains(persisted.variableID) {
            modelContext.delete(persisted)
        }

        project.modifiedAt = Date()
        project.formatVersion = Project.currentFormatVersion
        do {
            try modelContext.save()
            lastSaveError = nil
        } catch {
            // Silent save failures were review finding C1 — record them so
            // the editor can tell the user their work isn't reaching disk.
            lastSaveError = error.localizedDescription
        }
    }
}
