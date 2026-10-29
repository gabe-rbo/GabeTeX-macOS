import Foundation

/// Incrementally maintained line-start table of the text being edited.
///
/// Line terminators are `\n`, `\r\n` and `\r` — exactly the rules of `TeXCore.LineIndex` (and of TeX),
/// so line numbers in the gutter, the status bar and diagnostics always agree. Updating after an edit
/// costs O(log n + edited length + lines after the edit) instead of a full rescan, which keeps typing
/// latency flat on long files.
nonisolated struct LineTable: Equatable {
    /// UTF-16 offset of the first character of each line; `starts[0] == 0` always.
    private(set) var starts: [Int] = [0]
    /// Total UTF-16 length of the text.
    private(set) var length = 0

    init() {}

    init(_ text: NSString) {
        rebuild(text)
    }

    var lineCount: Int { starts.count }

    mutating func rebuild(_ text: NSString) {
        length = text.length
        starts = [0]
        starts.reserveCapacity(length / 32 + 1)
        Self.scanLineStarts(in: text, from: 1, through: length, into: &starts)
    }

    /// Applies an edit: `editedRange` is in the *new* text, `delta` the change in length
    /// (the replaced range in the old text had length `editedRange.length - delta`).
    mutating func update(_ text: NSString, editedRange: NSRange, delta: Int) {
        let newLength = text.length
        let loc = max(0, min(editedRange.location, newLength))
        let newEnd = max(loc, min(editedRange.location + editedRange.length, newLength))
        let oldEnd = newEnd - delta
        guard oldEnd >= loc, length + delta == newLength else {
            rebuild(text)
            return
        }
        // Line starts whose determining characters (s-1, s) touch the replaced region are recomputed.
        let lower = max(1, Self.firstIndex(in: starts, notLessThan: loc))
        let upper = max(lower, Self.firstIndex(in: starts, greaterThan: oldEnd))
        var fresh: [Int] = []
        Self.scanLineStarts(in: text, from: max(1, loc), through: newEnd, into: &fresh)
        starts.replaceSubrange(lower..<upper, with: fresh)
        if delta != 0 {
            var i = lower + fresh.count
            while i < starts.count {
                starts[i] += delta
                i += 1
            }
        }
        length = newLength
    }

    /// 0-based index of the line containing `offset` (offsets past the end map to the last line).
    func lineIndex(containing offset: Int) -> Int {
        let target = max(0, min(offset, length))
        return max(0, Self.firstIndex(in: starts, greaterThan: target) - 1)
    }

    /// 1-based line number containing `offset`.
    func lineNumber(containing offset: Int) -> Int { lineIndex(containing: offset) + 1 }

    func startOfLine(_ index: Int) -> Int {
        starts[max(0, min(index, starts.count - 1))]
    }

    /// Start of the next line, or the text length for the last line (i.e. the end including the terminator).
    func endOfLineIncludingTerminator(_ index: Int) -> Int {
        let i = max(0, min(index, starts.count - 1))
        return i + 1 < starts.count ? starts[i + 1] : length
    }

    /// Range of the line's contents, excluding its terminator.
    func contentsRange(ofLine index: Int, in text: NSString) -> NSRange {
        let i = max(0, min(index, starts.count - 1))
        let start = starts[i]
        var end = endOfLineIncludingTerminator(i)
        if i + 1 < starts.count, end > start {
            // strip "\n", "\r" or "\r\n"
            let last = text.character(at: end - 1)
            if last == 10 {
                end -= 1
                if end > start, text.character(at: end - 1) == 13 { end -= 1 }
            } else if last == 13 {
                end -= 1
            }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Range including the terminator.
    func fullRange(ofLine index: Int) -> NSRange {
        let i = max(0, min(index, starts.count - 1))
        return NSRange(location: starts[i], length: endOfLineIncludingTerminator(i) - starts[i])
    }

    // MARK: - Scanning

    /// Appends every line start `s` with `from <= s <= through` (s ≥ 1) to `out`, in order.
    /// A line starts after `\n`, or after a `\r` that is not followed by `\n`.
    static func scanLineStarts(in text: NSString, from: Int, through: Int, into out: inout [Int]) {
        let length = text.length
        let first = max(1, from)
        let last = min(through, length)
        guard first <= last else { return }
        // Read characters [first-1, last] (one look-ahead for "\r\n").
        let readStart = first - 1
        let readEnd = min(length, last + 1)
        let chunk = 16_384
        var buffer = [unichar](repeating: 0, count: min(chunk + 1, readEnd - readStart))
        var base = readStart
        while base < last {
            let count = min(chunk + 1, readEnd - base)
            buffer.withUnsafeMutableBufferPointer { ptr in
                guard let p = ptr.baseAddress else { return }
                text.getCharacters(p, range: NSRange(location: base, length: count))
            }
            // characters buffer[k] is text[base + k]; candidate start s = base + k + 1
            var k = 0
            let limit = min(count, last - base)   // s = base + k + 1 <= last
            while k < limit {
                let c = buffer[k]
                if c == 10 {
                    out.append(base + k + 1)
                } else if c == 13 {
                    let next: unichar = k + 1 < count ? buffer[k + 1] : (base + k + 1 < length ? text.character(at: base + k + 1) : 0)
                    if next != 10 { out.append(base + k + 1) }
                }
                k += 1
            }
            base += limit
            if limit == 0 { break }
        }
    }

    /// First index `i` with `array[i] >= value` (array sorted ascending).
    static func firstIndex(in array: [Int], notLessThan value: Int) -> Int {
        var lo = 0, hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index `i` with `array[i] > value`.
    static func firstIndex(in array: [Int], greaterThan value: Int) -> Int {
        var lo = 0, hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
