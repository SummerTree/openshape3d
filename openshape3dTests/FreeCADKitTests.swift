//
//  FreeCADKitTests.swift
//  openshape3dTests
//
//  FreeCAD documents (.FCStd): the small XML reader; an export that reads
//  back exact (a cylinder stays a cylinder), named, coloured and placed, its
//  zip entries in the order FreeCAD reads them; a FreeCAD-1.x-style
//  document — hidden inputs, an App::Part's placement, a PartDesign Body
//  standing for its features, ShapeAppearance and ShapeColor colours;
//  things that are not FreeCAD refused. With OS3D_FCSTD_SAMPLES set to a
//  folder of real FreeCAD documents (TEST_RUNNER_OS3D_FCSTD_SAMPLES on the
//  xcodebuild line), each must import.
//

import XCTest
import SwiftData
import simd
@testable import openshape3d

@MainActor
final class FreeCADKitTests: XCTestCase {

    private static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([Project.self, PersistedBody.self, PersistedSketch.self,
                             PersistedPlane.self, PersistedImage.self, PersistedSymbol.self])
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let project = Project(name: "FreeCAD import")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    /// The zip's entry names in file order (local headers, front to back).
    private func entryNames(_ data: Data) -> [String] {
        let b = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var names: [String] = [], at = 0
        while at + 30 <= b.count, u32(at) == 0x04034b50 {
            let n = u16(at + 26), extra = u16(at + 28), size = u32(at + 18)
            names.append(String(decoding: b[at + 30..<at + 30 + n], as: UTF8.self))
            at += 30 + n + extra + size
        }
        return names
    }

    // MARK: MiniXML

    func testMiniXMLReadsElementsAttributesAndEntities() throws {
        let xml = """
        <?xml version='1.0' encoding='utf-8'?>
        <!-- a comment with <tags> -->
        <Document a="1" b='two &amp; &lt;3&gt; &#65;&#x42;'>
            <Empty/>
            <Item name="x"><Child value="y"/></Item>
            <![CDATA[ <not> an element ]]>
            text is ignored
        </Document>
        """
        let root = try XCTUnwrap(MiniXML.parse(Data(xml.utf8)))
        XCTAssertEqual(root.name, "Document")
        XCTAssertEqual(root["a"], "1")
        XCTAssertEqual(root["b"], "two & <3> AB")
        XCTAssertEqual(root.children.map(\.name), ["Empty", "Item"])
        XCTAssertEqual(root.first("Item")?.first("Child")?["value"], "y")
        XCTAssertEqual(root.descendants("Child").count, 1)

        XCTAssertNil(MiniXML.parse(Data("<a><b></a></b>".utf8)), "tags that do not nest")
        XCTAssertNil(MiniXML.parse(Data("<a>".utf8)), "unclosed")
        XCTAssertNil(MiniXML.parse(Data("<a/><b/>".utf8)), "two roots")
        XCTAssertNil(MiniXML.parse(Data("<a b=c/>".utf8)), "unquoted attribute")
        XCTAssertNil(MiniXML.parse(Data(String(repeating: "<a>", count: 300).utf8)), "too deep")
        XCTAssertEqual(MiniXML.decoded("a &unknown; b &amp"), "a &unknown; b &amp")
    }

    // MARK: Round trip

    private func cylinder() throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(.cylinder(radius: 5, height: 20), placement: .identity))
    }

    private func body(_ name: String, _ handle: BRepHandle) throws -> Body {
        try XCTUnwrap(STEPKit.body(from: handle, name: name, revision: 1))
    }

    func testExportReadsBackExactNamedColouredAndPlaced() throws {
        var wheel = try body("Wheel & Axle", try cylinder())
        wheel.transform.translation = SIMD3(100, 0, 0)
        wheel.material = BodyMaterialSpec(baseColor: SIMD4(0.8, 0.2, 0.1, 0.5))
        var hidden = try body("Spare", try cylinder())
        hidden.isHidden = true
        var mesh = try body("Scan", try cylinder())
        mesh.brep = nil

        guard case let .success(data, skipped) = FreeCADKit.export(bodies: [wheel, hidden, mesh], documentLabel: "Cart")
        else { return XCTFail("export failed") }
        XCTAssertEqual(skipped, ["Scan"], "a mesh-only body has no B-rep to write")

        // The order FreeCAD reads entries in.
        let names = entryNames(data)
        XCTAssertEqual(names, ["Document.xml", "PartShape.brp", "PartShape1.brp",
                               "GuiDocument.xml", "ShapeAppearance", "ShapeAppearance1"])

        let contents = try FreeCADKit.parts(from: data)
        XCTAssertEqual(contents.parts.map(\.label), ["Wheel & Axle"], "the hidden body stays hidden")
        let part = try XCTUnwrap(contents.parts.first)
        XCTAssertEqual(part.placement, .identity, "the placement is baked into the shape")
        let color = try XCTUnwrap(part.color)
        XCTAssertEqual(color.x, 0.8, accuracy: 0.01)
        XCTAssertEqual(color.y, 0.2, accuracy: 0.01)
        XCTAssertEqual(color.w, 0.5, accuracy: 0.01)

        let back = try XCTUnwrap(OCCTKernel.deserialize(part.brep))
        XCTAssertEqual(OCCTKernel.faceTypeCounts(back).cylindrical, 1, "still a cylinder")
        XCTAssertEqual(OCCTKernel.volume(back), .pi * 25 * 20, accuracy: 1e-6)
        let mesh2 = OCCTKernel.renderMesh(from: back)
        let minX = mesh2.positions.map(\.x).min() ?? 0
        XCTAssertEqual(Double(minX), 95, accuracy: 1e-3, "moved where the body was")

        // Nothing analytic: nothing to write.
        XCTAssertEqual(FreeCADKit.export(bodies: [mesh], documentLabel: "x"), .nothingAnalytic(skipped: ["Scan"]))
    }

    func testDocumentXMLIsWhatFreeCADReads() throws {
        guard case let .success(data, _) = FreeCADKit.export(bodies: [try body("A <b>", try cylinder())],
                                                             documentLabel: "Doc")
        else { return XCTFail("export failed") }
        let entries = try ZipReader.entries(in: data)
        let doc = try XCTUnwrap(MiniXML.parse(try XCTUnwrap(entries["Document.xml"])))
        XCTAssertEqual(doc["SchemaVersion"], "4")
        XCTAssertEqual(doc.first("Objects")?.first("Object")?["type"], "Part::Feature")
        let props = try XCTUnwrap(doc.first("ObjectData")?.first("Object")?.first("Properties"))
        XCTAssertEqual(props["Count"], "\(props.all("Property").count)")
        XCTAssertEqual(props.all("Property").first { $0["name"] == "Label" }?.first("String")?["value"], "A <b>")
        let gui = try XCTUnwrap(MiniXML.parse(try XCTUnwrap(entries["GuiDocument.xml"])))
        XCTAssertNotNil(gui.first("Camera"))
        let provider = try XCTUnwrap(gui.first("ViewProviderData")?.first("ViewProvider"))
        XCTAssertEqual(provider.first("Properties")?["Count"], "\(provider.first("Properties")?.all("Property").count ?? 0)")
        // Opaque grey: transparency byte 0 (pre-1.1 meaning, as declared).
        XCTAssertEqual(FreeCADKit.packedColor(SIMD4(0.8, 0.8, 0.8, 1)), 0xCCCC_CC00)
        XCTAssertEqual(try XCTUnwrap(entries["ShapeAppearance"]).count, 40)
    }

    // MARK: FreeCAD's own documents

    /// A document laid out as FreeCAD 1.x saves one: a Cut of a hidden box
    /// and cylinder, a PartDesign Body with a visible feature inside, an
    /// App::Part moved 50 mm holding a box, a sketch (wires only), a hidden
    /// App::Part's box, and a shape saved in binary.
    private func freeCADDocument() throws -> Data {
        let brep = try XCTUnwrap(OCCTKernel.serialize(try cylinder()))
        func object(_ name: String, label: String, file: String?, visible: Bool = true, group: [String] = [],
                    placement: String = #"Px="0" Py="0" Pz="0" Q0="0" Q1="0" Q2="0" Q3="1""#) -> String {
            var props = """
            <Property name="Label" type="App::PropertyString" status="134217728"><String value="\(label)"/></Property>
            <Property name="Placement" type="App::PropertyPlacement"><PropertyPlacement \(placement) A="0" Ox="0" Oy="0" Oz="1"/></Property>
            <Property name="Visibility" type="App::PropertyBool" status="648"><Bool value="\(visible)"/></Property>
            """
            if let file {
                props += #"<Property name="Shape" type="Part::PropertyPartShape"><Part ElementMap="15.70200.5" file="\#(file)"/></Property>"#
            }
            if !group.isEmpty {
                props += #"<Property name="Group" type="App::PropertyLinkList"><LinkList count="\#(group.count)">"#
                    + group.map { #"<Link value="\#($0)"/>"# }.joined() + "</LinkList></Property>"
            }
            return #"<Object name="\#(name)" Extensions="True"><Extensions Count="0"></Extensions><Properties Count="9" TransientCount="0">\#(props)</Properties></Object>"#
        }
        let objects: [(type: String, xml: String)] = [
            ("Part::Box", object("Box", label: "Box", file: "Box.Shape.brp", visible: false)),
            ("Part::Cylinder", object("Cylinder", label: "Cylinder", file: "Cylinder.Shape.brp", visible: false)),
            ("Part::Cut", object("Cut", label: "Engine &amp; Block", file: "Cut.Shape.brp")),
            ("PartDesign::Body", object("Body", label: "Body", file: "Body.Shape.brp", group: ["Pad"])),
            ("PartDesign::Pad", object("Pad", label: "Pad", file: "Pad.Shape.brp")),
            ("App::Part", object("Part", label: "Part", file: nil, group: ["Box001"],
                                 placement: #"Px="50" Py="0" Pz="0" Q0="0" Q1="0" Q2="0.7071067811865476" Q3="0.7071067811865476""#)),
            ("Part::Box", object("Box001", label: "Lid", file: "Box001.Shape.brp")),
            ("Sketcher::SketchObject", object("Sketch", label: "Sketch", file: "Sketch.Shape.brp")),
            ("App::Part", object("Hidden", label: "Hidden", file: nil, visible: false, group: ["Box002"])),
            ("Part::Box", object("Box002", label: "Inside hidden", file: "Box002.Shape.brp")),
            ("Part::Feature", object("Binary", label: "Binary", file: "Binary.Shape.bin")),
        ]
        let document = """
        <?xml version='1.0' encoding='utf-8'?>
        <!--
         FreeCAD Document, see https://www.freecad.org for more information...
        -->
        <Document SchemaVersion="4" ProgramVersion="26.3R48259 (Git)" FileVersion="1" StringHasher="1">
            <StringHasher saveall="0" threshold="0" count="0" new="1"/>
            <Properties Count="1" TransientCount="1">
                <_Property name="FileName" type="App::PropertyString" status="50331649"/>
                <Property name="Label" type="App::PropertyString"><String value="EngineBlock"/></Property>
            </Properties>
            <Objects Count="\(objects.count)" Dependencies="1">
                <ObjectDeps Name="Cut" Count="2"><Dep Name="Box"/><Dep Name="Cylinder"/></ObjectDeps>
                \(objects.map { #"<Object type="\#($0.type)" name="\#(MiniXML.parse(Data($0.xml.utf8))!["name"]!)" id="1"/>"# }.joined())
            </Objects>
            <ObjectData Count="\(objects.count)">\(objects.map(\.xml).joined())</ObjectData>
        </Document>
        """
        // Cut: ShapeAppearance red (1.x); Lid: ShapeColor green, 25% transparent (pre-1.x).
        var appearance = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { appearance.append(contentsOf: $0) } }
        u32(1); u32(0x333333FF); u32(0xFF0000FF); u32(0x000000FF); u32(0x000000FF)
        u32(Float(0.2).bitPattern); u32(Float(0).bitPattern); u32(0); u32(0); u32(0)
        let gui = """
        <?xml version='1.0' encoding='utf-8'?>
        <Document SchemaVersion="1" HasExpansion="1">
            <ViewProviderData Count="2">
                <ViewProvider name="Cut" expanded="0" treeRank="-1" Extensions="True"><Properties Count="1" TransientCount="0">
                    <Property name="ShapeAppearance" type="App::PropertyMaterialList" status="1"><MaterialList file="ShapeAppearance" version="3"/></Property>
                </Properties></ViewProvider>
                <ViewProvider name="Box001" expanded="0"><Properties Count="2" TransientCount="0">
                    <Property name="ShapeColor" type="App::PropertyColor"><PropertyColor value="16711680"/></Property>
                    <Property name="Transparency" type="App::PropertyPercent"><Integer value="25"/></Property>
                </Properties></ViewProvider>
            </ViewProviderData>
            <Camera settings=""/>
        </Document>
        """
        var zip = MinimalZipWriter()
        zip.addFile(path: "Document.xml", data: Data(document.utf8))
        for file in ["Box", "Cylinder", "Cut", "Body", "Pad", "Box001", "Box002"] {
            zip.addFile(path: "\(file).Shape.brp", data: brep)
        }
        zip.addFile(path: "Sketch.Shape.brp", data: Data("DBRep_DrawableShape\n\nCASCADE Topology V1, (c) Matra-Datavision\nLocations 0\nCurve2ds 0\nCurves 0\nPolygon3D 0\nPolygonOnTriangulations 0\nSurfaces 0\nTriangulations 0\n\nTShapes 0\n\n+0 0 \n0\n".utf8))
        zip.addFile(path: "Binary.Shape.bin", data: Data([1, 2, 3]))
        zip.addFile(path: "GuiDocument.xml", data: Data(gui.utf8))
        zip.addFile(path: "ShapeAppearance", data: appearance)
        return zip.finish()
    }

    func testFreeCADDocumentsImportTheirVisibleShapes() throws {
        let contents = try FreeCADKit.parts(from: try freeCADDocument())
        XCTAssertEqual(contents.parts.map(\.label), ["Engine & Block", "Body", "Lid", "Sketch"],
                       "hidden inputs, a Body's features and a hidden Part's contents are left out")
        XCTAssertEqual(contents.skipped, 1, "the binary shape")

        let cut = contents.parts[0]
        XCTAssertEqual(cut.color, SIMD4(1, 0, 0, 1), "ShapeAppearance's diffuse")
        let lid = contents.parts[2]
        let lidColor = try XCTUnwrap(lid.color)
        XCTAssertEqual(lidColor.y, 1, accuracy: 1e-9, "ShapeColor 0x00FF0000 is green")
        XCTAssertEqual(lidColor.w, 0.75, accuracy: 1e-9)
        XCTAssertEqual(lid.placement.translation, SIMD3(50, 0, 0), "the App::Part's placement")
        XCTAssertEqual(lid.placement.rotation.angle, .pi / 2, accuracy: 1e-9)
        XCTAssertNil(contents.parts[1].color)
    }

    func testImportMakesExactBodiesInOneUndoStep() throws {
        let vm = try makeViewModel()
        vm.importFreeCAD(data: try freeCADDocument(), fileName: "EngineBlock.FCStd")
        let bodies = vm.session.document.bodies
        XCTAssertEqual(bodies.map(\.name), ["Engine & Block", "Body", "Lid"], "the sketch has no surface to show")
        XCTAssertTrue(bodies.allSatisfy { $0.brep != nil }, "exact, like STEP")
        XCTAssertEqual(bodies[2].transform.translation, SIMD3(50, 0, 0))
        XCTAssertEqual(bodies[0].material?.baseColor, SIMD4(1, 0, 0, 1))
        XCTAssertNil(bodies[1].material, "no colour: ours")
        vm.undo()
        XCTAssertTrue(vm.session.document.bodies.isEmpty)

        vm.importFreeCAD(data: Data("not a zip".utf8), fileName: "x.FCStd")
        XCTAssertEqual(vm.errorMessage, "Couldn't import “x.FCStd” — it isn't a FreeCAD document.")
    }

    func testThingsThatAreNotFreeCADAreRefused() {
        XCTAssertThrowsError(try FreeCADKit.parts(from: Data())) { XCTAssertEqual($0 as? FreeCADKit.ReadError, .notFreeCAD) }
        var zip = MinimalZipWriter()
        zip.addFile(path: "Other.xml", data: Data("<a/>".utf8))
        XCTAssertThrowsError(try FreeCADKit.parts(from: zip.finish()))
        var broken = MinimalZipWriter()
        broken.addFile(path: "Document.xml", data: Data("<Document><Objects></Document>".utf8))
        XCTAssertThrowsError(try FreeCADKit.parts(from: broken.finish()))
    }

    /// Real documents saved by FreeCAD, when a folder of them is given.
    func testRealFreeCADDocumentsImport() throws {
        guard let folder = ProcessInfo.processInfo.environment["OS3D_FCSTD_SAMPLES"] else {
            throw XCTSkip("set OS3D_FCSTD_SAMPLES to a folder of .FCStd files")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".FCStd") }
        XCTAssertFalse(files.isEmpty)
        for file in files.sorted() {
            let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(file))
            let contents = try FreeCADKit.parts(from: data)
            let solids = contents.parts.compactMap { OCCTKernel.deserialize($0.brep) }
            let meshed = solids.filter { !OCCTKernel.renderMesh(from: $0).indices.isEmpty }
            print("[FCStd] \(file): \(contents.parts.count) visible shapes, \(solids.count) read, \(meshed.count) with surfaces, \(contents.skipped) skipped; labels \(contents.parts.prefix(6).map(\.label)), colours \(contents.parts.prefix(3).map { $0.color.map { "\($0)" } ?? "-" })")
            XCTAssertEqual(solids.count, contents.parts.count, "\(file): every visible shape reads")
        }
    }
}
