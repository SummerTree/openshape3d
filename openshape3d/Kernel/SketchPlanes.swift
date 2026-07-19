//
//  SketchPlanes.swift
//  openshape3d
//
//  World sketch planes, geometric plane matching, and offset construction
//  planes (spec §2.3/§6.1). Nonisolated: shared with the kernel.
//

import Foundation
import simd

nonisolated extension SketchPlane {
    /// Front plane (z = 0): sketch X → world X, sketch Y → world Y, normal +Z.
    static let worldXY = SketchPlane(
        origin: .zero,
        xAxis: SIMD3(1, 0, 0),
        yAxis: SIMD3(0, 1, 0)
    )

    /// Side plane (x = 0): sketch X → world -Z, sketch Y → world Y, normal +X,
    /// so the sketch reads right-handed when viewed from +X.
    static let worldYZ = SketchPlane(
        origin: .zero,
        xAxis: SIMD3(0, 0, -1),
        yAxis: SIMD3(0, 1, 0)
    )

    /// Same geometric plane (parallel normals, coplanar origins) within
    /// tolerance — basis vectors may differ. Shapr3D's rule: continuing on
    /// the same plane edits the same sketch item.
    func isCoincident(with other: SketchPlane, tolerance: Double = 1e-4) -> Bool {
        let n = simd_normalize(normal)
        let m = simd_normalize(other.normal)
        guard abs(simd_dot(n, m)) > 1 - 1e-6 else { return false }
        return abs(simd_dot(other.origin - origin, n)) < tolerance
    }
}

nonisolated struct ConstructionPlaneID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

/// A construction plane in the document: a sketch plane plus the edge length
/// of the translucent quad that visualizes it.
nonisolated struct ConstructionPlane: Identifiable, Codable, Equatable, Sendable {
    let id: ConstructionPlaneID
    var plane: SketchPlane
    var size: Double
    /// Items Manager visibility (spec §11).
    var isHidden: Bool

    init(
        id: ConstructionPlaneID = ConstructionPlaneID(),
        plane: SketchPlane,
        size: Double,
        isHidden: Bool = false
    ) {
        self.id = id
        self.plane = plane
        self.size = size
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, plane, size, isHidden
    }

    /// `isHidden` is optional on decode so pre-A8 documents load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ConstructionPlaneID.self, forKey: .id)
        plane = try container.decode(SketchPlane.self, forKey: .plane)
        size = try container.decode(Double.self, forKey: .size)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}
