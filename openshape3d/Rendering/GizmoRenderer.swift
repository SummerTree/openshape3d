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
        let part: GizmoPart?   // nil = non-interactive (centre dot)
        let vertexRange: Range<Int>
        let color: SIMD4<Float>
    }

    private var vertexBuffer: MTLBuffer?
    private var parts: [Part] = []

    // Shapr3D-style monochrome gizmo: white translate/rotate handles, white
    // plane tiles, a cyan centre dot. Axis identity comes from position, not
    // colour (matches the reference).
    private static let handleWhite = SIMD4<Float>(0.97, 0.97, 0.99, 1)
    private static let planeWhite = SIMD4<Float>(0.97, 0.97, 0.99, 0.5)
    private static let centerCyan = SIMD4<Float>(0.20, 0.80, 0.85, 1)

    private static let colors: [GizmoPart: SIMD4<Float>] = [
        .xAxis: handleWhite, .yAxis: handleWhite, .zAxis: handleWhite,
        .yzPlane: planeWhite, .zxPlane: planeWhite, .xyPlane: planeWhite,
        .xRing: handleWhite, .yRing: handleWhite, .zRing: handleWhite,
    ]

    func prepare(device: MTLDevice) {
        guard vertexBuffer == nil else { return }
        var vertices: [SIMD3<Float>] = []
        var built: [Part] = []

        for part in [GizmoPart.xAxis, .yAxis, .zAxis] {
            let start = vertices.count
            appendArrow(along: part.axisDirection, into: &vertices)
            built.append(Part(part: part, vertexRange: start..<vertices.count,
                              color: Self.colors[part]!))
        }
        for part in [GizmoPart.xyPlane, .yzPlane, .zxPlane] {
            let start = vertices.count
            appendPlaneHandle(normalAxis: part, into: &vertices)
            built.append(Part(part: part, vertexRange: start..<vertices.count,
                              color: Self.colors[part]!))
        }
        for part in [GizmoPart.xRing, .yRing, .zRing] {
            let start = vertices.count
            appendRotationGlyph(around: part, into: &vertices)
            built.append(Part(part: part, vertexRange: start..<vertices.count,
                              color: Self.colors[part]!))
        }
        // Centre dot (free-move pivot) — non-interactive (nil part).
        let dotStart = vertices.count
        appendCenterDot(into: &vertices)
        built.append(Part(part: nil, vertexRange: dotStart..<vertices.count,
                          color: Self.centerCyan))

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
            if let p = part.part, gizmo.highlighted == p {
                // Highlight in Shapr3D blue (arrows/handles are white).
                color = SIMD4(0.20, 0.55, 0.95, 1)
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

    /// Shapr3D-style pull affordance: a flat, camera-facing blue DOUBLE-HEADED
    /// arrow (↕) — the touch/grab surface that drags the face in or out — riding a
    /// thin dark connector off the moving cap. Billboarded so it always shows the
    /// chevron profile; its "up" is the pull direction so it points along the
    /// extrude axis. Turns red when the pending result would fail (spec §18).
    func drawPullArrow(
        encoder: MTLRenderCommandEncoder,
        pipelines: PipelineStore,
        frame: inout FrameUniforms,
        arrow: PullArrowState,
        scale: Float
    ) {
        let origin = arrow.origin
        let pullDir = simd_normalize(arrow.direction)
        let camPos = SIMD3<Float>(frame.cameraPosition.x, frame.cameraPosition.y, frame.cameraPosition.z)
        let toCam = simd_normalize(camPos - origin)

        // Billboard basis: `up` = the pull direction projected into the plane
        // facing the camera, `right` perpendicular to both. Degenerate only when
        // looking straight down the pull axis, where a fallback basis is fine.
        var up = pullDir - simd_dot(pullDir, toCam) * toCam
        var right: SIMD3<Float>
        if simd_length(up) > 1e-3 {
            up = simd_normalize(up)
            right = simd_normalize(simd_cross(toCam, up))
        } else {
            let ref: SIMD3<Float> = abs(toCam.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            right = simd_normalize(simd_cross(toCam, ref))
            up = simd_normalize(simd_cross(right, toCam))
        }
        func world(_ x: Float, _ y: Float) -> SIMD3<Float> {
            origin + right * (x * scale) + up * (y * scale)
        }

        encoder.setRenderPipelineState(pipelines.unlitColor)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))

        var body = BodyUniforms()
        body.modelMatrix = matrix_identity_float4x4   // vertices are already world-space
        func fill(_ triangles: [SIMD3<Float>], _ color: SIMD4<Float>) {
            body.baseColor = color
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            triangles.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexPositions.rawValue))
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
        }

        // A filled polygon (fan from `center`, both windings) → world triangles.
        func poly(_ pts: [(Float, Float)], center: (Float, Float)) -> [SIMD3<Float>] {
            var t: [SIMD3<Float>] = []
            let c = world(center.0, center.1)
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                let A = world(a.0, a.1), B = world(b.0, b.1)
                t += [c, A, B, c, B, A]
            }
            return t
        }

        let shaftLen: Float = 0.42, sw: Float = 0.03
        let headLen: Float = 0.28, midH: Float = 0.24, W: Float = 0.30, w: Float = 0.11
        let y0 = shaftLen                         // arrow's lower tip sits atop the shaft

        // Dark connector.
        fill(poly([(-sw, 0), (sw, 0), (sw, shaftLen), (-sw, shaftLen)],
                  center: (0, shaftLen * 0.5)), SIMD4(0.14, 0.15, 0.17, 1))

        // Blue double-arrow: down tip, up the right head/shaft, up tip, down the left.
        let arrowPts: [(Float, Float)] = [
            (0, y0),
            (W, y0 + headLen), (w, y0 + headLen),
            (w, y0 + headLen + midH), (W, y0 + headLen + midH),
            (0, y0 + 2 * headLen + midH),
            (-W, y0 + headLen + midH), (-w, y0 + headLen + midH),
            (-w, y0 + headLen), (-W, y0 + headLen),
        ]
        let handle: SIMD4<Float> = arrow.isValid ? SIMD4(0.31, 0.57, 0.98, 1) : SIMD4(0.90, 0.28, 0.28, 1)
        fill(poly(arrowPts, center: (0, y0 + headLen + midH * 0.5)), handle)
    }

    /// Plane picker tiles: translucent bordered quads in world space. Tiny
    /// vertex payloads, so setVertexBytes instead of buffers.
    func drawPlaneTiles(
        encoder: MTLRenderCommandEncoder,
        pipelines: PipelineStore,
        frame: inout FrameUniforms,
        tiles: [PlanePickerTile]
    ) {
        guard !tiles.isEmpty else { return }
        encoder.setRenderPipelineState(pipelines.unlitColor)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))

        for tile in tiles {
            let c = tile.worldCorners
            // Both windings so the quad is visible from either side.
            let triangles: [SIMD3<Float>] = [
                c[0], c[1], c[2], c[0], c[2], c[3],
                c[0], c[2], c[1], c[0], c[3], c[2],
            ]
            let border: [SIMD3<Float>] = [c[0], c[1], c[1], c[2], c[2], c[3], c[3], c[0]]

            var body = BodyUniforms()
            body.modelMatrix = matrix_identity_float4x4
            body.baseColor = tile.color
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            triangles.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexPositions.rawValue))
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)

            body.baseColor = SIMD4(tile.color.x, tile.color.y, tile.color.z, 1)
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            border.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexPositions.rawValue))
            }
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: border.count)
        }
    }

    // MARK: - Mesh generation (gizmo-local space, unit length arrows)

    private func appendArrow(along axis: SIMD3<Float>, into vertices: inout [SIMD3<Float>]) {
        // Shorter, slimmer than before so the gizmo reads as a tight cluster.
        let shaftRadius: Float = 0.014
        let shaftLength: Float = 0.62
        let coneRadius: Float = 0.055
        let coneLength: Float = 0.2
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

    /// A small curved rotation glyph (short arc + arrowheads) in the ring's
    /// plane — Shapr3D's rotation affordance instead of a full ring. The hit
    /// test still uses the full circle at GizmoGeometry.ringRadius (forgiving).
    private func appendRotationGlyph(around part: GizmoPart, into vertices: inout [SIMD3<Float>]) {
        let r = GizmoGeometry.ringRadius
        let half: Float = 0.014            // band half-thickness
        let (u, v) = GizmoGeometry.ringBasis(for: part)
        // Arc centred at a fixed local angle, ~70° wide.
        let center: Float = .pi / 4
        let span: Float = 70 * .pi / 180
        let a0 = center - span / 2, a1 = center + span / 2
        let steps = 16
        func dir(_ a: Float) -> SIMD3<Float> { u * cos(a) + v * sin(a) }

        for i in 0..<steps {
            let t0 = a0 + (a1 - a0) * Float(i) / Float(steps)
            let t1 = a0 + (a1 - a0) * Float(i + 1) / Float(steps)
            let d0 = dir(t0), d1 = dir(t1)
            let c0 = d0 * (r - half), c1 = d0 * (r + half)
            let c2 = d1 * (r + half), c3 = d1 * (r - half)
            vertices.append(contentsOf: [c0, c1, c2, c0, c2, c3])
            vertices.append(contentsOf: [c0, c2, c1, c0, c3, c2])
        }
        // Tangential arrowheads at each arc end.
        func head(at a: Float, pointing forward: Bool) {
            let p = dir(a) * r
            let radial = dir(a)
            var tangent = u * -sin(a) + v * cos(a)
            if !forward { tangent = -tangent }
            let tip = p + tangent * 0.09
            let b1 = p + radial * 0.05
            let b2 = p - radial * 0.05
            vertices.append(contentsOf: [tip, b1, b2])
            vertices.append(contentsOf: [tip, b2, b1])
        }
        head(at: a0, pointing: false)
        head(at: a1, pointing: true)
    }

    /// A small cyan sphere-ish dot at the origin (free-move pivot).
    private func appendCenterDot(into vertices: inout [SIMD3<Float>]) {
        let r: Float = 0.055
        // Octahedron.
        let p = [SIMD3<Float>(r,0,0), SIMD3(-r,0,0), SIMD3(0,r,0),
                 SIMD3(0,-r,0), SIMD3(0,0,r), SIMD3(0,0,-r)]
        let faces = [(0,2,4),(2,1,4),(1,3,4),(3,0,4),
                     (2,0,5),(1,2,5),(3,1,5),(0,3,5)]
        for (a, b, c) in faces {
            vertices.append(contentsOf: [p[a], p[b], p[c]])
        }
    }

    private func perpendicularBasis(for axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let reference: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(reference, axis))
        let v = simd_cross(axis, u)
        return (u, v)
    }
}
