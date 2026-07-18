//
//  KernelOps.swift
//  openshape3d
//
//  Solid-modeling operations on top of Euclid: profile extrusion and booleans.
//

import Foundation
import simd
import Euclid

nonisolated enum KernelOps {

    /// Extrude a closed profile (with optional holes) along the plane normal.
    /// Positive distance pulls along +normal; negative pushes the other way.
    /// The profile face stays on the sketch plane.
    static func extrude(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        distance: Double
    ) -> Euclid.Mesh {
        let depth = abs(distance)
        guard depth > 1e-6 else { return Euclid.Mesh([]) }

        var solid = extrudeLoop(profile, depth: depth)
        for hole in holes {
            // Cut holes with a slightly deeper tool so coplanar caps don't
            // leave slivers.
            let tool = extrudeLoop(hole, depth: depth * 1.002)
            solid = solid.subtracting(tool).makeWatertight()
        }

        // Euclid centers extrusion on the path plane: shift so the base sits on
        // the sketch plane and the pull goes one-sided.
        let offset = distance / 2
        solid = solid.translated(by: Vector(0, 0, offset))

        // Map plane-local (x, y, z=normal) into world space.
        let transform = planeToWorld(plane)
        return solid.transformed(by: transform)
    }

    private static func extrudeLoop(_ profile: Profile, depth: Double) -> Euclid.Mesh {
        let path = closedPath(for: profile)
        return Euclid.Mesh.extrude(path, depth: depth)
    }

    /// Closed CCW path in plane-local XY.
    static func closedPath(for profile: Profile) -> Euclid.Path {
        var points = profile.loop.map { PathPoint.point($0.x, $0.y) }
        if let first = points.first {
            points.append(first)
        }
        return Euclid.Path(points)
    }

    /// Rotation+translation mapping plane-local coordinates (x→xAxis, y→yAxis,
    /// z→normal) into world space.
    static func planeToWorld(_ plane: SketchPlane) -> Euclid.Transform {
        let x = plane.xAxis
        let y = plane.yAxis
        let z = plane.normal
        // Build a quaternion from the orthonormal basis matrix.
        let matrix = simd_double3x3(
            SIMD3(x.x, x.y, x.z),
            SIMD3(y.x, y.y, y.z),
            SIMD3(z.x, z.y, z.z)
        )
        let quaternion = simd_quatd(matrix)
        return Euclid.Transform(
            rotation: Rotation(quaternion),
            translation: Vector(plane.origin.x, plane.origin.y, plane.origin.z)
        )
    }

    // MARK: - Booleans

    static func boolean(
        _ kind: BooleanKind,
        target: Body,
        tool: Body,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Euclid.Mesh {
        let a = target.euclidMesh().transformed(by: target.transform.euclid)
        let b = tool.euclidMesh().transformed(by: tool.transform.euclid)
        let result: Euclid.Mesh
        switch kind {
        case .union:
            result = a.union(b, isCancelled: isCancelled)
        case .subtract:
            result = a.subtracting(b, isCancelled: isCancelled)
        case .intersect:
            result = a.intersection(b, isCancelled: isCancelled)
        }
        // CSG can leave T-junction cracks along cut seams; heal them.
        return result.makeWatertight()
    }
}
