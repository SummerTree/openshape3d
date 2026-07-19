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
    @State private var scaleFactor: Double = 1
    @FocusState private var focusedField: Int?

    var body: some View {
        if let part = viewModel.axisEntryPart {
            axisMoveBar(part)
        } else if viewModel.scaleEntryActive {
            scaleBar
        } else if let context = viewModel.toolContext, viewModel.mode != .pickingRevolveAxis {
            switch context.kind {
            case .extrude:
                extrudeBar(context)
            case .revolve:
                revolveBar(context)
            case .offsetPlane:
                offsetPlaneBar(context)
            }
        } else if case .sketching(_, .polygon) = viewModel.mode {
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
                        TextField(label, value: binding(at: index), format: .number)
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
                TextField("Distance", value: $axisDistance, format: .number)
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

    /// Uniform scale about the body pivot (spec §5.4 v1).
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
                TextField("Factor", value: $scaleFactor, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { viewModel.commitScale(factor: scaleFactor) }
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelScaleEntry()
            }
            Button("Apply") {
                viewModel.commitScale(factor: scaleFactor)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .onAppear { scaleFactor = 1 }
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
                TextField(
                    "Sides",
                    value: Binding(
                        get: { viewModel.polygonSides },
                        set: { viewModel.polygonSides = min(max($0, 3), 64) }
                    ),
                    format: .number
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

    private func extrudeBar(_ context: EditorViewModel.ToolContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("Extrude")
                    .font(.headline)

                HStack(spacing: 6) {
                    Text("Distance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Distance",
                        value: Binding(
                            get: { viewModel.toolContext?.distance ?? 0 },
                            set: { viewModel.setExtrudeDistance($0) }
                        ),
                        format: .number
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

                // Sketch profiles can revolve about one of their lines instead.
                if context.sketchID != nil {
                    Button("Revolve") {
                        viewModel.beginRevolveAxisPick()
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
                TextField(
                    "Distance",
                    value: Binding(
                        get: { viewModel.toolContext?.distance ?? 0 },
                        set: { viewModel.setOffsetPlaneDistance($0) }
                    ),
                    format: .number
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
                TextField(
                    "Angle",
                    value: Binding(
                        get: { viewModel.toolContext?.angle ?? 360 },
                        set: { viewModel.setRevolveAngle($0) }
                    ),
                    format: .number
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
