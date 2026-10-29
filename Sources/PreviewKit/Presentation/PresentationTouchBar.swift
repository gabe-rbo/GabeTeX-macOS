import AppKit

/// The Touch Bar while presenting (shown by the presentation windows, on Macs that have one):
/// ‹ 5 / 23 › · 12:34 ⏸ · Black Screen · … · End.
public enum PresentationTouchBar {
    public enum Item {
        /// Previous slide, "5 / 23", next slide.
        public static let navigation = make("navigation")
        /// Elapsed time and pause / resume.
        public static let timer = make("timer")
        /// Black screen on / off.
        public static let blank = make("blank")
        /// End the presentation.
        public static let end = make("end")

        private static func make(_ name: String) -> NSTouchBarItem.Identifier {
            NSTouchBarItem.Identifier("io.github.gabe-rbo.GabeTeX.presentation.\(name)")
        }
    }

    public static let defaultItemIdentifiers: [NSTouchBarItem.Identifier] = [
        Item.navigation, .fixedSpaceLarge, Item.timer, .fixedSpaceLarge, Item.blank, .flexibleSpace, Item.end,
    ]
}

/// The presentation `NSTouchBar`; it owns its delegate (`NSTouchBar.delegate` is weak).
final class PresentationTouchBarHost: NSTouchBar {
    let provider: PresentationTouchBarProvider

    init(provider: PresentationTouchBarProvider) {
        self.provider = provider
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Builds the presentation Touch Bar's items and keeps them current: pushed by the controller after every
/// command (`controllerDidChange`), and ticking twice a second for the timer.
final class PresentationTouchBarProvider: NSObject, NSTouchBarDelegate {
    private typealias Item = PresentationTouchBar.Item

    private(set) weak var controller: PresentationController?

    private let previousButtons = NSHashTable<NSButton>.weakObjects()
    private let nextButtons = NSHashTable<NSButton>.weakObjects()
    private let counterLabels = NSHashTable<NSTextField>.weakObjects()
    private let timerLabels = NSHashTable<NSTextField>.weakObjects()
    private let timerButtons = NSHashTable<NSButton>.weakObjects()
    private let blankButtons = NSHashTable<NSButton>.weakObjects()
    private var tickTask: Task<Void, Never>?

    private static let live = NSHashTable<PresentationTouchBarProvider>.weakObjects()

    init(controller: PresentationController) {
        self.controller = controller
        super.init()
        Self.live.add(self)
    }

    isolated deinit {
        tickTask?.cancel()
    }

    /// Refreshes the bars of `controller` (called after every change of the presentation).
    static func controllerDidChange(_ controller: PresentationController) {
        for provider in live.allObjects where provider.controller === controller {
            provider.refresh()
        }
    }

    func makeTouchBar() -> NSTouchBar {
        let bar = PresentationTouchBarHost(provider: self)
        bar.delegate = self
        bar.defaultItemIdentifiers = PresentationTouchBar.defaultItemIdentifiers
        startTicking()
        return bar
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.controller?.isRunning == true else { return }
                self.refreshTimer()
            }
        }
    }

    // MARK: State

    func refresh() {
        guard let controller else {
            for button in previousButtons.allObjects + nextButtons.allObjects + timerButtons.allObjects
                + blankButtons.allObjects { button.isEnabled = false }
            return
        }
        let navigator = controller.navigator
        let count = navigator.pageCount
        let current = count > 0 ? navigator.currentIndex + 1 : 0
        let blanked = navigator.blank != .none
        for button in previousButtons.allObjects { button.isEnabled = navigator.previousIndex != nil || blanked }
        for button in nextButtons.allObjects { button.isEnabled = navigator.nextIndex != nil || blanked }
        for label in counterLabels.allObjects {
            label.stringValue = "\(current) / \(count)"
            label.setAccessibilityLabel(String(localized: "Slide \(current) of \(count)"))
        }
        for button in blankButtons.allObjects {
            button.state = navigator.blank == .black ? .on : .off
            button.bezelColor = navigator.blank == .black ? .systemOrange : nil
        }
        for button in timerButtons.allObjects {
            let running = controller.timer.isRunning
            let title = running ? String(localized: "Pause Timer") : String(localized: "Resume Timer")
            button.image = Self.symbol(running ? "pause.fill" : "play.fill", title)
            button.setAccessibilityLabel(title)
        }
        refreshTimer()
    }

    private func refreshTimer() {
        guard let controller else { return }
        let text = PresentationTimer.format(controller.timer.elapsed(at: Date()))
        for label in timerLabels.allObjects where label.stringValue != text {
            label.stringValue = text
            label.textColor = controller.timer.isRunning ? .labelColor : .systemOrange
        }
    }

    /// The current text of the counter label (for checks).
    var counterText: String? { counterLabels.allObjects.first?.stringValue }

    // MARK: NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item: NSTouchBarItem?
        switch identifier {
        case Item.navigation: item = makeNavigationItem()
        case Item.timer: item = makeTimerItem()
        case Item.blank: item = makeBlankItem()
        case Item.end: item = makeEndItem()
        default: item = nil
        }
        if item != nil { refresh() }
        return item
    }

    private func makeNavigationItem() -> NSTouchBarItem {
        let previous = Self.button(symbol: "chevron.left", title: String(localized: "Previous Slide"),
                                   target: self, action: #selector(previousSlide(_:)))
        let next = Self.button(symbol: "chevron.right", title: String(localized: "Next Slide"),
                               target: self, action: #selector(nextSlide(_:)))
        let counter = NSTextField(labelWithString: "– / –")
        counter.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        counter.alignment = .center
        counter.translatesAutoresizingMaskIntoConstraints = false
        counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        previousButtons.add(previous)
        nextButtons.add(next)
        counterLabels.add(counter)
        let stack = NSStackView(views: [previous, counter, next])
        stack.spacing = 6
        let item = NSCustomTouchBarItem(identifier: Item.navigation)
        item.view = stack
        item.customizationLabel = String(localized: "Slides")
        return item
    }

    private func makeTimerItem() -> NSTouchBarItem {
        let label = NSTextField(labelWithString: "00:00")
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.setAccessibilityLabel(String(localized: "Elapsed time"))
        let toggle = Self.button(symbol: "pause.fill", title: String(localized: "Pause Timer"),
                                 target: self, action: #selector(toggleTimer(_:)))
        timerLabels.add(label)
        timerButtons.add(toggle)
        let stack = NSStackView(views: [label, toggle])
        stack.spacing = 8
        let item = NSCustomTouchBarItem(identifier: Item.timer)
        item.view = stack
        item.customizationLabel = String(localized: "Timer")
        return item
    }

    private func makeBlankItem() -> NSTouchBarItem {
        let button = Self.button(symbol: "eye.slash", title: String(localized: "Black Screen"),
                                 target: self, action: #selector(toggleBlack(_:)))
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageLeading
        button.title = String(localized: "Black Screen")
        blankButtons.add(button)
        let item = NSCustomTouchBarItem(identifier: Item.blank)
        item.view = button
        item.customizationLabel = String(localized: "Black Screen")
        return item
    }

    private func makeEndItem() -> NSTouchBarItem {
        let title = String(localized: "End Presentation")
        let button = NSButton(title: title, target: self, action: #selector(endPresentation(_:)))
        button.bezelColor = .systemRed
        button.setAccessibilityLabel(title)
        let item = NSCustomTouchBarItem(identifier: Item.end)
        item.view = button
        item.customizationLabel = title
        return item
    }

    // MARK: Actions

    @objc private func previousSlide(_ sender: Any?) { controller?.perform(.previous) }
    @objc private func nextSlide(_ sender: Any?) { controller?.perform(.next) }
    @objc private func toggleTimer(_ sender: Any?) { controller?.toggleTimer() }
    @objc private func toggleBlack(_ sender: Any?) { controller?.perform(.toggleBlack) }
    @objc private func endPresentation(_ sender: Any?) { controller?.perform(.end) }

    // MARK: Helpers

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private static func button(symbol name: String, title: String, target: AnyObject, action: Selector) -> NSButton {
        let button: NSButton
        if let image = symbol(name, title) {
            button = NSButton(image: image, target: target, action: action)
        } else {
            button = NSButton(title: title, target: target, action: action)
        }
        button.setAccessibilityLabel(title)
        return button
    }
}
