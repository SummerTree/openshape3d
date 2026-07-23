//
//  SketchSolverBridge.swift
//  openshape3d
//
//  Bridges the symbolic sketch model (entities + SketchConstraint +
//  SketchDimension) to the numeric Levenberg–Marquardt solver
//  (`ConstraintSolver` / `ConstraintResidual`). It:
//
//   1. Collects each entity's mutable points into a flat variable vector where
//      2D point `i` occupies indices (2i, 2i+1); circle/arc/polygon radii become
//      scalar variables appended after all points.
//   2. WELDS points that are coincident — either joined by an explicit
//      `.coincident` constraint or lying within 1e-6 of each other — so they
//      share one variable pair and the solver moves them together.
//   3. Lowers each SketchConstraint / SketchDimension to the matching
//      `ConstraintResidual` struct, solves, and writes the solved values back
//      into a NEW `[SketchEntity]` (same IDs).
//
//  Degrees of freedom and per-entity fully-defined state are derived from the
//  null space of the numeric constraint Jacobian at the solution (see
//  `nullSpaceAnalysis`).
//
//  Scope notes (v1):
//   - Arc / ellipse angles and ellipse radii are NOT solve variables; only arc
//     & polygon centers and their radii move. Arc endpoints are therefore not
//     welded (documented limitation).
//   - `.coincident` between two points welds them; `.coincident` of a point to a
//     whole line is lowered to a `ColinearPointConstraint` (point-on-line).
//
//  nonisolated + Double math to match the kernel.
//

import Foundation
import simd

nonisolated enum SketchSolverBridge {

    // MARK: - Public API

    /// Solve the sketch. When `movingEntity`/`dragTarget` are supplied, the
    /// moved entity's point NEAREST the drag target is pulled toward it with a
    /// transient `FixedPointConstraint` (drag-to-solve), while the rest of the
    /// geometry follows. Returns new entities (same IDs) and the sketch's
    /// STRUCTURAL degrees of freedom (0 = fully defined), independent of any
    /// transient drag constraint.
    static func solve(
        _ sketch: Sketch,
        movingEntity: UUID?,
        dragTarget: SIMD2<Double>?
    ) -> (entities: [SketchEntity], dof: Int) {
        let sys = buildSystem(from: sketch, movingEntity: movingEntity, dragTarget: dragTarget)
        guard !sys.initial.isEmpty else { return (sketch.entities, 0) }

        let result = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.solveConstraints
        )
        let solved = result.variables
        let analysis = nullSpaceAnalysis(sys, at: solved)
        let newEntities = writeBack(sketch.entities, sys: sys, vars: solved)
        return (newEntities, analysis.dof)
    }

    /// Residual norm of the sketch's structural constraint/dimension system at
    /// its solved state. ~0 means every constraint is mutually satisfiable; a
    /// value above a small tolerance signals a CONFLICTING (over-constrained)
    /// system the solver cannot satisfy. Used to refuse an over-constraining
    /// edit before it corrupts the sketch. Ignores any transient drag target.
    static func residualNorm(_ sketch: Sketch) -> Double {
        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)
        guard !sys.initial.isEmpty, !sys.structural.isEmpty else { return 0 }
        let result = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.structural
        )
        return result.residualNorm
    }

    /// Per-entity fully-defined state: `true` when every variable the entity
    /// owns (its point coordinates + radius scalar) is determined — i.e. covered
    /// by the constraint Jacobian's rank (no null-space motion changes it).
    /// Heuristic: an entity variable is under-defined when it has a non-zero
    /// component in any null-space direction of the Jacobian at the solution.
    static func entityStates(_ sketch: Sketch) -> [UUID: Bool] {
        var out: [UUID: Bool] = [:]
        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)
        guard !sys.initial.isEmpty else {
            for e in sketch.entities { out[e.id] = true }
            return out
        }
        let solved = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.solveConstraints
        ).variables
        let analysis = nullSpaceAnalysis(sys, at: solved)
        for e in sketch.entities {
            out[e.id] = entityDetermined(e, sys: sys, determined: analysis.determined)
        }
        return out
    }

    // MARK: - System model

    private struct SlotKey: Hashable {
        let entityID: UUID
        let role: PointRole
    }

    private struct RawSlot {
        let entityID: UUID
        let role: PointRole
        let position: SIMD2<Double>
        let endpointLike: Bool
    }

    /// The lowered numeric problem plus the maps needed to write results back
    /// and to analyse per-entity DOF.
    private struct System {
        var initial: [Double]
        var fixed: Set<Int>
        var pointCount: Int
        var pointIndex: [SlotKey: Int]
        var radiusVar: [UUID: Int]
        /// Residuals for constraints + dimensions ONLY (no transient drag).
        var structural: [any ConstraintResidual]
        /// `structural` plus the transient drag constraint (used for the solve).
        var solveConstraints: [any ConstraintResidual]
        var entityPoints: [UUID: [Int]]
    }

    // MARK: - Entity point / scalar enumeration

    private static func mutableSlots(_ e: SketchEntity) -> [RawSlot] {
        switch e {
        case let .line(id, a, b):
            return [RawSlot(entityID: id, role: .endpointA, position: a, endpointLike: true),
                    RawSlot(entityID: id, role: .endpointB, position: b, endpointLike: true)]
        case let .rect(id, mn, mx):
            return [RawSlot(entityID: id, role: .endpointA, position: mn, endpointLike: true),
                    RawSlot(entityID: id, role: .endpointB, position: mx, endpointLike: true)]
        case let .circle(id, c, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .arc(id, c, _, _, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .ellipse(id, c, _, _, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .polygon(id, c, _, _, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .spline(id, points, closed):
            // Expose the OPEN spline's ends so it can be constrained/welded to
            // neighbouring geometry like a line. Interior fit points are not
            // solver variables yet (spec §1.4 spline constraints are future
            // work), so the curve keeps its shape when the ends move.
            guard !closed, let first = points.first, let last = points.last,
                  points.count >= 2 else { return [] }
            return [RawSlot(entityID: id, role: .endpointA, position: first, endpointLike: true),
                    RawSlot(entityID: id, role: .endpointB, position: last, endpointLike: true)]
        }
    }

    private static func radiusScalar(_ e: SketchEntity) -> Double? {
        switch e {
        case let .circle(_, _, r): return r
        case let .arc(_, _, r, _, _): return r
        case let .polygon(_, _, r, _, _): return r
        default: return nil
        }
    }

    // MARK: - System construction

    private static func buildSystem(
        from sketch: Sketch,
        movingEntity: UUID?,
        dragTarget: SIMD2<Double>?
    ) -> System {
        // 1. Raw point slots for every entity.
        var slots: [RawSlot] = []
        var rawIndexOf: [SlotKey: Int] = [:]
        for e in sketch.entities {
            for s in mutableSlots(e) {
                rawIndexOf[SlotKey(entityID: s.entityID, role: s.role)] = slots.count
                slots.append(s)
            }
        }

        // 2. Union-find weld.
        var parent = Array(0..<slots.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        // Proximity weld (endpoint-like slots within 1e-6).
        for i in 0..<slots.count where slots[i].endpointLike {
            for j in (i + 1)..<slots.count where slots[j].endpointLike {
                if simd_distance(slots[i].position, slots[j].position) < 1e-6 { union(i, j) }
            }
        }
        // Explicit coincident weld (point-to-point only).
        for c in sketch.constraints where c.kind == .coincident && c.refs.count == 2 {
            let k0 = SlotKey(entityID: c.refs[0].entityID, role: c.refs[0].role)
            let k1 = SlotKey(entityID: c.refs[1].entityID, role: c.refs[1].role)
            if let i0 = rawIndexOf[k0], let i1 = rawIndexOf[k1] { union(i0, i1) }
        }

        // 3. Root -> point index, averaging welded positions.
        var rootToPoint: [Int: Int] = [:]
        var sumPos: [SIMD2<Double>] = []
        var countPos: [Int] = []
        for i in 0..<slots.count {
            let r = find(i)
            if let pi = rootToPoint[r] {
                sumPos[pi] += slots[i].position
                countPos[pi] += 1
            } else {
                rootToPoint[r] = sumPos.count
                sumPos.append(slots[i].position)
                countPos.append(1)
            }
        }
        let pointCount = sumPos.count
        let pointPos: [SIMD2<Double>] = (0..<pointCount).map { sumPos[$0] / Double(countPos[$0]) }

        // 4. slotKey -> point index.
        var pointIndex: [SlotKey: Int] = [:]
        for i in 0..<slots.count {
            pointIndex[SlotKey(entityID: slots[i].entityID, role: slots[i].role)] = rootToPoint[find(i)]
        }

        // 5. Radius scalars, appended after the points.
        var radiusVar: [UUID: Int] = [:]
        var scalarValues: [Double] = []
        for e in sketch.entities {
            if let r = radiusScalar(e) {
                radiusVar[e.id] = 2 * pointCount + scalarValues.count
                scalarValues.append(r)
            }
        }

        // 6. Initial variable vector.
        var initial = [Double](repeating: 0, count: 2 * pointCount + scalarValues.count)
        for pi in 0..<pointCount {
            initial[2 * pi] = pointPos[pi].x
            initial[2 * pi + 1] = pointPos[pi].y
        }
        for j in 0..<scalarValues.count { initial[2 * pointCount + j] = scalarValues[j] }

        // 7. Entity -> point indices.
        var entityPoints: [UUID: [Int]] = [:]
        for e in sketch.entities {
            entityPoints[e.id] = mutableSlots(e).compactMap {
                pointIndex[SlotKey(entityID: $0.entityID, role: $0.role)]
            }
        }

        // Resolve helpers.
        func pIdx(_ id: UUID, _ role: PointRole) -> Int? {
            pointIndex[SlotKey(entityID: id, role: role)]
        }
        func linePair(_ id: UUID) -> (Int, Int)? {
            guard let a = pIdx(id, .endpointA), let b = pIdx(id, .endpointB) else { return nil }
            return (a, b)
        }
        func pointOperand(_ ref: ConstraintRef) -> Int? {
            switch ref.role {
            case .endpointA, .endpointB, .center: return pIdx(ref.entityID, ref.role)
            case .whole: return nil
            }
        }
        func twoLines(_ refs: [ConstraintRef]) -> (Int, Int, Int, Int)? {
            guard refs.count == 2,
                  let (a1, b1) = linePair(refs[0].entityID),
                  let (a2, b2) = linePair(refs[1].entityID) else { return nil }
            return (a1, b1, a2, b2)
        }

        // 8. Fixed set from `.fixed` (Lock) constraints.
        var fixed = Set<Int>()
        func fixPoint(_ pi: Int) { fixed.insert(2 * pi); fixed.insert(2 * pi + 1) }
        for c in sketch.constraints where c.kind == .fixed {
            for ref in c.refs {
                switch ref.role {
                case .endpointA, .endpointB, .center:
                    if let pi = pIdx(ref.entityID, ref.role) { fixPoint(pi) }
                case .whole:
                    for pi in entityPoints[ref.entityID] ?? [] { fixPoint(pi) }
                    if let rv = radiusVar[ref.entityID] { fixed.insert(rv) }
                }
            }
        }

        // 9. Lower constraints + dimensions to residuals.
        var structural: [any ConstraintResidual] = []
        func appendAlign(_ refs: [ConstraintRef], horizontal: Bool) {
            let wholeLines = refs.filter { $0.role == .whole }
            if !wholeLines.isEmpty {
                for r in wholeLines where linePair(r.entityID) != nil {
                    let (a, b) = linePair(r.entityID)!
                    structural.append(horizontal
                        ? HorizontalConstraint(pA: a, pB: b)
                        : VerticalConstraint(pA: a, pB: b))
                }
            } else if refs.count == 2,
                      let a = pointOperand(refs[0]), let b = pointOperand(refs[1]) {
                structural.append(horizontal
                    ? HorizontalConstraint(pA: a, pB: b)
                    : VerticalConstraint(pA: a, pB: b))
            }
        }
        func appendColinear(_ point: ConstraintRef, _ line: ConstraintRef) {
            if let p = pointOperand(point), let (la, lb) = linePair(line.entityID) {
                structural.append(ColinearPointConstraint(p: p, lA: la, lB: lb))
            }
        }
        func appendTangent(_ refs: [ConstraintRef]) {
            guard refs.count == 2 else { return }
            var lineRef: ConstraintRef?
            var circleRef: ConstraintRef?
            for r in refs {
                if radiusVar[r.entityID] != nil { circleRef = r }
                else if linePair(r.entityID) != nil { lineRef = r }
            }
            if let l = lineRef, let cRef = circleRef,
               let (a, b) = linePair(l.entityID),
               let center = pIdx(cRef.entityID, .center),
               let rv = radiusVar[cRef.entityID] {
                structural.append(TangentLineCircleConstraint(lA: a, lB: b, center: center, radiusVar: rv))
            }
        }
        func appendDistance(_ refs: [ConstraintRef], value: Double) {
            guard refs.count == 2 else { return }
            let r0 = refs[0], r1 = refs[1]
            if let p0 = pointOperand(r0), let p1 = pointOperand(r1) {
                structural.append(DistanceConstraint(pA: p0, pB: p1, distance: value))
            } else if let p = pointOperand(r0), r1.role == .whole, let (la, lb) = linePair(r1.entityID) {
                structural.append(PointDistanceToLineConstraint(p: p, lA: la, lB: lb, distance: value))
            } else if let p = pointOperand(r1), r0.role == .whole, let (la, lb) = linePair(r0.entityID) {
                structural.append(PointDistanceToLineConstraint(p: p, lA: la, lB: lb, distance: value))
            } else if r0.role == .whole, r1.role == .whole,
                      let (la, lb) = linePair(r0.entityID), let (a2, _) = linePair(r1.entityID) {
                structural.append(PointDistanceToLineConstraint(p: a2, lA: la, lB: lb, distance: value))
            }
        }

        for c in sketch.constraints {
            switch c.kind {
            case .fixed:
                break // handled via the fixed set
            case .coincident:
                guard c.refs.count == 2 else { break }
                let r0 = c.refs[0], r1 = c.refs[1]
                if r1.role == .whole {
                    appendColinear(r0, r1)
                } else if r0.role == .whole {
                    appendColinear(r1, r0)
                } else if let a = pointOperand(r0), let b = pointOperand(r1), a != b {
                    structural.append(CoincidentConstraint(pA: a, pB: b))
                }
            case .horizontal:
                appendAlign(c.refs, horizontal: true)
            case .vertical:
                appendAlign(c.refs, horizontal: false)
            case .parallel:
                if let (a1, b1, a2, b2) = twoLines(c.refs) {
                    structural.append(ParallelConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2))
                }
            case .perpendicular:
                if let (a1, b1, a2, b2) = twoLines(c.refs) {
                    structural.append(PerpendicularConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2))
                }
            case .equalLength:
                if let (a1, b1, a2, b2) = twoLines(c.refs) {
                    structural.append(EqualLengthConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2))
                }
            case .equalRadius:
                if c.refs.count == 2,
                   let rv1 = radiusVar[c.refs[0].entityID],
                   let rv2 = radiusVar[c.refs[1].entityID] {
                    structural.append(EqualRadiusConstraint(rVar1: rv1, rVar2: rv2))
                }
            case .concentric:
                if c.refs.count == 2,
                   let a = pIdx(c.refs[0].entityID, .center),
                   let b = pIdx(c.refs[1].entityID, .center), a != b {
                    structural.append(ConcentricConstraint(cA: a, cB: b))
                }
            case .midpoint:
                if c.refs.count == 2,
                   let p = pointOperand(c.refs[0]),
                   let (la, lb) = linePair(c.refs[1].entityID) {
                    structural.append(MidpointConstraint(p: p, lA: la, lB: lb))
                }
            case .symmetric:
                if c.refs.count == 3,
                   let a = pointOperand(c.refs[0]),
                   let b = pointOperand(c.refs[1]),
                   let (la, lb) = linePair(c.refs[2].entityID) {
                    structural.append(SymmetricConstraint(pA: a, pB: b, lA: la, lB: lb))
                }
            case .tangent:
                appendTangent(c.refs)
            case .colinear:
                guard c.refs.count == 2 else { break }
                let r0 = c.refs[0], r1 = c.refs[1]
                if r1.role == .whole, r0.role != .whole {
                    appendColinear(r0, r1)
                } else if r0.role == .whole, r1.role != .whole {
                    appendColinear(r1, r0)
                } else if r0.role == .whole, r1.role == .whole,
                          let (la, lb) = linePair(r0.entityID), let (a2, b2) = linePair(r1.entityID) {
                    structural.append(ColinearPointConstraint(p: a2, lA: la, lB: lb))
                    structural.append(ColinearPointConstraint(p: b2, lA: la, lB: lb))
                }
            }
        }

        for d in sketch.dimensions {
            switch d.kind {
            case .distance:
                appendDistance(d.refs, value: d.value)
            case .radius:
                if let ref = d.refs.first, let rv = radiusVar[ref.entityID] {
                    structural.append(RadiusConstraint(radiusVar: rv, radius: d.value))
                }
            case .diameter:
                if let ref = d.refs.first, let rv = radiusVar[ref.entityID] {
                    structural.append(RadiusConstraint(radiusVar: rv, radius: d.value / 2))
                }
            case .angle:
                if let (a1, b1, a2, b2) = twoLines(d.refs) {
                    structural.append(AngleConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2, angle: d.value))
                }
            }
        }

        // 10. Transient drag constraint: pull the moved entity's nearest point.
        var solveConstraints = structural
        if let mid = movingEntity, let target = dragTarget,
           let pts = entityPoints[mid], !pts.isEmpty {
            var best = pts[0]
            var bestD = Double.greatestFiniteMagnitude
            for pi in pts {
                let pos = SIMD2(initial[2 * pi], initial[2 * pi + 1])
                let dd = simd_distance(pos, target)
                if dd < bestD { bestD = dd; best = pi }
            }
            solveConstraints.append(FixedPointConstraint(p: best, target: target))
        }

        return System(
            initial: initial,
            fixed: fixed,
            pointCount: pointCount,
            pointIndex: pointIndex,
            radiusVar: radiusVar,
            structural: structural,
            solveConstraints: solveConstraints,
            entityPoints: entityPoints
        )
    }

    // MARK: - Write back

    private static func writeBack(
        _ entities: [SketchEntity],
        sys: System,
        vars: [Double]
    ) -> [SketchEntity] {
        func pt(_ id: UUID, _ role: PointRole) -> SIMD2<Double>? {
            guard let idx = sys.pointIndex[SlotKey(entityID: id, role: role)] else { return nil }
            return SIMD2(vars[2 * idx], vars[2 * idx + 1])
        }
        func rad(_ id: UUID, _ fallback: Double) -> Double {
            guard let rv = sys.radiusVar[id] else { return fallback }
            return abs(vars[rv])
        }
        return entities.map { e in
            switch e {
            case let .line(id, a, b):
                return .line(id: id, a: pt(id, .endpointA) ?? a, b: pt(id, .endpointB) ?? b)
            case let .rect(id, mn, mx):
                return .rect(id: id, min: pt(id, .endpointA) ?? mn, max: pt(id, .endpointB) ?? mx)
            case let .circle(id, c, r):
                return .circle(id: id, center: pt(id, .center) ?? c, radius: rad(id, r))
            case let .arc(id, c, r, sa, ea):
                return .arc(id: id, center: pt(id, .center) ?? c, radius: rad(id, r),
                            startAngle: sa, endAngle: ea)
            case let .ellipse(id, c, rx, ry, rot):
                return .ellipse(id: id, center: pt(id, .center) ?? c, radiusX: rx, radiusY: ry, rotation: rot)
            case let .polygon(id, c, r, sides, rot):
                return .polygon(id: id, center: pt(id, .center) ?? c, radius: rad(id, r),
                                sides: sides, rotation: rot)
            case let .spline(id, points, closed):
                // Move the ends the solver placed; interior points ride along by
                // the same translation so the curve is not distorted.
                guard !closed, points.count >= 2,
                      let a = pt(id, .endpointA) ?? points.first,
                      let b = pt(id, .endpointB) ?? points.last
                else { return e }
                var moved = points
                moved[0] = a
                moved[moved.count - 1] = b
                return .spline(id: id, points: moved, closed: closed)
            }
        }
    }

    // MARK: - Per-entity DOF

    private static func entityDetermined(
        _ e: SketchEntity,
        sys: System,
        determined: [Bool]
    ) -> Bool {
        var idxs: [Int] = []
        for pi in sys.entityPoints[e.id] ?? [] {
            idxs.append(2 * pi)
            idxs.append(2 * pi + 1)
        }
        if let rv = sys.radiusVar[e.id] { idxs.append(rv) }
        guard !idxs.isEmpty else { return true }
        return idxs.allSatisfy { $0 < determined.count && determined[$0] }
    }

    // MARK: - Null-space analysis (DOF + per-variable determinacy)

    private static func stacked(_ cons: [any ConstraintResidual], _ x: [Double]) -> [Double] {
        var out: [Double] = []
        for c in cons { out.append(contentsOf: c.residuals(x)) }
        return out
    }

    /// Analyse the structural constraint Jacobian at `x`: returns the estimated
    /// degrees of freedom (nullity) and, per global variable, whether it is
    /// determined (fixed vars and vars with no null-space component are `true`).
    private static func nullSpaceAnalysis(
        _ sys: System,
        at x: [Double]
    ) -> (dof: Int, determined: [Bool]) {
        let nGlobal = x.count
        var determined = [Bool](repeating: true, count: nGlobal) // fixed vars stay true
        let free = (0..<nGlobal).filter { !sys.fixed.contains($0) }
        let nf = free.count
        guard nf > 0 else { return (0, determined) }

        let cons = sys.structural
        let m = stacked(cons, x).count
        guard m > 0 else {
            for g in free { determined[g] = false }
            return (nf, determined)
        }

        // Numeric Jacobian (central differences) over free variables.
        let h = 1e-6
        var J = [[Double]](repeating: [Double](repeating: 0, count: nf), count: m)
        for (col, g) in free.enumerated() {
            var xp = x; xp[g] += h
            var xm = x; xm[g] -= h
            let rp = stacked(cons, xp)
            let rm = stacked(cons, xm)
            for i in 0..<m { J[i][col] = (rp[i] - rm[i]) / (2 * h) }
        }

        // Normal matrix M = JᵀJ (nf × nf, symmetric).
        var M = [[Double]](repeating: [Double](repeating: 0, count: nf), count: nf)
        for a in 0..<nf {
            for b in a..<nf {
                var s = 0.0
                for i in 0..<m { s += J[i][a] * J[i][b] }
                M[a][b] = s
                M[b][a] = s
            }
        }

        let (values, vectors) = jacobiEigen(M, n: nf)
        let lambdaMax = values.max() ?? 0
        let tol = Swift.max(lambdaMax * 1e-9, 1e-12)

        var nullEnergy = [Double](repeating: 0, count: nf)
        var dof = 0
        for k in 0..<nf where values[k] < tol {
            dof += 1
            for j in 0..<nf { nullEnergy[j] += vectors[k][j] * vectors[k][j] }
        }
        for (col, g) in free.enumerated() {
            determined[g] = nullEnergy[col] < 1e-6
        }
        return (dof, determined)
    }

    /// Cyclic Jacobi eigen-decomposition of a symmetric matrix. Returns
    /// eigenvalues and eigenvectors (`vectors[k]` is eigenvector `k`). Adequate
    /// for the small dense systems a single sketch produces.
    private static func jacobiEigen(
        _ input: [[Double]],
        n: Int
    ) -> (values: [Double], vectors: [[Double]]) {
        guard n > 0 else { return ([], []) }
        var A = input
        var V = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { V[i][i] = 1 }

        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<n { off += A[p][q] * A[p][q] } }
            if off < 1e-30 { break }
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = A[p][q]
                    if abs(apq) < 1e-300 { continue }
                    let tau = (A[q][q] - A[p][p]) / (2 * apq)
                    let sgn = tau >= 0 ? 1.0 : -1.0
                    let t = sgn / (abs(tau) + (tau * tau + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    // A <- Aᵀ...  two-sided rotation A' = GᵀAG (G acts on p,q).
                    for i in 0..<n {
                        let aip = A[i][p], aiq = A[i][q]
                        A[i][p] = c * aip - s * aiq
                        A[i][q] = s * aip + c * aiq
                    }
                    for j in 0..<n {
                        let apj = A[p][j], aqj = A[q][j]
                        A[p][j] = c * apj - s * aqj
                        A[q][j] = s * apj + c * aqj
                    }
                    for i in 0..<n {
                        let vip = V[i][p], viq = V[i][q]
                        V[i][p] = c * vip - s * viq
                        V[i][q] = s * vip + c * viq
                    }
                }
            }
        }

        let values = (0..<n).map { A[$0][$0] }
        let vectors = (0..<n).map { k in (0..<n).map { j in V[j][k] } }
        return (values, vectors)
    }
}

// MARK: - Per-point solve state (A2)

/// Identifies a single solver point: an entity plus which of its points.
/// Two coincident (welded) points have DIFFERENT keys but resolve to the same
/// solver variables, so they report the same `SketchPointState`.
nonisolated struct SketchPointKey: Hashable, Sendable {
    var entityID: UUID
    var role: PointRole
}

/// Determinacy of one sketch point, for the on-canvas DOF markers.
/// - `free`: still has null-space motion (under-defined / movable).
/// - `constrained`: fully determined by constraints + dimensions (no motion).
/// - `locked`: pinned by a `.fixed` (Lock) constraint, or welded to a point
///   whose every variable is in the solver's fixed set.
nonisolated enum SketchPointState: Sendable, Equatable {
    case free
    case constrained
    case locked
}

nonisolated extension SketchSolverBridge {

    /// Per-point determinacy for every point of every entity in `sketch`, keyed
    /// by (entityID, role). Reuses the SAME build → solve → null-space path as
    /// `entityStates`, but reports at (entity, role) granularity instead of one
    /// bool per entity. Coincident (welded) points share solver variables and
    /// therefore report identical states — desired for showing connected joints.
    static func pointStates(_ sketch: Sketch) -> [SketchPointKey: SketchPointState] {
        var out: [SketchPointKey: SketchPointState] = [:]

        // Which points an explicit `.fixed` (Lock) constraint pins. A `.whole`
        // ref pins every point (and radius) of that entity; a point ref pins
        // just that (entity, role). Mirrors buildSystem's `.fixed` handling.
        var lockedWholeEntities = Set<UUID>()
        var lockedPoints = Set<SketchPointKey>()
        for c in sketch.constraints where c.kind == .fixed {
            for ref in c.refs {
                if ref.role == .whole {
                    lockedWholeEntities.insert(ref.entityID)
                } else {
                    lockedPoints.insert(SketchPointKey(entityID: ref.entityID, role: ref.role))
                }
            }
        }
        func explicitlyLocked(_ id: UUID, _ role: PointRole) -> Bool {
            lockedWholeEntities.contains(id)
                || lockedPoints.contains(SketchPointKey(entityID: id, role: role))
        }

        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)

        // Degenerate (no variables / no entities): every enumerated point is as
        // determined as it can be — locked if pinned, else constrained (matches
        // `entityStates` returning `true` for an empty system).
        guard !sys.initial.isEmpty else {
            for e in sketch.entities {
                for slot in mutableSlots(e) {
                    let key = SketchPointKey(entityID: slot.entityID, role: slot.role)
                    out[key] = explicitlyLocked(slot.entityID, slot.role) ? .locked : .constrained
                }
            }
            return out
        }

        let solved = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.solveConstraints
        ).variables
        let determined = nullSpaceAnalysis(sys, at: solved).determined

        for e in sketch.entities {
            for slot in mutableSlots(e) {
                let key = SketchPointKey(entityID: slot.entityID, role: slot.role)
                guard let pi = sys.pointIndex[SlotKey(entityID: slot.entityID, role: slot.role)] else {
                    out[key] = explicitlyLocked(slot.entityID, slot.role) ? .locked : .free
                    continue
                }
                // The point's own position variables (its welded x,y pair).
                let posVars = [2 * pi, 2 * pi + 1]
                // A circle/arc/polygon `.center` also carries the entity's
                // radius scalar — the round entity is not fully *defined* until
                // its radius is, but the radius does not affect whether the
                // point itself can move.
                var definingVars = posVars
                if slot.role == .center, let rv = sys.radiusVar[slot.entityID] {
                    definingVars.append(rv)
                }
                // `.locked` is about immobility of the POINT: an explicit lock,
                // or every POSITION variable pinned in the solver's fixed set —
                // a centre welded onto a fixed point is locked even while its
                // radius is still free.
                if explicitlyLocked(slot.entityID, slot.role)
                    || posVars.allSatisfy({ sys.fixed.contains($0) }) {
                    out[key] = .locked
                } else if definingVars.allSatisfy({ $0 < determined.count && determined[$0] }) {
                    out[key] = .constrained
                } else {
                    out[key] = .free
                }
            }
        }
        return out
    }
}
