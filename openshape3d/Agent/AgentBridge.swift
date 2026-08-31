//
//  AgentBridge.swift
//  openshape3d
//
//  The main-actor half of the DEBUG-only agent bridge.
//
//  This is the piece that was structurally missing. `AgentServer` is
//  deliberately `nonisolated` and runs on its own `DispatchQueue` (it must be:
//  the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a
//  listener cannot live on the main actor). `EditorViewModel` is `@MainActor`
//  and is created per-document by a SwiftUI view. So the socket had no way to
//  reach the editor, and no reference to it if it had.
//
//  `AgentBridge` is that reference plus the hop. It holds the live view model
//  WEAKLY — the editor's lifetime belongs to `EditorView`, and a debug channel
//  must never be the thing keeping a closed document alive.
//
//  When no document is open (project gallery on screen) the editor routes
//  answer 409 `no_document`. That is a real, actionable state an agent should
//  see and recover from by opening a project, not a hang or an empty success.
//

#if DEBUG

import Foundation

// MARK: - Attachment flag, readable off the main actor

/// Whether a document is open, in a form `/v1/health` can read from the
/// listener queue.
///
/// `/v1/health` must answer even when the main actor is busy — a liveness probe
/// that blocks behind a wedged UI is worse than no probe, because it reports
/// the one condition it exists to detect as a timeout. So the flag is mirrored
/// out here under a lock rather than read from `AgentBridge` directly.
nonisolated enum AgentAttachment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attached = false

    static var isAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return attached
    }

    static func set(_ value: Bool) {
        lock.lock(); attached = value; lock.unlock()
    }
}

// MARK: - The bridge

@MainActor
final class AgentBridge {
    static let shared = AgentBridge()
    private init() {}

    /// Weak on purpose — see the file header.
    private weak var viewModel: EditorViewModel?
    private var documentName: String?

    /// Called from `EditorView`'s `.task`, right after the view model is built.
    func register(_ viewModel: EditorViewModel, documentName: String) {
        self.viewModel = viewModel
        self.documentName = documentName
        AgentAttachment.set(true)
        NSLog("[agent] editor attached: \(documentName)")
    }

    /// Called from `EditorView`'s `.onDisappear`. Guarded on identity so a
    /// fast document switch (new editor registers before the old one tears
    /// down) cannot detach the newcomer.
    func unregister(_ viewModel: EditorViewModel) {
        guard self.viewModel === viewModel else { return }
        self.viewModel = nil
        self.documentName = nil
        AgentAttachment.set(false)
        NSLog("[agent] editor detached")
    }

    // MARK: Serving the editor routes

    func handle(_ route: AgentRoute) -> AgentResponse {
        guard let viewModel else {
            return .failure(409, "Conflict", error: "no_document",
                            message: "No document is open — the project gallery is on screen. "
                                   + "Open or create a project first (launch with OS3D_FRESH=1 to start in a new one).")
        }

        switch route {
        case .state:
            return .ok(snapshot(of: viewModel))

        case .runCommand(let id):
            // The router already separated "unknown id" and "no entry point",
            // so a false here means exactly one thing: the editor is in a state
            // where this command does not apply. Say which state.
            let ran = viewModel.runCommand(id)
            var payload = snapshot(of: viewModel)
            payload["id"] = id
            payload["ran"] = ran
            if !ran {
                payload["reason"] = "not_applicable"
                payload["message"] = "'\(id)' does not apply in mode '\(Self.modeName(viewModel.mode))' "
                    + "with \(viewModel.selection.count) selected. The same guard would have disabled its palette button."
            }
            return .ok(payload)

        case .exec(let op):
            return execute(op, on: viewModel)

        case let .check(bodyID, runBOPCheck):
            return check(bodyID: bodyID, runBOPCheck: runBOPCheck, on: viewModel)

        case let .capture(note):
            let analytic = viewModel.session.document.bodies.compactMap { body in
                body.brep.map { (label: body.name, handle: $0) }
            }
            guard !analytic.isEmpty else {
                return .failure(409, "Conflict", error: "nothing_to_capture",
                                message: "No body carries a brep — a snapshot captures "
                                       + "analytic solids, and every body here is mesh-only.")
            }
            guard let bundle = KernelCapture.recordSnapshot(
                inputs: analytic, note: note.isEmpty ? "requested over /v1/capture" : note)
            else {
                return .failure(500, "Internal Server Error", error: "capture_failed",
                                message: "The capture bundle could not be written "
                                       + "(OS3D_KERNEL_CAPTURE=0 disables capture entirely).")
            }
            return .ok([
                "path": bundle.path,
                "bodies": analytic.map(\.label),
                "message": "Replayable bundle written. Pull it with scripts/fetch_captures.sh, "
                         + "or promote it to openshape3dTests/Fixtures/Captures as a regression fixture.",
            ])

        case .screenshot(let width, let height):
            guard let png = viewModel.captureScreenshot(
                width: width, height: height, transparentBackground: false, showGrid: true
            ) else {
                return .failure(500, "Internal Server Error", error: "screenshot_failed",
                                message: "The viewport did not return an image. It has to be on screen "
                                       + "and rendered at least once before it can be captured.")
            }
            return .png(png)

        default:
            // Routes that never need the editor are answered before this call.
            return .failure(500, "Internal Server Error", error: "misrouted",
                            message: "Route did not need the editor.")
        }
    }


    // MARK: - Exec

    /// Run one parameterized operation. See `AgentExec.swift` for why this goes
    /// to `DocumentCommand`/`FeatureKind` rather than puppeting the interactive
    /// tools: an exec'd model has to be the same model a person would have built.
    ///
    /// UNDO: a feature exec lands as TWO undo steps — the `AppendFeatureCommand`
    /// and the rebuild that evaluates it. `performRebuild` is private to
    /// `DocumentSession`, so bundling them would mean changing production code
    /// to suit a debug channel. Reported as `undoSteps` so a caller unwinding an
    /// exec knows how far back to go instead of guessing.
    private func execute(_ op: AgentExecOp, on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session

        switch op {

        case let .createSketch(name, plane):
            let sketch = Sketch(name: name, plane: plane)
            session.perform(AddSketchCommand(sketch: sketch, title: "Add \(name)"))
            return execOK(viewModel, ["sketchID": sketch.id.raw.uuidString,
                                      "name": name, "undoSteps": 1])

        case let .addEntities(sketchID, entities, constructionIndices):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            // `AddSketchEntitiesCommand` flags the WHOLE batch construction or
            // not, so a mixed batch has to be two commands. Split rather than
            // refuse: a revolve axis is a construction line living in the same
            // sketch as the profile it spins, which is the common case, not an
            // exotic one.
            let normal = entities.enumerated().filter { !constructionIndices.contains($0.offset) }.map(\.element)
            let construction = entities.enumerated().filter { constructionIndices.contains($0.offset) }.map(\.element)
            var steps = 0
            if !normal.isEmpty {
                session.perform(AddSketchEntitiesCommand(sketchID: sketchID, entities: normal))
                steps += 1
            }
            if !construction.isEmpty {
                session.perform(AddSketchEntitiesCommand(
                    sketchID: sketchID, entities: construction, asConstruction: true))
                steps += 1
            }
            session.rebuildForSketchChange(sketchID)
            return execOK(viewModel, [
                "sketchID": sketchID.raw.uuidString,
                "entityIDs": entities.map { $0.id.uuidString },
                "constructionCount": construction.count,
                "undoSteps": steps,
            ])

        case let .extrude(sketchID, seed, distance, symmetric, booleanOp, targets):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            return record(FeatureNode(
                name: "Extrude",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [],
                                        holeEntityIDs: [], seedPoint: seed),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    distance: Expr(value: distance),
                    symmetric: symmetric,
                    boolean: intent,
                    extraProfiles: []),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .revolve(sketchID, seed, axis, angleDegrees, booleanOp, targets):
            guard session.document.sketches.contains(where: { $0.id == sketchID }) else {
                return execMissing("sketch", sketchID.raw.uuidString)
            }
            if let bad = missingBody(targets, session) { return bad }
            let intent = BooleanIntent(op: booleanOp, resolvedTargets: targets.map { bodyRef($0, session) })
            return record(FeatureNode(
                name: "Revolve",
                kind: .revolve(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [],
                                        holeEntityIDs: [], seedPoint: seed),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    axis: AxisRef(source: .explicit(axis)),
                    angle: Expr(value: angleDegrees),
                    boolean: intent),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .pattern(bodyID, spec):
            if let bad = missingBody([bodyID], session) { return bad }
            // count includes the original, so a pattern emits count-1 NEW bodies.
            let outputs = (0..<max(0, spec.count - 1)).map { _ in BodyID() }
            return record(FeatureNode(
                name: spec.kind == .circular ? "Circular Pattern" : "Linear Pattern",
                kind: .pattern(body: bodyRef(bodyID, session), spec: spec),
                outputBodyIDs: outputs), on: viewModel)

        case let .mirror(bodyID, plane, keepOriginal):
            if let bad = missingBody([bodyID], session) { return bad }
            return record(FeatureNode(
                name: "Mirror",
                kind: .mirror(body: bodyRef(bodyID, session),
                              plane: PlaneRef(source: .explicit(plane)),
                              keepOriginal: keepOriginal),
                outputBodyIDs: [BodyID()]), on: viewModel)

        case let .boolean(kindName, target, tools):
            if let bad = missingBody([target] + tools, session) { return bad }
            guard let kind = BooleanKind(rawValue: kindName) else {
                return .failure(400, "Bad Request", error: "unknown_boolean_kind",
                                message: "'\(kindName)' is not a boolean kind.")
            }
            return record(FeatureNode(
                name: kindName.capitalized,
                kind: .boolean(kind: kind,
                               target: bodyRef(target, session),
                               tools: tools.map { bodyRef($0, session) }),
                outputBodyIDs: [BodyID()]), on: viewModel)
        }
    }

    /// Append a node and evaluate it. Reports the eval errors rather than a bare
    /// success: a feature that lands in History but produces no body is exactly
    /// the "silent no-op" failure this bridge exists to make visible.
    private func record(_ node: FeatureNode, on viewModel: EditorViewModel) -> AgentResponse {
        let session = viewModel.session
        // Revisions, not just ids. A boolean REPLACES its target in place, so it
        // adds no new body — reporting "produced nothing" on a subtract that had
        // just removed 4.5 million mm3 was the first thing this endpoint got
        // wrong in real use. What matters is whether the document moved at all.
        var before: [BodyID: UInt64] = [:]
        for body in session.document.bodies { before[body.id] = body.meshRevision }
        session.record(node)
        session.rebuildFrom(node.id)

        var produced: [BodyID] = []
        var changed: [BodyID] = []
        var surviving = Set<BodyID>()
        for body in session.document.bodies {
            surviving.insert(body.id)
            guard let was = before[body.id] else { produced.append(body.id); continue }
            if was != body.meshRevision { changed.append(body.id) }
        }
        let removed = before.keys.filter { !surviving.contains($0) }

        var payload: [String: Any] = [
            "featureID": node.id.raw.uuidString,
            "feature": node.name,
            "producedBodyIDs": produced.map(\.raw.uuidString),
            "changedBodyIDs": changed.map(\.raw.uuidString),
            "removedBodyIDs": removed.map(\.raw.uuidString),
            "undoSteps": 2,
        ]
        // Keyed by feature id, so an agent can tell ITS node failing from an
        // unrelated upstream node that was already broken.
        let errors = session.lastEvalErrors
        if !errors.isEmpty {
            payload["evalErrors"] = Dictionary(uniqueKeysWithValues:
                errors.map { ($0.key.raw.uuidString, String(describing: $0.value)) })
        }

        // THIS node failing is the signal that matters, and it has to be
        // unmissable. `changed` alone cannot carry it: `rebuildFrom` re-emits
        // bodies and bumps `meshRevision` on nodes it did not semantically
        // touch, so a failed feature can still look like it moved something.
        if let mine = errors[node.id] {
            payload["failed"] = true
            payload["message"] = "\(node.name) was recorded but did not build: \(mine). "
                + "For a profile feature the usual cause is a seed point outside any closed region."
        } else if produced.isEmpty && changed.isEmpty && removed.isEmpty {
            payload["warning"] = "The feature was recorded but changed nothing — no body was "
                + "added, modified or removed. For a boolean, check the tools actually "
                + "intersect the target."
        }
        return execOK(viewModel, payload)
    }

    private func bodyRef(_ id: BodyID, _ session: DocumentSession) -> BodyRef {
        let producer = session.document.features.nodes.last { $0.outputBodyIDs.contains(id) }
        return BodyRef(producer: producer?.id ?? FeatureID(), bodyID: id)
    }

    private func missingBody(_ ids: [BodyID], _ session: DocumentSession) -> AgentResponse? {
        let known = Set(session.document.bodies.map(\.id))
        guard let missing = ids.first(where: { !known.contains($0) }) else { return nil }
        return execMissing("body", missing.raw.uuidString)
    }

    private func execMissing(_ what: String, _ id: String) -> AgentResponse {
        .failure(404, "Not Found", error: "unknown_\(what)",
                 message: "No \(what) with id \(id) in this document. GET /v1/state for what exists.")
    }

    /// Every exec reply carries the post-op state, so an agent never needs a
    /// second round trip to see what its own call did.
    private func execOK(_ viewModel: EditorViewModel, _ extra: [String: Any]) -> AgentResponse {
        var payload = snapshot(of: viewModel)
        for (k, v) in extra { payload[k] = v }
        return .ok(payload)
    }

    // MARK: - Geometry health (/v1/check — docs/FREECAD_PLAYBOOK.md D1)

    /// Deep validity report per body. Mesh-only bodies are reported as
    /// `meshOnly` rather than silently skipped — losing the brep somewhere in
    /// a chain is itself a finding, and /v1/state's `brep` flag alone won't
    /// tell you WHICH downstream check you can no longer run.
    private func check(bodyID: String?, runBOPCheck: Bool,
                       on viewModel: EditorViewModel) -> AgentResponse {
        let bodies = viewModel.session.document.bodies
        let targets: [Body]
        if let bodyID {
            guard let uuid = UUID(uuidString: bodyID),
                  let body = bodies.first(where: { $0.id.raw == uuid }) else {
                return execMissing("body", bodyID)
            }
            targets = [body]
        } else {
            targets = bodies
        }
        var invalid = 0
        let rows = targets.map { body -> [String: Any] in
            var row: [String: Any] = [
                "id": body.id.raw.uuidString,
                "name": body.name,
            ]
            if let brep = body.brep {
                let health = OCCTKernel.healthReportDictionary(
                    for: brep, runBOPCheck: runBOPCheck)
                if health["valid"] as? Bool != true { invalid += 1 }
                row["health"] = health
            } else {
                row["meshOnly"] = true
            }
            return row
        }
        return .ok([
            "checked": rows.count,
            "invalid": invalid,
            "bopCheckRequested": runBOPCheck,
            "bodies": rows,
        ])
    }

    // MARK: State snapshot

    /// What the agent can see. Deliberately the same numbers the human sees:
    /// `selectionMeasurements` is exactly what `SelectionInfoBar` renders, so
    /// an agent and a person reading over its shoulder never disagree about
    /// what the model measures.
    private func snapshot(of viewModel: EditorViewModel) -> [String: Any] {
        let document = viewModel.session.document

        let bodies = document.bodies.map { body -> [String: Any] in
            [
                "id": body.id.raw.uuidString,
                "name": body.name,
                "hidden": body.isHidden,
                "volumeMM3": MeasureKit.bodyVolume(body.render, scale: body.transform.scale),
                // Whether this body is still analytic or has been flattened to
                // its tessellation — the distinction the OCCT port exists for.
                "brep": body.brep != nil,
            ]
        }

        let measurements = viewModel.selectionMeasurements.map {
            ["label": $0.label, "value": $0.value]
        }

        var state: [String: Any] = [
            "document": documentName ?? "(unnamed)",
            "mode": Self.modeName(viewModel.mode),
            "platform": AgentRouter.platformName,
            "selection": viewModel.selection.map(\.raw.uuidString),
            "selectedSketchEntities": viewModel.selectedSketchEntityIDs.count,
            "bodies": bodies,
            "sketchCount": document.sketches.count,
            "featureCount": document.features.nodes.count,
            "canUndo": viewModel.session.undoStack.canUndo,
            "canRedo": viewModel.session.undoStack.canRedo,
            "measurements": measurements,
            "commandSearchActive": viewModel.commandSearchActive,
        ]
        if let title = viewModel.session.undoStack.undoTitle { state["undoTitle"] = title }
        if let error = viewModel.errorMessage { state["error"] = error }
        // Per-feature replay failures — the same signal the History badges
        // render. `error` above is the one-shot interactive alert; this is the
        // persistent graph state, so an agent that drove the UI (not /v1/exec)
        // can still see WHICH feature failed without a second channel.
        let evalErrors = viewModel.session.lastEvalErrors
        if !evalErrors.isEmpty {
            state["evalErrors"] = document.features.nodes.compactMap { node -> [String: String]? in
                guard let err = evalErrors[node.id] else { return nil }
                return [
                    "featureID": node.id.raw.uuidString,
                    "feature": node.name,
                    "error": String(describing: err),
                ]
            }
        }
        return state
    }

    /// Case name only, derived rather than switched.
    ///
    /// `EditorMode` has north of twenty cases and gains more with every tool;
    /// a hand-written switch here would be a second list to forget to update,
    /// and its failure mode is reporting a stale mode name — which is worse
    /// than useless to an agent deciding what to do next. `String(describing:)`
    /// cannot go stale.
    static func modeName(_ mode: EditorMode) -> String {
        let described = String(describing: mode)
        return described.split(separator: "(").first.map(String.init) ?? described
    }
}

#endif
