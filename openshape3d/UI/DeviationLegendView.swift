//
//  DeviationLegendView.swift
//  openshape3d
//
//  The key to the deviation preview's colours, with its numbers and the
//  way out — over the viewport while the preview is on (or measuring).
//

import SwiftUI

struct DeviationLegendView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Deviation Preview")
                    .font(.headline)
                Spacer()
                if let preview = viewModel.deviationPreview {
                    Button("Done") { viewModel.endDeviationPreview() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("DeviationDone")
                        .accessibilityHint(Text(String(format: "%.0f%% within tolerance", preview.stats.withinTolerance * 100)))
                }
            }
            if let preview = viewModel.deviationPreview {
                let tol = preview.toleranceMM, limit = preview.maxMM
                LinearGradient(stops: [
                    .init(color: Color(red: 0.90, green: 0.42, blue: 0.08), location: 0),
                    .init(color: Color(red: 0.99, green: 0.80, blue: 0.58), location: max(0.5 - tol / (2 * limit) - 0.001, 0.02)),
                    .init(color: Color(red: 0.80, green: 0.81, blue: 0.84), location: 0.5 - tol / (2 * limit)),
                    .init(color: Color(red: 0.80, green: 0.81, blue: 0.84), location: 0.5 + tol / (2 * limit)),
                    .init(color: Color(red: 0.56, green: 0.74, blue: 0.96), location: min(0.5 + tol / (2 * limit) + 0.001, 0.98)),
                    .init(color: Color(red: 0.08, green: 0.32, blue: 0.86), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack {
                    Text(String(format: "−%.0f mm · model has too much", limit))
                    Spacer()
                    Text(String(format: "+%.0f mm · model is missing this", limit))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(String(format: "Grey within ±%.1f mm. Scan to model, every vertex: mean %.1f mm, 95%% within %.1f mm.",
                            tol, preview.stats.meanMM, preview.stats.p95MM))
                    .font(.caption)
                Text(String(format: "%.0f%% within tolerance · %.0f%% missing · %.0f%% excess",
                            preview.stats.withinTolerance * 100, preview.stats.missing * 100, preview.stats.excess * 100))
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("DeviationStats")
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Measuring every vertex of the scan against the model…")
                        .font(.caption)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("DeviationLegend")
    }
}
