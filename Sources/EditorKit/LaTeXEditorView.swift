import AppKit
import SwiftUI
import TeXCore

/// SwiftUI wrapper of the LaTeX text editor.
///
/// The view shows `buffer` (swapping NSTextStorage when the buffer changes, restoring its selection and
/// scroll position), renders `diagnostics` that belong to `buffer.url` (squiggles + gutter markers +
/// hover tooltips), and offers completion using `symbols`.
public struct LaTeXEditorView: NSViewRepresentable {
    public var buffer: SourceBuffer
    public var controller: EditorController
    public var configuration: EditorConfiguration
    public var diagnostics: [Diagnostic]
    public var symbols: ProjectSymbols
    /// Called after every edit (after `buffer.noteEdit()`), on the main actor.
    public var onTextChange: (SourceBuffer) -> Void

    public init(
        buffer: SourceBuffer,
        controller: EditorController,
        configuration: EditorConfiguration,
        diagnostics: [Diagnostic],
        symbols: ProjectSymbols,
        onTextChange: @escaping (SourceBuffer) -> Void
    ) {
        self.buffer = buffer
        self.controller = controller
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.symbols = symbols
        self.onTextChange = onTextChange
    }

    /// The diagnostics of `diagnostics` that belong to `url` (standardized path comparison).
    public static func diagnostics(_ diagnostics: [Diagnostic], for url: URL) -> [Diagnostic] {
        let path = url.standardizedFileURL.path
        return diagnostics.filter { $0.fileURL?.standardizedFileURL.path == path }
    }

    /// Per-view state of the representable. (Its `NSTextViewDelegate` methods are kept for source
    /// compatibility with the original contract; `LaTeXTextView` reports edits and owns undo itself.)
    public final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: LaTeXTextView?
        var observers: [NSObjectProtocol] = []

        override init() {
            super.init()
        }

        func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        /// No-op: every edit is already reported once by the text view (`noteEdit` + `onTextChange`).
        public func textDidChange(_ notification: Notification) {}

        /// The undo manager of the buffer currently shown.
        public func undoManager(for view: NSTextView) -> UndoManager? {
            textView?.buffer?.undoManager
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = LaTeXEditorScrollView(configuration: configuration)
        let textView = scroll.editor
        context.coordinator.textView = textView
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak textView] _ in
            MainActor.assumeIsolated {
                textView?.enclosingScrollViewDidScroll()
            }
        }
        context.coordinator.observers.append(observer)
        update(textView)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        update(textView)
    }

    private func update(_ textView: LaTeXTextView) {
        controller.bind(to: textView)
        textView.onTextChange = onTextChange
        textView.symbols = symbols
        textView.apply(configuration)
        let mine = Self.diagnostics(diagnostics, for: buffer.url)
        if textView.buffer !== buffer {
            textView.attach(buffer, diagnostics: mine)
        } else {
            textView.setDiagnostics(mine)
        }
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.removeObservers()
        coordinator.textView?.detachCurrentBuffer()
    }
}

/// The scroll view hosting a `LaTeXTextView` with its gutter. Usable directly from AppKit.
public final class LaTeXEditorScrollView: NSScrollView {
    /// The editor inside.
    public let editor: LaTeXTextView
    private(set) var gutter: EditorGutterView?

    public init(configuration: EditorConfiguration = EditorConfiguration(),
                tokenizer: @escaping LaTeXTokenizing = LaTeXTextView.defaultTokenizer,
                completionProvider: @escaping CompletionProviding = LaTeXTextView.defaultCompletionProvider) {
        editor = LaTeXTextView(configuration: configuration, tokenizer: tokenizer, completionProvider: completionProvider)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = !configuration.wrapLines
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        scrollerStyle = .overlay
        contentView.postsBoundsChangedNotifications = true
        editor.frame = NSRect(origin: .zero, size: contentSize)
        documentView = editor
        let gutter = EditorGutterView(scrollView: self, editor: editor)
        self.gutter = gutter
        verticalRulerView = gutter
        hasVerticalRuler = true
        rulersVisible = true
        editor.gutter = gutter
        editor.applyLayoutAfterEmbedding()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not decodable")
    }

    /// On macOS 26+ an NSScrollView with a (floating) vertical ruler reports no accessibility children,
    /// which hid the text (AXTextArea) from VoiceOver and automation. Expose the editor explicitly.
    public override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if !children.contains(where: { ($0 as AnyObject) === editor }) {
            children.insert(editor, at: 0)
        }
        return children
    }
}

extension LaTeXTextView {
    /// Scrolling: keep the gutter and the completion popup in sync, close hover popovers.
    func enclosingScrollViewDidScroll() {
        gutter?.needsDisplay = true
        completion.reposition()
        hover.dismiss()
    }
}
