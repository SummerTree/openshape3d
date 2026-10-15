//
//  Visualization.swift
//  openshape3d
//
//  The Visualization workspace's environment (spec §14): a lighting preset
//  plus the sun's rotation, elevation and intensity, the background and the
//  ground shadow, saved with the design. `VisualizationLighting` turns it
//  into the renderer's light and colours — one pure function, so the iPad,
//  the Mac and the web light a design identically.
//

import Foundation
import simd

nonisolated struct VisualizationEnvironment: Codable, Equatable, Sendable {
    enum Background: String, Codable, CaseIterable, Sendable {
        /// The preset's own sky gradient.
        case environment
        /// A flat colour (`backgroundColor`).
        case color
        /// No background: captures come out with a transparent background.
        case transparent

        var title: String {
            switch self {
            case .environment: "Environment"
            case .color: "Color"
            case .transparent: "Transparent"
            }
        }
    }

    /// An `EnvironmentPreset` name.
    var preset = EnvironmentPreset.library[0].name
    /// Where the sun stands around the model, degrees (0 = in front, +Z;
    /// 90 = to the right, +X).
    var lightRotation = 35.0
    /// How high the sun stands, degrees above the horizon (0…90).
    var sunElevation = 50.0
    /// Sun strength, 0…2 (1 = the preset's own).
    var lightIntensity = 1.0
    var background: Background = .environment
    /// Linear RGB 0…1, for `.color`.
    var backgroundColor = SIMD3<Double>(1, 1, 1)
    var groundShadow = true
    /// Depth of field: what is nearer or further than the focus point blurs.
    var depthOfField = false
    /// Where the camera focuses (world); nil focuses on what the view orbits.
    var focusPoint: SIMD3<Double>?
    /// How strongly out-of-focus parts blur, 0…1.
    var blur = 0.5

    init() {}

    /// Starting from `preset` with its own sun.
    init(preset: EnvironmentPreset) {
        self.preset = preset.name
        lightRotation = preset.lightRotation
        sunElevation = preset.sunElevation
    }

    private enum CodingKeys: String, CodingKey {
        case preset, lightRotation, sunElevation, lightIntensity, background, backgroundColor, groundShadow,
             depthOfField, focusPoint, blur
    }

    // Every field optional on the way in: a design saved by a build with
    // fewer settings (or more) still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VisualizationEnvironment()
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? fallback.preset
        lightRotation = try c.decodeIfPresent(Double.self, forKey: .lightRotation) ?? fallback.lightRotation
        sunElevation = try c.decodeIfPresent(Double.self, forKey: .sunElevation) ?? fallback.sunElevation
        lightIntensity = try c.decodeIfPresent(Double.self, forKey: .lightIntensity) ?? fallback.lightIntensity
        background = (try? c.decodeIfPresent(Background.self, forKey: .background)) ?? fallback.background
        backgroundColor = try c.decodeIfPresent(SIMD3<Double>.self, forKey: .backgroundColor)
            ?? fallback.backgroundColor
        groundShadow = try c.decodeIfPresent(Bool.self, forKey: .groundShadow) ?? fallback.groundShadow
        depthOfField = try c.decodeIfPresent(Bool.self, forKey: .depthOfField) ?? fallback.depthOfField
        focusPoint = try c.decodeIfPresent(SIMD3<Double>.self, forKey: .focusPoint)
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? fallback.blur
    }

    var presetValue: EnvironmentPreset {
        EnvironmentPreset.library.first { $0.name == preset } ?? EnvironmentPreset.library[0]
    }

    /// Values pinned to their ranges (slider and decode safety).
    var clamped: VisualizationEnvironment {
        var out = self
        out.lightRotation = lightRotation.truncatingRemainder(dividingBy: 360)
        if out.lightRotation < 0 { out.lightRotation += 360 }
        out.sunElevation = min(max(sunElevation, 0), 90)
        out.lightIntensity = min(max(lightIntensity, 0), 2)
        out.backgroundColor = simd_clamp(backgroundColor, SIMD3(repeating: 0), SIMD3(repeating: 1))
        out.blur = blur.isFinite ? min(max(blur, 0), 1) : 0.5
        if let point = focusPoint, !(point.x.isFinite && point.y.isFinite && point.z.isFinite) { out.focusPoint = nil }
        return out
    }
}

/// A lighting setup: sky and ground light, the sun's colour and default
/// position, and the background gradient.
nonisolated struct EnvironmentPreset: Identifiable, Sendable {
    var name: String
    var sky: SIMD3<Double>
    var ground: SIMD3<Double>
    var sun: SIMD3<Double>
    var backgroundTop: SIMD3<Double>
    var backgroundBottom: SIMD3<Double>
    var lightRotation: Double
    var sunElevation: Double
    var id: String { name }

    static let library: [EnvironmentPreset] = [
        EnvironmentPreset(name: "Studio", sky: SIMD3(1.0, 1.0, 1.04), ground: SIMD3(0.62, 0.60, 0.58),
                          sun: SIMD3(1, 1, 1), backgroundTop: SIMD3(0.96, 0.96, 0.97),
                          backgroundBottom: SIMD3(0.80, 0.81, 0.83), lightRotation: 35, sunElevation: 50),
        EnvironmentPreset(name: "Daylight", sky: SIMD3(0.80, 0.90, 1.05), ground: SIMD3(0.55, 0.52, 0.45),
                          sun: SIMD3(1.05, 1.0, 0.92), backgroundTop: SIMD3(0.55, 0.74, 0.95),
                          backgroundBottom: SIMD3(0.90, 0.93, 0.96), lightRotation: 60, sunElevation: 60),
        EnvironmentPreset(name: "Sunset", sky: SIMD3(0.85, 0.65, 0.60), ground: SIMD3(0.40, 0.30, 0.30),
                          sun: SIMD3(1.15, 0.72, 0.42), backgroundTop: SIMD3(0.32, 0.30, 0.52),
                          backgroundBottom: SIMD3(0.98, 0.62, 0.40), lightRotation: 110, sunElevation: 12),
        EnvironmentPreset(name: "Overcast", sky: SIMD3(0.92, 0.93, 0.95), ground: SIMD3(0.70, 0.70, 0.70),
                          sun: SIMD3(0.55, 0.56, 0.58), backgroundTop: SIMD3(0.82, 0.83, 0.85),
                          backgroundBottom: SIMD3(0.70, 0.71, 0.73), lightRotation: 20, sunElevation: 75),
        EnvironmentPreset(name: "Warm Interior", sky: SIMD3(1.0, 0.92, 0.82), ground: SIMD3(0.55, 0.45, 0.38),
                          sun: SIMD3(1.05, 0.88, 0.70), backgroundTop: SIMD3(0.93, 0.88, 0.82),
                          backgroundBottom: SIMD3(0.72, 0.64, 0.56), lightRotation: 300, sunElevation: 35),
        EnvironmentPreset(name: "Night", sky: SIMD3(0.30, 0.34, 0.48), ground: SIMD3(0.12, 0.12, 0.16),
                          sun: SIMD3(0.70, 0.78, 1.0), backgroundTop: SIMD3(0.04, 0.05, 0.10),
                          backgroundBottom: SIMD3(0.14, 0.16, 0.24), lightRotation: 220, sunElevation: 40),
    ]
}

/// The renderer's light and colours for an environment.
nonisolated struct VisualizationLighting: Equatable, Sendable {
    /// The direction the sunlight travels (world, unit) — the renderer's
    /// `keyLightDirection`.
    var lightDirection: SIMD3<Float>
    /// Sun colour × intensity.
    var lightColor: SIMD3<Float>
    var sky: SIMD3<Float>
    var ground: SIMD3<Float>
    var backgroundTop: SIMD3<Float>
    var backgroundBottom: SIMD3<Float>
    /// The background is to be left out of captures.
    var transparentBackground: Bool
    /// Depth of field, when on: the focus point (nil: the camera's orbit
    /// target) and the blur strength 0…1.
    var depthOfField: DepthOfField?

    struct DepthOfField: Equatable, Sendable {
        var focus: SIMD3<Float>?
        var blur: Float
    }

    init(_ environment: VisualizationEnvironment) {
        let env = environment.clamped
        let preset = env.presetValue
        let rotation = env.lightRotation * .pi / 180, elevation = env.sunElevation * .pi / 180
        // Where the sun is, seen from the model; the light travels the other way.
        let sun = SIMD3(cos(elevation) * sin(rotation), sin(elevation), cos(elevation) * cos(rotation))
        lightDirection = SIMD3<Float>(simd_normalize(-sun))
        lightColor = SIMD3<Float>(preset.sun * env.lightIntensity)
        sky = SIMD3<Float>(preset.sky)
        ground = SIMD3<Float>(preset.ground)
        switch env.background {
        case .environment, .transparent:
            backgroundTop = SIMD3<Float>(preset.backgroundTop)
            backgroundBottom = SIMD3<Float>(preset.backgroundBottom)
        case .color:
            backgroundTop = SIMD3<Float>(env.backgroundColor)
            backgroundBottom = SIMD3<Float>(env.backgroundColor)
        }
        transparentBackground = env.background == .transparent
        depthOfField = env.depthOfField && env.blur > 0
            ? DepthOfField(focus: env.focusPoint.map { SIMD3<Float>($0) }, blur: Float(env.blur)) : nil
    }
}

/// Depth of field (spec §14): how much each pixel blurs. The renderers
/// (Metal `fragment_depthOfField`, WebGL `dof`) apply the same rule per pixel.
nonisolated enum DepthOfFieldKit {
    /// The widest blur, as a fraction of the image's height, at blur 1.
    static let maxRadiusFraction: Float = 0.02
    /// How fast the blur grows: the widest a third of the focus distance
    /// off it — a part's own depth is a fair share of that in a close shot.
    static let falloff: Float = 3

    /// How far in front of the camera `focus` lies, along the view.
    static func focusDistance(eye: SIMD3<Float>, viewDirection: SIMD3<Float>, focus: SIMD3<Float>) -> Float {
        max(simd_dot(focus - eye, simd_normalize(viewDirection)), 1e-4)
    }

    /// The blur radius in pixels for a point `distance` in front of the
    /// camera: none at the focus distance, growing with the distance from
    /// it relative to the focus distance (`falloff`), up to the widest blur.
    static func radius(distance: Float, focusDistance: Float, blur: Float, imageHeight: Float) -> Float {
        let widest = blur * imageHeight * maxRadiusFraction
        return widest * min(1, falloff * abs(distance - focusDistance) / max(focusDistance, 1e-4))
    }
}

struct SetVisualizationEnvironmentCommand: DocumentCommand {
    let title = "Environment"
    let old: VisualizationEnvironment
    let new: VisualizationEnvironment

    func apply(to document: inout DesignDocument) { document.visualization = new }
    func revert(in document: inout DesignDocument) { document.visualization = old }
}
