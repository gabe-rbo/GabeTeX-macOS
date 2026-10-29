import Foundation
import CheckKit
import VimKit

func wordObjectChecks() {
    vim("diw", "foo b|ar baz", "foo | baz")
    vim("daw", "foo b|ar baz", "foo |baz")
    vim("daw", "foo ba|r", "fo|o")                    // last word: takes the blank before it
    vim("daw", "|foo bar", "|bar")
    vim("ciwX<Esc>", "foo b|ar baz", "foo |X baz")
    vim("diw", "foo| bar", "foo|bar")                 // iw on blanks selects the blanks
    vim("daw", "foo| bar baz", "foo| baz")            // aw on blanks: blanks + the next word
    vim("diW", "a b.|c d", "a | d")
    vim("daW", "a |b.c d", "a |d")
    vim("d2aw", "|a b c d", "|c d")
    vim("d2iw", "|foo bar baz", "|bar baz")
    vim("ciwX<Esc>", "|foo", "|X")
    vim("diw", "|ação você", "| você")                // accented letters belong to the word
    vim("ciw", "x.|y", "x.|", mode: .insert)          // punctuation and words are different classes
    vim("daw", "foo.ba|r baz", "foo.|baz")

    // Visual
    var s = run("viw", on: "foo b|ar baz")
    Check.equal(s.selectedText, "bar", "viw selects the word")
    Check.equal(s.mode, .visual)
    s = run("vawd", on: "foo b|ar baz")
    Check.equal(s.text, "foo baz", "vawd")
    s = run("viwiw", on: "foo b|ar baz")
    Check.equal(s.selectedText, "bar ", "viw viw extends over the following blanks")
    s = run("ve", on: "|a bc de")
    Check.equal(s.selectedText, "a bc", "v e from a one-letter word")
    s = run("vee", on: "|a bc de")
    Check.equal(s.selectedText, "a bc de", "v e e")
}

func paragraphObjectChecks() {
    vim("dap", "|a\nb\n\nc", "|c")
    vim("dap", "a\n\n|b", "|a")                       // last paragraph: includes the blank lines before it
    vim("dip", "a\n|\n\nb", "a\n|b")
    vim("cipX<Esc>", "a\n|b\n\nc", "|X\n\nc")
    vim("yapP", "|a\n\nb", "|a\n\na\n\nb")
    vim("dip", "a\nb\n|c\n\nd", "|\nd")
    let s = run("vip", on: "x\n\na\n|b\nc\n\ny")
    Check.equal(s.selectedText, "a\nb\nc\n", "vip selects whole lines")
    Check.equal(s.mode, .visualLine)
}

func bracketObjectChecks() {
    vim("di(", "f(a, |b)", "f(|)")
    vim("da(", "f(a, |b)", "|f")
    vim("ci(X<Esc>", "f(a, |b)", "f(|X)")
    vim("dib", "f(a, |b)", "f(|)")
    vim("dab", "f(a, |b)", "|f")
    vim("di)", "f(a, |b)", "f(|)")
    vim("di(", "((a|))", "((|))")
    vim("d2i(", "(a (b |c) d)", "(|)")
    vim("da(", "(a (b |c) d)", "(a | d)")
    vim("d2a(", "x (a (b |c) d) y", "x | y")
    vim("di(", "|(abc)", "(|)")                       // cursor on the opening delimiter
    vim("di(", "(abc|)", "(|)")                       // cursor on the closing delimiter
    vim("di(", "(|)", "(|)")                          // empty object: nothing happens
    vim("ci(X<Esc>", "(|)", "(|X)")                   // but ci( inserts between
    vim("di(", "a |b", "a |b")                        // not inside any pair
    vim("di(", "(a) b |c", "(a) b |c")
    vim("di{", "x{a|b}y", "x{|}y")
    vim("di}", "x{a|b}y", "x{|}y")
    vim("diB", "x{a|b}y", "x{|}y")
    vim("daB", "x{a|b}y", "x|y")
    vim("di[", "x[a|b]y", "x[|]y")
    vim("da[", "x[a|b]y", "x|y")
    vim("di<", "<a|b>", "<|>")
    vim("da>", "x<a|b>y", "x|y")
    vim("yi(P", "f(a|b)", "f(a|bab)")
    vim("di(", "f(a(b)|c)", "f(|)")                  // cursor after a nested pair: the outer one
    vim("di(", "f(a\\(b|)", "f(|)")                  // an escaped parenthesis is not a delimiter
    vim("ci{X<Esc>", "\\textbf{he|llo}", "\\textbf{|X}")
    vim("di{", "\\frac{a}{b|}", "\\frac{a}{|}")

    // Multi-line blocks select whole lines.
    vim("di{", "if (x) {\n  a;\n  |b;\n}", "if (x) {\n|}")
    vim("ci{X<Esc>", "if (x) {\n  a;\n  |b;\n}", "if (x) {\n  |X\n}")
    vim("da{", "a {\n  |b\n}", "a| ")
    vim("di{", "{\n|a\n  b\n}", "{\n|}")
    vim("yi{P", "{\n|a\n}", "{\n|a\na\n}")

    let s = run("vi(", on: "f(a, |b)")
    Check.equal(s.selectedText, "a, b", "vi( selects the inside")
    let t = run("vi(i(", on: "((a|b))")
    Check.equal(t.selectedText, "(ab)", "repeating i( grows the selection")
    let u = run("va(", on: "f(a, |b)")
    Check.equal(u.selectedText, "(a, b)", "va( includes the delimiters")
}

func quoteObjectChecks() {
    vim("di\"", "say \"he|llo\" now", "say \"|\" now")
    vim("da\"", "say \"he|llo\" now", "say |now")
    vim("da\"", "say \"he|llo\"", "sa|y")               // no trailing blank: take the leading blanks
    vim("di\"", "|x \"abc\"", "x \"|\"")                  // cursor before the string: the next pair
    vim("di\"", "|\"abc\" d", "\"|\" d")                  // on the opening quote
    vim("di\"", "\"abc|\" d", "\"|\" d")                  // on the closing quote
    vim("ci'X<Esc>", "a 'b|c' d", "a '|X' d")
    vim("di`", "`a|b`", "`|`")
    vim("di\"", "\"a\\\"b|c\"", "\"|\"")                  // escaped quote inside
    vim("di\"", "\"a\" \"b|\"", "\"a\" \"|\"")
    vim("di\"", "\"a\" |x \"b\"", "\"a\"|\"b\"")          // between two strings: Vim uses the nearest quotes
    vim("di\"", "a \" b|", "a \" |b")                    // unbalanced
    vim("di\"", "\"a\nb|\"", "\"a\nb|\"")             // never pairs quotes across lines
    vim("d2i\"", "x \"a|b\" y", "x | y")                 // 2i" includes the quotes
    vim("ci\"X<Esc>", "\"|\"", "\"|X\"")
    vim("yi\"P", "\"a|b\"", "\"a|bab\"")
    let s = run("vi\"", on: "x \"a|b\" y")
    Check.equal(s.selectedText, "ab", "vi\"")
    let t = run("va\"", on: "x \"a|b\" y")
    Check.equal(t.selectedText, "\"ab\" ", "va\" includes the trailing blank")
}

func mathObjectChecks() {
    vim("di$", "a $x+|y$ b", "a $|$ b")
    vim("da$", "a $x+|y$ b", "a | b")
    vim("ci$X<Esc>", "$a+|b$", "$|X$")
    vim("di$", "|$a+b$", "$|$")                        // on the opening delimiter
    vim("di$", "$a+b|$", "$|$")                        // on the closing delimiter
    vim("di$", "$a$ and $b|$", "$a$ and $|$")          // the pair around the cursor
    vim("di$", "$a$ x| $b$", "$a$ x $|$")              // between formulas: the next one on the line
    vim("di$", "$a|$ and $b$", "$|$ and $b$")
    vim("di$", "$$ x|y $$", "$$|$$")
    vim("di$", "\\(a+|b\\)", "\\(|\\)")
    vim("di$", "\\[ x|y \\]", "\\[|\\]")
    vim("da$", "x \\(a|\\) y", "x | y")
    vim("di$", "cost \\$5 and $x|$", "cost \\$5 and $|$")  // \$ is not a delimiter
    vim("di$", "$a+\nb|$", "$|$")                      // formulas may span lines ...
    vim("di$", "$a\n\nb|$", "$a\n\nb|$")               // ... but not blank lines
    vim("di$", "no math |here", "no math |here")
    vim("di$", "% $x|$\n", "% $x|$\n")                 // comments are skipped
    vim("yi$P", "$a|b$", "$a|bab$")
    vim("ci$x^2<Esc>", "$|y$", "$x^|2$")
    let s = run("vi$", on: "a $x+|y$ b")
    Check.equal(s.selectedText, "x+y", "vi$")
    let t = run("va$", on: "a $x+|y$ b")
    Check.equal(t.selectedText, "$x+y$", "va$")
}

func environmentObjectChecks() {
    let item = "\\begin{itemize}\n  \\item a|\n\\end{itemize}"
    vim("die", item, "\\begin{itemize}\n|\\end{itemize}")
    vim("dae", item, "|")
    vim("cieX<Esc>", item, "\\begin{itemize}\n  |X\n\\end{itemize}")
    vim("yaeP", "\\begin{a}\nx|\n\\end{a}", "|\\begin{a}\nx\n\\end{a}\\begin{a}\nx\n\\end{a}")
    vim("die", "\\begin{a}x|\\end{a}", "\\begin{a}|\\end{a}")
    vim("die", "\\begin{a}|\\end{a}", "\\begin{a}|\\end{a}")   // empty environment: nothing to delete
    vim("cieX<Esc>", "\\begin{a}|\\end{a}", "\\begin{a}|X\\end{a}")

    let nested = "\\begin{figure}\n\\begin{center}\nx|\n\\end{center}\n\\end{figure}"
    vim("die", nested, "\\begin{figure}\n\\begin{center}\n|\\end{center}\n\\end{figure}")
    vim("d2ie", nested, "\\begin{figure}\n|\\end{figure}")
    vim("dae", nested, "\\begin{figure}\n|\\end{figure}")
    vim("d3ie", nested, "\\begin{figure}\n\\begin{center}\n|x\n\\end{center}\n\\end{figure}")                                              // no third level: unchanged
    vim("die", "\\begin{tabular}{cc}\na|\n\\end{tabular}", "\\begin{tabular}{cc}\n|\\end{tabular}")
    vim("die", "\\begin{figure}[h]\nx|\n\\end{figure}", "\\begin{figure}[h]\n|\\end{figure}")
    vim("die", "\\be|gin{a}\nx\n\\end{a}", "\\begin{a}\n|\\end{a}")        // cursor on \begin
    vim("die", "\\begin{a}\nx\n\\en|d{a}", "\\begin{a}\n|\\end{a}")        // cursor on \end
    vim("die", "x|", "|x")                                                  // not inside an environment
    vim("die", "% \\begin{a}\nx|\n% \\end{a}", "% \\begin{a}\n|x\n% \\end{a}")   // commented out
    vim("die", "\\begin{a}\n\\begin{b}\nx\n\\end{b}\ny|\n\\end{a}", "\\begin{a}\n|\\end{a}")
    let s = run("vie", on: "\\begin{a}\nx|\ny\n\\end{a}")
    Check.equal(s.selectedText, "x\ny\n", "vie selects the inner lines")
    let t = run("vae", on: "pre \\begin{a}\nx|\n\\end{a} post")
    Check.equal(t.selectedText, "\\begin{a}\nx\n\\end{a}", "vae selects the whole environment")
}
