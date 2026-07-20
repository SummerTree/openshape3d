//
//  HistoryPanelView.swift
//  openshape3d
//
//  Feature history / timeline panel (Phase D, Task C3): a leading sidebar
//  listing the parametric feature nodes in creation order (top = oldest) with
//  rename, suppress, delete, Zoom to, tap-to-select, an error badge, and an
//  inline distance editor for extrude / push-pull nodes. Mirrors the structure
//  and style of ItemsPanelView; consumes the C2 VM panel API.
//

import SwiftUI

struct HistoryPanelView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("History")
                if viewModel.historyRows.isEmpty {
                    emptyRow("No features yet")
                }
                ForEach(viewModel.historyRows) { row in
                    HistoryRowView(
                        icon: iconName(for: row.id),
                        row: row,
                        distance: distanceValue(for: row.id),
                        onSelect: { viewModel.selectFeature(row.id) },
                        onRename: { viewModel.renameFeature(row.id, to: $0) },
                        onToggleSuppressed: {
                            viewModel.setFeatureSuppressed(row.id, !row.suppressed)
                        },
                        onZoom: { viewModel.zoomToFeature(row.id) },
                        onDelete: { viewModel.deleteFeature(row.id) },
                        onEditDistance: { viewModel.editFeatureDistance(row.id, $0) }
                    )
                }
            }
            .padding(12)
        }
        .frame(width: 290)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityIdentifier("HistoryPanel")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }

    /// SF Symbol for a node kind (read directly from the graph node).
    private func iconName(for id: FeatureID) -> String {
        guard let node = viewModel.session.document.features.node(id) else { return "gearshape" }
        switch node.kind {
        case .primitive: return "cube"
        case .extrude: return "square.stack.3d.up"
        case .boolean: return "circle.lefthalf.filled"
        case .pushPull: return "hand.draw"
        case .revolve: return "arrow.triangle.2.circlepath"
        case .sweep: return "scribble.variable"
        case .loft: return "square.on.square.dashed"
        case .transform: return "move.3d"
        case .mirror: return "flip.horizontal"
        case .pattern: return "square.grid.3x3"
        }
    }

    /// The editable primary distance for extrude / push-pull nodes; `nil`
    /// (no inline field) for every other kind.
    private func distanceValue(for id: FeatureID) -> Double? {
        guard let node = viewModel.session.document.features.node(id) else { return nil }
        switch node.kind {
        case let .extrude(_, _, distance, _, _, _): return distance.value
        case let .pushPull(_, distance, _): return distance.value
        default: return nil
        }
    }
}

/// One history row: a type icon, an editable name with the kind label beneath,
/// an optional inline distance field (extrude / push-pull), a suppress toggle;
/// tap selects, an error badge surfaces the last eval error, and a context menu
/// offers Zoom to / Delete.
private struct HistoryRowView: View {
    let icon: String
    let row: EditorViewModel.FeatureRow
    /// Non-nil for extrude / push-pull: shows the inline distance editor.
    let distance: Double?
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onToggleSuppressed: () -> Void
    let onZoom: () -> Void
    let onDelete: () -> Void
    let onEditDistance: (Double) -> Void

    @State private var draft = ""
    @State private var distanceText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 24)
                    .foregroundStyle(row.suppressed ? .tertiary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { onRename(draft) }
                        .foregroundStyle(row.suppressed ? Color.secondary : Color.primary)
                        .accessibilityIdentifier("HistoryName-\(row.name)")
                    Text(row.kindLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if row.hasError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .help(row.errorText ?? "Error")
                        .accessibilityIdentifier("HistoryError-\(row.name)")
                }
                Button(action: onToggleSuppressed) {
                    Image(systemName: row.suppressed ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(row.suppressed ? Color.secondary : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("HistorySuppress-\(row.name)")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("HistoryDelete-\(row.name)")
            }

            if row.hasError, let text = row.errorText {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if distance != nil {
                HStack(spacing: 4) {
                    TextField("", text: $distanceText)
                        .textFieldStyle(.plain)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .frame(width: 74)
                        .onSubmit(commitDistance)
                        .accessibilityIdentifier("HistoryDistanceField")
                    Text("mm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(action: commitDistance) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("HistoryDistanceCommit-\(row.name)")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button {
                onZoom()
            } label: {
                Label("Zoom to", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HistoryRow-\(row.name)")
        .onAppear {
            draft = row.name
            distanceText = distance.map(Self.fmt) ?? ""
        }
        .onChange(of: row.name) { _, updated in draft = updated }
        .onChange(of: distance) { _, updated in
            distanceText = updated.map(Self.fmt) ?? ""
        }
    }

    private func commitDistance() {
        // Accept plain numbers and simple arithmetic ("25.4/2").
        guard let value = ExpressionEvaluator.evaluate(distanceText) else { return }
        onEditDistance(value)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%g", (v * 1000).rounded() / 1000)
    }
}
