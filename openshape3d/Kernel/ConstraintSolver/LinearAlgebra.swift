//
//  LinearAlgebra.swift
//  openshape3d
//
//  Small dense linear-algebra helpers for the 2D constraint solver. Pure
//  Swift, Double math, no external dependencies (deliberately not Accelerate
//  LAPACK — the matrices here are tiny and the LAPACK ABI shifts between SDKs).
//
//  Two primitives the Levenberg–Marquardt core needs:
//    • Cholesky solve of the damped normal equations (always SPD, so this
//      never hits the non-positive-definite branch in practice).
//    • Singular values of the Jacobian via one-sided Jacobi SVD, used only to
//      estimate numeric rank → remaining degrees of freedom.
//

import Foundation

nonisolated enum LinearAlgebra {

    // MARK: - Cholesky solve (SPD)

    /// Solves `A x = b` for a symmetric positive-definite `A` (row-major,
    /// `n`×`n`) via Cholesky factorisation. Returns `nil` if `A` is not
    /// positive-definite (a non-positive pivot appears), which the caller
    /// treats as a failed LM step. Only the lower triangle of `A` is read.
    static func solveSPD(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
        if n == 0 { return [] }
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = A[i * n + j]
                var k = 0
                while k < j {
                    sum -= L[i * n + k] * L[j * n + k]
                    k += 1
                }
                if i == j {
                    if !(sum > 0) || !sum.isFinite { return nil }
                    L[i * n + i] = sum.squareRoot()
                } else {
                    let d = L[j * n + j]
                    if d == 0 || !d.isFinite { return nil }
                    L[i * n + j] = sum / d
                }
            }
        }

        // Forward solve  L y = b.
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            var k = 0
            while k < i {
                sum -= L[i * n + k] * y[k]
                k += 1
            }
            y[i] = sum / L[i * n + i]
        }

        // Back solve  Lᵀ x = y.
        var x = [Double](repeating: 0, count: n)
        var i = n - 1
        while i >= 0 {
            var sum = y[i]
            var k = i + 1
            while k < n {
                sum -= L[k * n + i] * x[k]
                k += 1
            }
            x[i] = sum / L[i * n + i]
            i -= 1
        }

        for v in x where !v.isFinite { return nil }
        return x
    }

    // MARK: - Singular values (one-sided Jacobi SVD)

    /// Singular values of an `m`×`n` matrix (row-major) via one-sided Jacobi
    /// rotation of its columns. Robust for the small, possibly rank-deficient
    /// Jacobians the solver produces; returns values sorted descending. The
    /// count returned is `n` (one per column); rank-deficient directions come
    /// back as ~0 singular values.
    static func singularValues(_ A: [Double], m: Int, n: Int) -> [Double] {
        if m == 0 || n == 0 { return [] }

        // Store columns contiguously: cols[c * m + r].
        var cols = [Double](repeating: 0, count: n * m)
        for r in 0..<m {
            for c in 0..<n {
                cols[c * m + r] = A[r * n + c]
            }
        }

        let tiny = 1e-300
        let maxSweeps = 60
        for _ in 0..<maxSweeps {
            var rotated = false
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var alpha = 0.0, beta = 0.0, gamma = 0.0
                    let bi = i * m, bj = j * m
                    for r in 0..<m {
                        let ci = cols[bi + r]
                        let cj = cols[bj + r]
                        alpha += ci * ci
                        beta += cj * cj
                        gamma += ci * cj
                    }
                    let denom = (alpha * beta).squareRoot()
                    if denom <= tiny { continue }
                    // Off-diagonal already negligible for this pair.
                    if abs(gamma) <= 1e-15 * denom { continue }

                    let zeta = (beta - alpha) / (2 * gamma)
                    let sign = zeta >= 0 ? 1.0 : -1.0
                    let t = sign / (abs(zeta) + (1 + zeta * zeta).squareRoot())
                    let cs = 1 / (1 + t * t).squareRoot()
                    let sn = cs * t

                    for r in 0..<m {
                        let cik = cols[bi + r]
                        let cjk = cols[bj + r]
                        cols[bi + r] = cs * cik - sn * cjk
                        cols[bj + r] = sn * cik + cs * cjk
                    }
                    rotated = true
                }
            }
            if !rotated { break }
        }

        var sv = [Double](repeating: 0, count: n)
        for c in 0..<n {
            var s = 0.0
            let base = c * m
            for r in 0..<m { s += cols[base + r] * cols[base + r] }
            sv[c] = s.squareRoot()
        }
        sv.sort(by: >)
        return sv
    }

    /// Numeric rank from singular values: counts those above a threshold that
    /// scales with the largest singular value (with a small absolute floor so a
    /// genuinely empty system reports rank 0). `relativeTolerance` defaults are
    /// chosen to sit comfortably above central-difference Jacobian noise
    /// (~1e-7 relative) yet well below the O(1) singular values of independent
    /// constraints.
    static func rank(singularValues sv: [Double],
                     relativeTolerance: Double = 1e-6,
                     absoluteFloor: Double = 1e-9) -> Int {
        guard let sigmaMax = sv.first, sigmaMax > 0 else { return 0 }
        let threshold = max(sigmaMax * relativeTolerance, absoluteFloor)
        var r = 0
        for s in sv where s > threshold { r += 1 }
        return r
    }
}
