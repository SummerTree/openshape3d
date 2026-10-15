//
//  SavedDrawing.swift
//  openshape3d
//
//  Drawings kept in the project (spec §15): each one remembers its sheet
//  options, the bodies it draws, its section and detail views and where
//  the views were moved to. The lines themselves are never stored — a
//  drawing is regenerated from the model every time it is shown, so it
//  always matches the design.
//

import Foundation
import simd

nonisolated struct SavedDrawing: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var options = DrawingOptions()
    /// The bodies drawn; empty draws every visible body.
    var bodyIDs: [BodyID] = []
    var sections: [DrawingSectionView] = []
    var details: [DrawingDetailView] = []
    /// How far each view was dragged from where the layout put it (sheet
    /// mm), keyed by `DrawingSheet.viewKey`.
    var viewOffsets: [String: SIMD2<Double>] = [:]
    /// Dimensions and notes placed on the views.
    var annotations: [DrawingAnnotation] = []

    var name: String { options.title }

    init(id: UUID = UUID(), options: DrawingOptions = DrawingOptions(), bodyIDs: [BodyID] = []) {
        self.id = id
        self.options = options
        self.bodyIDs = bodyIDs
    }

    // Every field but the id is optional on the way in, so drawings written
    // by an older build — or a newer one with fields this build lacks — load.
    private enum CodingKeys: String, CodingKey { case id, options, bodyIDs, sections, details, viewOffsets, annotations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        options = try c.decodeIfPresent(DrawingOptions.self, forKey: .options) ?? DrawingOptions()
        bodyIDs = try c.decodeIfPresent([BodyID].self, forKey: .bodyIDs) ?? []
        sections = try c.decodeIfPresent([DrawingSectionView].self, forKey: .sections) ?? []
        details = try c.decodeIfPresent([DrawingDetailView].self, forKey: .details) ?? []
        viewOffsets = try c.decodeIfPresent([String: SIMD2<Double>].self, forKey: .viewOffsets) ?? [:]
        annotations = try c.decodeIfPresent([DrawingAnnotation].self, forKey: .annotations) ?? []
    }

    /// The next free view letter. Drafting skips I, O and Q (they read as
    /// digits); after Z come AA, BB, …
    func nextLabel() -> String {
        let used = Set(sections.map(\.label) + details.map(\.label))
        let letters = "ABCDEFGHJKLMNPRSTUVWXYZ".map(String.init)
        for n in 1... {
            for letter in letters {
                let label = String(repeating: letter, count: n)
                if !used.contains(label) { return label }
            }
        }
        return "?"
    }
}

extension DesignDocument {
    /// "Drawing 1", "Drawing 2", … — or `base` itself while it is free.
    func uniqueDrawingTitle(base: String) -> String {
        let existing = Set(drawings.map(\.name))
        if !base.isEmpty, !existing.contains(base) { return base }
        let stem = base.isEmpty ? "Drawing" : base
        var n = 2
        while existing.contains("\(stem) \(n)") { n += 1 }
        return "\(stem) \(n)"
    }
}

struct AddDrawingCommand: DocumentCommand {
    let title = "New Drawing"
    let drawing: SavedDrawing

    func apply(to document: inout DesignDocument) {
        document.drawings.append(drawing)
    }

    func revert(in document: inout DesignDocument) {
        document.drawings.removeAll { $0.id == drawing.id }
    }
}

struct UpdateDrawingCommand: DocumentCommand {
    let title = "Edit Drawing"
    let old: SavedDrawing
    let new: SavedDrawing

    func apply(to document: inout DesignDocument) {
        if let i = document.drawings.firstIndex(where: { $0.id == new.id }) { document.drawings[i] = new }
    }

    func revert(in document: inout DesignDocument) {
        if let i = document.drawings.firstIndex(where: { $0.id == old.id }) { document.drawings[i] = old }
    }
}

struct DeleteDrawingCommand: DocumentCommand {
    let title = "Delete Drawing"
    let drawing: SavedDrawing
    let index: Int

    func apply(to document: inout DesignDocument) {
        document.drawings.removeAll { $0.id == drawing.id }
    }

    func revert(in document: inout DesignDocument) {
        document.drawings.insert(drawing, at: min(index, document.drawings.count))
    }
}
