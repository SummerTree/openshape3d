//
//  ExtrudeGizmoOverlay.swift
//  openshape3d
//
//  Shapr3D-style on-arrow value pill for extrude / face push-pull / cylinder
//  diameter. Rides the pull arrow tip (projected from world each camera move
//  via `cameraEpoch`); tap the pill to type a value inline (Enter commits, like
//  the bottom bar), with a "Total / Symmetric" extent menu for axial extrudes.
//

import SwiftUI

struct ExtrudeGizmoOverlay: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        let _ = viewModel.cameraEpoch
        if let label = viewModel.extrudeArrowLabel,
           let pt = viewModel.cameraControl?.worldToScreenPoint(label.world) {
            pill(label)
                // Just off the shaft so the arrow line stays visible.
                .position(x: pt.x + 34, y: pt.y)
        }
    }

    @ViewBuilder
    private func pill(_ label: EditorViewModel.ExtrudeArrowLabel) -> some View {
        if viewModel.editingExtrudeArrow {
            ExtrudeArrowField(viewModel: viewModel)
        } else {
            // Extent menu stacked above the value pill, centred on the arrow.
            VStack(spacing: 5) {
                if !label.isDiameter {
                    Menu {
                        Button { viewModel.setExtrudeSymmetric(false) } label: {
                            Label("Total", systemImage: label.symmetric ? "" : "checkmark")
                        }
                        Button { viewModel.setExtrudeSymmetric(true) } label: {
                            Label("Symmetric", systemImage: label.symmetric ? "checkmark" : "")
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(label.symmetric ? "Symmetric" : "Total").font(.caption2)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .accessibilityIdentifier("ExtrudeExtentMenu")
                }

                Button {
                    viewModel.beginExtrudeArrowEdit()
                } label: {
                    Text(label.text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1.5))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ExtrudeArrowValue")
            }
        }
    }
}

private struct ExtrudeArrowField: View {
    @Bindable var viewModel: EditorViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .multilineTextAlignment(.center)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .frame(width: 84)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1.5))
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { viewModel.commitExtrudeArrowEdit(text) }
            .accessibilityIdentifier("ExtrudeArrowField")
            .onAppear {
                // Seed with the numeric part of the current label.
                text = (viewModel.extrudeArrowLabel?.text ?? "")
                    .replacingOccurrences(of: "⌀ ", with: "")
                    .replacingOccurrences(of: " mm", with: "")
                focused = true
            }
    }
}
