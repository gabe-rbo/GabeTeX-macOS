import AppKit

/// Keeps exactly one ⌘W item in the menu bar.
///
/// SwiftUI's File menu carries the system's own “Close ⌘W” and its “Close All” alternate (AppKit's
/// `performClose:` / `closeAll:`), next to the app's own Close Tab / Close Window item. Two ⌘W items are
/// ambiguous, so this removes the system ones.
///
/// In every top-level menu that contains one of the app's own close items (recognised by title), any *other* item
/// counts as a system close when
/// - its action is `performClose:`, `_performClose:`, `closeAll:` or `_closeAll:`, or
/// - its key equivalent is “w” with ⌘ (with or without ⌥ / ⇧, which covers “Close All”).
/// Items that follow a removed one as its alternates go too. A menu without an own close item is never touched,
/// so ⌘W cannot end up missing.
///
/// When is the menu cleaned? Whenever an item is added, changed or removed in any menu, the main menu is replaced,
/// a window becomes key or main, the app becomes active, a menu starts tracking, after each event (throttled) and
/// once a second while the app is active — SwiftUI rebuilds or fills the menu at moments no single notification
/// covers.
///
/// Diagnostics: launch with `-GabeTeXDebugMenus YES` and every run appends the File menu's items (title, key
/// equivalent, modifier mask, action, target, alternate, separator, tag, whether it would be removed) to
/// `/tmp/gabetex-menus.txt`.
@MainActor
final class SystemCloseItemRemover {
    static let shared = SystemCloseItemRemover()

    static let debugDefaultsKey = "GabeTeXDebugMenus"
    static let debugLogPath = "/tmp/gabetex-menus.txt"

    /// Actions of AppKit's own close commands.
    private static let systemCloseActions: Set<String> = ["performClose:", "_performClose:", "closeAll:", "_closeAll:"]

    private var observers: [NSObjectProtocol] = []
    private var mainMenuObservation: NSKeyValueObservation?
    private var timer: Timer?
    private var isScheduled = false
    private var lastRun = Date.distantPast
    private var runCount = 0
    private var lastLoggedSignature = ""

    private init() {}

    /// Starts watching the menu bar. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        // Passes that wait for SwiftUI to finish its update.
        let deferred: [(Notification.Name, String)] = [
            (NSMenu.didAddItemNotification, "menuDidAddItem"),
            (NSMenu.didChangeItemNotification, "menuDidChangeItem"),
            (NSMenu.didRemoveItemNotification, "menuDidRemoveItem"),
            (NSWindow.didBecomeKeyNotification, "windowDidBecomeKey"),
            (NSWindow.didBecomeMainNotification, "windowDidBecomeMain"),
            (NSApplication.didBecomeActiveNotification, "appDidBecomeActive"),
            (NSApplication.didUpdateNotification, "appDidUpdate"),
        ]
        for (name, trigger) in deferred {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(trigger) }
            })
        }
        // A menu is about to be shown: clean it right now, and once more when it has been filled.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.run("menuDidBeginTracking")
                self?.schedule("menuDidBeginTracking+")
            }
        })
        // SwiftUI may hand AppKit a brand-new menu instead of changing the old one.
        mainMenuObservation = NSApp.observe(\.mainMenu, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.schedule("mainMenuReplaced") }
        }
        // Fallback for anything the notifications miss; also runs while a menu is open (common run loop modes).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSApp.isActive { self?.schedule("timer") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if Self.isDebugging {
            Self.append("=== GabeTeX menu diagnostics started \(Date()) (pid \(ProcessInfo.processInfo.processIdentifier))\n")
        }
        schedule("start")
    }

    // MARK: Scheduling

    /// Coalesces bursts into one pass after SwiftUI has finished its update; per-event passes are throttled.
    private func schedule(_ trigger: String) {
        guard !isScheduled else { return }
        if trigger == "appDidUpdate", Date().timeIntervalSince(lastRun) < 0.5 { return }
        isScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.run(trigger)
        }
    }

    private func run(_ trigger: String) {
        lastRun = Date()
        guard let mainMenu = NSApp.mainMenu else { return }
        runCount += 1
        let ownTitles = Self.ownTitles
        let debugging = Self.isDebugging
        if debugging {
            let report = Self.report(for: mainMenu, ownTitles: ownTitles)
            // Chatty triggers only log when the menu looks different from the last logged state.
            let chatty = trigger == "timer" || trigger == "appDidUpdate"
            if !chatty || report.signature != lastLoggedSignature {
                lastLoggedSignature = report.signature
                Self.append("--- run #\(runCount) trigger=\(trigger) \(Date())\n\(report.text)")
            }
        }
        let removed = Self.removeSystemCloseItems(in: mainMenu, ownTitles: ownTitles)
        if debugging, removed > 0 { Self.append("    removed \(removed) item(s)\n") }
    }

    // MARK: Matching and removal

    /// The titles of the app's own close items, as SwiftUI shows them.
    private static var ownTitles: Set<String> {
        [String(localized: "Close Tab"), String(localized: "Close Window")]
    }

    /// Whether `item` is AppKit's own close command rather than one of the app's.
    static func isSystemClose(_ item: NSMenuItem, ownTitles: Set<String>) -> Bool {
        if item.isSeparatorItem || ownTitles.contains(item.title) { return false }
        if let action = item.action, systemCloseActions.contains(NSStringFromSelector(action)) { return true }
        guard item.keyEquivalent.lowercased() == "w" else { return false }
        let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        return mask.contains(.command) && mask.isSubset(of: [.command, .option, .shift])
    }

    /// Whether a menu holds one of the app's own close items (only such menus are cleaned).
    private static func hasOwnCloseItem(_ menu: NSMenu, ownTitles: Set<String>) -> Bool {
        menu.items.contains { ownTitles.contains($0.title) }
    }

    /// Removes the system close items (and alternates hanging on them) from every menu that has an own close
    /// item. Returns how many items were removed.
    @discardableResult
    static func removeSystemCloseItems(in mainMenu: NSMenu, ownTitles: Set<String>) -> Int {
        var removed = 0
        for topLevel in mainMenu.items {
            guard let menu = topLevel.submenu, hasOwnCloseItem(menu, ownTitles: ownTitles) else { continue }
            var removedHere = 0
            var index = 0
            var previousWasRemoved = false
            while index < menu.items.count {
                let item = menu.items[index]
                let alternateOfRemoved = previousWasRemoved && item.isAlternate && !ownTitles.contains(item.title)
                if isSystemClose(item, ownTitles: ownTitles) || alternateOfRemoved {
                    menu.removeItem(at: index)
                    removedHere += 1
                    previousWasRemoved = true
                } else {
                    previousWasRemoved = false
                    index += 1
                }
            }
            if removedHere > 0 { tidySeparators(in: menu) }
            removed += removedHere
        }
        return removed
    }

    /// Removes the doubled and trailing separators a removed item can leave behind.
    private static func tidySeparators(in menu: NSMenu) {
        var index = 1
        while index < menu.items.count {
            if menu.items[index].isSeparatorItem, menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            } else {
                index += 1
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    // MARK: Diagnostics

    private static var isDebugging: Bool { UserDefaults.standard.bool(forKey: debugDefaultsKey) }

    /// One line per item of every menu that holds an own close item (else of the second top-level menu, which is
    /// File), with what the matching would do.
    static func report(for mainMenu: NSMenu, ownTitles: Set<String>) -> (text: String, signature: String) {
        var text = "mainMenu: \(mainMenu.items.map(\.title))\nownTitles: \(ownTitles.sorted())\n"
        var menus: [(menu: NSMenu, title: String)] = []
        for top in mainMenu.items {
            if let submenu = top.submenu, hasOwnCloseItem(submenu, ownTitles: ownTitles) {
                menus.append((submenu, top.title))
            }
        }
        if menus.isEmpty {
            text += "no menu holds an own close item; dumping the menu at index 1\n"
            if mainMenu.items.count > 1, let submenu = mainMenu.items[1].submenu {
                menus.append((submenu, mainMenu.items[1].title))
            }
        }
        for (menu, title) in menus {
            let delegate = menu.delegate.map { String(describing: type(of: $0)) } ?? "nil"
            text += "menu \"\(title)\" (\(menu.items.count) items, delegate: \(delegate))\n"
            var previousWasRemoved = false
            for (index, item) in menu.items.enumerated() {
                let remove = isSystemClose(item, ownTitles: ownTitles)
                    || (previousWasRemoved && item.isAlternate && !ownTitles.contains(item.title))
                previousWasRemoved = remove
                let action = item.action.map { NSStringFromSelector($0) } ?? "nil"
                let target = item.target.map { String(describing: type(of: $0)) } ?? "nil"
                text += "  [\(index)] title=\"\(item.title)\" key=\"\(escaped(item.keyEquivalent))\""
                text += " mask=0x\(String(item.keyEquivalentModifierMask.rawValue, radix: 16)) action=\(action) target=\(target)"
                text += " alternate=\(item.isAlternate) separator=\(item.isSeparatorItem) tag=\(item.tag) remove=\(remove)\n"
            }
        }
        return (text, text)
    }

    private static func escaped(_ string: String) -> String {
        string.unicodeScalars.map { scalar in
            (0x20..<0x7F).contains(scalar.value) ? String(scalar) : "\\u{\(String(scalar.value, radix: 16))}"
        }.joined()
    }

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: debugLogPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
