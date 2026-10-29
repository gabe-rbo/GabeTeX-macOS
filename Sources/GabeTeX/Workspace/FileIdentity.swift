import Foundation
import Darwin

/// Canonical file identity: the same file can be reached through different spellings (a symlinked
/// folder, `/var` vs `/private/var`, a different letter case on a case-insensitive volume). Two spellings
/// of one file must never become two buffers.
nonisolated enum FileIdentity {
    /// The physical path of `path`: symbolic links resolved and every component spelled exactly as it is
    /// stored on disk (the kernel’s `F_GETPATH`, which — unlike `realpath` — also fixes the case).
    /// When the item does not exist, the deepest existing ancestor is resolved and the rest is appended
    /// unchanged. Returns nil only for an empty path.
    static func physicalPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var remainder: [String] = []
        var current = path
        while true {
            if let physical = existingPhysicalPath(current) {
                return remainder.reversed().reduce(physical) { partial, component in
                    partial == "/" ? "/" + component : partial + "/" + component
                }
            }
            if current == "/" { return nil }
            let name = (current as NSString).lastPathComponent
            if !name.isEmpty { remainder.append(name) }
            let parent = (current as NSString).deletingLastPathComponent
            current = parent.isEmpty ? "/" : parent
        }
    }

    private static func existingPhysicalPath(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_EVTONLY)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(descriptor, F_GETPATH, &buffer) != -1 {
                let length = buffer.firstIndex(of: 0) ?? buffer.count
                return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        // Unreadable (no permission) but possibly present: fall back to realpath, which still resolves links.
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `path` equals `base` or lies below it (both spelled the same way).
    static func isInside(_ path: String, base: String) -> Bool {
        path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
