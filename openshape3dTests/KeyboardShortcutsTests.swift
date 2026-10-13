//
//  KeyboardShortcutsTests.swift
//  openshape3dTests
//
//  Settings ▸ Keyboard Shortcuts (spec §8.4): a chord fires one command, a
//  shortcut moved onto a taken chord takes it, resets restore the shipped
//  keys, and the system's own chords stay out of reach.
//

import XCTest
@testable import openshape3d

final class KeyboardShortcutsTests: XCTestCase {

    private func chord(_ id: String, _ c: ShortcutCustomization) -> KeyChord? {
        c.applied(to: CommandRegistry.defaults).first { $0.id == id }?.chord
    }

    func testUntouchedIsTheDefaults() {
        let c = ShortcutCustomization()
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.applied(to: CommandRegistry.defaults), CommandRegistry.defaults)
    }

    func testGivingAShortcutToACommandWithout() {
        var c = ShortcutCustomization()
        XCTAssertNil(chord("sketch.ellipse", c))
        XCTAssertNil(c.assign(KeyChord("j"), to: "sketch.ellipse"))
        XCTAssertEqual(chord("sketch.ellipse", c), KeyChord("j"))
        XCTAssertEqual(chord("sketch.line", c), KeyChord("l"), "others keep theirs")
    }

    func testATakenChordMovesAndNamesTheLoser() {
        var c = ShortcutCustomization()
        let displaced = c.assign(KeyChord("l"), to: "sketch.ellipse")
        XCTAssertEqual(displaced?.id, "sketch.line")
        XCTAssertEqual(chord("sketch.ellipse", c), KeyChord("l"))
        XCTAssertNil(chord("sketch.line", c), "one chord, one command")
        let applied = c.applied(to: CommandRegistry.defaults)
        XCTAssertEqual(applied.filter { $0.chord == KeyChord("l") }.count, 1)

        // Resetting Line takes its key back from Ellipse.
        XCTAssertEqual(c.reset("sketch.line")?.id, "sketch.ellipse")
        XCTAssertEqual(chord("sketch.line", c), KeyChord("l"))
        XCTAssertNil(chord("sketch.ellipse", c))
        XCTAssertTrue(c.isEmpty, "back to the defaults leaves nothing stored")
    }

    func testMovingAndRemovingADefault() {
        var c = ShortcutCustomization()
        c.assign(KeyChord("k", .command), to: "sketch.line")
        XCTAssertEqual(chord("sketch.line", c), KeyChord("k", .command))
        c.assign(nil, to: "model.extrude")
        XCTAssertNil(chord("model.extrude", c))
        // Assigning the shipped chord again is the same as resetting.
        c.assign(KeyChord("l"), to: "sketch.line")
        c.assign(KeyChord("e"), to: "model.extrude")
        XCTAssertTrue(c.isEmpty)
    }

    func testNoTwoCommandsShareAChordAfterAnySequence() {
        var c = ShortcutCustomization()
        let ids = CommandRegistry.customizableCommands.map(\.id)
        let chords = [KeyChord("a"), KeyChord("1", .command), KeyChord("e"), KeyChord("j"), KeyChord("z", .command)]
        for (i, id) in ids.prefix(20).enumerated() {
            c.assign(chords[i % chords.count], to: id)
        }
        let used = c.applied(to: CommandRegistry.defaults).compactMap(\.chord)
        XCTAssertEqual(used.count, Set(used).count)
    }

    func testWhatCanBeAShortcut() {
        XCTAssertNil(ShortcutCustomization.refusal(for: KeyChord("j")))
        XCTAssertNil(ShortcutCustomization.refusal(for: KeyChord("1", .command)))
        XCTAssertNil(ShortcutCustomization.refusal(for: KeyChord("space", .shift)))
        XCTAssertEqual(ShortcutCustomization.refusal(for: KeyChord("q", .command)), .reserved)
        XCTAssertEqual(ShortcutCustomization.refusal(for: KeyChord(",", .command)), .reserved)
        XCTAssertEqual(ShortcutCustomization.refusal(for: KeyChord("1")), .typesValues)
        XCTAssertEqual(ShortcutCustomization.refusal(for: KeyChord(".", .shift)), .typesValues)
        XCTAssertEqual(ShortcutCustomization.refusal(for: KeyChord("f1")), .unsupportedKey)
    }

    func testCodableRoundTripAndOlderData() throws {
        var c = ShortcutCustomization()
        c.assign(KeyChord("j", [.command, .shift]), to: "sketch.ellipse")
        c.assign(nil, to: "model.extrude")
        let decoded = try JSONDecoder().decode(ShortcutCustomization.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
        XCTAssertTrue(try JSONDecoder().decode(ShortcutCustomization.self, from: Data("{}".utf8)).isEmpty)
    }

    func testTheRegistryFollowsTheCustomization() {
        let saved = CommandRegistry.customization
        defer { CommandRegistry.customization = saved }
        var c = ShortcutCustomization()
        c.assign(KeyChord("j"), to: "sketch.ellipse")
        CommandRegistry.customization = c
        let registry = CommandRegistry()
        XCTAssertEqual(registry.command(for: KeyChord("j"))?.id, "sketch.ellipse")
        XCTAssertTrue(CommandRegistry.routableChordedCommands.contains { $0.id == "sketch.ellipse" })
        CommandRegistry.customization = ShortcutCustomization()
        XCTAssertNil(registry.command(for: KeyChord("j")))
    }

    @MainActor
    func testPersistsWithoutTouchingTheLiveCatalog() throws {
        let saved = CommandRegistry.customization
        defer { CommandRegistry.customization = saved }
        let suite = "KeyboardShortcutsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.shortcuts.isEmpty)
        settings.shortcuts.assign(KeyChord("j"), to: "sketch.ellipse")
        XCTAssertEqual(AppSettings(defaults: defaults).shortcuts, settings.shortcuts)
        XCTAssertEqual(CommandRegistry.customization, saved, "a settings copy other than the app's changes nothing live")
    }
}
