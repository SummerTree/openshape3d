//
//  ProjectVersionsView.swift
//  openshape3d
//
//  Gallery ▸ a design's menu ▸ Versions… (spec §13.3): the design's earlier
//  states, newest first, each with its thumbnail, when it was kept and how
//  many bodies it had. Restore as Latest makes one the design again (what it
//  was a moment before is kept as a version first); Open as Copy puts it in
//  the gallery beside the design.
//

import SwiftUI

struct ProjectVersionsView: View {
    let project: Project
    var onRestore: (Int) -> Void
    var onCopy: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private var versions: [ProjectVersionStore.Version] {
        project.versionsKey.map(ProjectVersionStore.shared.versions) ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if versions.isEmpty {
                    Text("No versions yet. A version is kept as you work on a design — when you leave it, and every ten minutes while you change it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ProjectVersionsEmpty")
                }
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    row(version, isLatest: index == 0)
                }
            }
            .navigationTitle("Versions of “\(project.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("ProjectVersionsDone")
                }
            }
        }
    }

    private func row(_ version: ProjectVersionStore.Version, isLatest: Bool) -> some View {
        HStack(spacing: 12) {
            thumbnail(version)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Version \(version.number)").font(.headline)
                    if isLatest {
                        Text("Latest")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(version.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text([version.note, "\(version.bodies) \(version.bodies == 1 ? "body" : "bodies")"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if !isLatest {
                    Button("Restore as Latest") {
                        onRestore(version.number)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ProjectVersionRestore_\(version.number)")
                }
                Button("Open as Copy") {
                    onCopy(version.number)
                    dismiss()
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("ProjectVersionCopy_\(version.number)")
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ProjectVersion_\(version.number)")
    }

    @ViewBuilder
    private func thumbnail(_ version: ProjectVersionStore.Version) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        if let key = project.versionsKey, let data = ProjectVersionStore.shared.thumbnail(key, number: version.number),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 66)
                .clipShape(shape)
        } else {
            shape.fill(Color(.secondarySystemBackground)).frame(width: 88, height: 66)
        }
    }
}
