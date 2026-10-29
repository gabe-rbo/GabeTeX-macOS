import Foundation
import CoreGraphics
import PDFKit
import CheckKit
import TeXCore
@testable import TeXToolchain

// End-to-end checks of SectionPageLocator (page of each section heading through SyncTeX) on real PDFs made by
// this Mac's TeX: article sections, book chapters, a heading in an included file, no SyncTeX data.
// Run on their own: swift run TeXToolchainChecks --section-pages

/// A paragraph of ordinary text, `count` times, separated by blank lines.
private func filler(_ count: Int) -> String {
    let paragraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. "
        + "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat."
    return (0..<count).map { _ in paragraph }.joined(separator: "\n\n") + "\n"
}

/// 1-based line of the first line of `text` that contains `needle`.
private func line(of needle: String, in text: String) -> Int {
    for (offset, content) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where content.contains(needle) {
        return offset + 1
    }
    return 0
}

/// The 1-based page PDFKit finds `word` on first (case-sensitive).
private func page(of word: String, in document: PDFDocument?) -> Int? {
    guard let document, let selection = document.findString(word, withOptions: []).first,
          let found = selection.pages.first else { return nil }
    return document.index(for: found) + 1
}

@MainActor
func sectionPageChecks() async {
    guard let dist = await TeXDistributionLocator.locate() else {
        Check.fail("no TeX distribution found")
        return
    }
    let compiler = LaTeXCompiler(distribution: dist, shadowRoot: Fixtures.scratch("section-pages-shadow"))

    await Check.suite("SectionPageLocator: article sections, an included file, a heading at the top of a page") {
        let project = Fixtures.scratch("section-pages-article")
        let main = project.appendingPathComponent("main.tex")
        let delta = project.appendingPathComponent("sections/delta.tex")
        let text = "\\documentclass{article}\n\\usepackage[a4paper,margin=2.5cm]{geometry}\n\\begin{document}\n"
            + filler(8) + "\n\\section{HeadAlpha}\n" + filler(4) + "\\subsection{HeadBeta}\n" + filler(10)
            + "\\clearpage\n\\section{HeadGamma\nspanning two lines}\n" + filler(6) + "\\input{sections/delta}\n" + filler(30)
            + "\\section{HeadEpsilon}\nShort.\n\\end{document}\n"
        let deltaText = "\\section{HeadDelta}\n" + filler(3)
        Fixtures.write(text, to: main)
        Fixtures.write(deltaText, to: delta)
        let result = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        guard result.status == .succeeded, let pdf = result.pdfURL else {
            Check.fail("compile failed: \(result.status) \(describe(result.diagnostics))")
            return
        }
        Check.expect(SectionPageLocator.hasSyncTeXData(for: pdf), "the compile left SyncTeX data")

        let headings: [SectionPageLocator.Heading] = [
            .init(key: "alpha", fileURL: main, line: line(of: "\\section{HeadAlpha}", in: text), endLine: line(of: "\\section{HeadAlpha}", in: text)),
            .init(key: "beta", fileURL: main, line: line(of: "\\subsection{HeadBeta}", in: text), endLine: line(of: "\\subsection{HeadBeta}", in: text)),
            .init(key: "gamma", fileURL: main, line: line(of: "\\section{HeadGamma", in: text), endLine: line(of: "spanning two lines}", in: text)),
            .init(key: "delta", fileURL: delta, line: 1, endLine: 1),
            .init(key: "epsilon", fileURL: main, line: line(of: "\\section{HeadEpsilon}", in: text), endLine: line(of: "\\section{HeadEpsilon}", in: text)),
        ]
        guard let output = await SectionPageLocator.locate(headings, pdfURL: pdf, distribution: dist, mapper: result.pathMapper) else {
            Check.fail("no answer")
            return
        }
        let document = PDFDocument(url: pdf)
        Check.equal(output.totalPages, document?.pageCount ?? -1, "total pages")
        Check.equal(output.placements[SectionStatistics.frontMatterID], HeadingPlacement(page: 1, isAtPageTop: true))
        for (key, word) in [("alpha", "HeadAlpha"), ("beta", "HeadBeta"), ("gamma", "HeadGamma"), ("delta", "HeadDelta"), ("epsilon", "HeadEpsilon")] {
            Check.equal(output.placements[key]?.page, page(of: word, in: document), "page of \(word)")
        }
        Check.equal(output.placements["alpha"]?.isAtPageTop, false, "Alpha comes after eight paragraphs")
        Check.equal(output.placements["beta"]?.isAtPageTop, false)
        Check.equal(output.placements["gamma"]?.isAtPageTop, true, "Gamma follows \\clearpage")
        Check.equal(output.placements["delta"]?.isAtPageTop, false, "Delta comes after six paragraphs")
        Check.expect((output.placements["gamma"]?.page ?? 0) > (output.placements["beta"]?.page ?? 99), "Gamma starts a later page than Beta")
        Check.expect((output.placements["epsilon"]?.page ?? 0) >= (output.placements["delta"]?.page ?? 99))

        // From placements to spans, in reading order.
        let order = [SectionStatistics.frontMatterID, "alpha", "beta", "gamma", "delta", "epsilon"]
        let spans = PageAttribution.spans(placements: order.map { output.placements[$0] }, totalPages: output.totalPages)
        let gammaPage = output.placements["gamma"]?.page ?? 0
        Check.equal(spans[2]?.first, output.placements["beta"]?.page, "Beta starts on its page")
        Check.equal(spans[2]?.last, gammaPage - 1, "Beta ends the page before Gamma, which starts a page")
        Check.equal(spans[5]?.last, output.totalPages, "the last section runs to the last page")
        Check.equal(spans[1]?.isApproximate, true, "Alpha and Beta share a page")

        // The same PDF without its SyncTeX file, and too many headings.
        let bare = Fixtures.scratch("section-pages-bare")
        let copy = bare.appendingPathComponent("main.pdf")
        try? FileManager.default.copyItem(at: pdf, to: copy)
        Check.equal(SectionPageLocator.hasSyncTeXData(for: copy), false)
        let none = await SectionPageLocator.locate(headings, pdfURL: copy, distribution: dist, mapper: result.pathMapper)
        Check.equal(none, nil, "no SyncTeX data, no answer")
        let many = (0...SectionPageLocator.headingLimit).map { SectionPageLocator.Heading(key: "\($0)", fileURL: main, line: 1, endLine: 1) }
        Check.equal(await SectionPageLocator.locate(many, pdfURL: pdf, distribution: dist, mapper: result.pathMapper), nil, "too many headings")
        let nothing = await SectionPageLocator.locate([], pdfURL: pdf, distribution: dist, mapper: result.pathMapper)
        Check.equal(nothing?.placements.count, 1, "no headings: only the front matter")
        // A heading line that does not exist in the PDF is simply missing.
        let ghost = await SectionPageLocator.locate([.init(key: "ghost", fileURL: project.appendingPathComponent("nothere.tex"), line: 3, endLine: 3)],
                                                    pdfURL: pdf, distribution: dist, mapper: result.pathMapper)
        Check.equal(ghost?.placements["ghost"], nil)
    }

    await Check.suite("SectionPageLocator: book chapters start pages (their running headers and blank pages do not fool it)") {
        let project = Fixtures.scratch("section-pages-book")
        let main = project.appendingPathComponent("main.tex")
        let text = "\\documentclass[a4paper,11pt]{book}\n\\begin{document}\n"
            + "\\chapter{HeadChOne}\n\\section{HeadSecOneOne}\n" + filler(12) + "\\section{HeadSecOneTwo}\n" + filler(10)
            + "\\chapter{HeadChTwo}\n\\section{HeadSecTwoOne}\n" + filler(8)
            + "\\chapter{HeadChThree}\n" + filler(2) + "\\end{document}\n"
        Fixtures.write(text, to: main)
        let result = await compiler.compile(CompileRequest(projectDirectory: project, rootFile: main, engine: .pdflatex, purpose: .live))
        guard result.status == .succeeded, let pdf = result.pdfURL else {
            Check.fail("compile failed: \(result.status) \(describe(result.diagnostics))")
            return
        }
        let titles = ["HeadChOne", "HeadSecOneOne", "HeadSecOneTwo", "HeadChTwo", "HeadSecTwoOne", "HeadChThree"]
        let headings = titles.map { title -> SectionPageLocator.Heading in
            let number = line(of: "{\(title)}", in: text)
            return .init(key: title, fileURL: main, line: number, endLine: number)
        }
        guard let output = await SectionPageLocator.locate(headings, pdfURL: pdf, distribution: dist, mapper: result.pathMapper) else {
            Check.fail("no answer")
            return
        }
        let document = PDFDocument(url: pdf)
        for title in titles {
            Check.equal(output.placements[title]?.page, page(of: title, in: document), "page of \(title)")
        }
        for chapter in ["HeadChOne", "HeadChTwo", "HeadChThree"] {
            Check.equal(output.placements[chapter]?.isAtPageTop, true, "\(chapter) opens its page")
        }
        for section in ["HeadSecOneOne", "HeadSecOneTwo", "HeadSecTwoOne"] {
            Check.equal(output.placements[section]?.isAtPageTop, false, "\(section) sits below the chapter title or in the middle of a page")
        }
        // Chapter 1 ends before chapter 2's page, with its sections' pages included.
        let order = [SectionStatistics.frontMatterID] + titles
        let own = PageAttribution.spans(placements: order.map { output.placements[$0] }, totalPages: output.totalPages)
        let nested = PageAttribution.subtreeSpans(levels: [-1, 1, 2, 2, 1, 2, 1], spans: own)
        let chapterTwoPage = output.placements["HeadChTwo"]?.page ?? 0
        Check.equal(nested[1]?.first, 1)
        Check.equal(nested[1]?.last, chapterTwoPage - 1, "chapter 1 ends the page before chapter 2 (the blank page of \\cleardoublepage included)")
        Check.equal(nested[4]?.first, chapterTwoPage)
        Check.equal(nested[6]?.last, output.totalPages)
    }
}
