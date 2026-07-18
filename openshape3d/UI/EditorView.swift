//
//  EditorView.swift
//  openshape3d
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Minimal FileDocument wrapper so `.fileExporter` can save binary STL.
struct STLDocument: FileDocument {
    static let stlType = UTType(filenameExtension: "stl") ?? .data
    static var readableContentTypes: [UTType] { [stlType] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Modeling editor: full-bleed Metal viewport with floating tool chrome.
struct EditorView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: EditorViewModel?
    @State private var exportDocument: STLDocument?

    var body: some View {
        Group {
            if let viewModel {
                editorContent(viewModel)
            } else {
                Color(.systemGroupedBackground).ignoresSafeArea()
            }
        }
        .task {
            if viewModel == nil {
                viewModel = EditorViewModel(project: project, modelContext: modelContext)
                viewModel?.debugSeedIfRequested()
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            viewModel?.saveThumbnail()
            viewModel?.session.save()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel?.saveThumbnail()
                viewModel?.session.save()
            }
        }
    }

    private func statusPill(
        icon: String, text: String, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
            Text(text)
                .font(.subheadline)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func editorContent(_ viewModel: EditorViewModel) -> some View {
        ViewportView(viewModel: viewModel)
            .ignoresSafeArea()
            .overlay(alignment: .leading) {
                ToolPaletteView(viewModel: viewModel)
                    .padding(.leading, 14)
            }
            .overlay(alignment: .bottom) {
                NumericInputBar(viewModel: viewModel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .top) {
                if viewModel.mode.isSketching {
                    statusPill(icon: "pencil.and.outline", text: "Sketching on ground plane") {
                        Button("Exit Sketching") {
                            viewModel.finishSketch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else if case .pickingBooleanTool(let kind, _) = viewModel.mode {
                    statusPill(
                        icon: "square.on.square",
                        text: "Tap the second body to \(kind.rawValue)"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelBooleanPicking()
                        }
                        .controlSize(.small)
                    }
                } else if case .faceSelected = viewModel.mode {
                    statusPill(
                        icon: "square.3.layers.3d.top.filled",
                        text: "Face selected — drag it to push or pull"
                    ) {
                        Button("Done") {
                            viewModel.commitExtrude()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .overlay {
                if viewModel.isComputingBoolean {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Computing…")
                            .font(.subheadline)
                        Button("Cancel") {
                            viewModel.cancelBooleanComputation()
                        }
                        .controlSize(.small)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        viewModel.undo()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!viewModel.session.undoStack.canUndo)

                    Button {
                        viewModel.redo()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!viewModel.session.undoStack.canRedo)

                    Button {
                        viewModel.fitView()
                    } label: {
                        Label("Fit View", systemImage: "arrow.up.left.and.arrow.down.right")
                    }

                    Button {
                        if let data = viewModel.exportSTL() {
                            exportDocument = STLDocument(data: data)
                        }
                    } label: {
                        Label("Export STL", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil } }
                ),
                document: exportDocument,
                contentType: STLDocument.stlType,
                defaultFilename: "\(project.name).stl"
            ) { result in
                exportDocument = nil
                if case .failure = result {
                    viewModel.errorMessage = "Export failed — please try again."
                }
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
    }
}
