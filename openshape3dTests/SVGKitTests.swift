//
//  SVGKitTests.swift
//  openshape3dTests
//
//  Export ▸ SVG from Sketch: well-formed SVG in millimetres, one element per
//  entity, Y flipped so the drawing reads as the sketch does head-on.
//

import XCTest
import simd
@testable import openshape3d

final class SVGKitTests: XCTestCase {

    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [(String, [String: String])] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            elements.append((name, attributes))
        }
    }

    private func parse(_ svg: String) throws -> [(String, [String: String])] {
        let parser = XMLParser(data: Data(svg.utf8))
        let collector = Collector()
        parser.delegate = collector
        XCTAssertTrue(parser.parse(), "well-formed XML: \(parser.parserError.map(String.init(describing:)) ?? "")")
        return collector.elements
    }

    func testEveryEntityBecomesOneElement() throws {
        let entities: [SketchEntity] = [
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(40, 0)),
            .circle(id: UUID(), center: SIMD2(20, 10), radius: 5),
            .arc(id: UUID(), center: SIMD2(0, 0), radius: 10, startAngle: 0, endAngle: .pi / 2),
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(40, 20)),
            .ellipse(id: UUID(), center: SIMD2(30, 10), radiusX: 6, radiusY: 3, rotation: .pi / 6),
            .spline(id: UUID(), points: [SIMD2(0, 0), SIMD2(10, 15), SIMD2(20, 0)], closed: false),
        ]
        let elements = try parse(SVGKit.exportSketch(entities: entities))
        let names = elements.map(\.0)
        XCTAssertEqual(names.first, "svg")
        for name in ["line", "circle", "path", "polygon", "ellipse", "polyline"] {
            XCTAssertEqual(names.filter { $0 == name }.count, 1, name)
        }
        let svg = try XCTUnwrap(elements.first?.1)
        XCTAssertTrue(svg["width"]?.hasSuffix("mm") == true, "physical size in millimetres")
    }

    func testYIsFlipped() throws {
        // A line going UP in the sketch goes up on the page too — its higher
        // end has the smaller SVG y.
        let svg = SVGKit.exportSketch(entities: [.line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(0, 30))])
        let line = try XCTUnwrap(try parse(svg).first { $0.0 == "line" }?.1)
        let y1 = try XCTUnwrap(Double(line["y1"] ?? "")), y2 = try XCTUnwrap(Double(line["y2"] ?? ""))
        XCTAssertGreaterThan(y1, y2)
        XCTAssertEqual(y1 - y2, 30, accuracy: 1e-9)
    }

    func testEmptySketchIsStillValid() throws {
        XCTAssertEqual(try parse(SVGKit.exportSketch(entities: [])).first?.0, "svg")
    }
}
