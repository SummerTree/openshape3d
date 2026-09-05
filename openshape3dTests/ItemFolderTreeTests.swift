//
//  ItemFolderTreeTests.swift
//  openshape3dTests
//
//  Pure Items-Manager folder logic (spec §11): membership moves, nesting
//  legality, remove-keeping-contents vs remove-subtree, pruning, naming,
//  and the undo command's before/after swap.
//

import XCTest
@testable import openshape3d

final class ItemFolderTreeTests: XCTestCase {

    private let bodyA = DocumentItemKey.body(BodyID(raw: UUID()))
    private let bodyB = DocumentItemKey.body(BodyID(raw: UUID()))
    private let sketch = DocumentItemKey.sketch(SketchID(raw: UUID()))
    private let plane = DocumentItemKey.plane(ConstructionPlaneID(raw: UUID()))

    private let outer = ItemFolderID()
    private let inner = ItemFolderID()
    private let other = ItemFolderID()

    /// outer{bodyA} ── inner{sketch}   other{bodyB}
    private var tree: ItemFolderTree {
        ItemFolderTree([
            ItemFolder(id: outer, name: "Folder 1", members: [bodyA]),
            ItemFolder(id: inner, name: "Folder 2", parentID: outer, members: [sketch]),
            ItemFolder(id: other, name: "Folder 3", members: [bodyB]),
        ])
    }

    func testStructureQueries() {
        XCTAssertEqual(tree.children(of: nil).map(\.id), [outer, other])
        XCTAssertEqual(tree.children(of: outer).map(\.id), [inner])
        XCTAssertEqual(tree.parent(of: inner), outer)
        XCTAssertNil(tree.parent(of: outer))
        XCTAssertEqual(tree.path(to: inner).map(\.name), ["Folder 1", "Folder 2"])
        XCTAssertEqual(tree.descendants(of: outer).map(\.id), [inner])
        XCTAssertEqual(tree.keys(inSubtree: outer), [bodyA, sketch])
        XCTAssertEqual(tree.folder(containing: sketch), inner)
        XCTAssertNil(tree.folder(containing: plane))
        XCTAssertEqual(tree.filedKeys, [bodyA, bodyB, sketch])
        XCTAssertEqual(tree.flattened().map(\.depth), [0, 1, 0])
        XCTAssertEqual(tree.uniqueName(), "Folder 4")
    }

    func testMoveLegality() {
        XCTAssertTrue(tree.canMove(folder: other, into: inner))
        XCTAssertTrue(tree.canMove(folder: inner, into: nil))
        XCTAssertFalse(tree.canMove(folder: outer, into: outer), "not into itself")
        XCTAssertFalse(tree.canMove(folder: outer, into: inner), "not into its own subtree")
        XCTAssertFalse(tree.canMove(folder: outer, into: ItemFolderID()), "not into a folder that does not exist")
        XCTAssertEqual(tree.reparenting(outer, to: inner), tree.folders, "an illegal move is a no-op")
        let moved = ItemFolderTree(tree.reparenting(other, to: inner))
        XCTAssertEqual(moved.path(to: other).map(\.name), ["Folder 1", "Folder 2", "Folder 3"])
    }

    func testMovingItemsBetweenFolders() {
        // An item is in at most one folder.
        var t = ItemFolderTree(tree.moving([bodyA, plane], to: other))
        XCTAssertEqual(t.folder(containing: bodyA), other)
        XCTAssertEqual(t.folder(containing: plane), other)
        XCTAssertEqual(t.folder(other)?.members, [bodyB, bodyA, plane])
        XCTAssertEqual(t.folder(outer)?.members, [])
        // Moving out of every folder.
        t = ItemFolderTree(t.moving([bodyB], to: nil))
        XCTAssertNil(t.folder(containing: bodyB))
        XCTAssertEqual(t.folder(other)?.members, [bodyA, plane])
        // Moving an item to where it already is keeps its place.
        XCTAssertEqual(t.moving([bodyA], to: other), t.folders)
        // An unknown destination changes nothing.
        XCTAssertEqual(t.moving([bodyA], to: ItemFolderID()), t.folders)
    }

    func testAddingDisplacesMembers() {
        let fresh = ItemFolder(name: "Selected", members: [bodyA, bodyB, bodyA])
        let t = ItemFolderTree(tree.adding(fresh))
        XCTAssertEqual(t.folder(fresh.id)?.members, [bodyA, bodyB], "deduplicated")
        XCTAssertEqual(t.folder(outer)?.members, [], "bodyA left Folder 1")
        XCTAssertEqual(t.folder(other)?.members, [], "bodyB left Folder 3")
        // A parent that does not exist reads as top level.
        let orphan = ItemFolder(name: "Orphan", parentID: ItemFolderID())
        XCTAssertNil(ItemFolderTree(tree.adding(orphan)).folder(orphan.id)?.parentID)
    }

    func testRemoveKeepingContentsLiftsItemsAndChildren() {
        let t = ItemFolderTree(tree.removingKeepingContents(outer))
        XCTAssertNil(t.folder(outer))
        XCTAssertNil(t.parent(of: inner), "the child folder moves up to the top level")
        XCTAssertNil(t.folder(containing: bodyA), "a top-level folder's items go back to the sections")
        XCTAssertEqual(t.folder(inner)?.members, [sketch], "the child keeps its own items")

        // Removing the nested one: its items join the parent.
        let t2 = ItemFolderTree(tree.removingKeepingContents(inner))
        XCTAssertEqual(t2.folder(outer)?.members, [bodyA, sketch])
    }

    func testRemoveSubtree() {
        let t = ItemFolderTree(tree.removingSubtree(outer))
        XCTAssertEqual(t.folders.map(\.id), [other])
    }

    func testPrunedDropsMissingItems() {
        let t = ItemFolderTree(tree.pruned(to: [bodyA, plane]))
        XCTAssertEqual(t.folder(outer)?.members, [bodyA])
        XCTAssertEqual(t.folder(inner)?.members, [])
        XCTAssertEqual(t.folder(other)?.members, [])
        XCTAssertEqual(t.folders.count, 3, "empty folders survive pruning")
    }

    func testRenamingAndCommand() {
        let renamed = tree.renaming(inner, to: "Fasteners")
        XCTAssertEqual(ItemFolderTree(renamed).folder(inner)?.name, "Fasteners")
        var document = DesignDocument()
        document.itemFolders = tree.folders
        let command = SetItemFoldersCommand(title: "Rename Folder", before: tree.folders, after: renamed)
        command.apply(to: &document)
        XCTAssertEqual(document.itemFolders, renamed)
        command.revert(in: &document)
        XCTAssertEqual(document.itemFolders, tree.folders)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(tree.folders)
        let decoded = try JSONDecoder().decode([ItemFolder].self, from: data)
        XCTAssertEqual(decoded, tree.folders)
        // The archive remap rewrites UUID strings inside JSON; the encoding
        // must therefore spell IDs as plain uuidStrings.
        let text = String(decoding: data, as: UTF8.self)
        if case .body(let id) = bodyA {
            XCTAssertTrue(text.contains(id.raw.uuidString))
        }
    }
}
