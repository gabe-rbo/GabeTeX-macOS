# GabeTeX — Architecture

GabeTeX is a native macOS 26+ LaTeX editor for people who write documents as `main.tex` plus one file per section.
It has three non-negotiables:

1. **Beautiful and native**: SwiftUI + AppKit, the macOS Liquid Glass design language, system controls.
2. **Projects, not files**: open a folder (or create a project from a template), see the file tree, switch between
   files instantly (sidebar, tabs, ⌘P Quick Open, ⌘-click on `\input{…}`), and get an outline across files.
3. **Adapts to the local TeX**: detect the distribution, compile with latexmk, **compile in the background while
   typing** and show errors inline, and offer to **install missing packages** (tlmgr with an administrator prompt).

Also part of the app: an integrated PDF preview with precise two-way SyncTeX navigation (word-level, with a brief
highlight at the destination) that can be detached into its own window; autocompletion (commands, environments,
`\ref` labels, `\cite` keys, files, packages); live reference and citation warnings; a document outline with word
and page counts; a Beamer presentation mode with a presenter view; a command palette with editable keyboard shortcuts;
an optional Vim mode; color labels for recent projects; Touch Bar support; and a UI localized in English and Brazilian
Portuguese (it follows the system language).

This document describes how the code is organized and why the trickier parts work the way they do. For how to
build and contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Module map

```
TeXCore ──────────────┬──► TeXToolchain ─┐
  models, tokenizer,  │                  │
  scanning, completion├──► EditorKit ────┼──► GabeTeX (app)
VimKit ───────────────┘    (AppKit)      │
PreviewKit (PDFKit) ─────────────────────┘
```

| Module | Kind | Responsibility |
|---|---|---|
| TeXCore | pure Swift, `Sendable` | Shared models (Diagnostic, Outline, Symbols, Completion, ProjectTemplate), `LineIndex`, `LaTeXTokenizer`, `LaTeXScanner`, `BibParser`, `ProjectIndex`, `StructureLinter`, `ReferenceLinter`, `DocumentStatistics`, `CompletionEngine`, `Snippet`, the completion catalog data, the project templates |
| VimKit | pure Swift, MainActor | `VimEngine` state machine over the `VimTextBuffer` protocol |
| TeXToolchain | Foundation + actors | `TeXDistributionLocator`, `LaTeXCompiler` (shadow workspace + latexmk), `TeXLogParser`, `ChkTeXLinter`, `TeXPackageManager` (tlmgr), `SyncTeX`, `DirectoryWatcher` |
| EditorKit | AppKit (TextKit 1), MainActor | `SourceBuffer`, `LaTeXEditorView` (`NSViewRepresentable`), `EditorController`, `EditorConfiguration`, highlighting, gutter, diagnostics, completion popup and Tab completion, reveal highlight |
| PreviewKit | PDFKit, MainActor | `PDFPreviewView`, `PDFPreviewController`, `PDFPreviewControls`, `PDFPreviewPlaceholder`, highlights, sync clicks, the presentation (audience + presenter) windows |
| GabeTeX | SwiftUI app | windows, project workspace model, sidebar, tabs, Quick Open, toolbar, Issues panel, status bar, Settings, new-project flow, Welcome window and project labels, compile orchestration, package-install flow, SyncTeX glue, detachable PDF window, word and page count, presentation control, `CommandRegistry` / `ShortcutStore` / Command Palette, Touch Bar |
| CheckKit and `*Checks` | executables | A small assertion harness and the check executables that replace XCTest (see [Checks](#checks)) |

The UI modules (EditorKit, PreviewKit, VimKit, GabeTeX) are **MainActor by default**
(`defaultIsolation(MainActor.self)`); the pure modules (TeXCore, TeXToolchain) are built from `Sendable` value types
and actors.

### Conventions shared by every module

- Lines and columns are **1-based**; columns and ranges are **UTF-16** (`NSString`) units.
- File URLs are `standardizedFileURL` file URLs; diagnostics always refer to **project** paths, never to paths inside
  the shadow workspace.
- "Root file" is the main document being compiled (the one with `\documentclass`); a project may contain several.
- Geometry exchanged between modules is in **PDF page space** (points, origin bottom-left, the PDFKit convention).
  SyncTeX's own coordinates are converted at the boundary (see [SyncTeX](#synctex)).

---

## Design language (Liquid Glass)

- **Native structure first**: `NavigationSplitView` (the sidebar gets glass automatically), a standard toolbar
  (glass on macOS 26+), the `Settings` scene, standard menus. No opaque custom backgrounds on chrome; let the
  system materials show.
- **Custom glass only for floating elements**: editor tab pills, status-bar capsules, the compile button, the
  missing-package banner, the Quick Open palette, PDF zoom controls, the completion popup. Use
  `.glassEffect(.regular.interactive(), in: .capsule)` or a `RoundedRectangle`, group neighbours in
  `GlassEffectContainer(spacing:)` so they morph; prominent actions use `.buttonStyle(.glassProminent)`, secondary
  ones `.buttonStyle(.glass)`; `ToolbarSpacer` groups toolbar items.
- **Content stays calm**: the text editor and the PDF are content, not chrome. Standard text background, no glass
  behind text; `scrollEdgeEffectStyle(.soft, for: .top)` where content scrolls under bars.
- Typography: SF Pro for UI, **SF Mono** (`NSFont.monospacedSystemFont`) for code. SF Symbols for icons. System
  semantic colors plus the accent color; everything must look right in Light and Dark mode.
- Motion: subtle `.smooth` animations, `withAnimation` for panel toggles; Reduce Motion is respected.
- Accessibility: every icon-only button has an accessibility label and a `.help()` tooltip.

---

## TeXCore

### LaTeXTokenizer
- Single pass over UTF-16 code units (`NSString.getCharacters` into a buffer), O(n). Target: 100 KB in < 10 ms in a
  release build. Tokens are sorted and non-overlapping; plain prose yields no tokens.
- Commands: `\` + ASCII letters (and `@`), or `\` + one non-letter (`\\`, `\{`, `\%`, `\$`, `\,` …). Escaped
  specials never act as delimiters or comments.
- `structureCommand`: `\part \chapter \section \subsection \subsubsection \paragraph \subparagraph` (starred too),
  `\begin \end \documentclass \usepackage \RequirePackage \input \include \subfile \maketitle \tableofcontents
  \appendix \frontmatter \mainmatter \backmatter \bibliography \printbibliography`.
- After `\begin` / `\end`: braces → `brace`, the name → `environmentName`.
- Reference commands (`\label \ref \eqref \cref \Cref \autoref \pageref \nameref \cite* \citep \citet \parencite
  \textcite \autocite \footcite \nocite \input \include \subfile \includegraphics \includepdf \usepackage
  \documentclass \bibliography \addbibresource \bibliographystyle \lstinputlisting`): skip the optional `[...]`,
  then the `{…}` argument content → `referenceArgument`.
- Comments: an unescaped `%` to the end of the line; a comment line starting `% !TEX` / `%!TEX` / `% !TeX` /
  `% !BIB` → `magicComment`.
- Math mode: `$…$`, `$$…$$`, `\(…\)`, `\[…\]`, and the environments equation, equation\*, align(\*), alignat(\*),
  flalign(\*), gather(\*), multline(\*), eqnarray(\*), math, displaymath, dmath. Inside math: commands →
  `mathCommand`, other runs → `math`. A blank line terminates unclosed inline `$` math, which prevents runaway
  highlighting while typing.
- Verbatim: `\verb<c>…<c>` / `\verb*`, the environments verbatim(\*), Verbatim, lstlisting, minted (skipping
  `{lang}`) and comment → a `verbatim` body until the matching `\end{name}`.
- `& ~ ^ _ #` → `specialCharacter`; `{ }` → `brace`; `[ ]` → `bracket` (only right after a command or in
  `\begin{…}[…]`; ordinary prose brackets stay plain).

### LaTeXScanner (single file, no I/O)
- Ignores comments and verbatim bodies. Arguments may contain nested braces and be preceded by `[optional]`
  arguments and `*`.
- `magicComments`: TeXShop syntax in the first 20 lines: `% !TEX root = path`, `% !TEX program = x` (also
  `TS-program`), `% !TEX spellcheck = x`, `% !BIB program = x` / `% !TEX bib = x`. Keys are case-insensitive.
- `includes`: every `IncludeReference.Kind`; the space-delimited TeX primitive form `\input file` too; comma lists are
  split into one reference each, with per-item ranges.
- `outlineEntries`: sectioning (title = the argument with whitespace collapsed and `\label{…}` removed; a short
  `[title]` is ignored in favour of the long one), beamer `\begin{frame}{Title}` / `[opts]{Title}` /
  `\frametitle{…}`, and `\label{key}`.
- `labels`: context = the innermost enclosing environment (for example "equation", "figure", "theorem") if any, else
  the nearest preceding heading title.
- `customCommands`: `\newcommand \renewcommand \providecommand` (with `[n][default]`), `\newcommand\foo`,
  `\def\foo#1#2`, `\DeclareMathOperator(*)`, `\NewDocumentCommand \RenewDocumentCommand \DeclareDocumentCommand`
  (counting `m` / `o` / `O{}` arguments; mandatory → `{${k:arg}}`, optional omitted), `\DeclarePairedDelimiter`.
  detail = "Defined in project".
- `customEnvironments`: `\newenvironment \renewenvironment \NewDocumentEnvironment \newtheorem(*) \declaretheorem
  \newtcolorbox \newtcbtheorem`.

### ProjectIndex
- `resolve`: the base directory is the root file's directory for input, include, import (the directory is absolute
  or relative to the root directory), bibliography, addbibresource, includegraphics, includepdf, lstinputlisting,
  inputminted, usepackage (local .sty) and documentclass (local .cls); it is the **including file's directory** for
  subfile and subimport. Candidates, in order: input / subfile / import / subimport → `arg`, `arg.tex`;
  include → `arg.tex`; bibliography → `arg.bib`; addbibresource → `arg`; includegraphics / includepdf → `arg`, then
  `.pdf .png .jpg .jpeg .eps`; usepackage → `arg.sty`; documentclass → `arg.cls`. Absolute paths are honoured. The
  first candidate for which `fileExists` is true wins.
- `build`: a depth-first walk from the root through input / include / subfile / import / subimport (`.tex` only),
  cycle-safe and de-duplicated. `files` come in document order. The **outline interleaves included files at the
  position of the include command** (a section in `sections/intro.tex` appears exactly where `\input{sections/intro}`
  sits in `main.tex`). Headings nest by `Kind.level` (a deeper level becomes a child of the nearest shallower
  heading); labels are leaves under the nearest heading (or top level if none). Labels, bibliography entries and
  custom commands are aggregated across files (bibliography files come from `\bibliography` / `\addbibresource`).
- `findRoot`: the root document of a project, from magic comments and `\documentclass`.

### StructureLinter
Conservative, so that valid documents never produce false positives: unmatched `}` / missing `}` (reported at the
opening brace), `\begin{x}…\end{y}` mismatch (always), unclosed `\begin` and stray `\end` (only in files containing
`\begin{document}`), and unclosed inline `$` at the end of a paragraph (a warning). It ignores comments, verbatim,
`\{ \} \$` and `\verb`. Messages are user-facing and go through `String(localized:)`.

### ReferenceLinter
Live warnings for cross-references and citations, computed from the project index.

- **Uses are indexed, not just definitions.** Besides labels and bibliography entries, the index records every
  reference and citation *use* with its file, line, column and length (UTF-16):
  - references: `\ref \eqref \pageref \autoref \nameref \vref \cref \Cref \cpageref \labelcref \crefrange`, including
    comma lists and both keys of a range;
  - citations: `\cite \citep \citet \citealp \citeauthor \citeyear \parencite \textcite \autocite \footcite
    \smartcite \supercite \nocite`, including starred forms, optional `[…][…]` arguments and comma lists
    (`\nocite{*}` is skipped).

  Comments and verbatim are ignored (the scanner works on `MaskedSource`), and keys containing `#` or `\` (macro
  parameters and constructed keys) are never reported. **Label definitions keep every occurrence**, so duplicates can be
  found.
- `ReferenceLinter.diagnostics(index:) -> [Diagnostic]` is pure, `nonisolated` and fast. It produces warnings with
  source `.structure`, whose `length` is the key's UTF-16 length so the editor underlines exactly the key:
  - **Undefined reference** (“Reference ‘key’ is not defined”) at the use. Skipped entirely when the project uses `xr`
    or `xr-hyper` (`\externaldocument`), because the label may live in another document.
  - **Duplicate label** (“Label ‘key’ is defined more than once”) at *every* definition; the `detail` names the other
    location(s) as `file:line`.
  - **Missing citation** (“Citation ‘key’ is not in the bibliography”) at the use. The bibliography is the union of the
    keys of every `.bib` file (`\bibliography{a,b}`, `\addbibresource{…}`) and every `\bibitem{key}`. A project with no
    bibliography source at all gets no citation warnings: the user may simply not be done yet.
- The app recomputes these diagnostics after every index rebuild (which already uses unsaved buffer text) and merges
  them with the compile and structure diagnostics, keeping diagnostic ids stable across rebuilds so underlines do not
  flicker.

### DocumentStatistics
Word counts per section, pure and independent of any PDF.

- Walks the document in reading order from the root file, following `\input` / `\include` / `\subfile` exactly as the
  outline does. For every outline section (part … subparagraph, plus the text before the first section, reported as
  “Preamble/Front matter”) it counts the **words of text**, the **words in headings**, the number of **inline math**
  expressions and the number of **display math** expressions, and it reports document totals.
- The counting rule is close to `texcount`'s defaults. Commands and their non-text arguments (`\label{}`, `\ref{}`,
  `\cite{}`, `\begin{env}`, `\includegraphics`, …), comments, math, verbatim and the preamble are **not** words. The text
  arguments of commands (`\emph{…}`, `\textbf{…}`, section titles, captions, footnotes) **are** counted. A hyphenated
  word and a word with Portuguese accents count as one word; numbers count as words.
- Pages are attributed by the app, not here: see [Word and page count](#word-and-page-count).

### Completion
- Contexts and ranking are documented in the doc comment of `CompletionEngine.swift`. After a bare `\` the most
  common commands are shown; inside math, math commands rank first; at most 200 items.
- `replacementRange` covers the typed prefix. When the accepted text ends with `}` and a `}` already follows the
  cursor (auto-paired), the range extends over it. For `\cite{a,b|}` only the current item is replaced.
- `\begin{` environments insert `name}` + arguments + an indented body + `\n\end{name}` (see the completion
  catalog). `\end{` suggests the innermost unclosed environment first.
- `Snippet(parsing:)`: `${N:default}` (the default may contain `{}` and `\`), `$N`, `$0`, `\$`. Mirrors: only the
  first occurrence of an index is a tab stop.

---

## VimKit

`VimEngine.handle(_:in:)` works over `VimTextBuffer`. The command set (counts apply wherever they make sense):

- Modes: normal, insert, visual, visual-line, replace (`R`), command line (`:` `/` `?`).
- Motions: `h j k l` (j/k keep the desired column), `w W b B e E ge`, `0 ^ $`, `gg G` (`5G`), `{ }`, `%`,
  `f F t T ; ,`, `H M L`, `Ctrl-d Ctrl-u Ctrl-f Ctrl-b`, `* #`, `n N`, `/pattern` `?pattern` (`NSRegularExpression`,
  falling back to a literal search; smartcase), and marks `m{a-z}` + `` `a `` / `'a`.
- Operators with motions and text objects, plus doubled forms: `d c y > < gu gU g~`; `x X s S D C Y`, `r{c}`, `~`, `J`,
  `p P`, `u` / `Ctrl-r`, `.` (repeat the last change including inserted text), `i a I A o O`.
- Text objects: `iw aw iW aW`, `i( a( ib ab`, `i{ a{ iB aB`, `i[ a[`, `i< a<`, `i" a" i' a' i\` a\``, and the LaTeX
  ones: `i$ a$` (inline math) and `ie ae` (the innermost `\begin…\end` environment).
- Visual: `v V`, `o`, operators, `>` `<`, `~ u U`, `J`, Esc.
- Insert mode: printable keys return **false** (the host inserts them natively, so auto-pairing and completion keep
  working). Esc → normal (the cursor steps left). The text inserted during an insert session is reconstructed
  (start offset + length delta) for `.` repeat.
- Ex: `:w :q :wq :x :wa :make :TeX :{N} :s/a/b/[g] :%s/a/b/g :noh`.
- Registers: unnamed, `"a-z`, `"0`, and `"+` / `"*` through clipboard closures; linewise vs characterwise.
- The normal-mode cursor never rests on a line terminator (except on empty lines). Surrogate pairs and composed
  characters are never split (`rangeOfComposedCharacterSequence`). One undo group per change.
- `public var indentUnit: String` (default two spaces); EditorKit sets it from the configuration.
- Not implemented: visual-block mode, macros (`q` / `@`), `:g`, `:normal`, `:sort`.

---

## TeXToolchain

### Distribution detection
Candidates in order: a custom bin directory; `/Library/TeX/texbin` (MacTeX); the newest
`/usr/local/texlive/<year>/bin/universal-darwin`; `~/Library/TinyTeX/bin/universal-darwin`; `/opt/homebrew/bin`;
and the directories of the login-shell `PATH` (`/bin/zsh -lc 'printf %s "$PATH"'`, 3 s timeout). A candidate is
validated with `kpsewhich --var-value TEXMFROOT`; the year and version come from `pdftex --version` /
`tlmgr --version`; the name is MacTeX (the texbin symlink points into `/Library/TeX/Distributions`), TinyTeX,
Homebrew, or else "TeX Live <year>". `isUserWritable` is whether `<TEXMFROOT>/tlpkg` is writable. A health check also
notices tools that are installed but do not run (for example a broken `biber`).

### Process running
An internal async process runner: concurrent stdout/stderr draining (no pipe deadlocks), the environment from
`TeXDistribution.processEnvironment`, a working directory, optional stdin, a timeout, and **cancellation that kills
the whole process tree** (latexmk spawns pdflatex, bibtex and biber, so processes are spawned into a new process
group with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`, and stopped with `kill(-pgid, SIGTERM)` then `SIGKILL`).
Nothing blocks an actor or thread waiting on a process.

### Shadow workspace
This is how background compilation works without touching the user's files.
`~/Library/Caches/io.github.gabe-rbo.GabeTeX/Shadow/<first 16 hex of SHA-256(project path)>/`

- `tree/` mirrors the folder **three levels above** the project (stopping at `/`). At each ancestor level the
  siblings are symlinks to the real entries, the folders on the way down are real directories, and the project
  mirror sits at its real relative position (`tree/<a>/<b>/<project>`), so `\input{../macros}` and
  `\bibliography{../refs}` resolve exactly as they do on disk. Levels with more than 5 000 entries get no sibling
  links. Inside the project every file is a **symlink** to the original, except files in `request.overlays` (unsaved
  buffers), which are written as real files in `request.overlayEncodings` (UTF-8 fallback).
- **Safety:** a symlinked project folder that contains an overlay (or the root) is *materialized* into a real
  directory of per-entry symlinks along that path. Every write, mkdir and symlink first checks that `realpath(parent)`
  lies inside the shadow (`O_CREAT|O_EXCL|O_NOFOLLOW` temp file + rename), so the compiler can never write into the
  user's files; latexmk refuses to run if its working directory escapes the shadow.
- Everything is mirrored except `.git`, `.svn`, `.hg`, `.DS_Store` and editor swap/backup files (so a project
  `.latexmkrc` / `latexmkrc` is honoured). Stale entries are removed on every refresh.
- `out/` is latexmk's `-outdir`, kept across runs (incremental), with the source sub-directory tree mirrored (needed
  for `\include` of files in sub-directories).
- The working directory is the shadow directory of the root file. Command:
  `latexmk <engineFlag> -interaction=nonstopmode -file-line-error -synctex=1 -f -outdir=<out> -e '$bibtex_fudge = 0;'
  [-shell-escape] <root.tex>` with `TEXMFOUTPUT=<out>` (bibtex runs from the compile folder so `../refs.bib` works).
- One compile at a time per project: a new request waits for the cancelled previous run to exit.
  `LaTeXCompiler.terminateAllRunningProcesses()` SIGKILLs every live TeX process group synchronously (it is called when
  the app quits; tlmgr installs are exempt).
- Result: the PDF, log and synctex file come from `out/`. Diagnostics come from the log (and the `.blg`) and are mapped
  to project paths through `ShadowPathMapper`, which also maps the ancestor layer back to the real files (log paths are
  normalized lexically, with a case-insensitive fallback to the on-disk spelling). `status` is `.failed` if any error
  diagnostic exists, `.cancelled` if cancelled, `.toolError` if latexmk could not run, and `.succeeded` otherwise.
- The `.build` purpose additionally copies the PDF atomically to `<root dir>/<jobname>.pdf`; `.live` never exports.

### Log parser (correctness-critical)
- The environment makes the log unwrapped (`max_print_line=10000`).
- `file:line: message` errors (from `-file-line-error`) plus the following context lines (`l.N …` and the next line)
  become the `detail`; "Undefined control sequence" gets the offending control sequence appended (the last token of
  the `l.N` line).
- `! …` errors without file:line take the current file from the **file stack** and the line from `l.N`.
- Warnings: `LaTeX Warning:`, `Package X Warning:`, `Class X Warning:`, `LaTeX Font Warning:`, `pdfTeX warning`.
  `\MessageBreak` continuation lines (the `(X)   …` prefix) are joined; the line comes from `on input line N`.
  `Info` lines are skipped. "Label(s) may have changed" / "Rerun" → `.info`.
- Bad boxes: `Overfull/Underfull \hbox|\vbox (…) in paragraph at lines a--b`, `at line N`, `detected at line N`, and
  `has occurred while \output is active` → `.badbox`.
- File stack: `(` followed by a path-like token (starting with `./ ../ /` or ending with a known extension: .tex .sty
  .cls .cfg .def .clo .fd .aux .toc .lof .lot .bbl .out .nav .ind .ltx .dtx .bib .mkii .lua) pushes a file; any other
  `(` pushes a non-file marker so `)` stays balanced.
- Missing files: ``! LaTeX Error: File `x.sty' not found.``, ``! I can't find file `x'.``, and latexmk's "Missing input
  file" → `missingFile`.
- BibTeX `.blg` (`Warning--…`, `I couldn't open database file`, `---line N of file F`) and biber (`ERROR -`, `WARN -`).
- Duplicates are removed; errors sort first, then by file and line.
- The parser is tested against **real** logs (see `Tests/Fixtures/TeXToolchain`).

### chktex
`chktex -q -I0 -v0 -f '%l:%c:%d:%k:%n:%m\n'` with the text on stdin. Noisy warnings are suppressed by default.
Severity: chktex Error → `.warning`, Warning / Message → `.info`.

### tlmgr
- `packages(providing:)`: `tlmgr search --global --file "/<file>"` (network, 60 s timeout). The `pkg:` header lines are
  parsed. Ranking: a package whose name equals the file stem or the file's parent directory name comes first.
- `install`: if `isUserWritable`, tlmgr runs directly; otherwise through
  `/usr/bin/osascript -e 'do shell script "<sh command>" with administrator privileges with prompt "<localized>"'`,
  with every argument single-quoted for sh and then escaped for an AppleScript string. osascript error -128 →
  `.userCancelledAuthorization`. "tlmgr itself needs to be updated" → `.tlmgrNeedsUpdate`, "is older than remote
  repository" → `.distributionFrozen`, "not present in repository" → `.notFoundInRepository`.
- The checks cover parsing and command construction and never install anything.

### SyncTeX
`synctex view -i "<line>:<column>:<shadow input path>" -o "<pdf>"` (forward) and
`synctex edit -o "<page>:<x>:<y>:<pdf>"` (inverse).

**Coordinate convention** (verified against real pdfTeX output by the checks): the CLI uses PDF points with the origin
at the **top-left** of the page's media box. In `synctex view` records `h` is the left edge and `v` is the **bottom**
of the box (baseline + depth), so the box spans `v − H … v` with y growing downward; `synctex edit -o page:x:y` takes a
top-left-origin point as well. Conversion to PDF page space (origin bottom-left): `x = mediaBox.minX + h`,
`y = mediaBox.maxY − v` (the bottom edge), height `H`; and back, `x − mediaBox.minX`, `mediaBox.maxY − y`. The media
box comes from `CGPDFDocument`. Paths are mapped with `ShadowPathMapper`, and the returned file URL is normalized to
the on-disk spelling (Unicode normalization, letter case) so it compares equal to the URLs the app got from its file
tree.

`SyncTeX.forward` returns `SyncTeXBox`es (page + rect in PDF page space); `SyncTeX.inverse` returns a
`SourceLocation` (file, line, optional column). SyncTeX alone only knows the *line* and a box, not the word; the
word-level precision is added by the app, EditorKit and PreviewKit (see [Source ↔ PDF sync](#source--pdf-sync)).

### DirectoryWatcher
FSEvents (`kFSEventStreamCreateFlagFileEvents | NoDefer | WatchRoot`), 0.2 s latency, its own dispatch queue; `.git`
and hidden paths are ignored; changes are coalesced and delivered as changed URLs.

---

## EditorKit (TextKit 1)

- `LaTeXTextView: NSTextView` is built on an explicit TextKit 1 stack (`NSTextView(usingTextLayoutManager: false)` or
  an `NSLayoutManager` / `NSTextContainer` pair). **`textLayoutManager` is never accessed**, because that would
  switch the view to TextKit 2. Swapping buffers is `layoutManager.replaceTextStorage(buffer.textStorage)`, restoring
  `savedSelection` / `savedScrollY` and saving them when switching away. Undo is per buffer through
  `undoManager(for:)`.
- Smart quotes, dashes, text replacement and auto-correction are disabled; spell checking follows the configuration.
- **Highlighting**: `LaTeXTokenizer` → colors through layout-manager **temporary attributes** (they never affect undo
  or dirtiness). Small documents are highlighted synchronously; large ones (> 200 KB) off the main thread with a
  version check. Dynamic colors for Light and Dark with a calm palette: commands purple, structure accent blue,
  environment names teal, math green, references indigo, comments secondary label, braces tertiary, verbatim orange.
- **Gutter**: an `NSRulerView` with line numbers (first fragment of wrapped lines only, current line emphasized, the
  width adapts to the digit count) and diagnostic markers per line (maximum severity); clicking opens a popover that
  lists the messages.
- **Current line**: a subtle background highlight.
- **Diagnostics in text**: a squiggle-like underline (patterned underline + color) from the column for `length` (or to
  the end of the token or word; the whole trimmed line when there is no column). Errors red, warnings orange, info and
  bad boxes subtle. Hovering shows the message after a short delay. Existing anchors are kept when another diagnostic
  source updates, so underlines do not jump back to stale lines.
- **Editing**: auto-pair `{} [] () $$` (only when sensible; type-over of the closing character; backspace removes an
  empty pair), Enter after `\begin{x}…` inserts the matching `\end{x}` (if not already closed) with the caret indented
  inside, auto-indent (copies the leading whitespace), Tab / ⇧Tab indent and outdent selections, ⌘/ toggles `% `
  comments. The indent unit comes from the configuration.
- **Completion popup**: a borderless non-activating child panel under the caret (`firstRect(forCharacterRange:)`) with
  SwiftUI content on a glass background: label (mono), detail (secondary), package badge. It triggers automatically
  after `\` + letters and after `{` in ref / cite / begin / input / usepackage contexts (debounced ~80 ms, configurable),
  and manually with ⌃Space / ⌥⎋. ↑↓ PgUp PgDn move, Return / Tab accept, Esc dismisses. Accepting replaces
  `replacementRange` with the snippet (indenting `\n` to the current line's indentation, `\t` → the indent unit) and
  starts a tab-stop session (Tab / ⇧Tab cycle; it ends on Esc or when the caret leaves). One undo group.
- **Tab completes** (`EditorConfiguration`, default **on**; handled by `CompletionController` and the text view's Tab
  handling). With the caret right after a completable prefix (`\com…`, or inside `\ref{…}`, `\cite{…}`, `\begin{…}` or
  a file argument), Tab opens the completion popup, or inserts directly when exactly one candidate matches. In every
  other situation Tab keeps its previous meaning: accept the open popup, jump to the next snippet field, or indent.
  ⌃Space remains an always-on trigger (and, like every shortcut, can be rebound). Which keys *accept* a suggestion is
  configurable (Tab and Return, Tab only, or Return only). Both settings live in `EditorConfiguration` and are covered
  by headless `EditorKitChecks`. With Vim mode on, Tab completion applies in insert mode only.
- **⌘-click** (`TextViewMouse`, `TextViewSync`):
  - on an include argument → `controller.onOpenReference`;
  - on a `\ref`-family key → `controller.onOpenLabel`;
  - on a `\cite` key → reserved for bibliography jumps, never "Show in PDF";
  - on ordinary text → `controller.onShowInPDF` (see below).
- **Vim**: when `configuration.vimMode`, `keyDown` goes to `VimEngine` first. The adapter conforms to `VimTextBuffer`;
  normal and visual modes draw a block caret (custom `drawInsertionPoint`, widened invalidation rect); the controller
  exposes the mode, pending keys and command line; registers are bridged to `NSPasteboard`. Outside insert mode, keys
  that are dead keys on ABNT2 and US-International layouts (`^ ~ \` ´`) are translated with the keyboard layout
  instead of being swallowed.
- **Find bar**: `usesFindBar` with incremental search; `showFind(replace:)` drives it.
- Every user edit calls `buffer.noteEdit()` and then `onTextChange(buffer)`.
- Typing latency must stay imperceptible on 5 000-line files.

### Programmatic editor API (`EditorController`)
Besides the state published for the status bar (cursor, selection, Vim mode), `EditorController` is the bridge the
app uses:

| API | Purpose |
|---|---|
| `onOpenReference`, `onOpenLabel`, `onVimExCommand` | callbacks for ⌘-click navigation and Vim `:` commands |
| `onShowInPDF: ((SourcePosition, String?) -> Void)?` | source → PDF requests: ⌘-click on ordinary text and the "Show in PDF" context-menu item. Reports the position (1-based line, UTF-16 column) and the word there. The context-menu item only exists while a handler is set |
| `reveal(_ range: NSRange, flash: Bool = true)` | puts the caret at the start of `range`, centers it vertically, and briefly flashes a soft rounded accent highlight behind the range |
| `word(at offset: Int) -> (word: String, range: NSRange)?` | the word at or right before a UTF-16 offset (a LaTeX control word counts as a word without its backslash) |
| `goTo(line:column:highlight:)` | caret to a 1-based position, with the same highlight |
| `select`, `focus`, `insertText`, `toggleComment`, `indentSelection`, `outdentSelection`, `showFind`, `triggerCompletion` | imperative editing helpers |

**The reveal highlight** is drawing only: nothing is written to the text storage, the undo manager or the dirty state,
and no layout-manager attribute is touched. Its rectangles are recomputed from the layout manager on every tick, so it
follows scrolling, wrapping and re-layout while it fades (about 1.2 s; with Reduce Motion it stays briefly at full
strength and is then removed without animation). It is cancelled by another reveal, a buffer swap, a text edit or the
view leaving its window.

---

## PreviewKit

- A `PDFView` subclass. `load(_:)` reads the file into `Data` (avoiding mmap of a file latexmk rewrites; if the data does
  not end with `%%EOF`, it retries shortly) and **preserves** the page, in-page point and scale across reloads without
  flashing. The controller owns the `PDFDocument`, so it works whether or not a `PDFPreviewView` is on screen, and a view
  that appears later receives the document and the reading position the previous view had.
- **Highlights** are an overlay (not PDF annotations): rounded, translucent accent rectangles that scroll the first one
  into view (centered) and fade out after ~1.5 s (Reduce Motion is respected). Highlights requested while a new PDF is
  still loading are held briefly and shown once it is on screen.
- **Sync click**: `PDFPreviewController.syncTrigger` selects the gesture (`PDFSyncTrigger`: `.doubleClick`, the default,
  or `.commandClick`). When it happens, `onSyncClick(PDFSyncClick)` fires with the page index, the point in PDF page
  space, the **word under the pointer** (via `PDFPage.selectionForWord(at:)`; ligatures and hyphenation are resolved by
  PDFKit) and about 40 characters of page text on each side as context. Normal selection and links keep working, and a
  double-click still selects the word visually. `onInverseSearch(pageIndex, point)` remains for hosts that only want
  the position.
- **Matching highlight**: `showHighlights(_:matching:contextBefore:contextAfter:)` takes the SyncTeX boxes plus the source
  word and its context. If that word occurs in the page text inside or near a box, only that occurrence is highlighted
  (the one closest to the box, using the context to choose among repeats); otherwise the boxes themselves are shown.
  `showHighlights(_:)` shows plain boxes.
- Tracks the current page and scale for the controls. `PDFPreviewControls` is a floating glass capsule (zoom −, zoom %,
  zoom +, fit width, "3 / 12"). `PDFPreviewPlaceholder` is the empty state.

### Presentation
PreviewKit also contains the presentation mode: it works with **any compiled PDF** (Beamer slides are the target) and
is controlled by the app through the workspace (see [Presentation mode](#presentation-mode)).

- **Pure logic, tested headlessly.** The slide math and the navigation are plain value types with no AppKit: the
  navigation state machine (current slide, next/previous, first/last, digit entry with Return to go to a slide, black and
  white screens, clamping the index when a reload changes the page count) and the geometry that splits a page into its
  slide and notes halves. `EditorKitChecks` exercises them.
- **Audience window**: borderless, full screen on the external display, black background, slide scaled to fit, no
  chrome. The cursor hides after 2 s without movement; a click advances.
- **Presenter window**: full screen on the main display. It shows the current slide large, the next slide, a slide
  counter (“5 / 23”), an elapsed timer (pause, resume, reset), the clock, and a notes pane, with a Liquid Glass controls
  bar. The chrome follows Light and Dark; the slides always sit on black.
- **One display**: the audience view is full screen on that display and **P** toggles the presenter view on top of it.
- **Beamer notes**: when pages are about twice as wide as tall (`\setbeameroption{show notes on second screen=right}`),
  the audience shows the slide half of each page and the presenter's notes pane shows the other half. `=left` is
  mirrored. A “Notes on” setting offers right, left, or none (automatic).
- **Keys** work in both windows: next = → ↓ Space Page Down Return; previous = ← ↑ Page Up Delete; Home / End; digits then
  Return jump to a slide; B or . = black screen; W or , = white screen; Esc ends the presentation.
- **Live reload** keeps the current slide index (clamped to the new page count). With Reduce Motion there are no
  transitions.
- Windows are managed by a controller that follows `NSScreen` changes: when displays are plugged or unplugged it
  re-places the windows, or ends the presentation gracefully.

---

## Source ↔ PDF sync

SyncTeX knows *lines* and *boxes*. GabeTeX narrows both directions down to the exact word, then flashes the
destination.

**PDF → source.** The user double-clicks a word in the PDF (or ⌘-clicks, depending on **Settings › General › Jump to
source from PDF**).
1. PreviewKit fires `onSyncClick` with the page, the point, the word and its context.
2. The app asks `SyncTeX.inverse` for the file and line, opens that file and looks for the clicked word in the source.
3. The search starts on the reported line and widens to ±3 lines. The source is read the way TeX typesets it: comments
   and command names are ignored, and the arguments of `\label`, `\ref`, `\cite`, `\begin` … are skipped. LaTeX accents
   (`\'e`, `\~a`, `{\c c}`, `\"o`) and letters (`\ss`, `\ae`, `\o`) are decoded. Comparison ignores case and diacritics
   and expands ligatures; a prefix match of at least four letters is accepted when the PDF word is only a fragment of a
   hyphenated word.
4. With several candidates, the best is chosen by context similarity, the distance to the reported line and, when
   SyncTeX reports one, the column.
5. The app calls `editor.reveal(range, flash: true)` and focuses the editor. If no word matches, it reveals the whole
   line instead.

**Source → PDF.** The user presses ⇧⌘J (Show in PDF), ⌘-clicks ordinary text in the editor, or picks "Show in PDF" from
the editor's context menu. All three end in `onShowInPDF(position, word)`.
1. The app asks `SyncTeX.forward` for the boxes.
2. It calls `preview.showHighlights(boxes, matching: word, contextBefore:, contextAfter:)`; PreviewKit highlights exactly
   that word occurrence in or near the boxes (else the boxes) and scrolls it to the center.

An optional **Follow cursor in PDF** setting (off by default) performs a silent forward sync after the caret has rested
for about 0.6 s with no selection. It scrolls only if the target is off-screen and never steals focus.

---

## GabeTeX app

### Scenes
- **Welcome** window: the app icon, New Project…, Open Folder…, Open File…, and the recent projects (UserDefaults, at
  most 15 unlabeled ones) with their labels, label filter chips and a search field.
- **Project windows**: `WindowGroup(id: "project", for: ProjectReference.self)`;
  `ProjectReference { folderURL; initialFile? }` is `Codable` and `Hashable`. Opening a single `.tex` file opens its
  folder with that file selected. Finder and Dock opens (`application(_:open:)`) route to project windows.
- **PDF window**: `WindowGroup(id: "pdf", for: <reference to the project folder>)`, showing the same
  `PDFPreviewController` as its project window (see [Detachable PDF](#detachable-pdf)).
- **Presentation windows**: an audience window and a presenter window, created and owned by a PreviewKit controller on
  behalf of the project workspace (see [Presentation mode](#presentation-mode)).
- **Command Palette**: a floating panel inside the project window (and the detached PDF window), see
  [Commands, shortcuts and the Command Palette](#commands-shortcuts-and-the-command-palette).
- **Settings**: General (default engine, live compile on / off, live delay 0.5–5 s, compile on save, chktex on / off,
  sync the PDF to the cursor after a build, jump-to-source trigger, follow cursor in PDF), Editor (font, size, line
  height, line numbers, wrapping, current line, auto-pair, auto-close environments, auto-completion, indent width and
  spaces, spell check, **Vim mode**, the autocomplete options: whether Tab completes and which keys accept a
  suggestion), TeX (detected distribution, version and tools ✓ / ✗, custom bin directory override, writable or
  admin-required note, a link to install MacTeX if none is found), **Shortcuts** (every command and its shortcut, see
  below).

### Project window layout
```
NavigationSplitView
├─ sidebar: [Files | Outline] segmented
│   Files: tree (folders first, SF Symbol per type, ★ main file, dirty dot); context menu: New File,
│          New Folder, Rename, Duplicate, Move to Trash, Reveal in Finder, Set as Main Document
│   Outline: ProjectIndex.outline (sections / frames / labels) across files → click jumps;
│            a small secondary word count trails each section
└─ detail:
    ├─ tab strip (glass pills: icon, name, dirty dot, close; ⌘1…⌘9, ⌃Tab cycling)
    ├─ banners (missing package / file changed on disk / no TeX found): glass
    ├─ EditorPreviewSplit: editor | PDF preview (toggle ⌥⌘P; 55/45 by default, divider remembered per project), floating PDFPreviewControls
    ├─ Issues panel (toggle ⇧⌘M): errors / warnings / bad boxes filter, click → jump; Log tab with the raw log
    └─ status bar: compile state capsule, error / warning counts, word / page count capsule (click → Document
       Statistics popover), engine, distribution, Vim mode, Ln/Col
toolbar: Compile (glassProminent, spinner while compiling) · Stop · engine menu · live-compile toggle ·
         preview toggle · detach-PDF toggle · issues toggle · Present (play; only for Beamer documents)
overlay: Command Palette (⇧⌘P), Quick Open (⌘P)
```

### ProjectWorkspace (`@Observable`, one per window)
- The file tree is scanned off the main thread and refreshed by `DirectoryWatcher`. Open buffers `[URL: SourceBuffer]`,
  tabs and the current file live here. The main file is a per-project override (UserDefaults keyed by folder path),
  else `ProjectIndex.findRoot` / the magic comment.
- `ProjectIndex` is rebuilt (debounced ~300 ms) after edits and saves, off the main thread, using a snapshot of the
  open buffers' text.
- **Live compile** (default on): an edit starts a debounce (a setting, default 1.0 s), then
  `LaTeXCompiler.compile(.live)` runs with overlays of every dirty buffer. ⌘B / save → save all → `.build`. The
  diagnostics, the preview (the newest PDF is shown even when the compile failed but produced one) and the status are
  updated. The engine comes from `% !TEX program`, then the project setting, then the default.
- Diagnostics = compile ∪ chktex (current file, debounced 1.5 s, if enabled) ∪ structure lint (on edit, debounced
  0.3 s) ∪ [reference and citation warnings](#referencelinter) (after each index rebuild).
- **Missing package flow**: `result.missingFiles` → a banner (“tikz-cd.sty” is not installed) with [Install] and
  [Dismiss] → `packages(providing:)` → a choice if several packages match → `install` (administrator prompt) with
  progress → recompile. Errors appear in an alert with actionable text (update tlmgr, update the TeX distribution).
- **Navigation**: ⌘-click on an include → `ProjectIndex.resolve` → open the file; ⌘-click on a label → its definition.
  Source ↔ PDF sync is described [above](#source--pdf-sync).
- **Vim ex commands**: `:w` saves, `:wa` saves all, `:q` closes the tab, `:make` compiles.
- **Saving**: atomic write preserving metadata, in the file's own encoding; the disk is checked first, and a file that
  changed underneath asks what to do. External changes: a clean buffer reloads silently; a dirty one shows a banner
  with [Reload] and [Keep Mine].
- **Quick Open** (⌘P): a glass palette with fuzzy file search; ↑↓ and Return.
- Menus via `.commands` and `FocusedValue` for the active workspace, generated from the command registry (see below).
  Default shortcuts: File (New Project ⇧⌘N, Open ⌘O, Open Recent, New File ⌘N, Save ⌘S, Save All ⌥⌘S, Project Labels),
  Edit (Toggle Comment ⌘/, Complete ⌃Space), View (preview ⌥⌘P, Open PDF in Separate Window / Attach PDF to Project
  Window, issues ⇧⌘M, Quick Open ⌘P), **Build** (Compile ⌘B, Stop ⌘., Live Compile, Engine ▸, Set as Main, Clean
  Auxiliary Files ⇧⌘K, Show in PDF ⇧⌘J, Next / Previous Issue ⌘' / ⇧⌘'). Start Presentation (⌥⌘↩) and the Command
  Palette (⇧⌘P) are commands too.
- Unbundled `swift run` must still work (`setActivationPolicy(.regular)`).

### Project labels
Labels organize the Welcome window's recent projects. They are **app-level**: nothing is written to the project folder
and they are unrelated to Finder tags.
- `ProjectLabel { id: UUID, name, color }` with a Finder-like palette (red, orange, yellow, green, blue, purple, gray),
  mapped to system colors so it is correct in Light and Dark.
- An `@Observable` store keeps labels and assignments in UserDefaults. Assignments are keyed by the project's folder
  path, together with a folder identity (device + inode) so labels follow a folder that was renamed or moved on the same
  volume once it is reopened from its new path.
- The Welcome window shows a row of filter chips (single selection; hidden when no labels exist), a search field when
  there are many recents, and labels as small colored capsules on each row. Row context menu: Labels ▸ (toggles +
  New Label…), Reveal in Finder, Remove from Recents. Chip menu: Rename…, Color ▸, Delete Label. The project window's
  **File › Project Labels** menu offers the same toggles.
- **Labeled projects never fall off the recents list**: the cap on the recents count applies only to unlabeled ones.

### Detachable PDF
- **View › Open PDF in Separate Window** (also a toolbar toggle and a small glass button on the docked preview) moves the
  preview into its own window showing the **same** `PDFPreviewController` as the project's workspace
  (`PDFPreviewView` + `PDFPreviewControls` + `PDFPreviewPlaceholder`). While detached, the docked preview disappears
  from the split.
- **Attach PDF to Project Window** (the detached window's toolbar and the View menu) docks it again; closing the
  detached window also re-docks it, and closing the project window closes its PDF window.
- The detached window remembers its frame per project (it works across displays, using a stable per-project frame
  autosave name) and the detached state per project, which is restored when the project reopens. Full screen is
  allowed. The title is "<Project> — PDF".
- Everything works the same while detached: live reloads, forward-sync highlights, PDF → source sync (which activates
  the project window and focuses the editor), and the menu shortcuts (⌘B etc.), because the PDF window publishes the
  same focused scene values.

### Word and page count
- **Words** come from `DocumentStatistics` ([above](#documentstatistics)), recomputed in the background after index
  rebuilds. The **status bar capsule** shows “1 234 words · 12 pages” with locale-aware number formatting; while the
  editor has a selection it shows “86 of 1 234 words”. The outline sidebar shows a small trailing word count per
  section in a secondary style.
- **Pages**: the total is the page count of the loaded PDF (PDFKit). Per section, the app asks `SyncTeX.forward` for
  the page of each section's heading line; a section spans from its own page to the page of the next section, and the
  count is shown with “≈” when sections share pages. This needs a PDF and its `.synctex` file; without them the
  per-section pages show “—”.
- Page attribution never blocks the UI: it runs in the background, is debounced, and a stale request is cancelled when
  a newer one arrives.
- Clicking the capsule (or running **Document Statistics** from the command palette) opens a glass popover: a table with
  one row per section (title indented by level, words, pages), the document totals, and a footnote stating the
  counting rule.

### Presentation mode
`ProjectWorkspace` exposes `canPresent`, `isPresenting`, `startPresentation()` and `stopPresentation()`.
- `canPresent` is true whenever a compiled PDF exists, so the **Start Presentation** command (⌥⌘↩, also in the command
  palette) works for any document. The **Present** (play) toolbar button is shown only for Beamer documents, detected by
  `\documentclass{beamer}` in the root file.
- Starting a presentation hands the current PDF to PreviewKit's presentation controller (see
  [Presentation](#presentation)), which creates the audience and presenter windows on the right displays. When the
  workspace reloads the PDF after a live compile, the controller keeps the current slide.
- Ending the presentation (Esc, or `stopPresentation()`) closes both windows.

### Commands, shortcuts and the Command Palette
- **`CommandRegistry`** is the single list of everything the user can do. Each `AppCommand` has a stable string `id`, a
  `title`, a `category`, an optional `defaultShortcut`, an `isEnabled(context)` and a `perform(context)`. It covers every
  menu command (File, Edit, View, Build, project labels, the PDF window, Quick Open, statistics, presentation …) and the
  editor actions: Toggle Comment, Indent / Outdent, Complete, and the markup actions that the Touch Bar also uses through
  `EditorController.performMarkup` (inline and display math, fractions, sub- and superscripts, bold / italic / emphasis,
  environments, sections). `Commands.swift` builds the menus from the registry, so a customized shortcut shows in the
  menu and works. The menus and the palette run the same entries, so each action has one code path; the Touch Bar
  shares the same markup actions.
- **`ShortcutStore`** keeps the user's overrides on top of the defaults, persisted in `UserDefaults` as JSON, keyed by
  command id. It detects conflicts (two commands on one combination), refuses system-reserved combinations (⌘Q, ⌘H, ⌘Tab,
  ⌘Space, ⌘, …) and can restore one command or everything to the defaults.
- **Command Palette** (⇧⌘P): a floating glass panel at the top of the project window, in the style of Spotlight. It
  searches with the same fuzzy matcher as Quick Open. Each row shows an SF Symbol, the title, the category and the
  shortcut glyphs; recently used commands come first. ↑↓ moves, Return runs, Esc closes. Disabled commands are shown dimmed
  and cannot be run. It also works while the detached PDF window is key, because that window publishes the same focused
  scene values as the project window.
- **Settings › Shortcuts**: a searchable list grouped by category. Each row has a shortcut recorder (click, then press
  the combination; ⌫ clears it; Esc cancels). A conflict shows an inline warning with a **Replace** action; there are
  per-row and global **Restore Defaults**.

### Touch Bar
On Macs that have a Touch Bar, the app provides an `NSTouchBar` through the responder chain, so the bar follows the focus:
- **Editor / project window**: compile and stop, Show in PDF, math shortcuts, scrubbers for Greek letters and math
  symbols, and section and environment commands. Items act through the same workspace and `EditorController` entry points
  as the menus and keyboard shortcuts, so there is a single code path for each action.
- **PDF focused**: page and zoom controls, driving `PDFPreviewController` (`goToPage`, `zoomIn`, `zoomOut`, …).
- The bar is customizable (**View › Customize Touch Bar…**) and its layout is remembered by the system.

---

## Platform gotchas worth knowing

- **Floating rulers (macOS 26).** An `NSScrollView` with a ruler offsets its clip view horizontally (negative x). Code
  that restores or sets the scroll position must keep `contentView.bounds.origin.x`, or text slides under the gutter.
- **`clipsToBounds`.** Since macOS 14 views no longer clip by default. `EditorGutterView` sets `clipsToBounds = true` and
  fills only `dirtyRect ∩ bounds`, otherwise the gutter paints over the text.
- **Accessibility.** With a ruler on macOS 26, `NSScrollView.accessibilityChildren()` comes back empty;
  `LaTeXEditorScrollView` overrides it to expose the editor as an `AXTextArea`. Don't put an `.accessibilityLabel` on
  the `NSViewRepresentable` wrapper: it replaces the text area.
- **No SwiftUI macros.** `@State`, `@Entry` and `#Preview` do not build with the Command Line Tools; the module-internal
  `@LocalState` wrapper and hand-written environment keys replace them.

---

## Checks

XCTest and swift-testing are not available with the Command Line Tools alone, so tests are executables on top of
`CheckKit` (`Check.suite`, `Check.expect`, `Check.equal`; `Check.finish()` prints `CHECKS: N passed, M failed` and exits
non-zero on failure).

| Target | Covers |
|---|---|
| `TeXCoreChecks` | tokenizer, scanner, project index, structure and reference linters (every reference and citation macro form, comma lists and ranges, multi-file projects, duplicates, `\bibitem` vs `.bib`, the no-bibliography and `xr` cases, UTF-16 columns), document statistics, completion, snippets, bibliography parser, performance budgets |
| `VimKitChecks` | motions, operators, text objects, visual mode, registers, ex commands and search, Unicode, fuzzing |
| `EditorKitChecks` | headless `NSTextView` editing behaviour (no window needed), Tab completion, highlights and sync helpers, and the pure presentation logic (slide and notes geometry, navigation, digit entry, clamping on reload) |
| `TeXToolchainChecks` | log parser against real-log fixtures, process runner, shadow workspace and its safety guarantees, SyncTeX, and (without `--unit`) end-to-end compiles on a machine with MacTeX |

---

## Build & packaging

`Scripts/build-app.sh` produces `build/GabeTeX.app` from a release build: the binary, `Info.plist`, `AppIcon.icns`, the
`*.lproj` localizations, and an ad-hoc code signature (`--install` copies it to `~/Applications`). The app is **not
sandboxed**: it has to run TeX binaries and write wherever the user chooses. It is not notarized.
