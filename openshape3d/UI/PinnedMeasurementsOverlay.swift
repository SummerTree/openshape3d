//
//  PinnedMeasurementsOverlay.swift
//  openshape3d
//
//  Labels for pinned measurements (spec §16.3, "Pin to Always Show"): each
//  reading rides its span's midpoint or sits inside its angle. In Measure
//  mode every label carries an ✕ that unpins it.
//

import SwiftUI
import simd

struct PinnedMeasurementsOverlay: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        let pins = viewModel.showPinnedMeasurements ? viewModel.session.document.pinnedMeasurements : []
        let measuring: Bool = { if case .measuring = viewModel.mode { return true }; return false }()
        ZStack {
            ForEach(pins) { pin in
                if let anchor = viewModel.cameraControl?.worldToScreenPoint(pin.labelAnchor) {
                    HStack(spacing: 4) {
                        Text(Self.text(for: pin))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        if measuring {
                            Button {
                                viewModel.unpinMeasurement(pin.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Unpin")
                            .accessibilityIdentifier("UnpinMeasurement")
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1))
                    .foregroundStyle(Color.blue)
                    .position(anchor)
                    .allowsHitTesting(measuring)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("PinnedMeasurement")
                }
            }
        }
        // `worldToScreenPoint` is in full-screen coordinates (see MoveDistanceOverlay).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    static func text(for pin: PinnedMeasurement) -> String {
        switch pin.kind {
        case .distance: return EditorViewModel.formattedLength(pin.value)
        case .angle: return EditorViewModel.formattedAngle(pin.value)
        }
    }
}
