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

/// Minimal pattern descriptor so `FeatureKind.pattern` is Codable now; the real
/// linear/circular pattern spec + evaluation lands in tranche 2.
nonisolated struct PatternSpec: Codable, Hashable, Sendable {
    var count: Int
    var offset: SIMD3<Double>
    init(count: Int = 1, offset: SIMD3<Double> = .zero) {
        self.count = count
        self.offset = offset
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

/// The ordered feature history. `evaluate` is a pure function of the graph plus
/// the sketches/planes the profiles/planes reference.
nonisolated struct FeatureGraph: Codable, Sendable {
    var nodes: [FeatureNode]

    init(nodes: [FeatureNode] = []) { self.nodes = nodes }

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

        for node in nodes where !node.suppressed {
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

        // Defined but not evaluated in tranche 1 — keep the graph total.
        case .revolve:
            state.errors[node.id] = .kernelFailure("revolve evaluation is tranche 2")
        case .sweep:
            state.errors[node.id] = .kernelFailure("sweep evaluation is tranche 2")
        case .loft:
            state.errors[node.id] = .kernelFailure("loft evaluation is tranche 2")
        case .transform:
            state.errors[node.id] = .kernelFailure("transform evaluation is tranche 2")
        case .mirror:
            state.errors[node.id] = .kernelFailure("mirror evaluation is tranche 2")
        case .pattern:
            state.errors[node.id] = .kernelFailure("pattern evaluation is tranche 2")
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
