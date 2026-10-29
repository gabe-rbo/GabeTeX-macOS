import AppKit
import TeXCore

extension LaTeXTextView {
    /// The editor's Touch Bar (see `EditorTouchBar`). AppKit asks for it lazily while the editor is first
    /// responder, and only on Macs with a Touch Bar.
    public override func makeTouchBar() -> NSTouchBar? {
        EditorTouchBarProvider(textView: self).makeTouchBar()
    }

    /// NSTextView would replace the bar's identifiers with its rich-text formatting items (whenever a text
    /// setting changes). The editor's bar keeps its own; its state is refreshed by the provider. Deliberately
    /// does not touch `touchBar` (which would create a bar on Macs without one).
    public override func updateTouchBarItemIdentifiers() {}
}

/// The editor's `NSTouchBar`. It owns its delegate (`NSTouchBar.delegate` is weak).
final class LaTeXEditorTouchBar: NSTouchBar {
    let provider: EditorTouchBarProvider

    init(provider: EditorTouchBarProvider) {
        self.provider = provider
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Builds the editor's Touch Bar items and keeps them in sync with the host's `EditorTouchBarStatus`.
///
/// Items are created on demand (`NSTouchBarDelegate`), also for the customization palette, so every
/// stateful control is tracked weakly and refreshed together.
final class EditorTouchBarProvider: NSObject, NSTouchBarDelegate {
    private typealias Item = EditorTouchBar.Item

    weak var textView: LaTeXTextView?
    private(set) weak var bar: NSTouchBar?

    private let compileButtons = NSHashTable<NSButton>.weakObjects()
    private let issueButtons = NSHashTable<NSButton>.weakObjects()
    private let showInPDFButtons = NSHashTable<NSButton>.weakObjects()
    private let previewButtons = NSHashTable<NSButton>.weakObjects()
    private let previewWindowButtons = NSHashTable<NSButton>.weakObjects()
    private var scrubberSources: [TouchBarScrubberSource] = []
    private var popovers: [NSTouchBarItem.Identifier: NSPopoverTouchBarItem] = [:]

    /// Live providers, to forward host state changes (weak: a provider lives as long as its bar).
    private static let live = NSHashTable<EditorTouchBarProvider>.weakObjects()

    init(textView: LaTeXTextView) {
        self.textView = textView
        super.init()
        Self.live.add(self)
    }

    /// Called when the host changed `touchBarStatus` / `onTouchBarCommand` of `controller`.
    static func hostStateDidChange(for controller: EditorController) {
        for provider in live.allObjects where provider.textView?.controller === controller {
            provider.refresh()
        }
    }

    func makeTouchBar() -> NSTouchBar {
        let bar = LaTeXEditorTouchBar(provider: self)
        bar.delegate = self
        bar.customizationIdentifier = EditorTouchBar.customizationIdentifier
        bar.customizationAllowedItemIdentifiers = EditorTouchBar.customizationAllowedItemIdentifiers
        bar.defaultItemIdentifiers = EditorTouchBar.defaultItemIdentifiers(for: status)
        self.bar = bar
        return bar
    }

    // MARK: Host state

    private var controller: EditorController? { textView?.controller }
    private var status: EditorTouchBarStatus { controller?.touchBarStatus ?? EditorTouchBarStatus() }
    private var hostCommand: ((EditorTouchBarCommand) -> Void)? { controller?.onTouchBarCommand }

    /// Applies the host state to every live control (and shows/hides Issues in the default arrangement).
    func refresh() {
        let status = self.status
        let hasHost = hostCommand != nil
        for button in compileButtons.allObjects { configureCompile(button, status: status, hasHost: hasHost) }
        for button in issueButtons.allObjects { configureIssues(button, status: status, hasHost: hasHost) }
        let canShowInPDF = controller?.onShowInPDF != nil
        for button in showInPDFButtons.allObjects { button.isEnabled = canShowInPDF }
        for button in previewButtons.allObjects {
            button.isEnabled = hasHost && status.isPreviewVisible != nil
            button.state = status.isPreviewVisible == true ? .on : .off
        }
        for button in previewWindowButtons.allObjects { configurePreviewWindow(button, status: status, hasHost: hasHost) }
        if let bar {
            let identifiers = EditorTouchBar.defaultItemIdentifiers(for: status)
            if bar.defaultItemIdentifiers != identifiers { bar.defaultItemIdentifiers = identifiers }
        }
    }

    private func send(_ command: EditorTouchBarCommand) {
        hostCommand?(command)
    }

    // MARK: NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Item.compile: return makeCompileItem()
        case Item.showInPDF: return makeShowInPDFItem()
        case Item.issues: return makeIssuesItem()
        case Item.togglePreview: return makePreviewItem()
        case Item.previewWindow: return makePreviewWindowItem()
        case Item.inlineMath:
            return buttonItem(identifier, label: String(localized: "Inline Math"), priority: .normal,
                              button: TouchBarButton.text("$x$", label: String(localized: "Inline Math")) { [weak self] in
                                  self?.perform(.inlineMath)
                              }.width(48, minimumOnly: true))
        case Item.displayMath: return makeDisplayMathItem()
        case Item.fraction:
            return buttonItem(identifier, label: String(localized: "Fraction"), priority: .normal,
                              button: TouchBarButton.text("x⁄y", label: String(localized: "Fraction")) { [weak self] in
                                  self?.perform(.fraction)
                              }.width(44, minimumOnly: true))
        case Item.superscript:
            return buttonItem(identifier, label: String(localized: "Superscript"), priority: .low,
                              button: TouchBarButton.symbol("textformat.superscript", fallbackTitle: "x²",
                                                            label: String(localized: "Superscript")) { [weak self] in
                                  self?.perform(.superscript)
                              }.width(40))
        case Item.subscript:
            return buttonItem(identifier, label: String(localized: "Subscript"), priority: .low,
                              button: TouchBarButton.symbol("textformat.subscript", fallbackTitle: "x₂",
                                                            label: String(localized: "Subscript")) { [weak self] in
                                  self?.perform(.subscript)
                              }.width(40))
        case Item.greekLetters:
            return makeSymbolPopover(identifier, label: String(localized: "Greek Letters"), collapsed: "αβγ",
                                     scrubber: Item.greekScrubber)
        case Item.mathSymbols:
            return makeSymbolPopover(identifier, label: String(localized: "Math Symbols"), collapsed: "∑",
                                     scrubber: Item.symbolScrubber)
        case Item.environments: return makeEnvironmentsItem()
        case Item.sections: return makeSectionsItem()
        case Item.textStyle: return makeTextStyleItem()
        case Item.comment:
            return buttonItem(identifier, label: String(localized: "Toggle Comment"), priority: .low,
                              button: TouchBarButton.symbol("percent", fallbackTitle: "%",
                                                            label: String(localized: "Toggle Comment")) { [weak self] in
                                  self?.perform(.toggleComment)
                              }.width(40))
        case Item.greekScrubber:
            return makeScrubberItem(identifier, symbols: EditorTouchBar.greekLetters, popover: Item.greekLetters)
        case Item.symbolScrubber:
            return makeScrubberItem(identifier, symbols: EditorTouchBar.mathSymbols, popover: Item.mathSymbols)
        case Item.environmentScrubber:
            return makeEnvironmentScrubberItem(identifier)
        case .candidateList:
            // NSTextView builds its own candidate list (typing suggestions / input methods).
            if let textView { return textView.touchBar(touchBar, makeItemForIdentifier: identifier) }
            return nil
        default:
            if let kind = LaTeXMarkupAction.DisplayMath.allCases.first(where: { Item.displayMathOption($0) == identifier }) {
                return optionItem(identifier, title: kind.label, action: .displayMath(kind), popover: Item.displayMath)
            }
            if let name = EditorTouchBar.sections.first(where: { Item.sectionOption($0) == identifier }) {
                return optionItem(identifier, title: "\\" + name, action: .section(name), popover: Item.sections)
            }
            return nil
        }
    }

    // MARK: Markup

    private func perform(_ action: LaTeXMarkupAction) {
        textView?.performMarkup(action)
    }

    // MARK: App-level items

    private func makeCompileItem() -> NSTouchBarItem {
        let button = TouchBarButton.symbol("play.fill", fallbackTitle: String(localized: "Compile"),
                                           label: String(localized: "Compile")) { [weak self] in
            guard let self else { return }
            self.send(self.status.compile == .running ? .stopCompile : .compile)
        }.width(56)
        compileButtons.add(button)
        configureCompile(button, status: status, hasHost: hostCommand != nil)
        return buttonItem(Item.compile, label: String(localized: "Compile"), priority: .high, button: button)
    }

    private func configureCompile(_ button: NSButton, status: EditorTouchBarStatus, hasHost: Bool) {
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

    private func makeShowInPDFItem() -> NSTouchBarItem {
        let button = TouchBarButton.symbol("doc.text.magnifyingglass", fallbackTitle: String(localized: "Show in PDF"),
                                           label: String(localized: "Show in PDF")) { [weak self] in
            self?.showInPDF()
        }.width(40)
        button.isEnabled = controller?.onShowInPDF != nil
        showInPDFButtons.add(button)
        return buttonItem(Item.showInPDF, label: String(localized: "Show in PDF"), priority: .normal, button: button)
    }

    /// Same as the editor's "Show in PDF": the caret position and the word there.
    private func showInPDF() {
        guard let textView, let storage = textView.textStorage, let controller = textView.controller,
              let handler = controller.onShowInPDF, textView.buffer != nil else { return }
        let caret = min(textView.selectedRange().location, storage.length)
        let lines = textView.lineTable
        let line = lines.lineIndex(containing: caret)
        let column = caret - lines.startOfLine(line) + 1
        handler(SourcePosition(line: line + 1, column: column), controller.word(at: caret)?.word)
    }

    private func makeIssuesItem() -> NSTouchBarItem {
        let button = TouchBarButton.text("", label: String(localized: "Next Issue")) { [weak self] in
            self?.send(.nextIssue)
        }.width(56, minimumOnly: true)
        issueButtons.add(button)
        configureIssues(button, status: status, hasHost: hostCommand != nil)
        return buttonItem(Item.issues, label: String(localized: "Next Issue"), priority: .high, button: button)
    }

    private func configureIssues(_ button: NSButton, status: EditorTouchBarStatus, hasHost: Bool) {
        let errors = max(0, status.errorCount)
        let warnings = max(0, status.warningCount)
        let (symbol, tint, count): (String, NSColor?, Int) =
            errors > 0 ? ("xmark.octagon.fill", .systemRed, errors)
            : warnings > 0 ? ("exclamationmark.triangle.fill", .systemOrange, warnings)
            : ("checkmark.circle", nil, 0)
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let tint, let base = image {
            image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) ?? base
        }
        button.image = image
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.title = count > 0 ? count.formatted() : ""
        button.setAccessibilityLabel(count > 0 ? String(localized: "\(errors) errors, \(warnings) warnings")
                                               : String(localized: "No Issues"))
        button.isEnabled = hasHost && count > 0
    }

    private func makePreviewItem() -> NSTouchBarItem {
        let button = TouchBarButton.symbol("doc.richtext", fallbackTitle: "PDF",
                                           label: String(localized: "PDF Preview")) { [weak self] in
            self?.send(.togglePreview)
        }.width(40)
        button.setButtonType(.pushOnPushOff)
        previewButtons.add(button)
        button.isEnabled = hostCommand != nil && status.isPreviewVisible != nil
        button.state = status.isPreviewVisible == true ? .on : .off
        return buttonItem(Item.togglePreview, label: String(localized: "PDF Preview"), priority: .low, button: button)
    }

    private func makePreviewWindowItem() -> NSTouchBarItem {
        let button = TouchBarButton.symbol("arrow.up.forward.app", fallbackTitle: "PDF",
                                           label: String(localized: "Open PDF in Separate Window")) { [weak self] in
            self?.send(.togglePreviewWindow)
        }.width(40)
        previewWindowButtons.add(button)
        configurePreviewWindow(button, status: status, hasHost: hostCommand != nil)
        return buttonItem(Item.previewWindow, label: String(localized: "PDF Window"), priority: .low, button: button)
    }

    private func configurePreviewWindow(_ button: NSButton, status: EditorTouchBarStatus, hasHost: Bool) {
        let detached = status.isPreviewDetached == true
        let label = detached ? String(localized: "Attach PDF to Project Window")
                             : String(localized: "Open PDF in Separate Window")
        let symbol = detached ? "arrow.down.right.and.arrow.up.left" : "arrow.up.forward.app"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.setAccessibilityLabel(label)
        button.isEnabled = hasHost && status.isPreviewDetached != nil
    }

    // MARK: Popovers

    private func makeDisplayMathItem() -> NSTouchBarItem {
        let options = LaTeXMarkupAction.DisplayMath.allCases.map { Item.displayMathOption($0) }
        return popoverItem(Item.displayMath, label: String(localized: "Display Math"), collapsed: "\\[ \\]",
                           width: 48, priority: .normal, content: options)
    }

    private func makeSectionsItem() -> NSTouchBarItem {
        let options = EditorTouchBar.sections.map { Item.sectionOption($0) }
        return popoverItem(Item.sections, label: String(localized: "Sections"), collapsed: "§",
                           width: 40, priority: .low, content: options)
    }

    private func makeEnvironmentsItem() -> NSTouchBarItem {
        popoverItem(Item.environments, label: String(localized: "Environments"), collapsed: "\\begin",
                    width: 60, priority: .normal, content: [Item.environmentScrubber])
    }

    private func makeSymbolPopover(_ identifier: NSTouchBarItem.Identifier, label: String, collapsed: String,
                                   scrubber: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        popoverItem(identifier, label: label, collapsed: collapsed, width: 44, priority: .normal, content: [scrubber])
    }

    /// A popover whose collapsed button has a fixed width; its content bar is built by this delegate.
    private func popoverItem(_ identifier: NSTouchBarItem.Identifier, label: String, collapsed: String,
                             width: CGFloat, priority: NSTouchBarItem.Priority,
                             content: [NSTouchBarItem.Identifier]) -> NSPopoverTouchBarItem {
        let item = NSPopoverTouchBarItem(identifier: identifier)
        item.customizationLabel = label
        item.visibilityPriority = priority
        item.showsCloseButton = true
        let button = TouchBarButton.text(collapsed, label: label) { [weak item] in
            item?.showPopover(nil)
        }.width(width, minimumOnly: true)
        item.collapsedRepresentation = button
        let contentBar = NSTouchBar()
        contentBar.delegate = self
        contentBar.defaultItemIdentifiers = content
        item.popoverTouchBar = contentBar
        popovers[identifier] = item
        return item
    }

    private func dismissPopover(_ identifier: NSTouchBarItem.Identifier) {
        popovers[identifier]?.dismissPopover(nil)
    }

    private func optionItem(_ identifier: NSTouchBarItem.Identifier, title: String, action: LaTeXMarkupAction,
                            popover: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let button = TouchBarButton.text(title, label: title) { [weak self] in
            self?.perform(action)
            self?.dismissPopover(popover)
        }
        return buttonItem(identifier, label: title, priority: .normal, button: button)
    }

    private func makeScrubberItem(_ identifier: NSTouchBarItem.Identifier, symbols: [EditorTouchBar.Symbol],
                                  popover: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let source = TouchBarScrubberSource(titles: symbols.map(\.glyph), accessibilityLabels: symbols.map(\.command),
                                            itemWidth: 36) { [weak self] index in
            guard symbols.indices.contains(index) else { return }
            self?.perform(.mathCommand(symbols[index].command))
            self?.dismissPopover(popover)
        }
        scrubberSources.append(source)
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = source.makeScrubber(width: 560)
        item.customizationLabel = popover == Item.greekLetters ? String(localized: "Greek Letters")
                                                               : String(localized: "Math Symbols")
        return item
    }

    private func makeEnvironmentScrubberItem(_ identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let names = EditorTouchBar.environments
        let source = TouchBarScrubberSource(titles: names, itemWidth: nil) { [weak self] index in
            guard names.indices.contains(index) else { return }
            self?.perform(.environment(names[index]))
            self?.dismissPopover(Item.environments)
        }
        scrubberSources.append(source)
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = source.makeScrubber(width: 560)
        item.customizationLabel = String(localized: "Environments")
        return item
    }

    // MARK: Text style

    private func makeTextStyleItem() -> NSTouchBarItem {
        let styles = LaTeXMarkupAction.TextStyle.allCases
        let control = NSSegmentedControl(labels: styles.map { _ in "" }, trackingMode: .momentary,
                                         target: self, action: #selector(textStyleTapped(_:)))
        for (index, style) in styles.enumerated() {
            let symbol: String? = switch style {
            case .bold: "bold"
            case .italic: "italic"
            case .emphasis: nil
            }
            if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: style.localizedName) {
                control.setImage(image, forSegment: index)
            } else {
                control.setLabel(style == .emphasis ? "emph" : style.localizedName, forSegment: index)
            }
            control.setToolTip(style.localizedName, forSegment: index)
            control.setWidth(style == .emphasis ? 48 : 36, forSegment: index)
        }
        control.setAccessibilityLabel(String(localized: "Text Style"))
        let item = NSCustomTouchBarItem(identifier: Item.textStyle)
        item.view = control
        item.customizationLabel = String(localized: "Text Style")
        item.visibilityPriority = .low
        return item
    }

    @objc private func textStyleTapped(_ sender: NSSegmentedControl) {
        let styles = LaTeXMarkupAction.TextStyle.allCases
        guard styles.indices.contains(sender.selectedSegment) else { return }
        perform(.textStyle(styles[sender.selectedSegment]))
    }

    // MARK: Helpers

    private func buttonItem(_ identifier: NSTouchBarItem.Identifier, label: String, priority: NSTouchBarItem.Priority,
                            button: NSButton) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = button
        item.customizationLabel = label
        item.visibilityPriority = priority
        return item
    }
}
