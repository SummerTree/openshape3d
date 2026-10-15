//
//  Materials.swift
//  openshape3d
//
//  Visualization-lite body materials (plan §B15): a persisted per-body
//  appearance (flat color + metallic/roughness) plus the small preset
//  library the Material sheet offers. Model space is Double; the editor
//  bridges to the Float32 BodyMaterial render uniform.
//

import Foundation
import simd

/// Persisted appearance of a body. Backward compatible: absent on old
/// documents (decodeIfPresent on the owning blob → nil keeps the legacy
/// default look).
nonisolated struct BodyMaterialSpec: Codable, Equatable, Sendable {
    /// Linear-ish RGBA in 0…1 (matches the renderer's baseColor space).
    var baseColor: SIMD4<Double>
    /// 0 = dielectric (legacy shading path), 1 = metal.
    var metallic: Double = 0
    /// 0 keeps the legacy fixed highlight; > 0 widens/softens it.
    var roughness: Double = 0
    /// Encoded image bytes (PNG/JPEG) multiplied into `baseColor` where the
    /// body's mesh carries texture coordinates — how an imported OBJ, glTF or
    /// USDZ keeps its look. Nil for every modelled body. Optional in the
    /// JSON, so pre-texture material records decode unchanged.
    var baseColorTexture: Data? = nil
    /// Glow (spec §14 emission): 0 lit normally; toward 1 the surface shows
    /// its own colour, brighter, whatever the light. Absent in older records.
    var emission: Double = 0

    /// The document default — identical to the pre-material body color and
    /// shading, so assigning it changes nothing visually.
    static let `default` = BodyMaterialSpec(
        baseColor: SIMD4(0.72, 0.74, 0.78, 1), metallic: 0, roughness: 0
    )

    init(baseColor: SIMD4<Double>, metallic: Double = 0, roughness: Double = 0,
         baseColorTexture: Data? = nil, emission: Double = 0) {
        self.baseColor = baseColor
        self.metallic = metallic
        self.roughness = roughness
        self.baseColorTexture = baseColorTexture
        self.emission = emission
    }

    private enum CodingKeys: String, CodingKey { case baseColor, metallic, roughness, baseColorTexture, emission }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseColor = try c.decode(SIMD4<Double>.self, forKey: .baseColor)
        metallic = try c.decodeIfPresent(Double.self, forKey: .metallic) ?? 0
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 0
        baseColorTexture = try c.decodeIfPresent(Data.self, forKey: .baseColorTexture)
        emission = try c.decodeIfPresent(Double.self, forKey: .emission) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseColor, forKey: .baseColor)
        try c.encode(metallic, forKey: .metallic)
        try c.encode(roughness, forKey: .roughness)
        try c.encodeIfPresent(baseColorTexture, forKey: .baseColorTexture)
        // Written only when set, so a plain material's record is unchanged.
        if emission != 0 { try c.encode(emission, forKey: .emission) }
    }

    /// Clamped copy: colors and factors pinned to 0…1 (slider/decode safety).
    var clamped: BodyMaterialSpec {
        BodyMaterialSpec(
            baseColor: simd_clamp(baseColor, SIMD4(repeating: 0), SIMD4(repeating: 1)),
            metallic: min(max(metallic, 0), 1),
            roughness: min(max(roughness, 0), 1),
            baseColorTexture: baseColorTexture,
            emission: min(max(emission, 0), 1)
        )
    }
}

/// A material on one face of a body (spec §14, per-face materials). The face
/// is found again by a point on it and its outward normal, in the body's own
/// coordinates — so it follows the body as it moves, survives edits that
/// leave the face where it is, and works for imported meshes, which have no
/// feature history. A face a later edit moves away simply drops its material.
nonisolated struct FaceMaterial: Codable, Equatable, Sendable {
    var point: SIMD3<Double>
    var normal: SIMD3<Double>
    var material: BodyMaterialSpec
}

nonisolated enum FaceMaterialKit {
    /// `mesh`'s indices without `triangles` (the faces that wear their own
    /// material, drawn as patches) and a revision for them that differs
    /// from every plain mesh revision and changes with the set left out;
    /// nil when nothing is left out.
    static func drawnIndices(of mesh: RenderMesh, without triangles: [Int],
                             revision: UInt64) -> (indices: [UInt32], revision: UInt64)? {
        let out = Set(triangles)
        guard !out.isEmpty else { return nil }
        var indices: [UInt32] = []
        indices.reserveCapacity(max(0, mesh.indices.count - out.count * 3))
        for t in 0..<mesh.triangleCount where !out.contains(t) {
            indices += mesh.indices[t * 3 ..< t * 3 + 3]
        }
        var hasher = Hasher()
        hasher.combine(revision)
        hasher.combine(out.sorted())
        // The top bit set: plain revisions are counters and never reach it.
        return (indices, UInt64(bitPattern: Int64(hasher.finalize())) | (1 << 63))
    }

    /// The face a tap on `seedTriangle` means: a flat face, or the curved
    /// surface (a cylinder wall, a blend) under it. Surfaces that meet
    /// smoothly — a plate's top, its fillets and its sides — are told apart
    /// by size: within one smooth region a flat face is far bigger than the
    /// thin facets a curve is drawn with, so it stands alone, and a curve is
    /// the connected run of facets between the flat faces.
    static func region(in mesh: RenderMesh, seedTriangle: Int) -> [Int]? {
        let flat = FaceTopology.planarFace(in: mesh, seedTriangle: seedTriangle)
        guard let smooth = FaceTopology.smoothRegion(in: mesh, seedTriangle: seedTriangle), smooth.isCurved,
              flat.map({ $0.triangles.count < smooth.triangles.count }) ?? true else {
            return flat?.triangles
        }
        let triangles = smooth.triangles
        let neighbours = adjacency(of: triangles, in: mesh)
        // Coplanar patches within the region, and their areas.
        var patchOf: [Int: Int] = [:]
        var patches: [[Int]] = []
        for start in triangles where patchOf[start] == nil {
            guard let base = plane(mesh, start) else { patchOf[start] = -1; continue }
            let id = patches.count
            var patch = [start], queue = [start]
            patchOf[start] = id
            while let t = queue.popLast() {
                for n in neighbours[t] ?? [] where patchOf[n] == nil {
                    guard let other = plane(mesh, n), simd_dot(other.normal, base.normal) > 0.99995 else { continue }
                    patchOf[n] = id
                    patch.append(n)
                    queue.append(n)
                }
            }
            patches.append(patch)
        }
        let areas = patches.map { $0.reduce(0) { $0 + area(mesh, $1) } }
        let median = areas.sorted()[areas.count / 2]
        let isFlatFace = areas.map { $0 > 4 * median }
        if let seedPatch = patchOf[seedTriangle], seedPatch >= 0, isFlatFace[seedPatch] {
            return patches[seedPatch].sorted()
        }
        // On a curve: its facets connected to the seed, short of the flat faces.
        var picked: Set<Int> = [seedTriangle], queue = [seedTriangle]
        while let t = queue.popLast() {
            for n in neighbours[t] ?? [] where !picked.contains(n) {
                if let p = patchOf[n], p >= 0, isFlatFace[p] { continue }
                picked.insert(n)
                queue.append(n)
            }
        }
        return picked.sorted()
    }

    /// The outline of a set of triangles: the edges only one of them has.
    static func boundary(of triangles: [Int], in mesh: RenderMesh) -> [(SIMD3<Float>, SIMD3<Float>)] {
        struct Edge: Hashable { var a: SIMD3<Float>, b: SIMD3<Float> }
        var count: [Edge: Int] = [:]
        var order: [Edge] = []
        for t in triangles where t < mesh.triangleCount {
            let p = (0..<3).map { mesh.positions[Int(mesh.indices[t * 3 + $0])] }
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let e = (p[i].x, p[i].y, p[i].z) < (p[j].x, p[j].y, p[j].z) ? Edge(a: p[i], b: p[j]) : Edge(a: p[j], b: p[i])
                if count[e] == nil { order.append(e) }
                count[e, default: 0] += 1
            }
        }
        return order.filter { count[$0] == 1 }.map { ($0.a, $0.b) }
    }

    /// Triangles of `triangles` sharing an edge, by corner position.
    private static func adjacency(of triangles: [Int], in mesh: RenderMesh) -> [Int: [Int]] {
        struct Edge: Hashable { var a: SIMD3<Float>, b: SIMD3<Float> }
        func edge(_ p: SIMD3<Float>, _ q: SIMD3<Float>) -> Edge {
            (p.x, p.y, p.z) < (q.x, q.y, q.z) ? Edge(a: p, b: q) : Edge(a: q, b: p)
        }
        var byEdge: [Edge: [Int]] = [:]
        for t in triangles {
            let p = (0..<3).map { mesh.positions[Int(mesh.indices[t * 3 + $0])] }
            for (i, j) in [(0, 1), (1, 2), (2, 0)] { byEdge[edge(p[i], p[j]), default: []].append(t) }
        }
        var out: [Int: [Int]] = [:]
        for shared in byEdge.values where shared.count > 1 {
            for t in shared { out[t, default: []] += shared.filter { $0 != t } }
        }
        return out
    }

    private static func plane(_ mesh: RenderMesh, _ t: Int) -> (normal: SIMD3<Double>, point: SIMD3<Double>)? {
        guard let (a, b, c) = corners(mesh, t) else { return nil }
        let n = simd_cross(b - a, c - a)
        guard simd_length(n) > 1e-12 else { return nil }
        return (simd_normalize(n), a)
    }

    private static func area(_ mesh: RenderMesh, _ t: Int) -> Double {
        guard let (a, b, c) = corners(mesh, t) else { return 0 }
        return simd_length(simd_cross(b - a, c - a)) / 2
    }

    /// Where a face is remembered: the tapped triangle's centre and normal.
    static func anchor(in mesh: RenderMesh, triangle: Int) -> (point: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard let (a, b, c) = corners(mesh, triangle) else { return nil }
        let n = simd_cross(b - a, c - a)
        guard simd_length(n) > 1e-12 else { return nil }
        return ((a + b + c) / 3, simd_normalize(n))
    }

    /// The triangle an anchor lands on: the nearest one facing its way,
    /// within a small tolerance of the body's size. Nil when the face has
    /// moved away.
    static func seed(in mesh: RenderMesh, point: SIMD3<Double>, normal: SIMD3<Double>) -> Int? {
        let box = mesh.localAABB
        let size = simd_length(SIMD3<Double>(box.max) - SIMD3<Double>(box.min))
        let tolerance = Swift.max(0.05, size * 0.002)
        var best: (triangle: Int, distance: Double)?
        for t in 0..<mesh.triangleCount {
            guard let (a, b, c) = corners(mesh, t) else { continue }
            let n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            // Facing the same way (a curved face's facets turn a little).
            guard length > 1e-12, simd_dot(n / length, normal) > 0.8 else { continue }
            let d = simd_distance(point, closestPoint(point, a, b, c))
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (t, d) }
        }
        return best?.triangle
    }

    /// Each face material's triangles on `mesh`, in order (a later one wins
    /// a triangle two share); empty for a face no longer found.
    static func resolve(_ faces: [FaceMaterial], in mesh: RenderMesh) -> [[Int]] {
        var owner = [Int](repeating: -1, count: mesh.triangleCount)
        for (i, face) in faces.enumerated() {
            guard let seed = seed(in: mesh, point: face.point, normal: face.normal),
                  let triangles = region(in: mesh, seedTriangle: seed) else { continue }
            for t in triangles where t < owner.count { owner[t] = i }
        }
        var out = [[Int]](repeating: [], count: faces.count)
        for (t, i) in owner.enumerated() where i >= 0 { out[i].append(t) }
        return out
    }

    /// `faces` with a material set on the faces whose triangles are `targets`
    /// (nil clears them): any face material already covering one of those
    /// triangles is replaced.
    static func setting(_ material: BodyMaterialSpec?, on targets: [(point: SIMD3<Double>, normal: SIMD3<Double>,
                                                                     triangles: [Int])],
                        in faces: [FaceMaterial], mesh: RenderMesh) -> [FaceMaterial] {
        let covered = Set(targets.flatMap(\.triangles))
        let resolved = resolve(faces, in: mesh)
        var out = faces.indices.filter { !resolved[$0].contains(where: covered.contains) }.map { faces[$0] }
        if let material {
            out += targets.map { FaceMaterial(point: $0.point, normal: $0.normal, material: material) }
        }
        return out
    }

    private static func corners(_ mesh: RenderMesh, _ t: Int)
        -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)? {
        guard t >= 0, t < mesh.triangleCount else { return nil }
        let i = mesh.indices[t * 3], j = mesh.indices[t * 3 + 1], k = mesh.indices[t * 3 + 2]
        guard Int(Swift.max(i, j, k)) < mesh.positions.count else { return nil }
        return (SIMD3<Double>(mesh.positions[Int(i)]), SIMD3<Double>(mesh.positions[Int(j)]),
                SIMD3<Double>(mesh.positions[Int(k)]))
    }

    /// The point of triangle abc nearest `p` (Ericson, Real-Time Collision Detection 5.1.5).
    private static func closestPoint(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>,
                                     _ c: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }
}

/// A named entry in the material library (spec §14), by category.
nonisolated struct MaterialPreset: Identifiable, Sendable {
    var name: String
    var category: Category
    var spec: BodyMaterialSpec
    var id: String { name }

    enum Category: String, CaseIterable, Sendable {
        case metal = "Metal", plastic = "Plastic", rubber = "Rubber", wood = "Wood", glass = "Glass"
        case stone = "Stone", ceramic = "Ceramic", fabric = "Fabric", paint = "Paint", emissive = "Emissive"
    }

    private init(_ name: String, _ category: Category, _ r: Double, _ g: Double, _ b: Double,
                 metallic: Double = 0, roughness: Double, alpha: Double = 1, emission: Double = 0) {
        self.name = name
        self.category = category
        spec = BodyMaterialSpec(baseColor: SIMD4(r, g, b, alpha), metallic: metallic, roughness: roughness,
                                emission: emission)
    }

    /// Flat-colour library. The first seven are the original starter set,
    /// kept in order and value (saved designs and the agent name them).
    static let library: [MaterialPreset] = [
        MaterialPreset("Steel", .metal, 0.62, 0.64, 0.67, metallic: 1, roughness: 0.35),
        MaterialPreset("Aluminum", .metal, 0.83, 0.85, 0.87, metallic: 1, roughness: 0.22),
        MaterialPreset("Brass", .metal, 0.85, 0.68, 0.30, metallic: 1, roughness: 0.30),
        MaterialPreset("Plastic Matte", .plastic, 0.90, 0.91, 0.93, roughness: 0.85),
        MaterialPreset("Plastic Gloss", .plastic, 0.16, 0.45, 0.95, roughness: 0.12),
        MaterialPreset("Rubber", .rubber, 0.13, 0.13, 0.14, roughness: 0.95),
        MaterialPreset("Wood", .wood, 0.55, 0.38, 0.22, roughness: 0.75),
        // Metals
        MaterialPreset("Stainless Steel", .metal, 0.70, 0.71, 0.72, metallic: 1, roughness: 0.18),
        MaterialPreset("Brushed Aluminum", .metal, 0.78, 0.79, 0.80, metallic: 1, roughness: 0.45),
        MaterialPreset("Chrome", .metal, 0.92, 0.93, 0.95, metallic: 1, roughness: 0.05),
        MaterialPreset("Copper", .metal, 0.86, 0.50, 0.33, metallic: 1, roughness: 0.28),
        MaterialPreset("Gold", .metal, 0.95, 0.76, 0.34, metallic: 1, roughness: 0.15),
        MaterialPreset("Titanium", .metal, 0.55, 0.53, 0.50, metallic: 1, roughness: 0.40),
        MaterialPreset("Cast Iron", .metal, 0.30, 0.30, 0.31, metallic: 1, roughness: 0.80),
        MaterialPreset("Anodized Black", .metal, 0.10, 0.10, 0.11, metallic: 1, roughness: 0.38),
        // Plastics
        MaterialPreset("ABS White", .plastic, 0.95, 0.95, 0.93, roughness: 0.55),
        MaterialPreset("ABS Black", .plastic, 0.07, 0.07, 0.08, roughness: 0.55),
        MaterialPreset("Plastic Red", .plastic, 0.85, 0.12, 0.10, roughness: 0.25),
        MaterialPreset("Plastic Yellow", .plastic, 0.97, 0.80, 0.10, roughness: 0.25),
        MaterialPreset("Plastic Green", .plastic, 0.15, 0.62, 0.30, roughness: 0.25),
        MaterialPreset("Nylon", .plastic, 0.92, 0.90, 0.84, roughness: 0.70),
        MaterialPreset("PLA Orange", .plastic, 0.98, 0.45, 0.10, roughness: 0.45),
        // Rubber
        MaterialPreset("Silicone Grey", .rubber, 0.55, 0.56, 0.57, roughness: 0.85),
        MaterialPreset("Rubber Red", .rubber, 0.62, 0.10, 0.08, roughness: 0.90),
        // Wood
        MaterialPreset("Oak", .wood, 0.70, 0.53, 0.33, roughness: 0.70),
        MaterialPreset("Walnut", .wood, 0.36, 0.24, 0.15, roughness: 0.65),
        MaterialPreset("Maple", .wood, 0.87, 0.74, 0.55, roughness: 0.70),
        MaterialPreset("Plywood", .wood, 0.80, 0.66, 0.45, roughness: 0.85),
        // Glass
        MaterialPreset("Clear Glass", .glass, 0.88, 0.93, 0.96, roughness: 0.04, alpha: 0.30),
        MaterialPreset("Frosted Glass", .glass, 0.90, 0.92, 0.94, roughness: 0.55, alpha: 0.55),
        MaterialPreset("Tinted Glass", .glass, 0.30, 0.42, 0.45, roughness: 0.05, alpha: 0.45),
        MaterialPreset("Clear Acrylic", .glass, 0.94, 0.96, 0.98, roughness: 0.08, alpha: 0.38),
        // Stone
        MaterialPreset("Concrete", .stone, 0.62, 0.61, 0.58, roughness: 0.92),
        MaterialPreset("Marble", .stone, 0.93, 0.92, 0.90, roughness: 0.20),
        MaterialPreset("Granite", .stone, 0.35, 0.34, 0.34, roughness: 0.45),
        // Ceramic
        MaterialPreset("Porcelain", .ceramic, 0.96, 0.96, 0.95, roughness: 0.10),
        MaterialPreset("Terracotta", .ceramic, 0.74, 0.40, 0.26, roughness: 0.85),
        // Fabric
        MaterialPreset("Felt Grey", .fabric, 0.45, 0.46, 0.48, roughness: 1),
        MaterialPreset("Leather Brown", .fabric, 0.40, 0.24, 0.14, roughness: 0.60),
        MaterialPreset("Denim", .fabric, 0.22, 0.32, 0.50, roughness: 0.95),
        // Paint
        MaterialPreset("Paint White Gloss", .paint, 0.96, 0.96, 0.96, roughness: 0.10),
        MaterialPreset("Paint Black Matte", .paint, 0.06, 0.06, 0.06, roughness: 0.90),
        MaterialPreset("Car Paint Red", .paint, 0.70, 0.04, 0.05, metallic: 0.4, roughness: 0.15),
        MaterialPreset("Car Paint Blue", .paint, 0.08, 0.20, 0.60, metallic: 0.4, roughness: 0.15),
        // Emissive
        MaterialPreset("Glow White", .emissive, 1, 1, 0.97, roughness: 0.5, emission: 1),
        MaterialPreset("Glow Warm", .emissive, 1, 0.72, 0.38, roughness: 0.5, emission: 1),
        MaterialPreset("Glow Blue", .emissive, 0.25, 0.60, 1, roughness: 0.5, emission: 1),
        MaterialPreset("Glow Red", .emissive, 1, 0.20, 0.15, roughness: 0.5, emission: 1),
    ]

    /// Library entries in `category` (nil = all) whose name or category
    /// contains every word of `query`, case- and accent-insensitively.
    static func matching(_ query: String, in category: Category? = nil) -> [MaterialPreset] {
        let words = query.split(whereSeparator: \.isWhitespace).map { String($0) }
        return library.filter { preset in
            guard category == nil || preset.category == category else { return false }
            let haystack = "\(preset.name) \(preset.category.rawValue)"
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The library entry whose look `spec` is (texture aside), if any.
    static func named(_ spec: BodyMaterialSpec) -> MaterialPreset? {
        library.first {
            $0.spec.baseColor == spec.baseColor && $0.spec.metallic == spec.metallic
                && $0.spec.roughness == spec.roughness && $0.spec.emission == spec.emission
        }
    }
}
