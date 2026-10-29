import SwiftUI
import TeXCore
import PreviewKit

/// The “Document Statistics” popover of the status bar: totals, a per-section table (words and pages) and the
/// counting rule in a footnote.
struct StatisticsPopover: View {
    let workspace: ProjectWorkspace

    private static let wordsColumn: CGFloat = 72
    private static let pagesColumn: CGFloat = 64

    var body: some View {
        let model = workspace.statistics
        VStack(alignment: .leading, spacing: 14) {
            if let document = model.document {
                header(document)
                tiles(document, model)
                breakdown(document, model)
                table(document, model)
                footnote(model)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { workspace.scheduleStatisticsRefresh(immediately: true) }
    }

    // MARK: Header and totals

    private func header(_ document: DocumentStatistics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Document Statistics").font(.headline)
            Text(verbatim: document.rootFile.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tiles(_ document: DocumentStatistics, _ model: StatisticsModel) -> some View {
        let totals = document.totals
        let pages = totalPages(model)
        return HStack(spacing: 10) {
            StatisticsTile(value: StatisticsText.number(totals.words), label: "Words")
            StatisticsTile(value: pages > 0 ? StatisticsText.number(pages) : "—", label: "Pages")
            StatisticsTile(value: StatisticsText.number(totals.inlineMath + totals.displayMath), label: "Formulas")
        }
    }

    private func breakdown(_ document: DocumentStatistics, _ model: StatisticsModel) -> some View {
        let totals = document.totals
        return VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    detailLabel("Text")
                    detailValue(totals.textWords)
                    detailLabel("Inline formulas")
                    detailValue(totals.inlineMath)
                }
                GridRow {
                    detailLabel("Headings")
                    detailValue(totals.headingWords)
                    detailLabel("Displayed formulas")
                    detailValue(totals.displayMath)
                }
            }
            if let selection = model.selection {
                HStack {
                    Text("Selection").foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: StatisticsText.words(selection.words)).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    private func detailLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func detailValue(_ value: Int) -> some View {
        Text(verbatim: StatisticsText.number(value))
            .font(.caption.monospacedDigit())
            .gridColumnAlignment(.trailing)
    }

    // MARK: Table

    private func table(_ document: DocumentStatistics, _ model: StatisticsModel) -> some View {
        let sections = document.sections
        let base = sections.map(\.level).min() ?? 0
        let showsFrontMatter = !document.frontMatter.own.isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Section").frame(maxWidth: .infinity, alignment: .leading)
                Text("Words").frame(width: Self.wordsColumn, alignment: .trailing)
                Text("Pages").frame(width: Self.pagesColumn, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if showsFrontMatter {
                        row(document.frontMatter, indent: 0, model)
                    }
                    ForEach(sections, id: \.stableKey) { section in
                        row(section, indent: max(0, section.level - base), model)
                    }
                    if !showsFrontMatter && sections.isEmpty {
                        Text("No sections yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: tableHeight(rows: sections.count + (showsFrontMatter ? 1 : 0)))
            Divider()
            HStack(spacing: 0) {
                Text("Total").frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: StatisticsText.number(document.totals.words))
                    .monospacedDigit()
                    .frame(width: Self.wordsColumn, alignment: .trailing)
                let pages = totalPages(model)
                Text(verbatim: pages > 0 ? StatisticsText.number(pages) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.pagesColumn, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }

    private func row(_ section: SectionStatistics, indent: Int, _ model: StatisticsModel) -> some View {
        let span = model.pageSpans[section.stableKey]
        return StatisticsSectionRow(
            section: section,
            indent: indent,
            span: span
        ) {
            model.isPopoverPresented = false
            workspace.open(section.fileURL, line: section.isFrontMatter ? nil : section.line)
        }
    }

    // MARK: Footnote

    private func footnote(_ model: StatisticsModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Words are counted the way texcount does: running text, headings, captions and footnotes. Commands, formulas, table contents, other text inside figures, comments, verbatim code and the preamble are left out, and a hyphenated word counts once. Each row includes its subsections.")
            if model.pageSpans.isEmpty {
                Text("Pages per section need a compiled PDF with SyncTeX data.")
            } else {
                Text("Pages come from SyncTeX after the last successful compile; ≈ marks a section that shares its page with the next one.")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The table takes the room its rows need, up to a limit, and scrolls beyond it.
    private func tableHeight(rows: Int) -> CGFloat {
        min(264, max(52, CGFloat(rows) * 25 + 8))
    }

    /// Pages of the PDF on screen (else of the one the sections were last looked up in).
    private func totalPages(_ model: StatisticsModel) -> Int {
        guard workspace.pdfURL != nil else { return 0 }
        return workspace.preview.pageCount
    }
}

/// A big number with a caption underneath.
private struct StatisticsTile: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// One line of the table: indented title, words, pages. A click goes to the heading in the editor.
private struct StatisticsSectionRow: View {
    let section: SectionStatistics
    let indent: Int
    let span: PageSpan?
    let onSelect: () -> Void

    @LocalState private var isHovering = false

    var body: some View {
        let words = section.isFrontMatter ? section.own.words : section.subtree.words
        let pages = span.map(StatisticsText.pageRange) ?? "—"
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: section.level <= 1 ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, CGFloat(indent) * 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: StatisticsText.number(words))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 72, alignment: .trailing)
                Text(verbatim: pages)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering ? Color.primary.opacity(0.07) : Color.clear, in: .rect(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: StatisticsText.words(words) + (span == nil ? "" : ", " + pages)))
    }

    private var title: String {
        if section.isFrontMatter { return String(localized: "Front matter") }
        return section.title.isEmpty ? String(localized: "Untitled") : section.title
    }
}
