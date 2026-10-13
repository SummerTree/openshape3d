//
//  VisualizationPanelView.swift
//  openshape3d
//
//  Tools ▸ Visualize (spec §14): the Visualization panel. Materials — the
//  library by category with search, the materials the design already uses,
//  and the selected bodies' material to edit or reset — and Environment —
//  lighting presets, the sun's rotation, elevation and intensity, the
//  background and the ground shadow — plus Capture for a clean picture.
//

import SwiftUI

struct VisualizationPanelView: View {
    @Bindable var viewModel: EditorViewModel
    /// Opens the Screenshot sheet (owned by EditorView).
    let onCapture: () -> Void

    @State private var query = ""
    @State private var category: MaterialPreset.Category?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Visualization").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    onCapture()
                } label: {
                    Label("Capture", systemImage: "camera")
                }
                .accessibilityIdentifier("VisualizeCapture")
                Button("Done") { viewModel.exitVisualize() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("VisualizeDone")
            }
            Picker("Panel", selection: $viewModel.visualizationTab) {
                ForEach(EditorViewModel.VisualizationTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("VisualizeTab")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch viewModel.visualizationTab {
                    case .materials: materials
                    case .environment: environment
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 300)
        .frame(maxHeight: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        // A container, so the panel's id does not replace its controls' ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("VisualizationPanel")
    }

    // MARK: - Materials

    private var materials: some View {
        Group {
            if viewModel.selection.isEmpty {
                Text("Select bodies, then tap a material to apply it.")
                    .font(.caption)
                    .foregroundStyle(Color.barLabel)
            } else {
                HStack {
                    Text(viewModel.selection.count == 1 ? "1 body selected" : "\(viewModel.selection.count) bodies selected")
                        .font(.caption)
                        .foregroundStyle(Color.barLabel)
                    Spacer()
                    Button("Edit…") { viewModel.showMaterialSheet = true }
                        .font(.caption)
                        .accessibilityIdentifier("VisualizeEditMaterial")
                    Button("Reset") { viewModel.resetMaterial() }
                        .font(.caption)
                        .accessibilityIdentifier("VisualizeResetMaterial")
                }
            }
            let used = viewModel.usedMaterials
            if !used.isEmpty {
                header("Used Materials")
                swatchGrid(used.map { spec in (MaterialPreset.named(spec)?.name ?? "Custom", spec) },
                           idPrefix: "UsedMaterial")
            }
            header("Library")
            TextField("Search Materials", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier("MaterialSearch")
            Picker("Category", selection: $category) {
                Text("All Categories").tag(MaterialPreset.Category?.none)
                ForEach(MaterialPreset.Category.allCases, id: \.self) {
                    Text($0.rawValue).tag(MaterialPreset.Category?.some($0))
                }
            }
            .accessibilityIdentifier("MaterialCategory")
            let found = MaterialPreset.matching(query, in: category)
            if found.isEmpty {
                Text("No materials match “\(query)”.").font(.caption).foregroundStyle(Color.barLabel)
            }
            swatchGrid(found.map { ($0.name, $0.spec) }, idPrefix: "Material")
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.barLabel)
            .padding(.top, 4)
    }

    private func swatchGrid(_ items: [(name: String, spec: BodyMaterialSpec)], idPrefix: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    viewModel.applyMaterial(item.spec)
                } label: {
                    VStack(spacing: 4) {
                        MaterialSwatch(spec: item.spec).frame(width: 44, height: 44)
                        Text(item.name)
                            .font(.system(size: 10))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.primary)
                            .frame(height: 26, alignment: .top)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selection.isEmpty)
                .opacity(viewModel.selection.isEmpty ? 0.6 : 1)
                .accessibilityIdentifier("\(idPrefix)_\(item.name)")
                .accessibilityLabel(item.name)
            }
        }
    }

    // MARK: - Environment

    private func binding<T>(_ keyPath: WritableKeyPath<VisualizationEnvironment, T>) -> Binding<T> {
        Binding(get: { viewModel.visualizationEnvironment[keyPath: keyPath] },
                set: { value in
                    var environment = viewModel.visualizationEnvironment
                    environment[keyPath: keyPath] = value
                    viewModel.setEnvironment(environment)
                })
    }

    /// A slider that previews while dragging and saves (one undo step) on release.
    private func slider(_ title: String, _ keyPath: WritableKeyPath<VisualizationEnvironment, Double>,
                        in range: ClosedRange<Double>, format: (Double) -> String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(format(viewModel.visualizationEnvironment[keyPath: keyPath]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.barLabel)
            }
            Slider(value: Binding(get: { viewModel.visualizationEnvironment[keyPath: keyPath] },
                                  set: { value in
                                      var environment = viewModel.visualizationEnvironment
                                      environment[keyPath: keyPath] = value
                                      viewModel.setEnvironment(environment, live: true)
                                  }),
                   in: range) { editing in
                if !editing { viewModel.commitEnvironment() }
            }
            .accessibilityIdentifier(id)
        }
    }

    private var environment: some View {
        let environment = viewModel.visualizationEnvironment
        return Group {
            header("Environment")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(EnvironmentPreset.library) { preset in
                    Button {
                        viewModel.applyEnvironmentPreset(preset)
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(colors: [color(preset.backgroundTop), color(preset.backgroundBottom)],
                                                     startPoint: .top, endPoint: .bottom))
                                .overlay(Circle().fill(color(preset.sun)).frame(width: 12, height: 12)
                                    .offset(x: 14, y: -10))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(environment.preset == preset.name ? Color.accentColor : .clear, lineWidth: 2))
                                .frame(height: 44)
                            Text(preset.name).font(.system(size: 10)).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("Environment_\(preset.name)")
                    .accessibilityAddTraits(environment.preset == preset.name ? .isSelected : [])
                }
            }
            header("Light")
            slider("Light Rotation", \.lightRotation, in: 0...360, format: { "\(Int($0.rounded()))°" },
                   id: "EnvironmentRotation")
            slider("Sun Elevation", \.sunElevation, in: 0...90, format: { "\(Int($0.rounded()))°" },
                   id: "EnvironmentElevation")
            slider("Light Intensity", \.lightIntensity, in: 0...2, format: { "\(Int(($0 * 100).rounded()))%" },
                   id: "EnvironmentIntensity")
            header("Background")
            Picker("Background", selection: binding(\.background)) {
                ForEach(VisualizationEnvironment.Background.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("EnvironmentBackground")
            if environment.background == .color {
                ColorPicker("Background Color", selection: Binding(
                    get: { color(environment.backgroundColor) },
                    set: { value in
                        guard let rgb = rgb(value) else { return }
                        var next = viewModel.visualizationEnvironment
                        next.backgroundColor = rgb
                        viewModel.setEnvironment(next)
                    }), supportsOpacity: false)
                    .font(.caption)
                    .accessibilityIdentifier("EnvironmentBackgroundColor")
            }
            if environment.background == .transparent {
                Text("Captures leave the background out.").font(.caption).foregroundStyle(Color.barLabel)
            }
            Toggle("Ground Shadow", isOn: binding(\.groundShadow))
                .font(.caption)
                .accessibilityIdentifier("EnvironmentGroundShadow")
        }
    }

    private func color(_ rgb: SIMD3<Double>) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    private func rgb(_ color: Color) -> SIMD3<Double>? {
        let resolved = color.resolve(in: EnvironmentValues())
        return SIMD3(Double(resolved.red), Double(resolved.green), Double(resolved.blue))
    }
}

/// A sphere-like swatch of a material: its colour, a highlight as tight as
/// its roughness, a metal's darker rim, a glow's halo, glass's checker.
struct MaterialSwatch: View {
    let spec: BodyMaterialSpec

    var body: some View {
        let c = spec.baseColor
        let base = Color(red: c.x, green: c.y, blue: c.z)
        // The shaded side: darker, more so for a metal.
        let dark = 1 - (spec.metallic * 0.45 + 0.15)
        let shade = Color(red: c.x * dark, green: c.y * dark, blue: c.z * dark)
        let highlight = 1 - min(max(spec.roughness, 0.05), 1)
        ZStack {
            if c.w < 1 {
                // Glass: a checker behind shows through.
                Canvas { context, size in
                    let n = 4
                    let cell = size.width / CGFloat(n)
                    for i in 0..<n { for j in 0..<n where (i + j).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell)),
                                     with: .color(.gray.opacity(0.35)))
                    } }
                }
                .clipShape(Circle())
            }
            Circle().fill(RadialGradient(
                colors: [base.opacity(c.w), shade.opacity(c.w)],
                center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 30))
            Circle().fill(RadialGradient(colors: [.white.opacity(0.85 * highlight), .clear],
                                         center: .init(x: 0.33, y: 0.28), startRadius: 0,
                                         endRadius: 6 + 14 * (1 - highlight)))
            if spec.emission > 0 {
                Circle().stroke(base, lineWidth: 2).blur(radius: 3).opacity(spec.emission)
            }
        }
        .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}
