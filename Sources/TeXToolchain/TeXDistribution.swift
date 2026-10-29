import Foundation
import Synchronization

public enum TeXTool: String, CaseIterable, Sendable, Hashable, Codable {
    case pdflatex, xelatex, lualatex, latexmk, bibtex, biber, makeindex, chktex, synctex, tlmgr, kpsewhich
}

/// A detected TeX installation.
public struct TeXDistribution: Sendable, Hashable {
    /// Display name, e.g. "MacTeX 2026", "TeX Live 2026", "TinyTeX 2026", "TeX Live (Homebrew)".
    public var name: String
    public var year: Int?
    /// Directory containing the binaries (e.g. /Library/TeX/texbin).
    public var binDirectory: URL
    /// TEXMFROOT (e.g. /usr/local/texlive/2026), if known.
    public var texmfRoot: URL?
    /// True when tlmgr can modify the installation without administrator rights.
    public var isUserWritable: Bool
    /// Absolute paths of the tools that were found.
    public var tools: [TeXTool: URL]
    /// First line of `pdftex --version` / `tlmgr --version`, for the Settings pane.
    public var versionDescription: String?
    /// Tools that are installed but do not work, with a user-facing explanation (e.g. a broken `biber`
    /// binary). Shown in Settings; the compiler also uses it to explain failed bibliography runs.
    public var toolProblems: [TeXTool: String]

    public init(name: String, year: Int?, binDirectory: URL, texmfRoot: URL?, isUserWritable: Bool, tools: [TeXTool: URL], versionDescription: String? = nil, toolProblems: [TeXTool: String] = [:]) {
        self.name = name
        self.year = year
        self.binDirectory = binDirectory
        self.texmfRoot = texmfRoot
        self.isUserWritable = isUserWritable
        self.tools = tools
        self.versionDescription = versionDescription
        self.toolProblems = toolProblems
    }

    public func url(for tool: TeXTool) -> URL? { tools[tool] }

    /// Tools that are installed but failed their health check.
    public var brokenTools: Set<TeXTool> { Set(toolProblems.keys) }

    /// True when `tool` exists and passed its health check (tools without a check count as working).
    public func isWorking(_ tool: TeXTool) -> Bool { tools[tool] != nil && toolProblems[tool] == nil }

    /// Environment for child processes: PATH starts with `binDirectory` (GUI apps do not inherit the
    /// login shell PATH), plus `max_print_line`/`error_line`/`half_error_line` so logs do not wrap.
    public var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let basePath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = binDirectory.path + ":" + basePath
        env["max_print_line"] = "10000"
        env["error_line"] = "254"
        env["half_error_line"] = "238"
        return env
    }
}

public enum TeXDistributionLocator {
    /// Finds the best installation: `customBinDirectory` if valid, else /Library/TeX/texbin,
    /// newest /usr/local/texlive/<year>/bin/universal-darwin, ~/Library/TinyTeX/bin/*, Homebrew, login-shell PATH.
    /// Returns nil when no directory contains a working `kpsewhich` plus a LaTeX engine or latexmk.
    public static func locate(customBinDirectory: URL? = nil) async -> TeXDistribution? {
        if let customBinDirectory, let d = await inspect(binDirectory: customBinDirectory) { return d }
        for dir in staticCandidateDirectories() {
            if let d = await inspect(binDirectory: dir) { return d }
        }
        for dir in await loginShellPathDirectories() {
            if let d = await inspect(binDirectory: dir) { return d }
        }
        return nil
    }

    /// All installations found (for the Settings picker), best first, one entry per TEXMFROOT.
    public static func candidates() async -> [TeXDistribution] {
        var result: [TeXDistribution] = []
        var seenRoots = Set<String>()
        var seenDirs = Set<String>()
        let dirs = staticCandidateDirectories() + (await loginShellPathDirectories())
        for dir in dirs {
            let resolved = dir.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenDirs.insert(resolved).inserted else { continue }
            guard let d = await inspect(binDirectory: dir) else { continue }
            let key = d.texmfRoot?.resolvingSymlinksInPath().standardizedFileURL.path ?? resolved
            guard seenRoots.insert(key).inserted else { continue }
            result.append(d)
        }
        return result
    }

    /// Validates one bin directory and describes the installation it belongs to. nil if it is not a TeX
    /// installation (no `kpsewhich`, `kpsewhich --var-value TEXMFROOT` fails, or no engine/latexmk).
    public static func inspect(binDirectory: URL) async -> TeXDistribution? {
        let bin = binDirectory.standardizedFileURL
        var tools: [TeXTool: URL] = [:]
        for tool in TeXTool.allCases {
            let url = bin.appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: url.path) { tools[tool] = url }
        }
        guard let kpsewhich = tools[.kpsewhich],
              tools[.latexmk] != nil || tools[.pdflatex] != nil || tools[.xelatex] != nil || tools[.lualatex] != nil
        else { return nil }

        let env = environment(for: bin)
        guard let rootOutput = try? await ProcessRunner.run(kpsewhich, arguments: ["--var-value", "TEXMFROOT"],
                                                           environment: env, timeout: .seconds(5)),
              rootOutput.succeeded else { return nil }
        let rootPath = rootOutput.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard !rootPath.isEmpty, FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let texmfRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL

        // biber is a self-extracting binary that can be broken independently of the rest of TeX Live;
        // check it concurrently with the version probe (cached per binary).
        let biberURL = tools[.biber]
        async let biberProblem = checkBiber(biberURL, environment: env)

        // Version: pdftex is fast; tlmgr (Perl) only as a fallback.
        var versionLine: String?
        let pdftex = bin.appendingPathComponent("pdftex")
        if FileManager.default.isExecutableFile(atPath: pdftex.path),
           let out = try? await ProcessRunner.run(pdftex, arguments: ["--version"], environment: env, timeout: .seconds(5)),
           out.succeeded {
            versionLine = firstLine(out.stdoutText)
        } else if let tlmgr = tools[.tlmgr],
                  let out = try? await ProcessRunner.run(tlmgr, arguments: ["--version"], environment: env, timeout: .seconds(10)),
                  out.succeeded {
            versionLine = out.stdoutText.split(separator: "\n").first(where: { $0.contains("version") }).map(String.init)
                ?? firstLine(out.stdoutText)
        }
        let year = parseYear(versionLine: versionLine, texmfRoot: texmfRoot)
        let tlpkg = texmfRoot.appendingPathComponent("tlpkg").path
        let writable = FileManager.default.isWritableFile(atPath: tlpkg)
        let name = distributionName(binDirectory: bin, texmfRoot: texmfRoot, year: year)
        var problems: [TeXTool: String] = [:]
        if let p = await biberProblem { problems[.biber] = p }
        return TeXDistribution(name: name, year: year, binDirectory: bin, texmfRoot: texmfRoot,
                               isUserWritable: writable, tools: tools, versionDescription: versionLine,
                               toolProblems: problems)
    }

    // MARK: - Tool health

    private static let healthCache = HealthCache()

    private static func checkBiber(_ biber: URL?, environment: [String: String]) async -> String? {
        guard let biber else { return nil }
        return await biberHealth(biber, environment: environment)
    }

    /// Runs `biber --version` (cached per binary path + modification date). Returns a user-facing problem
    /// description when biber is installed but cannot run, nil when it works or the check was inconclusive
    /// (timeout: the first run of a healthy biber unpacks itself and can be slow).
    public static func biberHealth(_ biber: URL, environment: [String: String]? = nil) async -> String? {
        let resolved = biber.resolvingSymlinksInPath()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(resolved.path)#\(mtime)"
        if let cached = healthCache.value(for: key) { return cached }
        guard let out = try? await ProcessRunner.run(biber, arguments: ["--version"], environment: environment,
                                                     timeout: .seconds(20)) else {
            let problem = String(localized: "biber could not be started.")
            healthCache.set(problem, for: key)
            return problem
        }
        if out.timedOut || out.cancelled { return nil }
        let text = out.combinedText
        if out.succeeded && text.range(of: "biber version", options: .caseInsensitive) != nil {
            healthCache.set(nil, for: key)
            return nil
        }
        let reason = text.split(separator: "\n").last(where: { $0.contains("biber") && !$0.contains("usage") })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            ?? text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let problem = reason.isEmpty
            ? String(localized: "biber is installed but does not run.")
            : String(localized: "biber is installed but does not run (\(reason)).")
        healthCache.set(problem, for: key)
        return problem
    }

    // MARK: - Helpers (public for the checks; not needed by the app)

    /// Directories probed before the login-shell PATH, in priority order.
    public static func staticCandidateDirectories() -> [URL] {
        var dirs: [URL] = [URL(fileURLWithPath: "/Library/TeX/texbin", isDirectory: true)]
        let fm = FileManager.default
        // Newest /usr/local/texlive/<year>/bin/<arch>
        if let years = try? fm.contentsOfDirectory(atPath: "/usr/local/texlive") {
            for year in years.compactMap({ Int($0) }).sorted(by: >) {
                dirs.append(contentsOf: archDirectories(in: "/usr/local/texlive/\(year)/bin"))
            }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        dirs.append(contentsOf: archDirectories(in: home + "/Library/TinyTeX/bin"))
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        dirs.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))
        return dirs
    }

    /// `universal-darwin` first, then any other architecture directory.
    private static func archDirectories(in binRoot: String) -> [URL] {
        guard let archs = try? FileManager.default.contentsOfDirectory(atPath: binRoot) else { return [] }
        let ordered = archs.filter { !$0.hasPrefix(".") }.sorted { a, b in
            (a == "universal-darwin" ? 0 : 1, a) < (b == "universal-darwin" ? 0 : 1, b)
        }
        return ordered.map { URL(fileURLWithPath: binRoot + "/" + $0, isDirectory: true) }
    }

    /// Directories of the login shell's PATH (`/bin/zsh -lc 'printf %s "$PATH"'`, 3 s timeout).
    public static func loginShellPathDirectories() async -> [URL] {
        let zsh = URL(fileURLWithPath: "/bin/zsh")
        guard let out = try? await ProcessRunner.run(zsh, arguments: ["-lc", "printf %s \"$PATH\""], timeout: .seconds(3)),
              !out.timedOut, !out.cancelled else { return [] }
        return parseLoginShellPath(out.stdoutText)
    }

    /// The PATH is the last line of the output (profile scripts may print before it).
    public static func parseLoginShellPath(_ output: String) -> [URL] {
        let last = output.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        var seen = Set<String>()
        return last.split(separator: ":").compactMap { part in
            let p = String(part)
            guard p.hasPrefix("/"), seen.insert(p).inserted else { return nil }
            return URL(fileURLWithPath: p, isDirectory: true)
        }
    }

    /// Year from "pdfTeX 3.14… (TeX Live 2026)", "TeX Live (https://tug.org/texlive) version 2026", or a
    /// TEXMFROOT ending in the year.
    public static func parseYear(versionLine: String?, texmfRoot: URL?) -> Int? {
        if let line = versionLine {
            for pattern in [#"TeX Live (\d{4})"#, #"version (\d{4})"#] {
                if let r = line.range(of: pattern, options: .regularExpression) { return Int(line[r].suffix(4)) }
            }
        }
        if let last = texmfRoot?.lastPathComponent, last.count == 4, let y = Int(last) { return y }
        return nil
    }

    /// "MacTeX 2026" (texbin symlink into /Library/TeX/Distributions), "TinyTeX 2026", "TeX Live (Homebrew)",
    /// else "TeX Live 2026".
    public static func distributionName(binDirectory: URL, texmfRoot: URL?, year: Int?) -> String {
        let binPath = binDirectory.path
        let resolved = binDirectory.resolvingSymlinksInPath().path
        let rootPath = texmfRoot?.path ?? ""
        let yearSuffix = year.map { " \($0)" } ?? ""
        if binPath.hasPrefix("/Library/TeX/") || resolved.hasPrefix("/Library/TeX/Distributions") {
            return "MacTeX" + yearSuffix
        }
        if binPath.contains("/TinyTeX/") || rootPath.contains("/TinyTeX") {
            return "TinyTeX" + yearSuffix
        }
        if binPath.hasPrefix("/opt/homebrew") || rootPath.hasPrefix("/opt/homebrew") || rootPath.contains("/Cellar/") {
            return "TeX Live (Homebrew)"
        }
        return "TeX Live" + yearSuffix
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func environment(for bin: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}

/// Process-wide cache of tool health checks (key → problem or nil for "healthy").
private final class HealthCache: Sendable {
    private let storage = Mutex<[String: String?]>([:])

    func value(for key: String) -> String?? {
        storage.withLock { $0[key] }
    }

    func set(_ value: String?, for key: String) {
        storage.withLock { $0[key] = .some(value) }
    }
}
