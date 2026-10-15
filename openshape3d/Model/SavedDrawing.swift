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
//  A drawing has one or more sheets. The first sheet's views live in the
//  drawing's own fields (so drawings saved before sheets existed are simply
//  one-sheet drawings); the rest are `moreSheets`. The title, standard and
//  title block belong to the whole drawing; each sheet has its own paper,
//  scale, bodies, views and annotations.
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
    /// Sheets 2, 3, … (the first sheet is the fields above).
    var moreSheets: [DrawingPage] = []

    var name: String { options.title }

    var sheetCount: Int { 1 + moreSheets.count }

    /// Every sheet, first to last. Setting it keeps at least one sheet.
    var pages: [DrawingPage] {
        get { [DrawingPage(firstSheetOf: self)] + moreSheets }
        set {
            guard let first = newValue.first else { return }
            options.sheet = first.sheet
            options.scale = first.scale
            options.includeIsometric = first.includeIsometric
            options.showHiddenLines = first.showHiddenLines
            options.showDimensions = first.showDimensions
            options.showCenterMarks = first.showCenterMarks
            bodyIDs = first.bodyIDs
            sections = first.sections
            details = first.details
            viewOffsets = first.viewOffsets
            annotations = first.annotations
            moreSheets = Array(newValue.dropFirst())
        }
    }

    /// The drawing as sheet `index` shows it: that sheet's paper, views and
    /// annotations in the drawing's own fields (what `DrawingSheet.layout`
    /// draws). Out-of-range indices show the first sheet.
    func onSheet(_ index: Int) -> SavedDrawing {
        guard index > 0, index < sheetCount else { return self }
        var shown = self
        var pages = self.pages
        pages.swapAt(0, index)
        shown.pages = pages
        return shown
    }

    init(id: UUID = UUID(), options: DrawingOptions = DrawingOptions(), bodyIDs: [BodyID] = []) {
        self.id = id
        self.options = options
        self.bodyIDs = bodyIDs
    }

    // Every field but the id is optional on the way in, so drawings written
    // by an older build — or a newer one with fields this build lacks — load.
    private enum CodingKeys: String, CodingKey {
        case id, options, bodyIDs, sections, details, viewOffsets, annotations, moreSheets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        options = try c.decodeIfPresent(DrawingOptions.self, forKey: .options) ?? DrawingOptions()
        bodyIDs = try c.decodeIfPresent([BodyID].self, forKey: .bodyIDs) ?? []
        sections = try c.decodeIfPresent([DrawingSectionView].self, forKey: .sections) ?? []
        details = try c.decodeIfPresent([DrawingDetailView].self, forKey: .details) ?? []
        viewOffsets = try c.decodeIfPresent([String: SIMD2<Double>].self, forKey: .viewOffsets) ?? [:]
        annotations = try c.decodeIfPresent([DrawingAnnotation].self, forKey: .annotations) ?? []
        moreSheets = try c.decodeIfPresent([DrawingPage].self, forKey: .moreSheets) ?? []
    }

    /// Write back sheet `index` as `shown` (what `onSheet(index)` gave,
    /// edited): its paper, views and annotations go to that sheet, its
    /// title, standard and title block to the whole drawing.
    mutating func setSheet(_ index: Int, from shown: SavedDrawing) {
        var pages = self.pages
        let index = pages.indices.contains(index) ? index : 0
        var page = DrawingPage(firstSheetOf: shown)
        page.id = pages[index].id
        pages[index] = page
        options.title = shown.options.title
        options.standard = shown.options.standard
        options.titleBlock = shown.options.titleBlock
        options.titleFields = shown.options.titleFields
        self.pages = pages
    }

    /// The next free view letter, across every sheet. Drafting skips I, O
    /// and Q (they read as digits); after Z come AA, BB, …
    func nextLabel() -> String {
        let used = Set(pages.flatMap { $0.sections.map(\.label) + $0.details.map(\.label) })
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

/// One sheet of a drawing: its paper and scale, which views it shows, the
/// bodies it draws and what is placed on it.
nonisolated struct DrawingPage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var sheet: DrawingSheetSize = .a4
    var scale: Double?
    var includeIsometric = true
    var showHiddenLines = true
    var showDimensions = true
    var showCenterMarks = true
    var bodyIDs: [BodyID] = []
    var sections: [DrawingSectionView] = []
    var details: [DrawingDetailView] = []
    var viewOffsets: [String: SIMD2<Double>] = [:]
    var annotations: [DrawingAnnotation] = []

    init(id: UUID = UUID()) { self.id = id }

    /// The first sheet, read from the drawing's own fields. Its id is the
    /// drawing's: it has no id of its own.
    init(firstSheetOf drawing: SavedDrawing) {
        id = drawing.id
        sheet = drawing.options.sheet
        scale = drawing.options.scale
        includeIsometric = drawing.options.includeIsometric
        showHiddenLines = drawing.options.showHiddenLines
        showDimensions = drawing.options.showDimensions
        showCenterMarks = drawing.options.showCenterMarks
        bodyIDs = drawing.bodyIDs
        sections = drawing.sections
        details = drawing.details
        viewOffsets = drawing.viewOffsets
        annotations = drawing.annotations
    }

    /// A new sheet after `page`: the same paper, scale, view choices and
    /// bodies, nothing placed on it yet.
    init(following page: DrawingPage) {
        sheet = page.sheet
        scale = page.scale
        includeIsometric = page.includeIsometric
        showHiddenLines = page.showHiddenLines
        showDimensions = page.showDimensions
        showCenterMarks = page.showCenterMarks
        bodyIDs = page.bodyIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, sheet, scale, includeIsometric, showHiddenLines, showDimensions, showCenterMarks,
             bodyIDs, sections, details, viewOffsets, annotations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DrawingPage()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sheet = (try? c.decodeIfPresent(DrawingSheetSize.self, forKey: .sheet)) ?? d.sheet
        scale = try c.decodeIfPresent(Double.self, forKey: .scale)
        includeIsometric = try c.decodeIfPresent(Bool.self, forKey: .includeIsometric) ?? d.includeIsometric
        showHiddenLines = try c.decodeIfPresent(Bool.self, forKey: .showHiddenLines) ?? d.showHiddenLines
        showDimensions = try c.decodeIfPresent(Bool.self, forKey: .showDimensions) ?? d.showDimensions
        showCenterMarks = try c.decodeIfPresent(Bool.self, forKey: .showCenterMarks) ?? d.showCenterMarks
        bodyIDs = try c.decodeIfPresent([BodyID].self, forKey: .bodyIDs) ?? []
        sections = try c.decodeIfPresent([DrawingSectionView].self, forKey: .sections) ?? []
        details = try c.decodeIfPresent([DrawingDetailView].self, forKey: .details) ?? []
        viewOffsets = try c.decodeIfPresent([String: SIMD2<Double>].self, forKey: .viewOffsets) ?? [:]
        annotations = try c.decodeIfPresent([DrawingAnnotation].self, forKey: .annotations) ?? []
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
