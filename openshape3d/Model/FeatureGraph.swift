//
//  FeatureGraph.swift
//  openshape3d
//
//  Phase D (Task B1) — the parametric history ENGINE. A `FeatureGraph` is an
//  ordered list of editable `FeatureNode`s; `evaluate` replays them in order into
//  a live set of bodies + per-body `FaceTable`s, reproducing exactly the geometry
//  the live tools build (primitive → mesh, profile → extrude → boolean, planar
//  face push/pull) so that editing any step's parameter and re-evaluating
//  rebuilds everything downstream — including re-resolving a persisted `FaceRef`
//  against the freshly rebuilt geometry (the topological-naming payoff).
//
//  Everything here is `nonisolated` pure geometry, replayed off the main actor
//  and round-tripped through the SwiftData store as JSON. Model space is Double;
//  every emitted `Body` gets a FRESH `meshRevision` from `nextRevision()` so the
//  GPU cache invalidates, and reuses `node.outputBodyIDs` (never mints a new
//  `BodyID` on rebuild) so selection / transform / material survive an edit.
//
//  Tranche 1 EVALUATES `.primitive`, `.extrude`, `.boolean`, and
//  `.pushPull(.planarAxial)`. The remaining kinds are DEFINED (so the graph type
//  is total and Codable) but return `.kernelFailure` from `evaluate` rather than
//  building geometry — they are recorded/evaluated in tranche 2.
//

import Foundation
import simd
import Euclid

// MARK: - Placeholder value types (tranche-2 payloads)

/// Linear/circular 3D body-pattern descriptor (tranche 4). `count` is the TOTAL
/// number of instances including the original, so a pattern EMITS `count − 1`
/// copies; `axis` is the linear direction or the circular rotation axis (world);
/// `totalAngle` is the circular first→last sweep in RADIANS.
nonisolated struct PatternSpec: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case linear, circular }
    var kind: Kind
    var axis: SIMD3<Double>       // linear: direction; circular: rotation axis (world)
    var count: Int                // TOTAL instances incl. the original (>=1)
    var spacing: Double           // linear: adjacent-center distance
    var totalAngle: Double        // circular: first->last sweep in RADIANS
    var rotateInstances: Bool

    init(
        kind: Kind = .linear,
        axis: SIMD3<Double> = SIMD3(1, 0, 0),
        count: Int = 1,
        spacing: Double = 0,
        totalAngle: Double = 2 * .pi,
        rotateInstances: Bool = true
    ) {
        self.kind = kind
        self.axis = axis
        self.count = count
        self.spacing = spacing
        self.totalAngle = totalAngle
        self.rotateInstances = rotateInstances
    }
}

/// A Codable/Hashable wrapper around a 3D point so `FeatureKind.sweep`'s spine is
/// a plain `[PointWrapper]` (kept a struct so tranche-2 can extend it).
nonisolated struct PointWrapper: Codable, Hashable, Sendable {
    var point: SIMD3<Double>
    init(_ point: SIMD3<Double>) { self.point = point }
}

// MARK: - Feature kinds / nodes / graph (frozen contract)

/// One editable operation in the history. Tranche 1 records/evaluates
/// `primitive`, `extrude`, `boolean`, `pushPull(.planarAxial)`; the rest are
/// defined for schema stability and evaluated in tranche 2.
nonisolated enum FeatureKind: Codable, Sendable {
    case primitive(spec: PrimitiveSpec, placement: Transform3D)
    case extrude(
        profile: ProfileRef,
        plane: PlaneRef,
        distance: Expr,
        symmetric: Bool,
        boolean: BooleanIntent,
        extraProfiles: [ProfileRef]
    )
    case revolve(profile: ProfileRef, plane: PlaneRef, axis: AxisRef, angle: Expr, boolean: BooleanIntent)
    case sweep(profile: ProfileRef, plane: PlaneRef, spine: [PointWrapper], boolean: BooleanIntent)
    case loft(sections: [ProfileRef], boolean: BooleanIntent)
    case boolean(kind: BooleanKind, target: BodyRef, tools: [BodyRef])
    case transform(body: BodyRef, delta: Transform3D)
    case mirror(body: BodyRef, plane: PlaneRef, keepOriginal: Bool)
    case pattern(body: BodyRef, spec: PatternSpec)
    case pushPull(face: FaceRef, distance: Expr, mode: PushPullMode)
    /// Phase E: bevel the referenced convex edges of `body` by a flat `setback`.
    case chamfer(body: BodyRef, edges: [EdgeRef], setback: Expr)
    /// Phase E: round the referenced convex edges of `body` to `radius`.
    case fillet(body: BodyRef, edges: [EdgeRef], radius: Expr)
}

/// A node in the feature graph: stable identity, display name, its operation, a
/// suppress flag, and the `BodyID`s it owns (minted once, reused every rebuild).
nonisolated struct FeatureNode: Codable, Identifiable, Sendable {
    let id: FeatureID
    var name: String
    var kind: FeatureKind
    var suppressed: Bool
    var outputBodyIDs: [BodyID]

    init(
        id: FeatureID = FeatureID(),
        name: String,
        kind: FeatureKind,
        suppressed: Bool = false,
        outputBodyIDs: [BodyID]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.suppressed = suppressed
        self.outputBodyIDs = outputBodyIDs
    }
}

nonisolated extension FeatureNode {
    /// Every sketch this node reads — the union of its profile/extra-profile/loft-
    /// section `ProfileRef.sketchID`s, its `PlaneRef.sketch(sid)` build plane, and
    /// its `AxisRef.sketchLine(sid,_)` axis. `DocumentSession.rebuildForSketchChange`
    /// uses this to skip nodes a given sketch edit does not touch.
    var referencedSketchIDs: Set<SketchID> {
        var ids = Set<SketchID>()
        func addPlane(_ ref: PlaneRef) {
            if case let .sketch(sid) = ref.source { ids.insert(sid) }
        }
        func addAxis(_ ref: AxisRef) {
            if case let .sketchLine(sid, _) = ref.source { ids.insert(sid) }
        }
        switch kind {
        case let .extrude(profile, plane, _, _, _, extraProfiles):
            ids.insert(profile.sketchID)
            for extra in extraProfiles { ids.insert(extra.sketchID) }
            addPlane(plane)
        case let .revolve(profile, plane, axis, _, _):
            ids.insert(profile.sketchID)
            addPlane(plane)
            addAxis(axis)
        case let .sweep(profile, plane, _, _):
            ids.insert(profile.sketchID)
            addPlane(plane)
        case let .loft(sections, _):
            for ref in sections { ids.insert(ref.sketchID) }
        case let .mirror(_, plane, _):
            addPlane(plane)
        case .primitive, .boolean, .transform, .pattern, .pushPull,
             .chamfer, .fillet:
            break
        }
        return ids
    }
}

/// The ordered feature history. `evaluate` is a pure function of the graph plus
/// the sketches/planes the profiles/planes reference.
nonisolated struct FeatureGraph: Codable, Sendable {
    var nodes: [FeatureNode]
    /// Rollback marker: the number of ACTIVE (leading) nodes. `nil` = every node
    /// active; `k` = `nodes[0..<k]` active, nodes at/after `k` rolled back (not
    /// evaluated → their bodies are removed). Synthesized Codable decodes this via
    /// `decodeIfPresent`, so pre-rollback blobs load with `rollbackIndex == nil`.
    var rollbackIndex: Int? = nil

    init(nodes: [FeatureNode] = [], rollbackIndex: Int? = nil) {
        self.nodes = nodes
        self.rollbackIndex = rollbackIndex
    }

    /// The node with `id`, if present.
    func node(_ id: FeatureID) -> FeatureNode? {
        nodes.first { $0.id == id }
    }

    /// Index of the node with `id`, if present.
    func index(of id: FeatureID) -> Int? {
        nodes.firstIndex { $0.id == id }
    }
}

// MARK: - Evaluation result

/// Why a node failed to build. `evaluate` records these per node and keeps
/// going; a failed node simply emits no geometry (the graph stays total).
nonisolated enum FeatureError: Sendable, Equatable {
    /// A referenced body / profile / plane / face could not be resolved.
    case brokenRef(String)
    /// The operation ran but produced an empty mesh.
    case emptyGeometry
    /// The kernel op failed or is not implemented in this tranche.
    case kernelFailure(String)
}

/// The output of replaying a `FeatureGraph`: the live bodies (in creation order),
/// their face tables, and any per-node errors.
nonisolated struct EvalResult: Sendable {
    var bodies: [Body]
    var faceTables: [BodyID: FaceTable]
    var errors: [FeatureID: FeatureError]

    init(
        bodies: [Body] = [],
        faceTables: [BodyID: FaceTable] = [:],
        errors: [FeatureID: FeatureError] = [:]
    ) {
        self.bodies = bodies
        self.faceTables = faceTables
        self.errors = errors
    }
}

// MARK: - The replay engine

nonisolated extension FeatureGraph {

    /// Replay every non-suppressed node in order, building the document geometry.
    ///
    /// - Parameters:
    ///   - sketches: sketches the `ProfileRef`/`PlaneRef`s resolve against.
    ///   - planes: construction planes a `PlaneRef.construction` resolves against.
    ///   - naming: the topological-naming strategy (labels faces, propagates
    ///     labels through booleans/push-pull, re-resolves persisted `FaceRef`s).
    ///   - nextRevision: mints a monotonically fresh `meshRevision` per emitted
    ///     body so the GPU/render caches invalidate.
    func evaluate(
        sketches: [Sketch],
        planes: [ConstructionPlane],
        naming: TopoNaming,
        nextRevision: () -> UInt64
    ) -> EvalResult {
        var state = EvalState(sketches: sketches, planes: planes, naming: naming)

        // Replay only the active prefix: nodes at/after the rollback marker are not
        // evaluated (their bodies never enter the live set). `prefix` clamps to the
        // node count, so an out-of-range marker is safe. `nil` = all nodes active.
        for node in nodes.prefix(rollbackIndex ?? nodes.count) where !node.suppressed {
            evaluate(node, into: &state, nextRevision: nextRevision)
        }

        return EvalResult(
            bodies: state.order.compactMap { state.bodies[$0] },
            faceTables: state.faceTables,
            errors: state.errors
        )
    }

    // MARK: Per-node dispatch

    private func evaluate(
        _ node: FeatureNode,
        into state: inout EvalState,
        nextRevision: () -> UInt64
    ) {
        switch node.kind {
        case let .primitive(spec, placement):
            evalPrimitive(node, spec: spec, placement: placement, into: &state, next: nextRevision)
        case let .extrude(profile, plane, distance, symmetric, boolean, extraProfiles):
            evalExtrude(
                node, profileRef: profile, planeRef: plane, distance: distance,
                symmetric: symmetric, boolean: boolean, extraProfileRefs: extraProfiles,
                into: &state, next: nextRevision)
        case let .boolean(kind, target, tools):
            evalBoolean(node, kind: kind, target: target, tools: tools, into: &state, next: nextRevision)
        case let .pushPull(face, distance, mode):
            evalPushPull(node, face: face, distance: distance, mode: mode, into: &state, next: nextRevision)
        case let .revolve(profile, plane, axis, angle, boolean):
            evalRevolve(
                node, profileRef: profile, planeRef: plane, axisRef: axis,
                angle: angle, boolean: boolean, into: &state, next: nextRevision)
        case let .sweep(profile, plane, spine, boolean):
            evalSweep(
                node, profileRef: profile, planeRef: plane, spine: spine,
                boolean: boolean, into: &state, next: nextRevision)
        case let .loft(sections, boolean):
            evalLoft(node, sectionRefs: sections, boolean: boolean, into: &state, next: nextRevision)
        case let .mirror(body, plane, keepOriginal):
            evalMirror(
                node, bodyRef: body, planeRef: plane, keepOriginal: keepOriginal,
                into: &state, next: nextRevision)
        case let .pattern(body, spec):
            evalPattern(node, bodyRef: body, spec: spec, into: &state, next: nextRevision)
        case let .chamfer(body, edges, setback):
            evalEdgeBlend(
                node, bodyRef: body, edgeRefs: edges, amount: setback.value,
                isFillet: false, into: &state, next: nextRevision)
        case let .fillet(body, edges, radius):
            evalEdgeBlend(
                node, bodyRef: body, edgeRefs: edges, amount: radius.value,
                isFillet: true, into: &state, next: nextRevision)

        // Defined but not evaluated yet — keep the graph total.
        case .transform:
            state.errors[node.id] = .kernelFailure("transform evaluation is tranche 2")
        }
    }

    // MARK: Primitive

    private func evalPrimitive(
        _ node: FeatureNode,
        spec: PrimitiveSpec,
        placement: Transform3D,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let id = node.outputBodyIDs.first else {
            state.errors[node.id] = .brokenRef("primitive node has no output BodyID")
            return
        }
        // Same path the app uses (Euclid.Mesh.primitive), then bake the placement
        // so body-local space == the coordinate space every downstream op (and the
        // face signatures) works in. Body transform stays identity in tranche 1.
        var mesh = Euclid.Mesh.primitive(spec)
        if placement != .identity {
            mesh = mesh.transformed(by: placement.euclid)
        }
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let body = Body(
            id: id, name: node.name, transform: .identity,
            primitive: placement == .identity ? spec : nil,
            euclidMesh: mesh, revision: nextRevision())
        let table = state.naming.faceTable(for: body, createdBy: node.id, scheme: .primitive(spec))
        state.put(body, table: table)
    }

    // MARK: Extrude

    private func evalExtrude(
        _ node: FeatureNode,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        distance: Expr,
        symmetric: Bool,
        boolean: BooleanIntent,
        extraProfileRefs: [ProfileRef],
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("extrude plane unresolved")
            return
        }
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("extrude profile unresolved")
            return
        }

        // Resolve extra profiles once; both the new-body and the cut paths use them.
        var extras: [(profile: Profile, holes: [Profile])] = []
        for ref in extraProfileRefs {
            guard let (extra, extraHoles) = state.resolveProfile(ref) else {
                state.errors[node.id] = .brokenRef("extrude extra profile unresolved")
                return
            }
            extras.append((profile: extra, holes: extraHoles))
        }

        if boolean.op == .newBody {
            // New body: FLUSH prisms unioned — exact as-drawn geometry.
            var solid = KernelOps.extrude(
                profile: outer, holes: holes, in: plane, distance: distance.value, symmetric: symmetric)
            for extra in extras {
                solid = solid.union(KernelOps.extrude(
                    profile: extra.profile, holes: extra.holes, in: plane,
                    distance: distance.value, symmetric: symmetric))
            }
            guard !solid.polygons.isEmpty else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            guard let id = node.outputBodyIDs.first else {
                state.errors[node.id] = .brokenRef("extrude node has no output BodyID")
                return
            }
            let body = Body(
                id: id, name: node.name, transform: .identity, primitive: nil,
                euclidMesh: solid, revision: nextRevision())
            let table = state.naming.faceTable(for: body, createdBy: node.id, scheme: .extrude(outer))
            state.put(body, table: table)
            return
        }

        // Boolean-into-target: the extrude modifies an existing body in place.
        guard let kind = boolean.op.kernelKind else {
            state.errors[node.id] = .kernelFailure("unsupported boolean op")
            return
        }
        guard let targetRef = boolean.resolvedTargets.first,
              let target = state.bodies[targetRef.bodyID] else {
            state.errors[node.id] = .brokenRef("extrude boolean target unresolved")
            return
        }
        // Use the OVERLAPPED (padded) tool — exactly what the live extrude-cut
        // uses — so coplanar / flush cut faces merge cleanly instead of leaving
        // hanging thin walls. A flush prism here would diverge from the tool.
        let toolMesh = KernelOps.overlapExtrudeTool(
            profile: outer, holes: holes, extraProfiles: extras,
            in: plane, distance: distance.value, symmetric: symmetric)
        guard !toolMesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        // The tool prism, wrapped identity so KernelOps.boolean bakes no extra
        // transform (mesh already lives in the shared world space).
        let toolBody = Body(
            id: BodyID(), name: "\(node.name) tool", transform: .identity, primitive: nil,
            euclidMesh: toolMesh, revision: 0)
        let toolTable = state.naming.faceTable(for: toolBody, createdBy: node.id, scheme: .extrude(outer))
        let resultMesh = KernelOps.boolean(kind, target: target, tool: toolBody)
        guard !resultMesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: target.id, name: target.name, transform: .identity, primitive: nil,
            euclidMesh: resultMesh, revision: nextRevision())
        let inputTables = [state.faceTables[target.id], toolTable].compactMap { $0 }
        let table = state.naming.propagate(inputs: inputTables, output: result, op: .boolean(kind))
        state.put(result, table: table)
    }

    // MARK: Boolean

    private func evalBoolean(
        _ node: FeatureNode,
        kind: BooleanKind,
        target targetRef: BodyRef,
        tools toolRefs: [BodyRef],
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let target = state.bodies[targetRef.bodyID] else {
            state.errors[node.id] = .brokenRef("boolean target unresolved")
            return
        }
        var acc = target
        var inputTables: [FaceTable] = state.faceTables[target.id].map { [$0] } ?? []
        var consumed: [BodyID] = []

        for toolRef in toolRefs {
            guard let tool = state.bodies[toolRef.bodyID] else {
                state.errors[node.id] = .brokenRef("boolean tool unresolved")
                return
            }
            if let t = state.faceTables[tool.id] { inputTables.append(t) }
            let mesh = KernelOps.boolean(kind, target: acc, tool: tool)
            guard !mesh.polygons.isEmpty else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            acc = Body(
                id: target.id, name: target.name, transform: .identity, primitive: nil,
                euclidMesh: mesh, revision: nextRevision())
            consumed.append(tool.id)
        }

        // Remove the consumed tool bodies from the live set.
        for id in consumed { state.remove(id) }

        let table = state.naming.propagate(inputs: inputTables, output: acc, op: .boolean(kind))
        state.put(acc, table: table)
    }

    // MARK: Push/pull

    private func evalPushPull(
        _ node: FeatureNode,
        face: FaceRef,
        distance: Expr,
        mode: PushPullMode,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard mode == .planarAxial else {
            state.errors[node.id] = .kernelFailure("pushPull(.cylinderRadial) is tranche 2")
            return
        }
        guard let body = state.bodies[face.body.bodyID] else {
            state.errors[node.id] = .brokenRef("pushPull body unresolved")
            return
        }
        // Re-resolve the persisted FaceRef against the (possibly rebuilt) body —
        // this is the topological-naming step that lets the pushed face follow the
        // geometry after an upstream edit.
        let table = state.faceTables[body.id]
        guard let resolved = state.naming.resolve(face, in: body, table: table),
              let planar = resolved.planar else {
            state.errors[node.id] = .brokenRef("pushPull face did not resolve")
            return
        }
        let mesh = KernelOps.pushPullPlanarFace(
            mesh: body.euclidMesh(), face: planar, distance: distance.value)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: .identity, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        // Carry the old labels forward through the push/pull.
        let newTable: FaceTable
        if let table {
            newTable = state.naming.propagate(inputs: [table], output: result, op: .pushPull)
        } else {
            newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        }
        state.put(result, table: newTable)
    }

    // MARK: Chamfer / Fillet (edge blends)

    /// Resolve each persisted `EdgeRef` against the input body's rebuilt edges
    /// and remove/round the corner. Refs resolve against the INPUT body because
    /// the blend destroys the very edges it names. Non-convex or unresolved edges
    /// are skipped; if none resolve the node errors so History shows a badge.
    private func evalEdgeBlend(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        edgeRefs: [EdgeRef],
        amount: Double,
        isFillet: Bool,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard amount > 1e-6 else {
            state.errors[node.id] = .kernelFailure("blend amount must be positive")
            return
        }
        guard let body = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("blend body unresolved")
            return
        }
        let available = EdgeTopology.selectableEdges(from: body.render)
        let aabb = body.render.localAABB
        let scale = Double(simd_length(aabb.max - aabb.min))

        func d3(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3(Double(v.x), Double(v.y), Double(v.z))
        }

        var mesh = body.euclidMesh()
        var resolvedAny = false
        for ref in edgeRefs {
            guard let edge = EdgeTopology.resolve(
                ref.signature, in: available, sizeScale: scale), edge.isConvex
            else { continue }
            let p0 = d3(edge.start), p1 = d3(edge.end)
            let nA = d3(edge.normalA), nB = d3(edge.normalB)
            mesh = isFillet
                ? KernelOps.filletEdge(mesh: mesh, p0: p0, p1: p1, normalA: nA, normalB: nB, radius: amount)
                : KernelOps.chamferEdge(mesh: mesh, p0: p0, p1: p1, normalA: nA, normalB: nB, setback: amount)
            resolvedAny = true
        }
        guard resolvedAny else {
            state.errors[node.id] = .brokenRef("no blend edge resolved")
            return
        }
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: .identity, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        // A blend changes face count/areas; relabel by geometry. Downstream
        // FaceRefs re-resolve by signature scoring against the surviving faces.
        let table = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        state.put(result, table: table)
    }

    // MARK: Revolve / Sweep / Loft (full-solid ops)

    /// Emit a freshly built world-space `mesh` as either a NEW body or a boolean
    /// into an existing target. Unlike extrude's cut (which uses a padded overlap
    /// prism), revolve/sweep/loft merge the FULL solid: the tool is `mesh` wrapped
    /// in an identity `Body` and fed straight to `KernelOps.boolean`.
    private func emitFullSolid(
        _ node: FeatureNode,
        mesh: Euclid.Mesh,
        boolean: BooleanIntent,
        scheme: FaceScheme,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }

        if boolean.op == .newBody {
            guard let id = node.outputBodyIDs.first else {
                state.errors[node.id] = .brokenRef("node has no output BodyID")
                return
            }
            let body = Body(
                id: id, name: node.name, transform: .identity, primitive: nil,
                euclidMesh: mesh, revision: nextRevision())
            let table = state.naming.faceTable(for: body, createdBy: node.id, scheme: scheme)
            state.put(body, table: table)
            return
        }

        guard let kind = boolean.op.kernelKind else {
            state.errors[node.id] = .kernelFailure("unsupported boolean op")
            return
        }
        guard let targetRef = boolean.resolvedTargets.first,
              let target = state.bodies[targetRef.bodyID] else {
            state.errors[node.id] = .brokenRef("boolean target unresolved")
            return
        }
        // The full solid, wrapped identity so KernelOps.boolean bakes no extra
        // transform (mesh already lives in the shared world space).
        let toolBody = Body(
            id: BodyID(), name: "\(node.name) tool", transform: .identity, primitive: nil,
            euclidMesh: mesh, revision: 0)
        let toolTable = state.naming.faceTable(for: toolBody, createdBy: node.id, scheme: scheme)
        let resultMesh = KernelOps.boolean(kind, target: target, tool: toolBody)
        guard !resultMesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: target.id, name: target.name, transform: .identity, primitive: nil,
            euclidMesh: resultMesh, revision: nextRevision())
        let inputTables = [state.faceTables[target.id], toolTable].compactMap { $0 }
        let table = state.naming.propagate(inputs: inputTables, output: result, op: .boolean(kind))
        state.put(result, table: table)
    }

    private func evalRevolve(
        _ node: FeatureNode,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        axisRef: AxisRef,
        angle: Expr,
        boolean: BooleanIntent,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("revolve plane unresolved")
            return
        }
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("revolve profile unresolved")
            return
        }
        guard let axis = state.resolveAxis(axisRef) else {
            state.errors[node.id] = .brokenRef("revolve axis unresolved")
            return
        }
        // KernelOps.revolve returns an EMPTY mesh when the profile crosses/collapses
        // onto the axis — emitFullSolid maps that to .emptyGeometry.
        let mesh = KernelOps.revolve(
            profile: outer, holes: holes, in: plane, axis: axis, angle: angle.value)
        emitFullSolid(node, mesh: mesh, boolean: boolean, scheme: .revolve, into: &state, next: nextRevision)
    }

    private func evalSweep(
        _ node: FeatureNode,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        spine: [PointWrapper],
        boolean: BooleanIntent,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("sweep plane unresolved")
            return
        }
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("sweep profile unresolved")
            return
        }
        let spinePts = spine.map(\.point)   // WORLD-space 3D points
        let mesh = SweepLoftKit.sweep(profile: outer, holes: holes, in: plane, alongPath: spinePts)
        emitFullSolid(node, mesh: mesh, boolean: boolean, scheme: .generic, into: &state, next: nextRevision)
    }

    private func evalLoft(
        _ node: FeatureNode,
        sectionRefs: [ProfileRef],
        boolean: BooleanIntent,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        // Resolve each section's profile (outer + holes) AND its plane, in order.
        // ANY unresolvable section is a broken reference: error out rather than
        // silently lofting a subset (e.g. deleting a middle section's sketch must
        // surface a broken-ref badge, not reshape the body into an A->C loft the
        // user never authored). Matches revolve/sweep/mirror's error contract.
        var sections: [(profile: Profile, holes: [Profile], plane: SketchPlane)] = []
        for ref in sectionRefs {
            guard let (outer, holes) = state.resolveProfile(ref),
                  let plane = state.resolvePlane(PlaneRef(source: .sketch(ref.sketchID))) else {
                state.errors[node.id] = .brokenRef("loft section profile/plane unresolved")
                return
            }
            sections.append((outer, holes, plane))
        }
        guard sections.count >= 2 else {
            state.errors[node.id] = .brokenRef("loft needs >= 2 sections")
            return
        }
        let mesh = SweepLoftKit.loft(profiles: sections)
        emitFullSolid(node, mesh: mesh, boolean: boolean, scheme: .generic, into: &state, next: nextRevision)
    }

    // MARK: Mirror

    private func evalMirror(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        planeRef: PlaneRef,
        keepOriginal: Bool,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let input = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("mirror body unresolved")
            return
        }
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("mirror plane unresolved")
            return
        }
        // Reflect the input in world space (its transform is identity in replay,
        // but bake it in to stay correct if that ever changes).
        let worldInput = input.euclidMesh().transformed(by: input.transform.euclid)
        let mirrored = KernelOps.mirror(mesh: worldInput, across: plane)
        guard !mirrored.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        guard let id = node.outputBodyIDs.first else {
            state.errors[node.id] = .brokenRef("mirror node has no output BodyID")
            return
        }
        // keepOriginal is effectively true in v1: the mirror node only ADDS its own
        // output body; the source stays put (never removed here).
        let body = Body(
            id: id, name: node.name, transform: .identity, primitive: nil,
            euclidMesh: mirrored, revision: nextRevision())
        let table = state.naming.faceTable(for: body, createdBy: node.id, scheme: .generic)
        state.put(body, table: table)
    }

    // MARK: Pattern

    /// Linear/circular body pattern. The source body (already in `state`) stays
    /// PUT; the pattern only ADDS `count − 1` copies. Each copy reuses one of the
    /// node's pre-allocated `outputBodyIDs` (the recording/edit layer owns id
    /// allocation — never mint here), carries the composed instance transform, and
    /// reuses the source's LOCAL mesh (the app's live pattern does the same:
    /// copy transform = composed(instanceₙ, base: source.transform), mesh = source
    /// local mesh). If fewer `outputBodyIDs` are supplied than copies are needed,
    /// only the ids we have are emitted.
    private func evalPattern(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        spec: PatternSpec,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let source = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("pattern body unresolved")
            return
        }
        // Instance transforms; element 0 is identity (the original / source body,
        // which is NOT re-emitted). Matches EditorViewModel.patternTransforms.
        let transforms: [Transform3D]
        switch spec.kind {
        case .linear:
            transforms = PatternKit.linearTransforms(
                direction: spec.axis, spacing: spec.spacing, count: max(1, spec.count))
        case .circular:
            transforms = PatternKit.circularTransforms(
                center: .zero, axis: spec.axis, count: max(1, spec.count),
                totalAngle: spec.totalAngle, rotateInstances: spec.rotateInstances)
        }

        let localMesh = source.euclidMesh()  // source stays put; copies reuse its local mesh
        for i in 1..<transforms.count {
            let idIndex = i - 1
            guard idIndex < node.outputBodyIDs.count else { break } // never mint ids in eval
            let copy = Body(
                id: node.outputBodyIDs[idIndex],
                name: node.name,
                transform: Self.composePatternTransform(transforms[i], base: source.transform),
                primitive: nil,
                euclidMesh: localMesh,
                revision: nextRevision())
            let table = state.naming.faceTable(for: copy, createdBy: node.id, scheme: .generic)
            state.put(copy, table: table)
        }
    }

    /// Compose a pattern instance transform onto the source's base transform:
    /// world = pattern.rotation.act(base(x)) + pattern.translation, so rotation
    /// and translation pre-compose. Mirrors
    /// `EditorViewModel.composedPatternTransform` (kept here so eval stays
    /// `nonisolated` and free of the Editor layer).
    private static func composePatternTransform(
        _ pattern: Transform3D, base: Transform3D
    ) -> Transform3D {
        var result = base
        result.rotation = simd_normalize(pattern.rotation * base.rotation)
        result.translation = pattern.rotation.act(base.translation) + pattern.translation
        return result
    }
}

// MARK: - Live evaluation state

/// Mutable replay state: the live bodies (with a stable creation order), their
/// face tables, accumulated errors, and the sketch/plane inputs + resolvers.
private struct EvalState {
    let sketches: [Sketch]
    let planes: [ConstructionPlane]
    let naming: TopoNaming

    var bodies: [BodyID: Body] = [:]
    var order: [BodyID] = []
    var faceTables: [BodyID: FaceTable] = [:]
    var errors: [FeatureID: FeatureError] = [:]

    /// Insert or replace a body (keeping its slot on replace) with its face table.
    mutating func put(_ body: Body, table: FaceTable) {
        if bodies[body.id] == nil { order.append(body.id) }
        bodies[body.id] = body
        faceTables[body.id] = table
    }

    /// Remove a consumed body from the live set.
    mutating func remove(_ id: BodyID) {
        bodies[id] = nil
        faceTables[id] = nil
        order.removeAll { $0 == id }
    }

    // MARK: Reference resolution

    /// A `PlaneRef` → concrete `SketchPlane`.
    func resolvePlane(_ ref: PlaneRef) -> SketchPlane? {
        switch ref.source {
        case let .sketch(sid):
            return sketch(sid)?.plane
        case let .construction(cid):
            return planes.first { $0.id == cid }?.plane
        case .ground:
            return .ground
        case let .explicit(plane):
            return plane
        }
    }

    /// A `ProfileRef` → the outer `Profile` plus its hole profiles, detected from
    /// the referenced sketch. Matches the outer loop by entity ids (falling back
    /// to the seed point) and each hole loop by its recorded entity ids.
    func resolveProfile(_ ref: ProfileRef) -> (outer: Profile, holes: [Profile])? {
        guard let sketch = sketch(ref.sketchID) else { return nil }
        let detected = ProfileDetector.detectProfiles(in: sketch)
        guard !detected.isEmpty else { return nil }

        let wanted = Set(ref.entityIDs)
        var outer: Profile?
        if !wanted.isEmpty {
            outer = detected.first { $0.sourceEntityIDs == wanted }
                ?? detected.first { wanted.isSubset(of: $0.sourceEntityIDs) }
        }
        if outer == nil, let seed = ref.seedPoint {
            // Innermost enclosing region at the seed point.
            outer = ProfileDetector.profiles(at: seed, in: sketch).first
        }
        guard let outer else { return nil }

        var holes: [Profile] = []
        if ref.holeEntityIDs.isEmpty {
            // No explicit holes recorded — nothing to punch.
            holes = []
        } else {
            for group in ref.holeEntityIDs {
                let ids = Set(group)
                if let hole = detected.first(where: { $0.sourceEntityIDs == ids })
                    ?? detected.first(where: { ids.isSubset(of: $0.sourceEntityIDs) && $0.id != outer.id }) {
                    holes.append(hole)
                }
            }
        }
        return (outer, holes)
    }

    /// An `AxisRef` → a plane-local `RevolveAxis`. `.explicit` passes through;
    /// `.sketchLine` finds the named `.line` entity in the referenced sketch and
    /// builds an axis from its endpoints: point = a, direction = b − a.
    func resolveAxis(_ ref: AxisRef) -> RevolveAxis? {
        switch ref.source {
        case let .explicit(axis):
            return axis
        case let .sketchLine(sid, entityID):
            guard let sketch = sketch(sid) else { return nil }
            for entity in sketch.entities {
                if case let .line(id, a, b) = entity, id == entityID {
                    return RevolveAxis(point: a, direction: b - a)
                }
            }
            return nil
        }
    }

    private func sketch(_ id: SketchID) -> Sketch? {
        sketches.first { $0.id == id }
    }
}

// MARK: - Small mappings

private extension BooleanIntent.Op {
    /// The kernel boolean for this intent, or nil for `.newBody`.
    var kernelKind: BooleanKind? {
        switch self {
        case .newBody: return nil
        case .union: return .union
        case .subtract: return .subtract
        case .intersect: return .intersect
        }
    }
}

// MARK: - Conformance bridge for a reused kernel type
//
// `FeatureKind.boolean(kind: BooleanKind, …)` needs `BooleanKind` (a String raw
// enum in EditorMode.swift) to be Codable so `FeatureKind` synthesizes Codable.
// RawRepresentable-with-Codable-RawValue gives the encode/decode for free; the
// conformance just has to be stated. (It is already Sendable-usable — TopoOp
// wraps it — so only Codable is added here.)
nonisolated extension BooleanKind: Codable {}
