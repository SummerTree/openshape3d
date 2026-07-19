//
//  ImageSymbolTests.swift
//  openshape3dTests
//
//  Phase B10/B16 model half: Insert Image data model (commands + SwiftData
//  round-trip) and Symbol capture/instantiate.
//

import XCTest
import SwiftData
import simd
@testable import openshape3d

final class ImageSymbolTests: XCTestCase {

    private func makeImage(name: String = "Image 1") -> InsertedImage {
        InsertedImage(
            name: name,
            plane: .ground,
            width: 100,
            height: 60,
            opacity: 0.75,
            imageData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        )
    }

    // MARK: - Image commands

    func testAddImageCommandAppliesAndReverts() {
        var document = DesignDocument()
        let image = makeImage()
        let command = AddImageCommand(image: image)

        command.apply(to: &document)
        XCTAssertEqual(document.images, [image])

        command.revert(in: &document)
        XCTAssertTrue(document.images.isEmpty)
    }

    func testUpdateImageCommandRoundTrips() {
        var document = DesignDocument()
        let before = makeImage()
        document.images.append(before)

        var after = before
        after.width = 200
        after.height = 120
        after.opacity = 0.25
        after.plane.origin = SIMD3(5, 0, 3)

        let command = UpdateImageCommand(before: before, after: after)
        command.apply(to: &document)
        XCTAssertEqual(document.images, [after])

        command.revert(in: &document)
        XCTAssertEqual(document.images, [before])
    }

    func testRemoveImageCommandRestoresOrdering() {
        var document = DesignDocument()
        let first = makeImage(name: "Image 1")
        let second = makeImage(name: "Image 2")
        document.images = [first, second]

        guard let command = RemoveImageCommand(id: first.id, document: document) else {
            return XCTFail("Command should resolve the image")
        }
        command.apply(to: &document)
        XCTAssertEqual(document.images.map(\.name), ["Image 2"])

        command.revert(in: &document)
        XCTAssertEqual(document.images.map(\.name), ["Image 1", "Image 2"])
        XCTAssertEqual(document.images[0].id, first.id)
    }

    func testVisibilityAndRenameExtendToImages() {
        var document = DesignDocument()
        let image = makeImage()
        document.images.append(image)

        let hide = SetItemVisibilityCommand(imageID: image.id, isHidden: true)
        hide.apply(to: &document)
        XCTAssertTrue(document.images[0].isHidden)
        hide.revert(in: &document)
        XCTAssertFalse(document.images[0].isHidden)

        let rename = RenameItemCommand(imageID: image.id, before: "Image 1", after: "Blueprint")
        rename.apply(to: &document)
        XCTAssertEqual(document.images[0].name, "Blueprint")
        rename.revert(in: &document)
        XCTAssertEqual(document.images[0].name, "Image 1")
    }

    func testOpacityClampsAndUniqueImageNameNumbersFromOne() {
        var document = DesignDocument()
        XCTAssertEqual(document.uniqueImageName(), "Image 1")
        document.images.append(makeImage(name: "Image 1"))
        XCTAssertEqual(document.uniqueImageName(), "Image 2")

        let over = InsertedImage(plane: .ground, width: 1, height: 1, opacity: 3, imageData: Data())
        XCTAssertEqual(over.opacity, 1)
        let under = InsertedImage(plane: .ground, width: 1, height: 1, opacity: -1, imageData: Data())
        XCTAssertEqual(under.opacity, 0)
    }

    // MARK: - Insert flow helpers (plan §B10 UI)

    func testInsertedImageSizePreservesAspectAtMaxDimension() {
        let landscape = EditorViewModel.insertedImageSize(pixelWidth: 400, pixelHeight: 300)
        XCTAssertEqual(landscape.width, 50, accuracy: 1e-9)
        XCTAssertEqual(landscape.height, 37.5, accuracy: 1e-9)

        let portrait = EditorViewModel.insertedImageSize(pixelWidth: 100, pixelHeight: 200)
        XCTAssertEqual(portrait.width, 25, accuracy: 1e-9)
        XCTAssertEqual(portrait.height, 50, accuracy: 1e-9)

        // Degenerate pixel sizes fall back to a square at the max dimension.
        let broken = EditorViewModel.insertedImageSize(pixelWidth: 0, pixelHeight: 0)
        XCTAssertEqual(broken.width, 50)
        XCTAssertEqual(broken.height, 50)

        // Resizing via the Size field re-derives from the same helper.
        let resized = EditorViewModel.insertedImageSize(
            pixelWidth: 50, pixelHeight: 37.5, maxDimension: 80
        )
        XCTAssertEqual(resized.width, 80, accuracy: 1e-9)
        XCTAssertEqual(resized.height, 60, accuracy: 1e-9)
    }

    func testDebugSeedImagePNGDecodes() throws {
        let size = try XCTUnwrap(
            EditorViewModel.imagePixelSize(of: EditorViewModel.debugSeedImagePNG),
            "The embedded seed PNG must stay ImageIO-decodable"
        )
        XCTAssertEqual(size.width, 32)
        XCTAssertEqual(size.height, 24)
        XCTAssertNil(EditorViewModel.imagePixelSize(of: Data([0x00, 0x01, 0x02])))
    }

    func testImageBoundsSpanTheQuadOnItsPlane() {
        var image = makeImage() // 100 × 60 on the ground plane
        image.plane.origin = SIMD3(10, 0, -4)
        let bounds = EditorViewModel.imageBounds(image)
        // Ground plane: xAxis (1,0,0), yAxis (0,0,-1) → X spans ±50, Z ±30.
        XCTAssertEqual(bounds.min.x, -40, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.x, 60, accuracy: 1e-4)
        XCTAssertEqual(bounds.min.z, -34, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.z, 26, accuracy: 1e-4)
        XCTAssertEqual(bounds.min.y, 0, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.y, 0, accuracy: 1e-4)
    }

    // MARK: - Backward compatibility

    func testInsertedImageDecodesWithoutOptionalFields() throws {
        let image = makeImage()
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(image)
        ) as! [String: Any]
        json.removeValue(forKey: "name")
        json.removeValue(forKey: "opacity")
        json.removeValue(forKey: "isHidden")
        json.removeValue(forKey: "imageData")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(InsertedImage.self, from: data)
        XCTAssertEqual(decoded.id, image.id)
        XCTAssertEqual(decoded.name, "Image")
        XCTAssertEqual(decoded.opacity, 1)
        XCTAssertFalse(decoded.isHidden)
        XCTAssertEqual(decoded.imageData, Data())
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    func testSymbolDecodesWithoutName() throws {
        let symbol = SymbolKit.capture(name: "Bolt", entities: [
            .circle(id: UUID(), center: SIMD2(3, 4), radius: 1),
        ])
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(symbol)
        ) as! [String: Any]
        json.removeValue(forKey: "name")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Symbol.self, from: data)
        XCTAssertEqual(decoded.id, symbol.id)
        XCTAssertEqual(decoded.name, "Symbol")
        XCTAssertEqual(decoded.entities, symbol.entities)
    }

    // MARK: - Symbol capture / instantiate

    func testCaptureNormalizesCentroidToOrigin() {
        let entities: [SketchEntity] = [
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(2, 0)),
            .circle(id: UUID(), center: SIMD2(4, 2), radius: 1),
        ]
        // Anchors: line midpoint (1, 0), circle center (4, 2) → centroid (2.5, 1).
        XCTAssertEqual(SymbolKit.centroid(of: entities), SIMD2(2.5, 1))

        let symbol = SymbolKit.capture(name: "Pair", entities: entities)
        XCTAssertEqual(symbol.name, "Pair")
        XCTAssertEqual(symbol.entities.count, 2)
        let centroid = SymbolKit.centroid(of: symbol.entities)
        XCTAssertEqual(centroid.x, 0, accuracy: 1e-12)
        XCTAssertEqual(centroid.y, 0, accuracy: 1e-12)
        // Capture remints IDs so the symbol never aliases live entities.
        let sourceIDs = Set(entities.map(\.id))
        XCTAssertTrue(sourceIDs.isDisjoint(with: symbol.entities.map(\.id)))
    }

    func testInstantiateTwiceProducesFreshIDsAtPoint() {
        let symbol = SymbolKit.capture(name: "Pair", entities: [
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(2, 0)),
            .circle(id: UUID(), center: SIMD2(4, 2), radius: 1),
        ])

        let target = SIMD2<Double>(10, 5)
        let first = SymbolKit.instantiate(symbol, at: target)
        let second = SymbolKit.instantiate(symbol, at: target)

        for placed in [first, second] {
            XCTAssertEqual(placed.count, 2)
            let centroid = SymbolKit.centroid(of: placed)
            XCTAssertEqual(centroid.x, target.x, accuracy: 1e-12)
            XCTAssertEqual(centroid.y, target.y, accuracy: 1e-12)
        }

        // No collisions: symbol vs instance, instance vs instance.
        let symbolIDs = Set(symbol.entities.map(\.id))
        let firstIDs = Set(first.map(\.id))
        let secondIDs = Set(second.map(\.id))
        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertEqual(secondIDs.count, 2)
        XCTAssertTrue(symbolIDs.isDisjoint(with: firstIDs))
        XCTAssertTrue(symbolIDs.isDisjoint(with: secondIDs))
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs))
    }

    func testInstantiateAppliesRotationAboutSymbolOrigin() throws {
        let symbol = Symbol(name: "Bar", entities: [
            .line(id: UUID(), a: SIMD2(-1, 0), b: SIMD2(1, 0)),
        ])
        let placed = SymbolKit.instantiate(symbol, at: SIMD2(3, 3), rotation: .pi / 2)
        guard case let .line(_, a, b) = try XCTUnwrap(placed.first) else {
            return XCTFail("Expected a line")
        }
        XCTAssertEqual(a.x, 3, accuracy: 1e-12)
        XCTAssertEqual(a.y, 2, accuracy: 1e-12)
        XCTAssertEqual(b.x, 3, accuracy: 1e-12)
        XCTAssertEqual(b.y, 4, accuracy: 1e-12)
    }

    // MARK: - Symbol commands

    func testAddAndRemoveSymbolCommandsRoundTrip() {
        var document = DesignDocument()
        let symbol = SymbolKit.capture(name: "Symbol 1", entities: [
            .circle(id: UUID(), center: SIMD2(1, 1), radius: 2),
        ])

        let add = AddSymbolCommand(symbol: symbol)
        add.apply(to: &document)
        XCTAssertEqual(document.symbols, [symbol])
        XCTAssertEqual(document.uniqueSymbolName(), "Symbol 2")

        guard let remove = RemoveSymbolCommand(id: symbol.id, document: document) else {
            return XCTFail("Command should resolve the symbol")
        }
        remove.apply(to: &document)
        XCTAssertTrue(document.symbols.isEmpty)
        remove.revert(in: &document)
        XCTAssertEqual(document.symbols, [symbol])
    }

    // MARK: - Persistence round-trip

    @MainActor
    private func makeInMemorySession() throws -> (DocumentSession, Project, ModelContext) {
        let schema = Schema([
            Project.self,
            PersistedBody.self,
            PersistedSketch.self,
            PersistedPlane.self,
            PersistedImage.self,
            PersistedSymbol.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let project = Project(name: "Test")
        context.insert(project)
        let session = DocumentSession(project: project, modelContext: context)
        return (session, project, context)
    }

    @MainActor
    func testImageAndSymbolPersistenceRoundTrip() async throws {
        let (session, project, context) = try makeInMemorySession()

        var image = makeImage()
        image.isHidden = true
        let symbol = SymbolKit.capture(name: "Bolt", entities: [
            .circle(id: UUID(), center: SIMD2(2, 3), radius: 1),
            .polygon(id: UUID(), center: SIMD2(2, 3), radius: 2, sides: 6, rotation: 0.1),
        ])
        session.perform(AddImageCommand(image: image))
        session.perform(AddSymbolCommand(symbol: symbol))
        session.save()

        // The blob lands in the externalStorage column, not the JSON info.
        XCTAssertEqual(project.images.count, 1)
        XCTAssertEqual(project.images[0].imageData, image.imageData)
        let info = try JSONDecoder().decode(InsertedImage.self, from: project.images[0].infoData)
        XCTAssertEqual(info.imageData, Data())

        // A fresh session over the same store reloads both, blob reattached.
        let reloaded = DocumentSession(project: project, modelContext: context)
        XCTAssertEqual(reloaded.document.images, [image])
        XCTAssertEqual(reloaded.document.symbols, [symbol])
    }

    @MainActor
    func testImageRemovalDeletesPersistedRow() async throws {
        let (session, project, _) = try makeInMemorySession()
        let image = makeImage()
        session.perform(AddImageCommand(image: image))
        session.save()
        XCTAssertEqual(project.images.count, 1)

        guard let remove = RemoveImageCommand(id: image.id, document: session.document) else {
            return XCTFail("Command should resolve the image")
        }
        session.perform(remove)
        session.save()
        XCTAssertTrue(project.images.isEmpty)
    }

    @MainActor
    func testProjectWithoutImagesOrSymbolsLoads() async throws {
        // Pre-B10 store: only a sketch row, no image/symbol rows.
        let (_, project, context) = try makeInMemorySession()
        let sketch = Sketch(name: "Sketch 1", plane: .ground, entities: [
            .circle(id: UUID(), center: .zero, radius: 1),
        ])
        let persisted = PersistedSketch(
            sketchID: sketch.id.raw,
            sketchData: try JSONEncoder().encode(sketch)
        )
        persisted.project = project
        context.insert(persisted)

        let session = DocumentSession(project: project, modelContext: context)
        XCTAssertEqual(session.document.sketches, [sketch])
        XCTAssertTrue(session.document.images.isEmpty)
        XCTAssertTrue(session.document.symbols.isEmpty)
    }
}
