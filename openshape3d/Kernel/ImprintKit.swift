//
//  ImprintKit.swift
//  openshape3d
//
//  Imprint Edge (spec §4.17): a sketch's curves, ready for the kernel to
//  split a body's faces along them. Each curve keeps its exact shape — lines
//  and arcs as themselves, a fit spline as the same B-spline a profile
//  builds — so an imprinted circle pulls out as a true cylinder.
//

import Foundation
import simd

nonisolated enum ImprintKit {

    /// Every non-construction curve of `sketch` as plane-local segments, in
    /// `Profile.Segment`'s exact-boundary form. Ellipses go as fine
    /// polylines, the one curve the kernel's segment format has no record for.
    static func segments(of sketch: Sketch) -> [Profile.Segment] {
        var out: [Profile.Segment] = []
        func polyline(_ points: [SIMD2<Double>], closed: Bool) {
            guard points.count >= 2 else { return }
            for i in 0..<(closed ? points.count : points.count - 1) {
                out.append(Profile.Segment(start: points[i], end: points[(i + 1) % points.count]))
            }
        }
        for entity in sketch.entities where !sketch.constructionEntityIDs.contains(entity.id) {
            switch entity {
            case let .line(_, a, b):
                out.append(Profile.Segment(start: a, end: b))
            case let .rect(_, lo, hi):
                polyline([lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)], closed: true)
            case let .circle(_, c, r):
                guard r > 1e-9 else { continue }
                let east = c + SIMD2(r, 0), west = c - SIMD2(r, 0)
                out.append(Profile.Segment(start: east, end: west, mid: c + SIMD2(0, r)))
                out.append(Profile.Segment(start: west, end: east, mid: c - SIMD2(0, r)))
            case let .arc(_, c, r, start, end):
                let sweep = SketchEntity.arcSweep(startAngle: start, endAngle: end)
                guard r > 1e-9, sweep > 1e-9 else { continue }
                func at(_ angle: Double) -> SIMD2<Double> {
                    SketchEntity.arcPoint(center: c, radius: r, angle: angle)
                }
                out.append(Profile.Segment(start: at(start), end: at(start + sweep),
                                           mid: at(start + sweep / 2)))
            case let .ellipse(_, c, rx, ry, rotation):
                polyline(SketchEntity.ellipsePoints(center: c, radiusX: rx, radiusY: ry,
                                                    rotation: rotation, segments: 96), closed: true)
            case let .polygon(_, c, r, sides, rotation):
                polyline(SketchEntity.polygonPoints(center: c, radius: r, sides: sides,
                                                    rotation: rotation), closed: true)
            case let .spline(_, points, closed):
                if points.count < 3 {
                    polyline(points, closed: false)
                } else {
                    out.append(Profile.Segment(start: points[0],
                                               end: closed ? points[0] : points[points.count - 1],
                                               controlPoints: points, closed: closed))
                }
            }
        }
        return out
    }

    /// `segments` re-expressed for a body placed at `transform`: the sketch
    /// plane carried into the body's own frame (where its B-rep lives), and
    /// the plane-local coordinates divided by the body's scale.
    static func bodyLocal(_ segments: [Profile.Segment], plane: SketchPlane,
                          transform: Transform3D) -> (segments: [Profile.Segment], plane: SketchPlane) {
        let inverse = transform.rotation.inverse
        let s = max(transform.scale, 1e-12)
        let local = SketchPlane(
            origin: inverse.act(plane.origin - transform.translation) / s,
            xAxis: simd_normalize(inverse.act(plane.xAxis)),
            yAxis: simd_normalize(inverse.act(plane.yAxis)))
        guard abs(s - 1) > 1e-12 else { return (segments, local) }
        let scaled = segments.map { seg in
            Profile.Segment(start: seg.start / s, end: seg.end / s, mid: seg.mid.map { $0 / s },
                            controlPoints: seg.controlPoints?.map { $0 / s }, closed: seg.closed)
        }
        return (scaled, local)
    }
}

// MARK: - Applying

nonisolated extension ImprintKit {

    enum Failure: Error, Equatable {
        /// The body has no B-rep: a mesh has no faces to split.
        case notAnalytic
        /// No curve of any sketch lies in a face of the body.
        case notOnBody
        case kernel(String)

        var message: String {
            switch self {
            case .notAnalytic:
                return "Imprint Edge needs a solid body — this one is a mesh, which has no faces to split."
            case .notOnBody:
                return "None of the sketch's curves lie on a face of the body. Draw the sketch on the face to imprint."
            case let .kernel(detail):
                return "The imprint failed: \(detail)"
            }
        }
    }

    /// `body` with its faces split along every sketch's curves — the shared
    /// step behind the Imprint Edge tool and its history replay. A sketch
    /// that misses the body is skipped as long as another one lands.
    static func imprint(_ body: Body, sketches: [Sketch], revision: UInt64)
        -> Result<(body: Body, ancestries: [ShapeAncestry]), Failure> {
        guard OCCTKernel.useOCCTAsSourceOfTruth, var brep = body.brep else {
            return .failure(.notAnalytic)
        }
        var ancestries: [ShapeAncestry] = []
        for sketch in sketches {
            let local = bodyLocal(segments(of: sketch), plane: sketch.plane, transform: body.transform)
            guard !local.segments.isEmpty else { continue }
            switch OCCTKernel.imprintResultWithAncestry(brep, segments: local.segments, plane: local.plane) {
            case let .success((handle, ancestry)):
                brep = handle
                ancestries.append(ancestry)
            case .failure(.noTargetMatched):
                continue
            case let .failure(error):
                return .failure(.kernel(error.message))
            }
        }
        guard !ancestries.isEmpty else { return .failure(.notOnBody) }
        var result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: body.euclidMesh(), revision: revision)
        guard result.adoptBRep(brep, keepingFaceRegions: true) else {
            return .failure(.kernel("the split solid could not be tessellated"))
        }
        return .success((result.keepingAppearance(of: body), ancestries))
    }
}
