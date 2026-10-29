import Foundation

/// Subsequence matching used by Quick Open. Higher score = better; nil = no match.
nonisolated enum FuzzyMatcher {
    /// Scores `query` against a path. Matches in the file name weigh more than matches in folders;
    /// consecutive characters and word starts earn bonuses; shorter paths win ties.
    static func score(query: String, path: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let chars = Array(path.lowercased())
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0

        var score = 0
        var qi = 0
        var previousMatch = -2
        for (i, c) in chars.enumerated() where qi < q.count && c == q[qi] {
            var s = 1
            if i == previousMatch + 1 { s += 5 }                       // consecutive
            if i == 0 || "/._-".contains(chars[i - 1]) { s += 4 }      // word start
            if i >= nameStart { s += 3 }                                // in the file name
            score += s
            previousMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Exact file-name prefix / equality bonuses.
        let name = String(chars[nameStart...])
        let query = String(q)
        if name == query { score += 40 } else if name.hasPrefix(query) { score += 20 } else if name.contains(query) { score += 10 }
        return score * 4 - min(chars.count, 120) / 4
    }
}
