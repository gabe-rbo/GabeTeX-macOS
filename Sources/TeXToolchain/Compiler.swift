import Foundation
import TeXCore

public enum TeXEngine: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case pdflatex, xelatex, lualatex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pdflatex: "pdfLaTeX"
        case .xelatex: "XeLaTeX"
        case .lualatex: "LuaLaTeX"
        }
    }

    /// latexmk flag selecting this engine.
    public var latexmkFlag: String {
        switch self {
        case .pdflatex: "-pdf"
        case .xelatex: "-xelatex"
        case .lualatex: "-lualatex"
        }
    }

    /// Parses `% !TEX program = …` values ("xelatex", "XeLaTeX", "lualatex", "pdflatex", "latexmk -xelatex"…).
    public init?(magicProgram: String) {
        let p = magicProgram.lowercased()
        if p.contains("xelatex") || p.contains("xetex") { self = .xelatex }
        else if p.contains("lualatex") || p.contains("luatex") { self = .lualatex }
        else if p.contains("pdflatex") || p.contains("pdftex") || p == "latex" { self = .pdflatex }
        else { return nil }
    }
}

public enum CompilePurpose: Sendable, Hashable {
    /// Debounced background compile while typing: uses unsaved buffers, never touches project files.
    case live
    /// Explicit build (⌘B / save): additionally copies the PDF atomically next to the root file
    /// (`<root dir>/<jobname>.pdf`, see `CompileResult.exportedPDFURL`). The .synctex.gz stays in the
    /// shadow output directory (it records shadow paths; use `CompileResult.pathMapper`).
    case build
}

public struct CompileRequest: Sendable {
    public var projectDirectory: URL
    public var rootFile: URL
    public var engine: TeXEngine
    /// Unsaved editor contents, keyed by standardized project file URL.
    public var overlays: [URL: String]
    /// Encoding to write each overlay with (the buffer's on-disk encoding, e.g. ISO Latin-1 for legacy
    /// `inputenc{latin1}` projects). Missing entries — or text the encoding cannot represent — use UTF-8.
    public var overlayEncodings: [URL: String.Encoding] = [:]
    public var purpose: CompilePurpose
    public var shellEscape: Bool
    public var extraArguments: [String]
    /// Wall-clock limit for the whole latexmk run (an endless TeX loop never ends on its own).
    /// nil = 5 minutes for `.live`, 30 minutes for `.build`.
    public var timeout: Duration?

    public init(projectDirectory: URL, rootFile: URL, engine: TeXEngine, overlays: [URL: String] = [:], purpose: CompilePurpose, shellEscape: Bool = false, extraArguments: [String] = [], timeout: Duration? = nil) {
        self.timeout = timeout
        self.projectDirectory = projectDirectory
        self.rootFile = rootFile
        self.engine = engine
        self.overlays = overlays
        self.purpose = purpose
        self.shellEscape = shellEscape
        self.extraArguments = extraArguments
    }
}

public enum CompileStatus: Sendable, Hashable {
    case succeeded
    /// TeX finished but reported errors (a PDF may still exist).
    case failed
    case cancelled
    /// Could not run at all (no distribution, latexmk missing, …). Message is user-facing.
    case toolError(String)
}

/// Maps paths between the user's project directory and the private shadow workspace the compiler
/// runs in (see ARCHITECTURE.md §Shadow workspace).
///
/// The shadow also mirrors a few folders *above* the project (the ancestor layer), so that
/// `\input{../macros}` compiles; paths in that layer map back to the real files outside the project.
public struct ShadowPathMapper: Sendable, Hashable {
    public var projectDirectory: URL
    public var shadowDirectory: URL
    /// The real folder mirrored by the shadow's ancestor layer (an ancestor of `projectDirectory`), or nil.
    public var ancestorDirectory: URL?
    /// Where `ancestorDirectory` is mirrored in the shadow (an ancestor of `shadowDirectory`), or nil.
    public var ancestorShadowDirectory: URL?

    public init(projectDirectory: URL, shadowDirectory: URL) {
        self.projectDirectory = projectDirectory.standardizedFileURL
        self.shadowDirectory = shadowDirectory.standardizedFileURL
    }

    /// A mapper that also translates the ancestor layer: `ancestorShadowDirectory/<rel>` ⇄ `ancestorDirectory/<rel>`.
    public init(projectDirectory: URL, shadowDirectory: URL, ancestorDirectory: URL?, ancestorShadowDirectory: URL?) {
        self.init(projectDirectory: projectDirectory, shadowDirectory: shadowDirectory)
        if let ancestorDirectory, let ancestorShadowDirectory {
            self.ancestorDirectory = ancestorDirectory.standardizedFileURL
            self.ancestorShadowDirectory = ancestorShadowDirectory.standardizedFileURL
        }
    }

    /// Maps a path as written by TeX/SyncTeX (absolute, or relative to the shadow directory, possibly
    /// starting with "./") back to the project — or, for a file reached with `../` (ancestor layer), to the
    /// real file outside the project. Returns nil for files outside the shadow (e.g. TeX Live files).
    public func projectURL(forShadowPath path: String) -> URL? {
        let shadowRoot = shadowDirectory.path
        var p = path
        if !p.hasPrefix("/") {
            if p.hasPrefix("./") { p.removeFirst(2) }
            p = shadowRoot + "/" + p
        }
        // Lexical, not URL.standardizedFileURL: that resolves `..` through the file system, i.e. through the
        // mirror's symlinks, and would turn `<shadow>/../macros.tex` into the target before we can map it.
        let standardized = Self.lexicallyStandardized(p)
        if let rel = Self.relativePath(of: standardized, under: shadowRoot) {
            return projectDirectory.appendingPathComponent(rel).standardizedFileURL
        }
        if let ancestorDirectory, let ancestorShadowDirectory,
           let rel = Self.relativePath(of: standardized, under: ancestorShadowDirectory.path) {
            return (rel.isEmpty ? ancestorDirectory : ancestorDirectory.appendingPathComponent(rel)).standardizedFileURL
        }
        return nil
    }

    /// The shadow path corresponding to a project file (or to a file of the ancestor layer).
    public func shadowURL(forProjectURL url: URL) -> URL {
        let std = URL(fileURLWithPath: Self.lexicallyStandardized(url.path)).standardizedFileURL.path
        let root = projectDirectory.path
        if std.hasPrefix(root + "/") {
            return shadowDirectory.appendingPathComponent(String(std.dropFirst(root.count + 1)))
        }
        if let ancestorDirectory, let ancestorShadowDirectory {
            let base = ancestorDirectory.path == "/" ? "" : ancestorDirectory.path
            if std.hasPrefix(base + "/") {
                return ancestorShadowDirectory.appendingPathComponent(String(std.dropFirst(base.count + 1)))
            }
        }
        return url
    }

    /// An absolute path with `.`, `..` and empty components removed purely textually (no symlink resolution).
    static func lexicallyStandardized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` relative to `root` ("" for the root itself), tolerating the /private/var ⇄ /var alias.
    private static func relativePath(of path: String, under root: String) -> String? {
        let candidates = [root, "/private" + root, root.replacingOccurrences(of: "/private/", with: "/")]
        for candidate in candidates where path == candidate || path.hasPrefix(candidate + "/") {
            return String(path.dropFirst(candidate.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return nil
    }
}

public struct CompileResult: Sendable {
    public var status: CompileStatus
    /// PDF produced in the shadow output directory (what the preview displays). nil if none.
    public var pdfURL: URL?
    /// For `.build`: the PDF copied next to the root file.
    public var exportedPDFURL: URL?
    public var synctexURL: URL?
    /// Diagnostics mapped to project paths, errors first then by file/line.
    public var diagnostics: [Diagnostic]
    /// Raw TeX log (the .log file) — shown in the "Log" tab.
    public var log: String
    /// latexmk's stdout/stderr.
    public var toolOutput: String
    public var duration: TimeInterval
    /// Files TeX reported as missing (e.g. ["tikz-cd.sty"]), for the package installer.
    public var missingFiles: [String]
    public var pathMapper: ShadowPathMapper

    public init(status: CompileStatus, pdfURL: URL? = nil, exportedPDFURL: URL? = nil, synctexURL: URL? = nil, diagnostics: [Diagnostic] = [], log: String = "", toolOutput: String = "", duration: TimeInterval = 0, missingFiles: [String] = [], pathMapper: ShadowPathMapper) {
        self.status = status
        self.pdfURL = pdfURL
        self.exportedPDFURL = exportedPDFURL
        self.synctexURL = synctexURL
        self.diagnostics = diagnostics
        self.log = log
        self.toolOutput = toolOutput
        self.duration = duration
        self.missingFiles = missingFiles
        self.pathMapper = pathMapper
    }
}
