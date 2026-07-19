//
//  DesignDocument.swift
//  openshape3d
//
//  In-memory document: plain value type mirrored to SwiftData by
//  DocumentSession. Sketches join in the sketch build step.
//

import Foundation

nonisolated struct DesignDocument: Sendable {
    var bodies: [Body] = []
    var sketches: [Sketch] = []
    var planes: [ConstructionPlane] = []
    var images: [InsertedImage] = []
    var symbols: [Symbol] = []

    /// Monotonic revision source for mesh changes (GPU cache invalidation).
    private var revisionCounter: UInt64 = 0

    mutating func nextRevision() -> UInt64 {
        revisionCounter += 1
        return revisionCounter
    }

    func body(with id: BodyID) -> Body? {
        bodies.first { $0.id == id }
    }

    func bodyIndex(of id: BodyID) -> Int? {
        bodies.firstIndex { $0.id == id }
    }

    /// Auto-name like "Box 2" based on what's already in the document.
    func uniqueBodyName(base: String) -> String {
        let existing = Set(bodies.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Sketches number from 1 ("Sketch 1", "Sketch 2", …), Shapr3D style.
    func uniqueSketchName(base: String = "Sketch") -> String {
        let existing = Set(sketches.map(\.name))
        var n = 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func imageIndex(of id: InsertedImageID) -> Int? {
        images.firstIndex { $0.id == id }
    }

    /// Images number from 1 ("Image 1", "Image 2", …) like sketches.
    func uniqueImageName(base: String = "Image") -> String {
        let existing = Set(images.map(\.name))
        var n = 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Symbols number from 1 ("Symbol 1", "Symbol 2", …) like sketches.
    func uniqueSymbolName(base: String = "Symbol") -> String {
        let existing = Set(symbols.map(\.name))
        var n = 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
