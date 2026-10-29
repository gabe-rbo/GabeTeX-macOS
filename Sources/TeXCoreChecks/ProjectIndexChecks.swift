import Foundation
import CheckKit
import TeXCore

/// In-memory project: relative path → contents.
private struct FakeProject {
    var files: [String: String]

    func url(_ path: String) -> URL { fileURL(path) }
    func read(_ url: URL) -> String? {
        let prefix = "/proj/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return files[String(url.path.dropFirst(prefix.count))]
    }
    func exists(_ url: URL) -> Bool { read(url) != nil }
}

@MainActor
func runProjectIndexChecks() async {
    await Check.suite("ProjectIndex.resolve") {
        let existing: Set<String> = [
            "/proj/sections/deep.tex", "/proj/x", "/proj/x.tex", "/proj/y", "/proj/refs.bib", "/proj/fig/plot.png",
            "/proj/fig/plot.pdf", "/proj/fig/only.png", "/proj/fig/exact.jpg", "/proj/mystyle.sty", "/proj/myclass.cls",
            "/abs/file.tex", "/proj/chapters/c1a.tex", "/proj/chapters/sub/part.tex", "/proj/imp/x.tex", "/abs/d/x.tex",
            "/proj/shared/x.tex", "/proj/code.c", "/proj/script.py", "/proj/sections/intro.tex", "/proj/main.tex",
            "/proj/plain/refs2.bib", "/proj/chapters/local.tex",
        ]
        let exists: (URL) -> Bool = { existing.contains($0.path) }
        let root = fileURL("main.tex")
        let intro = fileURL("sections/intro.tex")
        let c1 = fileURL("chapters/c1.tex")

        func resolve(_ kind: IncludeReference.Kind, _ argument: String, directory: String? = nil,
                     from including: URL? = nil) -> String? {
            let reference = IncludeReference(kind: kind, argument: argument, directory: directory, line: 1, range: NSRange(location: 0, length: 0))
            return ProjectIndex.resolve(reference, includingFile: including ?? intro, rootFile: root, fileExists: exists)?.path
        }

        Check.equal(resolve(.input, "sections/deep"), "/proj/sections/deep.tex", "\\input appends .tex")
        Check.equal(resolve(.input, "deep"), nil, "\\input is relative to the ROOT directory, not the including file")
        Check.equal(resolve(.input, "sections/deep.tex"), "/proj/sections/deep.tex")
        Check.equal(resolve(.input, "./sections/deep"), "/proj/sections/deep.tex", "leading ./")
        Check.equal(resolve(.input, "  sections/deep \n"), "/proj/sections/deep.tex", "argument whitespace")
        Check.equal(resolve(.input, "x"), "/proj/x", "extensionless file wins over x.tex for \\input")
        Check.equal(resolve(.input, "/abs/file"), "/abs/file.tex", "absolute path")
        Check.equal(resolve(.input, "nothing"), nil)
        Check.equal(resolve(.input, ""), nil)
        Check.equal(resolve(.include, "sections/deep"), "/proj/sections/deep.tex")
        Check.equal(resolve(.include, "y"), nil, "\\include always appends .tex")
        Check.equal(resolve(.include, "x"), "/proj/x.tex")
        Check.equal(resolve(.bibliography, "refs"), "/proj/refs.bib")
        Check.equal(resolve(.bibliography, "refs.bib"), "/proj/refs.bib")
        Check.equal(resolve(.bibliography, "plain/refs2"), "/proj/plain/refs2.bib")
        Check.equal(resolve(.addbibresource, "refs.bib"), "/proj/refs.bib")
        Check.equal(resolve(.addbibresource, "refs"), nil, "\\addbibresource keeps the name as written")
        Check.equal(resolve(.includegraphics, "fig/plot"), "/proj/fig/plot.pdf", "pdf is tried before png")
        Check.equal(resolve(.includegraphics, "fig/only"), "/proj/fig/only.png")
        Check.equal(resolve(.includegraphics, "fig/exact.jpg"), "/proj/fig/exact.jpg")
        Check.equal(resolve(.includegraphics, "fig/plot.png"), "/proj/fig/plot.png")
        Check.equal(resolve(.includegraphics, "fig/none"), nil)
        Check.equal(resolve(.includepdf, "fig/plot"), "/proj/fig/plot.pdf")
        Check.equal(resolve(.usepackage, "mystyle"), "/proj/mystyle.sty")
        Check.equal(resolve(.usepackage, "amsmath"), nil)
        Check.equal(resolve(.documentclass, "myclass"), "/proj/myclass.cls")
        Check.equal(resolve(.lstinputlisting, "code.c"), "/proj/code.c")
        Check.equal(resolve(.inputminted, "script.py"), "/proj/script.py")
        // Kinds relative to the including file's directory.
        Check.equal(resolve(.subfile, "c1a", from: c1), "/proj/chapters/c1a.tex", "\\subfile is relative to the including file")
        Check.equal(resolve(.subfile, "c1a", from: root), nil)
        Check.equal(resolve(.subimport, "part", directory: "sub/", from: c1), "/proj/chapters/sub/part.tex")
        Check.equal(resolve(.subimport, "x", directory: "../shared/", from: c1), "/proj/shared/x.tex", "directory with ..")
        Check.equal(resolve(.importFile, "x", directory: "imp/", from: c1), "/proj/imp/x.tex", "\\import dir is relative to the root")
        Check.equal(resolve(.importFile, "x", directory: "/abs/d/", from: c1), "/abs/d/x.tex", "absolute \\import dir")
        Check.equal(resolve(.input, "local", from: c1), nil, "\\input in a subdirectory still uses the root directory")
    }

    await Check.suite("ProjectIndex.build: outline interleaving, nesting, aggregation, cycles") {
        let project = FakeProject(files: [
            "main.tex": """
            \\documentclass{article}
            \\usepackage{amsmath}
            \\newcommand{\\R}{\\mathbb{R}}
            \\begin{document}
            \\section{Intro}
            \\label{sec:intro}
            \\input{sections/intro}
            \\section{Methods}
            \\input{sections/methods}
            \\include{sections/results}
            \\bibliography{refs}
            \\end{document}
            % !TEX program = lualatex
            """,
            "sections/intro.tex": """
            \\subsection{Background}
            \\label{sub:bg}
            \\input{sections/deep}
            \\subsection{Goals}
            """,
            "sections/deep.tex": """
            \\subsubsection{Deep}
            \\label{deep:1}
            \\input{sections/intro}
            """,
            "sections/methods.tex": """
            \\subsection{Setup}
            \\label{eq:setup}
            \\newcommand{\\Z}{\\mathbb{Z}}
            \\addbibresource{extra.bib}
            \\input{sections/missing}
            \\input{data.csv}
            \\includegraphics{figs/plot}
            """,
            "sections/results.tex": """
            \\section{Results}
            \\newtheorem{thm}{Theorem}
            \\begin{thm}\\label{thm:main} x \\end{thm}
            """,
            "refs.bib": "@article{knuth1984, author={Knuth, Donald}, title={Literate Programming}, year=1984}",
            "extra.bib": "@book{hatcher2002, author = {Hatcher, Allen}, title = {Algebraic Topology}, year = {2002}}",
            "data.csv": "a,b",
        ])
        let root = project.url("main.tex")
        let index = ProjectIndex.build(rootFile: root, read: project.read, fileExists: project.exists)

        Check.equal(index.rootFile, root)
        Check.equal(index.files.map(\.path), ["/proj/main.tex", "/proj/sections/intro.tex", "/proj/sections/deep.tex",
                                               "/proj/sections/methods.tex", "/proj/sections/results.tex"],
                    "depth-first document order, deduplicated, cycle-safe")
        Check.equal(index.includeGraph[root]?.map(\.path),
                    ["/proj/sections/intro.tex", "/proj/sections/methods.tex", "/proj/sections/results.tex"])
        Check.equal(index.includeGraph[project.url("sections/intro.tex")]?.map(\.path), ["/proj/sections/deep.tex"])
        Check.equal(index.includeGraph[project.url("sections/deep.tex")]?.map(\.path), ["/proj/sections/intro.tex"], "cycle edge is recorded")
        Check.equal(index.includeGraph[project.url("sections/results.tex")], nil)

        Check.equal(describeOutline(index.outline), [
            "section:Intro",
            "  label:sec:intro",
            "  subsection:Background",
            "    label:sub:bg",
            "    subsubsection:Deep",
            "      label:deep:1",
            "  subsection:Goals",
            "section:Methods",
            "  subsection:Setup",
            "    label:eq:setup",
            "section:Results",
            "  label:thm:main",
        ])
        // Entries keep their own file and line (1-based).
        let intro = index.outline.first
        Check.equal(intro?.entry.fileURL, root)
        Check.equal(intro?.entry.line, 5)
        let background = intro?.children?.first { $0.entry.title == "Background" }
        Check.equal(background?.entry.fileURL.path, "/proj/sections/intro.tex")
        Check.equal(background?.entry.line, 1)
        let deep = background?.children?.first { $0.entry.kind == .subsubsection }
        Check.equal(deep?.entry.fileURL.path, "/proj/sections/deep.tex")
        func leavesHaveNilChildren(_ nodes: [OutlineNode]) -> Bool {
            nodes.allSatisfy { node in
                if node.entry.kind == .label { return node.children == nil }
                return node.children.map(leavesHaveNilChildren) ?? true
            }
        }
        Check.expect(leavesHaveNilChildren(index.outline), "labels are leaves (children == nil)")
        var ids = Set<String>()
        func collectIDs(_ nodes: [OutlineNode]) { for n in nodes { ids.insert(n.id); collectIDs(n.children ?? []) } }
        collectIDs(index.outline)
        Check.equal(ids.count, 12, "node ids are unique")

        Check.equal(index.labels.map(\.key), ["sec:intro", "sub:bg", "deep:1", "eq:setup", "thm:main"])
        Check.equal(index.labels.first { $0.key == "deep:1" }?.context, "Deep")
        Check.equal(index.labels.first { $0.key == "thm:main" }?.context, "thm")
        Check.equal(index.bibFiles.map(\.path), ["/proj/extra.bib", "/proj/refs.bib"], "bib files in document order")
        Check.equal(index.bibEntries.map(\.key), ["hatcher2002", "knuth1984"])
        Check.equal(index.bibEntries.first?.fileURL.path, "/proj/extra.bib")
        Check.equal(index.customCommands.map(\.label), ["\\R", "\\Z"])
        Check.equal(index.customEnvironments, ["thm"])
        Check.equal(index.magicComments.program, "lualatex")

        let symbols = index.symbols(projectFiles: ["a.tex"])
        Check.equal(symbols.labels.count, 5)
        Check.equal(symbols.bibEntries.count, 2)
        Check.equal(symbols.projectFiles, ["a.tex"])
        Check.equal(symbols.customEnvironments, ["thm"])
    }

    await Check.suite("ProjectIndex.build: subfile, import, edge cases") {
        let project = FakeProject(files: [
            "main.tex": """
            \\documentclass{article}
            \\begin{document}
            \\subfile{chapters/c1}
            \\subimport{sub/}{part}
            \\import{imp/}{x}
            \\end{document}
            """,
            "chapters/c1.tex": """
            \\documentclass[../main.tex]{subfiles}
            \\begin{document}
            \\section{C1}
            \\subfile{c1a}
            \\end{document}
            """,
            "chapters/c1a.tex": "\\subsection{C1A}\n",
            "sub/part.tex": "\\section{Part from sub}\n",
            "imp/x.tex": "\\section{Imported}\n",
        ])
        let root = project.url("main.tex")
        let index = ProjectIndex.build(rootFile: root, read: project.read, fileExists: project.exists)
        Check.equal(index.files.map(\.path), ["/proj/main.tex", "/proj/chapters/c1.tex", "/proj/chapters/c1a.tex", "/proj/sub/part.tex", "/proj/imp/x.tex"])
        Check.equal(describeOutline(index.outline), ["section:C1", "  subsection:C1A", "section:Part from sub", "section:Imported"])

        // Root that cannot be read.
        let empty = ProjectIndex.build(rootFile: fileURL("missing.tex"), read: { _ in nil }, fileExists: { _ in false })
        Check.equal(empty.files.map(\.path), ["/proj/missing.tex"])
        Check.equal(empty.outline.count, 0)

        // Self-include and mutual cycle terminate.
        let cyc = FakeProject(files: ["a.tex": "\\section{A}\\input{a}\\input{b}", "b.tex": "\\section{B}\\input{a}"])
        let cycIndex = ProjectIndex.build(rootFile: cyc.url("a.tex"), read: cyc.read, fileExists: cyc.exists)
        Check.equal(cycIndex.files.map(\.path), ["/proj/a.tex", "/proj/b.tex"])
        Check.equal(describeOutline(cycIndex.outline), ["section:A", "section:B"])

        // Labels before the first heading are top-level; headings out of order nest by level.
        let flat = FakeProject(files: ["main.tex": "\\label{first}\n\\subsection{Deep first}\n\\section{Then up}\n\\label{l2}\n\\subsubsection{Skip a level}\n"])
        let flatIndex = ProjectIndex.build(rootFile: flat.url("main.tex"), read: flat.read, fileExists: flat.exists)
        Check.equal(describeOutline(flatIndex.outline), [
            "label:first", "subsection:Deep first", "section:Then up", "  label:l2", "  subsubsection:Skip a level",
        ])

        // Entries after the last include and between two includes keep their position.
        let mix = FakeProject(files: [
            "main.tex": "\\section{One}\n\\input{p}\n\\section{Two}\n\\input{q}\n\\section{Three}\n",
            "p.tex": "\\subsection{P}\n", "q.tex": "\\subsection{Q}\n",
        ])
        let mixIndex = ProjectIndex.build(rootFile: mix.url("main.tex"), read: mix.read, fileExists: mix.exists)
        Check.equal(describeOutline(mixIndex.outline), ["section:One", "  subsection:P", "section:Two", "  subsection:Q", "section:Three"])

        // An include on the same line as a heading, after it.
        let sameLine = FakeProject(files: ["main.tex": "\\section{A} \\input{p} \\section{B}\n", "p.tex": "\\subsection{P}\n"])
        let sameIndex = ProjectIndex.build(rootFile: sameLine.url("main.tex"), read: sameLine.read, fileExists: sameLine.exists)
        Check.equal(describeOutline(sameIndex.outline), ["section:A", "  subsection:P", "section:B"])

        // A commented-out include is ignored; an include inside a comment inside a heading is too.
        let commented = FakeProject(files: ["main.tex": "% \\input{p}\n\\section{A}\n", "p.tex": "\\section{P}\n"])
        let commentedIndex = ProjectIndex.build(rootFile: commented.url("main.tex"), read: commented.read, fileExists: commented.exists)
        Check.equal(commentedIndex.files.count, 1)

        // Local .sty definitions are picked up.
        let sty = FakeProject(files: ["main.tex": "\\usepackage{local}\n", "local.sty": "\\newcommand{\\fromsty}[1]{#1}\n\\newtheorem{styenv}{S}"])
        let styIndex = ProjectIndex.build(rootFile: sty.url("main.tex"), read: sty.read, fileExists: sty.exists)
        Check.equal(styIndex.customCommands.map(\.label), ["\\fromsty"])
        Check.equal(styIndex.customEnvironments, ["styenv"])

        // Same bib referenced twice is listed once.
        let bib = FakeProject(files: ["main.tex": "\\bibliography{r}\\addbibresource{r.bib}\n", "r.bib": "@misc{k, title={T}}"])
        let bibIndex = ProjectIndex.build(rootFile: bib.url("main.tex"), read: bib.read, fileExists: bib.exists)
        Check.equal(bibIndex.bibFiles.count, 1)
        Check.equal(bibIndex.bibEntries.map(\.key), ["k"])
    }

    await Check.suite("ProjectIndex.findRoot") {
        let project = FakeProject(files: [
            "main.tex": "\\documentclass{article}\n\\begin{document}\n\\input{sections/intro}\n\\input{shared}\n\\input{sections/badmagic}\n\\end{document}\n",
            "other.tex": "\\documentclass{article}\n\\begin{document}x\\end{document}\n",
            "a.tex": "\\documentclass{article}\n\\begin{document}\\input{shared}\\end{document}\n",
            "shared.tex": "\\section{Shared}\n",
            "sections/intro.tex": "\\section{Intro}\n\\input{sections/deep}\n",
            "sections/deep.tex": "\\subsection{Deep}\n",
            "sections/magic.tex": "% !TEX root = ../main.tex\n\\section{M}\n",
            "sections/abs.tex": "% !TEX root = /proj/other.tex\n\\section{M}\n",
            "sections/badmagic.tex": "% !TEX root = ../nonexistent.tex\n\\section{M}\n",
            "sections/self.tex": "\\documentclass{article}\n\\begin{document}x\\end{document}\n",
            "sub/s.tex": "\\documentclass[../main.tex]{subfiles}\n\\begin{document}\\section{S}\\end{document}\n",
            "lonely.tex": "\\section{Lonely}\n",
        ])
        let candidates = ["other.tex", "a.tex", "main.tex", "sections/self.tex", "sub/s.tex"].map(project.url)
        func root(of path: String, candidates: [URL]? = nil) -> String? {
            ProjectIndex.findRoot(for: project.url(path), candidates: candidates ?? [], read: project.read, fileExists: project.exists)?.path
        }
        Check.equal(root(of: "sections/magic.tex"), "/proj/main.tex", "magic comment (relative)")
        Check.equal(root(of: "sections/abs.tex"), "/proj/other.tex", "magic comment (absolute)")
        Check.equal(root(of: "sections/badmagic.tex", candidates: candidates), "/proj/main.tex", "bad magic comment falls back to the candidates")
        Check.equal(root(of: "sections/self.tex"), "/proj/sections/self.tex", "a root document is its own root")
        Check.equal(root(of: "sections/intro.tex", candidates: candidates), "/proj/main.tex", "closure search; other.tex does not include it")
        Check.equal(root(of: "sections/deep.tex", candidates: candidates), "/proj/main.tex", "two levels deep")
        Check.equal(root(of: "shared.tex", candidates: candidates), "/proj/main.tex", "main.tex is preferred over a.tex when both include the file")
        Check.equal(root(of: "shared.tex", candidates: ["a.tex", "other.tex"].map(project.url)), "/proj/a.tex")
        Check.equal(root(of: "lonely.tex", candidates: candidates), nil)
        Check.equal(root(of: "lonely.tex"), nil)
        Check.equal(root(of: "sub/s.tex"), "/proj/main.tex", "subfiles document points at its main file")
        Check.equal(root(of: "unreadable.tex"), nil)
    }
}
