import AppKit
import PDFKit

/// The sync gestures of the preview: a click in the PDF that asks the app to show the matching place in the source.
///
/// - `PDFSyncTrigger.doubleClick`: PDFKit handles the double-click as it always does (it selects the word under the
///   pointer, so the user sees what was picked) and the click is reported right after.
/// - `PDFSyncTrigger.commandClick`: the ⌘-click is reported and kept from PDFKit (no selection starts).
/// - Clients that only use the legacy `onInverseSearch` keep getting ⌘-clicks, whatever the trigger says.
///
/// Single clicks, drags and links are never touched.
extension GabePDFView {
    enum SyncGesture {
        case commandClick
        case doubleClick
    }

    /// Which sync gesture `event` is for the controller's current configuration, or `nil` for an ordinary event.
    func syncGesture(for event: NSEvent) -> SyncGesture? {
        guard event.type == .leftMouseDown, document != nil, let controller else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.control), !flags.contains(.option) else { return nil }
        let wantsSyncClick = controller.onSyncClick != nil
        guard wantsSyncClick || controller.onInverseSearch != nil else { return nil }

        if flags.contains(.command) {
            return controller.syncTrigger == .commandClick || !wantsSyncClick ? .commandClick : nil
        }
        if wantsSyncClick, controller.syncTrigger == .doubleClick, event.clickCount == 2 {
            return .doubleClick
        }
        return nil
    }

    /// `true` when the pointer is still (within a few points) where `event` put it.
    func pointerStayedNear(_ event: NSEvent) -> Bool {
        guard let window else { return true }
        let now = pointerLocation(window)
        return hypot(now.x - event.locationInWindow.x, now.y - event.locationInWindow.y) <= 6
    }

    /// Describes the PDF content at `event`'s location and hands it to `onSyncClick`. Nothing happens when the
    /// pointer is not on a page.
    func reportSyncClick(for event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let document, let page = page(for: location, nearest: false) else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        onSyncClick?(PDFTextLocator.syncClick(on: page, pageIndex: index, at: convert(location, to: page)))
    }
}
