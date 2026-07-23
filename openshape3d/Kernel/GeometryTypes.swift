//
//  GeometryTypes.swift
//  openshape3d
//
//  Core model types for the geometry kernel. Everything here is nonisolated —
//  the kernel runs off the main actor (CSG, extrude, edge extraction).
//  Convention: kernel/model space is Double, GPU buffers are Float32.
//

import Foundation
import simd
import Euclid

nonisolated struct BodyID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

nonisolated struct SketchID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

/// TRS transform (uniform scale only). Applied as a per-body uniform in the
/// viewport; baked into mesh coordinates only for booleans and export.
nonisolated struct Transform3D: Equatable, Sendable {
    var translation: SIMD3<Double> = .zero
    var rotation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var scale: Double = 1

    static let identity = Transform3D()

    var matrix: simd_double4x4 {
        var result = simd_double4x4(rotation)
        result.columns.0 *= scale
        result.columns.1 *= scale
        result.columns.2 *= scale
        result.columns.3 = SIMD4(translation, 1)
        return result
    }

    var matrixFloat: simd_float4x4 {
        let m = matrix
        return simd_float4x4(
            SIMD4<Float>(m.columns.0),
            SIMD4<Float>(m.columns.1),
            SIMD4<Float>(m.columns.2),
            SIMD4<Float>(m.columns.3)
        )
    }

    var euclid: Euclid.Transform {
        Euclid.Transform(
            scale: Vector(scale, scale, scale),
            rotation: Rotation(rotation),
            translation: Vector(translation.x, translation.y, translation.z)
        )
    }

    func applying(to point: SIMD3<Double>) -> SIMD3<Double> {
        rotation.act(point * scale) + translation
    }
}

nonisolated extension Transform3D: Codable {
    private enum CodingKeys: String, CodingKey {
        case translation, rotation, scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let t = try container.decode([Double].self, forKey: .translation)
        let r = try container.decode([Double].self, forKey: .rotation)
        guard t.count == 3, r.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .translation, in: container,
                debugDescription: "Expected 3 translation and 4 rotation components"
            )
        }
        translation = SIMD3(t[0], t[1], t[2])
        rotation = simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3])
        scale = try container.decode(Double.self, forKey: .scale)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([translation.x, translation.y, translation.z], forKey: .translation)
        try container.encode(
            [rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real],
            forKey: .rotation
        )
        try container.encode(scale, forKey: .scale)
    }
}

/// Parametric definition a primitive body keeps until a boolean/extrude bakes it.
nonisolated enum PrimitiveSpec: Codable, Equatable, Sendable {
    case box(width: Double, depth: Double, height: Double)
    case cylinder(radius: Double, height: Double)
    case sphere(radius: Double)

    var displayName: String {
        switch self {
        case .box: "Box"
        case .cylinder: "Cylinder"
        case .sphere: "Sphere"
        }
    }
}

/// A solid body in the document, in body-local coordinates. `render`/`edges`
/// are always present (documents open straight into drawable buffers); the
/// Euclid mesh is a lazy cache rebuilt from triangles when CSG/export needs it.
nonisolated struct Body: Identifiable, Sendable {
    let id: BodyID
    var name: String
    var transform: Transform3D = .identity
    var primitive: PrimitiveSpec?
    var render: RenderMesh
    var edges: FeatureEdgeSet
    /// Bumped whenever the geometry changes so the GPU cache rebuilds buffers.
    var meshRevision: UInt64
    /// Items Manager visibility (spec §11): hidden bodies stay in the
    /// document but are skipped by the viewport scene.
    var isHidden: Bool = false
    /// Visualization-lite appearance (plan §B15); nil keeps the legacy
    /// default look exactly.
    var material: BodyMaterialSpec?
    /// Euclid source mesh, if this body was just built/booleaned in-session.
    /// Nil after loading from disk; use `euclidMesh()` which rebuilds on demand.
    var euclid: Euclid.Mesh?
    /// OCCT B-rep handle when this body was built through the OCCT source-of-truth
    /// path (extrude/boolean). Transient (not persisted); lets downstream ops
    /// (boolean composition, smooth re-render) stay analytic. Nil = Euclid-only.
    var brep: BRepHandle?

    /// Build from a freshly generated Euclid mesh (primitive, extrude, boolean).
    init(
        id: BodyID = BodyID(),
        name: String,
        transform: Transform3D = .identity,
        primitive: PrimitiveSpec? = nil,
        euclidMesh: Euclid.Mesh,
        revision: UInt64
    ) {
        self.id = id
        self.name = name
        self.transform = transform
        self.primitive = primitive
        self.euclid = euclidMesh
        self.render = EuclidBridge.renderMesh(from: euclidMesh)
        self.edges = FeatureEdgeExtractor.edges(from: self.render)
        self.meshRevision = revision
    }

    /// Build from persisted render buffers (document load).
    init(
        id: BodyID,
        name: String,
        transform: Transform3D,
        primitive: PrimitiveSpec?,
        render: RenderMesh,
        revision: UInt64
    ) {
        self.id = id
        self.name = name
        self.transform = transform
        self.primitive = primitive
        self.render = render
        self.edges = FeatureEdgeExtractor.edges(from: render)
        self.meshRevision = revision
        self.euclid = nil
    }

    /// The CSG-ready mesh, rebuilding from triangle buffers if needed.
    func euclidMesh() -> Euclid.Mesh {
        euclid ?? EuclidBridge.euclidMesh(from: render)
    }
}
