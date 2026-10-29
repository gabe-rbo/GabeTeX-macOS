# Changelog

All notable changes to GabeTeX are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-10-29

The first public release.

### Added

**Projects and navigation**

- Native SwiftUI + AppKit app with the macOS 26 Liquid Glass look, Light and Dark mode and an SF Mono editor.
- **Projects, not files**: open any folder or create a project from a template; file tree sidebar, tabs, Quick Open
  (⌘P), ⌘-click on `\input{…}` / `\include{…}` to open the file and on `\ref{…}` to jump to its `\label`, and a
  document outline that spans all included files. Made for one-file-per-section writing, with `% !TEX root` and
  `% !TEX program` magic comments and automatic root detection.
- **Project labels** on the Welcome window. Give recent projects color labels (red, orange, yellow, green, blue,
  purple, gray), filter the list with chips, and search it when it grows. Labeled projects never fall off the
  recents list. Create, rename, recolor and delete labels from the chip menu, assign them from a project's context
  menu or from **File › Project Labels**. Labels are stored in the app and never touch your project folders or
  Finder tags.
- Respects file encodings (UTF-8 and Latin-1 detection with an encoding indicator), saves atomically while
  preserving file metadata, and detects external changes.

**Compiling and checking**

- **Adapts to the installed TeX**: detects MacTeX, TeX Live, BasicTeX and TinyTeX; compiles with `latexmk`
  (pdfLaTeX, XeLaTeX, LuaLaTeX) **in the background while you type**, including unsaved text, in a private shadow
  copy of the project so your files are never touched until you save.
- Errors and warnings from the TeX log and from ChkTeX underlined at the right line of the right file (also inside
  section files), an Issues panel, and an offer to install missing packages with `tlmgr` (asking for the
  administrator password when needed).
- **Live reference and citation warnings.** While you type, GabeTeX underlines a `\ref`-style reference to a label
  that does not exist, a label defined more than once (at every definition, naming the others), and a `\cite`-style
  key that is missing from the bibliography. It understands `\ref`, `\eqref`, `\autoref`, `\cref` and friends,
  `\cite`, `\citep`, `\textcite`, `\parencite` and friends, comma lists, and labels and bibliography entries spread
  over many files. Projects that use `xr` / `xr-hyper` skip the reference checks, and citation checks stay quiet
  until the project has a bibliography.
- ⌘B saves and exports the PDF next to `main.tex`; ⇧⌘K cleans auxiliary files.

**PDF preview and sync**

- Integrated PDF preview (PDFKit) with SyncTeX that keeps your page and zoom across reloads. The editor and the
  PDF open side by side in a balanced split, and the divider position is remembered per project.
- **Precise two-way sync with a brief highlight.**
  - *PDF → source:* double-click a word in the PDF (or ⌘-click, chosen in **Settings › General**) to jump to that
    exact word in the source, even inside section files. Accents (`\'e`, `{\c c}`), ligatures and hyphenated words
    are understood. The target is briefly highlighted and the editor takes focus.
  - *Source → PDF:* ⌘-click ordinary text in the editor, use **Show in PDF** from the context menu, or press ⇧⌘J
    (**Build › Show in PDF**) to jump to that exact word in the PDF, which is briefly highlighted.
  - Optional **Follow cursor in PDF** setting (off by default) keeps the PDF in step as the caret rests.
- **Detachable PDF preview.** **View › Open PDF in Separate Window** (also a toolbar toggle and a button on the
  docked preview) moves the preview into its own window, ready for a second display or full screen. **Attach PDF
  to Project Window** (or simply closing the window) docks it again. The window remembers its position per
  project, and live reloads, sync highlights and the build shortcuts keep working while it is detached.
- **Presentation mode for Beamer.** Press ⌥⌘↩ (**Start Presentation**), or the **Present** button that appears in
  the toolbar for Beamer documents, to present the compiled PDF.
  - With two displays, the audience sees the slides full screen on the external display (cursor hidden when idle)
    while you get a presenter view on the main display: the current slide, the next slide, a slide counter, an
    elapsed timer with pause and reset, the clock, and your notes.
  - With one display, the audience view is full screen and **P** switches the presenter view on and off.
  - Beamer notes on the second screen (`\setbeameroption{show notes on second screen=right}`, or `left`) are split
    automatically: slides to the audience, notes to the presenter. You can also choose the notes side in Settings.
  - Navigate with the arrow keys, Space, Return, Page Up / Down, Home / End, a slide number followed by Return, or a
    click. **B** / **.** blanks the screen to black, **W** / **,** to white, and Esc ends the presentation. Live
    reloads keep your current slide.

**Writing**

- Autocomplete for commands, environments, `\ref` / `\cite` keys, files and packages, with snippets. **Tab
  completes** (on by default): after a partial command (`\sec` → `\section{…}`) or inside `\ref{…}` / `\cite{…}` /
  `\begin{…}`, Tab inserts the first suggestion, however fast you type, and opens the list when none is showing
  yet. Elsewhere Tab keeps indenting and moving between snippet fields. ⌃Space always works, and you can choose
  whether Tab, Return or both accept a suggestion.
- **Word and page count.** The status bar shows the document's words and pages (for example “1 234 words · 12
  pages”, or “86 of 1 234 words” while you have a selection). Click it for **Document Statistics**: a table with the
  words and pages of every section, plus totals. The outline sidebar shows each section's word count. Counting follows `texcount`'s defaults: commands, comments, math and the preamble are not
  words, while the text of `\section`, `\emph`, captions and footnotes is.
- **Command palette and editable shortcuts.** ⇧⌘P opens a Spotlight-like palette with fuzzy search over every
  command, listed with its shortcut and the most recently used first. **Settings › Shortcuts** lets you record your
  own shortcut for any command, warns about conflicts, refuses system-reserved combinations, and restores the
  defaults at any time.
- Optional **Vim mode**: normal, insert, visual and visual-line modes, operators and text objects (including `i$` /
  `a$` for math and `ie` / `ae` for environments), `:w :wa :q :make`, search and substitute; aware of dead keys on
  ABNT2 and US-International layouts.

**Touch Bar**

- **Touch Bar support** on Macs that have a Touch Bar: compile and stop, Show in PDF, shortcuts for math and for
  sections and environments, scrubbers for Greek letters and math symbols, and page and zoom controls when the PDF
  has focus. Customize it with **View › Customize Touch Bar…**.

**Languages**

- User interface in English and Brazilian Portuguese, following the system language.

[Unreleased]: https://github.com/gabe-rbo/GabeTeX/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/gabe-rbo/GabeTeX/releases/tag/v1.0.0
