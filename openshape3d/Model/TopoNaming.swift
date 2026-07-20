//
//  TopoNaming.swift
//  openshape3d
//
//  Topological-naming facade (Phase D, task A2). A `TopoNaming` labels the faces
//  of a freshly built body with stable `FaceRole`s + geometric `FaceSignature`s,
//  propagates those labels through booleans/transforms/push-pull, and — the point
//  of the whole exercise — re-resolves a persisted `FaceRef` back to a concrete
//  face after the owning feature is rebuilt with different parameters.
//
//  Tranche 1 ships the geometric `SignatureNaming`: a face is identified by its
//  normal + centroid + area, so a `FaceRef` survives a rebuild that moves/grows
//  the face (a bigger box's +Z face is still the +Z face). `MaterialTagNaming`
//  (O(1) tag lookup) is a tranche-2 swap behind this same facade.
//
//  All types are `nonisolated` (pure geometry, off the main actor) per repo
//  convention. Face signatures are computed in BODY-LOCAL space (`body.render`),
//  consistent between `faceTable` and `resolve`; `body.transform` is intentionally
//  ignored in tranche 1 (transform features are a tranche-2 concern).
//

import Foundation
import simd

// MARK: - Facade types (frozen contract)

/// The per-body label table produced when a feature builds a body: one entry per
/// enumerated face carrying its role, geometric signature, and triangle indices.
nonisolated struct FaceTable: Codable, Sendable {
    var entries: [Entry]

    struct Entry: Codable, Sendable {
        var role: FaceRole
        var signature: FaceSignature
        var triangles: [Int]
    }

    init(entries: [Entry] = []) { self.entries = entries }
}

/// How a body was built — drives which `FaceRole`s the faces are labelled with.
nonisolated enum FaceScheme: Sendable {
    case primitive(PrimitiveSpec)
    case extrude(Profile)
    case revolve
    case generic
}

/// A topology-mutating operation, so `propagate` can specialise if needed.
nonisolated enum TopoOp: Sendable {
    case boolean(BooleanKind)
    case transform(Transform3D)
    case pushPull
}

/// The concrete face a `FaceRef` resolved to, plus the match confidence [0,1].
nonisolated struct ResolvedFace: Sendable {
    var planar: FaceTopology.PlanarFace?
    var cylinder: FaceTopology.CylindricalFace?
    var confidence: Double
}

/// Swappable topological-naming strategy. Tranche 1 = `SignatureNaming`.
nonisolated protocol TopoNaming: Sendable {
    /// Label every face of a just-built `body` (created by `createdBy`) per `scheme`.
    func faceTable(for body: Body, createdBy: FeatureID, scheme: FaceScheme) -> FaceTable
    /// Re-label the faces of `output` (result of `op`) by best-matching the
    /// `inputs`' entries; unmatched faces fall back to `derived(index:)`.
    func propagate(inputs: [FaceTable], output: Body, op: TopoOp) -> FaceTable
    /// Re-resolve a persisted `ref` against `body`'s current faces (optionally
    /// boosted by a `table`'s roles). Returns the best face above threshold, else nil.
    func resolve(_ ref: FaceRef, in body: Body, table: FaceTable?) -> ResolvedFace?
}

// MARK: - SignatureNaming (tranche 1)

/// Geometric topological naming: faces are matched by normal alignment, centroid
/// proximity (scaled by the body's bbox diagonal), and area ratio. Zero mesh /
/// persistence format change — the ground-truth resolver.
nonisolated struct SignatureNaming: TopoNaming {

    // MARK: Scoring weights (reported in A2 deliverable)

    /// Weight on normal alignment  = max(0, n·refN).           Dominant term.
    static let wNormal: Double = 0.5
    /// Weight on centroid proximity = 1 - min(1, dist/bboxDiag).
    static let wCentroid: Double = 0.3
    /// Weight on area similarity    = 1 - min(1, |1 - area/refArea|).
    static let wArea: Double = 0.2
    /// Additive boost when a candidate's table role equals `ref.role`.
    static let roleBoost: Double = 0.2
    /// A face must score at least this to `resolve`.
    static let resolveThreshold: Double = 0.6
    /// An output face must score at least this to inherit an input entry's role.
    static let propagateThreshold: Double = 0.55

    // Base weights sum to 1.0, so a candidate whose normal is orthogonal to the
    // target (n·refN = 0) caps at wCentroid + wArea = 0.5 < resolveThreshold —
    // i.e. a face pointing the wrong way can never resolve. An aligned face
    // (n·refN = 1) ranges [0.5, 1.0]. This is what makes a removed/rotated-away
    // face resolve to nil while a moved/grown same-orientation face still hits.

    init() {}

    // MARK: TopoNaming

    func faceTable(for body: Body, createdBy: FeatureID, scheme: FaceScheme) -> FaceTable {
        let faces = Self.enumerate(body.render)
        let roles = assignRoles(faces: faces, scheme: scheme)
        let entries = zip(faces, roles).map { face, role in
            FaceTable.Entry(role: role, signature: face.signature, triangles: face.triangles)
        }
        return FaceTable(entries: entries)
    }

    func propagate(inputs: [FaceTable], output: Body, op: TopoOp) -> FaceTable {
        let faces = Self.enumerate(output.render)
        let diag = Self.bboxDiagonal(output.render)
        let inputEntries = inputs.flatMap { $0.entries }

        // Area-rank fallback for faces that match nothing well.
        let areaOrder = faces.indices.sorted { faces[$0].signature.area > faces[$1].signature.area }
        var rankOf = [Int: Int]()
        for (rank, idx) in areaOrder.enumerated() { rankOf[idx] = rank }

        var entries: [FaceTable.Entry] = []
        entries.reserveCapacity(faces.count)
        for (i, face) in faces.enumerated() {
            var bestScore = -Double.infinity
            var bestRole: FaceRole?
            for entry in inputEntries {
                let s = score(face.signature, against: entry.signature, bboxDiag: diag)
                if s > bestScore { bestScore = s; bestRole = entry.role }
            }
            let role: FaceRole
            if let bestRole, bestScore >= Self.propagateThreshold {
                role = bestRole
            } else {
                role = .derived(index: rankOf[i] ?? i)
            }
            entries.append(.init(role: role, signature: face.signature, triangles: face.triangles))
        }
        return FaceTable(entries: entries)
    }

    func resolve(_ ref: FaceRef, in body: Body, table: FaceTable?) -> ResolvedFace? {
        let faces = Self.enumerate(body.render)
        guard !faces.isEmpty else { return nil }
        let diag = Self.bboxDiagonal(body.render)

        var best: (score: Double, face: EnumeratedFace)?
        for face in faces {
            var s = score(face.signature, against: ref.signature, bboxDiag: diag)
            // Boost candidates whose recorded role (from the table) matches the ref.
            if let table, let role = roleFromTable(for: face, table: table, bboxDiag: diag),
               role == ref.role {
                s += Self.roleBoost
            }
            if best == nil || s > best!.score { best = (s, face) }
        }
        guard let best, best.score >= Self.resolveThreshold else { return nil }
        return ResolvedFace(
            planar: best.face.planar,
            cylinder: best.face.cylinder,
            confidence: min(1, best.score)
        )
    }

    // MARK: Scoring

    /// Geometric similarity of a candidate signature to a reference, in [0,1]
    /// (before any role boost). See the class comment for the weight rationale.
    private func score(
        _ candidate: FaceSignature, against ref: FaceSignature, bboxDiag diag: Double
    ) -> Double {
        let nAlign = max(0, simd_dot(Self.unit(candidate.normal), Self.unit(ref.normal)))
        let dist = simd_length(candidate.centroid - ref.centroid)
        let cProx = 1 - min(1, dist / max(diag, 1e-9))
        let aSim: Double
        if ref.area > 1e-12 {
            aSim = 1 - min(1, abs(1 - candidate.area / ref.area))
        } else {
            aSim = candidate.area < 1e-12 ? 1 : 0
        }
        return Self.wNormal * nAlign + Self.wCentroid * cProx + Self.wArea * aSim
    }

    /// The role the `table` would assign to `face` (its closest entry by signature).
    private func roleFromTable(
        for face: EnumeratedFace, table: FaceTable, bboxDiag diag: Double
    ) -> FaceRole? {
        var best: (score: Double, role: FaceRole)?
        for entry in table.entries {
            let s = score(face.signature, against: entry.signature, bboxDiag: diag)
            if best == nil || s > best!.score { best = (s, entry.role) }
        }
        return best?.role
    }

    // MARK: Role assignment by scheme

    private func assignRoles(faces: [EnumeratedFace], scheme: FaceScheme) -> [FaceRole] {
        switch scheme {
        case let .primitive(spec):
            switch spec {
            case .box:      return rolesForBox(faces)
            case .cylinder: return rolesForCylinder(faces)
            case .sphere:   return faces.map { _ in .sphereSurface }
            }
        case let .extrude(profile):
            return rolesForExtrude(profile, faces: faces)
        case .revolve, .generic:
            return derivedRoles(faces)
        }
    }

    private func rolesForBox(_ faces: [EnumeratedFace]) -> [FaceRole] {
        faces.enumerated().map { idx, face in
            face.planar != nil
                ? .boxFace(Self.boxFace(for: face.signature.normal))
                : .derived(index: idx)
        }
    }

    private func rolesForCylinder(_ faces: [EnumeratedFace]) -> [FaceRole] {
        // Axis from the fitted side surface, else the primitive's +Y build axis.
        var axis = SIMD3<Double>(0, 1, 0)
        for face in faces {
            if let cyl = face.cylinder { axis = Self.unit(cyl.axisDir); break }
        }
        let caps = faces.indices.filter { faces[$0].planar != nil }
        let axialPos = caps.map { simd_dot(faces[$0].signature.centroid, axis) }
        let maxPos = axialPos.max() ?? 0

        var roles = [FaceRole](repeating: .cylinderSide, count: faces.count)
        for (k, capIdx) in caps.enumerated() {
            roles[capIdx] = .cylinderCap(top: axialPos[k] >= maxPos - 1e-6)
        }
        // Non-cap, non-cylinder faces (shouldn't happen for a clean cylinder).
        for i in faces.indices where faces[i].planar == nil && faces[i].cylinder == nil {
            roles[i] = .derived(index: i)
        }
        return roles
    }

    private func rolesForExtrude(_ profile: Profile, faces: [EnumeratedFace]) -> [FaceRole] {
        var roles = [FaceRole?](repeating: nil, count: faces.count)
        let profileArea = abs(profile.area)
        let planar = faces.indices.filter { faces[$0].planar != nil }

        // Caps: the anti-parallel planar pair whose areas best match the profile.
        var bestPair: (Int, Int)?
        var bestScore = -Double.infinity
        for a in 0..<planar.count {
            for b in (a + 1)..<planar.count {
                let sa = faces[planar[a]].signature
                let sb = faces[planar[b]].signature
                let anti = -simd_dot(Self.unit(sa.normal), Self.unit(sb.normal))
                guard anti > 0.9 else { continue }
                let areaMatch = 1 - min(1,
                    (abs(sa.area - profileArea) + abs(sb.area - profileArea)) / max(profileArea, 1e-9))
                let s = anti + areaMatch
                if s > bestScore { bestScore = s; bestPair = (planar[a], planar[b]) }
            }
        }

        var axis = SIMD3<Double>(0, 1, 0)
        var capCenter = SIMD3<Double>.zero
        if let (i, j) = bestPair {
            let ti = simd_dot(faces[i].signature.centroid, Self.unit(faces[i].signature.normal))
            // Start cap = lower along the extrude axis (deterministic tie-break).
            let axisI = Self.unit(faces[i].signature.normal)
            let tj = simd_dot(faces[j].signature.centroid, axisI)
            if ti <= tj {
                roles[i] = .extrudeStartCap; roles[j] = .extrudeEndCap
            } else {
                roles[i] = .extrudeEndCap;   roles[j] = .extrudeStartCap
            }
            axis = axisI
            capCenter = (faces[i].signature.centroid + faces[j].signature.centroid) / 2
        }

        // Walls: match each to a profile edge by angular order around the axis.
        let (bx, by) = Self.perpendicularBasis(axis)
        let loop = profile.loop
        let profCentroid = profile.centroid
        var profileEdges: [(index: Int, angle: Double)] = []
        for e in loop.indices {
            let mid = (loop[e] + loop[(e + 1) % loop.count]) / 2 - profCentroid
            profileEdges.append((e, atan2(mid.y, mid.x)))
        }
        profileEdges.sort { $0.angle < $1.angle }

        var walls: [(faceIndex: Int, angle: Double)] = []
        for k in faces.indices where roles[k] == nil {
            let d = faces[k].signature.centroid - capCenter
            walls.append((k, atan2(simd_dot(d, by), simd_dot(d, bx))))
        }
        walls.sort { $0.angle < $1.angle }
        for (rank, wall) in walls.enumerated() {
            let edgeIndex = profileEdges.isEmpty ? rank : profileEdges[rank % profileEdges.count].index
            roles[wall.faceIndex] = .extrudeWall(loopIndex: 0, edgeIndex: edgeIndex)
        }

        // Anything still unlabelled → area-rank derived.
        let fallback = derivedRoles(faces)
        return roles.indices.map { roles[$0] ?? fallback[$0] }
    }

    private func derivedRoles(_ faces: [EnumeratedFace]) -> [FaceRole] {
        let order = faces.indices.sorted { faces[$0].signature.area > faces[$1].signature.area }
        var roles = [FaceRole](repeating: .derived(index: 0), count: faces.count)
        for (rank, idx) in order.enumerated() { roles[idx] = .derived(index: rank) }
        return roles
    }

    // MARK: Face enumeration + signatures

    /// A face of a body, with its geometry and precomputed signature.
    private struct EnumeratedFace {
        var planar: FaceTopology.PlanarFace?
        var cylinder: FaceTopology.CylindricalFace?
        var signature: FaceSignature
        var triangles: [Int]
    }

    /// Group a body's triangles into faces (planar patches + cylindrical side
    /// surfaces), each with its `FaceSignature`. Delegates to A1's whole-mesh
    /// `FaceTopology.enumerateFaces`, the single source of truth for the partition.
    private static func enumerate(_ mesh: RenderMesh) -> [EnumeratedFace] {
        let result = FaceTopology.enumerateFaces(in: mesh)
        var faces: [EnumeratedFace] = []
        faces.reserveCapacity(result.planar.count + result.cylindrical.count)
        for planar in result.planar {
            faces.append(EnumeratedFace(
                planar: planar, cylinder: nil,
                signature: signature(planar: planar), triangles: planar.triangles))
        }
        for cyl in result.cylindrical {
            faces.append(EnumeratedFace(
                planar: nil, cylinder: cyl,
                signature: signature(cylinder: cyl), triangles: cyl.triangles))
        }
        return faces
    }

    private static func signature(planar face: FaceTopology.PlanarFace) -> FaceSignature {
        let n = SIMD3<Double>(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let centroid = face.origin // loop centroid, in body-local space
        var area = abs(Profile.signedArea(face.outline))
        for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
        return FaceSignature(
            kind: .planar, normal: n, centroid: centroid,
            area: max(area, 0), planeOffset: simd_dot(n, centroid))
    }

    private static func signature(cylinder cyl: FaceTopology.CylindricalFace) -> FaceSignature {
        let axis = unit(cyl.axisDir)
        let centroid = cyl.baseCenter + axis * (cyl.height / 2)
        let area = 2 * Double.pi * cyl.radius * cyl.height
        return FaceSignature(
            kind: .cylindrical(radius: cyl.radius), normal: axis, centroid: centroid,
            area: area, planeOffset: simd_dot(axis, centroid))
    }

    // MARK: Small helpers

    private static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : v
    }

    private static func bboxDiagonal(_ mesh: RenderMesh) -> Double {
        let (lo, hi) = mesh.localAABB
        let d = SIMD3<Double>(Double(hi.x - lo.x), Double(hi.y - lo.y), Double(hi.z - lo.z))
        let len = simd_length(d)
        return len > 1e-9 ? len : 1
    }

    /// The signed ±X/±Y/±Z box face whose axis a normal points most strongly along.
    private static func boxFace(for normal: SIMD3<Double>) -> BoxFace {
        let ax = abs(normal.x), ay = abs(normal.y), az = abs(normal.z)
        if ax >= ay && ax >= az { return normal.x >= 0 ? .px : .nx }
        if ay >= az            { return normal.y >= 0 ? .py : .ny }
        return normal.z >= 0 ? .pz : .nz
    }

    /// Two unit vectors spanning the plane perpendicular to `axis`.
    private static func perpendicularBasis(_ axis: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let a = unit(axis)
        let ref = abs(a.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let bx = unit(simd_cross(ref, a))
        let by = simd_cross(a, bx)
        return (bx, by)
    }
}
