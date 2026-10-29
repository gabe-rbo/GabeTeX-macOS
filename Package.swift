// swift-tools-version: 6.2
//
// GabeTeX — a native macOS LaTeX editor.
// Built with the Command Line Tools only (no Xcode project): `make app` assembles GabeTeX.app.
//
import PackageDescription

/// UI-facing modules run on the main actor by default (SE-0466).
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "GabeTeX",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "GabeTeX", targets: ["GabeTeX"]),
    ],
    targets: [
        // ── Pure logic (no AppKit) ───────────────────────────────────────────
        /// Shared models, LaTeX tokenizer, project scanning (includes, outline, labels, bib), completion.
        .target(name: "TeXCore"),
        /// Vim emulation state machine, independent of AppKit (operates on `VimTextBuffer`).
        .target(name: "VimKit", swiftSettings: mainActorByDefault),
        /// TeX distribution detection, compilation (latexmk), log parsing, chktex, tlmgr, SyncTeX.
        .target(name: "TeXToolchain", dependencies: ["TeXCore"]),

        // ── UI ──────────────────────────────────────────────────────────────
        /// NSTextView-based LaTeX editor (highlighting, gutter, diagnostics, completion, Vim adapter).
        .target(name: "EditorKit", dependencies: ["TeXCore", "VimKit"], swiftSettings: mainActorByDefault),
        /// PDFKit preview with state-preserving reloads and SyncTeX highlights.
        .target(name: "PreviewKit", swiftSettings: mainActorByDefault),
        /// The SwiftUI application.
        .executableTarget(
            name: "GabeTeX",
            dependencies: ["TeXCore", "VimKit", "TeXToolchain", "EditorKit", "PreviewKit"],
            swiftSettings: mainActorByDefault
        ),

        // ── Checks (XCTest/swift-testing are unavailable without full Xcode) ─
        .target(name: "CheckKit"),
        .executableTarget(name: "TeXCoreChecks", dependencies: ["TeXCore", "CheckKit"]),
        .executableTarget(name: "VimKitChecks", dependencies: ["VimKit", "CheckKit"], swiftSettings: mainActorByDefault),
        .executableTarget(name: "TeXToolchainChecks", dependencies: ["TeXToolchain", "CheckKit"]),
        /// Headless NSTextView checks (no window needed) for editing behaviours.
        .executableTarget(name: "EditorKitChecks", dependencies: ["EditorKit", "TeXCore", "VimKit", "CheckKit", "PreviewKit"], swiftSettings: mainActorByDefault),
    ]
)
