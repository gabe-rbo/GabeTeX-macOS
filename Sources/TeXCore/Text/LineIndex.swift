import Foundation

/// Maps between UTF-16 offsets and 1-based (line, column) positions.
/// Recognizes "\n", "\r\n" and "\r" line terminators. Build once per text snapshot: O(n) build, O(log n) queries.
public struct LineIndex: Sendable, Hashable {
    /// UTF-16 offset of the first character of each line.
    public let lineStarts: [Int]
    /// UTF-16 offset just past the last character of each line, *excluding* its terminator.
    public let lineEnds: [Int]
    /// Total UTF-16 length of the text.
    public let length: Int

    public init(_ text: String) {
        self.init(text as NSString)
    }

    public init(_ text: NSString) {
        let len = text.length
        var starts: [Int] = [0]
        var ends: [Int] = []
        if len > 0 {
            var buffer = [unichar](repeating: 0, count: len)
            text.getCharacters(&buffer, range: NSRange(location: 0, length: len))
            var i = 0
            while i < len {
                let c = buffer[i]
                if c == 10 { // \n
                    ends.append(i)
                    starts.append(i + 1)
                } else if c == 13 { // \r or \r\n
                    ends.append(i)
                    if i + 1 < len && buffer[i + 1] == 10 { i += 1 }
                    starts.append(i + 1)
                }
                i += 1
            }
        }
        ends.append(len)
        self.lineStarts = starts
        self.lineEnds = ends
        self.length = len
    }

    public var lineCount: Int { lineStarts.count }

    /// 1-based line containing `offset` (offsets past the end map to the last line).
    public func line(ofOffset offset: Int) -> Int {
        let target = max(0, min(offset, length))
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    public func position(ofOffset offset: Int) -> SourcePosition {
        let line = line(ofOffset: offset)
        let start = lineStarts[line - 1]
        return SourcePosition(line: line, column: max(0, min(offset, length)) - start + 1)
    }

    /// UTF-16 offset for a 1-based position; line and column are clamped into the text.
    public func offset(of position: SourcePosition) -> Int {
        let l = max(1, min(position.line, lineCount))
        let start = lineStarts[l - 1]
        let end = lineEnds[l - 1]
        return max(start, min(start + position.column - 1, end))
    }

    /// Range of the line's contents, excluding the terminator. Line is 1-based and clamped.
    public func contentsRange(ofLine line: Int) -> NSRange {
        let l = max(1, min(line, lineCount))
        return NSRange(location: lineStarts[l - 1], length: lineEnds[l - 1] - lineStarts[l - 1])
    }

    /// Range of the line including its terminator.
    public func fullRange(ofLine line: Int) -> NSRange {
        let l = max(1, min(line, lineCount))
        let end = l < lineCount ? lineStarts[l] : length
        return NSRange(location: lineStarts[l - 1], length: end - lineStarts[l - 1])
    }
}
