//
//  CommandSearchTests.swift
//  openshape3dTests
//
//  The Command Search launcher (spec §8.4). `CommandRegistryTests` already
//  covers the fuzzy matcher and the recents list as pure values; what is new
//  here is the POOL the launcher draws from.
//
//  That pool is the whole safety property. The catalog deliberately names more
//  commands than `runCommand` can perform — `unroutedChordedCommands` keeps
//  that gap visible — and a launcher showing one of those would give the user
//  a result that does nothing when chosen. Harder to explain than a dead
//  hotkey, because they just read the name off a list.
//

import XCTest
@testable import openshape3d

final class CommandSearchTests: XCTestCase {

    private let registry = CommandRegistry()

    // MARK: - Nothing offered can be dead

    /// The invariant the launcher rests on: every command it can show is one
    /// `runCommand` routes. Adding a catalog entry without routing it must not
    /// make it appear in the launcher.
    func testEveryLaunchableCommandIsRoutable() {
        for command in CommandRegistry.launchableCommands {
            XCTAssertTrue(CommandRegistry.routableIDs.contains(command.id),
                          "\(command.id) is offered by the launcher but has no route")
        }
    }

    /// …and the pool really is narrower than the catalog, so the test above is
    /// not passing vacuously.
    func testTheLauncherPoolIsNarrowerThanTheCatalog() {
        XCTAssertLessThan(CommandRegistry.launchableCommands.count,
                          CommandRegistry.all.count,
                          "the catalog names commands that cannot run yet")
        XCTAssertGreaterThan(CommandRegistry.launchableCommands.count, 20,
                             "…but the launcher should still be worth opening")
    }

    /// Offering "Command Search" inside Command Search is noise.
    func testTheLauncherDoesNotOfferItself() {
        let ids = Set(CommandRegistry.launchableCommands.map(\.id))
        XCTAssertFalse(ids.contains("app.commandSearch"))
        XCTAssertFalse(ids.contains("app.commandSearchAlt"))
    }

    /// A search over the launcher's pool can never surface an unroutable
    /// command, whatever the query.
    func testNoQuerySurfacesAnUnroutableCommand() {
        let routable = CommandRegistry.routableIDs
        for query in ["e", "fi", "sh", "un", "zoom", "face", "a", "o", "pattern"] {
            let hits = registry.search(query, in: CommandRegistry.launchableCommands)
            for hit in hits {
                XCTAssertTrue(routable.contains(hit.id),
                              "query “\(query)” surfaced unroutable \(hit.id)")
            }
        }
    }

    // MARK: - The launcher opens

    /// X and ⌘F both have to reach `runCommand`, or the panel has no way in.
    func testBothCommandSearchChordsAreRoutable() {
        for id in ["app.commandSearch", "app.commandSearchAlt"] {
            XCTAssertTrue(CommandRegistry.routableIDs.contains(id),
                          "\(id) must be routable or the launcher cannot open")
            XCTAssertNotNil(CommandRegistry.command(inCatalog: id)?.chord)
        }
    }

    // MARK: - The face tools shipped 2026-08-29 are reachable

    /// Delete Face and Replace Face exist in the app now, so the catalog
    /// entries that name them must actually run — otherwise the launcher lists
    /// two tools the user can see in the Modify palette and cannot launch.
    func testTheDirectModelingFaceToolsAreRoutable() {
        for id in ["model.deleteFace", "model.replaceFace"] {
            XCTAssertTrue(CommandRegistry.routableIDs.contains(id))
            XCTAssertTrue(CommandRegistry.launchableCommands.contains { $0.id == id },
                          "\(id) should be findable in the launcher")
        }
    }

    /// And they are findable by the name a user would type.
    func testFaceToolsAreFoundByName() throws {
        let deleteHit = registry.search("delface", in: CommandRegistry.launchableCommands).first
        XCTAssertEqual(deleteHit?.id, "model.deleteFace")
        let replaceHit = registry.search("repface", in: CommandRegistry.launchableCommands).first
        XCTAssertEqual(replaceHit?.id, "model.replaceFace")
    }

    // MARK: - Recents still work through the narrower pool

    /// An empty query shows recents — but only recents that are still
    /// launchable, so a remembered unroutable command cannot leak back in.
    func testEmptyQueryShowsOnlyLaunchableRecents() {
        var registry = CommandRegistry()
        registry.markUsed("model.extrude")
        registry.markUsed("project.new")      // real, but not routable
        registry.markUsed("model.fillet")

        let recents = registry.search("", in: CommandRegistry.launchableCommands)
        XCTAssertEqual(recents.map(\.id), ["model.fillet", "model.extrude"],
                       "the unroutable recent is dropped, order otherwise preserved")
    }

    // MARK: - Single Key Action

    /// With the launcher preference on, a bare letter stops being a hotkey —
    /// that is what frees it to be the first character of a search.
    func testCommandSearchPreferenceReleasesBareLetters() {
        var registry = CommandRegistry(singleKeyAction: .commandSearch)
        XCTAssertNil(registry.command(for: KeyChord("e")),
                     "a bare letter belongs to the launcher in this mode")
        XCTAssertNotNil(registry.command(for: KeyChord("z", .command)),
                        "chorded shortcuts are unaffected")

        registry.singleKeyAction = .hotkeys
        XCTAssertEqual(registry.command(for: KeyChord("e"))?.id, "model.extrude")
    }
}
