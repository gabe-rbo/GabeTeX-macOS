import Foundation
import CoreGraphics
import TeXCore

/// A region of the PDF corresponding to a source position.
public struct SyncTeXBox: Sendable, Hashable {
    /// 1-based page number.
    public var page: Int
    /// Rectangle in **PDF page space** (PDF points, origin bottom-left — the PDFKit convention).
    public var rect: CGRect

    public init(page: Int, rect: CGRect) {
        self.page = page
        self.rect = rect
    }
}

/// Forward/inverse search through the `synctex` command-line tool.
///
/// Coordinate convention (verified on real pdfTeX output, see TeXToolchainChecks "SyncTeX"): the CLI uses
/// PDF points with the origin at the **top-left** of the page's media box. In `synctex view` records,
/// `h` is the left edge and `v` the **bottom** of the box (baseline + depth), so the box spans
/// `v - H … v` (y growing downward); `synctex edit -o page:x:y` takes a top-left-origin point as well.
/// Conversion to PDF page space (origin bottom-left): `x = mediaBox.minX + h`,
/// `y = mediaBox.maxY - v` (bottom edge), height `H`.
public struct SyncTeX: Sendable {
    public let distribution: TeXDistribution

    public init(distribution: TeXDistribution) {
        self.distribution = distribution
    }

    /// Source → PDF. `sourceFile` is a project URL; `mapper` translates to the shadow path recorded in the
    /// .synctex.gz. Returns boxes (possibly several) on the matched page(s); [] when nothing matches.
    public func forward(pdfURL: URL, sourceFile: URL, line: Int, column: Int, mapper: ShadowPathMapper) async -> [SyncTeXBox] {
        guard let synctex = distribution.url(for: .synctex), line >= 1 else { return [] }
        let shadowPath = mapper.shadowURL(forProjectURL: sourceFile).path
        let arguments = ["view", "-i", "\(line):\(max(column, 0)):\(shadowPath)", "-o", pdfURL.path]
        guard let output = try? await ProcessRunner.run(synctex, arguments: arguments,
                                                        environment: distribution.processEnvironment,
                                                        timeout: .seconds(10)),
              !output.cancelled, !output.timedOut else { return [] }
        let records = Self.parseViewOutput(output.stdoutText)
        guard !records.isEmpty else { return [] }
        let geometry = PageGeometry(pdfURL: pdfURL)
        var seen = Set<SyncTeXBox>()
        var result: [SyncTeXBox] = []
        for record in records {
            guard let mediaBox = geometry.mediaBox(page: record.page) else { continue }
            let box = SyncTeXBox(page: record.page, rect: Self.pageSpaceRect(record, mediaBox: mediaBox))
            if seen.insert(box).inserted { result.append(box) }
        }
        return result
    }

    /// PDF → source. `point` is in PDF page space (origin bottom-left) of 1-based `page`.
    public func inverse(pdfURL: URL, page: Int, point: CGPoint, mapper: ShadowPathMapper) async -> SourceLocation? {
        guard let synctex = distribution.url(for: .synctex), page >= 1,
              let mediaBox = PageGeometry(pdfURL: pdfURL).mediaBox(page: page) else { return nil }
        let p = Self.synctexPoint(fromPageSpace: point, mediaBox: mediaBox)
        let arguments = ["edit", "-o", "\(page):\(Self.format(p.x)):\(Self.format(p.y)):\(pdfURL.path)"]
        guard let output = try? await ProcessRunner.run(synctex, arguments: arguments,
                                                        environment: distribution.processEnvironment,
                                                        timeout: .seconds(10)),
              !output.cancelled, !output.timedOut,
              let record = Self.parseEditOutput(output.stdoutText),
              let url = mapper.projectURL(forShadowPath: record.input) else { return nil }
        return SourceLocation(fileURL: Self.canonicalSpelling(of: url, within: mapper.projectDirectory),
                              line: record.line, column: record.column)
    }

    // MARK: Pure helpers (unit-tested)

    struct ViewRecord: Equatable, Sendable {
        var page: Int
        var h: Double, v: Double, width: Double, height: Double
    }

    struct EditRecord: Equatable, Sendable {
        var input: String
        var line: Int
        var column: Int?
    }

    /// `synctex view` output: one record per `Page:` line, followed by `x: y: h: v: W: H:` fields.
    static func parseViewOutput(_ text: String) -> [ViewRecord] {
        var records: [ViewRecord] = []
        var current: [String: Double] = [:]
        var page: Int?
        func flush() {
            if let page, let h = current["h"], let v = current["v"] {
                records.append(ViewRecord(page: page, h: h, v: v, width: current["W"] ?? 0, height: current["H"] ?? 0))
            }
            current = [:]
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SyncTeX result end") {
                flush()
                page = nil
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            if key == "Page" {
                flush()
                page = Int(value)
            } else if ["x", "y", "h", "v", "W", "H"].contains(key), let number = Double(value) {
                current[key] = number
            }
        }
        flush()
        return records
    }

    /// `synctex edit` output: the first `Input:` / `Line:` / `Column:` record. Column -1 → nil.
    static func parseEditOutput(_ text: String) -> EditRecord? {
        var input: String?
        var line: Int?
        var column: Int?
        for raw in text.split(separator: "\n") {
            if raw.hasPrefix("Input:") {
                if input != nil, line != nil { break }    // a second record starts
                input = String(raw.dropFirst("Input:".count))
            } else if raw.hasPrefix("Line:") {
                line = Int(raw.dropFirst("Line:".count).trimmingCharacters(in: .whitespaces))
            } else if raw.hasPrefix("Column:") {
                let c = Int(raw.dropFirst("Column:".count).trimmingCharacters(in: .whitespaces)) ?? -1
                column = c > 0 ? c : nil
            }
        }
        guard let input, !input.isEmpty, let line, line >= 1 else { return nil }
        return EditRecord(input: input, line: line, column: column)
    }

    /// `synctex view` box (top-left origin, `v` = bottom edge) → PDF page space rectangle.
    static func pageSpaceRect(_ record: ViewRecord, mediaBox: CGRect) -> CGRect {
        CGRect(x: mediaBox.minX + record.h, y: mediaBox.maxY - record.v,
               width: max(record.width, 0), height: max(record.height, 0))
    }

    /// PDF page-space point → `synctex edit` point (top-left origin).
    static func synctexPoint(fromPageSpace point: CGPoint, mediaBox: CGRect) -> CGPoint {
        CGPoint(x: point.x - mediaBox.minX, y: mediaBox.maxY - point.y)
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }

    /// The on-disk spelling (Unicode normalization and, on case-insensitive volumes, letter case) of a project
    /// file, so URLs compare equal to the ones the app got from its file tree. Returns `url` unchanged when
    /// nothing better is found.
    static func canonicalSpelling(of url: URL, within projectDirectory: URL) -> URL {
        let root = projectDirectory.standardizedFileURL.path
        let base = root == "/" ? "" : root
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return url }
        var current = base
        for component in path.dropFirst(base.count + 1).split(separator: "/") {
            let wanted = String(component)
            let wantedNFC = wanted.precomposedStringWithCanonicalMapping
            let names = (try? FileManager.default.contentsOfDirectory(atPath: current.isEmpty ? "/" : current)) ?? []
            if let match = names.first(where: { $0 == wanted })
                ?? names.first(where: { $0.precomposedStringWithCanonicalMapping == wantedNFC }) {
                current += "/" + match
                continue
            }
            // A case-insensitive volume opened `Chapters/Intro.tex` for chapters/intro.tex: use the real case
            // (only when unambiguous — on a case-sensitive volume both spellings may exist).
            let folded = LaTeXCompiler.foldedKey(wanted)
            let caseMatches = names.filter { LaTeXCompiler.foldedKey($0) == folded }
            current += "/" + (caseMatches.count == 1 ? caseMatches[0] : wanted)
        }
        return URL(fileURLWithPath: current).standardizedFileURL
    }
}

/// Media boxes of a PDF's pages (the document is opened once per search).
private struct PageGeometry {
    let document: CGPDFDocument?

    init(pdfURL: URL) {
        document = CGPDFDocument(pdfURL as CFURL)
    }

    func mediaBox(page: Int) -> CGRect? {
        guard let document, page >= 1, page <= document.numberOfPages, let p = document.page(at: page) else { return nil }
        return p.getBoxRect(.mediaBox)
    }
}
