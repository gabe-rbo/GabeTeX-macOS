import Foundation
import CheckKit
import TeXCore

@MainActor
func runSnippetChecks() async {
    func stops(_ s: Snippet) -> [String] { s.tabStops.map { "\($0.location),\($0.length)" } }

    await Check.suite("Snippet: placeholders and final cursor") {
        let frac = Snippet(parsing: "\\frac{${1:num}}{${2:den}}$0")
        Check.equal(frac.text, "\\frac{num}{den}")
        Check.equal(stops(frac), ["6,3", "11,3"])
        Check.equal(frac.finalCursor, 15)
        Check.equal(frac.mirrors, [])

        let newcommand = Snippet(parsing: "\\newcommand{${1:\\name}}[${2:0}]{${3:definition}}$0")
        Check.equal(newcommand.text, "\\newcommand{\\name}[0]{definition}")
        Check.equal(stops(newcommand), ["12,5", "19,1", "22,10"])
        Check.equal(newcommand.finalCursor, 33)

        let plain = Snippet(parsing: "\\alpha")
        Check.equal(plain.text, "\\alpha")
        Check.equal(plain.tabStops, [])
        Check.equal(plain.finalCursor, nil)

        let empty = Snippet(parsing: "")
        Check.equal(empty.text, "")
        Check.equal(empty.finalCursor, nil)

        let middle = Snippet(parsing: "\\begin{x}\n\t$0\n\\end{x}")
        Check.equal(middle.text, "\\begin{x}\n\t\n\\end{x}")
        Check.equal(middle.finalCursor, 11)

        Check.equal(stops(Snippet(parsing: "$2 $1")), ["1,0", "0,0"], "tab stops are sorted by index, bare $N has empty text")
        Check.equal(stops(Snippet(parsing: "${1}")), ["0,0"])
        Check.equal(stops(Snippet(parsing: "a${12:xy}b$10")), ["4,0", "1,2"], "multi-digit indices sort numerically (10 before 12)")
        Check.equal(stops(Snippet(parsing: "é${1:ç😀}")), ["1,3"], "UTF-16 offsets")
        Check.equal(Snippet(parsing: "é${1:ç😀}").text, "éç😀")

        let nested = Snippet(parsing: "${1:a ${2:b}}")
        Check.equal(nested.text, "a b")
        Check.equal(stops(nested), ["0,3", "2,1"])
    }

    await Check.suite("Snippet: contract — real newlines/tabs, backslash sequences, dollars") {
        // (1) real newline / tab characters are kept; backslash sequences are ordinary LaTeX.
        Check.equal(Snippet(parsing: "a\nb\tc").text, "a\nb\tc")
        let latex = "\\newcommand \\textbf{${1:x}} \\tau \\n \\t"
        Check.equal(Snippet(parsing: latex).text, "\\newcommand \\textbf{x} \\tau \\n \\t", "\\n and \\t are not escapes")
        Check.equal(Snippet(parsing: "\\begin{itemize}\n\t\\item $0\n\\end{itemize}").text, "\\begin{itemize}\n\t\\item \n\\end{itemize}")

        // (2) a `$` preceded by a backslash is never a tab stop; both characters stay.
        Check.equal(Snippet(parsing: "\\$").text, "\\$")
        let dollar = Snippet(parsing: "\\$${1:x}")
        Check.equal(dollar.text, "\\$x")
        Check.equal(stops(dollar), ["2,1"], "the second $ starts a placeholder")
        let literal = Snippet(parsing: "cost \\$1 and \\$0 and \\${1:x}")
        Check.equal(literal.text, "cost \\$1 and \\$0 and \\${1:x}")
        Check.equal(literal.tabStops, [])
        Check.equal(literal.finalCursor, nil)
        Check.equal(Snippet(parsing: "\\$5 \\$").text, "\\$5 \\$")

        // (3) defaults may contain backslashes and balanced braces.
        let frac = Snippet(parsing: "${1:\\frac{a}{b}}")
        Check.equal(frac.text, "\\frac{a}{b}")
        Check.equal(stops(frac), ["0,11"])
        Check.equal(Snippet(parsing: "${1:{}}x").text, "{}x")
        Check.equal(Snippet(parsing: "${1:\\}}x").text, "\\}x", "escaped brace inside a default")
        Check.equal(Snippet(parsing: "[${1:\\{}]").text, "[\\{]", "escaped opening brace inside a default")
        Check.equal(Snippet(parsing: "\\left\\{ ${1:x} \\right\\}").text, "\\left\\{ x \\right\\}")
        Check.equal(stops(Snippet(parsing: "\\left\\{ ${1:x} \\right\\}")), ["8,1"])

        // (4) a `$` not followed by a digit or `{` is literal.
        for literalText in ["$x$", "a $ b", "$", "$$", "US$", "$ {1}", "$a$b", "50$-$x", "${", "${a}", "${1", "${1:abc", "${1:{x}"] {
            let s = Snippet(parsing: literalText)
            Check.equal(s.text, literalText, "literal: \(literalText)")
            Check.equal(s.tabStops, [], "no tab stops: \(literalText)")
        }
        let twoDollars = Snippet(parsing: "$$0")
        Check.equal(twoDollars.text, "$")
        Check.equal(twoDollars.finalCursor, 1)
    }

    await Check.suite("Snippet: mirrors") {
        let mirror = Snippet(parsing: "${1:x} and $1")
        Check.equal(mirror.text, "x and x")
        Check.equal(stops(mirror), ["0,1"], "only the first occurrence is a tab stop")
        Check.equal(mirror.mirrors.map { $0.map { "\($0.location),\($0.length)" } }, [["6,1"]])

        let reversed = Snippet(parsing: "$1 ${1:x}")
        Check.equal(reversed.text, "x x")
        Check.equal(stops(reversed), ["0,1"])

        let triple = Snippet(parsing: "${1:ab} $1 $1")
        Check.equal(triple.text, "ab ab ab")
        Check.equal(stops(triple), ["0,2"])
        Check.equal(triple.mirrors.first?.count, 2)

        let two = Snippet(parsing: "\\begin{${1:env}} $0 \\end{$1}")
        Check.equal(two.text, "\\begin{env}  \\end{env}")
        Check.equal(stops(two), ["7,3"])
        Check.equal(two.finalCursor, 12)
    }

    await Check.suite("Snippet: every catalog item parses cleanly") {
        let all = CompletionCatalog.commands + CompletionCatalog.mathCommands + CompletionCatalog.environments + CompletionCatalog.packages
        Check.expect(all.count > 1000, "catalog size \(all.count)")
        var problems: [String] = []
        for item in all {
            let snippet = Snippet(parsing: item.insertText)
            let length = (snippet.text as NSString).length
            if snippet.text.contains("${") { problems.append("leftover ${ in \(item.label): \(item.insertText)") }
            // No unescaped `$digit` may survive.
            let ns = snippet.text as NSString
            var k = 0
            while k + 1 < ns.length {
                if ns.character(at: k) == 36, ns.character(at: k + 1) >= 48, ns.character(at: k + 1) <= 57,
                   k == 0 || ns.character(at: k - 1) != 92 {
                    problems.append("leftover $N in \(item.label): \(item.insertText)")
                    break
                }
                k += 1
            }
            for range in snippet.tabStops where range.location < 0 || NSMaxRange(range) > length {
                problems.append("range out of bounds in \(item.label)")
            }
            if let cursor = snippet.finalCursor, cursor < 0 || cursor > length { problems.append("cursor out of bounds in \(item.label)") }
            if item.insertText.isEmpty { problems.append("empty insertText for \(item.label)") }
            // Contract: line breaks and indentation are real U+000A / U+0009 characters, never the two-character
            // escapes `\n` / `\t`. A backslash followed by a letter is an ordinary control word (\newcommand,
            // \textbf), so only backslash-n/t followed by a character that cannot continue a command
            // name, open an argument or be a starred form can be a mistaken escape.
            let raw = Array(item.insertText.utf16)
            var r = 0
            while r + 2 < raw.count {
                let third = raw[r + 2]
                let isLetter = (third >= 65 && third <= 90) || (third >= 97 && third <= 122)
                if raw[r] == 92, raw[r + 1] == 110 || raw[r + 1] == 116, !isLetter,
                   third != 123, third != 42, third != 91, r == 0 || raw[r - 1] != 92 {
                    problems.append("escape-looking \\n/\\t in \(item.label): \(item.insertText.debugDescription)")
                    break
                }
                r += 1
            }
            if item.label.isEmpty || item.label.contains(" ") && item.kind != .snippet && item.kind != .file {
                problems.append("suspicious label '\(item.label)'")
            }
        }
        Check.equal(problems.prefix(10).map { $0 }, [], "catalog problems (\(problems.count) total)")

        // Environments: `name}` + args + indented body + `\end{name}`.
        for env in CompletionCatalog.environments {
            let text = Snippet(parsing: env.insertText).text
            Check.expect(text.hasPrefix(env.label + "}"), "\(env.label) starts with name}")
            Check.expect(text.hasSuffix("\n\\end{\(env.label)}"), "\(env.label) ends with \\end{name}")
            Check.expect(text.contains("\n\t"), "\(env.label) has an indented body line")
        }
        // Commands insert their own label (parameters such as \arraystretch insert a \renewcommand around it).
        var notPrefixed: [String] = []
        for item in CompletionCatalog.commands + CompletionCatalog.mathCommands where !item.insertText.contains(item.label) {
            notPrefixed.append("\(item.label) -> \(item.insertText)")
        }
        Check.equal(notPrefixed.prefix(10).map { $0 }, [], "command insertText contains its label (\(notPrefixed.count) exceptions)")
        Check.expect(CompletionCatalog.commands.allSatisfy { $0.label.hasPrefix("\\") }, "all command labels start with a backslash")
        Check.expect(CompletionCatalog.mathCommands.allSatisfy { $0.label.hasPrefix("\\") })
        Check.expect(CompletionCatalog.commands.count > 400, "text commands: \(CompletionCatalog.commands.count)")
        Check.expect(CompletionCatalog.mathCommands.count > 500, "math commands: \(CompletionCatalog.mathCommands.count)")
        Check.expect(CompletionCatalog.environments.count > 100, "environments: \(CompletionCatalog.environments.count)")
        Check.expect(CompletionCatalog.packages.count > 200, "packages: \(CompletionCatalog.packages.count)")
        print("  INFO catalog: \(CompletionCatalog.commands.count) commands, \(CompletionCatalog.mathCommands.count) math, \(CompletionCatalog.environments.count) environments, \(CompletionCatalog.packages.count) packages")
        for table in [CompletionCatalog.commands, CompletionCatalog.mathCommands, CompletionCatalog.environments, CompletionCatalog.packages] {
            var seen = Set<String>()
            let duplicates = table.map(\.label).filter { !seen.insert($0).inserted }
            Check.expect(duplicates.count < 5, "duplicate labels in one table: \(duplicates.prefix(5))")
        }
    }
}
