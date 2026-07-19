//
//  Renderer.swift
//  openshape3d
//
//  Frame orchestration. Pass order in one encoder:
//  background → opaque bodies → feature edges → grid → translucent bodies.
//  (Sketch overlay and gizmo join in later build steps.)
//

import Foundation
import Metal
import MetalKit
import simd
import UIKit
import CoreGraphics

final class Renderer: NSObject, MTKViewDelegate {
    let context: RenderContext
    var camera = TurntableCamera()
    var scene = ViewportScene()

    private let cache = GPUResourceCache()
    private let gizmoRenderer = GizmoRenderer()
    private let orientationCubeRenderer = OrientationCubeRenderer()
    private var viewportSize = CGSize(width: 1, height: 1)

    /// World-units-per-gizmo-unit for constant ~screen size, shared by
    /// rendering and hit-testing.
    func gizmoScale(origin: SIMD3<Float>) -> Float {
        simd_length(camera.position - origin) * tan(camera.fovY * 0.5) * 0.24
    }

    init(context: RenderContext) {
        self.context = context
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.width > 0, size.height > 0 {
            viewportSize = size
        }
    }

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = context.commandQueue.makeCommandBuffer()
        else { return }

        // Every frame ends in a second overlay pass (cleared depth): the
        // orientation cube always, plus gizmo/pull arrow/plane pickers when
        // present. Keep the MSAA color texture and resolve at the end.
        let msaaColor = descriptor.colorAttachments[0].texture
        let resolveTarget = descriptor.colorAttachments[0].resolveTexture
        // A pass with a resolveTexture attached must use a resolving store
        // action (Metal validation asserts otherwise) — detach it here and
        // resolve in the overlay pass instead.
        descriptor.colorAttachments[0].resolveTexture = nil
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.storeAction = .dontCare

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        cache.sync(with: scene, device: context.device)

        var frame = makeFrameUniforms()
        encodeScene(encoder: encoder, frame: &frame)
        encoder.endEncoding()

        // 6. Overlay pass: depth cleared so overlays draw on top.
        if let msaaColor {
            let overlay = MTLRenderPassDescriptor()
            overlay.colorAttachments[0].texture = msaaColor
            overlay.colorAttachments[0].loadAction = .load
            if let resolveTarget {
                overlay.colorAttachments[0].resolveTexture = resolveTarget
                overlay.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                overlay.colorAttachments[0].storeAction = .store
            }
            overlay.depthAttachment.texture = descriptor.depthAttachment.texture
            overlay.depthAttachment.loadAction = .clear
            overlay.depthAttachment.storeAction = .dontCare
            overlay.depthAttachment.clearDepth = 1

            if let overlayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: overlay) {
                gizmoRenderer.prepare(device: context.device)
                if var gizmo = scene.gizmo {
                    gizmo.scale = gizmoScale(origin: gizmo.origin)
                    gizmoRenderer.draw(
                        encoder: overlayEncoder,
                        pipelines: context.pipelines,
                        frame: &frame,
                        gizmo: gizmo
                    )
                }
                if !scene.planePickers.isEmpty {
                    gizmoRenderer.drawPlaneTiles(
                        encoder: overlayEncoder,
                        pipelines: context.pipelines,
                        frame: &frame,
                        tiles: scene.planePickers
                    )
                }
                if let arrow = scene.pullArrow {
                    gizmoRenderer.drawPullArrow(
                        encoder: overlayEncoder,
                        pipelines: context.pipelines,
                        frame: &frame,
                        arrow: arrow,
                        scale: gizmoScale(origin: arrow.origin)
                    )
                }
                // Orientation cube (spec §7.2), always on. Layout math is in
                // points so its NDC placement matches tap hit-testing.
                orientationCubeRenderer.prepare(device: context.device)
                orientationCubeRenderer.draw(
                    encoder: overlayEncoder,
                    pipelines: context.pipelines,
                    camera: camera,
                    viewSize: view.bounds.size
                )
                overlayEncoder.endEncoding()
            }
        }

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    /// Everything except the gizmo overlay — shared by live drawing and
    /// offscreen thumbnail/screenshot capture. `drawBackground`/`drawGrid`
    /// support screenshot options (transparent background, grid off).
    private func encodeScene(
        encoder: MTLRenderCommandEncoder,
        frame: inout FrameUniforms,
        drawBackground: Bool = true,
        drawGrid: Bool = true
    ) {
        let pipelines = context.pipelines

        // 1. Background gradient
        if drawBackground {
            encoder.setRenderPipelineState(pipelines.background)
            encoder.setDepthStencilState(pipelines.depthIgnore)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                                     index: Int(BufferIndexFrameUniforms.rawValue))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 2. Opaque bodies
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setRenderPipelineState(pipelines.lit)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        for drawable in scene.bodies where !drawable.isTranslucent {
            drawBody(drawable, encoder: encoder, pipeline: pipelines.lit)
        }

        // 3. Feature edges
        encoder.setRenderPipelineState(pipelines.edge)
        encoder.setDepthStencilState(pipelines.depthReadOnly)
        for drawable in scene.bodies where !drawable.isTranslucent {
            drawEdges(drawable, encoder: encoder)
        }

        // 4. Ground grid (blended, depth read only)
        if drawGrid {
            encoder.setRenderPipelineState(pipelines.grid)
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // 4b. Closed-profile fills (edge pipeline reused for its depth bias so
        // fills win against coplanar body faces; blended, no depth write)
        if !scene.profileFills.isEmpty {
            encoder.setRenderPipelineState(pipelines.edge)
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            for batch in scene.profileFills where !batch.triangles.isEmpty {
                var body = BodyUniforms()
                body.modelMatrix = matrix_identity_float4x4
                body.baseColor = batch.color
                let length = batch.triangles.count * MemoryLayout<SIMD3<Float>>.stride
                guard let buffer = batch.triangles.withUnsafeBytes({ raw in
                    context.device.makeBuffer(bytes: raw.baseAddress!, length: length,
                                              options: .storageModeShared)
                }) else { continue }
                encoder.setVertexBuffer(buffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
                encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                       index: Int(BufferIndexBodyUniforms.rawValue))
                encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                         index: Int(BufferIndexBodyUniforms.rawValue))
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: batch.triangles.count)
            }
        }

        // 5. Sketch overlay lines (edge pipeline: depth-biased line list)
        if !scene.sketchLines.isEmpty {
            encoder.setRenderPipelineState(pipelines.edge)
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            for batch in scene.sketchLines where !batch.segments.isEmpty {
                var body = BodyUniforms()
                body.modelMatrix = matrix_identity_float4x4
                body.baseColor = batch.color
                let length = batch.segments.count * MemoryLayout<SIMD3<Float>>.stride
                guard let buffer = batch.segments.withUnsafeBytes({ raw in
                    context.device.makeBuffer(bytes: raw.baseAddress!, length: length,
                                              options: .storageModeShared)
                }) else { continue }
                encoder.setVertexBuffer(buffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
                encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                       index: Int(BufferIndexBodyUniforms.rawValue))
                encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                         index: Int(BufferIndexBodyUniforms.rawValue))
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: batch.segments.count)
            }
        }

        // 6. Translucent bodies (previews) last
        for drawable in scene.bodies where drawable.isTranslucent {
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            drawBody(drawable, encoder: encoder, pipeline: pipelines.litBlended)
        }
    }

    // MARK: - Thumbnail capture

    /// Offscreen render of the current scene (no gizmo), returned as PNG data.
    /// Screenshot options: `transparentBackground` clears to alpha 0 and skips
    /// the gradient pass; `showGrid` off skips the ground grid.
    func makeThumbnailPNG(
        width: Int = 640,
        height: Int = 480,
        transparentBackground: Bool = false,
        showGrid: Bool = true
    ) -> Data? {
        let device = context.device

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderContext.colorPixelFormat, width: width, height: height, mipmapped: false
        )
        colorDescriptor.textureType = .type2DMultisample
        colorDescriptor.sampleCount = RenderContext.sampleCount
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .private

        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderContext.colorPixelFormat, width: width, height: height, mipmapped: false
        )
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .shared

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderContext.depthPixelFormat, width: width, height: height, mipmapped: false
        )
        depthDescriptor.textureType = .type2DMultisample
        depthDescriptor.sampleCount = RenderContext.sampleCount
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private

        guard
            let colorTexture = device.makeTexture(descriptor: colorDescriptor),
            let resolveTexture = device.makeTexture(descriptor: resolveDescriptor),
            let depthTexture = device.makeTexture(descriptor: depthDescriptor),
            let commandBuffer = context.commandQueue.makeCommandBuffer()
        else {
            NSLog("[openshape3d] thumbnail: texture/commandBuffer creation failed")
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].resolveTexture = resolveTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = transparentBackground
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            NSLog("[openshape3d] thumbnail: encoder creation failed")
            return nil
        }

        cache.sync(with: scene, device: context.device)
        var frame = makeFrameUniforms(viewportSize: CGSize(width: width, height: height))
        encodeScene(
            encoder: encoder,
            frame: &frame,
            drawBackground: !transparentBackground,
            drawGrid: showGrid
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back BGRA and wrap as PNG.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            resolveTexture.getBytes(
                raw.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard
            let providerData = CFDataCreate(nil, pixels, pixels.count),
            let provider = CGDataProvider(data: providerData),
            let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            NSLog("[openshape3d] thumbnail: CGImage creation failed")
            return nil
        }
        return UIImage(cgImage: image).pngData()
    }

    // MARK: - Draw helpers

    private func drawBody(
        _ drawable: BodyDrawable,
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState
    ) {
        guard let resources = cache.resources(for: drawable.id) else { return }
        encoder.setRenderPipelineState(pipeline)
        var body = makeBodyUniforms(drawable)
        encoder.setVertexBuffer(resources.positionBuffer, offset: 0,
                                index: Int(BufferIndexPositions.rawValue))
        encoder.setVertexBuffer(resources.normalBuffer, offset: 0,
                                index: Int(BufferIndexNormals.rawValue))
        encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                               index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                 index: Int(BufferIndexBodyUniforms.rawValue))
        var frame = makeFrameUniforms()
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                                 index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.indexCount,
            indexType: .uint32,
            indexBuffer: resources.indexBuffer,
            indexBufferOffset: 0
        )
    }

    private func drawEdges(_ drawable: BodyDrawable, encoder: MTLRenderCommandEncoder) {
        guard let resources = cache.resources(for: drawable.id),
              let edgeBuffer = resources.edgeVertexBuffer,
              resources.edgeVertexCount > 0
        else { return }
        var body = makeBodyUniforms(drawable)
        let selected = drawable.selectionState == SelectionStateSelected.rawValue
        body.baseColor = selected
            ? makeFrameUniforms().accentColor
            : SIMD4(0.13, 0.15, 0.17, 1)
        encoder.setVertexBuffer(edgeBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
        encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                               index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                 index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: resources.edgeVertexCount)
    }

    // MARK: - Uniforms

    private func makeFrameUniforms(viewportSize: CGSize? = nil) -> FrameUniforms {
        let viewportSize = viewportSize ?? self.viewportSize
        let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
        let cameraPosition = camera.position

        // Headlight: key light fixed relative to the camera, offset up and left,
        // so the model never goes dark while orbiting.
        let view = camera.viewMatrix
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        let forward = simd_normalize(camera.target - cameraPosition)
        let lightDirection = simd_normalize(forward + right * 0.35 - up * 0.45)

        var frame = FrameUniforms()
        frame.viewProjectionMatrix = camera.viewProjection(aspect: aspect)
        frame.cameraPosition = SIMD4(cameraPosition, 1)
        frame.keyLightDirection = SIMD4(lightDirection, 0)
        frame.skyColor = SIMD4(1.0, 1.0, 1.05, 1)
        frame.groundColor = SIMD4(0.62, 0.60, 0.58, 1)
        frame.backgroundTop = SIMD4(0.94, 0.95, 0.97, 1)
        frame.backgroundBottom = SIMD4(0.82, 0.84, 0.88, 1)
        frame.accentColor = SIMD4(0.98, 0.55, 0.12, 1) // Shapr3D-ish orange
        frame.gridParams = SIMD4(1, 10, 120, 0)
        frame.gridCenter = SIMD4(camera.target.x, 0, camera.target.z, 0)
        frame.edgeDepthBiasNDC = 1e-4
        return frame
    }

    private func makeBodyUniforms(_ drawable: BodyDrawable) -> BodyUniforms {
        var body = BodyUniforms()
        body.modelMatrix = drawable.modelMatrix
        body.baseColor = drawable.baseColor
        body.selectionState = drawable.selectionState
        return body
    }
}
