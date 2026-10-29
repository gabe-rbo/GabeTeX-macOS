# Contributing to GabeTeX

Thank you for taking the time to help! GabeTeX is a small, focused project and every bug report, idea,
translation fix and pull request is welcome.

**You can write issues and pull requests in English or in Portuguese** (Português do Brasil). Both are equally
welcome; the maintainer reads both.

Please be kind to each other: this project follows the [Code of Conduct](CODE_OF_CONDUCT.md). To report a
security problem privately, see [SECURITY.md](SECURITY.md).

## Contents

- [Development setup](#development-setup)
- [Build, run and check](#build-run-and-check)
- [Project layout](#project-layout)
- [Conventions that matter here](#conventions-that-matter-here)
- [Reporting bugs](#reporting-bugs)
- [Suggesting features](#suggesting-features)
- [Pull request checklist](#pull-request-checklist)

## Development setup

You need:

- a Mac running **macOS 26 (Tahoe) or later**;
- the **Command Line Tools** for Xcode, which provide Swift 6.2 or newer: `xcode-select --install`.
  **Full Xcode is not needed**, and the project is deliberately set up so that it builds without it;
- a **TeX distribution** ([MacTeX](https://tug.org/mactex/) recommended) to try the app and to run the
  end-to-end toolchain checks.

```sh
git clone https://github.com/gabe-rbo/GabeTeX-macOS.git
cd GabeTeX-macOS
swift build
```

There is no Xcode project, no package manager other than SwiftPM, and no third-party dependency to install.

## Build, run and check

```sh
swift build                       # debug build of every module and check executable
swift run GabeTeX                 # run the app straight from the build folder (no bundle)

Scripts/build-app.sh              # release build → build/GabeTeX.app, ad-hoc signed
CONFIG=debug Scripts/build-app.sh # same, as a debug build
Scripts/build-app.sh --install    # …and copy it to ~/Applications
```

### Checks instead of XCTest

XCTest and swift-testing only ship with full Xcode, so GabeTeX's tests are plain executables built on a tiny
assertion harness, `CheckKit` (`Check.expect`, `Check.equal`, `Check.suite`). Each one prints a summary line such as
`CHECKS: 555 passed, 0 failed` and exits with status 1 when anything fails.

```sh
swift run TeXCoreChecks           # tokenizer, scanner, project index, linter, completion, snippets
swift run VimKitChecks            # Vim engine: motions, operators, text objects, ex commands, fuzzing
swift run EditorKitChecks         # headless NSTextView editing behaviour (no window needed)
swift run TeXToolchainChecks      # log parser, shadow workspace, process runner + real compiles
```

Notes:

- `TeXToolchainChecks` also compiles real documents, so it expects a MacTeX install in `/Library/TeX/texbin` and
  takes a minute. `--unit` runs only the suites that need no TeX installation (this is what CI runs);
  `--offline` additionally skips the ones that need the network (`tlmgr search`).
- Please add or extend a check for every behaviour you change or fix. Look at the existing `*Checks` targets for
  the style; most checks are small and table-driven.
- Never make a check install, update or remove anything on the machine (no `tlmgr install`, no `sudo`).

## Project layout

```
Sources/
  TeXCore/            pure Swift: models, tokenizer, scanner, project index, linters, statistics, completion data
  VimKit/             Vim emulation over a text-buffer protocol (no AppKit)
  TeXToolchain/       TeX detection, shadow workspace, latexmk, log parser, ChkTeX, tlmgr, SyncTeX
  EditorKit/          AppKit (TextKit 1) editor: highlighting, gutter, diagnostics, completion, Vim adapter
  PreviewKit/         PDFKit viewer: reloads, highlights, sync clicks, zoom controls, presentation windows
  GabeTeX/            the SwiftUI app: windows, workspace model, sidebar, tabs, Issues, Settings, Welcome,
                      command registry + palette + shortcuts
  CheckKit/           the assertion harness
  TeXCoreChecks/ VimKitChecks/ EditorKitChecks/ TeXToolchainChecks/   the check executables
Resources/
  en.lproj/ pt-BR.lproj/   Localizable.strings (English is the source language)
Support/                   Info.plist, AppIcon.icns
Scripts/                   build-app.sh, make-icon.swift and the release tooling
Examples/Homologia/        a small multi-file sample project
Tests/Fixtures/TeXToolchain/   real TeX logs and tiny projects used by the parser checks
Support/Screenshots/       images used by the READMEs
```

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the modules fit together and the reasoning behind the
trickier parts (shadow workspace, log parser, SyncTeX conventions).

## Conventions that matter here

These are the rules that are easy to trip over. They exist because of how the project is built.

**Swift 6, strict concurrency.**
- The package builds in Swift 6 language mode. UI modules (`EditorKit`, `PreviewKit`, `VimKit`, `GabeTeX`) are
  **MainActor by default** (`defaultIsolation(MainActor.self)`); mark helpers that must run elsewhere
  `nonisolated`.
- Pure modules (`TeXCore`, `TeXToolchain`) use `Sendable` value types and actors.
- Avoid `@unchecked Sendable` and `nonisolated(unsafe)`. If there is truly no alternative, add a comment saying why.

**No third-party dependencies.** Apple frameworks only; no SwiftPM packages.

**The editor is TextKit 1.** `LaTeXTextView` is built on an explicit `NSLayoutManager` stack. Do not touch
`NSTextView.textLayoutManager`: that would silently switch the view to TextKit 2 and break highlighting, the
gutter and diagnostics.

**No SwiftUI macros.** Their compiler plugin ships only with full Xcode, so the Command Line Tools cannot build
them. That means:
- use the module-internal **`@LocalState`** property wrapper instead of `@State`;
- write `EnvironmentKey` / `FocusedValueKey` types by hand instead of `@Entry`;
- do not use `#Preview`.

`@Observable`, `@Bindable`, `@Environment`, `@FocusState`, `@AppStorage`, `@SceneStorage`, `@FocusedValue` and
`@Namespace` all work fine.

**Every user-facing string exists in English and Brazilian Portuguese.**
- English is the source language: write the English text in code. SwiftUI literals (`Text("Compile")`,
  `Button("Save")`, `.help("…")`) localize automatically; everywhere else use `String(localized: "…")`.
- Add the Portuguese translation to `Resources/pt-BR.lproj/Localizable.strings`. The key is the English
  string; use `%@` for text and `%lld` for integers, in the same order as the English.
- Put interpolation inside the localized string (`String(localized: "Installed \(name)")`); never concatenate
  fragments. Do not localize TeX or tool output, or Vim mode names.
- If your Portuguese is shaky, say so in the pull request and the maintainer will help.

**Commands go through the registry.** Every user-invokable action (a menu item, an editor action, a Touch Bar
action) is an entry in the app's `CommandRegistry`, with a stable id, a title, a category and a default shortcut. The
menus, the Command Palette (⇧⌘P) and **Settings › Shortcuts** are all generated from it, so a command added there
shows up everywhere and is automatically rebindable. Don't hard-code a `.keyboardShortcut` on a one-off menu item:
register a command instead, and pick a default shortcut that does not collide with the existing ones.

**Correctness over convenience.**
- Lines and columns are **1-based**; columns and ranges are **UTF-16** (`NSString`) units. Handle composed
  characters, surrogate pairs and CRLF.
- No force-unwraps on data derived from files, TeX logs or user input.
- Diagnostics always refer to **project** paths, never to paths inside the shadow workspace.

**Native look.** Use system controls, materials and semantic colors; custom Liquid Glass only for floating elements
(tab pills, status capsules, the compile button, the completion popup, PDF controls). Everything must look right in
Light and Dark mode, and icon-only buttons need an accessibility label and a `.help()` tooltip.

**Housekeeping.** Doc-comment public API, keep files focused (roughly under 600 lines), and prefer modern APIs over
deprecated ones.

### Test fixtures

`Tests/Fixtures/TeXToolchain/logs` holds **real** logs produced by `make-logs.sh` on a Mac with TeX Live. Before
committing regenerated logs, replace anything personal (such as `/Users/<your-name>`) with a placeholder of
**exactly the same length**: some tools hard-wrap their output, and the parser checks depend on the line layout.

## Reporting bugs

Open an [issue](https://github.com/gabe-rbo/GabeTeX-macOS/issues) and include as much of this as you can:

- **What you did, what you expected, what happened.** Screenshots or a short screen recording help.
- **Versions:** GabeTeX (**GabeTeX › About GabeTeX**), macOS, and your TeX distribution (**Settings › TeX** shows
  the detected distribution and tools).
- **The LaTeX log.** For compile problems, open the **Issues panel** (⇧⌘M), switch to the **Log** tab and paste the
  relevant part, or attach the whole log.
- **A minimal project** that reproduces the problem: a few files, with private content removed. A zipped folder
  is perfect.
- For crashes, the crash report from **Console › Crash Reports**.

Please check the [Troubleshooting](README.md#troubleshooting) section and existing issues first.

## Suggesting features

Open an issue describing the problem you are trying to solve before writing a large pull request, so we can agree
on the direction. GabeTeX aims to stay a calm, native, fast editor for LaTeX projects, so not every feature will fit,
but good ideas often do.

## Pull request checklist

Before you open a pull request:

- [ ] `swift build` succeeds with **no new warnings**, using only the Command Line Tools.
- [ ] All the check executables pass: `TeXCoreChecks`, `VimKitChecks`, `EditorKitChecks` and
      `TeXToolchainChecks` (`--unit` if you have no MacTeX).
- [ ] New or changed behaviour is covered by a check.
- [ ] New user-facing strings are in English **and** in `Resources/pt-BR.lproj/Localizable.strings`.
- [ ] New actions are registered in the `CommandRegistry` (so they appear in the Command Palette and can be rebound).
- [ ] No third-party dependencies, no `@State` / `@Entry` / `#Preview`, no use of `textLayoutManager`.
- [ ] The UI looks right in Light and Dark mode and works with the keyboard (and with Reduce Motion, if you added
      animation).
- [ ] You did not commit build products (`.build/`, `build/`) or personal paths.
- [ ] User-visible changes are noted in [CHANGELOG.md](CHANGELOG.md) under **Unreleased**.
- [ ] The pull request describes *what* changed and *why*, and links the issue it fixes.

Keep pull requests focused: one fix or feature at a time is much easier to review. Small, well-explained changes are
merged fastest.

If you use an AI coding agent, point it at this file and [ARCHITECTURE.md](ARCHITECTURE.md), and review everything it
wrote before you submit.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
