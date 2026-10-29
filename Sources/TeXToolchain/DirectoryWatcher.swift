import Foundation
import CoreServices
import Synchronization

/// Watches a directory tree (FSEvents) and reports changed paths, coalesced (~200 ms).
/// Used by the app to refresh the file tree and reload files changed on disk.
///
/// - File-level events (`kFSEventStreamCreateFlagFileEvents | NoDefer | WatchRoot`), latency 0.2 s.
/// - Paths with a hidden component below the root (`.git`, `.DS_Store`, editor swap files…) are ignored.
/// - `onChange` is called on a private serial queue with the unique changed URLs of one FSEvents batch
///   (files and directories, created/modified/removed/renamed — check the file system for the current
///   state). If the watched directory itself is moved or deleted, `onChange` receives `url`.
public final class DirectoryWatcher: Sendable {
    public let url: URL
    private let onChange: @Sendable ([URL]) -> Void
    private let queue = DispatchQueue(label: "io.github.gabe-rbo.GabeTeX.DirectoryWatcher")
    private let state = Mutex<State>(State())

    private struct State {
        var stream: FSEventStreamRef?
    }

    public init(url: URL, onChange: @escaping @Sendable ([URL]) -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
    }

    /// Starts watching (no-op when already started).
    public func start() {
        let sink = EventSink(rootPath: url.path, resolvedRootPath: Self.realPath(url.path), onChange: onChange)
        let watchedPath = url.path
        let queue = self.queue
        state.withLock { s in
            guard s.stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(sink).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<EventSink>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<EventSink>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, directoryWatcherCallback, &context, [watchedPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
            ) else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            if FSEventStreamStart(stream) {
                s.stream = stream
            } else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }

    /// Stops watching. No callback is delivered after `stop()` returns, except one that was already running.
    public func stop() {
        state.withLock { s in
            guard let stream = s.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            s.stream = nil
        }
    }

    /// True while the FSEvents stream runs.
    public var isRunning: Bool { state.withLock { $0.stream != nil } }

    /// The canonical path FSEvents reports events under (`realpath`, e.g. /var/… → /private/var/…).
    /// `URL.resolvingSymlinksInPath()` is not enough: it strips a leading /private again.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    deinit { stop() }
}

/// Receives FSEvents batches (on the watcher's queue) and forwards filtered URLs.
private final class EventSink: Sendable {
    let rootPath: String
    let resolvedRootPath: String
    let onChange: @Sendable ([URL]) -> Void

    init(rootPath: String, resolvedRootPath: String, onChange: @escaping @Sendable ([URL]) -> Void) {
        self.rootPath = rootPath
        self.resolvedRootPath = resolvedRootPath
        self.onChange = onChange
    }

    func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        var seen = Set<String>()
        var urls: [URL] = []
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                if seen.insert(rootPath).inserted { urls.append(URL(fileURLWithPath: rootPath, isDirectory: true)) }
                continue
            }
            guard let relative = relativePath(path) else { continue }
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let full = relative.isEmpty ? rootPath : rootPath + "/" + relative
            if seen.insert(full).inserted { urls.append(URL(fileURLWithPath: full).standardizedFileURL) }
        }
        if !urls.isEmpty { onChange(urls) }
    }

    /// Path relative to the watched root, in either spelling (FSEvents reports resolved paths, e.g. /private/var).
    private func relativePath(_ path: String) -> String? {
        for root in [rootPath, resolvedRootPath] {
            if path == root { return "" }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return nil
    }
}

private func directoryWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes: eventPaths is a CFArray of CFString.
    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let paths = (array as NSArray).compactMap { $0 as? String }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
    sink.handle(paths: paths, flags: flags)
}
