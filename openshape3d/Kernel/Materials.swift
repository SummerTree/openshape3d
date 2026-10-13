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
