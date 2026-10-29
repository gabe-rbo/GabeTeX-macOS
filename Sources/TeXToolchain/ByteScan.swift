import Foundation
import Darwin

/// Byte-level helpers for the log parser's hot path. `hasPrefix`/`range(of:)` on `Substring` compare
/// Unicode-canonically (and `range(of:)` bridges through Foundation), which is far too slow for scanning
/// every line of a megabyte-sized log; these operate on the UTF-8 bytes with `memcmp`/`memchr`/`memmem`.
/// All needles are ASCII.
extension Substring {
    /// Runs `body` on the substring's UTF-8 bytes (without copying for native strings).
    func withUTF8Bytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let result = utf8.withContiguousStorageIfAvailable(body) { return result }
        return Array(utf8).withUnsafeBufferPointer(body)
    }

    /// Byte-wise prefix test.
    func utf8HasPrefix(_ prefix: StaticString) -> Bool {
        prefix.withUTF8Buffer { needle in
            withUTF8Bytes { bytes in
                guard bytes.count >= needle.count else { return false }
                guard let a = bytes.baseAddress, let b = needle.baseAddress else { return needle.isEmpty }
                return memcmp(a, b, needle.count) == 0
            }
        }
    }

    /// Byte-wise suffix test.
    func utf8HasSuffix(_ suffix: StaticString) -> Bool {
        suffix.withUTF8Buffer { needle in
            withUTF8Bytes { bytes in
                guard bytes.count >= needle.count else { return false }
                guard let a = bytes.baseAddress, let b = needle.baseAddress else { return needle.isEmpty }
                return memcmp(a + (bytes.count - needle.count), b, needle.count) == 0
            }
        }
    }

    /// Byte offset (from the start of the substring) of the first occurrence of `needle`, or nil.
    func utf8Offset(of needle: StaticString) -> Int? {
        needle.withUTF8Buffer { n in
            withUTF8Bytes { bytes in ByteScan.find(n, in: bytes, from: 0) }
        }
    }

    /// The substring between two byte offsets (which must fall on character boundaries — they do when
    /// they were found next to ASCII bytes).
    func utf8Slice(_ from: Int, _ to: Int? = nil) -> Substring {
        let u = utf8
        let start = u.index(u.startIndex, offsetBy: from)
        let end = to.map { u.index(u.startIndex, offsetBy: $0) } ?? u.endIndex
        return Substring(u[start..<end])
    }
}

enum ByteScan {
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let colon = UInt8(ascii: ":")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let quote = UInt8(ascii: "\"")
    static let dot = UInt8(ascii: ".")
    static let slash = UInt8(ascii: "/")

    /// Offset of the first `needle` in `bytes[from...]`, or nil.
    static func find(_ needle: UnsafeBufferPointer<UInt8>, in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from >= 0, bytes.count - from >= needle.count, !needle.isEmpty,
              let base = bytes.baseAddress, let n = needle.baseAddress,
              let hit = memmem(base + from, bytes.count - from, n, needle.count) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
    }

    /// Offset of the first `byte` in `bytes[from...]`, or nil.
    static func find(_ byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from >= 0, from < bytes.count, let base = bytes.baseAddress,
              let hit = memchr(base + from, Int32(byte), bytes.count - from) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
    }

    /// `[start, end)` line ranges of `bytes` split at "\n", with a trailing "\r" excluded (same lines as
    /// `split(separator: "\n", omittingEmptySubsequences: false)`).
    static func lineRanges(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        result.reserveCapacity(bytes.count / 40 + 1)
        var start = 0
        while start <= bytes.count {
            let end = find(UInt8(ascii: "\n"), in: bytes, from: start) ?? bytes.count
            var lineEnd = end
            if lineEnd > start, bytes[lineEnd - 1] == UInt8(ascii: "\r") { lineEnd -= 1 }
            result.append(start..<lineEnd)
            start = end + 1
        }
        return result
    }
}
