import Foundation

public enum PackageManagerError: Error, Sendable, Equatable, LocalizedError {
    case tlmgrNotFound
    case userCancelledAuthorization
    case notFoundInRepository(String)
    /// The local TeX Live is older than the remote repository (frozen) — user must upgrade TeX Live.
    case distributionFrozen(String)
    /// tlmgr itself must be updated first (`tlmgr update --self`).
    case tlmgrNeedsUpdate
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .tlmgrNotFound: String(localized: "tlmgr was not found in the TeX distribution.")
        case .userCancelledAuthorization: String(localized: "Authorization was cancelled.")
        case .notFoundInRepository(let f): String(localized: "No TeX Live package provides \(f).")
        case .distributionFrozen(let m): m
        case .tlmgrNeedsUpdate: String(localized: "The TeX Live manager needs to be updated first.")
        case .failed(let m): m
        }
    }
}

/// Finds and installs missing TeX Live packages with tlmgr.
/// Installation uses an administrator prompt when the distribution is not user-writable.
public actor TeXPackageManager {
    public let distribution: TeXDistribution

    public init(distribution: TeXDistribution) {
        self.distribution = distribution
    }

    /// `kpsewhich file` succeeds (the file is findable by TeX).
    public func isInstalled(file: String) async -> Bool {
        guard let kpsewhich = distribution.url(for: .kpsewhich), !file.isEmpty else { return false }
        guard let out = try? await ProcessRunner.run(kpsewhich, arguments: [file],
                                                     environment: distribution.processEnvironment,
                                                     timeout: .seconds(10)) else { return false }
        return out.succeeded && !out.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Package names whose files include `file` (e.g. "tikz-cd.sty" → ["tikz-cd"]),
    /// via `tlmgr search --global --file /<file>` (needs the network; 60 s timeout); best match first.
    public func packages(providing file: String) async throws(PackageManagerError) -> [String] {
        guard let tlmgr = distribution.url(for: .tlmgr) else { throw .tlmgrNotFound }
        let name = (file as NSString).lastPathComponent
        guard !name.isEmpty else { return [] }
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(tlmgr, arguments: Self.searchArguments(file: name),
                                                 environment: distribution.processEnvironment, timeout: .seconds(60))
        } catch {
            throw .failed(error.localizedMessage)
        }
        if output.cancelled { throw .failed(String(localized: "The package search was cancelled.")) }
        if output.timedOut {
            throw .failed(String(localized: "The TeX Live package repository did not respond in time. Check your internet connection."))
        }
        let text = output.combinedText
        if let error = Self.mapError(output: text, exitCode: output.exitCode ?? -1) {
            if case .failed = error, !Self.parseSearchOutput(text).isEmpty {
                // tlmgr printed results and a harmless warning; use the results.
            } else {
                throw error
            }
        }
        return Self.rank(Self.parseSearchOutput(text), for: name)
    }

    /// Installs packages; returns tlmgr's output. Uses an administrator prompt unless the distribution
    /// is user-writable.
    public func install(_ packages: [String]) async throws(PackageManagerError) -> String {
        let names = packages.filter { !$0.isEmpty }
        guard !names.isEmpty else { return "" }
        if let bad = names.first(where: { !Self.isValidPackageName($0) }) {
            throw .failed(String(localized: "“\(bad)” is not a valid TeX Live package name."))
        }
        return try await runTlmgr(["install"] + names)
    }

    /// `tlmgr update --self` (with admin prompt if needed).
    public func updateManager() async throws(PackageManagerError) -> String {
        try await runTlmgr(["update", "--self"])
    }

    private func runTlmgr(_ arguments: [String]) async throws(PackageManagerError) -> String {
        guard let tlmgr = distribution.url(for: .tlmgr) else { throw .tlmgrNotFound }
        let invocation = Self.invocation(tlmgr: tlmgr, arguments: arguments, userWritable: distribution.isUserWritable,
                                         prompt: String(localized: "GabeTeX needs administrator rights to install TeX Live packages."))
        let output: ProcessOutput
        do {
            // Not killed at app quit: interrupting tlmgr half-way can leave TeX Live inconsistent.
            output = try await ProcessRunner.run(invocation.executable, arguments: invocation.arguments,
                                                 environment: distribution.processEnvironment, timeout: .seconds(1800),
                                                 killOnTerminateAll: false)
        } catch {
            throw .failed(error.localizedMessage)
        }
        if output.cancelled { throw .failed(String(localized: "The installation was cancelled.")) }
        if output.timedOut { throw .failed(String(localized: "The installation took too long and was stopped.")) }
        let text = output.combinedText
        if let error = Self.mapError(output: text, exitCode: output.exitCode ?? -1) { throw error }
        return text
    }

    // MARK: Command construction (pure, unit-tested)

    struct Invocation: Equatable, Sendable {
        var executable: URL
        var arguments: [String]
    }

    /// `tlmgr search --global --file /<file>`. tlmgr treats the pattern as a Perl regular expression, so
    /// metacharacters in the file name are escaped.
    static func searchArguments(file: String) -> [String] {
        ["search", "--global", "--file", "/" + regexEscaped(file)]
    }

    static func regexEscaped(_ text: String) -> String {
        var result = ""
        for ch in text {
            if "\\.^$|?*+()[]{}".contains(ch) { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    /// TeX Live package names: letters, digits and `-_.+` (e.g. "tikz-cd", "biber.universal-darwin").
    static func isValidPackageName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.unicodeScalars.allSatisfy {
            ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || "-_.+".unicodeScalars.contains($0)
        }
    }

    /// Direct tlmgr when the installation is user-writable, else
    /// `osascript -e 'do shell script "<sh>" with administrator privileges with prompt "<prompt>" without altering line endings'`.
    static func invocation(tlmgr: URL, arguments: [String], userWritable: Bool, prompt: String) -> Invocation {
        if userWritable { return Invocation(executable: tlmgr, arguments: arguments) }
        let shell = ([tlmgr.path] + arguments).map(shellQuoted).joined(separator: " ")
        let script = "do shell script \(appleScriptString(shell)) with administrator privileges with prompt "
            + "\(appleScriptString(prompt)) without altering line endings"
        return Invocation(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script])
    }

    /// Single-quotes a word for /bin/sh (`'` becomes `'\''`).
    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal: backslashes and double quotes escaped.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Output parsing (pure, unit-tested)

    /// `tlmgr search --file` output: `pkg:` header lines followed by tab-indented file paths.
    /// Returns (package, files) in output order.
    static func parseSearchOutput(_ text: String) -> [(package: String, files: [String])] {
        var result: [(package: String, files: [String])] = []
        for raw in text.split(separator: "\n") {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if let first = line.first, first == "\t" || first == " " {
                let path = line.trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !result.isEmpty { result[result.count - 1].files.append(path) }
                continue
            }
            guard line.hasSuffix(":"), !line.hasPrefix("tlmgr"), !line.contains(" ") else { continue }
            let name = String(line.dropLast())
            guard !name.isEmpty else { continue }
            result.append((name, []))
        }
        return result
    }

    /// Keeps packages that contain a file named exactly `file`, best first: name == file stem, then
    /// name == the parent directory of the file, then the rest (in tlmgr's order).
    static func rank(_ entries: [(package: String, files: [String])], for file: String) -> [String] {
        let stem = (file as NSString).deletingPathExtension.lowercased()
        var scored: [(score: Int, index: Int, name: String)] = []
        for (index, entry) in entries.enumerated() {
            let matching = entry.files.filter { ($0 as NSString).lastPathComponent == file }
            guard !matching.isEmpty || entry.files.isEmpty else { continue }
            let base = entry.package.split(separator: ".").first.map { String($0).lowercased() } ?? entry.package.lowercased()
            let parents = Set(matching.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased() })
            let score = base == stem ? 0 : parents.contains(base) ? 1 : 2
            scored.append((score, index, entry.package))
        }
        var seen = Set<String>()
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    /// Maps tlmgr / osascript failures. Returns nil when the output does not indicate a failure.
    static func mapError(output: String, exitCode: Int32) -> PackageManagerError? {
        if output.contains("(-128)") || output.contains("User canceled") || output.contains("User cancelled") {
            return .userCancelledAuthorization
        }
        if output.contains("tlmgr itself needs to be updated") { return .tlmgrNeedsUpdate }
        if let line = output.split(separator: "\n").first(where: { $0.contains("is older than remote repository") }) {
            let detail = line.replacingOccurrences(of: "tlmgr: ", with: "").trimmingCharacters(in: .whitespaces)
            return .distributionFrozen(String(localized: "Your TeX Live is older than the package repository (\(detail)). Install the current TeX Live / MacTeX to get new packages."))
        }
        if let line = output.split(separator: "\n").first(where: { $0.contains("not present in repository") }) {
            // "tlmgr install: package foo not present in repository."
            var name = ""
            if let r = line.range(of: "package ") {
                name = String(line[r.upperBound...].prefix(while: { $0 != " " }))
            }
            return .notFoundInRepository(name.isEmpty ? String(line) : name)
        }
        guard exitCode != 0 else { return nil }
        let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(tail.isEmpty ? String(localized: "tlmgr failed (exit status \(exitCode)).") : tail)
    }
}
