//
//  RenderContext.swift
//  openshape3d
//

import Foundation
import Metal
import MetalKit

/// Long-lived Metal objects shared by all render passes.
final class RenderContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let pipelines: PipelineStore

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    static let depthPixelFormat: MTLPixelFormat = .depth32Float
    static let sampleCount = 4

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.library = library
        guard let pipelines = PipelineStore(device: device, library: library) else { return nil }
        self.pipelines = pipelines
    }

    func configure(view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorPixelFormat
        view.depthStencilPixelFormat = Self.depthPixelFormat
        view.sampleCount = Self.sampleCount
        view.clearColor = MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        view.clearDepth = 1.0
        view.enableSetNeedsDisplay = true
        view.isPaused = true
    }
}
