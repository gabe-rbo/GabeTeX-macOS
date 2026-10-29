import Foundation
import CheckKit
import TeXCore

@MainActor
func runBibChecks() async {
    let url = fileURL("refs.bib")
    func parse(_ text: String) -> [BibEntry] { BibParser.entries(in: text, fileURL: url) }
    func summary(_ e: BibEntry) -> String {
        "\(e.type)|\(e.key)|\(e.author ?? "-")|\(e.title ?? "-")|\(e.year ?? "-")|\(e.line)"
    }

    await Check.suite("BibParser: typical file") {
        let bib = """
        % leading comment
        @comment{ignore {nested} me}
        @preamble{"\\newcommand{\\noop}[1]{}"}
        @string{jan = "January"}

        Some free text between entries (and an email me@example.com).

        @article{knuth1984,
          author  = {Knuth, Donald E.},
          title   = {The {TeX}book},
          year    = 1984,
          month   = jan,
        }
        @BOOK{Hatcher2002, AUTHOR="Hatcher, Allen" # " and Other", Title = "Algebraic {Topology}", year = "2002" }
        @book(parens, title = {Parenthesised}, year = {1999})
        % @article{commented, title = {No}}
        @misc{nofields}
        @inproceedings{multi,
          title = {A very
                   long title   spanning lines},
          author = {Doe, Jane and
                    Roe, Richard},
          date = {2020-05-01},
        }
        """
        let entries = parse(bib)
        Check.equal(entries.map(summary), [
            "article|knuth1984|Knuth, Donald E.|The TeXbook|1984|8",
            "book|Hatcher2002|Hatcher, Allen and Other|Algebraic Topology|2002|14",
            "book|parens|-|Parenthesised|1999|15",
            "misc|nofields|-|-|-|17",
            "inproceedings|multi|Doe, Jane and Roe, Richard|A very long title spanning lines|2020|18",
        ])
        Check.expect(entries.allSatisfy { $0.fileURL == url })
    }

    await Check.suite("BibParser: edge cases") {
        // Recovery from a missing closing brace.
        let broken = parse("@article{broken, title = {Unclosed\n@book{good, title = {Fine}}\n")
        Check.equal(broken.map(\.key), ["broken", "good"])
        Check.equal(broken.last?.title, "Fine")
        Check.equal(broken.last?.line, 2)

        // CRLF and CR line endings.
        let crlf = parse("@article{a,\r\n title = {T},\r\n year = 2000\r\n}\r\n@book{b, title={U}}")
        Check.equal(crlf.map { "\($0.key):\($0.line)" }, ["a:1", "b:5"])
        Check.equal(crlf.first?.year, "2000")
        let cr = parse("@article{a,\r title = {T}\r}\r@book{b, title={U}}")
        Check.equal(cr.map { "\($0.key):\($0.line)" }, ["a:1", "b:4"])

        // EOF inside an entry.
        Check.equal(parse("@article{eof, title = {abc").map(\.key), ["eof"])
        Check.equal(parse("@article{eof,").map(\.key), ["eof"])
        Check.equal(parse("@article{").count, 0)
        Check.equal(parse("").count, 0)
        Check.equal(parse("no entries here @ all").count, 0)

        // Keys with punctuation, trailing comma, empty entry.
        Check.equal(parse("@article{Doe:2020-ab_c+d/x, title={x}}").first?.key, "Doe:2020-ab_c+d/x")
        Check.equal(parse("@article{k,}").map(\.key), ["k"])
        Check.equal(parse("@article{ spaced , title = {x} }").first?.key, "spaced", "key is trimmed")
        Check.equal(parse("@Article{Mixed, Title = {x}}").first?.type, "article", "types are lowercased, keys keep their case")
        Check.equal(parse("@Article{Mixed, Title = {x}}").first?.key, "Mixed")
        Check.equal(parse("@online{k, url = {http://a.b/c%20d}, title = {t}}").first?.title, "t", "% inside a value is not a comment")

        // Values.
        Check.equal(parse("@a{k, title = {Cost: \\{x\\}}}").first?.title, "Cost: {x}", "escaped braces survive")
        Check.equal(parse("@a{k, author = {{Barnes and Noble, Inc.}}}").first?.author, "Barnes and Noble, Inc.", "protective braces removed")
        Check.equal(parse("@a{k, title = \"Say {\\\"o}\"}").first?.title, "Say \\\"o", "braced quote inside a quoted value")
        Check.equal(parse("@a{k, author = {A} # { and B}}").first?.author, "A and B", "concatenation with braces")
        Check.equal(parse("@a{k, author = \"A\" # \" and \" # \"B\"}").first?.author, "A and B", "concatenation keeps inner spaces")
        Check.equal(parse("@a{k, title = {  padded   value  }}").first?.title, "padded value")
        Check.equal(parse("@a{k, editor = {Ed, Itor}}").first?.author, "Ed, Itor", "editor is used when there is no author")
        Check.equal(parse("@a{k, author = {Au}, editor = {Ed}}").first?.author, "Au")
        Check.equal(parse("@a{k, date = {2019-12-31}}").first?.year, "2019")
        Check.equal(parse("@a{k, year = {2001}, date = {2019-12-31}}").first?.year, "2001", "explicit year wins")
        Check.equal(parse("@a{k, TITLE = {upper}, title = {second}}").first?.title, "upper", "first field wins")
        Check.equal(parse("@a{k, volume = 12, title = {t}}").first?.title, "t", "bare numbers")
        Check.equal(parse("@a{k, title = {Ação — é 😀}, year = {2020}}").first?.title, "Ação — é 😀")

        // Skipped entry types do not leak.
        Check.equal(parse("@comment{@article{inside, title={x}}}\n@article{real, title={y}}").map(\.key), ["real"])
        Check.equal(parse("@string{a = \"x\"}\n@string(b = \"y\")\n@article{real}").map(\.key), ["real"])
        Check.equal(parse("@preamble{ \"\\usepackage{x}\" }\n@article{real}").map(\.key), ["real"])

        // Many entries.
        let many = (0..<500).map { "@article{key\($0), title = {Title \($0)}, year = \(1500 + $0)}" }.joined(separator: "\n")
        let parsed = parse(many)
        Check.equal(parsed.count, 500)
        Check.equal(parsed.last?.key, "key499")
        Check.equal(parsed.last?.line, 500)
    }
}
