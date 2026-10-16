//
//  DrawingSheetView.swift
//  openshape3d
//
//  Drawings (spec §15): the design's saved drawings, one at a time — a live
//  preview of the sheet (standard views placed by the projection standard,
//  an isometric, section and detail views, overall dimensions and a title
//  block) with its options, and PDF / SVG / DXF export. Views are moved by
//  dragging them on the preview. The sheet always follows the current model.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct DrawingSheetView: View {
    @Bindable var viewModel: EditorViewModel
    /// The file waiting in the save panel (presented from the sheet itself,
    /// so several formats can be saved without closing it).
    @State private var document: ExportDocument?
    /// The view being dragged on the preview and its offset when the drag began.
    @State private var drag: (key: String, start: SIMD2<Double>)?
    @State private var confirmDelete = false
    /// The drag holds a dimension or note rather than a view.
    @State private var draggingAnnotation = false
    /// Title Block ▸ Logo: from Photos or from Files.
    @State private var showLogoPhotos = false
    @State private var logoPhotoItem: PhotosPickerItem?
    @State private var showLogoFiles = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = geo.size.width > 700
                let layout = viewModel.drawingLayout()
                Group {
                    if wide {
                        HStack(spacing: 0) {
                            canvas(layout)
                            options.frame(width: 340)
                        }
                    } else {
                        VStack(spacing: 0) {
                            canvas(layout).frame(height: geo.size.height * 0.5)
                            options
                        }
                    }
                }
            }
            .fileExporter(
                isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
                document: document,
                contentType: document?.contentType ?? .data,
                defaultFilename: "\(viewModel.drawingOptions.title).\(document?.fileExtension ?? "pdf")"
            ) { result in
                document = nil
                if case .failure = result {
                    viewModel.errorMessage = "Export failed — please try again."
                }
            }
            .confirmationDialog("Delete “\(viewModel.drawingOptions.title)”?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete Drawing", role: .destructive) { viewModel.deleteActiveDrawing() }
                    .accessibilityIdentifier("DrawingDeleteConfirm")
            }
            .navigationTitle("Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { viewModel.closeDrawing() }
                        .accessibilityIdentifier("DrawingDone")
                }
                ToolbarItem(placement: .principal) {
                    drawingMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(DrawingFileFormat.allCases, id: \.self) { format in
                            Button(format.title) { export(format) }
                                .accessibilityIdentifier("DrawingExport\(format.title)")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("DrawingExportMenu")
                }
            }
        }
    }

    /// The design's drawings: switch, add, delete.
    private var drawingMenu: some View {
        Menu {
            Picker("Drawings", selection: Binding(
                get: { viewModel.activeDrawing?.id },
                set: { if let id = $0 { viewModel.selectDrawing(id) } })) {
                ForEach(viewModel.session.document.drawings) { drawing in
                    Text(drawing.id == viewModel.activeDrawing?.id ? viewModel.drawingOptions.title : drawing.name)
                        .tag(UUID?.some(drawing.id))
                }
            }
            Divider()
            Button {
                viewModel.newDrawing(designName: viewModel.session.project.name)
            } label: {
                Label("New Drawing", systemImage: "plus")
            }
            .accessibilityIdentifier("DrawingNew")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Drawing", systemImage: "trash")
            }
            .accessibilityIdentifier("DrawingDelete")
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.drawingOptions.title).font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
        }
        .accessibilityIdentifier("DrawingMenu")
    }

    private func export(_ format: DrawingFileFormat) {
        guard let data = viewModel.exportDrawing(format) else { return }
        let type: UTType
        switch format {
        case .pdf: type = .pdf
        case .svg: type = .svg
        case .dxf: type = ExportDocument.dxfType
        }
        document = ExportDocument(data: data, contentType: type, fileExtension: format.rawValue)
    }

    // MARK: - Preview

    /// Paper placement in the preview: `k` points per sheet mm.
    private struct Paper {
        let k: Double
        let origin: CGPoint
        let height: Double

        init(canvas: CGSize, sheet: SIMD2<Double>) {
            let inset = 16.0
            k = min((canvas.width - inset * 2) / sheet.x, (canvas.height - inset * 2) / sheet.y)
            height = sheet.y * k
            origin = CGPoint(x: (canvas.width - sheet.x * k) / 2, y: (canvas.height - height) / 2)
        }

        func point(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: origin.x + p.x * k, y: origin.y + height - p.y * k)
        }

        func sheet(_ p: CGPoint) -> SIMD2<Double> {
            SIMD2((p.x - origin.x) / k, (origin.y + height - p.y) / k)
        }
    }

    /// The preview under its tool bar: Move, Dimension, Note, Centreline, Bolt Circle.
    private func canvas(_ layout: DrawingLayout) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $viewModel.drawingTool) {
                    ForEach(DrawingTool.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                // Every tool's name in full; the hint takes what is left.
                .fixedSize()
                .accessibilityIdentifier("DrawingToolPicker")
                Text(toolHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("DrawingToolHint")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.9))
            preview(layout)
            sheetTabs
        }
    }

    /// The drawing's sheets, under the preview: tap one to show it, + adds one.
    private var sheetTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<(viewModel.activeDrawing?.sheetCount ?? 1), id: \.self) { index in
                    let selected = index == viewModel.activeSheet
                    Button {
                        viewModel.selectDrawingSheet(index)
                    } label: {
                        Text("Sheet \(index + 1)")
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("DrawingSheetTab_\(index + 1)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Button {
                    viewModel.addDrawingSheet()
                } label: {
                    Image(systemName: "plus")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Add Sheet")
                .accessibilityIdentifier("DrawingAddSheet")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.84))
    }

    private var toolHint: String { viewModel.drawingToolHint }

    private func preview(_ layout: DrawingLayout) -> some View {
        GeometryReader { geo in
            let paper = Paper(canvas: geo.size, sheet: layout.size)
            ZStack {
                Color(white: 0.9)
                Canvas { context, _ in
                    let k = paper.k
                    context.fill(Path(CGRect(origin: paper.origin,
                                             size: CGSize(width: layout.size.x * k, height: paper.height))),
                                 with: .color(.white))
                    if let key = drag?.key, let frame = layout.placedViews[key] {
                        let a = paper.point(frame.min - 2), b = paper.point(frame.max + 2)
                        context.fill(Path(CGRect(x: a.x, y: b.y, width: b.x - a.x, height: a.y - b.y)),
                                     with: .color(.accentColor.opacity(0.12)))
                    }
                    for image in layout.images {
                        guard let picture = UIImage(data: image.logo.jpeg) else { continue }
                        let a = paper.point(image.origin), b = paper.point(image.origin + image.size)
                        context.draw(Image(uiImage: picture),
                                     in: CGRect(x: a.x, y: b.y, width: b.x - a.x, height: a.y - b.y))
                    }
                    for style in DrawingLineStyle.drawOrder {
                        var path = Path()
                        for run in DrawingExport.runs(layout.lines.filter { $0.style == style }) {
                            path.move(to: paper.point(run[0]))
                            for p in run.dropFirst() { path.addLine(to: paper.point(p)) }
                        }
                        let width = max(0.5, DrawingExport.width(style) * k)
                        let dash = DrawingExport.dash(style).map { CGFloat($0 * k) }
                        context.stroke(path, with: .color(.black),
                                       style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
                    }
                    for text in layout.texts {
                        let size = max(4, text.height * 1.4 * k)
                        let resolved = context.resolve(Text(text.string).font(.system(size: size)))
                        let anchor: UnitPoint = text.anchor == .start ? .bottomLeading
                            : text.anchor == .middle ? .bottom : .bottomTrailing
                        var c = context
                        let at = paper.point(text.position)
                        c.translateBy(x: at.x, y: at.y)
                        c.rotate(by: .radians(-text.rotation))
                        c.draw(resolved, at: .zero, anchor: anchor)
                    }
                    // A dimension's first point or edge, and the selected annotation.
                    for p in viewModel.drawingPendingSheetPoints {
                        let at = paper.point(p)
                        context.fill(Path(ellipseIn: CGRect(x: at.x - 4, y: at.y - 4, width: 8, height: 8)),
                                     with: .color(.accentColor))
                    }
                    if let edge = viewModel.drawingPendingSheetEdge {
                        var path = Path()
                        path.move(to: paper.point(edge.a))
                        path.addLine(to: paper.point(edge.b))
                        context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                    if let id = viewModel.drawingSelectedAnnotation, let handle = layout.annotationHandles[id] {
                        let at = paper.point(handle), r = max(10, DrawingAnnotationKit.handleRadius * k)
                        context.stroke(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)),
                                       with: .color(.accentColor), lineWidth: 1.5)
                    }
                }
                if layout.isEmpty {
                    Text(viewModel.drawingBodyIDs.isEmpty
                         ? "Nothing to draw — the design has no visible bodies."
                         : "Nothing to draw — the chosen bodies are gone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in moveView(value, layout: layout, paper: paper) }
                .onEnded { _ in
                    drag = nil
                    draggingAnnotation = false
                    viewModel.drawingAnnotationDragEnded()
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                viewModel.drawingTap(at: paper.sheet(value.location))
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("DrawingPreview")
        .accessibilityLabel(layout.isEmpty ? "Empty drawing" : "Drawing at \(DrawingSheet.scaleLabel(layout.scale))")
        .accessibilityValue("\(layout.placedViews.count) views")
    }

    /// Drag a view: the smallest view frame under the drag's start moves
    /// with the finger.
    private func moveView(_ value: DragGesture.Value, layout: DrawingLayout, paper: Paper) {
        guard viewModel.drawingTool == .move else { return }
        if draggingAnnotation {
            viewModel.drawingAnnotationDragged(to: paper.sheet(value.location))
            return
        }
        if drag == nil, viewModel.drawingAnnotationDragBegan(at: paper.sheet(value.startLocation)) {
            draggingAnnotation = true
            viewModel.drawingAnnotationDragged(to: paper.sheet(value.location))
            return
        }
        if drag == nil {
            guard let key = DrawingSheet.view(at: paper.sheet(value.startLocation), in: layout) else { return }
            drag = (key, viewModel.drawingViewOffsets[key] ?? .zero)
        }
        guard let drag else { return }
        let delta = SIMD2(value.translation.width / paper.k, -value.translation.height / paper.k)
        viewModel.drawingViewOffsets[drag.key] = drag.start + delta
    }

    // MARK: - Options

    private var sheetCount: Int { viewModel.activeDrawing?.sheetCount ?? 1 }

    private var options: some View {
        Form {
            Section {
                TextField("Title", text: $viewModel.drawingOptions.title)
                    .accessibilityIdentifier("DrawingTitleField")
                Picker("Size", selection: $viewModel.drawingOptions.sheet) {
                    ForEach(DrawingSheetSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("DrawingSizePicker")
                Picker("Standard", selection: $viewModel.drawingOptions.standard) {
                    ForEach(DrawingStandard.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("DrawingStandardPicker")
                Picker("Scale", selection: $viewModel.drawingOptions.scale) {
                    Text("Automatic").tag(Double?.none)
                    ForEach(DrawingSheet.standardScales, id: \.self) { scale in
                        Text(DrawingSheet.scaleLabel(scale)).tag(Double?.some(scale))
                    }
                }
                .accessibilityIdentifier("DrawingScalePicker")
                if sheetCount > 1 {
                    Button("Delete Sheet \(viewModel.activeSheet + 1)", role: .destructive) {
                        viewModel.deleteDrawingSheet()
                    }
                    .accessibilityIdentifier("DrawingDeleteSheet")
                }
            } header: {
                Text(sheetCount > 1 ? "Sheet \(viewModel.activeSheet + 1) of \(sheetCount)" : "Sheet")
            } footer: {
                if sheetCount > 1 {
                    Text("The title, standard and title block are shared by every sheet; size, scale, views and bodies are this sheet's own.")
                }
            }
            Section {
                Picker("Layout", selection: $viewModel.drawingOptions.titleBlock) {
                    ForEach(DrawingTitleBlock.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("DrawingTitleBlockPicker")
                if viewModel.drawingOptions.titleBlock == .detailed {
                    ForEach(DrawingTitleBlock.Field.allCases, id: \.self) { field in
                        TextField(field.title, text: $viewModel.drawingOptions[field])
                            .accessibilityIdentifier("DrawingTitleField_\(field.rawValue)")
                    }
                }
                if viewModel.drawingOptions.titleBlock != .none {
                    logoRow
                    ForEach($viewModel.drawingOptions.titleCustomFields) { $field in
                        HStack {
                            TextField("Label", text: $field.label)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: 110)
                                .accessibilityIdentifier("DrawingCustomFieldLabel")
                            TextField("Value", text: $field.value)
                                .accessibilityIdentifier("DrawingCustomFieldValue")
                            Button(role: .destructive) {
                                viewModel.removeDrawingTitleField(field.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(field.label)")
                            .accessibilityIdentifier("DrawingCustomFieldRemove")
                        }
                    }
                    Button("Add Field") { viewModel.addDrawingTitleField() }
                        .accessibilityIdentifier("DrawingAddTitleField")
                }
                Button(viewModel.drawingTitleBlockIsDefault ? "Saved as Default" : "Save as Default") {
                    viewModel.saveDrawingTitleTemplate()
                }
                .disabled(viewModel.drawingTitleBlockIsDefault)
                .accessibilityIdentifier("DrawingSaveTitleTemplate")
                if viewModel.hasDrawingTitleTemplate && !viewModel.drawingTitleBlockIsDefault {
                    Button("Use Default") { viewModel.applyDrawingTitleTemplate() }
                        .accessibilityIdentifier("DrawingUseTitleTemplate")
                }
            } header: {
                Text("Title Block")
            } footer: {
                Text("Save as Default keeps this title block — layout, company, logo and your fields — for the first drawing of every design.")
            }
            Section("Views") {
                Toggle("Isometric View", isOn: $viewModel.drawingOptions.includeIsometric)
                    .accessibilityIdentifier("DrawingIsometricToggle")
                Toggle("Hidden Lines", isOn: $viewModel.drawingOptions.showHiddenLines)
                    .accessibilityIdentifier("DrawingHiddenToggle")
                Toggle("Overall Dimensions", isOn: $viewModel.drawingOptions.showDimensions)
                    .accessibilityIdentifier("DrawingDimensionsToggle")
                Toggle("Centre Marks", isOn: $viewModel.drawingOptions.showCenterMarks)
                    .accessibilityIdentifier("DrawingCenterMarksToggle")
                if !viewModel.drawingViewOffsets.isEmpty {
                    Button("Reset View Positions") { viewModel.drawingViewOffsets = [:] }
                        .accessibilityIdentifier("DrawingResetPositions")
                }
            }
            annotationsSection
            bodiesSection
            sectionViews
            detailViews
            Section {
                Text("Drag a view on the sheet to move it; Top and the side view stay lined up with Front. The drawing is saved in the design and follows the model as it changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .photosPicker(isPresented: $showLogoPhotos, selection: $logoPhotoItem, matching: .images)
        .onChange(of: logoPhotoItem) { _, item in
            guard let item else { return }
            logoPhotoItem = nil
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                setLogo(data)
            }
        }
        .fileImporter(isPresented: $showLogoFiles, allowedContentTypes: [.png, .jpeg, .image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            setLogo(try? Data(contentsOf: url))
        }
    }

    /// Title Block ▸ Logo: the logo with Replace and Remove, or Add Logo.
    @ViewBuilder
    private var logoRow: some View {
        if let logo = viewModel.drawingOptions.titleLogo {
            HStack {
                if let image = UIImage(data: logo.jpeg) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 120, maxHeight: 36, alignment: .leading)
                        .accessibilityIdentifier("DrawingLogoPreview")
                }
                Spacer()
                logoMenu("Replace")
                Button("Remove", role: .destructive) { viewModel.removeDrawingLogo() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("DrawingRemoveLogo")
            }
        } else {
            logoMenu("Add Logo…")
        }
    }

    private func logoMenu(_ title: String) -> some View {
        Menu(title) {
            Button("Photos") { pickLogo(fromPhotos: true) }
            Button("Files") { pickLogo(fromPhotos: false) }
        }
        .accessibilityIdentifier("DrawingAddLogo")
    }

    private func pickLogo(fromPhotos: Bool) {
        // The system pickers can't be driven by XCUITest: OS3D_DEBUG_DRAWING_LOGO
        // stands the debug seed picture in for the pick.
        #if DEBUG
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_DRAWING_LOGO"] != nil {
            setLogo(EditorViewModel.debugSeedImagePNG)
            return
        }
        #endif
        if fromPhotos { showLogoPhotos = true } else { showLogoFiles = true }
    }

    private func setLogo(_ data: Data?) {
        guard let data, let jpeg = DrawingLogoImage.prepare(data), viewModel.setDrawingLogo(jpeg: jpeg) else {
            viewModel.errorMessage = "Couldn't read the selected image."
            return
        }
    }

    /// Dimensions and notes placed with the tools above the preview.
    private var annotationsSection: some View {
        Section {
            if viewModel.drawingAnnotations.isEmpty {
                Text("None yet — use Dimension or Note above the sheet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($viewModel.drawingAnnotations) { $annotation in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: annotation.kind == .note ? "text.bubble"
                              : annotation.kind == .linear ? "ruler"
                              : annotation.kind == .angle ? "angle"
                              : annotation.kind == .centerline ? "line.diagonal"
                              : annotation.kind == .boltCircle ? "circle.dotted" : "circle.dashed")
                            .foregroundStyle(.secondary)
                        Text(annotation.listTitle)
                            .font(.subheadline.weight(.semibold))
                        Text(viewModel.drawingViewName(annotation.view))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.deleteDrawingAnnotation(annotation.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("DrawingAnnotationDelete")
                    }
                    if annotation.kind == .linear {
                        Picker("Orientation", selection: $annotation.orientation) {
                            ForEach(DrawingAnnotation.Orientation.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("DrawingAnnotationOrientation")
                    }
                    if annotation.isCenterline {
                        EmptyView()
                    } else if annotation.kind != .note {
                        dimensionText($annotation)
                    } else {
                        TextField("Text", text: $annotation.text, axis: .vertical)
                            .accessibilityIdentifier("DrawingNoteText")
                        if !annotation.view.isEmpty {
                            Toggle("Leader", isOn: $annotation.leader)
                        }
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(annotation.id == viewModel.drawingSelectedAnnotation
                                   ? Color.accentColor.opacity(0.12) : nil)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("DrawingAnnotation_\(annotation.kind.rawValue)")
            }
        } header: {
            Text("Dimensions & Notes")
        }
    }

    /// A dimension's prefix and suffix text, its precision and its tolerance.
    @ViewBuilder
    private func dimensionText(_ annotation: Binding<DrawingAnnotation>) -> some View {
        let kind: ExpressionValueField.Kind = annotation.wrappedValue.kind == .angle ? .plain : .length
        let unit = annotation.wrappedValue.kind == .angle ? "°" : AppSettings.shared.unit.symbol
        HStack {
            TextField("Prefix", text: annotation.prefix)
                .accessibilityIdentifier("DrawingDimensionPrefix")
            TextField("Suffix", text: annotation.suffix)
                .accessibilityIdentifier("DrawingDimensionSuffix")
        }
        Picker("Precision", selection: annotation.precision) {
            ForEach(DrawingAnnotationKit.precisionChoices, id: \.self) {
                Text(DrawingAnnotationKit.precisionTitle($0)).tag($0)
            }
        }
        .accessibilityIdentifier("DrawingDimensionPrecision")
        Picker("Tolerance", selection: annotation.tolerance) {
            ForEach(DrawingAnnotation.Tolerance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("DrawingDimensionTolerance")
        switch annotation.wrappedValue.tolerance {
        case .symmetrical:
            HStack {
                Text("±")
                Spacer()
                ExpressionValueField(placeholder: unit, value: annotation.upper, kind: kind, clamp: 0...1_000,
                                     identifier: "DrawingToleranceUpper")
            }
        case .deviation, .limits:
            HStack {
                Text("Upper")
                ExpressionValueField(placeholder: unit, value: annotation.upper, kind: kind,
                                     identifier: "DrawingToleranceUpper")
                Spacer()
                Text("Lower")
                ExpressionValueField(placeholder: unit, value: annotation.lower, kind: kind,
                                     identifier: "DrawingToleranceLower")
            }
        case .none, .basic:
            EmptyView()
        }
    }

    private var bodiesSection: some View {
        Section("Bodies") {
            let chosen = Set(viewModel.drawingBodyIDs)
            Button {
                viewModel.drawingBodyIDs = []
            } label: {
                checkRow("All Visible Bodies", checked: chosen.isEmpty)
            }
            .accessibilityIdentifier("DrawingAllBodies")
            ForEach(viewModel.session.document.bodies) { body in
                Button {
                    var ids = viewModel.drawingBodyIDs
                    if let i = ids.firstIndex(of: body.id) { ids.remove(at: i) } else { ids.append(body.id) }
                    viewModel.drawingBodyIDs = ids
                } label: {
                    checkRow(body.name, checked: chosen.contains(body.id))
                }
                .accessibilityIdentifier("DrawingBody_\(body.name)")
            }
        }
    }

    private func checkRow(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if checked { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private var sectionViews: some View {
        Section("Section Views") {
            ForEach($viewModel.drawingSections) { $section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Section \(section.label)-\(section.label)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.drawingSections.removeAll { $0.id == section.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("DrawingSectionDelete_\(section.label)")
                    }
                    Picker("Cut On", selection: $section.base) {
                        ForEach(DrawingSectionView.bases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Line", selection: $section.cut) {
                        ForEach(DrawingSectionView.Cut.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("DrawingSectionCut_\(section.label)")
                    HStack {
                        Text("Position")
                        Slider(value: $section.position, in: 0...1)
                            .accessibilityIdentifier("DrawingSectionPosition_\(section.label)")
                    }
                    Toggle("Look the Other Way", isOn: $section.flipped)
                        .accessibilityIdentifier("DrawingSectionFlip_\(section.label)")
                }
                .padding(.vertical, 4)
            }
            Button {
                viewModel.addDrawingSection()
            } label: {
                Label("Add Section View", systemImage: "square.split.diagonal")
            }
            .accessibilityIdentifier("DrawingAddSection")
        }
    }

    private var detailViews: some View {
        Section("Detail Views") {
            ForEach($viewModel.drawingDetails) { $detail in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Detail \(detail.label)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.drawingDetails.removeAll { $0.id == detail.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("DrawingDetailDelete_\(detail.label)")
                    }
                    Picker("Of", selection: $detail.base) {
                        ForEach(DrawingDetailView.bases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Magnify", selection: $detail.magnification) {
                        ForEach(DrawingDetailView.magnifications, id: \.self) { m in
                            Text("\(Int(m))×").tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("DrawingDetailMagnification_\(detail.label)")
                    HStack {
                        Text("Across").frame(width: 64, alignment: .leading)
                        Slider(value: $detail.center.x, in: 0...1)
                    }
                    HStack {
                        Text("Up").frame(width: 64, alignment: .leading)
                        Slider(value: $detail.center.y, in: 0...1)
                    }
                    HStack {
                        Text("Size").frame(width: 64, alignment: .leading)
                        Slider(value: $detail.radius, in: 0.05...0.5)
                            .accessibilityIdentifier("DrawingDetailSize_\(detail.label)")
                    }
                }
                .padding(.vertical, 4)
            }
            Button {
                viewModel.addDrawingDetail()
            } label: {
                Label("Add Detail View", systemImage: "plus.magnifyingglass")
            }
            .accessibilityIdentifier("DrawingAddDetail")
        }
    }
}
