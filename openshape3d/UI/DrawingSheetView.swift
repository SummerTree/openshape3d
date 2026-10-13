//
//  DrawingSheetView.swift
//  openshape3d
//
//  File ▸ New Drawing (spec §15): a live preview of the drawing sheet —
//  Front, Top and side views placed by the projection standard, an
//  isometric, overall dimensions and a title block — with its options, and
//  PDF / SVG / DXF export. The sheet always follows the current model.
//

import SwiftUI
import UniformTypeIdentifiers

struct DrawingSheetView: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    /// The file waiting in the save panel (presented from the sheet itself,
    /// so several formats can be saved without closing it).
    @State private var document: ExportDocument?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = geo.size.width > 700
                let layout = viewModel.drawingLayout()
                Group {
                    if wide {
                        HStack(spacing: 0) {
                            preview(layout)
                            options.frame(width: 320)
                        }
                    } else {
                        VStack(spacing: 0) {
                            preview(layout).frame(height: geo.size.height * 0.45)
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
            .navigationTitle("Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("DrawingDone")
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

    private func preview(_ layout: DrawingLayout) -> some View {
        ZStack {
            Color(white: 0.9)
            Canvas { context, size in
                let inset: CGFloat = 16
                let k = min((size.width - inset * 2) / layout.size.x, (size.height - inset * 2) / layout.size.y)
                let paper = CGSize(width: layout.size.x * k, height: layout.size.y * k)
                let origin = CGPoint(x: (size.width - paper.width) / 2, y: (size.height - paper.height) / 2)
                func pt(_ p: SIMD2<Double>) -> CGPoint {
                    CGPoint(x: origin.x + p.x * k, y: origin.y + paper.height - p.y * k)
                }
                context.fill(Path(CGRect(origin: origin, size: paper)), with: .color(.white))
                for style in [DrawingLineStyle.border, .thin, .hidden, .visible] {
                    var path = Path()
                    for line in layout.lines where line.style == style {
                        path.move(to: pt(line.a))
                        path.addLine(to: pt(line.b))
                    }
                    let width = max(0.5, DrawingExport.width(style) * k)
                    let dash: [CGFloat] = style == .hidden ? DrawingExport.hiddenDash.map { CGFloat($0) * k } : []
                    context.stroke(path, with: .color(.black),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
                }
                for text in layout.texts {
                    let size = max(4, text.height * 1.4 * k)
                    let resolved = context.resolve(Text(text.string).font(.system(size: size)))
                    let anchor: UnitPoint = text.anchor == .start ? .bottomLeading
                        : text.anchor == .middle ? .bottom : .bottomTrailing
                    var c = context
                    let at = pt(text.position)
                    c.translateBy(x: at.x, y: at.y)
                    c.rotate(by: .radians(-text.rotation))
                    c.draw(resolved, at: .zero, anchor: anchor)
                }
            }
            if layout.isEmpty {
                Text("Nothing to draw — the design has no visible bodies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("DrawingPreview")
        .accessibilityLabel(layout.isEmpty ? "Empty drawing" : "Drawing at \(DrawingSheet.scaleLabel(layout.scale))")
    }

    // MARK: - Options

    private var options: some View {
        Form {
            Section("Sheet") {
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
            }
            Section("Views") {
                Toggle("Isometric View", isOn: $viewModel.drawingOptions.includeIsometric)
                    .accessibilityIdentifier("DrawingIsometricToggle")
                Toggle("Hidden Lines", isOn: $viewModel.drawingOptions.showHiddenLines)
                    .accessibilityIdentifier("DrawingHiddenToggle")
                Toggle("Overall Dimensions", isOn: $viewModel.drawingOptions.showDimensions)
                    .accessibilityIdentifier("DrawingDimensionsToggle")
            }
            Section {
                Text("Front, Top and Right views of the visible bodies, laid out by the standard. The drawing follows the model as it changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
