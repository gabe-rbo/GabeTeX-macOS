import Foundation
import TeXCore

// Shared helpers for the TeXCore checks.

/// `kind:text` description of every token, e.g. `["command:\\foo", "brace:{"]`.
func describeTokens(_ text: String) -> [String] {
    let ns = text as NSString
    return LaTeXTokenizer().tokenize(text).map { "\($0.kind.rawValue):\(ns.substring(with: $0.range))" }
}

/// Same, but only for the given kinds.
func describeTokens(_ text: String, only kinds: Set<LaTeXTokenKind>) -> [String] {
    let ns = text as NSString
    return LaTeXTokenizer().tokenize(text).filter { kinds.contains($0.kind) }
        .map { "\($0.kind.rawValue):\(ns.substring(with: $0.range))" }
}

/// File URL helper (all checks use fake absolute paths under /proj).
func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: "/proj/" + path).standardizedFileURL
}

/// Cursor marker used by the completion checks (`|` would clash with `\verb|…|`).
let cursorMarker = "‸"

/// Position (cursor offset) of the `‸` marker in `marked`; returns the text without it.
func splitCursor(_ marked: String) -> (text: String, cursor: Int) {
    let ns = marked as NSString
    let r = ns.range(of: cursorMarker)
    precondition(r.location != NSNotFound, "missing cursor marker")
    return (ns.replacingCharacters(in: r, with: ""), r.location)
}

/// The substring of `text` covered by `range`.
func substring(_ text: String, _ range: NSRange) -> String {
    (text as NSString).substring(with: range)
}

/// A deterministic LCG so the large inputs are reproducible.
struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(state >> 33)
    }
}

/// Renders an outline tree as indented text lines `kind:title` for exact assertions.
func describeOutline(_ nodes: [OutlineNode], indent: Int = 0) -> [String] {
    var lines: [String] = []
    for node in nodes {
        lines.append(String(repeating: "  ", count: indent) + "\(node.entry.kind.rawValue):\(node.entry.title)")
        lines.append(contentsOf: describeOutline(node.children ?? [], indent: indent + 1))
    }
    return lines
}

/// Items' labels, for compact assertions.
func labels(_ result: CompletionResult?) -> [String] {
    result?.items.map(\.label) ?? []
}
