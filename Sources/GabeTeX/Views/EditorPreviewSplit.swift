import SwiftUI

/// Editor | PDF preview side by side with a draggable divider.
///
/// `HSplitView` ignores ideal widths (the editor opened at its minimum and the PDF took the rest, and a PDF
/// that was attached again came back at its minimum), so the split is laid out here from a stored *share*: the
/// fraction of the work area the editor takes. It opens balanced (`standardShare`), keeps the minimum widths of
/// both sides, and the divider position is remembered per project (and as the default for projects without
/// one) — it survives hiding, detaching and attaching the PDF because it lives in the workspace.
///
/// The editor stays at the same place in the view tree whether or not the PDF is shown, so toggling the
/// preview never rebuilds the text view. Double-click the divider to restore the balanced split.
struct EditorPreviewSplit: View {
    /// The editor's share of the work area on a fresh profile.
    static let standardShare = 0.55
    static let editorMinWidth: CGFloat = 320
    static let previewMinWidth: CGFloat = 260

    private static let dividerWidth: CGFloat = 1
    /// The draggable strip around the 1 pt divider line.
    private static let handleWidth: CGFloat = 8
    private static let space = "EditorPreviewSplit"
    private static let shareRange = 0.1...0.9

    @Environment(ProjectWorkspace.self) private var workspace
    @LocalState private var dragStartWidth: CGFloat? = nil

    private var showsPreview: Bool { workspace.showPreview && !workspace.isPreviewDetached }

    var body: some View {
        GeometryReader { proxy in
            let available = max(1, proxy.size.width - Self.dividerWidth)
            let editorWidth = showsPreview ? clampedEditorWidth(in: available) : proxy.size.width
            HStack(spacing: 0) {
                EditorArea()
                    .frame(width: editorWidth)
                if showsPreview {
                    divider(editorWidth: editorWidth, available: available)
                    PreviewPane()
                        .frame(width: max(0, available - editorWidth))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .coordinateSpace(name: Self.space)
        }
        .frame(minWidth: showsPreview ? Self.editorMinWidth + Self.dividerWidth + Self.previewMinWidth : Self.editorMinWidth)
    }

    // MARK: Layout

    /// The editor's width for the stored share, within the minimum widths of both sides.
    private func clampedEditorWidth(in available: CGFloat) -> CGFloat {
        let low = Self.editorMinWidth
        let high = max(low, available - Self.previewMinWidth)
        return min(max((available * workspace.editorShare).rounded(), low), high)
    }

    // MARK: Divider

    private func divider(editorWidth: CGFloat, available: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: Self.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: Self.handleWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(dragGesture(editorWidth: editorWidth, available: available))
                    .onTapGesture(count: 2) { setShare(Self.standardShare, persist: true) }
                    .accessibilityElement()
                    .accessibilityLabel("Editor and PDF divider")
                    .accessibilityValue(Text(workspace.editorShare, format: .percent.precision(.fractionLength(0))))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: setShare(workspace.editorShare + 0.05, persist: true)
                        case .decrement: setShare(workspace.editorShare - 0.05, persist: true)
                        @unknown default: break
                        }
                    }
            }
            .zIndex(1)      // above the neighbours, so the whole strip takes the drag
    }

    private func dragGesture(editorWidth: CGFloat, available: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = dragStartWidth ?? editorWidth
                dragStartWidth = start
                resize(to: start + value.translation.width, available: available, persist: false)
            }
            .onEnded { value in
                let start = dragStartWidth ?? editorWidth
                dragStartWidth = nil
                resize(to: start + value.translation.width, available: available, persist: true)
            }
    }

    private func resize(to width: CGFloat, available: CGFloat, persist: Bool) {
        let low = Self.editorMinWidth
        let high = max(low, available - Self.previewMinWidth)
        setShare(Double(min(max(width, low), high) / available), persist: persist)
    }

    private func setShare(_ share: Double, persist: Bool) {
        let value = min(max(share, Self.shareRange.lowerBound), Self.shareRange.upperBound)
        workspace.editorShare = value
        if persist { Self.remember(value, forProject: workspace.folderURL.path) }
    }
}

// MARK: - Persistence

extension EditorPreviewSplit {
    private static let lastShareKey = "editorPreviewShare"
    private static func projectKey(_ path: String) -> String { "project.\(path).editorShare" }

    /// The divider position of a project: its own, else the one the user chose last anywhere, else balanced.
    static func storedShare(forProject path: String, defaults: UserDefaults = .standard) -> Double {
        for key in [projectKey(path), lastShareKey] {
            if let value = defaults.object(forKey: key) as? Double, value.isFinite, shareRange.contains(value) {
                return value
            }
        }
        return standardShare
    }

    /// Remembers the divider position for the project and as the default for projects opened later.
    static func remember(_ share: Double, forProject path: String, defaults: UserDefaults = .standard) {
        defaults.set(share, forKey: projectKey(path))
        defaults.set(share, forKey: lastShareKey)
    }
}
