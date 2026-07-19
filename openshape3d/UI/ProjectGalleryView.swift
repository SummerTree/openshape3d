//
//  ProjectGalleryView.swift
//  openshape3d
//

import SwiftUI
import SwiftData

struct ProjectGalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.modifiedAt, order: .reverse) private var projects: [Project]

    @State private var path = NavigationPath()
    @State private var renamingProject: Project?
    @State private var renameText = ""
    @State private var didHandleLaunchHooks = false

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
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createProject) {
                        Label("New Design", systemImage: "plus")
                    }
                }
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

    private func duplicate(_ project: Project) {
        let copy = Project(name: "\(project.name) Copy")
        copy.thumbnail = project.thumbnail
        modelContext.insert(copy)
        for body in project.bodies {
            let bodyCopy = PersistedBody(
                bodyID: UUID(),
                name: body.name,
                transformData: body.transformData,
                primitiveData: body.primitiveData,
                meshData: body.meshData
            )
            bodyCopy.project = copy
            modelContext.insert(bodyCopy)
        }
        for sketch in project.sketches {
            let sketchCopy = PersistedSketch(sketchID: UUID(), sketchData: sketch.sketchData)
            sketchCopy.project = copy
            modelContext.insert(sketchCopy)
        }
        for plane in project.planes {
            let planeCopy = PersistedPlane(planeID: UUID(), planeData: plane.planeData)
            planeCopy.project = copy
            modelContext.insert(planeCopy)
        }
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
