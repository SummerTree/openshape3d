import XCTest
import Euclid
@testable import openshape3d

/// The signature resolver on a DENSE body: a revolved spline tessellates into
/// tens of thousands of facet faces, and resolving one face used to rescan
/// the whole face table per candidate — minutes on the main thread for a
/// shell's one open face. The table aligns with the enumeration, so the
/// role lookup is an index; the scan survives only under the budget.
final class SignatureNamingScaleTests: XCTestCase {
    func testResolvingOneFaceOfATwentyThousandFacetBodyIsBounded() throws {
        // A lathe of a 200-point wavy profile, 100 slices: ~20k planar quads.
        var points: [PathPoint] = []
        for i in 0...200 {
            let h = Double(i) * 230.0 / 200
            let r = 28 + 4 * sin(h / 12) + (h > 200 ? -12 : 0)
            points.append(.point(Vector(r, h, 0)))
        }
        let path = Path(points)
        let mesh = Mesh.lathe(path, slices: 100)
        var document = DesignDocument()
        let body = Body(name: "Dense", transform: .identity, euclidMesh: mesh, revision: document.nextRevision())
        XCTAssertGreaterThan(body.render.triangleCount, 20_000)

        let naming = SignatureNaming()
        let table = naming.propagate(inputs: [], output: body, op: .pushPull)
        XCTAssertGreaterThan(table.entries.count, 5_000, "enumerated into thousands of facet faces")

        // Pick a mid-body facet and ask for it back, table in hand.
        let k = table.entries.count / 2
        let ref = FaceRef(body: BodyRef(producer: FeatureID(), bodyID: body.id), creator: FeatureID(),
                          role: table.entries[k].role, signature: table.entries[k].signature)
        let t0 = Date()
        let resolved = naming.resolve(ref, in: body, table: table)
        let seconds = Date().timeIntervalSince(t0)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.planar?.triangles, table.entries[k].triangles, "its own facet")
        XCTAssertLessThan(seconds, 3, "resolve took \(seconds) s on \(table.entries.count) faces")
    }
}
