//
//  RenderMeshFaceChannelTests.swift
//  openshape3dTests
//
//  The per-triangle OCCT face channel (docs/TOPO_NAMING_HISTORY_DESIGN.md
//  step 1): every render-mesh triangle knows WHICH analytic face it
//  tessellates, in the same 1-based indexed-map numbering the health report
//  names ("Face3"). No behavior changes ride on it yet — these tests pin the
//  channel's contract before element naming starts consuming it.
//  Pure values over OCCTKernel; no DocumentSession/ModelContainer.
//

import XCTest
import simd
@testable import openshape3d

final class RenderMeshFaceChannelTests: XCTestCase {

    private func channelAndTriangles(_ handle: BRepHandle)
        -> (channel: [UInt32], triangles: Int) {
        let mesh = OCCTKernel.renderMesh(from: handle)
        return (OCCTKernel.renderMeshFaceChannel(from: handle),
                mesh.indices.count / 3)
    }

    /// A box: 12 triangles over 6 faces — one channel entry per triangle,
    /// every face claimed by exactly 2, and every entry a real 1-based index.
    func testABoxLabelsTwoTrianglesPerFace() throws {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 4, depth: 4, height: 4), placement: .identity))
        let (channel, triangles) = channelAndTriangles(box)
        XCTAssertEqual(channel.count, triangles, "one entry per triangle")
        XCTAssertEqual(triangles, 12)
        XCTAssertFalse(channel.contains(0), "no triangle may be unlabelled")
        let perFace = Dictionary(grouping: channel, by: { $0 })
        XCTAssertEqual(perFace.count, 6)
        XCTAssertTrue(perFace.values.allSatisfy { $0.count == 2 },
                      "each box face tessellates to exactly 2 triangles")
        XCTAssertEqual(perFace.keys.sorted(), [1, 2, 3, 4, 5, 6],
                       "indices are 1-based and dense over the face map")
    }

    /// A cylinder: 3 analytic faces, many triangles — the channel's distinct
    /// values must agree with the face count, and the curved wall must own
    /// the overwhelming majority of them.
    func testACylinderChannelMatchesItsFaceCount() throws {
        let cylinder = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 4, height: 6), placement: .identity))
        let (channel, triangles) = channelAndTriangles(cylinder)
        XCTAssertEqual(channel.count, triangles)
        XCTAssertFalse(channel.contains(0))
        XCTAssertEqual(Set(channel).count, 3)  // 2 caps + 1 wall
    }

    /// A boolean result keeps the channel honest: box − cylinder = 7 faces
    /// (6 planar + 1 bore), and the channel must name all 7, nothing else.
    func testABooleanResultChannelCoversEveryResultFace() throws {
        let plate = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 6), placement: .identity))
        let drill = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 2, height: 20),
            placement: Transform3D(translation: SIMD3(5, -1, 5))))
        let cut = try OCCTKernel.booleanResult(plate, drill, op: 1).get().handle
        let counts = OCCTKernel.faceTypeCounts(cut)
        let (channel, triangles) = channelAndTriangles(cut)
        XCTAssertEqual(channel.count, triangles)
        XCTAssertFalse(channel.contains(0))
        XCTAssertEqual(Set(channel).count,
                       counts.planar + counts.cylindrical + counts.other)
    }
}
