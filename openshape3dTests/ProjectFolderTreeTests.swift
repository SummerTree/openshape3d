//
//  ProjectFolderTreeTests.swift
//  openshape3dTests
//
//  Pure folder-tree and navigation-history logic behind the gallery's
//  folders (spec §13.1). No SwiftData here on purpose (gotcha 1).
//

import XCTest
@testable import openshape3d

final class ProjectFolderTreeTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    /// root ── Alpha(a) ── Beta(b) ── Gamma(c)
    ///      └─ Delta(d)
    private var tree: ProjectFolderTree {
        ProjectFolderTree([
            FolderNode(id: a, name: "Alpha"),
            FolderNode(id: b, name: "Beta", parentID: a),
            FolderNode(id: c, name: "Gamma", parentID: b),
            FolderNode(id: d, name: "Delta"),
        ])
    }

    func testChildrenAreSortedByNameNumericAware() {
        let x = UUID(), y = UUID(), z = UUID()
        let t = ProjectFolderTree([
            FolderNode(id: x, name: "Part 10"),
            FolderNode(id: y, name: "Part 2"),
            FolderNode(id: z, name: "Assembly"),
        ])
        XCTAssertEqual(t.children(of: nil).map(\.name), ["Assembly", "Part 2", "Part 10"])
        XCTAssertEqual(tree.children(of: nil).map(\.name), ["Alpha", "Delta"])
        XCTAssertEqual(tree.children(of: a).map(\.id), [b])
        XCTAssertEqual(tree.children(of: c), [])
    }

    func testPathAndParent() {
        XCTAssertEqual(tree.path(to: nil), [])
        XCTAssertEqual(tree.path(to: c).map(\.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(tree.parent(of: c), b)
        XCTAssertNil(tree.parent(of: a))
        XCTAssertNil(tree.parent(of: nil))
        XCTAssertTrue(tree.exists(nil))
        XCTAssertTrue(tree.exists(b))
        XCTAssertFalse(tree.exists(UUID()))
        XCTAssertEqual(tree.path(to: UUID()), [], "an unknown ID has no path")
    }

    func testDescendantsAndMoveLegality() {
        XCTAssertEqual(tree.descendants(of: a).map(\.name), ["Beta", "Gamma"])
        XCTAssertEqual(tree.descendants(of: d), [])
        XCTAssertTrue(tree.isSelfOrDescendant(a, of: a))
        XCTAssertTrue(tree.isSelfOrDescendant(c, of: a))
        XCTAssertFalse(tree.isSelfOrDescendant(d, of: a))
        XCTAssertFalse(tree.isSelfOrDescendant(nil, of: a))

        XCTAssertTrue(tree.canMove(folder: a, into: d))
        XCTAssertTrue(tree.canMove(folder: c, into: nil))
        XCTAssertFalse(tree.canMove(folder: a, into: a), "not into itself")
        XCTAssertFalse(tree.canMove(folder: a, into: c), "not into its own subtree")
        XCTAssertFalse(tree.canMove(folder: a, into: UUID()), "not into a folder that does not exist")
        XCTAssertFalse(tree.canMove(folder: UUID(), into: nil), "an unknown folder cannot move")
    }

    func testOrphanAndCycleReadAsRoot() {
        let orphan = UUID(), loopA = UUID(), loopB = UUID()
        let t = ProjectFolderTree([
            FolderNode(id: orphan, name: "Orphan", parentID: UUID()),
            FolderNode(id: loopA, name: "LoopA", parentID: loopB),
            FolderNode(id: loopB, name: "LoopB", parentID: loopA),
        ])
        XCTAssertEqual(Set(t.children(of: nil).map(\.id)), [orphan],
                       "a folder whose parent is missing lists at the root")
        XCTAssertNil(t.parent(of: orphan))
        // A two-node cycle: each is the other's child, neither is at the root,
        // but path/descendants/flattened all terminate.
        XCTAssertLessThanOrEqual(t.path(to: loopA).count, 2)
        XCTAssertLessThanOrEqual(t.descendants(of: loopA).count, 2)
        _ = t.flattened()
    }

    func testFlattenedRespectsExpansion() {
        let all = tree.flattened()
        XCTAssertEqual(all.map(\.node.name), ["Alpha", "Beta", "Gamma", "Delta"])
        XCTAssertEqual(all.map(\.depth), [0, 1, 2, 0])
        let collapsed = tree.flattened(expanded: [])
        XCTAssertEqual(collapsed.map(\.node.name), ["Alpha", "Delta"])
        let partial = tree.flattened(expanded: [a])
        XCTAssertEqual(partial.map(\.node.name), ["Alpha", "Beta", "Delta"])
    }

    func testUniqueName() {
        XCTAssertEqual(ProjectFolderTree.uniqueName(base: "Untitled Folder", among: []),
                       "Untitled Folder")
        XCTAssertEqual(ProjectFolderTree.uniqueName(base: "Untitled Folder",
                                                    among: ["Untitled Folder"]),
                       "Untitled Folder 2")
        XCTAssertEqual(ProjectFolderTree.uniqueName(
            base: "Untitled Folder", among: ["Untitled Folder", "Untitled Folder 2"]),
            "Untitled Folder 3")
    }

    // MARK: History

    func testHistoryBackForward() {
        var h = FolderNavigationHistory()
        XCTAssertNil(h.current)
        XCTAssertFalse(h.canGoBack)
        h.go(to: a)
        h.go(to: b)
        XCTAssertEqual(h.current, b)
        XCTAssertTrue(h.canGoBack)
        XCTAssertFalse(h.canGoForward)
        h.goBack()
        XCTAssertEqual(h.current, a)
        XCTAssertTrue(h.canGoForward)
        h.goBack()
        XCTAssertNil(h.current)
        XCTAssertFalse(h.canGoBack)
        h.goForward()
        XCTAssertEqual(h.current, a)
        h.go(to: d)
        XCTAssertEqual(h.current, d)
        XCTAssertFalse(h.canGoForward, "navigating somewhere new clears Forward")
        h.go(to: d)
        h.goBack()
        XCTAssertEqual(h.current, a, "re-selecting the current folder adds no history entry")
    }

    func testHistoryDropsDeletedFolders() {
        var h = FolderNavigationHistory()
        h.go(to: a)   // back: [root]
        h.go(to: b)   // back: [root, a]
        h.go(to: c)   // back: [root, a, b]
        h.goBack()    // current b, forward: [c]
        // Delete Beta's subtree (b, c) while standing in Beta: land on Alpha.
        h.removing([b, c], fallback: a)
        XCTAssertEqual(h.current, a)
        XCTAssertFalse(h.canGoForward, "Forward pointed at a deleted folder")
        XCTAssertEqual(h.backStack, [nil], "Alpha collapsed out of Back — we are already there")
        h.goBack()
        XCTAssertNil(h.current)
    }
}
