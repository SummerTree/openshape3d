//
//  ItemsPanelView.swift
//  openshape3d
//
//  Items Manager v1 (spec §11): trailing sidebar listing bodies, sketches,
//  and construction planes with visibility, rename, Zoom to, and delete.
//

import SwiftUI

struct ItemsPanelView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        let document = viewModel.session.document
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Bodies")
                if document.bodies.isEmpty {
                    emptyRow("No bodies yet")
                }
                ForEach(document.bodies) { body in
                    ItemRowView(
                        icon: "cube",
                        name: body.name,
                        isHidden: body.isHidden,
                        renameable: true,
                        onSelect: { viewModel.selectItemBody(body.id) },
                        onToggleVisibility: {
                            viewModel.setItemHidden(.body(body.id), hidden: !body.isHidden)
                        },
                        onRename: { viewModel.renameItem(.body(body.id), to: $0) },
                        onZoom: { viewModel.zoomToItem(.body(body.id)) },
                        onDelete: { viewModel.deleteItem(.body(body.id)) }
                    )
                }

                sectionHeader("Sketches")
                if document.sketches.isEmpty {
                    emptyRow("No sketches yet")
                }
                ForEach(document.sketches) { sketch in
                    ItemRowView(
                        icon: "pencil.and.outline",
                        name: sketch.name,
                        isHidden: sketch.isHidden,
                        renameable: true,
                        onSelect: { viewModel.openItemSketch(sketch.id) },
                        onToggleVisibility: {
                            viewModel.setItemHidden(.sketch(sketch.id), hidden: !sketch.isHidden)
                        },
                        onRename: { viewModel.renameItem(.sketch(sketch.id), to: $0) },
                        onZoom: { viewModel.zoomToItem(.sketch(sketch.id)) },
                        onDelete: { viewModel.deleteItem(.sketch(sketch.id)) }
                    )
                }

                sectionHeader("Planes")
                if document.planes.isEmpty {
                    emptyRow("No planes yet")
                }
                ForEach(Array(document.planes.enumerated()), id: \.element.id) { index, plane in
                    ItemRowView(
                        icon: "square.3.layers.3d",
                        name: "Plane \(index + 1)",
                        isHidden: plane.isHidden,
                        renameable: false,
                        onSelect: {},
                        onToggleVisibility: {
                            viewModel.setItemHidden(.plane(plane.id), hidden: !plane.isHidden)
                        },
                        onRename: { _ in },
                        onZoom: { viewModel.zoomToItem(.plane(plane.id)) },
                        onDelete: { viewModel.deleteItem(.plane(plane.id)) }
                    )
                }
            }
            .padding(12)
        }
        .frame(width: 290)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityIdentifier("ItemsPanel")
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
}

/// One Items row: type icon, editable name, eye toggle; tap selects, context
/// menu offers Zoom to / Delete.
private struct ItemRowView: View {
    let icon: String
    let name: String
    let isHidden: Bool
    let renameable: Bool
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void
    let onRename: (String) -> Void
    let onZoom: () -> Void
    let onDelete: () -> Void

    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 24)
                .foregroundStyle(isHidden ? .tertiary : .secondary)
            if renameable {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit { onRename(draft) }
                    .foregroundStyle(isHidden ? Color.secondary : Color.primary)
                    .accessibilityIdentifier("ItemName-\(name)")
            } else {
                Text(name)
                    .foregroundStyle(isHidden ? Color.secondary : Color.primary)
            }
            Spacer(minLength: 4)
            Button(action: onToggleVisibility) {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(isHidden ? Color.secondary : Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ItemEye-\(name)")
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
        .accessibilityIdentifier("ItemRow-\(name)")
        .onAppear { draft = name }
        .onChange(of: name) { _, updated in draft = updated }
    }
}
