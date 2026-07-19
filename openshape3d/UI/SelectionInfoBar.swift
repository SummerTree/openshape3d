//
//  SelectionInfoBar.swift
//  openshape3d
//
//  Bottom selection info strip (spec §16.3): volume + bounds for a body,
//  area + perimeter for a face, length/radius for sketch entities. Read-only —
//  values come straight from EditorViewModel.selectionMeasurements.
//

import SwiftUI

struct SelectionInfoBar: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        let rows = viewModel.selectionMeasurements
        if !rows.isEmpty {
            HStack(spacing: 20) {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityIdentifier("SelectionInfoBar")
        }
    }
}
