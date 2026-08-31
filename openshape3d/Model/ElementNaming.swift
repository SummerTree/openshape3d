//
//  ElementNaming.swift
//  openshape3d — kernel-history element names
//  (docs/TOPO_NAMING_HISTORY_DESIGN.md step 2)
//
//  A face's NAME, derived from persisted stable identities the app already
//  owns — the creating feature and the sketch entity a wall came from —
//  bound to actual kernel faces through `ShapeAncestry` (OCCT's own
//  history), never through geometric resemblance. Names layer UNDER
//  `SignatureNaming`: an unnamed face is normal and falls back to signature
//  scoring; a WRONG name would be worse than none, so every derivation here
//  refuses to guess.
//

import Foundation

/// The identity of one face, stable across rebuilds because every component
/// is itself persisted and stable. Codable/Hashable value — no string
/// grammar, no hashing; the graphs are small.
nonisolated struct ElementName: Codable, Hashable, Sendable {

    nonisolated enum Source: Codable, Hashable, Sendable {
        /// A primitive's face — for primitives the role IS the identity
        /// (`boxFace(.top)`, `cylinderCap(top:)`, …).
        case primitiveFace(FaceRole)
        /// An extrude wall generated from one sketch entity. `occurrence`
        /// separates multiple walls owned by the same entity (a rect entity
        /// owns four), counted in wire order from the profile's own
        /// boundary arrays — deterministic per profile shape.
        case profileWall(entity: UUID, occurrence: Int)
        /// An extrude cap; `end` false = the start cap (zMin side).
        case profileCap(end: Bool)
        /// Fallback identity: the k-th face (1-based indexed-map order) of
        /// the creating op's result, when nothing finer exists.
        case kernelFace(index: Int)
    }

    var creator: FeatureID
    var source: Source
}

/// Derivation + attachment. Pure functions over values — the FeatureGraph
/// wiring comes separately, so these are unit-testable without a document.
nonisolated enum ElementNaming {

    /// Per-OCCT-face names for an extrude result: caps from the profile-face
    /// rows, walls from the generated-edge rows resolved through the
    /// profile's boundary identity. Keys are 1-based result face indices
    /// (the numbering `ShapeAncestry`, the face channel and the health
    /// report share). A face claimed by two DIFFERENT names is dropped —
    /// ambiguity never ships.
    static func extrudeNames(creator: FeatureID, ancestry: ShapeAncestry,
                             outer: Profile, holes: [Profile]) -> [Int: ElementName] {
        // Wall-edge counts per loop pick which boundary description built
        // the wire (conic / exact segments / polyline) — see
        // `Profile.boundaryIdentity`. A phantom-dropped row makes the count
        // match nothing and the loop's walls stay honestly unnamed.
        var wallCount: [Int: Int] = [:]
        for row in ancestry.rows where row.inputKind == .edge
            && row.relation == .generated {
            wallCount[row.inputOrdinal, default: 0] += 1
        }

        var names: [Int: ElementName] = [:]
        var ambiguous: Set<Int> = []
        func claim(_ face: Int, _ name: ElementName) {
            if let existing = names[face], existing != name {
                ambiguous.insert(face)
                return
            }
            names[face] = name
        }

        for row in ancestry.rows {
            if row.inputKind == .face, row.inputOrdinal == 0 {
                claim(row.resultFace, ElementName(
                    creator: creator,
                    source: .profileCap(end: row.inputSubshape == 2)))
            } else if row.inputKind == .edge, row.relation == .generated {
                let profile: Profile? = row.inputOrdinal == 0
                    ? outer
                    : (row.inputOrdinal - 1 < holes.count
                        ? holes[row.inputOrdinal - 1] : nil)
                guard let profile,
                      let count = wallCount[row.inputOrdinal],
                      let identity = profile.boundaryIdentity(
                          wireEdge: row.inputSubshape, wireEdgeCount: count)
                else { continue }
                claim(row.resultFace, ElementName(
                    creator: creator,
                    source: .profileWall(entity: identity.entity,
                                         occurrence: identity.occurrence)))
            }
        }
        for face in ambiguous { names.removeValue(forKey: face) }
        return names
    }

    /// Attach per-OCCT-face names to a face table by majority vote over the
    /// per-triangle face channel. Only meaningful when the table was built
    /// over the ADOPTED OCCT tessellation — the channel then aligns
    /// triangle-for-triangle with `body.render`. An entry needs a strict
    /// majority of its triangles on one kernel face to claim its name;
    /// anything less stays unnamed.
    static func attach(_ names: [Int: ElementName], to table: FaceTable,
                       channel: [UInt32]) -> FaceTable {
        guard !names.isEmpty, !channel.isEmpty else { return table }
        var out = table
        for i in out.entries.indices {
            var votes: [UInt32: Int] = [:]
            for triangle in out.entries[i].triangles where triangle < channel.count {
                votes[channel[triangle], default: 0] += 1
            }
            guard let winner = votes.max(by: { $0.value < $1.value }),
                  winner.key != 0,
                  winner.value * 2 > out.entries[i].triangles.count
            else { continue }
            out.entries[i].elementName = names[Int(winner.key)]
        }
        return out
    }

    /// Names for a primitive's table entries: the role is the identity, so
    /// no kernel channel is needed — which also covers the box, whose render
    /// deliberately stays Euclid. `.derived` roles carry no identity and
    /// stay unnamed.
    static func namePrimitiveEntries(_ table: FaceTable,
                                     creator: FeatureID) -> FaceTable {
        var out = table
        for i in out.entries.indices {
            if case .derived = out.entries[i].role { continue }
            out.entries[i].elementName = ElementName(
                creator: creator,
                source: .primitiveFace(out.entries[i].role))
        }
        return out
    }
}
