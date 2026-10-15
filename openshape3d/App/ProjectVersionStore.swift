//
//  ProjectVersionStore.swift
//  openshape3d
//
//  Project Versions (spec §13.3): earlier states of a design, kept on the
//  device. Each design (by `Project.versionsKey`) has a folder of numbered
//  snapshots — the design as an .os3d archive without its thumbnail, the
//  thumbnail beside it, and an index — written by the editor as you work
//  (`EditorView`) and listed, restored or opened as a copy from the gallery
//  (`ProjectVersionsView`). Files rather than SwiftData rows: a snapshot is a
//  whole design, and keeping it out of the store keeps the store small and
//  its schema unchanged.
//

import Foundation

struct ProjectVersionStore {
    /// One snapshot, as the index lists it.
    struct Version: Codable, Equatable, Identifiable {
        var number: Int
        var created: Date
        /// Why it was taken when not simply as you worked:
        /// "Before restoring version 3", "Restored from version 3".
        var note: String?
        var bodies: Int
        var bytes: Int
        var id: Int { number }
    }

    /// Versions kept per design; the oldest go first.
    static let limit = 50
    /// While editing, at most one version per this many seconds.
    static let interval: TimeInterval = 600

    let root: URL

    static let shared = ProjectVersionStore(root: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ProjectVersions", isDirectory: true))

    private func folder(_ key: UUID) -> URL {
        root.appendingPathComponent(key.uuidString, isDirectory: true)
    }
    private func indexURL(_ key: UUID) -> URL { folder(key).appendingPathComponent("index.json") }
    private func archiveURL(_ key: UUID, _ number: Int) -> URL { folder(key).appendingPathComponent("\(number).os3d") }
    private func thumbnailURL(_ key: UUID, _ number: Int) -> URL { folder(key).appendingPathComponent("\(number).png") }

    /// The design's versions, newest first.
    func versions(_ key: UUID) -> [Version] {
        guard let data = try? Data(contentsOf: indexURL(key)),
              let list = try? JSONDecoder().decode([Version].self, from: data) else { return [] }
        return list.sorted { $0.number > $1.number }
    }

    /// A version as an archive, its thumbnail back in place.
    func archive(_ key: UUID, number: Int) -> ProjectArchive? {
        guard let data = try? Data(contentsOf: archiveURL(key, number)),
              var archive = ProjectArchive.decode(data) else { return nil }
        archive.thumbnail = thumbnail(key, number: number)
        return archive
    }

    func thumbnail(_ key: UUID, number: Int) -> Data? {
        try? Data(contentsOf: thumbnailURL(key, number))
    }

    /// Keep `archive` as the design's next version — unless it is the same
    /// as the latest one, byte for byte (its thumbnail aside). Returns the
    /// version written.
    @discardableResult
    func record(_ archive: ProjectArchive, key: UUID, note: String? = nil, now: Date = Date()) -> Version? {
        var bare = archive
        let thumbnail = bare.thumbnail
        bare.thumbnail = nil
        guard let data = bare.encoded() else { return nil }
        var list = versions(key)
        if note == nil, let latest = list.first,
           (try? Data(contentsOf: archiveURL(key, latest.number))) == data {
            return nil
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder(key), withIntermediateDirectories: true)
            let version = Version(number: (list.first?.number ?? 0) + 1, created: now, note: note,
                                  bodies: archive.bodies.count, bytes: data.count)
            try data.write(to: archiveURL(key, version.number), options: .atomic)
            if let thumbnail { try? thumbnail.write(to: thumbnailURL(key, version.number), options: .atomic) }
            list.insert(version, at: 0)
            for old in list.dropFirst(Self.limit) {
                try? fm.removeItem(at: archiveURL(key, old.number))
                try? fm.removeItem(at: thumbnailURL(key, old.number))
            }
            list = Array(list.prefix(Self.limit))
            try JSONEncoder().encode(list).write(to: indexURL(key), options: .atomic)
            return version
        } catch {
            return nil
        }
    }

    /// Forget every version of a deleted design.
    func removeAll(_ key: UUID?) {
        guard let key else { return }
        try? FileManager.default.removeItem(at: folder(key))
    }
}
