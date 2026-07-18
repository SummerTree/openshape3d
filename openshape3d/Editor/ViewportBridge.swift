//
//  ViewportBridge.swift
//  openshape3d
//
//  The contract between the editor (model side) and the Metal viewport
//  (render side). The viewport consumes ViewportScene and never mutates the
//  document; it reports events back through ViewportEventHandler.
//

import Foundation
import simd

/// Everything the renderer needs to draw one body.
struct BodyDrawable: Identifiable {
    let id: BodyID
    var renderMesh: RenderMesh
    var edges: FeatureEdgeSet?
    /// Cache key: buffers are rebuilt only when (id, meshRevision) changes.
    var meshRevision: UInt64
    var modelMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var selectionState: UInt32 = 0 // SelectionState raw value
    var isTranslucent: Bool = false
}

/// A snapshot of what the viewport should draw. Value type, rebuilt cheaply
/// by the editor on any model change (mesh arrays are CoW references).
/// A batch of world-space line segments drawn in one color (sketch entities,
/// pending rubber-band, profile highlights).
struct SketchLineBatch {
    /// Pairs: [a0,b0, a1,b1, ...]
    var segments: [SIMD3<Float>]
    var color: SIMD4<Float>
}

/// Translucent triangles filling closed sketch profiles (Shapr3D-style fill).
struct SketchFillBatch {
    /// Triangle list: 3 vertices per triangle, world space.
    var triangles: [SIMD3<Float>]
    var color: SIMD4<Float>
}

struct ViewportScene {
    var bodies: [BodyDrawable] = []
    /// Move gizmo, when a body is selected. `scale` is finalized by the
    /// renderer each frame for constant screen size.
    var gizmo: GizmoState?
    /// Sketch overlay lines, drawn after the grid with edge depth bias.
    var sketchLines: [SketchLineBatch] = []
    /// Closed-profile fills, drawn between the grid and the sketch lines.
    var profileFills: [SketchFillBatch] = []

    /// World-space AABB of all bodies, for fit-view. Nil when empty.
    var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for body in bodies {
            let aabb = body.renderMesh.localAABB
            // Transform the 8 corners; cheap and correct for TRS.
            for i in 0..<8 {
                let corner = SIMD3<Float>(
                    (i & 1) == 0 ? aabb.min.x : aabb.max.x,
                    (i & 2) == 0 ? aabb.min.y : aabb.max.y,
                    (i & 4) == 0 ? aabb.min.z : aabb.max.z
                )
                let world4 = body.modelMatrix * SIMD4(corner, 1)
                let world = SIMD3(world4.x, world4.y, world4.z)
                if let current = result {
                    result = (simd_min(current.min, world), simd_max(current.max, world))
                } else {
                    result = (world, world)
                }
            }
        }
        return result
    }
}

