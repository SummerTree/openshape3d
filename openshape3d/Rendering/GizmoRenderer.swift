//
//  GizmoRenderer.swift
//  openshape3d
//
//  Procedural move-gizmo mesh (XYZ arrows + three quarter-plane handles),
//  built once in gizmo-local space and drawn in an overlay pass with cleared
//  depth so it always sits on top of the model.
//

import Foundation
import Metal
import simd

final class GizmoRenderer {
    private struct Part {
        let part: GizmoPart
        let vertexRange: Range<Int>
        let color: SIMD4<Float>
    }

    private var vertexBuffer: MTLBuffer?
    private var parts: [Part] = []

    private static let axisColors: [GizmoPart: SIMD4<Float>] = [
        .xAxis: SIMD4(0.88, 0.26, 0.26, 1),
        .yAxis: SIMD4(0.35, 0.72, 0.28, 1),
        .zAxis: SIMD4(0.26, 0.47, 0.90, 1),
        .yzPlane: SIMD4(0.88, 0.26, 0.26, 0.35),
        .zxPlane: SIMD4(0.35, 0.72, 0.28, 0.35),
        .xyPlane: SIMD4(0.26, 0.47, 0.90, 0.35),
    ]

    func prepare(device: MTLDevice) {
        guard vertexBuffer == nil else { return }
        var vertices: [SIMD3<Float>] = []
        var built: [Part] = []

        for part in [GizmoPart.xAxis, .yAxis, .zAxis] {
            let start = vertices.count
            appendArrow(along: part.axisDirection, into: &vertices)
            built.append(Part(
                part: part,
                vertexRange: start..<vertices.count,
                color: Self.axisColors[part]!
            ))
        }
        for part in [GizmoPart.xyPlane, .yzPlane, .zxPlane] {
            let start = vertices.count
            appendPlaneHandle(normalAxis: part, into: &vertices)
            built.append(Part(
                part: part,
                vertexRange: start..<vertices.count,
                color: Self.axisColors[part]!
            ))
        }

        vertexBuffer = vertices.withUnsafeBytes { raw in
            device.makeBuffer(
                bytes: raw.baseAddress!,
                length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            )
        }
        parts = built
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        pipelines: PipelineStore,
        frame: inout FrameUniforms,
        gizmo: GizmoState
    ) {
        guard let vertexBuffer else { return }

        var model = matrix_identity_float4x4
        model.columns.0 *= gizmo.scale
        model.columns.1 *= gizmo.scale
        model.columns.2 *= gizmo.scale
        model.columns.3 = SIMD4(gizmo.origin, 1)

        encoder.setRenderPipelineState(pipelines.unlitColor)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))

        for part in parts {
            var body = BodyUniforms()
            body.modelMatrix = model
            var color = part.color
            if gizmo.highlighted == part.part {
                color = SIMD4(
                    min(color.x * 1.35 + 0.1, 1),
                    min(color.y * 1.35 + 0.1, 1),
                    min(color.z * 1.35 + 0.1, 1),
                    min(color.w + 0.3, 1)
                )
            }
            body.baseColor = color
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: part.vertexRange.lowerBound,
                vertexCount: part.vertexRange.count
            )
        }
    }

    // MARK: - Mesh generation (gizmo-local space, unit length arrows)

    private func appendArrow(along axis: SIMD3<Float>, into vertices: inout [SIMD3<Float>]) {
        let shaftRadius: Float = 0.02
        let shaftLength: Float = 0.72
        let coneRadius: Float = 0.07
        let coneLength: Float = 0.28
        let segments = 16

        let (u, v) = perpendicularBasis(for: axis)

        func ring(radius: Float, at distance: Float) -> [SIMD3<Float>] {
            (0..<segments).map { i in
                let angle = Float(i) / Float(segments) * 2 * .pi
                return axis * distance + (u * cos(angle) + v * sin(angle)) * radius
            }
        }

        let base = ring(radius: shaftRadius, at: 0)
        let top = ring(radius: shaftRadius, at: shaftLength)
        let coneBase = ring(radius: coneRadius, at: shaftLength)
        let tip = axis * (shaftLength + coneLength)

        for i in 0..<segments {
            let j = (i + 1) % segments
            // Shaft side quad
            vertices.append(contentsOf: [base[i], top[i], top[j]])
            vertices.append(contentsOf: [base[i], top[j], base[j]])
            // Cone base cap
            vertices.append(contentsOf: [axis * shaftLength, coneBase[j], coneBase[i]])
            // Cone side
            vertices.append(contentsOf: [coneBase[i], coneBase[j], tip])
        }
    }

    private func appendPlaneHandle(normalAxis part: GizmoPart, into vertices: inout [SIMD3<Float>]) {
        let lo = GizmoGeometry.planeMin
        let hi = GizmoGeometry.planeMax
        let corners: [SIMD2<Float>] = [
            SIMD2(lo, lo), SIMD2(hi, lo), SIMD2(hi, hi), SIMD2(lo, hi),
        ]
        func lift(_ p: SIMD2<Float>) -> SIMD3<Float> {
            switch part {
            case .xyPlane: SIMD3(p.x, p.y, 0)
            case .yzPlane: SIMD3(0, p.x, p.y)
            case .zxPlane: SIMD3(p.y, 0, p.x)
            default: .zero
            }
        }
        let c = corners.map(lift)
        // Both windings so the quad is visible from either side.
        vertices.append(contentsOf: [c[0], c[1], c[2]])
        vertices.append(contentsOf: [c[0], c[2], c[3]])
        vertices.append(contentsOf: [c[0], c[2], c[1]])
        vertices.append(contentsOf: [c[0], c[3], c[2]])
    }

    private func perpendicularBasis(for axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let reference: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(reference, axis))
        let v = simd_cross(axis, u)
        return (u, v)
    }
}
