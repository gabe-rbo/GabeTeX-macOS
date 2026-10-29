# Changelog

All notable changes to GabeTeX are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] — 2026-10-29

The first public release. It adds project labels, a detachable PDF window, precise two-way sync between the
source and the PDF, and Touch Bar support.

### Added

- **Project labels** on the Welcome window. Give recent projects color labels (red, orange, yellow, green, blue,
  purple, gray), filter the list with chips, and search it when it grows. Labeled projects never fall off the
  recents list. Create, rename, recolor and delete labels from the chip menu, assign them from a project's context
  menu or from **File › Project Labels**. Labels are stored in the app and never touch your project folders or
  Finder tags.
- **Detachable PDF preview.** **View › Open PDF in Separate Window** (also a toolbar toggle and a button on the
  docked preview) moves the preview into its own window, ready for a second display or full screen. **Attach PDF
  to Project Window** (or simply closing the window) docks it again. The window remembers its position per
  project, and live reloads, sync highlights and the build shortcuts keep working while it is detached.
- **Precise two-way sync with a brief highlight.**
  - *PDF → source:* double-click a word in the PDF (or ⌘-click, chosen in **Settings › General**) to jump to that
    exact word in the source, even inside section files. Accents (`\'e`, `{\c c}`), ligatures and hyphenated words
    are understood. The target is briefly highlighted and the editor takes focus.
  - *Source → PDF:* ⌘-click ordinary text in the editor, use **Show in PDF** from the context menu, or press ⇧⌘J to
    jump to that exact word in the PDF, which is briefly highlighted.
  - Optional **Follow cursor in PDF** setting (off by default) keeps the PDF in step as the caret rests.
- **Touch Bar support** on Macs that have a Touch Bar: compile and stop, Show in PDF, shortcuts for math and for
  sections and environments, scrubbers for Greek letters and math symbols, and page and zoom controls when the PDF
  has focus. Customize it with **View › Customize Touch Bar…**.

### Changed

- Jumping to a position in the editor now flashes a soft, rounded accent-colored highlight (Light/Dark aware; no
  animation with Reduce Motion) instead of the yellow find indicator.
- PDF → source sync now defaults to double-click instead of ⌘-click.
- The editor and PDF now open side by side in a balanced split, and the divider position is remembered per
  project (also after detaching and re-attaching the PDF).
- **Build › Forward Search** is now **Build › Show in PDF** (⇧⌘J).

## 1.0.0 — 2026-10-28

The initial feature set (not released separately; it ships as part of 1.1.0).

### Added

- Native SwiftUI + AppKit app with the macOS 26 Liquid Glass look, Light and Dark mode and an SF Mono editor.
- **Projects, not files**: open any folder or create a project from a template; file tree sidebar, tabs, Quick Open
  (⌘P), ⌘-click on `\input{…}` / `\include{…}` to open the file and on `\ref{…}` to jump to its `\label`, and a
  document outline that spans all included files. Made for one-file-per-section writing, with `% !TEX root` and
  `% !TEX program` magic comments and automatic root detection.
- **Adapts to the installed TeX**: detects MacTeX, TeX Live, BasicTeX and TinyTeX; compiles with `latexmk`
  (pdfLaTeX, XeLaTeX, LuaLaTeX) **in the background while you type**, including unsaved text, in a private shadow
  copy of the project so your files are never touched until you save.
- Errors and warnings from the TeX log and from ChkTeX underlined at the right line of the right file (also inside
  section files), an Issues panel, and an offer to install missing packages with `tlmgr` (asking for the
  administrator password when needed).
- Integrated PDF preview (PDFKit) with SyncTeX; ⌘B saves and exports the PDF next to `main.tex`; ⇧⌘K cleans
  auxiliary files.
- Autocomplete for commands, environments, `\ref` / `\cite` keys, files and packages, with snippets.
- Optional **Vim mode**: normal, insert, visual and visual-line modes, operators and text objects (including `i$` /
  `a$` for math and `ie` / `ae` for environments), `:w :wa :q :make`, search and substitute; aware of dead keys on
  ABNT2 and US-International layouts.
- Respects file encodings (UTF-8 and Latin-1 detection with an encoding indicator), saves atomically while
  preserving file metadata, and detects external changes.
- User interface in English and Brazilian Portuguese, following the system language.

[Unreleased]: https://github.com/gabe-rbo/GabeTeX/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/gabe-rbo/GabeTeX/releases/tag/v1.1.0
