//
//  ConstraintSettingsView.swift
//  openshape3d
//
//  Auto-constrain settings panel (plan §B2): a compact toggle sheet bound to
//  EditorViewModel.autoConstrainSettings. A master "Auto-Constrain" switch gates
//  the per-inference sub-toggles and an angle-tolerance stepper. Presented while
//  viewModel.showConstraintSettings is true; Done clears that flag.
//

import SwiftUI

struct ConstraintSettingsView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-Constrain", isOn: $viewModel.autoConstrainSettings.enabled)
                        .accessibilityIdentifier("AutoConstrainToggle")
                } footer: {
                    Text("Infer sketch constraints automatically while you draw.")
                }

                if viewModel.autoConstrainSettings.enabled {
                    Section("Inferences") {
                        Toggle(
                            "Horizontal / Vertical",
                            isOn: $viewModel.autoConstrainSettings.horizontalVertical
                        )
                        .accessibilityIdentifier("AutoConstrainHVToggle")

                        Toggle(
                            "Snap to Points",
                            isOn: $viewModel.autoConstrainSettings.pointSnap
                        )
                        .accessibilityIdentifier("AutoConstrainPointSnapToggle")

                        Toggle(
                            "Parallel / Perpendicular",
                            isOn: $viewModel.autoConstrainSettings.parallelPerpendicular
                        )
                        .accessibilityIdentifier("AutoConstrainParallelPerpToggle")

                        Toggle(
                            "Tangent",
                            isOn: $viewModel.autoConstrainSettings.tangent
                        )
                        .accessibilityIdentifier("AutoConstrainTangentToggle")

                        Toggle(
                            "Equal Length",
                            isOn: $viewModel.autoConstrainSettings.equal
                        )
                        .accessibilityIdentifier("AutoConstrainEqualToggle")
                    }

                    Section("Tolerance") {
                        Stepper(
                            value: $viewModel.autoConstrainSettings.angleToleranceDeg,
                            in: 1...15,
                            step: 1
                        ) {
                            HStack {
                                Text("Angle Snap")
                                Spacer(minLength: 8)
                                Text("\(Int(viewModel.autoConstrainSettings.angleToleranceDeg.rounded()))°")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("AutoConstrainAngleValue")
                            }
                        }
                        .accessibilityIdentifier("AutoConstrainAngleStepper")
                    }
                }
            }
            .navigationTitle("Auto-Constrain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.showConstraintSettings = false
                    }
                    .accessibilityIdentifier("ConstraintSettingsDone")
                }
            }
        }
        .accessibilityIdentifier("ConstraintSettingsPanel")
        .presentationDetents([.medium])
    }
}
