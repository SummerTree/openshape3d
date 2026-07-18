//
//  GPUResourceCache.swift
//  openshape3d
//
//  Per-body MTLBuffers, keyed by body ID and invalidated by mesh revision.
//  Meshes change at user-action rate (extrude/boolean commits), so buffers are
//  simply reallocated fresh when the revision bumps.
//

import Foundation
import Metal
import simd

final class BodyGPUResources {
    let meshRevision: UInt64
    let positionBuffer: MTLBuffer
    let normalBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let edgeVertexBuffer: MTLBuffer?
    let edgeVertexCount: Int

    init?(drawable: BodyDrawable, device: MTLDevice) {
        let mesh = drawable.renderMesh
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else { return nil }
        let positionLength = mesh.positions.count * MemoryLayout<SIMD3<Float>>.stride
        let normalLength = mesh.normals.count * MemoryLayout<SIMD3<Float>>.stride
        let indexLength = mesh.indices.count * MemoryLayout<UInt32>.stride
        guard
            let positions = mesh.positions.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: positionLength, options: .storageModeShared)
            }),
            let normals = mesh.normals.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: normalLength, options: .storageModeShared)
            }),
            let indices = mesh.indices.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: indexLength, options: .storageModeShared)
            })
        else { return nil }

        meshRevision = drawable.meshRevision
        positionBuffer = positions
        normalBuffer = normals
        indexBuffer = indices
        indexCount = mesh.indices.count

        if let edges = drawable.edges, !edges.segments.isEmpty {
            let edgeLength = edges.segments.count * MemoryLayout<SIMD3<Float>>.stride
            edgeVertexBuffer = edges.segments.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: edgeLength, options: .storageModeShared)
            }
            edgeVertexCount = edges.segments.count
        } else {
            edgeVertexBuffer = nil
            edgeVertexCount = 0
        }
    }
}

final class GPUResourceCache {
    private var cache: [BodyID: BodyGPUResources] = [:]

    func sync(with scene: ViewportScene, device: MTLDevice) {
        var liveIDs = Set<BodyID>()
        for drawable in scene.bodies {
            liveIDs.insert(drawable.id)
            if let existing = cache[drawable.id], existing.meshRevision == drawable.meshRevision {
                continue
            }
            cache[drawable.id] = BodyGPUResources(drawable: drawable, device: device)
        }
        cache = cache.filter { liveIDs.contains($0.key) }
    }

    func resources(for id: BodyID) -> BodyGPUResources? {
        cache[id]
    }
}
