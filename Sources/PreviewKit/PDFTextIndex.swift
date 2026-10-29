import Foundation
import CoreGraphics

/// A word (or short phrase) from the source, prepared for matching against page text.
nonisolated struct PDFTextNeedle: Sendable, Hashable {
    /// Folded UTF-16 units (see `PDFTextFolding`), trimmed, whitespace runs collapsed to one space.
    let units: [UInt16]
    /// Number of letter/digit units.
    let wordLength: Int

    /// `nil` when `raw` has no letter or digit left after cleaning.
    init?(_ raw: String) {
        var text = raw
        if text.contains(where: { $0 == "\\" || $0 == "{" || $0 == "}" || $0 == "$" || $0 == "%" }) {
            text = PDFTextFolding.plainText(fromLaTeX: text)
        }
        var folded: [UInt16] = []
        for unit in PDFTextFolding.fold(text).units {
            if PDFTextFolding.isBreakOrSpace(unit) {
                if folded.last != PDFTextFolding.space { folded.append(PDFTextFolding.space) }
            } else {
                folded.append(unit)
            }
        }
        while let first = folded.first, !PDFTextFolding.isWordUnit(first) { folded.removeFirst() }
        while let last = folded.last, !PDFTextFolding.isWordUnit(last) { folded.removeLast() }
        let words = folded.filter(PDFTextFolding.isWordUnit).count
        guard words > 0 else { return nil }
        units = folded
        wordLength = words
    }

    var containsSpace: Bool { units.contains(PDFTextFolding.space) }
}

/// One place where a needle was found in a page's text.
nonisolated struct PDFTextOccurrence: Sendable, Hashable {
    enum Kind: Int, Sendable, Hashable {
        /// The whole needle is there.
        case exact
        /// The whole needle is there, but the page breaks the word with a line-end hyphen ("hy-⏎phenation").
        case hyphenated
        /// Only a ≥ 4-letter beginning of the needle is there, right before a line-end hyphen.
        case prefix
    }

    /// UTF-16 range in the original page string (a hyphenated match includes the hyphen and the line break).
    var range: NSRange
    var kind: Kind
    /// The match is delimited by non-word characters on both sides (and is not a piece of a hyphenated word).
    var isWholeWord: Bool
    /// How many needle units matched (shorter than the needle for `.prefix`).
    var matchedLength: Int
    /// Folded offsets of the match, for context lookups.
    var foldedStart: Int
    var foldedEnd: Int
}

/// Folded copy of one page's text that can be searched for occurrences of a word and asked what surrounds them.
nonisolated struct PDFTextIndex: Sendable {
    /// Matches kept per search (a pathological page with thousands of "e" must not stall the UI).
    static let occurrenceLimit = 400
    /// Page words looked at on each side of an occurrence when scoring context.
    static let contextTokenLimit = 6
    /// A prefix match needs at least this many letters.
    static let minimumPrefixLength = 4

    let folded: PDFTextFolding.Folded

    init(pageText: String) {
        folded = PDFTextFolding.fold(pageText)
    }

    private var units: [UInt16] { folded.units }

    // MARK: Search

    /// All occurrences of the whole needle, in reading order. Matching ignores case, accents and ligatures, lets
    /// whitespace runs (and line breaks) stand for a space, and sees through a line-end hyphenation.
    func occurrences(of needle: PDFTextNeedle) -> [PDFTextOccurrence] {
        let n = needle.units
        guard let first = n.first else { return [] }
        var result: [PDFTextOccurrence] = []
        var start = 0
        while start < units.count {
            if units[start] == first, let match = match(n, at: start) {
                result.append(makeOccurrence(start: start, end: match.end, kind: match.joined ? .hyphenated : .exact,
                                             matchedLength: n.count))
                if result.count >= Self.occurrenceLimit { break }
            }
            start += 1
        }
        return result
    }

    /// Occurrences of a ≥ 4-letter beginning of the needle that stands right before a line-end hyphen
    /// ("hyphen-⏎" for "hyphenation"), longest prefix first. For words the page broke where the continuation is
    /// not reachable as text (other column, other page, text order surprises).
    func prefixOccurrences(of needle: PDFTextNeedle) -> [PDFTextOccurrence] {
        guard !needle.containsSpace, needle.units.count > Self.minimumPrefixLength else { return [] }
        var result: [PDFTextOccurrence] = []
        let n = needle.units
        for length in stride(from: n.count - 1, through: Self.minimumPrefixLength, by: -1) {
            let prefix = Array(n[0..<length])
            var start = 0
            while start + length < units.count {
                defer { start += 1 }
                guard units[start] == prefix[0],
                      start == 0 || !PDFTextFolding.isWordUnit(units[start - 1]),
                      units[start..<(start + length)].elementsEqual(prefix) else { continue }
                let hyphenIndex = start + length
                guard units[hyphenIndex] == PDFTextFolding.hyphen,
                      let next = skipLineBreak(after: hyphenIndex), next < units.count,
                      PDFTextFolding.isWordUnit(units[next]) else { continue }
                result.append(makeOccurrence(start: start, end: hyphenIndex + 1, kind: .prefix, matchedLength: length))
                if result.count >= Self.occurrenceLimit { return result }
            }
        }
        return result
    }

    /// Matches `needle` at `start`; the second result says that a line-end hyphenation was crossed.
    private func match(_ needle: [UInt16], at start: Int) -> (end: Int, joined: Bool)? {
        var h = start
        var i = 0
        var joined = false
        while i < needle.count {
            guard h < units.count else { return nil }
            let c = units[h]
            let w = needle[i]
            if c == w {
                h += 1
                i += 1
                if w == PDFTextFolding.space {
                    while h < units.count, PDFTextFolding.isBreakOrSpace(units[h]) { h += 1 }
                }
                continue
            }
            if w == PDFTextFolding.space, c == PDFTextFolding.newline {
                h += 1
                i += 1
                while h < units.count, PDFTextFolding.isBreakOrSpace(units[h]) { h += 1 }
                continue
            }
            // The needle itself has a hyphen ("well-known") and the page broke the line right after it.
            if i > 0, needle[i - 1] == PDFTextFolding.hyphen, PDFTextFolding.isBreakOrSpace(c) {
                var next = h
                while next < units.count, PDFTextFolding.isBreakOrSpace(units[next]) { next += 1 }
                if next < units.count, units[next] == w {
                    h = next
                    continue
                }
                return nil
            }
            // The page hyphenated the word at a line end: "hy-⏎phenation".
            if i > 0, c == PDFTextFolding.hyphen, let next = skipLineBreak(after: h), next < units.count,
               units[next] == w {
                h = next
                joined = true
                continue
            }
            return nil
        }
        return (h, joined)
    }

    /// Index of the first unit after the spaces and line breaks that follow `index`, provided there was at least
    /// one line break; `nil` otherwise.
    private func skipLineBreak(after index: Int) -> Int? {
        var next = index + 1
        var sawBreak = false
        while next < units.count, PDFTextFolding.isBreakOrSpace(units[next]) {
            if units[next] == PDFTextFolding.newline { sawBreak = true }
            next += 1
        }
        return sawBreak ? next : nil
    }

    private func makeOccurrence(start: Int, end: Int, kind: PDFTextOccurrence.Kind, matchedLength: Int) -> PDFTextOccurrence {
        let originalStart = folded.starts[start]
        let originalEnd = folded.ends[end - 1]
        var whole = (start == 0 || !PDFTextFolding.isWordUnit(units[start - 1]))
            && (end >= units.count || !PDFTextFolding.isWordUnit(units[end]))
        if kind != .prefix {
            // "hyphen" at the end of "hyphen-⏎ation" is a piece of a longer word, not the word.
            if end < units.count, units[end] == PDFTextFolding.hyphen, let next = skipLineBreak(after: end),
               next < units.count, PDFTextFolding.isWordUnit(units[next]) {
                whole = false
            }
            // ... and neither is "ation" at the start of the next line.
            if start > 0, lastWordUnitIndex(beforeHyphenBreakAt: start) != nil {
                whole = false
            }
        }
        return PDFTextOccurrence(range: NSRange(location: originalStart, length: max(0, originalEnd - originalStart)),
                                 kind: kind, isWholeWord: whole, matchedLength: matchedLength,
                                 foldedStart: start, foldedEnd: end)
    }

    /// If the text right before `index` is "<letter>-<line break>", returns the index of that letter.
    private func lastWordUnitIndex(beforeHyphenBreakAt index: Int) -> Int? {
        var probe = index - 1
        var sawBreak = false
        while probe >= 0, PDFTextFolding.isBreakOrSpace(units[probe]) {
            if units[probe] == PDFTextFolding.newline { sawBreak = true }
            probe -= 1
        }
        guard sawBreak, probe >= 1, units[probe] == PDFTextFolding.hyphen,
              PDFTextFolding.isWordUnit(units[probe - 1]) else { return nil }
        return probe - 1
    }

    // MARK: Context

    /// Words right before folded offset `start`, nearest first (a hyphenated word counts as one).
    func tokensBefore(_ start: Int, limit: Int = PDFTextIndex.contextTokenLimit) -> [String] {
        var result: [String] = []
        var cursor = start
        while result.count < limit, cursor > 0 {
            while cursor > 0, !PDFTextFolding.isWordUnit(units[cursor - 1]) { cursor -= 1 }
            guard cursor > 0 else { break }
            let end = cursor
            var begin = end
            while true {
                while begin > 0, PDFTextFolding.isWordUnit(units[begin - 1]) { begin -= 1 }
                // Continue over a line-end hyphenation to the first half of the word.
                if let letter = lastWordUnitIndex(beforeHyphenBreakAt: begin), PDFTextFolding.isWordUnit(units[letter]) {
                    begin = letter + 1
                    continue
                }
                break
            }
            result.append(String(decoding: wordUnits(from: begin, to: end), as: UTF16.self))
            cursor = begin
        }
        return result
    }

    /// Words right after folded offset `end`, nearest first.
    func tokensAfter(_ end: Int, limit: Int = PDFTextIndex.contextTokenLimit) -> [String] {
        var result: [String] = []
        var cursor = end
        while result.count < limit, cursor < units.count {
            while cursor < units.count, !PDFTextFolding.isWordUnit(units[cursor]) { cursor += 1 }
            guard cursor < units.count else { break }
            let begin = cursor
            var stop = begin
            while true {
                while stop < units.count, PDFTextFolding.isWordUnit(units[stop]) { stop += 1 }
                if stop < units.count, units[stop] == PDFTextFolding.hyphen, let next = skipLineBreak(after: stop),
                   next < units.count, PDFTextFolding.isWordUnit(units[next]) {
                    stop = next
                    continue
                }
                break
            }
            result.append(String(decoding: wordUnits(from: begin, to: stop), as: UTF16.self))
            cursor = stop
        }
        return result
    }

    /// The units of a word, without the hyphens and line breaks of a line-end hyphenation inside it.
    private func wordUnits(from begin: Int, to end: Int) -> [UInt16] {
        units[begin..<end].filter { PDFTextFolding.isWordUnit($0) }
    }

    /// How well the page text around `occurrence` agrees with the source text around the word. Nearer words weigh
    /// more; short words little. `0` when the source gave no context or nothing agrees.
    func contextScore(for occurrence: PDFTextOccurrence, source: PDFSourceContext) -> Double {
        guard source.hasWords else { return 0 }
        let before = Self.similarity(page: tokensBefore(occurrence.foldedStart), source: source.before)
        let after = Self.similarity(page: tokensAfter(occurrence.foldedEnd), source: source.after)
        return before + after
    }

    /// Weighted overlap of two nearest-first word lists.
    static func similarity(page: [String], source: [String]) -> Double {
        guard !page.isEmpty, !source.isEmpty else { return 0 }
        var score = 0.0
        var used = Set<Int>()
        for (i, pageWord) in page.enumerated() {
            var bestIndex = -1
            var bestWeight = 0.0
            for (j, sourceWord) in source.enumerated() where !used.contains(j) {
                guard wordsAgree(pageWord, sourceWord) else { continue }
                let weight = 1 / (1 + Double(abs(i - j)))
                if weight > bestWeight {
                    bestWeight = weight
                    bestIndex = j
                }
            }
            guard bestIndex >= 0 else { continue }
            used.insert(bestIndex)
            let length = min(1, Double(pageWord.count) / 4)
            score += bestWeight * length / (1 + 0.25 * Double(i))
        }
        return score
    }

    /// Equal, or one is the (≥ 4-letter) beginning of the other (a word cut by hyphenation or by the context limit).
    static func wordsAgree(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= minimumPrefixLength, b.count >= minimumPrefixLength else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }
}

/// The source text around a word, reduced to comparable words (nearest first).
nonisolated struct PDFSourceContext: Sendable, Hashable {
    var before: [String]
    var after: [String]

    var hasWords: Bool { !before.isEmpty || !after.isEmpty }

    /// `contextBefore` / `contextAfter` are LaTeX source: markup is dropped, words folded.
    init(contextBefore: String, contextAfter: String, limit: Int = PDFTextIndex.contextTokenLimit) {
        before = Array(PDFTextFolding.tokens(of: contextBefore, latex: true).suffix(limit).reversed())
        after = Array(PDFTextFolding.tokens(of: contextAfter, latex: true).prefix(limit))
    }
}

/// One candidate highlight: an occurrence of the word with its geometry and scores.
nonisolated struct PDFMatchCandidate: Sendable {
    var pageIndex: Int
    var occurrence: PDFTextOccurrence
    /// One rectangle per text line the occurrence covers, in page space.
    var rects: [CGRect]
    var contextScore: Double
    /// Distance to the nearest SyncTeX box (0 = they intersect or touch).
    var gap: CGFloat

    var lineHeight: CGFloat { rects.map(\.height).max() ?? 0 }
}

nonisolated enum PDFMatchRanking {
    /// Gap between two rectangles (0 when they intersect or touch).
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(a.minX - b.maxX, b.minX - a.maxX, 0)
        let dy = max(a.minY - b.maxY, b.minY - a.maxY, 0)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Smallest gap between any of `rects` and any of `boxes`.
    static func gap(of rects: [CGRect], to boxes: [CGRect]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for rect in rects {
            for box in boxes { best = min(best, gap(rect, box)) }
        }
        return best
    }

    /// How far from a SyncTeX box an occurrence may lie and still count: about one line.
    static func tolerance(for candidate: PDFMatchCandidate) -> CGFloat {
        max(candidate.lineHeight, 10)
    }

    /// The occurrence to highlight: among those intersecting or within about a line of a box, whole words first,
    /// then the best context agreement, then the closest to a box, then reading order. `nil` when none is near.
    static func best(of candidates: [PDFMatchCandidate]) -> PDFMatchCandidate? {
        let near = candidates.filter { !$0.rects.isEmpty && $0.gap <= tolerance(for: $0) }
        return near.min { a, b in
            if a.occurrence.isWholeWord != b.occurrence.isWholeWord { return a.occurrence.isWholeWord }
            if a.occurrence.matchedLength != b.occurrence.matchedLength {
                return a.occurrence.matchedLength > b.occurrence.matchedLength
            }
            let scoreA = Int((a.contextScore * 4).rounded(.down))
            let scoreB = Int((b.contextScore * 4).rounded(.down))
            if scoreA != scoreB { return scoreA > scoreB }
            let gapA = (a.gap * 2).rounded()
            let gapB = (b.gap * 2).rounded()
            if gapA != gapB { return gapA < gapB }
            if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
            let rectA = a.rects[0]
            let rectB = b.rects[0]
            if abs(rectA.maxY - rectB.maxY) > 1 { return rectA.maxY > rectB.maxY }
            return rectA.minX < rectB.minX
        }
    }
}
