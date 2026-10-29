import AppKit
import Observation
import SwiftUI

/// How the presentation uses the displays.
public enum PresentationLayout: Hashable, Sendable {
    /// The slides on one display, the presenter view on another.
    case dual
    /// One display: the slides, or the presenter view while it is toggled on with P.
    case single(showsPresenter: Bool)
}

/// Remembered presentation settings (UserDefaults).
public enum PresentationPreferences {
    /// UserDefaults key of the "Notes on" setting (`PresentationNotesMode.rawValue`).
    public static let notesModeKey = "presentation.notesMode"

    /// The "Notes on" setting; `.automatic` until changed.
    public static var notesMode: PresentationNotesMode {
        get {
            UserDefaults.standard.string(forKey: notesModeKey).flatMap(PresentationNotesMode.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: notesModeKey) }
    }
}

/// Runs a presentation of a PDF: the audience window (slides full screen on black), the presenter window (current
/// and next slide, notes, timer, clock), the keyboard model, screen changes and live reloads.
///
/// Typical use (the app's workspace does this):
///
///     let presentation = PresentationController(title: "Talk", notesHint: .right)
///     presentation.onEnd = { … }
///     await presentation.start(url: pdf, at: 0, following: previewController, presenterScreen: window.screen)
///
/// - Two or more displays: the slides fill the external display, the presenter view the built-in one (see
///   `PresentationScreenPlanner`); one display: the slides, and P toggles the presenter view.
/// - Plugging or unplugging a display re-places the windows: losing the slides' display leaves the presenter view
///   on the remaining one (P shows the slides there); a new display gets the slides.
/// - While `following` a `PDFPreviewController`, every PDF it loads (a live compile) is reloaded here, keeping the
///   current slide (clamped).
/// - Esc, the End button, or closing a window ends it: windows close, the cursor and display sleep are restored and
///   `onEnd` is called (the host brings its window back).
///
/// The state and the commands also work without windows (`load(_:)` + `perform(_:)`), which is what the checks use.
@Observable
public final class PresentationController {
    /// The pointer hides over the slides after this long without moving.
    public static let cursorHideDelay: Duration = .seconds(2)
    /// A typed slide number that is not confirmed is dropped after this long.
    public static let digitEntryTimeout: Duration = .seconds(5)

    // MARK: Observable state

    /// Shown in the presenter view (the project name).
    public let title: String
    public private(set) var navigator = PresentationNavigator(pageCount: 0)
    public private(set) var timer = PresentationTimer()
    /// The presented document; replaced by every reload.
    public private(set) var deck = SlideDeck.empty
    public private(set) var layout = PresentationLayout.single(showsPresenter: false)
    /// `true` from `start` until `end`.
    public private(set) var isRunning = false
    /// `true` once ended (a controller is not reused).
    public private(set) var hasEnded = false
    /// Name of the display showing the slides.
    public private(set) var audienceDisplayName: String?
    /// The presenter and slide displays are exchanged.
    public private(set) var swapsDisplays = false
    /// Why the latest load failed (the previous PDF stays on screen).
    public private(set) var loadFailure: PDFLoadFailure?

    /// "Notes on": which half of double-width pages holds the notes. Remembered (`PresentationPreferences`).
    public var notesMode: PresentationNotesMode {
        didSet {
            guard notesMode != oldValue else { return }
            PresentationPreferences.notesMode = notesMode
            updateNotesSide()
        }
    }

    /// The notes side the document's preamble asks for (`\setbeameroption{show notes on second screen=…}`).
    public var notesHint: NotesSide? {
        didSet {
            guard notesHint != oldValue else { return }
            updateNotesSide()
        }
    }

    // MARK: Collaborators

    @ObservationIgnored public let renderer = SlideRenderer()
    /// Called once when the presentation ends (after its windows closed).
    @ObservationIgnored public var onEnd: (() -> Void)?

    @ObservationIgnored private var documentData: Data?
    @ObservationIgnored private(set) var primaryWindow: PresentationWindow?
    @ObservationIgnored private(set) var presenterWindow: PresentationWindow?
    @ObservationIgnored private weak var source: PDFPreviewController?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var digitTask: Task<Void, Never>?
    @ObservationIgnored private var cursorTask: Task<Void, Never>?
    @ObservationIgnored private var screenTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var preferredPresenterID: UInt32?
    /// Views to refresh after a state change (AppKit views; SwiftUI views observe the controller).
    @ObservationIgnored private let listeners = NSHashTable<AnyObject>.weakObjects()

    public init(title: String, notesHint: NotesSide? = nil, notesMode: PresentationNotesMode? = nil) {
        self.title = title
        self.notesHint = notesHint
        self.notesMode = notesMode ?? PresentationPreferences.notesMode
    }

    // MARK: Convenience

    public var currentIndex: Int { navigator.currentIndex }
    public var pageCount: Int { navigator.pageCount }
    public var nextIndex: Int? { navigator.nextIndex }
    /// `true` when the pages have a notes half.
    public var hasNotes: Bool { deck.hasNotes }
    /// The presenter view is on screen (its own display, or toggled on with P).
    public var showsPresenterView: Bool {
        switch layout {
        case .dual: true
        case .single(let showsPresenter): showsPresenter
        }
    }

    // MARK: Loading

    /// Reads and shows the PDF at `url` (no windows needed). Returns false when it cannot be shown; the previous
    /// document, if any, stays.
    @discardableResult
    public func load(_ url: URL) async -> Bool {
        switch await PDFFileReader.read(url) {
        case .failure(let failure):
            loadFailure = failure
            return false
        case .success(let data):
            return apply(data)
        }
    }

    /// Reloads from `url` in the background, keeping the current slide (clamped). Superseded by a newer call.
    public func reload(from url: URL) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let result = await PDFFileReader.read(url)
            guard let self, !Task.isCancelled, !self.hasEnded else { return }
            switch result {
            case .success(let data): self.apply(data)
            case .failure(let failure): self.loadFailure = failure
            }
        }
    }

    @discardableResult
    private func apply(_ data: Data) -> Bool {
        if data == documentData, !deck.pages.isEmpty {
            loadFailure = nil
            return true
        }
        guard let document = SlidePDF.document(from: data) else {
            loadFailure = .invalid
            return false
        }
        let pages = SlidePDF.pageInfos(of: document)
        let generation = renderer.setDocument(data)
        documentData = data
        loadFailure = nil
        deck = SlideDeck(generation: generation, pages: pages, notesSide: notesSide(for: pages))
        navigator.updatePageCount(pages.count)
        refreshViews(transition: nil)
        return true
    }

    private func notesSide(for pages: [SlidePageInfo]) -> NotesSide? {
        guard let first = pages.first(where: { $0.size.width > 0 && $0.size.height > 0 }) else { return nil }
        return SlideGeometry.notesSide(mode: notesMode, pageSize: first.size, hint: notesHint)
    }

    private func updateNotesSide() {
        let side = notesSide(for: deck.pages)
        guard side != deck.notesSide else { return }
        deck.notesSide = side
        refreshViews(transition: nil)
    }

    // MARK: Running

    /// Loads the PDF and shows the presentation from page `startPage` (0-based, clamped).
    ///
    /// - Parameters:
    ///   - following: a preview whose reloads (live compiles) the presentation follows.
    ///   - presenterScreen: the display the presenter view should prefer when there is no built-in display
    ///     (the project window's display).
    /// - Returns: false when the PDF could not be read (nothing is shown) or the presentation already ran.
    @discardableResult
    public func start(url: URL, at startPage: Int = 0, following: PDFPreviewController? = nil,
                      presenterScreen: NSScreen? = nil) async -> Bool {
        guard !isRunning, !hasEnded else { return false }
        guard await load(url), !hasEnded, !isRunning else { return false }
        navigator = PresentationNavigator(pageCount: deck.pageCount, startIndex: startPage)
        preferredPresenterID = presenterScreen?.presentationDisplayID
        isRunning = true
        timer = PresentationTimer()
        timer.start(at: Date())
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "Presenting slides")
        NSApp.activate()
        placeWindows()
        observeEnvironment()
        follow(following)
        sourceDidChange()       // a build that finished while the PDF was being read
        scheduleCursorHide()
        return true
    }

    /// Ends the presentation: closes the windows, restores the pointer and display sleep, calls `onEnd`.
    public func end() {
        guard !hasEnded else { return }
        hasEnded = true
        let wasRunning = isRunning
        isRunning = false
        timer.pause(at: Date())
        for task in [reloadTask, digitTask, cursorTask, screenTask] { task?.cancel() }
        sourceGeneration &+= 1
        source = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        workspaceObservers.removeAll()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if wasRunning { NSCursor.setHiddenUntilMouseMoves(false) }
        let windows = [presenterWindow, primaryWindow].compactMap { $0 }
        presenterWindow = nil
        primaryWindow = nil
        for window in windows { window.dismiss() }
        // Ending usually happens inside one of these windows' `sendEvent` (Esc): keep them alive until that returns.
        Task { @MainActor in withExtendedLifetime(windows) {} }
        PresentationTouchBarProvider.controllerDidChange(self)
        let callback = onEnd
        onEnd = nil
        callback?()
    }

    /// Brings the presentation windows to the front again (e.g. "Present" pressed while presenting).
    public func bringToFront() {
        guard isRunning else { return }
        NSApp.activate()
        primaryWindow?.orderFront(nil)
        (presenterWindow ?? primaryWindow)?.makeKeyAndOrderFront(nil)
        applyWindowLevel()
    }

    // MARK: Commands

    /// Performs a command (keys, clicks, controls) and updates the windows.
    @discardableResult
    public func perform(_ command: PresentationCommand) -> PresentationOutcome {
        guard !hasEnded else { return .none }
        let outcome = navigator.perform(command)
        switch outcome {
        case .end:
            end()
            return outcome
        case .togglePresenterView:
            togglePresenterView()
        case .moved(let from, let to):
            refreshViews(transition: transition(from: from, to: to))
        case .blankChanged:
            refreshViews(transition: nil)
        case .digitsChanged:
            refreshViews(transition: nil)
        case .none:
            break
        }
        scheduleDigitTimeout()
        PresentationTouchBarProvider.controllerDidChange(self)
        return outcome
    }

    /// Handles a key press from either window; false when the key is not part of the presentation keyboard.
    public func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags
        let key = PresentationKeyPress(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? "",
            shift: flags.contains(.shift), option: flags.contains(.option),
            command: flags.contains(.command), control: flags.contains(.control))
        guard let command = PresentationKeyMap.command(for: key) else { return false }
        perform(command)
        return true
    }

    /// Pause ↔ resume the elapsed-time timer.
    public func toggleTimer() {
        timer.toggle(at: Date())
        PresentationTouchBarProvider.controllerDidChange(self)
    }

    /// Restarts the timer at 0:00 (a paused timer stays paused).
    public func resetTimer() {
        timer.reset(at: Date())
        PresentationTouchBarProvider.controllerDidChange(self)
    }

    /// Exchanges the slides' and the presenter's displays (two displays only).
    public func swapDisplays() {
        guard layout == .dual else { return }
        swapsDisplays.toggle()
        placeWindows()
    }

    /// The transition into `to`: the page's own (`/Trans`) when advancing by one, else the standard dissolve.
    private func transition(from: Int, to: Int) -> SlideTransition {
        guard to == from + 1, deck.pages.indices.contains(to), let own = deck.pages[to].transition else {
            return .standard
        }
        return own
    }

    private func togglePresenterView() {
        guard case .single(let showsPresenter) = layout else { return }
        layout = .single(showsPresenter: !showsPresenter)
        primaryWindow?.stage.setMode(showsPresenter ? .audience : .presenter)
        primaryWindow?.focusStage()
        if showsPresenter {
            scheduleCursorHide()
        } else {
            cursorTask?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        refreshViews(transition: nil)
    }

    private func scheduleDigitTimeout() {
        digitTask?.cancel()
        guard !navigator.typedDigits.isEmpty else { return }
        digitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.digitEntryTimeout)
            guard let self, !Task.isCancelled else { return }
            self.perform(.clearDigits)
        }
    }

    // MARK: Views

    /// Registers an AppKit view that shows the presentation (`PresentationRefreshing`); held weakly.
    func addListener(_ view: PresentationRefreshing) {
        listeners.add(view)
        view.presentationDidChange(transition: nil)
    }

    private func refreshViews(transition: SlideTransition?) {
        for case let view as PresentationRefreshing in listeners.allObjects {
            view.presentationDidChange(transition: transition)
        }
    }

    // MARK: Pointer

    /// The pointer moved over the slides: show it now, hide it again after `cursorHideDelay`.
    func pointerMoved() {
        scheduleCursorHide()
    }

    private func scheduleCursorHide() {
        cursorTask?.cancel()
        guard isRunning else { return }
        cursorTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cursorHideDelay)
            guard let self, !Task.isCancelled, self.isRunning, self.isPointerOverSlides else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private var isPointerOverSlides: Bool {
        guard NSApp.isActive, let window = primaryWindow, window.isVisible, window.stage.mode == .audience else {
            return false
        }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: Windows and displays

    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    /// Creates or moves the windows for the connected displays (see `PresentationScreenPlanner`).
    private func placeWindows() {
        guard isRunning else { return }
        let screens = NSScreen.screens
        let descriptors = screens.compactMap(\.presentationScreen)
        guard let plan = PresentationScreenPlanner.plan(screens: descriptors, preferredPresenter: preferredPresenterID,
                                                        swapped: swapsDisplays),
              let audienceScreen = screens.first(where: { $0.presentationDisplayID == plan.audience }) else {
            end()
            return
        }
        audienceDisplayName = audienceScreen.localizedName
        if let presenterID = plan.presenter,
           let presenterScreen = screens.first(where: { $0.presentationDisplayID == presenterID }) {
            let primary = primaryWindow ?? PresentationWindow(controller: self, mode: .audience)
            primary.stage.setMode(.audience)
            primary.place(on: audienceScreen)
            let presenter = presenterWindow ?? PresentationWindow(controller: self, mode: .presenter)
            presenter.stage.setMode(.presenter)
            presenter.place(on: presenterScreen)
            primaryWindow = primary
            presenterWindow = presenter
            layout = .dual
            primary.orderFront(nil)
            presenter.makeKeyAndOrderFront(nil)
            presenter.focusStage()
        } else {
            // One display. Coming from two (the slides' display went away), the presenter view stays: that is
            // where the speaker is looking. P shows the slides.
            let showsPresenter: Bool
            switch layout {
            case .dual: showsPresenter = true
            case .single(let current): showsPresenter = current
            }
            if let presenterWindow {
                self.presenterWindow = nil
                presenterWindow.dismiss()
            }
            let primary = primaryWindow ?? PresentationWindow(controller: self, mode: .audience)
            primary.stage.setMode(showsPresenter ? .presenter : .audience)
            primary.place(on: audienceScreen)
            primaryWindow = primary
            layout = .single(showsPresenter: showsPresenter)
            primary.makeKeyAndOrderFront(nil)
            primary.focusStage()
        }
        applyWindowLevel()
        refreshViews(transition: nil)
        PresentationTouchBarProvider.controllerDidChange(self)
    }

    /// Above the menu bar and the Dock while the app is active; ordinary windows while another app is in front, so
    /// the speaker can switch to a demo.
    private func applyWindowLevel() {
        let level: NSWindow.Level = NSApp.isActive ? .presentation : .normal
        for window in [primaryWindow, presenterWindow].compactMap({ $0 }) where window.level != level {
            window.level = level
        }
    }

    private func observeEnvironment() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyWindowLevel() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        })
    }

    /// Display changes arrive in bursts: re-place once they settle.
    private func screensDidChange() {
        screenTask?.cancel()
        screenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.placeWindows()
        }
    }

    // MARK: Following the preview

    /// Reloads the presentation whenever `preview` finishes loading a PDF (a live compile), keeping the current
    /// slide (clamped). nil stops following. `start` calls it with its `following` argument.
    public func follow(_ preview: PDFPreviewController?) {
        source = preview
        sourceGeneration &+= 1
        observeSource()
    }

    /// Every finished load of the preview (`isLoading` back to false) reloads the presentation.
    private func observeSource() {
        guard let source, !hasEnded else { return }
        let generation = sourceGeneration
        withObservationTracking {
            _ = source.isLoading
            _ = source.hasDocument
            _ = source.pdfURL
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sourceGeneration == generation else { return }
                self.observeSource()
                self.sourceDidChange()
            }
        }
    }

    private func sourceDidChange() {
        guard !hasEnded, let source, !source.isLoading, source.hasDocument, source.loadFailure == nil,
              let url = source.pdfURL else { return }
        reload(from: url)
    }
}

/// An AppKit view that shows part of a presentation and is refreshed by its controller.
@MainActor
protocol PresentationRefreshing: AnyObject {
    func presentationDidChange(transition: SlideTransition?)
}

extension NSWindow.Level {
    /// Above the menu bar (and the Dock): the slides cover the whole display.
    static let presentation = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
}

extension NSScreen {
    /// The `CGDirectDisplayID` of the screen.
    var presentationDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen as the planner sees it.
    var presentationScreen: PresentationScreen? {
        guard let id = presentationDisplayID else { return nil }
        return PresentationScreen(id: id, frame: frame, isBuiltIn: CGDisplayIsBuiltin(id) != 0, name: localizedName)
    }
}
