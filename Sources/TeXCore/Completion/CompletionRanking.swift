import Foundation

/// Matching and ranking of completion candidates.
///
/// Tiers (lower is better): 0 exact, 1 case-sensitive prefix, 2 case-insensitive prefix,
/// 3 prefix of a "word" inside the candidate (after `: - _ . / space`), 4 subsequence (fuzzy),
/// 5 substring of secondary text (author / title of a bib entry). Ties are broken by the optional
/// `priority` (lower first; used to put the most common commands first), then by candidate order.
enum CompletionRanking {
    static let maxItems = 200

    private static func isSeparator(_ b: UInt8) -> Bool {
        b == 58 || b == 45 || b == 95 || b == 46 || b == 47 || b == 32
    }

    static func tier(typed: String, typedLower: String, candidate: String, allowFuzzy: Bool) -> Int? {
        if typed.isEmpty { return 1 }
        if candidate == typed { return 0 }
        if candidate.hasPrefix(typed) { return 1 }
        let lower = candidate.lowercased()
        if lower.hasPrefix(typedLower) { return 2 }
        let needle = Array(typedLower.utf8)
        let hay = Array(lower.utf8)
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        // Word-start prefix.
        var i = 1
        while i + needle.count <= hay.count {
            if isSeparator(hay[i - 1]) && !isSeparator(hay[i]) && hay[i] == needle[0] {
                var k = 1
                while k < needle.count && hay[i + k] == needle[k] { k += 1 }
                if k == needle.count { return 3 }
            }
            i += 1
        }
        guard allowFuzzy else { return nil }
        // Subsequence.
        var h = 0
        for byte in needle {
            while h < hay.count && hay[h] != byte { h += 1 }
            if h == hay.count { return nil }
            h += 1
        }
        return 4
    }

    /// Filters `items` by `typed` and orders them best first.
    static func rank(
        _ items: [CompletionItem],
        typed: String,
        allowFuzzy: Bool = true,
        limit: Int = maxItems,
        key: (CompletionItem) -> String,
        secondary: ((CompletionItem) -> String?)? = nil,
        priority: ((CompletionItem) -> Int)? = nil
    ) -> [CompletionItem] {
        let typedLower = typed.lowercased()
        var scored: [(tier: Int, priority: Int, index: Int, item: CompletionItem)] = []
        scored.reserveCapacity(min(items.count, 512))
        for (index, item) in items.enumerated() {
            var score = tier(typed: typed, typedLower: typedLower, candidate: key(item), allowFuzzy: allowFuzzy)
            if score == nil, let secondary, let text = secondary(item), text.lowercased().contains(typedLower) {
                score = 5
            }
            if let score { scored.append((score, priority?(item) ?? 0, index, item)) }
        }
        scored.sort { ($0.tier, $0.priority, $0.index) < ($1.tier, $1.priority, $1.index) }
        return scored.prefix(limit).map { $0.item }
    }
}
