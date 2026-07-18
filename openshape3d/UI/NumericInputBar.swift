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
    @FocusState private var focusedField: Int?

    var body: some View {
        if case .extruding = viewModel.mode, let context = viewModel.extrudeContext {
            extrudeBar(context)
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

    private func extrudeBar(_ context: EditorViewModel.ExtrudeContext) -> some View {
        HStack(spacing: 16) {
            Text("Extrude")
                .font(.headline)
            Text("Drag up or down, or type a distance")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "Distance",
                    value: Binding(
                        get: { viewModel.extrudeContext?.distance ?? 0 },
                        set: { viewModel.setExtrudeDistance($0) }
                    ),
                    format: .number
                )
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit { viewModel.commitExtrude() }
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelExtrude()
            }
            Button("Extrude") {
                viewModel.commitExtrude()
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
