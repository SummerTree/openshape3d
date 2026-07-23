//
//  NumericInputBar.swift
//  openshape3d
//
//  Bottom contextual numeric input: dimension fields for the primitive being
//  edited. Committing a value goes through the same command path as any other
//  mutation, so it's undoable.
//

import SwiftUI

struct NumericInputBar: View {
    @Bindable var viewModel: EditorViewModel

    @State private var values: [Double] = []
    @State private var axisDistance: Double = 0
    @FocusState private var focusedField: Int?

    var body: some View {
        if let part = viewModel.axisEntryPart {
            axisMoveBar(part)
        } else if viewModel.scaleEntryActive {
            scaleBar
        } else if viewModel.mode == .rotatingAroundAxis,
                  viewModel.rotateAxisState?.hasAxis == true {
            rotateAxisBar
        } else if viewModel.mode == .patterning, let state = viewModel.patternState {
            patternBar(state)
        } else if let image = viewModel.selectedImage {
            imageBar(image)
        } else if let context = viewModel.toolContext, viewModel.mode != .pickingRevolveAxis {
            switch context.kind {
            case .extrude:
                // While the sweep path pick is armed but empty, the sweep bar
                // carries the prompt/cancel instead of the extrude controls.
                if viewModel.mode == .pickingSweepPath {
                    sweepBar(context)
                } else {
                    extrudeBar(context)
                }
            case .revolve:
                revolveBar(context)
            case .offsetPlane:
                offsetPlaneBar(context)
            case .sweep:
                sweepBar(context)
            case .loft:
                loftBar(context)
            }
        } else if case .sketching(_, .some(.polygon)) = viewModel.mode {
            polygonBar
        } else if let body = viewModel.editingPrimitiveBody, let spec = body.primitive {
            HStack(spacing: 16) {
                Text(spec.displayName)
                    .font(.headline)

                ForEach(Array(fieldLabels(for: spec).enumerated()), id: \.offset) { index, label in
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(label, value: AppSettings.shared.unit.binding(binding(at: index)),
                                  format: .number.precision(.fractionLength(0...3)))
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .focused($focusedField, equals: index)
                            .onSubmit { commit() }
                    }
                }

                Spacer()

                Button("Done") {
                    commit()
                    viewModel.finishEditing()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
            .onAppear { values = fieldValues(for: spec) }
            .onChange(of: body.id) {
                if let spec = viewModel.editingPrimitiveBody?.primitive {
                    values = fieldValues(for: spec)
                }
            }
            .onChange(of: focusedField) { old, new in
                // Commit when a field loses focus.
                if old != nil, new != old { commit() }
            }
        }
    }

    /// Exact-distance move along a tapped gizmo arrow (spec §5.1).
    private func axisMoveBar(_ part: GizmoPart) -> some View {
        HStack(spacing: 16) {
            Text("Move \(part.axisName)")
                .font(.headline)

            HStack(spacing: 6) {
                Text("Distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField("Distance", value: AppSettings.shared.unit.binding($axisDistance),
                          format: .number.precision(.fractionLength(0...3)))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { viewModel.commitAxisMove(distance: axisDistance) }
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelAxisDistanceEntry()
            }
            Button("Move") {
                viewModel.commitAxisMove(distance: axisDistance)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .onAppear { axisDistance = 0 }
    }

    /// Uniform scale about the body pivot (spec §5.4): factor field, Copy
    /// badge (scales a duplicate), commit via Apply or an empty-grid tap.
    private var scaleBar: some View {
        HStack(spacing: 16) {
            Text("Scale")
                .font(.headline)
            Text("Uniform, about the body pivot")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Factor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Factor",
                    value: Binding(
                        get: { viewModel.scalePendingFactor },
                        set: { viewModel.scalePendingFactor = $0 }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .accessibilityIdentifier("ScaleFactorField")
                .onSubmit { viewModel.commitScale(factor: viewModel.scalePendingFactor) }
            }

            Button("Copy") {
                viewModel.scaleCopyOnCommit.toggle()
            }
            .buttonStyle(.bordered)
            .tint(viewModel.scaleCopyOnCommit ? Color.blue : Color.secondary)
            .accessibilityIdentifier("ScaleCopyBadge")

            Spacer()

            Button("Cancel") {
                viewModel.cancelScaleEntry()
            }
            Button("Apply") {
                viewModel.commitScale(factor: viewModel.scalePendingFactor)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ScaleApply")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    /// Rotate Around Axis (spec §5.3): angle entry once the axis is set;
    /// drags scrub in 5° steps, typed values are exact.
    private var rotateAxisBar: some View {
        HStack(spacing: 16) {
            Text("Rotate")
                .font(.headline)
            Text("Drag to rotate (5° steps), or type an angle")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Angle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Angle",
                    value: Binding(
                        get: { viewModel.rotateAxisState?.angleDegrees ?? 0 },
                        set: { viewModel.setRotateAngle($0) }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .accessibilityIdentifier("RotateAxisAngle")
                .onSubmit { viewModel.commitRotateAxis() }
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelRotateAxis()
            }
            Button("Apply") {
                viewModel.commitRotateAxis()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("RotateAxisApply")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    /// Pattern bar (plan §B5): Linear/Circular, axis, count, spacing/angle;
    /// instances preview live as ghosts in the viewport.
    private func patternBar(_ state: EditorViewModel.PatternState) -> some View {
        let axisChoices: [EditorViewModel.PatternState.Axis] = {
            guard state.isSketchPattern else { return [.x, .y, .z] }
            // Sketch patterns are in-plane: X/Y only; circular needs no axis.
            return state.kind == .linear ? [.x, .y] : []
        }()
        return HStack(spacing: 16) {
            Text("Pattern")
                .font(.headline)

            Picker("Type", selection: Binding(
                get: { viewModel.patternState?.kind ?? .linear },
                set: { viewModel.patternState?.kind = $0 }
            )) {
                ForEach(EditorViewModel.PatternState.Kind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if !axisChoices.isEmpty {
                Picker("Axis", selection: Binding(
                    get: { viewModel.patternState?.axis ?? .x },
                    set: { viewModel.patternState?.axis = $0 }
                )) {
                    ForEach(axisChoices, id: \.self) { axis in
                        Text(axis.rawValue).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            HStack(spacing: 6) {
                Text("Count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Count",
                    value: Binding(
                        get: { viewModel.patternState?.count ?? 3 },
                        set: { viewModel.patternState?.count = min(max($0, 1), 64) }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .accessibilityIdentifier("PatternCount")
            }

            if state.kind == .linear {
                HStack(spacing: 6) {
                    Text("Spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    TextField(
                        "Spacing",
                        value: AppSettings.shared.unit.binding(Binding(
                            get: { viewModel.patternState?.spacing ?? 6 },
                            set: { viewModel.patternState?.spacing = $0 }
                        )),
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .accessibilityIdentifier("PatternSpacing")
                }
            } else {
                HStack(spacing: 6) {
                    Text("Angle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    TextField(
                        "Angle",
                        value: Binding(
                            get: { viewModel.patternState?.totalAngle ?? 360 },
                            set: { viewModel.patternState?.totalAngle = $0 }
                        ),
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .accessibilityIdentifier("PatternAngle")
                }
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelPattern()
            }
            Button("Apply") {
                viewModel.commitPattern()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("PatternApply")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    /// Selected inserted image (plan §B10): size field (max dimension, aspect
    /// preserved), opacity slider, and delete — all through UpdateImageCommand.
    private func imageBar(_ image: InsertedImage) -> some View {
        HStack(spacing: 16) {
            Text(image.name)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text("Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Size",
                    value: AppSettings.shared.unit.binding(Binding(
                        get: {
                            viewModel.selectedImage.map { max($0.width, $0.height) }
                                ?? max(image.width, image.height)
                        },
                        set: { viewModel.setImageMaxDimension($0) }
                    )),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .accessibilityIdentifier("ImageSizeField")
            }

            HStack(spacing: 6) {
                Text("Opacity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Slider(
                    value: Binding(
                        get: { viewModel.selectedImage?.opacity ?? image.opacity },
                        set: { viewModel.setImageOpacity($0) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            viewModel.beginImageInteraction()
                        } else {
                            viewModel.endImageInteraction()
                        }
                    }
                )
                .frame(width: 140)
                .accessibilityIdentifier("ImageOpacitySlider")
            }

            Spacer()

            Button("Delete", role: .destructive) {
                viewModel.deleteImage(image.id)
            }
            .accessibilityIdentifier("ImageDelete")
            Button("Done") {
                viewModel.selectedImageID = nil
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ImageDone")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private var polygonBar: some View {
        HStack(spacing: 16) {
            Text("Polygon")
                .font(.headline)
            Text("Drag from center to a vertex")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Sides")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Sides",
                    value: Binding(
                        get: { viewModel.polygonSides },
                        set: { viewModel.polygonSides = min(max($0, 3), 64) }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                Stepper(
                    "Sides",
                    value: Binding(
                        get: { viewModel.polygonSides },
                        set: { viewModel.polygonSides = min(max($0, 3), 64) }
                    ),
                    in: 3...64
                )
                .labelsHidden()
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    /// Radial push/pull on a cylinder edits the diameter (Shapr3D Offset Face).
    private func diameterBar(_ context: EditorViewModel.ToolContext, radius: Double) -> some View {
        HStack(spacing: 16) {
            Text("Diameter")
                .font(.headline)
            HStack(spacing: 6) {
                Text("⌀")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Diameter",
                    value: AppSettings.shared.unit.binding(Binding(
                        get: { 2 * (radius + (viewModel.toolContext?.distance ?? 0)) },
                        set: { viewModel.setExtrudeDistance($0 / 2 - radius) }
                    )),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onSubmit { viewModel.commitTool() }
            }
            Spacer()
            Button("Cancel") { viewModel.cancelTool() }
            Button("Apply") { viewModel.commitTool() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private func extrudeBar(_ context: EditorViewModel.ToolContext) -> some View {
        if let cyl = context.cylinderFace {
            return AnyView(diameterBar(context, radius: cyl.radius))
        }
        return AnyView(extrudeBarBody(context))
    }

    private func extrudeBarBody(_ context: EditorViewModel.ToolContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("Extrude")
                    .font(.headline)

                HStack(spacing: 6) {
                    Text("Distance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    TextField(
                        "Distance",
                        value: AppSettings.shared.unit.binding(Binding(
                            get: { viewModel.toolContext?.distance ?? 0 },
                            set: { viewModel.setExtrudeDistance($0) }
                        )),
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { viewModel.commitTool() }
                }

                // Symmetric sides: distance is per-side, total depth 2×.
                Button("Symmetric") {
                    viewModel.setExtrudeSymmetric(!context.symmetric)
                }
                .buttonStyle(.bordered)
                .tint(context.symmetric ? Color.accentColor : Color.secondary)

                Spacer()

                // Sketch profiles can revolve about one of their lines, sweep
                // along a path, loft to more profiles, or coil into a helix.
                if context.sketchID != nil {
                    Button("Revolve") {
                        viewModel.beginRevolveAxisPick()
                    }
                    Button("Sweep") {
                        viewModel.beginSweepPathPick()
                    }
                    Button("Loft") {
                        viewModel.beginLoftProfilePick()
                    }
                    Button("Helix") {
                        viewModel.showHelixOptions = true
                    }
                }
                // Face pulls can become an offset construction plane instead.
                if context.sourceBody != nil {
                    Button("Offset Plane") {
                        viewModel.beginOffsetPlane()
                    }
                }
                Button("Cancel") {
                    viewModel.cancelTool()
                }
                Button("Extrude") {
                    viewModel.commitTool()
                }
                .buttonStyle(.borderedProminent)
            }

            // Boolean badge: manual result override (spec §4.1).
            HStack(spacing: 8) {
                Text("Result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Result", selection: Binding(
                    get: { viewModel.toolContext?.booleanOverride ?? .auto },
                    set: { viewModel.setBooleanOverride($0) }
                )) {
                    ForEach(BooleanOverride.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .sheet(isPresented: $viewModel.showHelixOptions) {
            HelixOptionsSheet { radius, pitch, turns in
                viewModel.commitHelixSweep(radius: radius, pitch: pitch, turns: turns)
            }
        }
    }

    /// Sweep path builder (plan §B1): taps chain sketch lines/arcs into the
    /// spine; commit sweeps the armed profile along it.
    private func sweepBar(_ context: EditorViewModel.ToolContext) -> some View {
        let count = context.sweepPathEntityIDs.count
        return HStack(spacing: 16) {
            Text("Sweep")
                .font(.headline)
            Text(count == 0
                ? "Tap sketch lines or arcs to build the path"
                : "\(count) path segment\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                viewModel.cancelSweepPathPick()
            }
            Button("Sweep") {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
            .disabled(count == 0)
            .accessibilityIdentifier("SweepCommit")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    /// Loft section collector (plan §B2): taps append profile fills in order;
    /// commit lofts through them.
    private func loftBar(_ context: EditorViewModel.ToolContext) -> some View {
        let count = context.loftProfiles.count
        return HStack(spacing: 16) {
            Text("Loft")
                .font(.headline)
            Text("\(count) section\(count == 1 ? "" : "s") — tap more profile fills")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                viewModel.cancelLoftProfilePick()
            }
            Button("Loft") {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
            .disabled(count < 2)
            .accessibilityIdentifier("LoftCommit")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private func offsetPlaneBar(_ context: EditorViewModel.ToolContext) -> some View {
        HStack(spacing: 16) {
            Text("Offset Plane")
                .font(.headline)
            Text("Drag the arrow, or type a distance")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Distance",
                    value: AppSettings.shared.unit.binding(Binding(
                        get: { viewModel.toolContext?.distance ?? 0 },
                        set: { viewModel.setOffsetPlaneDistance($0) }
                    )),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit { viewModel.commitTool() }
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelTool()
            }
            Button("Add Plane") {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private func revolveBar(_ context: EditorViewModel.ToolContext) -> some View {
        HStack(spacing: 16) {
            Text("Revolve")
                .font(.headline)
            Text("Drag to sweep, or type an angle")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Angle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField(
                    "Angle",
                    value: Binding(
                        get: { viewModel.toolContext?.angle ?? 360 },
                        set: { viewModel.setRevolveAngle($0) }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit { viewModel.commitTool() }
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelTool()
            }
            Button("Revolve") {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private func binding(at index: Int) -> Binding<Double> {
        Binding(
            get: { index < values.count ? values[index] : 0 },
            set: { newValue in
                if index < values.count { values[index] = newValue }
            }
        )
    }

    private func commit() {
        guard let spec = viewModel.editingPrimitiveBody?.primitive,
              let newSpec = makeSpec(from: values, like: spec)
        else { return }
        viewModel.commitPrimitiveSpec(newSpec)
    }

    private func fieldLabels(for spec: PrimitiveSpec) -> [String] {
        switch spec {
        case .box: ["W", "D", "H"]
        case .cylinder: ["R", "H"]
        case .sphere: ["R"]
        }
    }

    private func fieldValues(for spec: PrimitiveSpec) -> [Double] {
        switch spec {
        case let .box(w, d, h): [w, d, h]
        case let .cylinder(r, h): [r, h]
        case let .sphere(r): [r]
        }
    }

    private func makeSpec(from values: [Double], like spec: PrimitiveSpec) -> PrimitiveSpec? {
        let sane = values.map { max($0, 0.01) }
        switch spec {
        case .box where sane.count >= 3:
            return .box(width: sane[0], depth: sane[1], height: sane[2])
        case .cylinder where sane.count >= 2:
            return .cylinder(radius: sane[0], height: sane[1])
        case .sphere where sane.count >= 1:
            return .sphere(radius: sane[0])
        default:
            return nil
        }
    }
}

/// Helix sweep options (plan §B16, spec §1.17): the armed profile sweeps
/// along a helical spine coiling up from the sketch plane.
struct HelixOptionsSheet: View {
    @State private var radius = 3.0
    @State private var pitch = 2.0
    @State private var turns = 3.0

    @Environment(\.dismiss) private var dismiss
    let onCreate: (Double, Double, Double) -> Void

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Radius") {
                    TextField("Radius", value: $radius, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("HelixRadius")
                }
                LabeledContent("Pitch") {
                    TextField("Pitch", value: $pitch, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("HelixPitch")
                }
                LabeledContent("Turns") {
                    TextField("Turns", value: $turns, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("HelixTurns")
                }
            }
            .navigationTitle("Helix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("HelixCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(radius, pitch, turns)
                        dismiss()
                    }
                    .accessibilityIdentifier("HelixCreate")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
