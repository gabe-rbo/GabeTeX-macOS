import AppKit
import Observation
import PDFKit

extension GabePDFView {
    /// The PDF preview's Touch Bar (see `PDFTouchBar`), in the docked preview and in the separate PDF window.
    /// AppKit asks for it lazily while the view is first responder, and only on Macs with a Touch Bar.
    public override func makeTouchBar() -> NSTouchBar? {
        PDFTouchBarProvider(view: self).makeTouchBar()
    }
}

/// The PDF preview's `NSTouchBar`; it owns its delegate (`NSTouchBar.delegate` is weak).
final class GabePDFTouchBar: NSTouchBar {
    let provider: PDFTouchBarProvider

    init(provider: PDFTouchBarProvider) {
        self.provider = provider
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Builds the PDF Touch Bar's items and keeps them in sync with the controller (page, zoom — observed) and
/// the host's `PDFTouchBarStatus` (compile state, detached window — pushed).
final class PDFTouchBarProvider: NSObject, NSTouchBarDelegate {
    private typealias Item = PDFTouchBar.Item

    weak var view: GabePDFView?
    private(set) weak var bar: NSTouchBar?

    private let compileButtons = NSHashTable<NSButton>.weakObjects()
    private let previousButtons = NSHashTable<NSButton>.weakObjects()
    private let nextButtons = NSHashTable<NSButton>.weakObjects()
    private let pageLabels = NSHashTable<NSTextField>.weakObjects()
    private let zoomControls = NSHashTable<NSSegmentedControl>.weakObjects()
    private let sourceButtons = NSHashTable<NSButton>.weakObjects()
    private let windowButtons = NSHashTable<NSButton>.weakObjects()
    private weak var observedController: PDFPreviewController?
    private var observationGeneration = 0

    private static let live = NSHashTable<PDFTouchBarProvider>.weakObjects()

    init(view: GabePDFView) {
        self.view = view
        super.init()
        Self.live.add(self)
    }

    static func hostStateDidChange(for controller: PDFPreviewController) {
        for provider in live.allObjects where provider.view?.controller === controller {
            provider.refresh()
        }
    }

    func makeTouchBar() -> NSTouchBar {
        let bar = GabePDFTouchBar(provider: self)
        bar.delegate = self
        bar.customizationIdentifier = PDFTouchBar.customizationIdentifier
        bar.customizationAllowedItemIdentifiers = PDFTouchBar.customizationAllowedItemIdentifiers
        bar.defaultItemIdentifiers = PDFTouchBar.defaultItemIdentifiers
        self.bar = bar
        observeController()
        return bar
    }

    // MARK: State

    private var controller: PDFPreviewController? { view?.controller }
    private var status: PDFTouchBarStatus { controller?.touchBarStatus ?? PDFTouchBarStatus() }
    private var hostCommand: ((PDFTouchBarCommand) -> Void)? { controller?.onTouchBarCommand }

    /// Page and zoom follow the controller's observable state. Each change re-registers the observation; a
    /// generation number drops a registration that was superseded (controller swapped).
    private func observeController() {
        observationGeneration &+= 1
        observedController = controller
        guard let controller else { return }
        let generation = observationGeneration
        withObservationTracking {
            _ = controller.currentPageIndex
            _ = controller.pageCount
            _ = controller.scaleFactor
            _ = controller.hasDocument
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeController()
                self.refresh()
            }
        }
    }

    /// Applies controller and host state to every live control.
    func refresh() {
        let controller = self.controller
        if controller !== observedController { observeController() }
        let status = self.status
        let hasHost = hostCommand != nil
        for button in compileButtons.allObjects { configureCompile(button, status: status, hasHost: hasHost) }
        let pageCount = controller?.pageCount ?? 0
        let hasDocument = controller?.hasDocument == true && pageCount > 0
        let page = min(max((controller?.currentPageIndex ?? 0) + 1, 1), max(pageCount, 1))
        for button in previousButtons.allObjects { button.isEnabled = hasDocument && page > 1 }
        for button in nextButtons.allObjects { button.isEnabled = hasDocument && page < pageCount }
        for label in pageLabels.allObjects {
            label.stringValue = hasDocument ? "\(page) / \(pageCount)" : "– / –"
            label.setAccessibilityLabel(hasDocument ? String(localized: "Page \(page) of \(pageCount)")
                                                    : String(localized: "No pages"))
        }
        for control in zoomControls.allObjects {
            control.setEnabled(controller?.canZoomOut == true, forSegment: 0)
            control.setEnabled(hasDocument, forSegment: 1)
            control.setEnabled(controller?.canZoomIn == true, forSegment: 2)
        }
        let canShowSource = controller?.canShowSource == true
        for button in sourceButtons.allObjects { button.isEnabled = canShowSource }
        for button in windowButtons.allObjects { configureWindowButton(button, status: status, hasHost: hasHost) }
    }

    // MARK: NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item: NSTouchBarItem?
        switch identifier {
        case Item.compile: item = makeCompileItem()
        case Item.pageNavigation: item = makePageNavigationItem()
        case Item.zoom: item = makeZoomItem()
        case Item.showInSource: item = makeShowInSourceItem()
        case Item.previewWindow: item = makeWindowItem()
        default: item = nil
        }
        if item != nil { refresh() }
        return item
    }

    // MARK: Items

    private func makeCompileItem() -> NSTouchBarItem {
        let button = PDFTouchBarButton.make(symbol: "play.fill", fallbackTitle: String(localized: "Compile"),
                                            label: String(localized: "Compile"), width: 56) { [weak self] in
            guard let self else { return }
            self.hostCommand?(self.status.compile == .running ? .stopCompile : .compile)
        }
        compileButtons.add(button)
        return customItem(Item.compile, view: button, label: String(localized: "Compile"), priority: .high)
    }

    private func configureCompile(_ button: NSButton, status: PDFTouchBarStatus, hasHost: Bool) {
        let running = status.compile == .running
        let label = running ? String(localized: "Stop") : String(localized: "Compile")
        if let image = NSImage(systemSymbolName: running ? "stop.fill" : "play.fill", accessibilityDescription: label) {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.title = label
        }
        button.setAccessibilityLabel(label)
        button.isEnabled = hasHost && status.compile != .unavailable
    }

    private func makePageNavigationItem() -> NSTouchBarItem {
        let previous = PDFTouchBarButton.make(symbol: "chevron.left", fallbackTitle: "‹",
                                              label: String(localized: "Previous Page"), width: 40) { [weak self] in
            self?.controller?.goToPreviousPage()
        }
        let next = PDFTouchBarButton.make(symbol: "chevron.right", fallbackTitle: "›",
                                          label: String(localized: "Next Page"), width: 40) { [weak self] in
            self?.controller?.goToNextPage()
        }
        let label = NSTextField(labelWithString: "– / –")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        let stack = NSStackView(views: [previous, label, next])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(String(localized: "Page"))
        previousButtons.add(previous)
        nextButtons.add(next)
        pageLabels.add(label)
        return customItem(Item.pageNavigation, view: stack, label: String(localized: "Page"), priority: .normal)
    }

    private func makeZoomItem() -> NSTouchBarItem {
        let control = NSSegmentedControl(labels: ["", "", ""], trackingMode: .momentary,
                                         target: self, action: #selector(zoomTapped(_:)))
        let segments: [(String, String, String)] = [
            ("minus.magnifyingglass", "−", String(localized: "Zoom Out")),
            ("arrow.left.and.right", "↔", String(localized: "Fit Width")),
            ("plus.magnifyingglass", "+", String(localized: "Zoom In")),
        ]
        for (index, segment) in segments.enumerated() {
            if let image = NSImage(systemSymbolName: segment.0, accessibilityDescription: segment.2) {
                control.setImage(image, forSegment: index)
            } else {
                control.setLabel(segment.1, forSegment: index)
            }
            control.setToolTip(segment.2, forSegment: index)
            control.setWidth(40, forSegment: index)
        }
        control.setAccessibilityLabel(String(localized: "Zoom"))
        zoomControls.add(control)
        return customItem(Item.zoom, view: control, label: String(localized: "Zoom"), priority: .normal)
    }

    @objc private func zoomTapped(_ sender: NSSegmentedControl) {
        guard let controller else { return }
        switch sender.selectedSegment {
        case 0: controller.zoomOut()
        case 1: controller.zoomToFitWidth()
        case 2: controller.zoomIn()
        default: break
        }
    }

    private func makeShowInSourceItem() -> NSTouchBarItem {
        let button = PDFTouchBarButton.make(symbol: "chevron.left.forwardslash.chevron.right",
                                            fallbackTitle: String(localized: "Show in Source"),
                                            label: String(localized: "Show in Source"), width: 44) { [weak self] in
            self?.controller?.showSourceOfVisibleArea()
        }
        sourceButtons.add(button)
        return customItem(Item.showInSource, view: button, label: String(localized: "Show in Source"), priority: .normal)
    }

    private func makeWindowItem() -> NSTouchBarItem {
        let button = PDFTouchBarButton.make(symbol: "arrow.up.forward.app", fallbackTitle: "PDF",
                                            label: String(localized: "Open PDF in Separate Window"), width: 44) { [weak self] in
            self?.hostCommand?(.togglePreviewWindow)
        }
        windowButtons.add(button)
        return customItem(Item.previewWindow, view: button, label: String(localized: "PDF Window"), priority: .low)
    }

    private func configureWindowButton(_ button: NSButton, status: PDFTouchBarStatus, hasHost: Bool) {
        let detached = status.isPreviewDetached == true
        let label = detached ? String(localized: "Attach PDF to Project Window")
                             : String(localized: "Open PDF in Separate Window")
        if let image = NSImage(systemSymbolName: detached ? "arrow.down.right.and.arrow.up.left" : "arrow.up.forward.app",
                               accessibilityDescription: label) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.setAccessibilityLabel(label)
        button.isEnabled = hasHost && status.isPreviewDetached != nil
    }

    private func customItem(_ identifier: NSTouchBarItem.Identifier, view: NSView, label: String,
                            priority: NSTouchBarItem.Priority) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        item.customizationLabel = label
        item.visibilityPriority = priority
        return item
    }
}

/// A Touch Bar button that runs a closure.
final class PDFTouchBarButton: NSButton {
    var onPress: (() -> Void)?

    static func make(symbol: String, fallbackTitle: String, label: String, width: CGFloat,
                     onPress: @escaping () -> Void) -> PDFTouchBarButton {
        let button = PDFTouchBarButton(frame: .zero)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .push
        button.isBordered = true
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.title = fallbackTitle
        }
        button.target = button
        button.action = #selector(press(_:))
        button.onPress = onPress
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    @objc private func press(_ sender: Any?) {
        onPress?()
    }
}
