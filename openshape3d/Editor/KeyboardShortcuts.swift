//
//  KeyboardShortcuts.swift
//  openshape3d
//
//  Settings ▸ Keyboard Shortcuts (spec §8.4: "customizable shortcuts"). The
//  person's changes are kept as a difference from `CommandRegistry.defaults`
//  — commands moved to another chord, and commands whose chord was removed —
//  so a default added or changed in a later build still reaches everyone who
//  never touched that command.
//

import Foundation

nonisolated struct ShortcutCustomization: Codable, Equatable, Sendable {
    /// Commands given a chord other than their default.
    var bound: [String: KeyChord] = [:]
    /// Commands whose chord was removed.
    var cleared: Set<String> = []

    init() {}

    var isEmpty: Bool { bound.isEmpty && cleared.isEmpty }

    private enum CodingKeys: String, CodingKey { case bound, cleared }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bound = try c.decodeIfPresent([String: KeyChord].self, forKey: .bound) ?? [:]
        cleared = try c.decodeIfPresent(Set<String>.self, forKey: .cleared) ?? []
    }

    /// The chord `command` (as it ships) has here.
    func chord(for command: AppCommand) -> KeyChord? {
        if let chord = bound[command.id] { return chord }
        if cleared.contains(command.id) { return nil }
        // A default another command has since taken is no longer this one's.
        if let chord = command.chord, bound.values.contains(chord) { return nil }
        return command.chord
    }

    func applied(to catalog: [AppCommand]) -> [AppCommand] {
        guard !isEmpty else { return catalog }
        return catalog.map { command in
            var out = command
            out.chord = chord(for: command)
            return out
        }
    }

    /// Gives `id` the chord (nil removes it). Whatever command had that
    /// chord loses it — one chord fires one command — and is returned, so
    /// the person can be told.
    @discardableResult
    mutating func assign(_ chord: KeyChord?, to id: String,
                         catalog: [AppCommand] = CommandRegistry.defaults) -> AppCommand? {
        guard let command = catalog.first(where: { $0.id == id }) else { return nil }
        var displaced: AppCommand?
        if let chord, let other = catalog.first(where: { $0.id != id && self.chord(for: $0) == chord }) {
            displaced = other
            bound[other.id] = nil
            if other.chord != nil { cleared.insert(other.id) }
        }
        bound[id] = nil
        cleared.remove(id)
        if chord != command.chord {
            if let chord { bound[id] = chord } else { cleared.insert(id) }
        }
        normalize(catalog: catalog)
        return displaced
    }

    /// Back to the shipped chord — taking it back from any command it was
    /// given to since.
    @discardableResult
    mutating func reset(_ id: String, catalog: [AppCommand] = CommandRegistry.defaults) -> AppCommand? {
        guard let command = catalog.first(where: { $0.id == id }) else { return nil }
        return assign(command.chord, to: id, catalog: catalog)
    }

    /// Drops entries that say nothing: a binding equal to the default, a
    /// clear of a command with no default.
    private mutating func normalize(catalog: [AppCommand]) {
        for (id, chord) in bound where catalog.first(where: { $0.id == id })?.chord == chord {
            bound[id] = nil
        }
        cleared = cleared.filter { id in catalog.first(where: { $0.id == id })?.chord != nil }
    }

    // MARK: What can be a shortcut

    /// Keys a shortcut can use: letters, digits, a little punctuation, Space.
    static let assignableKeys = Set("abcdefghijklmnopqrstuvwxyz0123456789[];',./-=`\\".map(String.init) + ["space"])

    /// Chords the system or the browser keeps: quit, close, hide, minimise,
    /// settings, new tab, reload, the address bar.
    static let reserved: Set<KeyChord> = [
        KeyChord("q", .command), KeyChord("w", .command), KeyChord("h", .command), KeyChord("m", .command),
        KeyChord(",", .command), KeyChord("t", .command), KeyChord("r", .command), KeyChord("l", .command),
    ]

    enum Refusal: Equatable, Sendable {
        case unsupportedKey, reserved, typesValues
        var message: String {
            switch self {
            case .unsupportedKey: "That key can't be a shortcut. Use a letter, a digit or Space, with or without ⌘ ⌥ ⇧."
            case .reserved: "The system uses that shortcut."
            case .typesValues: "Digits and the decimal point on their own type values. Add ⌘ or ⌥."
            }
        }
    }

    /// Why `chord` can't be a shortcut, or nil when it can.
    static func refusal(for chord: KeyChord) -> Refusal? {
        guard assignableKeys.contains(chord.key) else { return .unsupportedKey }
        if reserved.contains(chord) { return .reserved }
        // Bare (or Shift-) digits and "." start a typed value (the
        // rectangle's baseline, a dimension).
        if chord.modifiers.subtracting(.shift).isEmpty, chord.key.first?.isNumber == true || chord.key == "." {
            return .typesValues
        }
        return nil
    }
}

extension CommandRegistry {
    /// The commands Settings ▸ Keyboard Shortcuts lists: everything a key
    /// can run, by category, in catalog order.
    static var customizableCommands: [AppCommand] {
        all.filter { routableIDs.contains($0.id) }
    }
}

extension AppCommand.Category {
    var title: String {
        switch self {
        case .sketch: "Sketch"
        case .modeling: "Modeling"
        case .boolean: "Combine"
        case .transform: "Transform"
        case .view: "View"
        case .edit: "Edit"
        case .project: "Project"
        }
    }
}
