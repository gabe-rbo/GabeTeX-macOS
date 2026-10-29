import Foundation
import Darwin

/// How a text file was encoded on disk, remembered per buffer so saving writes it back unchanged.
nonisolated struct TextFileFormat: Sendable, Equatable {
    var encoding: String.Encoding
    var hasBOM: Bool

    static let utf8 = TextFileFormat(encoding: .utf8, hasBOM: false)
    static let latin1 = TextFileFormat(encoding: .isoLatin1, hasBOM: false)

    /// Name used in alerts.
    var displayName: String {
        switch encoding {
        case .utf8: hasBOM ? "UTF-8 BOM" : "UTF-8"
        case .isoLatin1: "ISO Latin 1"
        case .utf16, .utf16LittleEndian, .utf16BigEndian: "UTF-16"
        default: "Text"
        }
    }

    /// Short label for the status bar (a technical name, never translated).
    var statusName: String {
        switch encoding {
        case .utf8: hasBOM ? "UTF-8 BOM" : "UTF-8"
        case .isoLatin1: "Latin-1"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf16: "UTF-16"
        default: "Text"
        }
    }
}

nonisolated enum TextFileError: Error, LocalizedError {
    case notText
    case tooLarge(Int)
    case notRepresentable(String)
    case unreadable
    /// The file (or its immutable flag) does not allow writing; saving never overrides that.
    case readOnly

    var errorDescription: String? {
        switch self {
        case .notText: String(localized: "This file does not look like a text file.")
        case .tooLarge: String(localized: "This file is too large to open in the editor.")
        case .notRepresentable(let name): String(localized: "The text contains characters that cannot be stored in the file’s \(name) encoding.")
        case .unreadable: String(localized: "The file could not be read.")
        case .readOnly: String(localized: "The file is read-only. Make it writable in Finder (File ▸ Get Info), then save again.")
        }
    }
}

/// Reading and writing text files: UTF-8 first, ISO Latin-1 for legacy files. Line endings are
/// never touched, and a UTF-8/UTF-16 byte-order mark is preserved. Saving keeps the file’s POSIX
/// permissions, extended attributes (Finder tags, quarantine …) and hard links.
nonisolated enum TextFileIO {
    nonisolated struct Loaded: Sendable {
        var text: String
        var format: TextFileFormat
        /// Bytes that were not valid UTF-8 and were replaced with U+FFFD (0 for a clean file).
        var invalidByteCount = 0
        /// The file’s stamp, taken just before it was read (so a concurrent write is noticed later).
        var stamp: DiskStamp?
        /// Fingerprint of the bytes that were read.
        var digest = 0

        var diskState: DiskState { DiskState(stamp: stamp, digest: digest) }
    }

    /// Files above this size are not opened in the editor.
    static let maxEditableBytes = 24 * 1024 * 1024

    /// Reads and decodes a file (as ISO Latin-1 when `asLatin1` is set). Never memory-maps: another
    /// program truncating a mapped file would crash the editor with SIGBUS.
    static func read(_ url: URL, asLatin1: Bool = false) throws -> Loaded {
        let before = stamp(of: url)
        if let before, before.size > maxEditableBytes { throw TextFileError.tooLarge(before.size) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw TextFileError.unreadable }
        guard data.count <= maxEditableBytes else { throw TextFileError.tooLarge(data.count) }
        guard var loaded = asLatin1 ? decodeLatin1(data) : decode(data) else { throw TextFileError.notText }
        loaded.stamp = before
        loaded.digest = digest(data)
        return loaded
    }

    /// The first `maxBytes` of a file (no memory mapping), nil when it cannot be read.
    static func readHead(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    /// nil when the data is binary (contains NUL bytes outside UTF-16) or cannot be decoded.
    ///
    /// UTF-8 is tried first. Data that is not valid UTF-8 is read as ISO Latin-1 only when it contains no
    /// well-formed multi-byte UTF-8 sequence at all (a real legacy file); a mostly-UTF-8 file with a few
    /// stray bytes stays UTF-8, the bad bytes become U+FFFD and `invalidByteCount` says how many.
    static func decode(_ data: Data) -> Loaded? {
        if data.isEmpty { return Loaded(text: "", format: .utf8) }
        let bytes = [UInt8](data.prefix(4))
        // UTF-16 with BOM.
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE, let s = String(data: data, encoding: .utf16LittleEndian) {
            return Loaded(text: String(s.drop(while: { $0 == "\u{FEFF}" })), format: TextFileFormat(encoding: .utf16LittleEndian, hasBOM: true))
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF, let s = String(data: data, encoding: .utf16BigEndian) {
            return Loaded(text: String(s.drop(while: { $0 == "\u{FEFF}" })), format: TextFileFormat(encoding: .utf16BigEndian, hasBOM: true))
        }
        if looksBinary(data) { return nil }
        // UTF-8 (with or without BOM).
        var body = data
        var bom = false
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            body = data.dropFirst(3)
            bom = true
        }
        if let s = String(data: body, encoding: .utf8) {
            return Loaded(text: s, format: TextFileFormat(encoding: .utf8, hasBOM: bom))
        }
        let scan = scanUTF8(body)
        if scan.multiByteSequences > 0 {
            // UTF-8 with stray bytes: keep it UTF-8, repair lossily, and let the caller warn.
            let text = String(decoding: body, as: UTF8.self)
            return Loaded(text: text, format: TextFileFormat(encoding: .utf8, hasBOM: bom), invalidByteCount: max(1, scan.invalidBytes))
        }
        // Legacy Brazilian files: ISO Latin-1 never fails.
        if let s = String(data: data, encoding: .isoLatin1) {
            return Loaded(text: s, format: .latin1)
        }
        return nil
    }

    /// Decodes `data` as ISO Latin-1 (the “Reopen as Latin-1” action).
    static func decodeLatin1(_ data: Data) -> Loaded? {
        guard !looksBinary(data), let s = String(data: data, encoding: .isoLatin1) else { return nil }
        return Loaded(text: s, format: .latin1)
    }

    /// Counts well-formed multi-byte UTF-8 sequences and bytes that belong to no well-formed sequence.
    static func scanUTF8(_ data: Data) -> (multiByteSequences: Int, invalidBytes: Int) {
        data.withUnsafeBytes { raw -> (Int, Int) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var multi = 0, invalid = 0
            var i = 0
            while i < count {
                let lead = bytes[i]
                if lead < 0x80 { i += 1; continue }
                var low: UInt8 = 0x80, high: UInt8 = 0xBF
                let continuation: Int
                switch lead {
                case 0xC2...0xDF: continuation = 1
                case 0xE0: continuation = 2; low = 0xA0
                case 0xE1...0xEC, 0xEE...0xEF: continuation = 2
                case 0xED: continuation = 2; high = 0x9F
                case 0xF0: continuation = 3; low = 0x90
                case 0xF1...0xF3: continuation = 3
                case 0xF4: continuation = 3; high = 0x8F
                default: invalid += 1; i += 1; continue
                }
                var valid = true
                for offset in 1...continuation {
                    guard i + offset < count else { valid = false; break }
                    let byte = bytes[i + offset]
                    let lower = offset == 1 ? low : 0x80
                    let upper = offset == 1 ? high : 0xBF
                    if byte < lower || byte > upper { valid = false; break }
                }
                if valid {
                    multi += 1
                    i += continuation + 1
                } else {
                    invalid += 1
                    i += 1
                }
            }
            return (multi, invalid)
        }
    }

    /// Heuristic: a NUL byte in the first 8 KB means binary.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    // MARK: Writing

    /// Encodes `text` for `format` (BOM included).
    static func encode(_ text: String, format: TextFileFormat) throws -> Data {
        var data = Data()
        switch format.encoding {
        case .utf8:
            if format.hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(Data(text.utf8))
        case .utf16LittleEndian, .utf16BigEndian:
            let withBOM = format.hasBOM ? "\u{FEFF}" + text : text
            guard let encoded = withBOM.data(using: format.encoding) else { throw TextFileError.notRepresentable(format.displayName) }
            data = encoded
        default:
            guard let encoded = text.data(using: format.encoding, allowLossyConversion: false) else {
                throw TextFileError.notRepresentable(format.displayName)
            }
            data = encoded
        }
        return data
    }

    /// Writes `text` using `format` and returns the file’s new on-disk state.
    ///
    /// - Symbolic links are written through.
    /// - A read-only file is refused with `TextFileError.readOnly` (the caller never overrides that).
    /// - A file with several hard links is rewritten in place so the links stay one file; otherwise the
    ///   write is atomic (temporary file + rename) and copies the original’s permissions, owner,
    ///   extended attributes and visibility flags to the new file.
    @discardableResult
    static func write(_ text: String, to url: URL, format: TextFileFormat) throws -> DiskState {
        let data = try encode(text, format: format)
        let path = FileIdentity.physicalPath(url.path) ?? url.path
        try writeData(data, toPath: path)
        return DiskState(stamp: stamp(of: url), digest: digest(data))
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func writeData(_ data: Data, toPath path: String) throws {
        var info = stat()
        let exists = stat(path, &info) == 0
        if exists {
            if (info.st_mode & S_IFMT) == S_IFDIR { throw posixError(EISDIR) }
            let immutable = UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)
            if access(path, W_OK) != 0 || info.st_flags & immutable != 0 { throw TextFileError.readOnly }
            if info.st_nlink > 1 {
                try overwriteInPlace(data, atPath: path)
                return
            }
        }
        do {
            try replaceAtomically(data, atPath: path, original: exists ? info : nil)
        } catch {
            // No permission to create files next to it (but the file itself is writable): write in place.
            if exists, let posix = error as? POSIXError, posix.code == .EACCES || posix.code == .EPERM {
                try overwriteInPlace(data, atPath: path)
            } else {
                throw error
            }
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                offset += written
            }
        }
    }

    /// Rewrites the file’s bytes through its existing inode (keeps hard links, owner and metadata).
    private static func overwriteInPlace(_ data: Data, atPath path: String) throws {
        let descriptor = open(path, O_WRONLY)
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { close(descriptor) }
        try writeAll(descriptor, data)
        // Truncate after writing: the file is never shorter than either version in between.
        if ftruncate(descriptor, off_t(data.count)) != 0 { throw posixError(errno) }
        _ = fsync(descriptor)
    }

    private static func replaceAtomically(_ data: Data, atPath path: String, original: stat?) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temporary = (directory.isEmpty ? "." : directory) + "/.\(name).gabetex-\(UUID().uuidString.prefix(8))"

        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw posixError(errno) }
        var finished = false
        defer {
            close(descriptor)
            if !finished { unlink(temporary) }
        }
        try writeAll(descriptor, data)
        if let original {
            fchmod(descriptor, original.st_mode & 0o7777)
            // Only root (or the owner, for the group) can do this; failing is harmless.
            _ = fchown(descriptor, original.st_uid, original.st_gid)
            let keptFlags = original.st_flags & (UInt32(UF_HIDDEN) | UInt32(UF_NODUMP))
            if keptFlags != 0 { _ = fchflags(descriptor, keptFlags) }
            copyExtendedAttributes(from: path, to: descriptor)
        } else {
            // New file: the default permissions (0666 filtered by the umask) like any other editor.
            let mask = umask(0)
            umask(mask)
            fchmod(descriptor, 0o666 & ~mask)
        }
        _ = fsync(descriptor)
        if rename(temporary, path) != 0 { throw posixError(errno) }
        finished = true
    }

    /// Copies every extended attribute (Finder tags, quarantine, comments …) that the kernel lets us set.
    private static func copyExtendedAttributes(from path: String, to descriptor: Int32) {
        let listLength = listxattr(path, nil, 0, 0)
        guard listLength > 0 else { return }
        var names = [CChar](repeating: 0, count: listLength)
        let got = listxattr(path, &names, listLength, 0)
        guard got > 0 else { return }
        var start = 0
        while start < got {
            var end = start
            while end < got, names[end] != 0 { end += 1 }
            if end > start {
                let name = String(decoding: names[start..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let size = getxattr(path, name, nil, 0, 0, 0)
                if size >= 0 {
                    var value = [UInt8](repeating: 0, count: size)
                    let read = value.isEmpty ? 0 : getxattr(path, name, &value, size, 0, 0)
                    if read >= 0 { _ = fsetxattr(descriptor, name, value, read, 0, 0) }
                }
            }
            start = end + 1
        }
    }

    // MARK: Disk state

    /// What the editor remembers about a file’s on-disk state, to tell its own writes from someone else’s
    /// (modification date and size: two quick external saves can share a timestamp, but rarely a size).
    nonisolated struct DiskStamp: Equatable, Sendable {
        var modified: Date?
        var size: Int
    }

    /// A file as the editor last saw it: its stamp and a fingerprint of its bytes. A changed stamp with an
    /// unchanged fingerprint (a `touch`, a re-save of identical bytes) is not a conflict.
    nonisolated struct DiskState: Equatable, Sendable {
        var stamp: DiskStamp?
        var digest: Int
    }

    /// Fingerprint of file contents (hashes every byte; stable within one run of the app).
    static func digest(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    /// The current on-disk stamp, nil when the file does not exist. Uses `stat` directly: `URL` caches its
    /// resource values, so `resourceValues(forKeys:)` on a URL that was queried before returns old data.
    static func stamp(of url: URL) -> DiskStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return DiskStamp(modified: Date(timeIntervalSince1970: seconds), size: Int(info.st_size))
    }

    /// The file’s current state (reads it to fingerprint it), nil when it does not exist or cannot be read.
    static func currentState(of url: URL) -> DiskState? {
        let before = stamp(of: url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return DiskState(stamp: before, digest: digest(data))
    }

    /// Modification date of a file, nil when it does not exist.
    static func modificationDate(of url: URL) -> Date? {
        stamp(of: url)?.modified
    }
}
