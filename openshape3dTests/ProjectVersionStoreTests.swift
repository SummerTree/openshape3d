//
//  ProjectVersionStoreTests.swift
//  openshape3dTests
//
//  Spec §13.3 Project Versions: snapshots numbered from 1, newest first;
//  an unchanged design is not kept twice (its thumbnail aside); a note
//  (restoring) always keeps one; only the newest 50 stay; a version comes
//  back with its thumbnail; deleting a design forgets its versions.
//

import XCTest
@testable import openshape3d

final class ProjectVersionStoreTests: XCTestCase {

    private var root: URL!
    private var store: ProjectVersionStore { ProjectVersionStore(root: root) }
    private let key = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("versions-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func design(_ name: String, bodies: Int = 1, thumbnail: Data? = Data([1, 2, 3])) -> ProjectArchive {
        var archive = ProjectArchive(name: name)
        archive.thumbnail = thumbnail
        archive.bodies = (0..<bodies).map { _ in
            .init(id: UUID(), name: "Box", transform: Data(), primitive: nil, mesh: Data([9]), isHidden: false, material: nil)
        }
        return archive
    }

    func testVersionsAreNumberedNewestFirstAndComeBackWithTheirThumbnail() throws {
        XCTAssertTrue(store.versions(key).isEmpty)
        let first = try XCTUnwrap(store.record(design("A"), key: key, now: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.bodies, 1)
        let second = try XCTUnwrap(store.record(design("A", bodies: 3, thumbnail: Data([7])), key: key))
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(store.versions(key).map(\.number), [2, 1])
        let back = try XCTUnwrap(store.archive(key, number: 1))
        XCTAssertEqual(back.bodies.count, 1)
        XCTAssertEqual(back.thumbnail, Data([1, 2, 3]))
        XCTAssertEqual(store.archive(key, number: 2)?.thumbnail, Data([7]))
        XCTAssertEqual(store.versions(key).last?.created, Date(timeIntervalSince1970: 100))
    }

    func testAnUnchangedDesignIsNotKeptTwiceUnlessANoteSaysWhy() throws {
        let archive = design("A")
        XCTAssertNotNil(store.record(archive, key: key))
        var reThumbed = archive
        reThumbed.thumbnail = Data([4, 5])
        XCTAssertNil(store.record(reThumbed, key: key), "the same design with a new thumbnail is the same version")
        XCTAssertEqual(store.versions(key).count, 1)
        let before = try XCTUnwrap(store.record(archive, key: key, note: "Before restoring version 1"))
        XCTAssertEqual(before.note, "Before restoring version 1")
        XCTAssertEqual(store.versions(key).count, 2)
    }

    func testOnlyTheNewestVersionsAreKept() throws {
        for i in 0..<(ProjectVersionStore.limit + 3) {
            store.record(design("A", bodies: i % 2 + 1), key: key, note: "\(i)")
        }
        let versions = store.versions(key)
        XCTAssertEqual(versions.count, ProjectVersionStore.limit)
        XCTAssertEqual(versions.first?.number, ProjectVersionStore.limit + 3)
        XCTAssertEqual(versions.last?.number, 4)
        XCTAssertNil(store.archive(key, number: 3), "the oldest are gone from disk too")
    }

    func testVersionsCanBeNamedAndNamedOnesAreNeverDropped() throws {
        var a = design("A")
        let first = try XCTUnwrap(store.record(a, key: key, name: "  Before the fillets \n"))
        XCTAssertEqual(first.name, "Before the fillets", "trimmed")
        // The same design named again names the latest instead of copying it.
        a.thumbnail = Data([5])
        let same = try XCTUnwrap(store.record(a, key: key, name: "Ready to print"))
        XCTAssertEqual(same.number, 1)
        XCTAssertEqual(store.versions(key).map(\.name), ["Ready to print"])
        XCTAssertNil(store.record(a, key: key), "unnamed and unchanged: nothing")

        XCTAssertEqual(store.rename(key, number: 1, to: "Milestone")?.name, "Milestone")
        XCTAssertNil(store.rename(key, number: 9, to: "x"), "no such version")
        XCTAssertEqual(ProjectVersionStore.cleaned(String(repeating: "a", count: 200))?.count, 80)

        // Fill past the limit with unnamed versions: the named one stays.
        for i in 0..<(ProjectVersionStore.limit + 5) { store.record(design("B\(i)"), key: key) }
        let list = store.versions(key)
        XCTAssertEqual(list.count, ProjectVersionStore.limit + 1)
        XCTAssertEqual(list.last?.number, 1)
        XCTAssertEqual(list.last?.name, "Milestone")
        XCTAssertNotNil(store.archive(key, number: 1))
        XCTAssertNil(store.archive(key, number: 2), "the oldest unnamed went")

        // Taking the name off makes it an ordinary version again.
        XCTAssertNil(store.rename(key, number: 1, to: "  ")?.name)
        store.record(design("C"), key: key)
        XCTAssertFalse(store.versions(key).contains { $0.number == 1 })

        // An index written before names existed still reads.
        let old = #"[{"number":3,"created":0,"bodies":1,"bytes":10}]"#
        let decoded = try JSONDecoder().decode([ProjectVersionStore.Version].self, from: Data(old.utf8))
        XCTAssertNil(decoded[0].name)
    }

    func testForgettingADesignRemovesItsVersions() throws {
        store.record(design("A"), key: key)
        let other = UUID()
        store.record(design("B"), key: other)
        store.removeAll(key)
        XCTAssertTrue(store.versions(key).isEmpty)
        XCTAssertEqual(store.versions(other).count, 1, "other designs keep theirs")
        store.removeAll(nil)
    }
}
