import SwiftUI
import TeXCore
import PreviewKit

/// “1,234 words · 12 pages” in the status bar (“86 of 1,234 words” while text is selected). A click opens the
/// Document Statistics popover. Reads only the statistics model and the PDF's page count, so typing does not
/// re-render it between counts.
struct StatisticsCapsule: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        let model = workspace.statistics
        let shown = summary(model)
        Button {
            model.isPopoverPresented.toggle()
        } label: {
            Text(verbatim: shown)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .popover(isPresented: Binding(get: { model.isPopoverPresented }, set: { model.isPopoverPresented = $0 }),
                 arrowEdge: .top) {
            StatisticsPopover(workspace: workspace)
        }
        .help("Show document statistics")
        .accessibilityLabel("Document Statistics")
        .accessibilityValue(Text(verbatim: shown))
    }

    private func summary(_ model: StatisticsModel) -> String {
        guard let document = model.document else { return String(localized: "– words") }
        let total = document.totals.words
        if let selection = model.selection { return StatisticsText.wordsOfTotal(selection.words, total) }
        var text = StatisticsText.words(total)
        let pages = workspace.preview.pageCount
        if pages > 0, workspace.pdfURL != nil { text += " · " + StatisticsText.pages(pages) }
        return text
    }
}
