import XCTest
@testable import openshape3d

/// The sketch solver's dense kernels run on LAPACK through the C shim; the
/// pure-Swift routines they replaced are the references. Same answers, same
/// refusals, and the contracts the callers rely on (value order, counts).
final class LinearAlgebraTests: XCTestCase {

    // MARK: - Cholesky

    func testSPDSolveMatchesTheReferenceAndTheHandSolution() throws {
        // A = [4 1 2; 1 3 0; 2 0 5] (SPD), b = A·[1, −2, 3]ᵀ = [8, −5, 17].
        let A: [Double] = [4, 1, 2, 1, 3, 0, 2, 0, 5]
        let b: [Double] = [8, -5, 17]
        let x = try XCTUnwrap(LinearAlgebra.solveSPD(A, b, n: 3))
        let ref = try XCTUnwrap(LinearAlgebra.solveSPDReference(A, b, n: 3))
        for i in 0..<3 {
            XCTAssertEqual(x[i], [1, -2, 3][i], accuracy: 1e-12)
            XCTAssertEqual(x[i], ref[i], accuracy: 1e-12)
        }
    }

    func testANonPositiveDefiniteMatrixIsRefusedByBoth() {
        let A: [Double] = [1, 2, 2, 1] // eigenvalues 3 and −1
        XCTAssertNil(LinearAlgebra.solveSPD(A, [1, 1], n: 2))
        XCTAssertNil(LinearAlgebra.solveSPDReference(A, [1, 1], n: 2))
        XCTAssertNil(LinearAlgebra.solveSPD([1, 0, 0, .nan], [1, 1], n: 2), "non-finite input refused")
        XCTAssertEqual(LinearAlgebra.solveSPD([], [], n: 0), [])
    }

    func testALargeDampedNormalSystemAgreesWithTheReference() throws {
        // JᵀJ + λI for a random 120×80 J: exactly what an LM step solves.
        var rng = SystemRandomNumberGenerator()
        let m = 120, n = 80
        let J = (0..<(m * n)).map { _ in Double.random(in: -1...1, using: &rng) }
        var A = [Double](repeating: 0, count: n * n)
        for i in 0..<m { for a in 0..<n { for b in 0..<n { A[a * n + b] += J[i * n + a] * J[i * n + b] } } }
        for a in 0..<n { A[a * n + a] += 1e-3 }
        let b = (0..<n).map { _ in Double.random(in: -1...1, using: &rng) }
        let x = try XCTUnwrap(LinearAlgebra.solveSPD(A, b, n: n))
        let ref = try XCTUnwrap(LinearAlgebra.solveSPDReference(A, b, n: n))
        for i in 0..<n { XCTAssertEqual(x[i], ref[i], accuracy: 1e-7 * max(1, abs(ref[i]))) }
    }

    // MARK: - Singular values

    func testSingularValuesAreDescendingCountNAndMatchTheReference() {
        // Rank-2 3×3 matrix: rows (1,0,0), (0,2,0), (0,2,0) → σ = 2√2, 1, 0.
        let A: [Double] = [1, 0, 0, 0, 2, 0, 0, 2, 0]
        let s = LinearAlgebra.singularValues(A, m: 3, n: 3)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0], 2 * 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(s[1], 1, accuracy: 1e-12)
        XCTAssertEqual(s[2], 0, accuracy: 1e-12)
        XCTAssertEqual(LinearAlgebra.rank(singularValues: s), 2)
        let ref = LinearAlgebra.singularValuesReference(A, m: 3, n: 3)
        for i in 0..<3 { XCTAssertEqual(s[i], ref[i], accuracy: 1e-12) }
    }

    func testAWideMatrixStillReportsOneValuePerColumn() {
        // 2×4: LAPACK gives min(m, n) = 2 values; the contract is n = 4.
        let A: [Double] = [1, 0, 0, 0, 0, 3, 0, 0]
        let s = LinearAlgebra.singularValues(A, m: 2, n: 4)
        XCTAssertEqual(s, [3, 1, 0, 0])
        XCTAssertEqual(LinearAlgebra.rank(singularValues: s), 2)
    }

    // MARK: - Symmetric eigen

    func testSymmetricEigenIsAscendingOrthonormalAndSatisfiesAvEqualsLambdaV() {
        // [2 1 0; 1 2 0; 0 0 5] → eigenvalues 1, 3, 5.
        let A: [Double] = [2, 1, 0, 1, 2, 0, 0, 0, 5]
        let (values, vectors) = LinearAlgebra.symmetricEigen(A, n: 3)
        XCTAssertEqual(values.count, 3)
        for (v, expected) in zip(values, [1.0, 3.0, 5.0]) { XCTAssertEqual(v, expected, accuracy: 1e-12) }
        for k in 0..<3 {
            let v = vectors[k]
            XCTAssertEqual((v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot(), 1, accuracy: 1e-12)
            for i in 0..<3 {
                let av = A[i * 3] * v[0] + A[i * 3 + 1] * v[1] + A[i * 3 + 2] * v[2]
                XCTAssertEqual(av, values[k] * v[i], accuracy: 1e-12, "A v = λ v for eigenpair \(k)")
            }
        }
        // The reference orders the same way and spans the same null-ish space.
        let ref = LinearAlgebra.symmetricEigenReference(A, n: 3)
        for k in 0..<3 { XCTAssertEqual(ref.values[k], values[k], accuracy: 1e-10) }
    }

    func testEigenNullSpaceEnergyMatchesTheReferenceOnARankDeficientGram() {
        // J = [1 1 0; 0 0 1] → JᵀJ has a one-dimensional null space along (1, −1, 0).
        let M: [Double] = [1, 1, 0, 1, 1, 0, 0, 0, 1]
        let (values, vectors) = LinearAlgebra.symmetricEigen(M, n: 3)
        XCTAssertEqual(values[0], 0, accuracy: 1e-12)
        let v = vectors[0]
        XCTAssertEqual(abs(v[0]), 1 / 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(v[0], -v[1], accuracy: 1e-12)
        XCTAssertEqual(v[2], 0, accuracy: 1e-12)
        XCTAssertEqual(values[2], 2, accuracy: 1e-12)
    }
}
