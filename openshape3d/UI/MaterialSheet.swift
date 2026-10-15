//
//  MaterialSheet.swift
//  openshape3d
//
//  Body material dialog (plan §B15): preset grid + custom color picker +
//  metallic/roughness/opacity/glow sliders, and texture mapping — a pattern
//  (wood grain, brushed, carbon fibre…) with its size and rotation. Apply
//  commits one SetMaterialCommand over the whole selection
//  (EditorViewModel.applyMaterial).
//

import SwiftUI

struct MaterialSheet: View {
    @State private var color: Color
    @State private var metallic: Double
    @State private var roughness: Double
    @State private var opacity: Double
    @State private var emission: Double
    @State private var pattern: MaterialPattern
    @State private var patternSize: Double
    @State private var patternRotation: Double

    @Environment(\.dismiss) private var dismiss
    let onApply: (BodyMaterialSpec) -> Void

    init(initial: BodyMaterialSpec, onApply: @escaping (BodyMaterialSpec) -> Void) {
        let spec = initial.clamped
        _color = State(initialValue: Color(
            red: spec.baseColor.x, green: spec.baseColor.y, blue: spec.baseColor.z
        ))
        _metallic = State(initialValue: spec.metallic)
        _roughness = State(initialValue: spec.roughness)
        _opacity = State(initialValue: spec.baseColor.w)
        _emission = State(initialValue: spec.emission)
        _pattern = State(initialValue: spec.pattern)
        _patternSize = State(initialValue: spec.patternSize)
        _patternRotation = State(initialValue: spec.patternRotation)
        self.onApply = onApply
    }

    private static let gridColumns = [GridItem(.adaptive(minimum: 74), spacing: 10)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    LazyVGrid(columns: Self.gridColumns, spacing: 10) {
                        ForEach(MaterialPreset.library) { preset in
                            presetSwatch(preset)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Custom") {
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                        .accessibilityIdentifier("MaterialColorPicker")
                    sliderRow(
                        "Metallic", value: $metallic,
                        sliderID: "MaterialMetallicSlider",
                        valueID: "MaterialMetallicValue"
                    )
                    sliderRow(
                        "Roughness", value: $roughness,
                        sliderID: "MaterialRoughnessSlider",
                        valueID: "MaterialRoughnessValue"
                    )
                    sliderRow(
                        "Opacity", value: $opacity,
                        sliderID: "MaterialOpacitySlider",
                        valueID: "MaterialOpacityValue"
                    )
                    sliderRow(
                        "Glow", value: $emission,
                        sliderID: "MaterialGlowSlider",
                        valueID: "MaterialGlowValue"
                    )
                }
                Section("Texture Mapping") {
                    Picker("Pattern", selection: Binding(get: { pattern }, set: { next in
                        // A new pattern starts at its own size.
                        if next != pattern { patternSize = next.defaultSize }
                        pattern = next
                    })) {
                        ForEach(MaterialPattern.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("MaterialPatternPicker")
                    if pattern != .none {
                        HStack {
                            Text("Size")
                            Slider(value: Binding(get: { log10(patternSize) }, set: { patternSize = DecalKit.tidyWidth(pow(10, $0)) }),
                                   in: log10(MaterialPattern.sizeRange.lowerBound)...log10(MaterialPattern.sizeRange.upperBound))
                                .accessibilityIdentifier("MaterialPatternSize")
                            Text(AppSettings.shared.unit.compactLengthString(fromMM: patternSize))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                        HStack {
                            Text("Rotation")
                            Slider(value: $patternRotation, in: -180...180, step: 1)
                                .accessibilityIdentifier("MaterialPatternRotation")
                            Text("\(Int(patternRotation.rounded()))°")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                }
            }
            .navigationTitle("Material")
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("MaterialCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(currentSpec)
                        dismiss()
                    }
                    .accessibilityIdentifier("MaterialApply")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func presetSwatch(_ preset: MaterialPreset) -> some View {
        Button {
            let spec = preset.spec
            color = Color(
                red: spec.baseColor.x, green: spec.baseColor.y, blue: spec.baseColor.z
            )
            metallic = spec.metallic
            roughness = spec.roughness
            opacity = spec.baseColor.w
            emission = spec.emission
            pattern = spec.pattern
            patternSize = spec.patternSize
            patternRotation = spec.patternRotation
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(
                        red: preset.spec.baseColor.x,
                        green: preset.spec.baseColor.y,
                        blue: preset.spec.baseColor.z
                    ))
                    .frame(height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.15))
                    )
                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "MaterialPreset\(preset.name.replacingOccurrences(of: " ", with: ""))"
        )
    }

    private func sliderRow(
        _ title: String, value: Binding<Double>, sliderID: String, valueID: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: 0...1)
                .accessibilityIdentifier(sliderID)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityIdentifier(valueID)
        }
    }

    /// The sheet state as a model spec (sRGB components from the picker).
    private var currentSpec: BodyMaterialSpec {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return BodyMaterialSpec(
            baseColor: SIMD4(Double(r), Double(g), Double(b), max(opacity, 0.05)),
            metallic: metallic,
            roughness: roughness,
            emission: emission,
            pattern: pattern,
            patternSize: patternSize,
            patternRotation: patternRotation
        ).clamped
    }
}
