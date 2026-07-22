//
//  ProjectGalleryView.swift
//  openshape3d
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ProjectGalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.modifiedAt, order: .reverse) private var projects: [Project]

    @State private var path = NavigationPath()
    @State private var renamingProject: Project?
    @State private var renameText = ""
    @State private var didHandleLaunchHooks = false
    @State private var showArchiveImporter = false
    @State private var importErrorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Designs", systemImage: "cube.transparent")
                    } description: {
                        Text("Tap + to create your first design.")
                    } actions: {
                        Button("New Design", action: createProject)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(projects) { project in
                                NavigationLink(value: project.persistentModelID) {
                                    ProjectCard(project: project)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        renameText = project.name
                                        renamingProject = project
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button {
                                        duplicate(project)
                                    } label: {
                                        Label("Duplicate", systemImage: "plus.square.on.square")
                                    }
                                    Button(role: .destructive) {
                                        modelContext.delete(project)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Designs")
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showArchiveImporter = true
                    } label: {
                        Label("Import Project…", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("ImportProjectButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createProject) {
                        Label("New Design", systemImage: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showArchiveImporter,
                allowedContentTypes: [ExportDocument.os3dType, .data]
            ) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                guard let data = try? Data(contentsOf: url),
                      let archive = ProjectArchive.decode(data) else {
                    importErrorMessage =
                        "That file isn't a readable OpenShape3D archive (or was made by a newer version)."
                    return
                }
                importArchive(archive, fallbackName: url.deletingPathExtension().lastPathComponent)
            }
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importErrorMessage != nil },
                    set: { if !$0 { importErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importErrorMessage = nil }
            } message: {
                Text(importErrorMessage ?? "")
            }
            .navigationDestination(for: PersistentIdentifier.self) { id in
                if let project = modelContext.model(for: id) as? Project {
                    EditorView(project: project)
                }
            }
            .task {
                // Debug hooks for automated verification (once per launch —
                // .task refires when navigation pops back to the gallery).
                guard !didHandleLaunchHooks else { return }
                didHandleLaunchHooks = true
                if ProcessInfo.processInfo.environment["OS3D_FRESH"] != nil {
                    createProject() // always a clean design (test isolation)
                } else if ProcessInfo.processInfo.environment["OS3D_AUTO_OPEN"] != nil {
                    if let first = projects.first {
                        path.append(first.persistentModelID)
                    } else {
                        createProject()
                    }
                }
            }
            .alert("Rename Design", isPresented: renameAlertBinding) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingProject = nil }
                Button("Rename") {
                    if let project = renamingProject, !renameText.isEmpty {
                        project.name = renameText
                        project.modifiedAt = Date()
                    }
                    renamingProject = nil
                }
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )
    }

    private func createProject() {
        let base = "Untitled"
        let existing = Set(projects.map(\.name))
        var name = base
        var n = 2
        while existing.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        let project = Project(name: name)
        modelContext.insert(project)
        // Save before navigating so the model ID is permanent — navigating on
        // a temporary ID crashes once autosave swaps it out.
        try? modelContext.save()
        path.append(project.persistentModelID)
    }

    /// Duplicate = archive round-trip: snapshot the rows, remap every UUID
    /// (record IDs and the references inside blobs stay consistent), insert
    /// as a new project. Unlike the old field-copy, this carries features,
    /// variables, images, symbols and materials, and can never collide with
    /// the original's unique ID columns.
    private func duplicate(_ project: Project) {
        importArchive(
            ProjectArchive.archive(from: project),
            fallbackName: project.name,
            nameSuffix: " Copy"
        )
    }

    /// Insert an archive as a new project under a unique name and save.
    private func importArchive(
        _ archive: ProjectArchive, fallbackName: String, nameSuffix: String = ""
    ) {
        let base = (archive.name.isEmpty ? fallbackName : archive.name) + nameSuffix
        let existing = Set(projects.map(\.name))
        var name = base
        var n = 2
        while existing.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        archive.remappingAllUUIDs().insert(into: modelContext, name: name)
        try? modelContext.save()
    }
}

private struct ProjectCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                if let data = project.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)

            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            Text(project.modifiedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

#Preview {
    ProjectGalleryView()
        .modelContainer(for: Project.self, inMemory: true)
}
