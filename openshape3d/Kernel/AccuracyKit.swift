//
//  AccuracyKit.swift
//  openshape3d
//
//  How closely a modelled body matches a reference mesh — a 3D scan, a
//  supplier's STL, a previous revision. Two complementary measures:
//
//  1. ORTHOGRAPHIC OVERLAYS. Both bodies are projected along the standard
//     view directions (the Drawings' Front / Top / Right), their silhouettes
//     rasterised on one shared grid and compared: overlap over union (IoU),
//     the areas, and how far each outline sits from the other (the distance
//     transform of one outline read at the pixels of the other). The outlines
//     come back as closed loops in view millimetres, so the sheet, the
//     `/v1/accuracy` reply and an SVG report all draw the same lines.
//
//  2. SURFACE DEVIATION. Points sampled on one surface are measured to the
//     nearest point of the other (triangles in a uniform grid), both ways,
//     with the sign telling whether the sample lies outside (+) or inside (−)
//     the other body. Mean, RMS, 95th percentile, maximum, the share within a
//     tolerance, and a histogram for the chart.
//
//  Pure value math over world-space triangle soups (Foundation + simd only),
//  so the same code runs on the iPad, the Mac and in the browser.
//

import Foundation
import simd

// MARK: - Inputs

/// A body placed in the world: its render mesh with the transform applied.
nonisolated struct AccuracyMesh: Sendable {
    var positions: [SIMD3<Double>]
    var indices: [UInt32]

    init(positions: [SIMD3<Double>], indices: [UInt32]) {
        self.positions = positions
        self.indices = indices
    }

    init(body: Body) {
        let t = body.transform
        positions = body.render.positions.map { t.applying(to: SIMD3<Double>($0)) }
        indices = body.render.indices
    }

    var triangleCount: Int { indices.count / 3 }

    var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard let first = positions.first else { return nil }
        var lo = first, hi = first
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    func translated(by delta: SIMD3<Double>) -> AccuracyMesh {
        AccuracyMesh(positions: positions.map { $0 + delta }, indices: indices)
    }

    /// Signed-tetrahedron volume (the divergence theorem); meaningful only
    /// for a closed surface, see `isWatertight`.
    var volume: Double {
        var sum = 0.0
        var i = 0
        while i + 2 < indices.count {
            let a = positions[Int(indices[i])], b = positions[Int(indices[i + 1])], c = positions[Int(indices[i + 2])]
            sum += simd_dot(a, simd_cross(b, c))
            i += 3
        }
        return abs(sum) / 6
    }

    /// True when every edge is shared by exactly two triangles, after welding
    /// vertices that sit on the same point (a textured scan keeps its UV-seam
    /// splits, which are not holes).
    var isWatertight: Bool { openEdgeCount == 0 }

    var openEdgeCount: Int {
        guard !positions.isEmpty else { return 0 }
        let weld = weldedIndices()
        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(indices.count)
        var i = 0
        while i + 2 < weld.count {
            let v = [weld[i], weld[i + 1], weld[i + 2]]
            i += 3
            for k in 0..<3 {
                let a = v[k], b = v[(k + 1) % 3]
                if a == b { continue }
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                counts[key, default: 0] += 1
            }
        }
        return counts.values.reduce(0) { $0 + ($1 == 2 ? 0 : 1) }
    }

    /// Triangle indices with coincident vertices merged (within a millionth
    /// of the mesh's diagonal).
    func weldedIndices() -> [UInt32] {
        guard let b = bounds else { return indices }
        let quantum = max(simd_length(b.max - b.min) * 1e-6, 1e-9)
        var canonical: [SIMD3<Int64>: UInt32] = [:]
        canonical.reserveCapacity(positions.count)
        var remap = [UInt32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int64>(Int64((p.x / quantum).rounded()), Int64((p.y / quantum).rounded()),
                                   Int64((p.z / quantum).rounded()))
            if let existing = canonical[key] {
                remap[i] = existing
            } else {
                canonical[key] = UInt32(i)
                remap[i] = UInt32(i)
            }
        }
        return indices.map { remap[Int($0)] }
    }
}

/// How the model is moved onto the reference before comparing.
nonisolated enum AccuracyAlignment: String, Codable, CaseIterable, Sendable {
    /// Compare where the bodies sit — the model was built in place.
    case none
    /// Translate the model so the bounding-box centres coincide.
    case boundsCenter
    /// Translate the model so the footprints' centres (X, Z) and the bottoms
    /// (min Y) coincide — two parts standing on the ground.
    case base

    var title: String {
        switch self {
        case .none: "As placed"
        case .boundsCenter: "Centre the bounds"
        case .base: "Stand on the same base"
        }
    }
}

nonisolated struct AccuracyOptions: Sendable, Equatable {
    var views: [DrawingViewDirection] = [.front, .top, .right]
    /// Pixels along the longer side of the shared silhouette grid.
    var resolution: Int = 512
    /// A deviation at or under this counts as within tolerance (mm).
    var toleranceMM: Double = 1
    /// Surface samples per direction for the deviation.
    var maxSamples: Int = 20_000
    var alignment: AccuracyAlignment = .none
    /// False skips the surface deviation (the overlays alone — what a
    /// picture of one view needs).
    var includeDeviation: Bool = true

    init(views: [DrawingViewDirection] = [.front, .top, .right], resolution: Int = 512,
         toleranceMM: Double = 1, maxSamples: Int = 20_000, alignment: AccuracyAlignment = .none,
         includeDeviation: Bool = true) {
        self.views = views.isEmpty ? [.front, .top, .right] : views
        self.resolution = min(max(resolution, 32), 4096)
        self.toleranceMM = max(toleranceMM, 0)
        self.maxSamples = min(max(maxSamples, 100), 500_000)
        self.alignment = alignment
        self.includeDeviation = includeDeviation
    }
}

// MARK: - Results

/// A closed outline in view millimetres (right, up), as marching squares
/// traced it around a silhouette; holes are loops too.
nonisolated struct AccuracyOutline: Codable, Equatable, Sendable {
    var points: [SIMD2<Double>]
    var area: Double
}

nonisolated struct SilhouetteOverlay: Sendable {
    var view: DrawingViewDirection
    var width: Int
    var height: Int
    /// Millimetres per pixel.
    var pixelMM: Double
    /// View coordinates of the grid's lower-left corner; pixel (column c,
    /// row r) is centred at `origin + (c + 0.5, r + 0.5) · pixelMM`, rows
    /// counting UP.
    var origin: SIMD2<Double>
    /// One byte per pixel, row-major from the bottom row: 1 inside.
    var reference: [UInt8]
    var model: [UInt8]
    var referenceAreaMM2: Double
    var modelAreaMM2: Double
    var overlapAreaMM2: Double
    /// Overlap over union, 0…1.
    var iou: Double
    /// Pooled both ways: every outline pixel of each silhouette measured to
    /// the other's outline.
    var boundaryMeanMM: Double
    var boundaryRMSMM: Double
    var boundaryP95MM: Double
    var boundaryMaxMM: Double
    var referenceOutlines: [AccuracyOutline]
    var modelOutlines: [AccuracyOutline]

    /// Reference pixels the model misses, and model pixels outside the
    /// reference, as areas.
    var missingAreaMM2: Double { referenceAreaMM2 - overlapAreaMM2 }
    var excessAreaMM2: Double { modelAreaMM2 - overlapAreaMM2 }
}

nonisolated struct DeviationStats: Codable, Equatable, Sendable {
    var samples: Int
    var meanMM: Double
    /// Mean of the signed distances: positive when the samples sit outside
    /// the other surface on average (that body is the smaller one).
    var meanSignedMM: Double
    var rmsMM: Double
    var medianMM: Double
    var p95MM: Double
    var maxMM: Double
    /// Share of samples at or under the tolerance, 0…1.
    var withinTolerance: Double
    var histogram: [Int]
    var histogramBinMM: Double

    static let empty = DeviationStats(samples: 0, meanMM: 0, meanSignedMM: 0, rmsMM: 0, medianMM: 0,
                                      p95MM: 0, maxMM: 0, withinTolerance: 1, histogram: [], histogramBinMM: 0)
}

nonisolated struct AccuracyReport: Sendable {
    var options: AccuracyOptions
    var referenceTriangles: Int
    var modelTriangles: Int
    var referenceBounds: (min: SIMD3<Double>, max: SIMD3<Double>)
    var modelBounds: (min: SIMD3<Double>, max: SIMD3<Double>)
    /// The shift the alignment applied to the model.
    var appliedTranslation: SIMD3<Double>
    var referenceVolumeMM3: Double
    var modelVolumeMM3: Double
    var referenceWatertight: Bool
    var modelWatertight: Bool
    var overlays: [SilhouetteOverlay]
    /// Reference samples measured to the model surface.
    var referenceToModel: DeviationStats
    /// Model samples measured to the reference surface.
    var modelToReference: DeviationStats

    /// Mean IoU over the views, 0…1 — the one number for a headline.
    var overallIoU: Double {
        overlays.isEmpty ? 0 : overlays.map(\.iou).reduce(0, +) / Double(overlays.count)
    }

    /// Size differences per axis, model minus reference (mm).
    var extentDeltaMM: SIMD3<Double> {
        (modelBounds.max - modelBounds.min) - (referenceBounds.max - referenceBounds.min)
    }
}

// MARK: - The comparison

nonisolated enum AccuracyKit {

    static func compare(reference: AccuracyMesh, model rawModel: AccuracyMesh,
                        options: AccuracyOptions = AccuracyOptions()) -> AccuracyReport? {
        guard let rb = reference.bounds, let mb0 = rawModel.bounds,
              reference.triangleCount > 0, rawModel.triangleCount > 0 else { return nil }
        let shift = alignmentShift(options.alignment, reference: rb, model: mb0)
        let model = shift == .zero ? rawModel : rawModel.translated(by: shift)
        let mb = model.bounds ?? mb0

        let overlays = options.views.map { view in
            overlay(reference: reference, model: model, view: view, resolution: options.resolution)
        }
        var referenceToModel = DeviationStats.empty, modelToReference = DeviationStats.empty
        if options.includeDeviation {
            referenceToModel = deviation(of: reference, to: model, grid: SurfaceGrid(mesh: model), options: options)
            modelToReference = deviation(of: model, to: reference, grid: SurfaceGrid(mesh: reference), options: options)
        }

        return AccuracyReport(
            options: options,
            referenceTriangles: reference.triangleCount, modelTriangles: model.triangleCount,
            referenceBounds: rb, modelBounds: mb, appliedTranslation: shift,
            referenceVolumeMM3: reference.volume, modelVolumeMM3: model.volume,
            referenceWatertight: reference.isWatertight, modelWatertight: model.isWatertight,
            overlays: overlays, referenceToModel: referenceToModel, modelToReference: modelToReference)
    }

    static func alignmentShift(_ alignment: AccuracyAlignment,
                               reference: (min: SIMD3<Double>, max: SIMD3<Double>),
                               model: (min: SIMD3<Double>, max: SIMD3<Double>)) -> SIMD3<Double> {
        switch alignment {
        case .none:
            return .zero
        case .boundsCenter:
            return (reference.min + reference.max) * 0.5 - (model.min + model.max) * 0.5
        case .base:
            let rc = (reference.min + reference.max) * 0.5, mc = (model.min + model.max) * 0.5
            return SIMD3(rc.x - mc.x, reference.min.y - model.min.y, rc.z - mc.z)
        }
    }

    // MARK: Silhouettes

    static func overlay(reference: AccuracyMesh, model: AccuracyMesh,
                        view: DrawingViewDirection, resolution: Int) -> SilhouetteOverlay {
        let basis = view.basis
        func flat(_ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(p, basis.right), simd_dot(p, basis.up)) }
        let rp = reference.positions.map(flat), mp = model.positions.map(flat)
        var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
        for p in rp { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        for p in mp { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let extent = hi - lo
        let longest = max(extent.x, extent.y, 1e-9)
        // A one-pixel margin all round, so an outline never touches the edge.
        let pixelMM = longest / Double(max(resolution - 2, 1))
        let width = Int((extent.x / pixelMM).rounded(.up)) + 2
        let height = Int((extent.y / pixelMM).rounded(.up)) + 2
        let origin = lo - SIMD2(repeating: pixelMM)

        let referenceMask = rasterize(points: rp, indices: reference.indices, origin: origin,
                                      pixelMM: pixelMM, width: width, height: height)
        let modelMask = rasterize(points: mp, indices: model.indices, origin: origin,
                                  pixelMM: pixelMM, width: width, height: height)
        var referenceCount = 0, modelCount = 0, overlap = 0
        for i in 0..<(width * height) {
            let r = referenceMask[i], m = modelMask[i]
            referenceCount += Int(r); modelCount += Int(m); overlap += Int(r & m)
        }
        let union = referenceCount + modelCount - overlap
        let area = pixelMM * pixelMM

        // Boundary deviation: each outline's pixels against the distance
        // transform of the other outline, pooled.
        let referenceEdge = outlinePixels(referenceMask, width: width, height: height)
        let modelEdge = outlinePixels(modelMask, width: width, height: height)
        let toModel = distanceTransform(modelEdge, width: width, height: height)
        let toReference = distanceTransform(referenceEdge, width: width, height: height)
        var distances: [Double] = []
        distances.reserveCapacity(width + height)
        for i in 0..<(width * height) {
            if referenceEdge[i] != 0 { distances.append(toModel[i] * pixelMM) }
            if modelEdge[i] != 0 { distances.append(toReference[i] * pixelMM) }
        }
        let stats = summarize(distances)

        return SilhouetteOverlay(
            view: view, width: width, height: height, pixelMM: pixelMM, origin: origin,
            reference: referenceMask, model: modelMask,
            referenceAreaMM2: Double(referenceCount) * area, modelAreaMM2: Double(modelCount) * area,
            overlapAreaMM2: Double(overlap) * area,
            iou: union > 0 ? Double(overlap) / Double(union) : 0,
            boundaryMeanMM: stats.mean, boundaryRMSMM: stats.rms, boundaryP95MM: stats.p95, boundaryMaxMM: stats.max,
            referenceOutlines: outlines(of: referenceMask, width: width, height: height, origin: origin, pixelMM: pixelMM),
            modelOutlines: outlines(of: modelMask, width: width, height: height, origin: origin, pixelMM: pixelMM))
    }

    /// Fill every triangle's pixels (centre-inside test with a half-pixel
    /// tolerance, so thin slivers still mark the pixels they cross).
    static func rasterize(points: [SIMD2<Double>], indices: [UInt32], origin: SIMD2<Double>,
                          pixelMM: Double, width: Int, height: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        let inv = 1 / pixelMM
        var i = 0
        while i + 2 < indices.count {
            let a = (points[Int(indices[i])] - origin) * inv
            let b = (points[Int(indices[i + 1])] - origin) * inv
            let c = (points[Int(indices[i + 2])] - origin) * inv
            i += 3
            let minX = max(Int(min(a.x, b.x, c.x).rounded(.down)), 0)
            let maxX = min(Int(max(a.x, b.x, c.x).rounded(.up)), width - 1)
            let minY = max(Int(min(a.y, b.y, c.y).rounded(.down)), 0)
            let maxY = min(Int(max(a.y, b.y, c.y).rounded(.up)), height - 1)
            if minX > maxX || minY > maxY { continue }
            var area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            var p0 = a, p1 = b, p2 = c
            if area < 0 { swap(&p1, &p2); area = -area }
            // Edge-on (zero projected area): nothing to fill. A solid's
            // neighbouring faces cover the same outline, and a flat sheet
            // seen edge-on really is a line — area none. Marking its pixels
            // would also spill one pixel past the silhouette, onto the grid's
            // empty border, and an outline that touches the border cannot
            // close.
            if area < 1e-12 { continue }
            // Pixel centres inside, with a hair of slack per edge (relative
            // to its length) so a centre exactly on a shared edge belongs
            // to both neighbours rather than neither.
            let t0 = 1e-7 * simd_length(p1 - p0), t1 = 1e-7 * simd_length(p2 - p1), t2 = 1e-7 * simd_length(p0 - p2)
            for y in minY...maxY {
                let py = Double(y) + 0.5
                for x in minX...maxX {
                    let px = Double(x) + 0.5
                    let w0 = (p1.x - p0.x) * (py - p0.y) - (p1.y - p0.y) * (px - p0.x)
                    let w1 = (p2.x - p1.x) * (py - p1.y) - (p2.y - p1.y) * (px - p1.x)
                    let w2 = (p0.x - p2.x) * (py - p2.y) - (p0.y - p2.y) * (px - p2.x)
                    if w0 >= -t0, w1 >= -t1, w2 >= -t2 {
                        mask[y * width + x] = 1
                    }
                }
            }
        }
        return mask
    }

    /// Inside pixels with at least one 4-neighbour outside (or off the grid).
    static func outlinePixels(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var edge = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard mask[i] != 0 else { continue }
                if x == 0 || y == 0 || x == width - 1 || y == height - 1
                    || mask[i - 1] == 0 || mask[i + 1] == 0 || mask[i - width] == 0 || mask[i + width] == 0 {
                    edge[i] = 1
                }
            }
        }
        return edge
    }

    /// Exact Euclidean distance (in pixels) from every pixel to the nearest
    /// set pixel — Felzenszwalb & Huttenlocher's two-pass parabola envelope.
    static func distanceTransform(_ set: [UInt8], width: Int, height: Int) -> [Double] {
        let inf = Double(width + height) * Double(width + height)
        var f = set.map { $0 != 0 ? 0.0 : inf }
        var column = [Double](repeating: 0, count: max(height, width))
        var out = [Double](repeating: 0, count: max(height, width))
        var v = [Int](repeating: 0, count: max(height, width))
        var z = [Double](repeating: 0, count: max(height, width) + 1)

        func pass(_ n: Int) {
            var k = 0
            v[0] = 0
            z[0] = -.infinity
            z[1] = .infinity
            for q in 1..<n {
                var s = ((column[q] + Double(q * q)) - (column[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
                while s <= z[k] {
                    k -= 1
                    s = ((column[q] + Double(q * q)) - (column[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = .infinity
            }
            k = 0
            for q in 0..<n {
                while z[k + 1] < Double(q) { k += 1 }
                let d = Double(q - v[k])
                out[q] = d * d + column[v[k]]
            }
        }

        // Columns, then rows.
        if height > 1 {
            for x in 0..<width {
                for y in 0..<height { column[y] = f[y * width + x] }
                pass(height)
                for y in 0..<height { f[y * width + x] = out[y] }
            }
        }
        if width > 1 {
            for y in 0..<height {
                for x in 0..<width { column[x] = f[y * width + x] }
                pass(width)
                for x in 0..<width { f[y * width + x] = out[x] }
            }
        }
        return f.map { $0 >= inf ? .infinity : $0.squareRoot() }
    }

    /// Marching squares over the pixel centres, chained into closed loops in
    /// view millimetres. Every crossing sits on an edge between two pixel
    /// centres, so crossings are keyed by that edge (two integers and an
    /// orientation) and the loops are walked in linear time. Saddles are
    /// split, so every crossing meets exactly two segments and the walks
    /// always close.
    static func outlines(of mask: [UInt8], width: Int, height: Int,
                         origin: SIMD2<Double>, pixelMM: Double) -> [AccuracyOutline] {
        guard width > 1, height > 1 else { return [] }
        // A crossing on the horizontal edge from centre (x, y) to (x + 1, y)
        // is `h(x, y)`; on the vertical edge from (x, y) to (x, y + 1) it is
        // `v(x, y)`. Keys pack the three into one integer.
        @inline(__always) func h(_ x: Int, _ y: Int) -> Int { (y * width + x) << 1 }
        @inline(__always) func v(_ x: Int, _ y: Int) -> Int { ((y * width + x) << 1) | 1 }
        var neighbours: [Int: (Int, Int)] = [:]
        func link(_ a: Int, _ b: Int) {
            for (from, to) in [(a, b), (b, a)] {
                if var pair = neighbours[from] {
                    if pair.0 == -1 { pair.0 = to } else { pair.1 = to }
                    neighbours[from] = pair
                } else {
                    neighbours[from] = (to, -1)
                }
            }
        }
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let bl = mask[y * width + x], br = mask[y * width + x + 1]
                let tl = mask[(y + 1) * width + x], tr = mask[(y + 1) * width + x + 1]
                let code = Int(bl) | Int(br) << 1 | Int(tr) << 2 | Int(tl) << 3
                if code == 0 || code == 15 { continue }
                let bottom = h(x, y), top = h(x, y + 1), left = v(x, y), right = v(x + 1, y)
                switch code {
                case 1, 14: link(left, bottom)
                case 2, 13: link(bottom, right)
                case 3, 12: link(left, right)
                case 4, 11: link(right, top)
                case 6, 9: link(bottom, top)
                case 7, 8: link(top, left)
                case 5: link(left, top); link(bottom, right)
                case 10: link(left, bottom); link(top, right)
                default: break
                }
            }
        }
        func point(_ key: Int) -> SIMD2<Double> {
            let cell = key >> 1
            let x = Double(cell % width), y = Double(cell / width)
            let horizontal = key & 1 == 0
            return origin + SIMD2(x + (horizontal ? 1.0 : 0.5), y + (horizontal ? 0.5 : 1.0)) * pixelMM
        }
        var visited = Set<Int>()
        visited.reserveCapacity(neighbours.count)
        var loops: [SectionLoop] = []
        for start in neighbours.keys where !visited.contains(start) {
            var chain: [SIMD2<Double>] = []
            var previous = -1
            var current = start
            while !visited.contains(current) {
                visited.insert(current)
                chain.append(point(current))
                guard let pair = neighbours[current] else { break }
                let next = pair.0 == previous ? pair.1 : pair.0
                if next == -1 { break }
                previous = current
                current = next
            }
            guard chain.count >= 3, current == start else { continue }
            let simplified = SectionKit.mergeCollinear(chain, closed: true, tolerance: pixelMM * 1e-3)
            guard simplified.count >= 3 else { continue }
            loops.append(SectionLoop(closed: true, points: simplified, area: Profile.signedArea(simplified)))
        }
        loops.sort { abs($0.area) > abs($1.area) }
        // Marching squares hands the pieces over unordered, so a chain's
        // direction is whatever the chaining found first. Orient by nesting:
        // an outer loop runs counter-clockwise (positive area), a hole inside
        // it clockwise (negative), an island inside the hole positive again.
        return loops.map { loop in
            let probe = loop.points[0]
            let depth = loops.filter { other in
                other.points.count >= 3 && other.points != loop.points && contains(other.points, probe)
            }.count
            let wantPositive = depth % 2 == 0
            if (loop.area > 0) == wantPositive {
                return AccuracyOutline(points: loop.points, area: loop.area)
            }
            return AccuracyOutline(points: loop.points.reversed(), area: -loop.area)
        }
    }

    /// Even–odd point-in-polygon.
    static func contains(_ polygon: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: Surface deviation

    /// Samples of `mesh`'s surface: its vertices (thinned to the budget), and
    /// triangle centroids when the vertices alone are too few.
    static func samplePoints(of mesh: AccuracyMesh, limit: Int) -> [SIMD3<Double>] {
        let used = Set(mesh.indices)
        var points = mesh.positions.enumerated().filter { used.contains(UInt32($0.offset)) }.map(\.element)
        if points.count < limit / 2 {
            var i = 0
            while i + 2 < mesh.indices.count {
                points.append((mesh.positions[Int(mesh.indices[i])] + mesh.positions[Int(mesh.indices[i + 1])]
                               + mesh.positions[Int(mesh.indices[i + 2])]) / 3)
                i += 3
            }
        }
        guard points.count > limit else { return points }
        let stride = Double(points.count) / Double(limit)
        return (0..<limit).map { points[Int(Double($0) * stride)] }
    }

    static func deviation(of mesh: AccuracyMesh, to target: AccuracyMesh, grid: SurfaceGrid,
                          options: AccuracyOptions) -> DeviationStats {
        let samples = samplePoints(of: mesh, limit: options.maxSamples)
        guard !samples.isEmpty else { return .empty }
        var signed: [Double] = []
        signed.reserveCapacity(samples.count)
        for p in samples {
            if let hit = grid.nearest(to: p) { signed.append(hit.signedDistance) }
        }
        guard !signed.isEmpty else { return .empty }
        let unsigned = signed.map(abs)
        let s = summarize(unsigned)
        let sorted = unsigned.sorted()
        let median = sorted[sorted.count / 2]
        let within = Double(unsigned.filter { $0 <= options.toleranceMM }.count) / Double(unsigned.count)
        // Histogram: 24 bins up to the larger of 3 tolerances and the maximum.
        let bins = 24
        let top = max(s.max, options.toleranceMM * 3, 1e-9)
        let binMM = top / Double(bins)
        var histogram = [Int](repeating: 0, count: bins)
        for d in unsigned { histogram[min(Int(d / binMM), bins - 1)] += 1 }
        return DeviationStats(
            samples: signed.count, meanMM: s.mean, meanSignedMM: signed.reduce(0, +) / Double(signed.count),
            rmsMM: s.rms, medianMM: median, p95MM: s.p95, maxMM: s.max,
            withinTolerance: within, histogram: histogram, histogramBinMM: binMM)
    }

    static func summarize(_ values: [Double]) -> (mean: Double, rms: Double, p95: Double, max: Double) {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return (0, 0, 0, 0) }
        let n = Double(finite.count)
        let mean = finite.reduce(0, +) / n
        let rms = (finite.reduce(0) { $0 + $1 * $1 } / n).squareRoot()
        let sorted = finite.sorted()
        let p95 = sorted[min(Int((Double(sorted.count - 1) * 0.95).rounded()), sorted.count - 1)]
        return (mean, rms, p95, sorted[sorted.count - 1])
    }
}

// MARK: - Nearest point on a triangle soup

/// Triangles bucketed on a uniform grid, for nearest-point queries.
nonisolated struct SurfaceGrid: Sendable {
    private struct Triangle {
        var a, b, c: SIMD3<Double>
        var normal: SIMD3<Double>
    }
    private var triangles: [Triangle] = []
    /// Compressed rows: the triangles of cell `c` are
    /// `entries[cellStart[c] ..< cellStart[c + 1]]`.
    private var cellStart: [Int32] = [0]
    private var entries: [Int32] = []
    private var lo = SIMD3<Double>(repeating: 0)
    private var cell = 1.0
    private var dims = SIMD3<Int>(repeating: 1)

    init(mesh: AccuracyMesh) {
        guard let b = mesh.bounds, mesh.triangleCount > 0 else { return }
        let extent = b.max - b.min
        let diagonal = max(simd_length(extent), 1e-9)
        // Cells sized to the mesh's density — about two triangles' worth
        // across — so a query touches a handful of triangles, not hundreds;
        // between 24 and 160 cells across the diagonal.
        let across = min(max(cbrt(Double(mesh.triangleCount)) * 2.2, 24), 160)
        cell = max(diagonal / across, 1e-6)
        lo = b.min - SIMD3(repeating: cell * 0.5)
        let hi = b.max + SIMD3(repeating: cell * 0.5)
        dims = SIMD3(Int(((hi.x - lo.x) / cell).rounded(.up)) + 1, Int(((hi.y - lo.y) / cell).rounded(.up)) + 1,
                     Int(((hi.z - lo.z) / cell).rounded(.up)) + 1)
        let cellCount = dims.x * dims.y * dims.z
        triangles.reserveCapacity(mesh.triangleCount)
        var ranges: [(SIMD3<Int>, SIMD3<Int>)] = []
        ranges.reserveCapacity(mesh.triangleCount)
        var counts = [Int32](repeating: 0, count: cellCount + 1)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[i])], bb = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            i += 3
            let n = simd_cross(bb - a, c - a)
            let length = simd_length(n)
            triangles.append(Triangle(a: a, b: bb, c: c, normal: length > 1e-18 ? n / length : .zero))
            let tmin = cellOf(simd_min(simd_min(a, bb), c)), tmax = cellOf(simd_max(simd_max(a, bb), c))
            ranges.append((tmin, tmax))
            for z in tmin.z...tmax.z { for y in tmin.y...tmax.y { for x in tmin.x...tmax.x {
                counts[(z * dims.y + y) * dims.x + x + 1] += 1
            } } }
        }
        // Prefix sums give each cell's start; a second pass fills in place.
        for c in 1...cellCount { counts[c] += counts[c - 1] }
        cellStart = counts
        entries = [Int32](repeating: 0, count: Int(counts[cellCount]))
        var fill = counts
        for (t, range) in ranges.enumerated() {
            for z in range.0.z...range.1.z { for y in range.0.y...range.1.y { for x in range.0.x...range.1.x {
                let c = (z * dims.y + y) * dims.x + x
                entries[Int(fill[c])] = Int32(t)
                fill[c] += 1
            } } }
        }
    }

    private func cellOf(_ p: SIMD3<Double>) -> SIMD3<Int> {
        let c = (p - lo) / cell
        return SIMD3(min(max(Int(c.x.rounded(.down)), 0), dims.x - 1),
                     min(max(Int(c.y.rounded(.down)), 0), dims.y - 1),
                     min(max(Int(c.z.rounded(.down)), 0), dims.z - 1))
    }

    nonisolated struct Hit: Sendable {
        var point: SIMD3<Double>
        var distance: Double
        /// Positive outside the surface (along the triangle's normal).
        var signedDistance: Double
    }

    /// The closest point of the soup to `p`, searching outward ring by ring
    /// until the ring itself is farther than the best candidate.
    func nearest(to p: SIMD3<Double>) -> Hit? {
        guard !triangles.isEmpty else { return nil }
        let centre = cellOf(p)
        var best: Hit?
        var bestSquared = Double.infinity
        let maxRing = max(dims.x, dims.y, dims.z)
        var ring = 0
        while ring <= maxRing {
            // Everything in this ring is at least (ring − 1) cells away.
            let ringDistance = Double(ring - 1) * cell
            if ring > 0, ringDistance * ringDistance > bestSquared { break }
            let zs = max(centre.z - ring, 0)...min(centre.z + ring, dims.z - 1)
            let ys = max(centre.y - ring, 0)...min(centre.y + ring, dims.y - 1)
            let xs = max(centre.x - ring, 0)...min(centre.x + ring, dims.x - 1)
            var any = false
            for z in zs { for y in ys { for x in xs {
                let onShell = abs(z - centre.z) == ring || abs(y - centre.y) == ring || abs(x - centre.x) == ring
                guard onShell else { continue }
                any = true
                let c = (z * dims.y + y) * dims.x + x
                for e in Int(cellStart[c])..<Int(cellStart[c + 1]) {
                    let tri = triangles[Int(entries[e])]
                    let q = Self.closestPoint(on: tri.a, tri.b, tri.c, to: p)
                    let d2 = simd_length_squared(q - p)
                    if d2 < bestSquared {
                        bestSquared = d2
                        let d = d2.squareRoot()
                        let side = simd_dot(p - q, tri.normal)
                        best = Hit(point: q, distance: d, signedDistance: side >= 0 ? d : -d)
                    }
                }
            } } }
            if !any, ring > 0, zs.count * ys.count * xs.count == dims.x * dims.y * dims.z { break }
            ring += 1
        }
        return best
    }

    /// Ericson, Real-Time Collision Detection 5.1.5.
    static func closestPoint(on a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                             to p: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return a + ab * v
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return a + ac * w
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + (c - b) * w
        }
        let sum = va + vb + vc
        guard abs(sum) > 1e-300 else { return a }      // a degenerate (zero-area) triangle
        let denom = 1 / sum
        let v = vb * denom, w = vc * denom
        return a + ab * v + ac * w
    }
}

/// A comparison the agent bridge asks Views ▸ Accuracy Report… to run as it
/// opens (`view.accuracyReport` over exec): the sheet picks these bodies and
/// compares at once, so a person watching sees the report appear.
nonisolated struct AccuracyReportRequest: Sendable, Equatable {
    var reference: BodyID
    var model: BodyID
    var toleranceMM: Double
}

// MARK: - On the wire

/// The report as JSON carries it (`/v1/accuracy`, the `accuracy` MCP op,
/// the sheet's Copy JSON): every number and the outlines, never the pixel
/// masks (an outline is a few hundred points; a mask is a megabyte).
nonisolated struct AccuracyReportWire: Codable, Sendable {
    nonisolated struct Bounds: Codable, Sendable {
        var min: [Double]
        var max: [Double]
        var sizeMM: [Double]
    }
    nonisolated struct Options: Codable, Sendable {
        var views: [String]
        var resolution: Int
        var toleranceMM: Double
        var maxSamples: Int
        var alignment: String
    }
    nonisolated struct Overlay: Codable, Sendable {
        var view: String
        var width: Int
        var height: Int
        var pixelMM: Double
        var origin: [Double]
        var referenceAreaMM2: Double
        var modelAreaMM2: Double
        var overlapAreaMM2: Double
        var missingAreaMM2: Double
        var excessAreaMM2: Double
        var iou: Double
        var boundaryMeanMM: Double
        var boundaryRMSMM: Double
        var boundaryP95MM: Double
        var boundaryMaxMM: Double
        var referenceOutlines: [AccuracyOutline]
        var modelOutlines: [AccuracyOutline]
    }

    var options: Options
    var referenceTriangles: Int
    var modelTriangles: Int
    var referenceBounds: Bounds
    var modelBounds: Bounds
    var extentDeltaMM: [Double]
    var appliedTranslation: [Double]
    var referenceVolumeMM3: Double
    var modelVolumeMM3: Double
    /// model / reference; meaningful when both are watertight.
    var volumeRatio: Double
    var referenceWatertight: Bool
    var modelWatertight: Bool
    var overallIoU: Double
    var overlays: [Overlay]
    var referenceToModel: DeviationStats
    var modelToReference: DeviationStats
    var summary: String
}

nonisolated extension AccuracyReport {

    var wire: AccuracyReportWire {
        func bounds(_ b: (min: SIMD3<Double>, max: SIMD3<Double>)) -> AccuracyReportWire.Bounds {
            let size = b.max - b.min
            return .init(min: [b.min.x, b.min.y, b.min.z], max: [b.max.x, b.max.y, b.max.z],
                         sizeMM: [size.x, size.y, size.z])
        }
        let delta = extentDeltaMM
        return AccuracyReportWire(
            options: .init(views: options.views.map(\.rawValue), resolution: options.resolution,
                           toleranceMM: options.toleranceMM, maxSamples: options.maxSamples,
                           alignment: options.alignment.rawValue),
            referenceTriangles: referenceTriangles, modelTriangles: modelTriangles,
            referenceBounds: bounds(referenceBounds), modelBounds: bounds(modelBounds),
            extentDeltaMM: [delta.x, delta.y, delta.z],
            appliedTranslation: [appliedTranslation.x, appliedTranslation.y, appliedTranslation.z],
            referenceVolumeMM3: referenceVolumeMM3, modelVolumeMM3: modelVolumeMM3,
            volumeRatio: referenceVolumeMM3 > 0 ? modelVolumeMM3 / referenceVolumeMM3 : 0,
            referenceWatertight: referenceWatertight, modelWatertight: modelWatertight,
            overallIoU: overallIoU,
            overlays: overlays.map { o in
                .init(view: o.view.rawValue, width: o.width, height: o.height, pixelMM: o.pixelMM,
                      origin: [o.origin.x, o.origin.y],
                      referenceAreaMM2: o.referenceAreaMM2, modelAreaMM2: o.modelAreaMM2,
                      overlapAreaMM2: o.overlapAreaMM2, missingAreaMM2: o.missingAreaMM2,
                      excessAreaMM2: o.excessAreaMM2, iou: o.iou,
                      boundaryMeanMM: o.boundaryMeanMM, boundaryRMSMM: o.boundaryRMSMM,
                      boundaryP95MM: o.boundaryP95MM, boundaryMaxMM: o.boundaryMaxMM,
                      referenceOutlines: o.referenceOutlines, modelOutlines: o.modelOutlines)
            },
            referenceToModel: referenceToModel, modelToReference: modelToReference,
            summary: summary)
    }

    /// One paragraph in the person's terms — what an assistant reports back.
    var summary: String {
        func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
        func mm(_ x: Double) -> String { String(format: "%.2f mm", x) }
        var parts: [String] = []
        let views = overlays.map { "\($0.view.title.lowercased()) \(pct($0.iou))" }.joined(separator: ", ")
        parts.append("Silhouette overlap (IoU): \(views); mean \(pct(overallIoU)).")
        if let worst = overlays.max(by: { $0.boundaryP95MM < $1.boundaryP95MM }) {
            parts.append("Outlines sit \(mm(overlays.map(\.boundaryMeanMM).reduce(0, +) / Double(max(overlays.count, 1)))) "
                         + "apart on average, 95% within \(mm(worst.boundaryP95MM)) (\(worst.view.title.lowercased()) view is the widest).")
        }
        let r = referenceToModel
        parts.append("Reference surface to model: mean \(mm(r.meanMM)), 95% within \(mm(r.p95MM)), max \(mm(r.maxMM)); "
                     + "\(pct(r.withinTolerance)) of \(r.samples) points within \(mm(options.toleranceMM)); "
                     + "bias \(String(format: "%+.2f mm", r.meanSignedMM)) "
                     + (r.meanSignedMM > 0 ? "(the model is slightly undersized)." : "(the model is slightly oversized)."))
        let m = modelToReference
        parts.append("Model surface to reference: mean \(mm(m.meanMM)), 95% within \(mm(m.p95MM)), max \(mm(m.maxMM)).")
        let d = extentDeltaMM
        parts.append("Size (model − reference): \(String(format: "%+.1f × %+.1f × %+.1f mm", d.x, d.y, d.z)) "
                     + "(W × H × D).")
        if referenceWatertight && modelWatertight {
            parts.append("Volume: model is \(pct(referenceVolumeMM3 > 0 ? modelVolumeMM3 / referenceVolumeMM3 : 0)) of the reference.")
        } else if !referenceWatertight {
            parts.append("The reference mesh is open (a scan with holes), so its volume is not compared.")
        }
        return parts.joined(separator: " ")
    }
}
