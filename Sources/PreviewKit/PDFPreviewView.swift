import AppKit
import PDFKit
import SwiftUI

/// SwiftUI wrapper of the preview `PDFView` (a `GabePDFView`).
///
/// The view fills the space it is given; place `PDFPreviewControls` over it (see `PDFPreviewPane`).
/// Destroying and re-creating the view (e.g. toggling the preview off and on) keeps the PDF, the zoom and the
/// reading position: they live in the `PDFPreviewController`.
///
/// The same controller can be hosted in a view of another window (detaching the preview into its own window and
/// docking it again): the newest view takes over the document, the reading position and the callbacks, and the old
/// view is retired – it ignores later updates and its dismantling does not touch the controller. Both views may be
/// alive for a moment during the move.
public struct PDFPreviewView: NSViewRepresentable {
    public var controller: PDFPreviewController

    public init(controller: PDFPreviewController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> GabePDFView {
        let view = GabePDFView(frame: .zero)
        controller.attach(view)
        return view
    }

    public func updateNSView(_ view: GabePDFView, context: Context) {
        // Does nothing for the view that is current already, and for a retired one (a newer view took over); it
        // re-attaches this view only when SwiftUI hands it another controller.
        controller.attach(view)
    }

    public static func dismantleNSView(_ view: GabePDFView, coordinator: ()) {
        view.isRetired = true
        view.controller?.detach(view)
    }
}

/// The complete preview pane: the PDF, the floating glass controls while a PDF is shown, and the empty-state
/// placeholder before the first successful build.
///
/// Drop it in as the right-hand side of the editor split view.
public struct PDFPreviewPane: View {
    public var controller: PDFPreviewController
    /// Shown instead of the default hint while there is no PDF, e.g. "The last build failed." Pass `nil` for the
    /// default "Press ⌘B to compile".
    public var placeholderMessage: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(controller: PDFPreviewController, placeholderMessage: String? = nil) {
        self.controller = controller
        self.placeholderMessage = placeholderMessage
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Always present, so the controller keeps a view to load into; the placeholder covers it.
            PDFPreviewView(controller: controller)

            if controller.hasDocument {
                PDFPreviewControls(controller: controller)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            } else {
                PDFPreviewPlaceholder(message: placeholderMessage)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: controller.hasDocument)
    }
}
