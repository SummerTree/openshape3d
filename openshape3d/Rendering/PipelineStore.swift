//
//  PipelineStore.swift
//  openshape3d
//
//  Builds and caches every MTLRenderPipelineState and depth-stencil state.
//  All vertex data is pulled from buffers via vertex_id, so no vertex
//  descriptors are needed.
//

import Foundation
import Metal

final class PipelineStore {
    // Render pipelines
    let background: MTLRenderPipelineState
    let lit: MTLRenderPipelineState
    let litBlended: MTLRenderPipelineState   // preview bodies (translucent)
    let unlitColor: MTLRenderPipelineState
    let edge: MTLRenderPipelineState
    let grid: MTLRenderPipelineState

    // Depth-stencil states
    let depthReadWrite: MTLDepthStencilState
    let depthReadOnly: MTLDepthStencilState
    let depthIgnore: MTLDepthStencilState

    init?(device: MTLDevice, library: MTLLibrary) {
        func makePipeline(
            vertex: String,
            fragment: String,
            blended: Bool
        ) -> MTLRenderPipelineState? {
            guard let vertexFn = library.makeFunction(name: vertex),
                  let fragmentFn = library.makeFunction(name: fragment)
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.rasterSampleCount = RenderContext.sampleCount
            descriptor.depthAttachmentPixelFormat = RenderContext.depthPixelFormat
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = RenderContext.colorPixelFormat
            if blended {
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard
            let background = makePipeline(
                vertex: "vertex_fullscreen", fragment: "fragment_backgroundGradient", blended: false
            ),
            let lit = makePipeline(vertex: "vertex_lit", fragment: "fragment_lit", blended: false),
            let litBlended = makePipeline(vertex: "vertex_lit", fragment: "fragment_lit", blended: true),
            let unlitColor = makePipeline(
                vertex: "vertex_unlit", fragment: "fragment_flatColor", blended: true
            ),
            let edge = makePipeline(vertex: "vertex_edge", fragment: "fragment_flatColor", blended: true),
            let grid = makePipeline(vertex: "vertex_grid", fragment: "fragment_grid", blended: true)
        else { return nil }

        self.background = background
        self.lit = lit
        self.litBlended = litBlended
        self.unlitColor = unlitColor
        self.edge = edge
        self.grid = grid

        func makeDepthState(compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: descriptor)
        }

        guard
            let depthReadWrite = makeDepthState(compare: .less, write: true),
            let depthReadOnly = makeDepthState(compare: .less, write: false),
            let depthIgnore = makeDepthState(compare: .always, write: false)
        else { return nil }

        self.depthReadWrite = depthReadWrite
        self.depthReadOnly = depthReadOnly
        self.depthIgnore = depthIgnore
    }
}
