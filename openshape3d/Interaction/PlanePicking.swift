//
//  PlanePicking.swift
//  openshape3d
//
//  Tappable plane tiles: the three origin plane pickers shown when a sketch
//  tool is waiting for a plane (spec §2.3), plus construction-plane quads.
//  Hit-testing mirrors HitTester's ray casting.
//

import Foundation
import simd

/// One tappable plane tile, drawn in the gizmo overlay pass.
nonisolated struct PlanePickerTile {
    /// Construction plane id; nil for the three world-plane tiles.
    var planeID: ConstructionPlaneID?
    var plane: SketchPlane
    /// Tile rectangle in plane-local coordinates.
    var localMin: SIMD2<Double>
    var localMax: SIMD2<Double>
    var color: SIMD4<Float>

    /// Quad corners in world space (CCW in plane space), for rendering.
    var worldCorners: [SIMD3<Float>] {
        [
            SIMD2(localMin.x, localMin.y),
            SIMD2(localMax.x, localMin.y),
            SIMD2(localMax.x, localMax.y),
            SIMD2(localMin.x, localMax.y),
        ].map { corner in
            let world = plane.toWorld(corner)
            return SIMD3(Float(world.x), Float(world.y), Float(world.z))
        }
    }
}

nonisolated enum PlanePicking {
    /// World tiles sit corner-to-origin so the three quads don't overlap.
    static let worldTileMin = 0.3
    static let worldTileMax = 2.3

    /// The three origin plane pickers at their smallest (an empty scene).
    static let worldTiles: [PlanePickerTile] = worldTiles(sceneExtent: 0)

    /// The three origin plane pickers (colors keyed like the gizmo axes by
    /// normal: +Y green, +Z blue, +X red), sized to the scene: the outer
    /// edge is 60 % of the largest body extent, never under the 2.3 mm
    /// default. Fixed 2 mm tiles were a speck beside a metre-scale scan and
    /// buried inside anything big centred on the origin (2026-09-05).
    static func worldTiles(sceneExtent: Double) -> [PlanePickerTile] {
        let outer = max(worldTileMax, sceneExtent * 0.6)
        let inner = outer * (worldTileMin / worldTileMax)
        let lo = SIMD2(inner, inner)
        let hi = SIMD2(outer, outer)
        return [
            PlanePickerTile(
                planeID: nil, plane: .ground, localMin: lo, localMax: hi,
                color: SIMD4(0.35, 0.72, 0.28, 0.35)
            ),
            PlanePickerTile(
                planeID: nil, plane: .worldXY, localMin: lo, localMax: hi,
                color: SIMD4(0.26, 0.47, 0.90, 0.35)
            ),
            PlanePickerTile(
                planeID: nil, plane: .worldYZ, localMin: lo, localMax: hi,
                color: SIMD4(0.88, 0.26, 0.26, 0.35)
            ),
        ]
    }

    /// Nearest tile hit by the ray, with its world-space distance.
    static func pick(
        ray: Ray, tiles: [PlanePickerTile]
    ) -> (tile: PlanePickerTile, distance: Float)? {
        var best: (tile: PlanePickerTile, distance: Float)?
        for tile in tiles {
            let plane = tile.plane
            let origin = SIMD3<Float>(
                Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
            )
            let n = plane.normal
            let normal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
            guard let t = ray.intersect(planePoint: origin, planeNormal: normal) else {
                continue
            }
            let world = ray.point(at: t)
            let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
            guard local.x >= tile.localMin.x, local.x <= tile.localMax.x,
                  local.y >= tile.localMin.y, local.y <= tile.localMax.y
            else { continue }
            if best == nil || t < best!.distance {
                best = (tile, t)
            }
        }
        return best
    }
}
