//
//  Decals.swift
//  openshape3d
//
//  Decals (spec §14): an image put on a body's surface — a logo, a label, a
//  warning sticker. A decal is projected onto the body along the surface's
//  normal where it was placed, so it lies flat on a flat face and wraps a
//  curved one; it is drawn over the body (the body's own triangles again,
//  with a shader that keeps only what falls inside the decal) and never
//  changes the geometry.
//
//  Decals are the document's, each naming its body, rather than the body's
//  own: a body is rebuilt whole by every edit, its ID stays.
//

import Foundation
import simd

nonisolated struct Decal: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var bodyID: BodyID
    /// What the decal list calls it (the picked file's name).
    var name: String
    /// The image, PNG or JPEG.
    var image: Data
    /// Where its middle sits (body-local) and the surface's outward normal
    /// there — the direction it is projected along.
    var center: SIMD3<Double>
    var normal: SIMD3<Double>
    /// Width along the surface, mm; the height follows the image.
    var width: Double
    /// Height ÷ width of the image.
    var aspect: Double
    /// Turned about the normal, degrees counter-clockwise.
    var rotation: Double = 0
    var opacity: Double = 1

    var height: Double { width * aspect }

    init(bodyID: BodyID, name: String, image: Data, center: SIMD3<Double>, normal: SIMD3<Double>,
         width: Double, aspect: Double) {
        self.bodyID = bodyID
        self.name = name
        self.image = image
        self.center = center
        self.normal = simd_length(normal) > 1e-12 ? simd_normalize(normal) : SIMD3(0, 1, 0)
        self.width = width
        self.aspect = aspect
    }

    private enum CodingKeys: String, CodingKey {
        case id, bodyID, name, image, center, normal, width, aspect, rotation, opacity
    }

    // Everything but the image and placement defaulted on the way in.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bodyID = try c.decode(BodyID.self, forKey: .bodyID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Decal"
        image = try c.decode(Data.self, forKey: .image)
        center = try c.decode(SIMD3<Double>.self, forKey: .center)
        let n = try c.decode(SIMD3<Double>.self, forKey: .normal)
        normal = simd_length(n) > 1e-12 ? simd_normalize(n) : SIMD3(0, 1, 0)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 10
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 1
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

nonisolated enum DecalKit {
    /// Decal sizes, mm.
    static let widthRange = 0.1...10_000.0
    /// Images are kept at most this many pixels on a side.
    static let maxPixels = 2048

    /// The decal's axes, body-local: `u` along its width, `v` up its height,
    /// `n` out of the surface. Unturned, `v` is the world's up as seen on the
    /// surface (or, on a face that looks up or down, the far side: -Z).
    static func frame(_ decal: Decal) -> (u: SIMD3<Double>, v: SIMD3<Double>, n: SIMD3<Double>) {
        let n = decal.normal
        var up = SIMD3<Double>(0, 1, 0)
        if abs(simd_dot(up, n)) > 0.95 { up = SIMD3(0, 0, -1) }
        let v0 = simd_normalize(up - n * simd_dot(up, n))
        let u0 = simd_normalize(simd_cross(v0, n))
        let a = decal.rotation * .pi / 180
        let u = u0 * cos(a) + v0 * sin(a)
        let v = v0 * cos(a) - u0 * sin(a)
        return (u, v, n)
    }

    /// Where a body-local point falls on the decal: (-1…1, -1…1) inside it.
    static func decalCoordinates(of point: SIMD3<Double>, in decal: Decal) -> SIMD2<Double> {
        let (u, v, _) = frame(decal)
        let d = point - decal.center
        return SIMD2(simd_dot(d, u) / (decal.width / 2), simd_dot(d, v) / (decal.height / 2))
    }

    /// A size from the Size slider, to three significant figures (14.3, not 14.2801).
    static func tidyWidth(_ width: Double) -> Double {
        guard width > 0, width.isFinite else { return 10 }
        let step = pow(10, floor(log10(width)) - 2)
        return (width / step).rounded() * step
    }

    /// A first size for a decal on `body`: a third of the body's largest
    /// extent, rounded to a tidy number.
    static func defaultWidth(for body: Body) -> Double {
        let box = body.render.localAABB
        let extent = SIMD3<Double>(box.max - box.min)
        let third = max(extent.x, extent.y, extent.z) / 3
        guard third > 0 else { return 10 }
        let step = pow(10, floor(log10(third)))
        return (third / step).rounded() * step
    }
}

/// Add, change or remove decals as one undo step.
struct SetDecalsCommand: DocumentCommand {
    let title: String
    let old: [Decal]
    let new: [Decal]

    func apply(to document: inout DesignDocument) { document.decals = new }
    func revert(in document: inout DesignDocument) { document.decals = old }
}
