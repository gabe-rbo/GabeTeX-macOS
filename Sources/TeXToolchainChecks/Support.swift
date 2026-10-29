import Foundation
import CheckKit
import TeXCore
@testable import TeXToolchain

/// Paths and helpers shared by the TeXToolchain checks.
enum Fixtures {
    /// `<package>/Tests/Fixtures/TeXToolchain`, found from this source file's location.
    static let root: URL = {
        let here = URL(fileURLWithPath: #filePath)            // …/Sources/TeXToolchainChecks/Support.swift
        return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/TeXToolchain", isDirectory: true)
    }()

    @MainActor
    static func log(_ name: String) -> String {
        let url = root.appendingPathComponent("logs").appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            Check.fail("missing fixture \(name)")
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func text(_ relativePath: String) -> String {
        let url = root.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func project(_ name: String) -> URL {
        root.appendingPathComponent("projects").appendingPathComponent(name, isDirectory: true).standardizedFileURL
    }

    /// The mapping LaTeXCompiler uses, approximated for logs produced by `make-logs.sh`: relative paths
    /// (relative to the compile cwd = the project directory) map into the fixture project when the file exists.
    static func mapper(for project: String) -> (String) -> URL? {
        let dir = Fixtures.project(project)
        return { path in
            guard !path.hasPrefix("/") else { return nil }
            var p = path
            if p.hasPrefix("./") { p.removeFirst(2) }
            let url = dir.appendingPathComponent(p).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// A private scratch directory on this Mac (under $TMPDIR), recreated empty.
    static func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GabeTeXToolchainChecks", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Compact description of a diagnostic for failure messages.
func describe(_ d: Diagnostic) -> String {
    let file = d.fileURL?.lastPathComponent ?? "-"
    return "[\(d.severity) \(d.source.rawValue)] \(file):\(d.line.map(String.init) ?? "?"):\(d.column.map(String.init) ?? "?") \(d.message)"
}

func describe(_ ds: [Diagnostic]) -> String {
    ds.map(describe).joined(separator: "\n      ")
}

/// Asserts that exactly one diagnostic matches `message` (exact) and checks its location/severity.
@MainActor
@discardableResult
func expectDiagnostic(
    _ diagnostics: [Diagnostic], message: String, severity: DiagnosticSeverity, file: URL?, line: Int?,
    column: Int?? = .none, length: Int?? = .none, source: DiagnosticSource = .tex, missingFile: String?? = .none,
    sourceFile: StaticString = #fileID, sourceLine: UInt = #line
) -> Diagnostic? {
    let matches = diagnostics.filter { $0.message == message }
    guard matches.count == 1, let d = matches.first else {
        Check.fail("expected exactly one diagnostic “\(message)”, found \(matches.count) in:\n      \(describe(diagnostics))",
                   file: sourceFile, line: sourceLine)
        return nil
    }
    Check.equal(d.severity, severity, "severity of “\(message)”", file: sourceFile, line: sourceLine)
    Check.equal(d.source, source, "source of “\(message)”", file: sourceFile, line: sourceLine)
    Check.equal(d.fileURL?.standardizedFileURL.path, file?.standardizedFileURL.path, "file of “\(message)”", file: sourceFile, line: sourceLine)
    Check.equal(d.line, line, "line of “\(message)”", file: sourceFile, line: sourceLine)
    if case .some(let c) = column { Check.equal(d.column, c, "column of “\(message)”", file: sourceFile, line: sourceLine) }
    if case .some(let l) = length { Check.equal(d.length, l, "length of “\(message)”", file: sourceFile, line: sourceLine) }
    if case .some(let m) = missingFile { Check.equal(d.missingFile, m, "missingFile of “\(message)”", file: sourceFile, line: sourceLine) }
    return d
}

/// Process ids whose command line matches `pattern` (via /usr/bin/pgrep -f).
func pgrep(_ pattern: String) async -> [Int32] {
    guard let out = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", pattern],
                                                 timeout: .seconds(5)) else { return [] }
    return out.stdoutText.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
}

/// Seconds elapsed while running `body`.
func measure(_ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    body()
    let c = (clock.now - start).components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}
