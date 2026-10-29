import Foundation

/// Ranking of the command palette: fuzzy matching (`FuzzyMatcher`) over the localized titles, plus the
/// category, the stable title of toggles ("Show or Hide Issues"), extra keywords and the command id (English
/// words, so `compile` finds “Compilar” too). Case and diacritics are ignored (`compilacao` finds “Compilação”).
nonisolated enum CommandPaletteSearch {
    struct Entry: Equatable {
        var id: String
        /// The title as shown now (dynamic for toggles).
        var title: String
        /// Other words that should find the command (lower weight).
        var alternates: [String]
        var isEnabled: Bool
    }

    /// The order of the palette.
    /// - Empty query: recently used commands first (most recent first), then the others in menu order with
    ///   unavailable ones last.
    /// - Otherwise: matches by score; recent commands get a bonus, unavailable ones a penalty (they stay listed,
    ///   dimmed, but rarely end up under Return).
    static func rank(_ entries: [Entry], query: String, recents: [String]) -> [Entry] {
        let recentRank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let folded = fold(query).filter { !$0.isWhitespace }
        if folded.isEmpty {
            let recent = entries.filter { recentRank[$0.id] != nil }
                .sorted { (recentRank[$0.id] ?? 0) < (recentRank[$1.id] ?? 0) }
            let others = entries.filter { recentRank[$0.id] == nil }
            return recent + others.filter(\.isEnabled) + others.filter { !$0.isEnabled }
        }
        var scored: [(entry: Entry, score: Int, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            guard var score = score(query: folded, entry: entry) else { continue }
            if let rank = recentRank[entry.id] { score += max(0, 40 - 4 * rank) }
            if !entry.isEnabled { score -= 60 }
            scored.append((entry, score, order))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.map(\.entry)
    }

    /// The best score of an (already folded) query against the title, or the alternates at half weight.
    static func score(query: String, entry: Entry) -> Int? {
        var best = FuzzyMatcher.score(query: query, path: words(entry.title))
        for alternate in entry.alternates + [entry.id] {
            guard let score = FuzzyMatcher.score(query: query, path: words(alternate)) else { continue }
            best = max(best ?? Int.min, score / 2)
        }
        return best
    }

    /// Lowercase, without diacritics.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// `FuzzyMatcher` rewards matches at word starts after `/ . _ -`: spaces become `-`, and slashes (which it
    /// reads as folders) become spaces-as-dashes too.
    private static func words(_ text: String) -> String {
        String(fold(text).map { $0 == " " || $0 == "/" ? "-" : $0 })
    }
}

/// The commands run from the palette, most recent first (UserDefaults; ids are stable).
final class CommandRecents {
    static let shared = CommandRecents()
    static let defaultsKey = "commandPalette.recents"
    static let limit = 10

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var ids: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func note(_ id: CommandID) {
        var list = ids.filter { $0 != id.rawValue }
        list.insert(id.rawValue, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.defaultsKey)
    }
}
