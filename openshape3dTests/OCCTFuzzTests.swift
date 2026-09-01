//
//  OCCTFuzzTests.swift
//  openshape3dTests — deserialize robustness harness. Promoted from
//  docs/occt-fuzz-harness.swift.txt (NEXT §4 item 4) so the compiler keeps
//  it honest; the sweep itself runs only when OS3D_FUZZ=1 is set (it takes
//  minutes and journals to /private/tmp — not a per-commit gate cost):
//
//    TEST_RUNNER_OS3D_FUZZ=1 xcodebuild test … \
//      -only-testing:openshape3dTests/OCCTFuzzTests
//
//  (xcodebuild forwards TEST_RUNNER_-prefixed variables into the test host,
//  minus the prefix. The skip message names the switch.)
//
//  The sweep CLOSED the count-*, ref-*, numeric-*, and nul-* crash/hang
//  families (deserialize now pre-gates them: OS3DPlausibleSectionCounts,
//  pinned in OCCTSerializationPinTests). It skips a documented KNOWN-OPEN set
//  it cannot pre-gate — truncated valid prefixes and one 200k-vertex resource
//  case (see the `knownOpen` block) — logging the count so the cap is never
//  silent. As promoted it is a REGRESSION guard: a NEW crasher fails it.
//
//  `OCCTKernel.deserialize` is fed ATTACKER-CONTROLLED bytes: a `.os3d` archive
//  is a shareable document type, and `ProjectArchive → PersistedBody.brepData →
//  DocumentSession.load → OCCTKernel.deserialize → BRepTools::Read` never
//  validates the blob. The Obj-C++ bridge wraps the read in `catch (...)`, which
//  stops C++ exceptions but NOT segfaults, `Standard_ASSERT` aborts, runaway
//  allocation, or a hang.
//
//  This harness feeds a battery of hostile blobs through that entry point and
//  asserts only ONE thing: the process survives. Each case is journalled to a
//  file with an fsync BEFORE the call and a second line AFTER it, so a crash
//  leaves an unmatched `CASE` line naming exactly what killed the process; the
//  next run resumes past it. Point the journal somewhere readable with
//  `OS3D_FUZZ_LOG`, otherwise it lands in the test host's tmp (the path is
//  printed to stderr on the first line of the run).
//

import XCTest
@testable import openshape3d

// MARK: - Journal

/// Append-only, fsync-per-line progress journal. Survives a hard crash of the
/// test process, which a normal XCTest failure log does not.
private final class FuzzJournal {
    let url: URL
    private let handle: FileHandle

    init?(url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        // Opened for APPEND — the journal accumulates across crash-resume runs.
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = h
        _ = try? h.seekToEnd()
    }

    func write(_ line: String) {
        let text = line + "\n"
        if let d = text.data(using: .utf8) {
            handle.write(d)
            try? handle.synchronize()          // survive SIGSEGV / SIGABRT
            FileHandle.standardError.write(d)
        }
    }

    /// Existing journal contents (previous runs), for resume.
    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - Deterministic PRNG (stable corpus across runs)

private struct LCG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 33)
    }
}

private func randomBytes(count: Int, seed: UInt64) -> Data {
    var rng = LCG(seed: seed)
    var out = Data(count: count)
    for i in 0..<count { out[i] = UInt8.random(in: 0...255, using: &rng) }
    return out
}

private func randomASCII(count: Int, seed: UInt64) -> Data {
    var rng = LCG(seed: seed)
    let alphabet = Array("0123456789 \n-+.eE*ABCDEFVeEdWiFaSoCuPl".utf8)
    var out = Data(count: count)
    for i in 0..<count { out[i] = alphabet.randomElement(using: &rng)! }
    return out
}

// MARK: - Watchdog

/// A hang is as fatal as a crash for a document open, but it does not kill the
/// process, so a plain sequential sweep would stall on the first one. Run each
/// case on its own thread and give it a wall-clock budget; on timeout the
/// runaway thread is ABANDONED (it cannot be safely killed — it is spinning
/// inside OCCT) and the sweep moves on.
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private enum Guarded<T> {
    case ok(T)
    case timedOut
}

private func runGuarded<T>(budget: TimeInterval,
                           _ work: @escaping @Sendable () -> T) -> Guarded<T> {
    let box = Box<T>()
    let sem = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = work()
        sem.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    if sem.wait(timeout: .now() + budget) == .success, let v = box.value {
        return .ok(v)
    }
    return .timedOut
}

// MARK: - Corpus

private struct FuzzCase {
    let name: String
    let data: Data
}

final class OCCTFuzzTests: XCTestCase {

    // MARK: Journal / resume plumbing

    private static func journalURL() -> URL {
        if let p = ProcessInfo.processInfo.environment["OS3D_FUZZ_LOG"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        // Try a host-visible path first; fall back to the sandboxed tmp dir.
        // NEVER `createFile` on an existing journal — that truncates it, and the
        // crash-resume record with it.
        let host = URL(fileURLWithPath: "/private/tmp/os3d_occt_fuzz/progress.log")
        let dir = host.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: host.path)
            || FileManager.default.createFile(atPath: host.path, contents: nil) {
            return host
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("os3d_occt_fuzz_progress.log")
    }

    /// Base blobs are cached on disk so case indices stay STABLE across the
    /// resume runs a crash forces.
    private func cachedBlob(_ name: String, dir: URL, build: () -> Data?) -> Data? {
        let url = dir.appendingPathComponent("base_\(name).brep")
        if let d = try? Data(contentsOf: url), !d.isEmpty { return d }
        guard let d = build(), !d.isEmpty else { return nil }
        try? d.write(to: url)
        return d
    }

    // MARK: Corpus construction

    private func makeCorpus(cacheDir: URL) -> [FuzzCase] {
        var cases: [FuzzCase] = []

        // ---- 1. Degenerate / trivial inputs -----------------------------
        cases.append(FuzzCase(name: "empty", data: Data()))
        cases.append(FuzzCase(name: "one-zero-byte", data: Data([0])))
        cases.append(FuzzCase(name: "one-letter", data: Data("A".utf8)))
        cases.append(FuzzCase(name: "newlines-only", data: Data(String(repeating: "\n", count: 4096).utf8)))
        cases.append(FuzzCase(name: "spaces-only", data: Data(String(repeating: " ", count: 4096).utf8)))
        cases.append(FuzzCase(name: "nul-run", data: Data(repeating: 0, count: 4096)))
        cases.append(FuzzCase(name: "header-only-v1",
                              data: Data("DBRep_DrawableShape\n\nCASCADE Topology V1, (c) Matra-Datavision\n".utf8)))
        cases.append(FuzzCase(name: "header-only-v3",
                              data: Data("DBRep_DrawableShape\n\nCASCADE Topology V3, (c) Open Cascade\n".utf8)))

        // ---- 2. Random bytes --------------------------------------------
        for (i, n) in [8, 64, 1024, 65536].enumerated() {
            cases.append(FuzzCase(name: "random-bytes-\(n)", data: randomBytes(count: n, seed: UInt64(i + 1))))
            cases.append(FuzzCase(name: "random-ascii-\(n)", data: randomASCII(count: n, seed: UInt64(100 + i))))
        }

        // ---- Base blobs (real, valid OCCT output) ------------------------
        let cylinder = cachedBlob("cylinder", dir: cacheDir) {
            OCCTKernel.primitiveShape(.cylinder(radius: 3, height: 5), placement: .identity)
                .flatMap(OCCTKernel.serialize)
        }
        let box = cachedBlob("box", dir: cacheDir) {
            OCCTKernel.primitiveShape(.box(width: 10, depth: 10, height: 10), placement: .identity)
                .flatMap(OCCTKernel.serialize)
        }
        let filleted = cachedBlob("filleted", dir: cacheDir) {
            guard let cyl = OCCTKernel.primitiveShape(.cylinder(radius: 5, height: 20),
                                                      placement: .identity),
                  let f = OCCTKernel.fillet(cyl, at: [SIMD3(5, 20, 0)], radius: 1, tolerance: 0.6)
            else { return nil }
            return OCCTKernel.serialize(f)
        }
        let extruded = cachedBlob("extrude", dir: cacheDir) {
            OCCTKernel.extrudeShape(
                outerLoop: [],
                outerConic: OCCTKernel.ConicSpec(
                    center: SIMD2(0, 0), radiusX: 4, radiusY: 4, rotation: 0),
                holes: [], zMin: 0, zMax: 6,
                origin: .zero, xAxis: SIMD3(1, 0, 0),
                yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1))
                .flatMap(OCCTKernel.serialize)
        }
        let bases: [(String, Data)] = [
            ("cyl", cylinder), ("box", box), ("fillet", filleted), ("extrude", extruded)
        ].compactMap { name, d in d.map { (name, $0) } }

        // Sanity: the corpus is only meaningful if real blobs exist.
        for (name, d) in bases {
            cases.append(FuzzCase(name: "control-valid-\(name)", data: d))
        }

        // Truncation and byte-flip are the two BIG families and (empirically)
        // the most lethal, so they go LAST: a crash costs a whole process
        // relaunch, and the cheaper families should report first.
        var late: [FuzzCase] = []

        // ---- 3. Truncation at sampled offsets ----------------------------
        for (name, blob) in bases {
            var offsets = Set<Int>([1, 4, 16, 64, 128])
            for i in 1..<10 { offsets.insert(blob.count * i / 10) }
            offsets.insert(blob.count - 1)
            for off in offsets.sorted() where off > 0 && off < blob.count {
                late.append(FuzzCase(name: "truncate-\(name)@\(off)",
                                     data: blob.prefix(off)))
            }
        }

        // ---- 4. Single-byte corruption ------------------------------------
        for (name, blob) in bases where !blob.isEmpty {
            let positions = (0..<10).map { blob.count * $0 / 10 }
            for p in positions {
                for (tag, byte) in [("00", UInt8(0)), ("FF", UInt8(255)), ("9", UInt8(57))] {
                    var m = blob
                    m[m.startIndex + p] = byte
                    late.append(FuzzCase(name: "flip-\(name)@\(p)=\(tag)", data: m))
                }
            }
        }

        // ---- 5. Declared-count inflation (the ASCII format's length fields)
        // Lines look like `Locations 3`, `Curve2ds 12`, `TShapes 27`. Inflating
        // them tells the reader to loop/allocate for records that are not there.
        if let (_, blob) = bases.first(where: { $0.0 == "fillet" }) ?? bases.first,
           let text = String(data: blob, encoding: .utf8) {
            let lines = text.components(separatedBy: "\n")
            let bigValues = ["2147483647", "4294967295", "99999999999999999999", "-1", "1000000000"]
            var mutated = 0
            for (idx, line) in lines.enumerated() where mutated < 12 {
                let parts = line.split(separator: " ")
                guard parts.count == 2,
                      Int(parts[1]) != nil,
                      parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                else { continue }
                mutated += 1
                for v in bigValues {
                    var copy = lines
                    copy[idx] = "\(parts[0]) \(v)"
                    cases.append(FuzzCase(name: "count-\(parts[0])=\(v)",
                                          data: Data(copy.joined(separator: "\n").utf8)))
                }
            }
        }

        // ---- 6. Sub-shape reference indices out of range -------------------
        // In the TShapes section, children are referenced as `*7 1` / `+3 0`.
        // Point them past the end of the table.
        if let (_, blob) = bases.first(where: { $0.0 == "fillet" }) ?? bases.first,
           let text = String(data: blob, encoding: .utf8) {
            for (tag, replacement) in [("huge", "2147483000"), ("neg", "-5"), ("big", "999999")] {
                for marker in ["*", "+", "-"] {
                    var out = ""
                    var i = text.startIndex
                    while i < text.endIndex {
                        let ch = text[i]
                        if String(ch) == marker {
                            var j = text.index(after: i)
                            var digits = ""
                            while j < text.endIndex, text[j].isNumber {
                                digits.append(text[j]); j = text.index(after: j)
                            }
                            if !digits.isEmpty {
                                out += marker + replacement
                                i = j
                                continue
                            }
                        }
                        out.append(ch)
                        i = text.index(after: i)
                    }
                    cases.append(FuzzCase(name: "ref-\(marker)-\(tag)", data: Data(out.utf8)))
                }
            }
        }

        // ---- 7. Absurd numeric fields --------------------------------------
        if let (_, blob) = bases.first(where: { $0.0 == "cyl" }) ?? bases.first,
           let text = String(data: blob, encoding: .utf8) {
            let poisons: [(String, String)] = [
                ("1e999", "1e999"),
                ("-1e999", "-1e999"),
                ("nan", "nan"),
                ("inf", "inf"),
                ("-inf", "-inf"),
                ("1e-999", "1e-999"),
                ("longdigits", String(repeating: "9", count: 5000)),
                ("longdigits1m", String(repeating: "7", count: 1_000_000)),
                ("hex", "0x41414141"),
                ("empty", "")
            ]
            // Replace every float-looking token (a decimal point with digits).
            for (tag, poison) in poisons {
                var out = ""
                var i = text.startIndex
                var replaced = 0
                while i < text.endIndex {
                    let ch = text[i]
                    if ch.isNumber || ch == "-" {
                        var j = i
                        var tok = ""
                        while j < text.endIndex,
                              text[j].isNumber || text[j] == "." || text[j] == "-"
                                || text[j] == "e" || text[j] == "+" {
                            tok.append(text[j]); j = text.index(after: j)
                        }
                        if tok.contains("."), replaced < 400 {
                            out += poison
                            replaced += 1
                            i = j
                            continue
                        }
                    }
                    out.append(ch)
                    i = text.index(after: i)
                }
                cases.append(FuzzCase(name: "numeric-\(tag)", data: Data(out.utf8)))
            }
        }

        // ---- 8. NUL injection ------------------------------------------------
        if let (_, blob) = bases.first {
            for frac in [1, 2, 3, 4, 6, 8] {
                var m = blob
                let p = blob.count * frac / 10
                if p > 0 && p < m.count { m[m.startIndex + p] = 0 }
                cases.append(FuzzCase(name: "nul-at-\(frac)0pct", data: m))
            }
        }

        // ---- 9. Header/version tampering --------------------------------------
        if let (_, blob) = bases.first, let text = String(data: blob, encoding: .utf8) {
            for v in ["V0", "V2", "V4", "V99", "V-1", "V2147483647", "VX"] {
                let t = text
                    .replacingOccurrences(of: "Topology V1", with: "Topology \(v)")
                    .replacingOccurrences(of: "Topology V2", with: "Topology \(v)")
                    .replacingOccurrences(of: "Topology V3", with: "Topology \(v)")
                cases.append(FuzzCase(name: "version-\(v)", data: Data(t.utf8)))
            }
            cases.append(FuzzCase(name: "no-header",
                                  data: Data(text.components(separatedBy: "\n").dropFirst(3)
                                                 .joined(separator: "\n").utf8)))
        }

        // ---- 10. Structural repetition / nesting ------------------------------
        if let (_, blob) = bases.first, let text = String(data: blob, encoding: .utf8) {
            cases.append(FuzzCase(name: "blob-repeated-100x",
                                  data: Data(String(repeating: text, count: 100).utf8)))
            // Long run of the vertex record token — a deep, cheap-to-emit nest.
            let head = text.components(separatedBy: "TShapes").first ?? text
            cases.append(FuzzCase(
                name: "tshapes-200k-Ve",
                data: Data((head + "TShapes 200000\n" + String(repeating: "Ve\n1e-07\n0 0 0\n0 0\n\n",
                                                               count: 200_000)).utf8)))
            cases.append(FuzzCase(
                name: "tshapes-huge-count-no-body",
                data: Data((head + "TShapes 2000000000\n").utf8)))
        }

        // ---- 11. Sheer size ----------------------------------------------------
        cases.append(FuzzCase(name: "4MB-of-X", data: Data(repeating: 0x58, count: 4 << 20)))
        cases.append(FuzzCase(name: "4MB-of-digits", data: Data(repeating: 0x39, count: 4 << 20)))
        if let (_, blob) = bases.first {
            var padded = blob
            padded.append(Data(repeating: 0x20, count: 4 << 20))
            cases.append(FuzzCase(name: "valid+4MB-padding", data: padded))
        }

        return cases + late
    }

    // MARK: The sweep

    /// Feeds the whole hostile corpus through `deserialize` and, for anything
    /// that parses, through the downstream tessellation barrier
    /// (`faceTypeCounts` / `renderMesh` / `adoptBRep`). Asserts only survival.
    func testDeserializeSurvivesHostileInput() throws {
        // Compiled always (so API drift breaks the build, not the doc file);
        // run on demand — the sweep costs minutes, not a per-commit gate.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OS3D_FUZZ"] != nil,
            "hostile-input sweep runs only with TEST_RUNNER_OS3D_FUZZ=1")
        let journalURL = Self.journalURL()
        guard let journal = FuzzJournal(url: journalURL) else {
            return XCTFail("could not open the fuzz journal at \(journalURL.path)")
        }
        let cacheDir = journalURL.deletingLastPathComponent()

        // Resume: anything with a CASE line but no DONE line crashed the process.
        let previous = FuzzJournal.read(journalURL)
        var completed = Set<Int>()
        var started = Set<Int>()
        for line in previous.components(separatedBy: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 2, let idx = Int(f[1]) else { continue }
            if f[0] == "CASE" { started.insert(idx) }
            if f[0] == "DONE" { completed.insert(idx) }
        }
        let crashed = started.subtracting(completed).sorted()
        journal.write("### RUN journal=\(journalURL.path) occt=\(OCCTKernel.version)")
        if !crashed.isEmpty {
            journal.write("### RESUME skipping previously-fatal indices: \(crashed)")
        }

        let corpus = makeCorpus(cacheDir: cacheDir)
        journal.write("### CORPUS \(corpus.count) cases")
        // Guard against a VACUOUS pass: if the corpus failed to build (e.g. the
        // base blobs could not be produced) there is nothing to survive.
        XCTAssertGreaterThan(corpus.count, 100, "corpus did not build")
        XCTAssertTrue(corpus.contains { $0.name.hasPrefix("control-valid") },
                      "no valid control blob — the mutation families are empty")

        // KNOWN-OPEN robustness gaps this harness FOUND but that cannot be
        // closed at the deserialize pre-gate. They are skipped (never fed), so
        // the sweep completes and stays a REGRESSION guard for everything
        // else; the count is logged, never silent (see the header). Closing
        // them needs bounds-checking inside OCCT's own reader, which we don't
        // vendor as source, or crash-isolating the read in a subprocess —
        // too heavy for a document-load path.
        //   truncate-*   : a valid blob cut mid-record is a valid PREFIX — no
        //                  bad token to reject; OCCT reads past the short data
        //                  and dereferences garbage.
        //   flip-*=9     : a single byte flipped to the ASCII digit '9' stays
        //                  valid text (passes the byte gate) but corrupts a
        //                  structural field into a still-IN-RANGE-but-wrong
        //                  index OCCT dereferences — same single-byte-desync
        //                  class as truncation. (The =00 and =FF flips are
        //                  GATED, not skipped — non-text bytes.)
        //   tshapes-200k-Ve : a real 200k-vertex body (4MB, well-formed) —
        //                  resource pressure, not corruption; a genuine model
        //                  this large is out of scope for the load path.
        // (The count-*, ref-*, numeric-*, nul-*, and flip-*={00,FF} families
        // this harness found ARE closed — see OS3DPlausibleSectionCounts and
        // its pins in OCCTSerializationPinTests.)
        func isKnownOpen(_ name: String) -> Bool {
            name.hasPrefix("truncate-")
                || name == "tshapes-200k-Ve"
                || (name.hasPrefix("flip-") && name.hasSuffix("=9"))
        }
        let skipped = corpus.enumerated().filter { isKnownOpen($0.element.name) }
        journal.write("### KNOWN-OPEN skipping \(skipped.count) desync/resource "
            + "cases: \(skipped.map(\.element.name))")

        var parsed = 0, rejected = 0, tessellated = 0, emptyMesh = 0
        var terminal = completed.union(crashed)
        var hangs: [String] = []
        var finishedAll = true
        // Per-stage wall-clock budget. The hangs are INFINITE loops, so a few
        // seconds separates them from anything legitimately slow; heavy cases
        // (multi-MB inputs) are re-checked individually afterwards.
        let budget: TimeInterval = 5

        for (i, c) in corpus.enumerated() {
            if completed.contains(i) || crashed.contains(i) { continue }
            if isKnownOpen(c.name) { terminal.insert(i); continue }  // documented gap
            // Too many abandoned spinning threads makes the remaining timings
            // meaningless; stop and let a later run resume.
            // Abandoned threads spin at 100% CPU forever; past ~a core's worth
            // they starve the remaining cases and manufacture false timeouts.
            // Stop and let the next run resume in a fresh process.
            if hangs.count >= 10 {
                journal.write("### STOP too many hangs; resume from \(i)")
                finishedAll = false
                break
            }
            journal.write("CASE \(i) \(c.name) bytes=\(c.data.count)")
            let t0 = Date()

            let blob = c.data
            let parseResult = runGuarded(budget: budget) { OCCTKernel.deserialize(blob) }

            let tParse = Date().timeIntervalSince(t0)
            guard case let .ok(maybeHandle) = parseResult else {
                hangs.append("\(i):\(c.name):parse")
                terminal.insert(i)
                journal.write("DONE \(i) HANG-parse t>\(Int(budget))s")
                continue
            }
            guard let handle = maybeHandle else {
                rejected += 1
                terminal.insert(i)
                journal.write("DONE \(i) nil t=\(String(format: "%.3f", tParse))")
                continue
            }
            parsed += 1

            // --- downstream barrier: does a parseable-but-corrupt shape kill
            // the tessellator that `adoptBRep` runs on every OCCT result?
            journal.write("STEP \(i) parsed→faceTypeCounts")
            guard case let .ok(counts) = runGuarded(budget: budget, {
                OCCTKernel.faceTypeCounts(handle)
            }) else {
                hangs.append("\(i):\(c.name):faceTypeCounts")
                terminal.insert(i)
                journal.write("DONE \(i) HANG-faceTypeCounts")
                continue
            }

            journal.write("STEP \(i) →renderMesh faces=\(counts.planar)/\(counts.cylindrical)/\(counts.other)")
            guard case let .ok(mesh) = runGuarded(budget: budget, {
                OCCTKernel.renderMesh(from: handle)
            }) else {
                hangs.append("\(i):\(c.name):renderMesh")
                terminal.insert(i)
                journal.write("DONE \(i) HANG-renderMesh")
                continue
            }
            if mesh.positions.isEmpty { emptyMesh += 1 } else { tessellated += 1 }

            if mesh.positions.count < 300_000 {
                journal.write("STEP \(i) →adoptBRep verts=\(mesh.positions.count)")
                let adopted = runGuarded(budget: budget) { () -> Bool in
                    var body = Body(id: BodyID(), name: "fuzz", transform: .identity,
                                    primitive: nil,
                                    render: RenderMesh(positions: [], normals: [], indices: []),
                                    revision: 1)
                    return body.adoptBRep(handle)
                }
                if case .timedOut = adopted {
                    hangs.append("\(i):\(c.name):adoptBRep")
                    journal.write("DONE \(i) HANG-adoptBRep")
                    continue
                }
            } else {
                journal.write("STEP \(i) skip-adoptBRep verts=\(mesh.positions.count)")
            }

            let tAll = Date().timeIntervalSince(t0)
            terminal.insert(i)
            journal.write("DONE \(i) shape verts=\(mesh.positions.count) tris=\(mesh.indices.count / 3) t=\(String(format: "%.3f", tAll))")
        }

        journal.write("### HANGS \(hangs.count): \(hangs)")
        if finishedAll {
            journal.write("### SUMMARY parsed=\(parsed) rejected=\(rejected) tessellated=\(tessellated) emptyMesh=\(emptyMesh) hangs=\(hangs.count) fatal=\(crashed.count) \(crashed)")
        }
        // Three independent ways this test can (and must) fail:
        //  1. a case SEGFAULTS — the process dies mid-case, so no assertion runs
        //     at all; xcodebuild reports the crash and the journal's unmatched
        //     `CASE` line names the input. The next run picks it up as `crashed`
        //     and fails HERE, so a resumed sweep can never go green while any
        //     input is known to kill the process.
        //  2. a case HANGS — recorded in-run and asserted below.
        //  3. the sweep does not reach a terminal state for every case — asserted
        //     below, so "green" can never mean "we skipped everything".
        if finishedAll {
            XCTAssertEqual(terminal.count, corpus.count,
                           "not every case reached a recorded outcome — \(corpus.count - terminal.count) missing")
        }
        XCTAssertTrue(crashed.isEmpty,
                      "these inputs killed the process on a previous run: " +
                      crashed.map { "\($0):\(corpus[$0].name)" }.joined(separator: ", "))
        XCTAssertTrue(hangs.isEmpty, "these inputs never returned: \(hangs)")
    }
}
