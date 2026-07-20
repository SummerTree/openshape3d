//
//  EditorView.swift
//  openshape3d
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreTransferable
import PhotosUI

/// Minimal FileDocument wrapper so `.fileExporter` can save any export
/// payload (STL/OBJ/3MF/GLB/DXF/USDZ/PNG); the concrete type travels with
/// the data.
struct ExportDocument: FileDocument {
    static let stlType = UTType(filenameExtension: "stl") ?? .data
    static let objType = UTType("public.geometry-definition-format")
        ?? UTType(filenameExtension: "obj") ?? .data
    static let threeMFType = UTType("org.3mf.model")
        ?? UTType(filenameExtension: "3mf") ?? .data
    static let glbType = UTType(filenameExtension: "glb") ?? .data
    static let dxfType = UTType(filenameExtension: "dxf") ?? .data
    static let usdzType = UTType.usdz
    static var readableContentTypes: [UTType] {
        [stlType, objType, threeMFType, glbType, dxfType, usdzType, .png, .data]
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

/// Transferable wrapper so `.fileExporter(items:)` writes each per-body
/// temp file under its own name (plan §B14 "Separate File per Body").
struct ExportFileItem: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { item in
            SentTransferredFile(item.url)
        }
    }
}

/// Export options for the mesh formats where a per-body split is supported
/// (plan §B14): OBJ and GLB can emit one file per body.
struct MeshExportOptionsSheet: View {
    /// User-facing format name ("OBJ" / "GLB") for the title.
    let formatName: String
    /// Called with the per-body choice when Export is confirmed.
    let onExport: (Bool) -> Void

    @State private var perBodyFiles = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Separate File per Body", isOn: $perBodyFiles)
                    .accessibilityIdentifier("ExportPerBodyToggle")
            }
            .navigationTitle("\(formatName) Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("MeshExportCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        onExport(perBodyFiles)
                        dismiss()
                    }
                    .accessibilityIdentifier("MeshExportConfirm")
                }
            }
        }
        .presentationDetents([.medium])
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

/// User-facing labels for the Display menu (spec §16.4: "active shader
/// labeled") — UI naming stays out of the render contract.
extension DisplayMode {
    var displayLabel: String {
        switch self {
        case .shaded: return "Shaded"
        case .shadedNoEdges: return "Shaded (No Edges)"
        case .wireframe: return "Wireframe"
        case .xray: return "X-Ray"
        }
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
    /// Insert Image (plan §B10): Photos picker + image file importer.
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showImageImporter = false
    /// Screenshot captured by the options sheet; promoted to `exportDocument`
    /// once the sheet has dismissed (two presentations can't overlap).
    @State private var pendingScreenshot: Data?

    /// Mesh export options (plan §B14): which format's sheet is up.
    private enum MeshExportFormat: String, Identifiable {
        case obj = "OBJ"
        case glb = "GLB"
        var id: String { rawValue }
    }
    @State private var meshExportFormat: MeshExportFormat?
    /// Payloads produced inside the mesh options sheet; promoted once the
    /// sheet has dismissed (two presentations can't overlap), single-file
    /// into `exportDocument`, per-body into `exportItems`.
    @State private var pendingExport: ExportDocument?
    @State private var pendingExportItems: [ExportFileItem]?
    /// Per-body temp files currently offered by `.fileExporter(items:)`.
    @State private var exportItems: [ExportFileItem]?
    /// DXF import (plan §B14): entities land in a ground-plane sketch.
    @State private var showDXFImporter = false

    /// Draft name for the Make Symbol prompt (plan §B16).
    @State private var symbolNameDraft = ""
    /// Temp USDZ shown by the AR preview sheet (plan §B14).
    @State private var arPreviewURL: URL?

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

    /// Sketch-state chip inside the sketch pill (plan §C4): GREEN "Fully
    /// defined" at zero DOF, else BLUE "Under-defined — N DOF".
    @ViewBuilder
    private func sketchStateChip(_ viewModel: EditorViewModel) -> some View {
        if let status = viewModel.sketchDefinitionStatus {
            Text(status.fullyDefined
                ? "Fully defined"
                : "Under-defined — \(status.dof) DOF")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(status.fullyDefined ? Color.green : Color.blue, in: Capsule())
                .accessibilityIdentifier("SketchStateChip")
        }
    }

    private func sketchStatusText(_ viewModel: EditorViewModel) -> String {
        guard let sketch = viewModel.activeSketch else { return "Sketching" }
        if case .sketching(_, let tool) = viewModel.mode {
            switch tool {
            case .text: return "Tap to place text"
            case .project: return "Tap a body to project its edges"
            default: break
            }
        }
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

    /// Marquee rectangle over the viewport (plan §B13, spec §8.2). Standard
    /// visual cue: solid border = window (L→R drag, fully-inside selects),
    /// dashed = crossing (R→L, touched selects). Screen points come straight
    /// from the gesture, so the path ignores the safe area to line up with
    /// the full-bleed Metal view.
    @ViewBuilder
    private func marqueeOverlay(_ viewModel: EditorViewModel) -> some View {
        if let marquee = viewModel.marqueeState {
            let rect = CGRect(
                x: min(marquee.start.x, marquee.current.x),
                y: min(marquee.start.y, marquee.current.y),
                width: abs(marquee.current.x - marquee.start.x),
                height: abs(marquee.current.y - marquee.start.y)
            )
            Path { $0.addRect(rect) }
                .fill(Color.blue.opacity(0.08))
                .overlay(
                    Path { $0.addRect(rect) }
                        .stroke(
                            Color.blue,
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                dash: marquee.isWindow ? [] : [6, 4]
                            )
                        )
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
                .accessibilityIdentifier("MarqueeOverlay")
        }
    }

    /// Select-mode pill (plan §B13): filter chips (Bodies | Sketches) + Done.
    private func selectModePill(_ viewModel: EditorViewModel) -> some View {
        statusPill(
            icon: "cursorarrow.and.square.on.square.dashed",
            text: "Drag to select"
        ) {
            Button("Bodies") {
                viewModel.toggleAreaSelectBodies()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(viewModel.areaSelectIncludesBodies ? Color.blue : Color.secondary)
            .accessibilityIdentifier("SelectFilterBodies")
            Button("Sketches") {
                viewModel.toggleAreaSelectSketches()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(viewModel.areaSelectIncludesSketches ? Color.blue : Color.secondary)
            .accessibilityIdentifier("SelectFilterSketches")
            Button("Done") {
                viewModel.exitSelectMode()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("SelectModeDone")
        }
    }

    /// Writes per-body payloads into a fresh temp folder and returns exporter
    /// items named "<body>.<ext>"; nil (with a user-facing error) on failure.
    private func perBodyExportItems(
        _ payloads: [(name: String, data: Data)]?,
        fileExtension: String,
        viewModel: EditorViewModel
    ) -> [ExportFileItem]? {
        guard let payloads else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("os3d-perbody-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            return try payloads.map { payload in
                let stem = payload.name.replacingOccurrences(of: "/", with: "-")
                let url = directory
                    .appendingPathComponent(stem.isEmpty ? "Body" : stem)
                    .appendingPathExtension(fileExtension)
                try payload.data.write(to: url)
                return ExportFileItem(url: url)
            }
        } catch {
            viewModel.errorMessage = "Export failed — please try again."
            return nil
        }
    }

    /// Mesh options sheet confirm (plan §B14): stages the chosen OBJ/GLB
    /// payload for the exporter that presents once the sheet dismisses.
    private func stageMeshExport(
        _ format: MeshExportFormat, perBody: Bool, viewModel: EditorViewModel
    ) {
        switch (format, perBody) {
        case (.obj, false):
            if let data = viewModel.exportOBJ() {
                pendingExport = ExportDocument(
                    data: data, contentType: ExportDocument.objType, fileExtension: "obj"
                )
            }
        case (.obj, true):
            pendingExportItems = perBodyExportItems(
                viewModel.exportOBJPerBody(), fileExtension: "obj", viewModel: viewModel
            )
        case (.glb, false):
            if let data = viewModel.exportGLB() {
                pendingExport = ExportDocument(
                    data: data, contentType: ExportDocument.glbType, fileExtension: "glb"
                )
            }
        case (.glb, true):
            pendingExportItems = perBodyExportItems(
                viewModel.exportGLBPerBody(), fileExtension: "glb", viewModel: viewModel
            )
        }
    }

    /// AR Preview (plan §B14): exports a temp USDZ and presents Quick Look.
    private func presentARPreview(_ viewModel: EditorViewModel) {
        guard let data = viewModel.exportUSDZ() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("os3d-ar-preview-\(UUID().uuidString)")
            .appendingPathExtension("usdz")
        do {
            try data.write(to: url)
            arPreviewURL = url
        } catch {
            viewModel.errorMessage = "Couldn't prepare the AR preview — please try again."
        }
    }

    /// Toolbar Import menu (STL/DXF files, inserted images).
    private func importMenu(_ viewModel: EditorViewModel) -> some View {
        Menu {
            Button("STL File…") {
                showImporter = true
            }
            // DXF import (plan §B14): entities join a ground-plane
            // sketch as one undo step.
            Button("DXF File…") {
                showDXFImporter = true
            }
            .accessibilityIdentifier("ImportDXF")
            Divider()
            // Insert Image (plan §B10, spec §6.3): the picked
            // picture waits for a plane tap (ground by default).
            Button("Image from Photos…") {
                showPhotoPicker = true
            }
            .accessibilityIdentifier("InsertImagePhotos")
            Button("Image from Files…") {
                showImageImporter = true
            }
            .accessibilityIdentifier("InsertImageFiles")
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("ImportMenu")
    }

    /// Toolbar Export menu (spec §12, plan §B14): mesh formats, sketch DXF,
    /// screenshot, and — where ModelIO can write USDZ — USDZ + AR Preview.
    private func exportMenu(_ viewModel: EditorViewModel) -> some View {
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
            // OBJ and GLB open an options sheet (plan §B14): both
            // support the "Separate File per Body" split.
            Button("OBJ") {
                meshExportFormat = .obj
            }
            Button("GLB") {
                meshExportFormat = .glb
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
            // USDZ only where ModelIO can actually write it
            // (never faked — some simulators can't).
            if USDZExporter.isSupported {
                Button("USDZ") {
                    if let data = viewModel.exportUSDZ() {
                        exportDocument = ExportDocument(
                            data: data,
                            contentType: ExportDocument.usdzType,
                            fileExtension: "usdz"
                        )
                    }
                }
            }
            // DXF of the active/ground sketch (plan §B14).
            Button("DXF") {
                if let data = viewModel.exportDXF() {
                    exportDocument = ExportDocument(
                        data: data,
                        contentType: ExportDocument.dxfType,
                        fileExtension: "dxf"
                    )
                }
            }
            Divider()
            Button("PNG Screenshot…") {
                showScreenshotOptions = true
            }
            if USDZExporter.isSupported {
                Button {
                    presentARPreview(viewModel)
                } label: {
                    Label("AR Preview", systemImage: "arkit")
                }
                .accessibilityIdentifier("ARPreviewButton")
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("ExportMenu")
    }

    /// Viewport + floating chrome + toolbar; the presentation modifiers
    /// (importers, exporters, sheets, alerts) attach in `editorContent`.
    /// Split keeps each expression type-checkable in reasonable time.
    private func viewportChrome(_ viewModel: EditorViewModel) -> some View {
        ViewportView(viewModel: viewModel)
            .ignoresSafeArea()
            .overlay {
                marqueeOverlay(viewModel)
            }
            .overlay {
                // Constraint glyphs: tap to select, Delete removes (plan §C3).
                // Below the dimension overlay so that when an auto-constraint
                // glyph and a dimension label share an anchor (e.g. a horizontal
                // line's "H" glyph over its length label), tapping opens the
                // dimension editor — the primary interaction — rather than
                // selecting the glyph (which is also deletable via the Items
                // panel).
                SketchConstraintOverlay(viewModel: viewModel)
            }
            .overlay {
                // Sketch dimension annotations + inline editors (plan §C2).
                SketchDimensionOverlay(viewModel: viewModel)
            }
            .overlay {
                // Per-point DOF markers: blue hollow = free, green =
                // constrained, blue square = locked. Non-interactive (plan §C4).
                SketchPointStateOverlay(viewModel: viewModel)
            }
            .overlay {
                // Shapr3D on-arrow value pill for extrude / diameter (§4.1).
                ExtrudeGizmoOverlay(viewModel: viewModel)
            }
            .overlay(alignment: .leading) {
                ToolPaletteView(viewModel: viewModel)
                    .padding(.leading, 14)
                    // Keep the (scrollable) palette clear of the top bar and
                    // the bottom info/input bars, which span the full width:
                    // without the inset the last tools (Delete) can sit under
                    // the numeric bar and become untappable in portrait.
                    .padding(.top, 8)
                    .padding(.bottom, 96)
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
                } else if viewModel.mode.isSketching,
                          !viewModel.selectedSketchEntityIDs.isEmpty {
                    // Sketch Copy chip (spec §1.10): the next selection-gizmo
                    // drag moves/rotates duplicates.
                    Button {
                        viewModel.sketchCopyOnDrag.toggle()
                    } label: {
                        Label("Copy", systemImage: "plus.square.on.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.sketchCopyOnDrag ? Color.blue : Color.secondary)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("SketchCopyBadge")
                    .padding(.trailing, 16)
                    .padding(.bottom, 96)
                } else if viewModel.sectionState != nil {
                    // Section badges (spec §16.1): Flip switches the visible
                    // side; Off restores the full model.
                    HStack(spacing: 8) {
                        Button {
                            viewModel.flipSection()
                        } label: {
                            Label("Flip", systemImage: "arrow.left.arrow.right")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("SectionFlip")
                        Button {
                            viewModel.endSection()
                        } label: {
                            Label("Section Off", systemImage: "xmark")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("SectionOff")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.secondary)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 16)
                    .padding(.bottom, 96)
                }
            }
            .overlay(alignment: .top) {
                if viewModel.selectModeActive {
                    selectModePill(viewModel)
                } else if viewModel.mode.isSketching, let symbol = viewModel.pendingSymbol {
                    // Insert Symbol armed (plan §B16): each tap stamps an
                    // instance; Done (or Esc) exits placement.
                    statusPill(
                        icon: "rectangle.stack",
                        text: "Tap to place \"\(symbol.name)\""
                    ) {
                        Button("Done") {
                            viewModel.cancelInsertSymbol()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("InsertSymbolDone")
                    }
                } else if viewModel.mode.isSketching {
                    statusPill(icon: "pencil.and.outline", text: sketchStatusText(viewModel)) {
                        sketchStateChip(viewModel)
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
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingSectionPlane = viewModel.mode {
                    statusPill(
                        icon: "square.split.diagonal.2x2",
                        text: "Choose a section plane"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelSectionPlanePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingImagePlane = viewModel.mode {
                    statusPill(
                        icon: "photo",
                        text: "Tap a plane for the image"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelImagePlanePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
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
                        .keyboardShortcut(.cancelAction)
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
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingSweepPath = viewModel.mode {
                    // Pill mirrors the sweep bar's segment count (plan §B1).
                    let count = viewModel.toolContext?.sweepPathEntityIDs.count ?? 0
                    statusPill(
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        text: count == 0
                            ? "Tap sketch lines to build the sweep path"
                            : "Sweep path: \(count) segment\(count == 1 ? "" : "s") chained"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelSweepPathPick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingLoftProfiles = viewModel.mode {
                    // Pill mirrors the loft bar's section count (plan §B2).
                    let count = viewModel.toolContext?.loftProfiles.count ?? 0
                    statusPill(
                        icon: "square.stack.3d.up",
                        text: count < 2
                            ? "Tap profile fills to add loft sections"
                            : "Loft: \(count) sections in tap order"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelLoftProfilePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingSplitCutter = viewModel.mode {
                    statusPill(
                        icon: "square.split.1x2",
                        text: "Tap a plane or profile to split"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelSplitCutterPick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .patterning = viewModel.mode {
                    statusPill(
                        icon: "square.grid.3x3",
                        text: "Set pattern options below, then Apply"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelPattern()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .rotatingAroundAxis = viewModel.mode {
                    statusPill(
                        icon: "arrow.clockwise",
                        text: viewModel.rotateAxisState?.hasAxis == true
                            ? "Drag to rotate, or type an angle"
                            : "Tap a sketch line, or pick a world axis"
                    ) {
                        if viewModel.rotateAxisState?.hasAxis != true {
                            Button("X") { viewModel.setRotateWorldAxis(.x) }
                                .controlSize(.small)
                                .accessibilityIdentifier("RotateAxisX")
                            Button("Y") { viewModel.setRotateWorldAxis(.y) }
                                .controlSize(.small)
                                .accessibilityIdentifier("RotateAxisY")
                            Button("Z") { viewModel.setRotateWorldAxis(.z) }
                                .controlSize(.small)
                                .accessibilityIdentifier("RotateAxisZ")
                        }
                        Button("Cancel") {
                            viewModel.cancelRotateAxis()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .translating = viewModel.mode {
                    statusPill(
                        icon: "arrow.right.to.line",
                        text: viewModel.transformPickPoints.isEmpty
                            ? "Tap the source point"
                            : "Tap the destination point"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelTranslate()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .aligning = viewModel.mode {
                    statusPill(
                        icon: "point.3.connected.trianglepath.dotted",
                        text: viewModel.transformPickPoints.isEmpty
                            ? "Tap a point on the body to move"
                            : "Tap the destination point"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelAlign()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
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

                    // Views popover (spec §7.3): standard views + projection,
                    // plus Display modes / Isolate / Section (spec §16).
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
                        Divider()
                        // Display modes (spec §16.4); the submenu label names
                        // the active shader.
                        Menu {
                            Picker("Display", selection: Binding(
                                get: { viewModel.displayMode },
                                set: { viewModel.displayMode = $0 }
                            )) {
                                ForEach(DisplayMode.allCases, id: \.self) { mode in
                                    Text(mode.displayLabel).tag(mode)
                                }
                            }
                            Divider()
                            Toggle("Show Hidden Edges", isOn: Binding(
                                get: { viewModel.showHiddenEdges },
                                set: { viewModel.showHiddenEdges = $0 }
                            ))
                        } label: {
                            Label(
                                "Display: \(viewModel.displayMode.displayLabel)",
                                systemImage: "cube.transparent"
                            )
                        }
                        // Ground blob shadows (visualization v1, plan §B15).
                        Toggle("Ground Shadow", isOn: Binding(
                            get: { viewModel.groundShadowEnabled },
                            set: { viewModel.groundShadowEnabled = $0 }
                        ))
                        // Isolate (spec §16.2): hide everything but the
                        // selection; exiting restores.
                        if viewModel.isIsolateActive {
                            Button("Exit Isolate") {
                                viewModel.exitIsolate()
                            }
                        } else {
                            Button("Isolate") {
                                viewModel.enterIsolate()
                            }
                            .disabled(viewModel.selection.isEmpty)
                        }
                        // Section View (spec §16.1).
                        if viewModel.sectionState != nil {
                            Button("Flip Section") {
                                viewModel.flipSection()
                            }
                            Button("Section Off") {
                                viewModel.endSection()
                            }
                        } else {
                            Button("Section") {
                                viewModel.beginSectionPlanePick()
                            }
                        }
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

                    importMenu(viewModel)

                    exportMenu(viewModel)
                }
            }
    }

    @ViewBuilder
    private func editorContent(_ viewModel: EditorViewModel) -> some View {
        viewportChrome(viewModel)
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
            .fileImporter(
                isPresented: $showDXFImporter,
                allowedContentTypes: [ExportDocument.dxfType]
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
                    viewModel.importDXF(data: data, fileName: url.lastPathComponent)
                case .failure:
                    viewModel.errorMessage = "Import failed — please try again."
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoPickerItem,
                matching: .images
            )
            .onChange(of: photoPickerItem) { _, item in
                guard let item else { return }
                photoPickerItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        viewModel.beginInsertImage(data: data)
                    } else {
                        viewModel.errorMessage = "Couldn't read the selected image."
                    }
                }
            }
            .fileImporter(
                isPresented: $showImageImporter,
                allowedContentTypes: [.png, .jpeg, .image]
            ) { result in
                switch result {
                case .success(let url):
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    guard let data = try? Data(contentsOf: url) else {
                        viewModel.errorMessage = "Couldn't read the selected image."
                        return
                    }
                    viewModel.beginInsertImage(data: data)
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
            .sheet(
                item: $meshExportFormat,
                onDismiss: {
                    // Promote whichever payload the sheet staged; the
                    // exporter can only present after the sheet is gone.
                    if let staged = pendingExport {
                        pendingExport = nil
                        exportDocument = staged
                    } else if let staged = pendingExportItems {
                        pendingExportItems = nil
                        exportItems = staged
                    }
                }
            ) { format in
                MeshExportOptionsSheet(formatName: format.rawValue) { perBody in
                    stageMeshExport(format, perBody: perBody, viewModel: viewModel)
                }
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportItems != nil },
                    set: { if !$0 { exportItems = nil } }
                ),
                items: exportItems ?? []
            ) { result in
                exportItems = nil
                if case .failure = result {
                    viewModel.errorMessage = "Export failed — please try again."
                }
            }
            .sheet(isPresented: Binding(
                get: { arPreviewURL != nil },
                set: { if !$0 { arPreviewURL = nil } }
            )) {
                if let url = arPreviewURL {
                    ARQuickLookView(url: url)
                        .ignoresSafeArea()
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.textPlacement != nil },
                set: { if !$0 { viewModel.textPlacement = nil } }
            )) {
                TextToolSheet { content, height, fontName in
                    viewModel.commitText(content: content, height: height, fontName: fontName)
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showMaterialSheet },
                set: { viewModel.showMaterialSheet = $0 }
            )) {
                // Body material assignment (plan §B15): one undoable
                // SetMaterialCommand over the whole selection.
                MaterialSheet(initial: viewModel.materialForSelection) { spec in
                    viewModel.applyMaterial(spec)
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showConstraintSettings },
                set: { viewModel.showConstraintSettings = $0 }
            )) {
                // Auto-constrain inference settings (plan §B, contract D).
                ConstraintSettingsView(viewModel: viewModel)
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
            .confirmationDialog(
                "Select Through",
                isPresented: Binding(
                    get: { viewModel.selectThroughCandidates != nil },
                    set: { if !$0 { viewModel.selectThroughCandidates = nil } }
                ),
                titleVisibility: .visible
            ) {
                // Long-press hit list, front→back (plan §B13, spec §8.3):
                // choosing an occluded body selects it (Select Through).
                ForEach(viewModel.selectThroughCandidates ?? []) { candidate in
                    Button(candidate.name) {
                        viewModel.chooseSelectThrough(candidate.id)
                    }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.selectThroughCandidates = nil
                }
            }
            .alert(
                "Make Symbol",
                isPresented: Binding(
                    get: { viewModel.showMakeSymbolPrompt },
                    set: { viewModel.showMakeSymbolPrompt = $0 }
                )
            ) {
                // Name prompt (plan §B16): the selected sketch entities
                // become a reusable symbol in the document.
                TextField("Name", text: $symbolNameDraft)
                Button("Create") {
                    viewModel.makeSymbol(named: symbolNameDraft)
                    symbolNameDraft = ""
                }
                Button("Cancel", role: .cancel) {
                    symbolNameDraft = ""
                }
            } message: {
                Text("Save the selected sketch entities as a reusable symbol.")
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
