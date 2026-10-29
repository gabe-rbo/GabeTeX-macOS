import AppKit
import CheckKit
import EditorKit
import TeXCore
import VimKit

/// A realistic 5 000-line document (sections, prose, inline and display math, environments, comments).
func largeDocument(lines count: Int = 5_000) -> String {
    var lines: [String] = ["\\documentclass{amsart}", "\\usepackage{amsmath,amssymb}", "\\begin{document}"]
    var i = 0
    while lines.count < count - 1 {
        switch i % 12 {
        case 0: lines.append("\\section{Homology of the space \(i)}\\label{sec:\(i)}")
        case 1: lines.append("Let $X$ be a CW complex and $H_n(X;\\mathbb{Z})$ its homology, cf.~\\cite{hatcher}.")
        case 2: lines.append("We compute the Betti numbers $\\beta_k = \\operatorname{rank} H_k$ for $k \\le \(i % 9)$.")
        case 3: lines.append("\\begin{equation}\\label{eq:\(i)}")
        case 4: lines.append("  \\chi(X) = \\sum_{k \\ge 0} (-1)^k \\beta_k = \\frac{a_{\(i)}}{b} + \\int_0^1 f(t)\\,dt")
        case 5: lines.append("\\end{equation}")
        case 6: lines.append("% TODO: check the Smith normal form of the boundary matrix \(i)")
        case 7: lines.append("\\begin{itemize}")
        case 8: lines.append("  \\item By \\eqref{eq:\(i - 5)} and Theorem~\\ref{thm:main}, the \\emph{Euler characteristic} is invariant.")
        case 9: lines.append("\\end{itemize}")
        case 10: lines.append("Plain prose without any markup keeps the tokenizer honest about the common case of text.")
        default: lines.append("")
        }
        i += 1
    }
    lines.append("\\end{document}")
    return lines.joined(separator: "\n")
}

func performanceChecks() async {
    await Check.suite("5 000-line highlight timing") {
        let source = largeDocument()
        let length = utf16Length(source)
        let tokenizeMs = measure { _ = LaTeXTokenizer().tokenize(source as NSString) }

        let scroll = LaTeXEditorScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 1_000)
        let editor = scroll.editor
        let buffer = SourceBuffer(url: URL(fileURLWithPath: "/tmp/editorkit-checks/large.tex"), text: source)
        let attachMs = measure { editor.attach(buffer) }
        let completeMs = measure { editor.flushHighlighting() }

        // Typing in the middle of the document.
        let middle = (source as NSString).range(of: "Plain prose", options: [], range: NSRange(location: length / 2, length: length / 2 - 1)).location
        editor.setSelectedRange(NSRange(location: middle, length: 0))
        var worst = 0.0
        var total = 0.0
        let keystrokes = 60
        for k in 0..<keystrokes {
            let t = measure { type(k % 10 == 9 ? " " : "x", editor) }
            worst = max(worst, t)
            total += t
        }
        await endEvent(editor)
        // A `$` changes math state for the rest of the paragraph: worst case for re-coloring.
        let dollarMs = measure {
            type("$", editor)
            editor.flushHighlighting()
        }
        let fresh = LaTeXTokenizer().tokenize(editor.textStorage?.mutableString ?? "")
        Check.expect(editor.syntaxTokens == fresh, "incremental highlighting converges to a fresh tokenization")
        Check.expect(!buffer.isDirty || buffer.changeCount == keystrokes + 1, "one change per keystroke")

        // Buffer swap round trip (cached tokens).
        let small = SourceBuffer(url: URL(fileURLWithPath: "/tmp/editorkit-checks/small.tex"), text: "\\section{A}")
        editor.attach(small)
        let reattachMs = measure { editor.attach(buffer) }

        print("    5 000 lines, \(length / 1024) KB: tokenize \(ms(tokenizeMs)); attach (tokenize + visible coloring) \(ms(attachMs)); "
              + "color everything \(ms(completeMs)); keystroke avg \(ms(total / Double(keystrokes))), worst \(ms(worst)); "
              + "\"$\" + full recolor \(ms(dollarMs)); re-attach (cached tokens, mid-document scroll restored) \(ms(reattachMs))")
        Check.expect(attachMs < 2_000, "attach is reasonably fast even in debug builds")
    }

    await Check.suite("Vim adapter wiring") {
        var config = EditorConfiguration()
        config.vimMode = true
        let (tv, _) = makeEditor("hello", caret: 0, configuration: config)
        let controller = EditorController()
        controller.bind(to: tv)
        Check.expect(tv.vimEngine != nil, "engine created")
        Check.equal(controller.vimMode, tv.vimEngine?.mode, "controller mirrors the engine mode")
        config.vimMode = false
        tv.apply(config)
        Check.expect(tv.vimEngine == nil)
        Check.expect(controller.vimMode == nil, "mode cleared when Vim is off")
    }
}
