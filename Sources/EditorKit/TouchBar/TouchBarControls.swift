import AppKit

/// Small building blocks shared by the Touch Bar providers of the editor.

/// A Touch Bar button that runs a closure (its target is itself).
final class TouchBarButton: NSButton {
    var onPress: (() -> Void)?

    /// A button showing an SF Symbol (template, tinted by the Touch Bar), or `fallbackTitle` when the symbol is
    /// missing on this system.
    static func symbol(_ name: String, fallbackTitle: String, label: String, onPress: @escaping () -> Void) -> TouchBarButton {
        let button = TouchBarButton.plain(label: label, onPress: onPress)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: label) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallbackTitle
        }
        return button
    }

    /// A button with a short text (LaTeX notation such as `$x$`, or a localized word).
    static func text(_ title: String, label: String, onPress: @escaping () -> Void) -> TouchBarButton {
        let button = TouchBarButton.plain(label: label, onPress: onPress)
        button.title = title
        return button
    }

    private static func plain(label: String, onPress: @escaping () -> Void) -> TouchBarButton {
        let button = TouchBarButton(frame: .zero)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .push
        button.isBordered = true
        button.title = ""
        button.target = button
        button.action = #selector(press(_:))
        button.onPress = onPress
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func press(_ sender: Any?) {
        onPress?()
    }

    /// Fixes the width (Touch Bar items are laid out from their intrinsic size).
    @discardableResult
    func width(_ width: CGFloat, minimumOnly: Bool = false) -> TouchBarButton {
        let constraint = minimumOnly ? widthAnchor.constraint(greaterThanOrEqualToConstant: width)
                                     : widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        return self
    }
}

/// Feeds an `NSScrubber` with short text items and reports taps.
///
/// A tap selects nothing permanently: the selection is cleared right away so the same item can be tapped
/// again (two `\alpha` in a row).
final class TouchBarScrubberSource: NSObject, NSScrubberDataSource, NSScrubberDelegate, NSScrubberFlowLayoutDelegate {
    static let itemIdentifier = NSUserInterfaceItemIdentifier("io.github.gabe-rbo.GabeTeX.touchBar.text")

    let titles: [String]
    /// Accessibility labels per item (nil: the title is read).
    let accessibilityLabels: [String?]
    /// Fixed item width (glyphs); nil sizes each item to its text (words).
    let itemWidth: CGFloat?
    var onSelect: ((Int) -> Void)?

    init(titles: [String], accessibilityLabels: [String?] = [], itemWidth: CGFloat?, onSelect: @escaping (Int) -> Void) {
        self.titles = titles
        self.accessibilityLabels = accessibilityLabels
        self.itemWidth = itemWidth
        self.onSelect = onSelect
        super.init()
    }

    /// A configured scrubber (free scrolling, rounded selection, tap to pick) of the given width.
    func makeScrubber(width: CGFloat) -> NSScrubber {
        let scrubber = NSScrubber(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        scrubber.register(NSScrubberTextItemView.self, forItemIdentifier: Self.itemIdentifier)
        let layout = NSScrubberFlowLayout()
        layout.itemSpacing = 4
        if let itemWidth { layout.itemSize = NSSize(width: itemWidth, height: 30) }
        scrubber.scrubberLayout = layout
        scrubber.mode = .free
        scrubber.selectionBackgroundStyle = .roundedBackground
        scrubber.isContinuous = false
        scrubber.showsArrowButtons = false
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.widthAnchor.constraint(equalToConstant: width).isActive = true
        return scrubber
    }

    func numberOfItems(for scrubber: NSScrubber) -> Int {
        titles.count
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = (scrubber.makeItem(withIdentifier: Self.itemIdentifier, owner: nil) as? NSScrubberTextItemView)
            ?? NSScrubberTextItemView()
        view.title = titles.indices.contains(index) ? titles[index] : ""
        if accessibilityLabels.indices.contains(index), let label = accessibilityLabels[index] {
            view.setAccessibilityLabel(label)
        }
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        guard titles.indices.contains(selectedIndex) else { return }
        scrubber.selectedIndex = -1
        onSelect?(selectedIndex)
    }

    func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt itemIndex: Int) -> NSSize {
        if let itemWidth { return NSSize(width: itemWidth, height: 30) }
        let title = titles.indices.contains(itemIndex) ? titles[itemIndex] : ""
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15)]).width
        return NSSize(width: ceil(width) + 28, height: 30)
    }
}
