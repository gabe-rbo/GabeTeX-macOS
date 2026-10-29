import Foundation

/// Minimal assertion harness used by the `*Checks` executables
/// (XCTest and swift-testing are not usable with the Command Line Tools alone).
///
/// Usage in a checks `main.swift`:
/// ```swift
/// import CheckKit
/// await Check.suite("Tokenizer") {
///     Check.equal(tokens.count, 3)
///     Check.expect(tokens.first?.kind == .command, "first token is a command")
/// }
/// Check.finish()   // prints a summary and exits with status 1 if anything failed
/// ```
@MainActor
public enum Check {
    public private(set) static var passed = 0
    public private(set) static var failed = 0
    private static var currentSuite = "-"

    public static func suite(_ name: String, _ body: () async throws -> Void) async {
        currentSuite = name
        let before = failed
        do {
            try await body()
        } catch {
            fail("threw \(error)", file: #fileID, line: #line)
        }
        let status = failed == before ? "ok" : "FAILED"
        print("[\(status)] \(name)")
    }

    public static func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #fileID, line: UInt = #line
    ) {
        if condition { passed += 1 } else { fail(message(), file: file, line: line) }
    }

    public static func equal<T: Equatable>(
        _ actual: T, _ expected: T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #fileID, line: UInt = #line
    ) {
        if actual == expected {
            passed += 1
        } else {
            let extra = message()
            fail("expected \(expected), got \(actual)" + (extra.isEmpty ? "" : " — \(extra)"), file: file, line: line)
        }
    }

    public static func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        failed += 1
        print("  ✗ [\(currentSuite)] \(file):\(line): \(message)")
    }

    /// Prints a summary and terminates the process (exit 1 on any failure).
    public static func finish() -> Never {
        print("CHECKS: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
