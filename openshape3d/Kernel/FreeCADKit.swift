//
//  FreeCADKit.swift
//  openshape3d
//
//  FreeCAD documents (.FCStd) in and out (spec §12.1 / §12.2). An .FCStd is
//  a zip: Document.xml lists the objects and their properties, each shape
//  property names a file of OpenCASCADE BRep text (PartShape.brp, …) beside
//  it, and GuiDocument.xml says how each object is shown — visible or not,
//  its colour. Our kernel is OpenCASCADE too, so the shapes come and go
//  exactly, like STEP: a cylinder stays a cylinder.
//
//  In: every VISIBLE object with a stored shape becomes a body — FreeCAD's
//  own model, where the intermediate steps (the box and cylinder under a
//  Cut, a Body's features) are there but hidden — named by its label,
//  coloured by its ShapeColor, placed by the App::Part containers around
//  it. A shape is read through the same hardened reader as our stored
//  solids (`OCCTKernel.deserialize`: plausible section counts, a deadline,
//  heal and validate), since the file is untrusted input. Objects with no
//  surface to show (sketches, lines) and binary-BRep shapes are left out
//  and counted.
//
//  Out: a minimal document FreeCAD opens — one Part::Feature per analytic
//  body, its placement baked into the shape, with its colour and visibility.
//  As with STEP, mesh-only bodies have no B-rep to write and are skipped
//  by name.
//
//  The XML is read by `MiniXML` below rather than Foundation's XMLParser,
//  which the WebAssembly build does not have; FreeCAD writes plain,
//  well-formed XML, which is all it needs to read.
//

import Foundation
import simd

private nonisolated extension Transform3D {
    /// The placement that undoes this one.
    var inverse: Transform3D {
        var t = Transform3D()
        t.rotation = rotation.inverse
        t.scale = 1 / max(scale, 1e-12)
        t.translation = -(t.rotation.act(translation) * t.scale)
        return t
    }
}

nonisolated enum FreeCADKit {

    static let fileExtension = "FCStd"

    enum ReadError: Error, Equatable {
        /// Not a zip, or no Document.xml in it.
        case notFreeCAD
        /// More objects than an import will take.
        case tooLarge
    }

    /// One object worth importing: its label, its shape's BRep text, the
    /// placement of the containers around it and its colour (nil: FreeCAD's
    /// default grey is not carried — the body keeps ours).
    struct Part: Equatable {
        var label: String
        var brep: Data
        var placement: Transform3D
        var color: SIMD4<Double>?
    }

    /// What `parts(from:)` found.
    struct Contents: Equatable {
        var parts: [Part]
        /// Visible objects left out: no shape stored, or a binary one.
        var skipped: Int
    }

    /// Objects a document may hold before it is refused (a large assembly is
    /// a few hundred).
    static let maxObjects = 5_000

    // MARK: Reading

    static func parts(from data: Data) throws -> Contents {
        guard let entries = try? ZipReader.entries(in: data),
              let documentXML = entries["Document.xml"],
              let document = MiniXML.parse(documentXML) else { throw ReadError.notFreeCAD }
        let gui = entries["GuiDocument.xml"].flatMap(MiniXML.parse)

        // Types from <Objects>, properties from <ObjectData>.
        var types: [String: String] = [:]
        for object in document.first("Objects")?.all("Object") ?? [] {
            if let name = object["name"] { types[name] = object["type"] ?? "" }
        }
        var properties: [String: [String: MiniXML.Element]] = [:]
        var order: [String] = []
        for object in document.first("ObjectData")?.all("Object") ?? [] {
            guard let name = object["name"] else { continue }
            var props: [String: MiniXML.Element] = [:]
            for property in object.first("Properties")?.all("Property") ?? [] {
                if let key = property["name"] { props[key] = property }
            }
            properties[name] = props
            order.append(name)
        }
        guard order.count <= maxObjects else { throw ReadError.tooLarge }
        var guiProperties: [String: [String: MiniXML.Element]] = [:]
        for provider in gui?.first("ViewProviderData")?.all("ViewProvider") ?? [] {
            guard let name = provider["name"] else { continue }
            var props: [String: MiniXML.Element] = [:]
            for property in provider.first("Properties")?.all("Property") ?? [] {
                if let key = property["name"] { props[key] = property }
            }
            guiProperties[name] = props
        }

        // Containers: who holds whom (App::Part and PartDesign::Body groups).
        var parent: [String: String] = [:]
        for name in order {
            guard let group = properties[name]?["Group"] else { continue }
            for link in group.descendants("Link") {
                if let child = link["value"], parent[child] == nil, child != name { parent[child] = name }
            }
        }

        func visible(_ name: String) -> Bool {
            let property = guiProperties[name]?["Visibility"] ?? properties[name]?["Visibility"]
            return property?.first("Bool")?["value"].map { $0 == "true" } ?? true
        }

        func placementOf(_ name: String) -> Transform3D {
            properties[name]?["Placement"].flatMap(Self.placement) ?? .identity
        }
        /// Containers whose placement carries down to what they hold: every
        /// group with one (App::Part, an assembly) but a PartDesign Body,
        /// whose own shape is already placed.
        func isBody(_ name: String) -> Bool { (types[name] ?? "").hasPrefix("PartDesign::Body") }
        func isContainer(_ name: String) -> Bool { properties[name]?["Group"] != nil }

        /// The shapes an object shows, each with the placement to put on its
        /// stored shape (which carries the object's own placement already):
        /// its own shape; for a Link, its target's, moved to the link's
        /// placement; for a container, its visible contents', moved by it.
        func shapes(_ name: String, depth: Int, visiting: Set<String>) -> [(file: String, transform: Transform3D, owner: String)]? {
            guard depth < 16, !visiting.contains(name), let props = properties[name] else { return nil }
            let visiting = visiting.union([name])
            if let link = props["LinkedObject"] {
                // App::Link: the target in the link's place. Without
                // LinkTransform the link's placement REPLACES the target's.
                guard let target = (link.first("XLink") ?? link.first("Link"))?["name"], !target.isEmpty,
                      (link.first("XLink")?["file"] ?? "").isEmpty,
                      (props["ElementCount"]?.first("Integer")?["value"].flatMap(Int.init) ?? 0) == 0,
                      let inner = shapes(target, depth: depth + 1, visiting: visiting) else { return nil }
                let here = placementOf(name)
                let linkTransform = props["LinkTransform"]?.first("Bool")?["value"] == "true"
                let move = linkTransform ? here : here.composed(onto: placementOf(target).inverse)
                return inner.map { ($0.file, move.composed(onto: $0.transform), $0.owner) }
            }
            if let shape = props["Shape"], (shape["type"] ?? "").contains("PropertyPartShape"),
               !isContainer(name) || isBody(name) {
                guard let file = shape.first("Part")?["file"], !file.isEmpty else { return nil }
                return [(file, .identity, name)]
            }
            if isContainer(name), !isBody(name) {
                let here = placementOf(name)
                var out: [(file: String, transform: Transform3D, owner: String)] = []
                for link in props["Group"]?.descendants("Link") ?? [] {
                    guard let child = link["value"], visible(child),
                          let inner = shapes(child, depth: depth + 1, visiting: visiting) else { continue }
                    out += inner.map { ($0.file, here.composed(onto: $0.transform), $0.owner) }
                }
                return out
            }
            return nil
        }

        var parts: [Part] = []
        var skipped = 0
        for name in order {
            guard visible(name), !isContainer(name) || isBody(name) else { continue }
            // Walk up the containers: a hidden one hides its contents; a
            // PartDesign Body stands for its features; the others carry
            // their placement down, outermost last.
            var placement = Transform3D.identity
            var hidden = false, insideBody = false
            var seen: Set<String> = [name]
            var up = parent[name]
            while let container = up, seen.insert(container).inserted {
                if !visible(container) { hidden = true; break }
                if isBody(container) { insideBody = true; break }
                placement = placementOf(container).composed(onto: placement)
                up = parent[container]
            }
            guard !hidden, !insideBody else { continue }
            let props = properties[name] ?? [:]
            let showsSomething = props["Shape"] != nil || props["LinkedObject"] != nil
            guard showsSomething else { continue }
            guard let found = shapes(name, depth: 0, visiting: []), !found.isEmpty else {
                skipped += 1
                continue
            }
            let label = props["Label"]?.first("String")?["value"] ?? name
            for shape in found {
                guard shape.file.lowercased().hasSuffix(".brp"), let brep = entries[shape.file], !brep.isEmpty else {
                    skipped += 1
                    continue
                }
                // A link shows its target's colour unless it has its own.
                let color = guiProperties[name].flatMap { Self.color($0, files: entries) }
                    ?? guiProperties[shape.owner].flatMap { Self.color($0, files: entries) }
                parts.append(Part(label: label.isEmpty ? name : label, brep: brep,
                                  placement: placement.composed(onto: shape.transform), color: color))
            }
        }
        return Contents(parts: parts, skipped: skipped)
    }

    /// <PropertyPlacement Px Py Pz Q0 Q1 Q2 Q3/> — Q0…Q2 the quaternion's
    /// vector part, Q3 its scalar.
    static func placement(_ property: MiniXML.Element) -> Transform3D? {
        guard let p = property.first("PropertyPlacement") else { return nil }
        func d(_ key: String, _ fallback: Double = 0) -> Double { p[key].flatMap(Double.init) ?? fallback }
        var t = Transform3D()
        t.translation = SIMD3(d("Px"), d("Py"), d("Pz"))
        let q = simd_quatd(ix: d("Q0"), iy: d("Q1"), iz: d("Q2"), r: d("Q3", 1))
        guard q.length > 1e-12, t.translation.x.isFinite, t.translation.y.isFinite, t.translation.z.isFinite else { return nil }
        t.rotation = simd_normalize(q)
        return t
    }

    /// An object's colour as RGBA, alpha the opacity: FreeCAD 1.x keeps it
    /// in a ShapeAppearance material list (a file beside the XML: count,
    /// then per material ambient, diffuse, specular, emissive as packed
    /// 0xRRGGBBAA, shininess and transparency as floats, little-endian —
    /// App/PropertyStandard.cpp), older versions in ShapeColor with
    /// Transparency (percent). The packed low byte is read as neither: its
    /// meaning flipped from transparency to alpha in FreeCAD 1.1.
    static func color(_ properties: [String: MiniXML.Element], files: [String: Data]) -> SIMD4<Double>? {
        func rgb(_ packed: UInt32) -> SIMD3<Double> {
            SIMD3(Double(packed >> 24 & 0xFF), Double(packed >> 16 & 0xFF), Double(packed >> 8 & 0xFF)) / 255
        }
        if let file = properties["ShapeAppearance"]?.first("MaterialList")?["file"], let data = files[file] {
            let b = [UInt8](data)
            func u32(_ at: Int) -> UInt32 {
                UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
            }
            if b.count >= 28, u32(0) >= 1 {
                let transparency = Double(Float(bitPattern: u32(24)))
                let opacity = transparency.isFinite ? 1 - min(max(transparency, 0), 1) : 1
                let c = rgb(u32(8))
                return SIMD4(c.x, c.y, c.z, opacity)
            }
        }
        guard let packed = properties["ShapeColor"]?.first("PropertyColor")?["value"].flatMap(UInt32.init) else { return nil }
        let percent = properties["Transparency"]?.first("Integer")?["value"].flatMap(Double.init) ?? 0
        let c = rgb(packed)
        return SIMD4(c.x, c.y, c.z, 1 - min(max(percent, 0), 100) / 100)
    }

    /// FreeCAD's packed colour for RGBA, the low byte the transparency — the
    /// meaning before FreeCAD 1.1, which our documents declare themselves.
    static func packedColor(_ c: SIMD4<Double>) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.x) << 24 | byte(c.y) << 16 | byte(c.z) << 8 | byte(1 - c.w)
    }

    /// A one-material ShapeAppearance list (format version 3) in `c`.
    static func appearance(_ c: SIMD4<Double>) -> Data {
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func f32(_ v: Float) { u32(v.bitPattern) }
        let opaque = SIMD4<Double>(0, 0, 0, 1)
        u32(1)
        u32(packedColor(SIMD4(0.2, 0.2, 0.2, 1)))           // ambient
        u32(packedColor(c))                                 // diffuse
        u32(packedColor(opaque))                            // specular
        u32(packedColor(opaque))                            // emissive
        f32(0.2)                                            // shininess
        f32(Float(1 - min(max(c.w, 0), 1)))                 // transparency
        u32(0); u32(0); u32(0)                              // image, image path, uuid
        return out
    }

    // MARK: Writing

    enum ExportOutcome: Equatable {
        case success(Data, skipped: [String])
        case nothingAnalytic(skipped: [String])
        case failed
    }

    /// The colour a body without a material shows (the scene's default grey).
    static let defaultColor = SIMD4<Double>(0.72, 0.74, 0.78, 1)

    static func export(bodies: [Body], documentLabel: String) -> ExportOutcome {
        var objects: [(name: String, label: String, file: String, color: SIMD4<Double>, visible: Bool)] = []
        // FreeCAD reads the zip's entries in the order it asks for them
        // (Base::XMLReader::readFiles): Document.xml, the shapes in object
        // order, GuiDocument.xml, then the view providers' files.
        var shapeFiles: [(String, Data)] = []
        var guiFiles: [(String, Data)] = []
        var skipped: [String] = []
        for body in bodies {
            guard let brep = body.brep, let placed = OCCTKernel.transformed(brep, by: body.transform),
                  let text = OCCTKernel.serialize(placed) else {
                skipped.append(body.name)
                continue
            }
            let index = objects.count
            let name = index == 0 ? "Solid" : String(format: "Solid%03d", index)
            let file = index == 0 ? "PartShape.brp" : "PartShape\(index).brp"
            let color = body.material?.baseColor ?? defaultColor
            objects.append((name, body.name, file, color, !body.isHidden))
            shapeFiles.append((file, text))
            guiFiles.append((index == 0 ? "ShapeAppearance" : "ShapeAppearance\(index)", appearance(color)))
        }
        guard !objects.isEmpty else { return .nothingAnalytic(skipped: skipped) }

        var doc = """
        <?xml version='1.0' encoding='utf-8'?>
        <!--
         FreeCAD Document, see https://www.freecad.org for more information...
         Written by OpenShape3D.
        -->
        <Document SchemaVersion="4" ProgramVersion="0.21R0 (OpenShape3D)" FileVersion="1">
            <Properties Count="1" TransientCount="0">
                <Property name="Label" type="App::PropertyString">
                    <String value="\(escaped(documentLabel))"/>
                </Property>
            </Properties>
            <Objects Count="\(objects.count)">

        """
        for o in objects { doc += "        <Object type=\"Part::Feature\" name=\"\(o.name)\"/>\n" }
        doc += "    </Objects>\n    <ObjectData Count=\"\(objects.count)\">\n"
        for o in objects {
            doc += """
                    <Object name="\(o.name)">
                        <Properties Count="4" TransientCount="0">
                            <Property name="Label" type="App::PropertyString">
                                <String value="\(escaped(o.label))"/>
                            </Property>
                            <Property name="Placement" type="App::PropertyPlacement">
                                <PropertyPlacement Px="0" Py="0" Pz="0" Q0="0" Q1="0" Q2="0" Q3="1" A="0" Ox="0" Oy="0" Oz="1"/>
                            </Property>
                            <Property name="Shape" type="Part::PropertyPartShape">
                                <Part file="\(o.file)"/>
                            </Property>
                            <Property name="Visibility" type="App::PropertyBool">
                                <Bool value="\(o.visible)"/>
                            </Property>
                        </Properties>
                    </Object>

            """
        }
        doc += "    </ObjectData>\n</Document>\n"

        var gui = """
        <?xml version='1.0' encoding='utf-8'?>
        <Document SchemaVersion="1">
            <ViewProviderData Count="\(objects.count)">

        """
        for o in objects {
            let transparency = Int(((1 - min(max(o.color.w, 0), 1)) * 100).rounded())
            let index = objects.firstIndex { $0.name == o.name } ?? 0
            gui += """
                    <ViewProvider name="\(o.name)">
                        <Properties Count="4" TransientCount="0">
                            <Property name="ShapeAppearance" type="App::PropertyMaterialList">
                                <MaterialList file="\(index == 0 ? "ShapeAppearance" : "ShapeAppearance\(index)")" version="3"/>
                            </Property>
                            <Property name="ShapeColor" type="App::PropertyColor">
                                <PropertyColor value="\(packedColor(o.color))"/>
                            </Property>
                            <Property name="Transparency" type="App::PropertyPercent">
                                <Integer value="\(transparency)"/>
                            </Property>
                            <Property name="Visibility" type="App::PropertyBool">
                                <Bool value="\(o.visible)"/>
                            </Property>
                        </Properties>
                    </ViewProvider>

            """
        }
        // Gui::Document::RestoreDocFile reads a Camera element last.
        gui += "    </ViewProviderData>\n    <Camera/>\n</Document>\n"

        var zip = MinimalZipWriter()
        zip.addFile(path: "Document.xml", data: Data(doc.utf8))
        for (path, data) in shapeFiles { zip.addFile(path: path, data: data) }
        zip.addFile(path: "GuiDocument.xml", data: Data(gui.utf8))
        for (path, data) in guiFiles { zip.addFile(path: path, data: data) }
        return .success(zip.finish(), skipped: skipped)
    }

    static func escaped(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            default:
                if c.value < 0x20 { continue }
                out.unicodeScalars.append(c)
            }
        }
        return out
    }
}

/// Just enough XML for documents a program wrote: elements and their
/// attributes, comments / declarations / CDATA skipped, text ignored, the
/// five named entities and numeric ones decoded. Nil when the tags do not
/// nest.
nonisolated enum MiniXML {
    final class Element {
        let name: String
        var attributes: [String: String] = [:]
        var children: [Element] = []
        init(name: String) { self.name = name }

        subscript(attribute: String) -> String? { attributes[attribute] }
        func first(_ child: String) -> Element? { children.first { $0.name == child } }
        func all(_ child: String) -> [Element] { children.filter { $0.name == child } }
        /// Every element under this one named `name`, depth first.
        func descendants(_ name: String) -> [Element] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
        }
    }

    /// Deepest nesting accepted (FreeCAD's is under 10).
    static let maxDepth = 256

    static func parse(_ data: Data) -> Element? {
        let b = [UInt8](data)
        var i = 0
        var stack: [Element] = []
        var root: Element?
        func startsWith(_ s: String, at at: Int) -> Bool {
            let u = Array(s.utf8)
            return at + u.count <= b.count && Array(b[at..<at + u.count]) == u
        }
        func skip(past s: String) -> Bool {
            let u = Array(s.utf8)
            while i + u.count <= b.count {
                if b[i] == u[0], Array(b[i..<i + u.count]) == u { i += u.count; return true }
                i += 1
            }
            return false
        }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func isNameByte(_ c: UInt8) -> Bool {
            !(isSpace(c) || c == UInt8(ascii: "=") || c == UInt8(ascii: ">") || c == UInt8(ascii: "/")
              || c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") || c == UInt8(ascii: "<"))
        }
        func name() -> String? {
            let start = i
            while i < b.count, isNameByte(b[i]) { i += 1 }
            return i > start ? String(decoding: b[start..<i], as: UTF8.self) : nil
        }
        while i < b.count {
            guard b[i] == UInt8(ascii: "<") else { i += 1; continue }
            if startsWith("<!--", at: i) {
                i += 4
                guard skip(past: "-->") else { return nil }
            } else if startsWith("<![CDATA[", at: i) {
                i += 9
                guard skip(past: "]]>") else { return nil }
            } else if startsWith("<?", at: i) {
                i += 2
                guard skip(past: "?>") else { return nil }
            } else if startsWith("<!", at: i) {
                i += 2
                guard skip(past: ">") else { return nil }
            } else if startsWith("</", at: i) {
                i += 2
                guard let closing = name(), let open = stack.popLast(), open.name == closing else { return nil }
                while i < b.count, isSpace(b[i]) { i += 1 }
                guard i < b.count, b[i] == UInt8(ascii: ">") else { return nil }
                i += 1
                if stack.isEmpty { root = open }
            } else {
                i += 1
                guard let tag = name() else { return nil }
                let element = Element(name: tag)
                var selfClosing = false
                while true {
                    while i < b.count, isSpace(b[i]) { i += 1 }
                    guard i < b.count else { return nil }
                    if b[i] == UInt8(ascii: ">") { i += 1; break }
                    if b[i] == UInt8(ascii: "/") {
                        guard i + 1 < b.count, b[i + 1] == UInt8(ascii: ">") else { return nil }
                        i += 2
                        selfClosing = true
                        break
                    }
                    guard let key = name() else { return nil }
                    while i < b.count, isSpace(b[i]) { i += 1 }
                    guard i < b.count, b[i] == UInt8(ascii: "=") else { return nil }
                    i += 1
                    while i < b.count, isSpace(b[i]) { i += 1 }
                    guard i < b.count, b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") else { return nil }
                    let quote = b[i]
                    i += 1
                    let start = i
                    while i < b.count, b[i] != quote { i += 1 }
                    guard i < b.count else { return nil }
                    element.attributes[key] = decoded(String(decoding: b[start..<i], as: UTF8.self))
                    i += 1
                }
                if let parent = stack.last {
                    parent.children.append(element)
                } else if root != nil {
                    return nil // a second root
                }
                if selfClosing {
                    if stack.isEmpty { root = element }
                } else {
                    guard stack.count < maxDepth else { return nil }
                    stack.append(element)
                }
            }
        }
        return stack.isEmpty ? root : nil
    }

    static func decoded(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 else {
                out += rest[amp...]
                return out
            }
            let entity = rest[rest.index(after: amp)..<semi]
            switch entity {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                let value = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16)
                    : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
                if let value, let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                } else {
                    out += rest[amp...semi]
                }
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }
}
