//
//  DeviationPreview.swift
//  openshape3d
//
//  The Accuracy Report on the part itself: the reference body (a scan)
//  coloured by how far each of its vertices sits from the model's surface —
//  blue where the model is missing material, orange where it has too much,
//  grey within tolerance — with the model ghosted behind it. The report
//  says by how much; this says WHERE, to a person looking at the viewport
//  and to an assistant looking at a screenshot of it. A display state like
//  a section view: nothing in the document, no undo step.
//
//  Drawn through the textured pipeline an imported photo uses: the
//  reference keeps its own mesh and gets texcoords (t, ½) into a 256 × 1
//  colour ramp, t = ½ at zero distance, 0 at −maxMM (excess), 1 at +maxMM
//  (missing). No new shader, no new buffer kind. The ramp is written as a
//  PNG by hand (stored deflate blocks) so this file stays Kernel-portable —
//  the web app compiles `Kernel/` unchanged, without UIKit.
//

import Foundation
import simd
#if canImport(Dispatch)
import Dispatch
#endif

/// Per-vertex deviation of a reference from a model, summarised.
nonisolated struct DeviationPreviewStats: Sendable, Equatable {
    var vertices: Int
    /// Of |distance|.
    var meanMM: Double
    var p95MM: Double
    var maxMM: Double
    /// Positive: the reference sits outside the model on average — the
    /// model is undersized there.
    var meanSignedMM: Double
    /// Shares of the vertices, 0…1.
    var withinTolerance: Double
    /// Beyond +tolerance: the reference has material the model lacks.
    var missing: Double
    /// Beyond −tolerance: the model has material the reference lacks.
    var excess: Double

    var wire: [String: Any] {
        ["vertices": vertices, "meanMM": meanMM, "p95MM": p95MM, "maxMM": maxMM,
         "meanSignedMM": meanSignedMM, "withinTolerance": withinTolerance,
         "missing": missing, "excess": excess]
    }
}

nonisolated struct DeviationPreview: Sendable, Equatable {
    var reference: BodyID
    var model: BodyID
    var toleranceMM: Double
    /// Full colour at this distance and beyond.
    var maxMM: Double
    var stats: DeviationPreviewStats
    /// One per vertex of the reference's render mesh, into `ramp`.
    var texcoords: [SIMD2<Float>]
    /// The 256 × 1 PNG the texcoords sample.
    var ramp: Data
    /// The reference's `meshRevision` the texcoords were built for; a
    /// rebuilt mesh ends the preview rather than wearing stale colours.
    var meshRevision: UInt64
    /// What the GPU caches key the ramp and the buffers on.
    var stamp: UInt64

    // MARK: Measuring

    /// Signed distance from every vertex of `reference` to `model`'s
    /// surface — positive outside it (the model lacks that material),
    /// negative inside (the model has too much). Vertices no triangle uses
    /// read 0.
    static func signedDistances(reference: AccuracyMesh, model: AccuracyMesh) -> [Double]? {
        guard model.triangleCount > 0, !reference.positions.isEmpty else { return nil }
        let grid = SurfaceGrid(mesh: model)
        let used = Set(reference.indices)
        let count = reference.positions.count
        var signed = [Double](repeating: 0, count: count)
        // Nearest-point queries are independent: spread them over the cores
        // in runs of a few hundred vertices (a dense scan has tens of
        // thousands, a few seconds on one core). The web app compiles this
        // file unchanged for WebAssembly, which has no Dispatch and one
        // thread: there the same loop runs in order.
        #if canImport(Dispatch) && !os(WASI)
        let chunk = 512
        let chunks = (count + chunk - 1) / chunk
        signed.withUnsafeMutableBufferPointer { out in
            // Each chunk writes its own slice; the pointer is shared on purpose.
            nonisolated(unsafe) let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunk, hi = min(lo + chunk, count)
                for i in lo..<hi where used.contains(UInt32(i)) {
                    if let hit = grid.nearest(to: reference.positions[i]) {
                        base[i] = hit.signedDistance
                    }
                }
            }
        }
        #else
        for i in 0..<count where used.contains(UInt32(i)) {
            if let hit = grid.nearest(to: reference.positions[i]) {
                signed[i] = hit.signedDistance
            }
        }
        #endif
        return signed
    }

    static func stats(of signed: [Double], toleranceMM: Double) -> DeviationPreviewStats {
        guard !signed.isEmpty else {
            return DeviationPreviewStats(vertices: 0, meanMM: 0, p95MM: 0, maxMM: 0, meanSignedMM: 0,
                                         withinTolerance: 1, missing: 0, excess: 0)
        }
        let unsigned = signed.map(abs)
        let s = AccuracyKit.summarize(unsigned)
        let n = Double(signed.count)
        return DeviationPreviewStats(
            vertices: signed.count, meanMM: s.mean, p95MM: s.p95, maxMM: s.max,
            meanSignedMM: signed.reduce(0, +) / n,
            withinTolerance: Double(unsigned.filter { $0 <= toleranceMM }.count) / n,
            missing: Double(signed.filter { $0 > toleranceMM }.count) / n,
            excess: Double(signed.filter { $0 < -toleranceMM }.count) / n)
    }

    /// Where a signed distance lands on the ramp: ½ at zero, the ends at
    /// ±maxMM, clamped.
    static func rampCoordinate(_ signed: Double, maxMM: Double) -> Float {
        let t = 0.5 + signed / (2 * max(maxMM, 1e-9))
        return Float(min(max(t, 0), 1))
    }

    /// The colour of the ramp at `t` (0…1): deep orange through grey to
    /// deep blue, with the grey band exactly ±tolerance wide so the step
    /// into colour is the tolerance itself.
    static func rampColor(at t: Double, toleranceMM: Double, maxMM: Double) -> (r: Double, g: Double, b: Double) {
        let d = (t - 0.5) * 2 * maxMM
        let grey = (0.80, 0.81, 0.84)
        if abs(d) <= toleranceMM { return grey }
        // How far past the tolerance, 0…1 at the full colour.
        let span = max(maxMM - toleranceMM, 1e-9)
        let f = min((abs(d) - toleranceMM) / span, 1)
        let light: (Double, Double, Double), deep: (Double, Double, Double)
        if d > 0 {
            light = (0.56, 0.74, 0.96); deep = (0.08, 0.32, 0.86)      // missing: blues
        } else {
            light = (0.99, 0.80, 0.58); deep = (0.90, 0.42, 0.08)      // excess: oranges
        }
        return (light.0 + (deep.0 - light.0) * f, light.1 + (deep.1 - light.1) * f, light.2 + (deep.2 - light.2) * f)
    }

    /// The 256 × 1 ramp as a PNG, for the texture cache.
    static func rampPNG(toleranceMM: Double, maxMM: Double) -> Data? {
        let width = 256
        var rgba = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let t = (Double(x) + 0.5) / Double(width)
            let c = rampColor(at: t, toleranceMM: toleranceMM, maxMM: maxMM)
            rgba[x * 4] = UInt8(max(0, min(255, (c.r * 255).rounded())))
            rgba[x * 4 + 1] = UInt8(max(0, min(255, (c.g * 255).rounded())))
            rgba[x * 4 + 2] = UInt8(max(0, min(255, (c.b * 255).rounded())))
        }
        return PNGWriter.rgba(width: width, height: 1, pixels: rgba)
    }

    /// Measure `reference` against `model` (both placed in the world) and
    /// build the preview; nil when either has no geometry.
    static func make(reference: AccuracyMesh, model: AccuracyMesh, referenceID: BodyID, modelID: BodyID,
                     meshRevision: UInt64, toleranceMM: Double, maxMM: Double) -> DeviationPreview? {
        guard let signed = signedDistances(reference: reference, model: model),
              let ramp = rampPNG(toleranceMM: toleranceMM, maxMM: maxMM) else { return nil }
        let texcoords = signed.map { SIMD2<Float>(rampCoordinate($0, maxMM: maxMM), 0.5) }
        var stamp = ImageFingerprint.of(ramp)
        stamp ^= UInt64(signed.count) &* 0x9E37_79B9_7F4A_7C15
        return DeviationPreview(reference: referenceID, model: modelID, toleranceMM: toleranceMM, maxMM: maxMM,
                                stats: stats(of: signed, toleranceMM: toleranceMM), texcoords: texcoords, ramp: ramp,
                                meshRevision: meshRevision, stamp: stamp)
    }

    static func make(reference: Body, model: Body, toleranceMM: Double, maxMM: Double) -> DeviationPreview? {
        make(reference: AccuracyMesh(body: reference), model: AccuracyMesh(body: model),
             referenceID: reference.id, modelID: model.id, meshRevision: reference.meshRevision,
             toleranceMM: toleranceMM, maxMM: maxMM)
    }
}


// MARK: - A PNG by hand

/// Enough of PNG to carry a small RGBA image without an image framework:
/// one IHDR, one IDAT holding the rows (filter byte 0) in a zlib stream of
/// stored deflate blocks, IEND. Decoders read it like any other PNG.
nonisolated enum PNGWriter {
    static func rgba(width: Int, height: Int, pixels: [UInt8]) -> Data? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        var raw: [UInt8] = []
        raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height {
            raw.append(0)                                   // filter: none
            raw += pixels[(y * width * 4)..<((y + 1) * width * 4)]
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr: [UInt8] = []
        ihdr += be32(UInt32(width)) + be32(UInt32(height))
        ihdr += [8, 6, 0, 0, 0]                             // 8 bits, RGBA, deflate, no filter, no interlace
        png += chunk("IHDR", ihdr)
        png += chunk("IDAT", zlibStored(raw))
        png += chunk("IEND", [])
        return png
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> Data {
        let typeBytes = Array(type.utf8)
        var out = Data(be32(UInt32(body.count)))
        out += typeBytes
        out += body
        out += be32(crc32(typeBytes + body))
        return out
    }

    /// A zlib stream whose deflate blocks are stored, not compressed.
    private static func zlibStored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]                     // deflate, 32K window, no preset dictionary
        var offset = 0
        repeat {
            let n = min(bytes.count - offset, 65_535)
            let last: UInt8 = offset + n >= bytes.count ? 1 : 0
            out.append(last)                                // BFINAL, BTYPE 00
            out += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += bytes[offset..<(offset + n)]
            offset += n
        } while offset < bytes.count
        out += be32(adler32(bytes))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}
