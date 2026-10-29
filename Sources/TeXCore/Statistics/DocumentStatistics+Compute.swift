import Foundation

extension DocumentStatistics {
    /// Counts the words and formulas of the project rooted at `rootFile`, per outline section.
    ///
    /// The walk follows `\input`, `\include`, `\subfile`, `\import` and `\subimport` at the position of the
    /// command, depth-first and without repeating a file, exactly like the outline (`ProjectIndex`), so every
    /// outline heading has a `SectionStatistics` with the same `id`. Everything lives in the closures: pass the
    /// text of unsaved buffers from `read`.
    ///
    /// ## Counting rules (close to `texcount`'s defaults)
    ///
    /// **What counts as a word.** A run of letters and digits. Accented letters (typed as UTF-8 or as LaTeX
    /// accents: `ação`, `Poincar\'e`, `\c{c}\~ao`, `Stra\ss e`, `Sch"on`), hyphenated words (`state-of-the-art`,
    /// `guarda-chuva`, also `hy\-phen`), contractions (`don't`, `d’água`), numbers (`1990`, `3.14`, `1,5`) and
    /// mixed forms (`COVID-19`, `2nd`) are one word each. `--` and `---` separate (`10--20` is two numbers),
    /// as do `~`, commands and all punctuation. Han and kana count one word per character.
    ///
    /// **Counted:** running text, list items, captions (`\caption`, `\captionof`, `\subcaption`, `\subfloat[…]`),
    /// footnotes, theorem titles, the text arguments of formatting commands (`\emph \textbf \textit \underline
    /// \footnote \item[…] …`), the titles of `\part … \subparagraph` and beamer frames (as *heading* words,
    /// counted apart from the text).
    ///
    /// **Not counted:** the preamble (everything before `\begin{document}`; a document without one counts
    /// entirely) and anything after `\end{document}`; comments; verbatim, listings and `\verb`; formulas
    /// (`$…$`, `\(…\)`, `\[…\]`, `$$…$$`, `equation`, `align`, `gather`, … — text inside `\text{}` in a formula
    /// included — which are counted as formulas instead); commands and their non-text arguments (`\label`,
    /// `\ref`, `\cite`, `\input`, `\includegraphics`, `\usepackage`, lengths, colors, `[options]`, `<overlays>`,
    /// column specifications, `\newcommand` definitions …); `tikzpicture` & co. and the bibliography
    /// (`thebibliography`); URLs. As in `texcount`, the contents of tables (`tabular`, `tabularx`, `longtable` & co.),
    /// `tabbing` and `titlepage` are layout, not prose, and so is everything inside a float (`figure`, `table`,
    /// `wrapfigure` …) except its captions; formulas and footnotes inside a float are left out with it.
    ///
    /// **Sections.** Front matter holds what precedes the first heading. A section's `own` counts run from
    /// its heading to the next heading of any level; `subtree` adds its sub-sections. The counts of all
    /// sections add up to `totals`. A file that is included twice is counted once, where it first appears.
    ///
    /// A subfile (an included file with its own `\documentclass` and `\begin{document}`) counts only what
    /// lies between its `\begin{document}` and `\end{document}`.
    public static func compute(rootFile: URL, read: (URL) -> String?, fileExists: (URL) -> Bool) -> DocumentStatistics {
        withoutActuallyEscaping(read) { read in
            withoutActuallyEscaping(fileExists) { fileExists in
                StatisticsEngine(root: rootFile.standardizedFileURL, read: read, fileExists: fileExists).run()
            }
        }
    }

    /// The counts of a loose piece of LaTeX (a selection): no sections, no includes, nothing is a preamble.
    /// Cheap enough to run on every selection change.
    public static func counts(in text: String) -> StatisticsCounts {
        let placeholder = URL(fileURLWithPath: "/selection.tex")
        let engine = StatisticsEngine(root: placeholder, read: { _ in text }, fileExists: { _ in false }, isFragment: true)
        return engine.run().totals
    }
}
