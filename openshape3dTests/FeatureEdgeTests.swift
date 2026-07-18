//
//  FeatureEdgeTests.swift
//  openshape3dTests
//

import XCTest
import Euclid
@testable import openshape3d

final class FeatureEdgeTests: XCTestCase {

    func testCubeHasTwelveEdges() {
        let cube = Euclid.Mesh.cube(size: Vector(2, 2, 2))
        let render = EuclidBridge.renderMesh(from: cube)
        let edges = FeatureEdgeExtractor.edges(from: render)

        XCTAssertEqual(edges.segmentCount, 12, "A cube has exactly 12 feature edges")
    }

    func testCylinderShowsOnlyRims() {
        let cylinder = Euclid.Mesh.cylinder(radius: 1, height: 2, slices: 48)
        let render = EuclidBridge.renderMesh(from: cylinder)
        let edges = FeatureEdgeExtractor.edges(from: render)

        // Two rim circles at 48 segments each; the smooth barrel and cap fans
        // must contribute nothing.
        XCTAssertEqual(edges.segmentCount, 96, "Cylinder should show only its two rim circles")

        for segment in edges.segments {
            XCTAssertEqual(abs(segment.y), 1, accuracy: 1e-4,
                           "All cylinder feature edges lie on the top/bottom rims")
        }
    }

    func testSphereHasNoFeatureEdges() {
        let sphere = Euclid.Mesh.sphere(radius: 1, slices: 32, stacks: 24)
        let render = EuclidBridge.renderMesh(from: sphere)
        let edges = FeatureEdgeExtractor.edges(from: render)

        XCTAssertEqual(edges.segmentCount, 0, "A smooth sphere has no feature edges")
    }
}
