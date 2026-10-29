import Foundation

/// Why the most recent attempt to load a PDF failed. The previously shown PDF (if any) stays on screen.
public nonisolated enum PDFLoadFailure: Error, Sendable, Hashable {
    /// The file does not exist (a TeX run may be about to recreate it).
    case missing
    /// The file exists but cannot be read.
    case unreadable
    /// The file never reached a `%%EOF` trailer – it was still being written (or got truncated).
    case incomplete
    /// The bytes are not a PDF PDFKit can open.
    case invalid

    /// Short, user-facing explanation (localized).
    public var message: String {
        switch self {
        case .missing: String(localized: "The PDF file could not be found.")
        case .unreadable: String(localized: "The PDF file could not be read.")
        case .incomplete: String(localized: "The PDF file is incomplete.")
        case .invalid: String(localized: "The file is not a valid PDF.")
        }
    }
}

/// Reads a PDF that `latexmk` may still be rewriting.
///
/// The file is always read into memory (never memory-mapped: a mapped file that gets truncated or replaced
/// underneath PDFKit crashes the process with SIGBUS). A complete PDF ends with `%%EOF`; while the trailer is
/// missing the read is retried a few times with a short, growing delay.
nonisolated enum PDFFileReader {
    /// Pauses between consecutive attempts (so there are `retryDelays.count + 1` attempts, ≈ 1.1 s in total).
    private static let retryDelays: [Duration] = [40, 80, 120, 160, 200, 250, 250].map { .milliseconds($0) }

    /// How many consecutive "no such file" results are tolerated before giving up early.
    private static let maxMissingAttempts = 3

    /// Reads `url` off the main actor. Returns the complete PDF bytes, or the reason it could not be read.
    @concurrent
    static func read(_ url: URL) async -> Result<Data, PDFLoadFailure> {
        var failure = PDFLoadFailure.unreadable
        var lastData: Data?
        var missingStreak = 0

        for attempt in 0...retryDelays.count {
            if Task.isCancelled { return .failure(failure) }
            switch attemptRead(url) {
            case .success(let data):
                missingStreak = 0
                if endsWithEOFMarker(data) { return .success(data) }
                lastData = data
                failure = .incomplete
            case .failure(let reason):
                failure = reason
                lastData = nil
                if reason == .missing {
                    missingStreak += 1
                    if missingStreak >= maxMissingAttempts { return .failure(.missing) }
                } else {
                    missingStreak = 0
                }
            }
            guard attempt < retryDelays.count else { break }
            try? await Task.sleep(for: retryDelays[attempt])
        }

        // Some producers append stray bytes after the trailer. If a `%%EOF` is at least close to the end,
        // let PDFKit have a go instead of refusing the file forever.
        if let lastData, hasEOFMarkerNearEnd(lastData) { return .success(lastData) }
        return .failure(failure)
    }

    private static func attemptRead(_ url: URL) -> Result<Data, PDFLoadFailure> {
        do {
            return .success(try Data(contentsOf: url, options: [.uncached]))
        } catch let error as CocoaError {
            switch error.code {
            case .fileReadNoSuchFile, .fileNoSuchFile: return .failure(.missing)
            default: return .failure(.unreadable)
            }
        } catch {
            return .failure(.unreadable)
        }
    }

    private static let eofMarker: [UInt8] = Array("%%EOF".utf8)

    /// `true` when the data ends with `%%EOF`, ignoring trailing whitespace / NUL bytes.
    static func endsWithEOFMarker(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var end = raw.count
            while end > 0, isTrailingFiller(raw[end - 1]) { end -= 1 }
            let marker = eofMarker
            guard end >= marker.count else { return false }
            let start = end - marker.count
            for index in 0..<marker.count where raw[start + index] != marker[index] { return false }
            return true
        }
    }

    /// `true` when `%%EOF` occurs in the last 2 KiB.
    static func hasEOFMarkerNearEnd(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let marker = eofMarker
            let count = raw.count
            guard count >= marker.count else { return false }
            let lowerBound = max(0, count - 2048)
            var index = count - marker.count
            while index >= lowerBound {
                var matches = true
                for offset in 0..<marker.count where raw[index + offset] != marker[offset] {
                    matches = false
                    break
                }
                if matches { return true }
                index -= 1
            }
            return false
        }
    }

    private static func isTrailingFiller(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
    }
}
