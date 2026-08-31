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
