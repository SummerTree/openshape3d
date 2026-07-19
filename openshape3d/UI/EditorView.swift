//
//  EditorView.swift
//  openshape3d
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Minimal FileDocument wrapper so `.fileExporter` can save any export
/// payload (STL/OBJ/3MF/PNG); the concrete type travels with the data.
struct ExportDocument: FileDocument {
    static let stlType = UTType(filenameExtension: "stl") ?? .data
    static let objType = UTType("public.geometry-definition-format")
        ?? UTType(filenameExtension: "obj") ?? .data
    static let threeMFType = UTType("org.3mf.model")
        ?? UTType(filenameExtension: "3mf") ?? .data
    static var readableContentTypes: [UTType] {
        [stlType, objType, threeMFType, .png, .data]
    }

    var data: Data
    var contentType: UTType
    /// File extension for the default filename ("stl", "obj", …).
    var fileExtension: String

    init(data: Data, contentType: UTType, fileExtension: String) {
        self.data = data
        self.contentType = contentType
        self.fileExtension = fileExtension
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .data
        fileExtension = "dat"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Screenshot options sheet (spec §12.2): resolution, transparency, grid.
struct ScreenshotOptionsSheet: View {
    /// Multiplier of the 1024×768 base size (1x / 2x / 4x).
    @State private var resolutionScale = 1
    @State private var transparentBackground = false
    @State private var showGrid = true

    @Environment(\.dismiss) private var dismiss
    let onExport: (Int, Int, Bool, Bool) -> Void

    private static let baseSize = (width: 1024, height: 768)

    var body: some View {
        NavigationStack {
            Form {
                Picker("Resolution", selection: $resolutionScale) {
                    ForEach([1, 2, 4], id: \.self) { scale in
                        Text("\(Self.baseSize.width * scale) × \(Self.baseSize.height * scale)")
                            .tag(scale)
                    }
                }
                .accessibilityIdentifier("ScreenshotResolution")
                Toggle("Transparent Background", isOn: $transparentBackground)
                    .accessibilityIdentifier("ScreenshotTransparent")
                Toggle("Show Grid", isOn: $showGrid)
                    .accessibilityIdentifier("ScreenshotGrid")
            }
            .navigationTitle("Screenshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("ScreenshotCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        onExport(
                            Self.baseSize.width * resolutionScale,
                            Self.baseSize.height * resolutionScale,
                            transparentBackground,
                            showGrid
                        )
                        dismiss()
                    }
                    .accessibilityIdentifier("ScreenshotExport")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Modeling editor: full-bleed Metal viewport with floating tool chrome.
struct EditorView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: EditorViewModel?
    @State private var exportDocument: ExportDocument?
    @State private var showItemsPanel = false
    @State private var showImporter = false
    @State private var showScreenshotOptions = false
    /// Screenshot captured by the options sheet; promoted to `exportDocument`
    /// once the sheet has dismissed (two presentations can't overlap).
    @State private var pendingScreenshot: Data?

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

    private func sketchStatusText(_ viewModel: EditorViewModel) -> String {
        guard let sketch = viewModel.activeSketch else { return "Sketching" }
        return sketch.plane.isCoincident(with: .ground)
            ? "Sketching on ground plane"
            : "Sketching on plane"
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

    /// Measure tool pill: prompts for picks, then shows distance + deltas.
    private func measurePill(_ viewModel: EditorViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler")
            if let result = viewModel.measureResult {
                Text(EditorViewModel.formatted(result.distance, unit: "mm"))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("MeasureDistanceValue")
                Text(String(
                    format: "ΔX %.2f  ΔY %.2f  ΔZ %.2f",
                    result.deltas.x, result.deltas.y, result.deltas.z
                ))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                Text(viewModel.measurePoints.isEmpty
                    ? "Tap two points to measure"
                    : "Tap the second point")
                    .font(.subheadline)
            }
            Button("Done") {
                viewModel.exitMeasure()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
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
                VStack(spacing: 10) {
                    // Selection info strip sits above the numeric bar when
                    // both are visible (spec §16.3).
                    SelectionInfoBar(viewModel: viewModel)
                    NumericInputBar(viewModel: viewModel)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .overlay(alignment: .topTrailing) {
                // Items Manager sidebar (spec §11).
                if showItemsPanel {
                    ItemsPanelView(viewModel: viewModel)
                        .padding(.trailing, 14)
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Copy badge (spec §5.1): next gizmo drag moves a duplicate.
                if viewModel.gizmoOrigin != nil {
                    Button {
                        viewModel.copyOnDrag.toggle()
                    } label: {
                        Label("Copy", systemImage: "plus.square.on.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.copyOnDrag ? Color.blue : Color.secondary)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("CopyBadge")
                    .padding(.trailing, 16)
                    .padding(.bottom, 96)
                }
            }
            .overlay(alignment: .top) {
                if viewModel.mode.isSketching {
                    statusPill(icon: "pencil.and.outline", text: sketchStatusText(viewModel)) {
                        // Shown when the camera drifted >10° off head-on.
                        if viewModel.lookAtSketchAvailable {
                            Button("Look at Sketch") {
                                viewModel.lookAtSketch()
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("LookAtSketch")
                        }
                        Button("Exit Sketching") {
                            viewModel.finishSketch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else if case .pickingSketchPlane = viewModel.mode {
                    statusPill(
                        icon: "square.3.layers.3d",
                        text: "Choose a sketch plane"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelPlanePicking()
                        }
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
                } else if case .pickingRevolveAxis = viewModel.mode {
                    statusPill(
                        icon: "arrow.triangle.2.circlepath",
                        text: "Tap a sketch line to set the revolve axis"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelRevolveAxisPick()
                        }
                        .controlSize(.small)
                    }
                } else if case .measuring = viewModel.mode {
                    measurePill(viewModel)
                } else if case .faceSelected = viewModel.mode {
                    statusPill(
                        icon: "square.3.layers.3d.top.filled",
                        text: "Face selected — drag it to push or pull"
                    ) {
                        Button("Done") {
                            viewModel.commitTool()
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

                    // Views popover (spec §7.3): standard views + projection.
                    Menu {
                        ForEach(StandardView.allCases) { standard in
                            Button(standard.rawValue) {
                                viewModel.applyStandardView(standard)
                            }
                        }
                        Divider()
                        Toggle("Orthographic", isOn: Binding(
                            get: { viewModel.orthographicEnabled },
                            set: { viewModel.setOrthographic($0) }
                        ))
                    } label: {
                        Label("Views", systemImage: "square.stack.3d.up")
                    }
                    .accessibilityIdentifier("ViewsMenu")

                    Button {
                        showItemsPanel.toggle()
                    } label: {
                        Label("Items", systemImage: "sidebar.trailing")
                    }
                    .accessibilityIdentifier("ItemsButton")

                    Menu {
                        Button("STL File…") {
                            showImporter = true
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("ImportMenu")

                    Menu {
                        Button("STL") {
                            if let data = viewModel.exportSTL() {
                                exportDocument = ExportDocument(
                                    data: data,
                                    contentType: ExportDocument.stlType,
                                    fileExtension: "stl"
                                )
                            }
                        }
                        Button("OBJ") {
                            if let data = viewModel.exportOBJ() {
                                exportDocument = ExportDocument(
                                    data: data,
                                    contentType: ExportDocument.objType,
                                    fileExtension: "obj"
                                )
                            }
                        }
                        Button("3MF") {
                            if let data = viewModel.exportThreeMF() {
                                exportDocument = ExportDocument(
                                    data: data,
                                    contentType: ExportDocument.threeMFType,
                                    fileExtension: "3mf"
                                )
                            }
                        }
                        Divider()
                        Button("PNG Screenshot…") {
                            showScreenshotOptions = true
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("ExportMenu")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [ExportDocument.stlType]
            ) { result in
                switch result {
                case .success(let url):
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    guard let data = try? Data(contentsOf: url) else {
                        viewModel.errorMessage = "Couldn't read the selected file."
                        return
                    }
                    viewModel.importSTL(data: data, fileName: url.lastPathComponent)
                case .failure:
                    viewModel.errorMessage = "Import failed — please try again."
                }
            }
            .sheet(
                isPresented: $showScreenshotOptions,
                onDismiss: {
                    if let data = pendingScreenshot {
                        pendingScreenshot = nil
                        exportDocument = ExportDocument(
                            data: data, contentType: .png, fileExtension: "png"
                        )
                    }
                }
            ) {
                ScreenshotOptionsSheet { width, height, transparent, showGrid in
                    pendingScreenshot = viewModel.captureScreenshot(
                        width: width,
                        height: height,
                        transparentBackground: transparent,
                        showGrid: showGrid
                    )
                }
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil } }
                ),
                document: exportDocument,
                contentType: exportDocument?.contentType ?? .data,
                defaultFilename: "\(project.name).\(exportDocument?.fileExtension ?? "stl")"
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
