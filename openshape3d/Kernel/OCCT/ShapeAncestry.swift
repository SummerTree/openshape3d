//
//  ShapeAncestry.swift
//  openshape3d — kernel-history ancestry (docs/TOPO_NAMING_HISTORY_DESIGN.md
//  step 1)
//
//  Typed Swift face of `OCCTShapeHistory`: which input sub-shape each result
//  face came from, per OCCT's own Modified()/Generated() history. This is
//  the raw material element naming will consume — no naming decisions are
//  made here, and nothing consumes it in production yet.
//

import Foundation

/// Per-face ancestry of one kernel op's result.
nonisolated struct ShapeAncestry: Sendable, Equatable {

    nonisolated enum Relation: Int32, Sendable {
        /// The input face reaches the result untouched (same TShape).
        case same = 0
        case modified = 1
        case generated = 2
    }

    nonisolated enum InputKind: Int32, Sendable {
        case face = 0
        case edge = 1
    }

    /// One history edge. `resultFace` is 1-based into the result's indexed
    /// face map — the same numbering `renderMeshFaceChannel` and the health
    /// report use. `inputSubshape` is 1-based into input `inputOrdinal`'s
    /// map of `inputKind`, over the operand as the kernel consumed it.
    nonisolated struct Row: Sendable, Equatable {
        let resultFace: Int
        let inputOrdinal: Int
        let inputKind: InputKind
        let inputSubshape: Int
        let relation: Relation
    }

    let rows: [Row]
    /// A post-history heal rebuilt the result: surviving rows are valid, but
    /// some faces may have lost their ancestry. Absence of rows for a face
    /// always means "history doesn't know" — signatures stay the fallback.
    let truncatedByHeal: Bool

    /// Direct construction, for tests and future non-bridge derivations.
    init(rows: [Row], truncatedByHeal: Bool = false) {
        self.rows = rows
        self.truncatedByHeal = truncatedByHeal
    }

    init(_ history: OCCTShapeHistory) {
        truncatedByHeal = history.truncatedByHeal
        let values: [Int32] = history.rows.withUnsafeBytes {
            Array($0.bindMemory(to: Int32.self))
        }
        var rows: [Row] = []
        rows.reserveCapacity(values.count / 5)
        for base in stride(from: 0, to: (values.count / 5) * 5, by: 5) {
            guard let kind = InputKind(rawValue: values[base + 2]),
                  let relation = Relation(rawValue: values[base + 4]) else { continue }
            rows.append(Row(resultFace: Int(values[base]),
                            inputOrdinal: Int(values[base + 1]),
                            inputKind: kind,
                            inputSubshape: Int(values[base + 3]),
                            relation: relation))
        }
        self.rows = rows
    }

    /// All history edges landing on one result face (1-based).
    func ancestors(ofResultFace face: Int) -> [Row] {
        rows.filter { $0.resultFace == face }
    }

    /// The result faces that carry no ancestry at all — the honest holes a
    /// consumer must resolve by signature instead.
    func unknownFaces(resultFaceCount: Int) -> [Int] {
        let known = Set(rows.map(\.resultFace))
        return (1...max(1, resultFaceCount)).filter { !known.contains($0) }
    }
}

nonisolated extension OCCTKernel {

    /// `extrudeShape` that also reports each result face's ancestry.
    /// Extrude convention (see `OCCTBridge.h`): `inputOrdinal` = loop
    /// (0 outer, 1…N holes); walls are `(.edge, wireEdgeOrdinal, .generated)`,
    /// caps `(.face, 1 = start / 2 = end, .modified)`.
    static func extrudeShapeWithAncestry(
        outerLoop: [SIMD2<Double>], outerConic: ConicSpec? = nil,
        holes: [ExtrudeHole], zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>,
        outerSegments: [Profile.Segment] = []
    ) -> (handle: BRepHandle, ancestry: ShapeAncestry)? {
        let history = OCCTShapeHistory()
        guard let handle = extrudeShape(
            outerLoop: outerLoop, outerConic: outerConic, holes: holes,
            zMin: zMin, zMax: zMax, origin: origin, xAxis: xAxis,
            yAxis: yAxis, normal: normal, outerSegments: outerSegments,
            history: history) else { return nil }
        return (handle, ShapeAncestry(history))
    }

    /// `composedBooleanResult` that also reports ancestry — the feature
    /// replay's entry point (step 3). Same nil/failure semantics: nil means
    /// OCCT DECLINED (mesh-only operand), and the Euclid fallback then owns
    /// the result with no names. Input sub-shape indices are over the
    /// TRANSFORMED operands, whose indexed-map order matches the body-local
    /// shapes (the placing transform copies structure in order), so a
    /// body's own kernel-face name map keys still apply.
    static func composedBooleanResultWithAncestry(
        _ kind: BooleanKind, target: Body, tool: Body
    ) -> Result<(outcome: BooleanOutcome, ancestry: ShapeAncestry), OCCTOpError>? {
        guard useOCCTAsSourceOfTruth,
              let a0 = target.brep, let b0 = tool.brep,
              let a = transformed(a0, by: target.transform),
              let b = transformed(b0, by: tool.transform)
        else { return nil }
        return booleanResultWithAncestry(a, b, op: booleanOp(kind))
    }

    /// `booleanResult` that also reports each result face's kernel-history
    /// ancestry (input ordinal 0 = `a`, 1 = `b`). Identical geometry to
    /// `booleanResult` for identical inputs — ancestry is observation only.
    static func booleanResultWithAncestry(_ a: BRepHandle, _ b: BRepHandle, op: Int)
        -> Result<(outcome: BooleanOutcome, ancestry: ShapeAncestry), OCCTOpError> {
        let status = OCCTOpStatus()
        let history = OCCTShapeHistory()
        guard let shape = OCCTBridge.boolean(of: a.shape, with: b.shape,
                                             op: op, status: status,
                                             history: history) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(op: "boolean",
                                        inputs: [("a", a), ("b", b)],
                                        params: ["op": op], error: error)
            return .failure(error)
        }
        let solids = status.code == .multiSolid ? status.solidCount : 1
        return .success((BooleanOutcome(handle: BRepHandle(shape),
                                        solidCount: solids),
                         ShapeAncestry(history)))
    }
}
