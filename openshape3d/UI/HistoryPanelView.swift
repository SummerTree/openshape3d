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
                ForEach(Array(viewModel.historyRows.enumerated()), id: \.element.id) { index, row in
                    // Subtle divider marking where rollback begins: the first
                    // rolled-back row (the one whose predecessor is still active).
                    if row.isRolledBack,
                       index == 0 || viewModel.historyRows[index - 1].isRolledBack == false {
                        rollbackDivider
                    }
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
                        onRollbackHere: { viewModel.rollbackToFeature(row.id) },
                        onEditDistance: { viewModel.editFeatureDistance(row.id, $0) },
                        onEditPatternCount: { viewModel.editPatternCount(row.id, $0) },
                        onEditPatternSpacing: { viewModel.editPatternSpacing(row.id, $0) },
                        onEditPatternAngle: { viewModel.editPatternAngle(row.id, $0) }
                    )
                    // Drag-to-reorder: the payload is the node's UUID; dropping it
                    // onto another row moves it to that row's position. Replaying
                    // out of dependency order surfaces a broken-ref badge (handled
                    // by the feature graph), so the reorder is never forbidden.
                    .draggable(row.id.raw.uuidString) {
                        Label(row.name, systemImage: "line.3.horizontal")
                            .font(.caption).padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        reorder(droppedIDs: items, onto: index)
                    }
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

    /// Move the dragged feature (by UUID payload) to the drop row's index.
    private func reorder(droppedIDs: [String], onto index: Int) -> Bool {
        guard let str = droppedIDs.first, let uuid = UUID(uuidString: str) else { return false }
        viewModel.moveFeature(FeatureID(raw: uuid), to: index)
        return true
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            // When the timeline is rolled back, offer a one-tap return to the
            // full (latest) history. Hidden when rollbackIndex is nil.
            if viewModel.rollbackIndex != nil {
                Button {
                    viewModel.clearRollback()
                } label: {
                    Label("Return to Latest", systemImage: "arrow.uturn.forward")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("ReturnToLatest")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// A thin dashed rule drawn just above the first rolled-back row to mark the
    /// boundary between the active (evaluated) prefix and the rolled-back tail.
    private var rollbackDivider: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 11))
            Text("Rolled back")
                .font(.caption2.weight(.semibold))
            VStack { Divider() }
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityIdentifier("RollbackDivider")
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
        case .moveFace: return "arrow.up.and.down.and.arrow.left.and.right"
        case .revolve: return "arrow.triangle.2.circlepath"
        case .sweep: return "scribble.variable"
        case .loft: return "square.on.square.dashed"
        case .transform: return "move.3d"
        case .mirror: return "flip.horizontal"
        case .pattern: return "square.grid.3x3"
        case .chamfer: return "square.on.circle"
        case .fillet: return "circle.circle"
        case .shell: return "cube.transparent"
        case .deleteFace: return "square.slash"
        }
    }

    /// The editable primary distance for extrude / push-pull nodes; `nil`
    /// (no inline field) for every other kind.
    private func distanceValue(for id: FeatureID) -> Double? {
        guard let node = viewModel.session.document.features.node(id) else { return nil }
        switch node.kind {
        case let .extrude(_, _, distance, _, _, _): return distance.value
        case let .pushPull(_, distance, _): return distance.value
        case let .chamfer(_, _, setback): return setback.value
        case let .fillet(_, _, radius): return radius.value
        case let .shell(_, _, thickness): return thickness.value
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
    let onRollbackHere: () -> Void
    let onEditDistance: (Double) -> Void
    let onEditPatternCount: (Int) -> Void
    let onEditPatternSpacing: (Double) -> Void
    let onEditPatternAngle: (Double) -> Void

    @State private var draft = ""
    @State private var distanceText = ""
    @State private var countText = ""
    @State private var spacingText = ""
    @State private var angleText = ""

    /// A row is visually de-emphasized when the node is suppressed OR sits at/
    /// after the rollback marker (its bodies are absent either way).
    private var dimmed: Bool { row.suppressed || row.isRolledBack }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 24)
                    .foregroundStyle(dimmed ? .tertiary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { onRename(draft) }
                        .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                        .accessibilityIdentifier("HistoryName-\(row.name)")
                    HStack(spacing: 4) {
                        Text(row.kindLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if row.isRolledBack {
                            Text("· rolled back")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityIdentifier("HistoryRolledBack-\(row.name)")
                        }
                    }
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
                        .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(row.isRolledBack)
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
                // Editing a rolled-back node is a silent no-op; block the field.
                .disabled(row.isRolledBack)
            }

            if row.isPattern {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Count")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("", text: $countText)
                            .textFieldStyle(.plain)
                            .keyboardType(.numberPad)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .frame(width: 44)
                            .onSubmit(commitCount)
                            .accessibilityIdentifier("PatternCountField-\(row.name)")
                        Stepper(
                            "",
                            value: Binding(
                                get: { Int(countText) ?? row.patternCount ?? 1 },
                                set: { countText = String($0); onEditPatternCount($0) }
                            ),
                            in: 1...999
                        )
                        .labelsHidden()
                        .accessibilityIdentifier("PatternCountStepper-\(row.name)")
                        Button(action: commitCount) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("PatternCountCommit-\(row.name)")
                    }

                    if row.patternIsCircular == true {
                        HStack(spacing: 4) {
                            Text("Angle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("", text: $angleText)
                                .textFieldStyle(.plain)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .frame(width: 60)
                                .onSubmit(commitAngle)
                                .accessibilityIdentifier("PatternAngleField-\(row.name)")
                            Text("°")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button(action: commitAngle) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("PatternAngleCommit-\(row.name)")
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("Spacing")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("", text: $spacingText)
                                .textFieldStyle(.plain)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .frame(width: 60)
                                .onSubmit(commitSpacing)
                                .accessibilityIdentifier("PatternSpacingField-\(row.name)")
                            Text("mm")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button(action: commitSpacing) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("PatternSpacingCommit-\(row.name)")
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 32)
                // Editing a rolled-back node is a silent no-op; block the fields.
                .disabled(row.isRolledBack)
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
            Button {
                onRollbackHere()
            } label: {
                Label("Roll Back to Here", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("RollbackHere-\(row.name)")
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
            seedPatternText()
        }
        .onChange(of: row.name) { _, updated in draft = updated }
        .onChange(of: distance) { _, updated in
            distanceText = updated.map(Self.fmt) ?? ""
        }
        .onChange(of: row.patternCount) { _, updated in
            countText = updated.map { String($0) } ?? ""
        }
        .onChange(of: row.patternSpacing) { _, updated in
            spacingText = updated.map(Self.fmt) ?? ""
        }
        .onChange(of: row.patternAngleDegrees) { _, updated in
            angleText = updated.map(Self.fmt) ?? ""
        }
    }

    private func seedPatternText() {
        countText = row.patternCount.map { String($0) } ?? ""
        spacingText = row.patternSpacing.map(Self.fmt) ?? ""
        angleText = row.patternAngleDegrees.map(Self.fmt) ?? ""
    }

    private func commitDistance() {
        // Accept plain numbers and simple arithmetic ("25.4/2").
        guard let value = ExpressionEvaluator.evaluate(distanceText) else { return }
        onEditDistance(value)
    }

    private func commitCount() {
        // Accept plain integers and simple arithmetic; round to nearest int.
        guard let value = ExpressionEvaluator.evaluate(countText) else { return }
        onEditPatternCount(Int(value.rounded()))
    }

    private func commitSpacing() {
        guard let value = ExpressionEvaluator.evaluate(spacingText) else { return }
        onEditPatternSpacing(value)
    }

    private func commitAngle() {
        guard let value = ExpressionEvaluator.evaluate(angleText) else { return }
        onEditPatternAngle(value)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%g", (v * 1000).rounded() / 1000)
    }
}
