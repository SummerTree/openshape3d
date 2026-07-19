//
//  SketchDimensionOverlay.swift
//  openshape3d
//
//  Light SwiftUI annotation layer for sketch dimensions (plan §C2, spec §2.2).
//  Draws a thin annotation line between the dimension's reference points and a
//  value label at the segment midpoint (projected from world space each camera
//  move via `cameraEpoch`). Tapping a label opens an inline numeric field;
//  committing sets the driving value and re-solves the sketch. Supports inline
//  arithmetic ("25.4/2") through `ExpressionEvaluator`.
//

import SwiftUI

struct SketchDimensionOverlay: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        if viewModel.mode.isSketching {
            ZStack(alignment: .topLeading) {
                ForEach(viewModel.sketchDimensionLabels) { label in
                    labelView(label)
                }
            }
            .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private func labelView(_ label: EditorViewModel.SketchDimensionLabel) -> some View {
        if let anchor = project(label.worldAnchor),
           let start = project(label.worldStart),
           let end = project(label.worldEnd) {
            // Thin annotation line between the reference points.
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)

            if viewModel.editingDimension?.labelID == label.id {
                DimensionField(viewModel: viewModel)
                    .position(anchor)
            } else {
                Button {
                    viewModel.beginDimensionEdit(label)
                } label: {
                    Text(label.text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(label.dimensionID == nil
                                        ? Color.blue.opacity(0.4) : Color.blue, lineWidth: 1)
                        )
                        .foregroundStyle(label.dimensionID == nil ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .position(anchor)
                .accessibilityIdentifier("DimensionLabel")
            }
        }
    }

    private func project(_ world: SIMD3<Double>) -> CGPoint? {
        viewModel.cameraControl?.worldToScreenPoint(world)
    }
}

/// The inline numeric editor shown in place of a dimension label while editing.
private struct DimensionField: View {
    @Bindable var viewModel: EditorViewModel
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .frame(width: 74)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { viewModel.commitDimensionEdit(text) }
                .accessibilityIdentifier("DimensionField")
            Button {
                viewModel.commitDimensionEdit(text)
            } label: {
                Image(systemName: "checkmark.circle.fill")
            }
            .accessibilityIdentifier("DimensionCommit")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue, lineWidth: 1))
        .onAppear {
            text = viewModel.editingDimension?.text ?? ""
            focused = true
        }
    }
}
