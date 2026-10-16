//
//  DrawingTitleBlockEditing.swift
//  openshape3d
//
//  Drawing ▸ Title Block (spec §15): a logo, fields of the user's own, and
//  Save as Default — the title block every new design's first drawing
//  starts with. The drawing itself is DrawingSheet.appendFrame.
//

import Foundation

extension EditorViewModel {

    /// Put a logo in the title block; false when the image is not a JPEG
    /// this can read (the picker hands over JPEG laid on white).
    @discardableResult
    func setDrawingLogo(jpeg: Data) -> Bool {
        guard let logo = DrawingTitleLogo(jpeg: jpeg) else { return false }
        drawingOptions.titleLogo = logo
        return true
    }

    func removeDrawingLogo() { drawingOptions.titleLogo = nil }

    /// Add Field: an empty one, named for the next free "Field n".
    func addDrawingTitleField() {
        let used = Set(drawingOptions.titleCustomFields.map(\.label))
        let label = (1...).lazy.map { "Field \($0)" }.first { !used.contains($0) } ?? "Field"
        drawingOptions.titleCustomFields.append(DrawingTitleCustomField(label: label))
    }

    func updateDrawingTitleField(_ id: UUID, label: String? = nil, value: String? = nil) {
        guard let i = drawingOptions.titleCustomFields.firstIndex(where: { $0.id == id }) else { return }
        if let label { drawingOptions.titleCustomFields[i].label = label }
        if let value { drawingOptions.titleCustomFields[i].value = value }
    }

    func removeDrawingTitleField(_ id: UUID) {
        drawingOptions.titleCustomFields.removeAll { $0.id == id }
    }

    /// Save as Default: this drawing's title block, for new designs' drawings.
    func saveDrawingTitleTemplate() {
        AppSettings.shared.drawingTitleTemplate = DrawingTitleTemplate(from: drawingOptions)
    }

    /// Use Default: the saved title block on this drawing (its title, part
    /// number and revision kept).
    func applyDrawingTitleTemplate() {
        guard let template = AppSettings.shared.drawingTitleTemplate else { return }
        drawingOptions = template.applied(to: drawingOptions)
    }

    var hasDrawingTitleTemplate: Bool { AppSettings.shared.drawingTitleTemplate != nil }

    /// Whether this drawing's title block is the saved default already.
    var drawingTitleBlockIsDefault: Bool {
        guard let template = AppSettings.shared.drawingTitleTemplate else { return false }
        return DrawingTitleTemplate(from: drawingOptions).sameStyle(as: template)
    }
}

extension DrawingTitleTemplate {
    /// Equal but for the custom fields' IDs (each drawing gets its own).
    func sameStyle(as other: DrawingTitleTemplate) -> Bool {
        titleBlock == other.titleBlock && titleFields == other.titleFields && logo == other.logo
            && customFields.map { [$0.label, $0.value] } == other.customFields.map { [$0.label, $0.value] }
    }
}
