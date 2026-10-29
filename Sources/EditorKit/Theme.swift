import AppKit
import TeXCore

/// The editor's color palette. Every color is a dynamic `NSColor` that resolves against the drawing
/// appearance, so Light/Dark (and increased contrast) switch without re-applying any attribute.
///
/// The syntax palette is deliberately calm: hues are muted in Light mode and softened in Dark mode so
/// that prose stays the most prominent thing on the page.
public enum EditorTheme {
    // MARK: Syntax

    /// `\commands` outside math.
    public static let command = dynamic(light: 0x7A3E9D, dark: 0xC79BEA)
    /// Sectioning, `\begin`/`\end`, `\documentclass`, `\usepackage` … (accent blue).
    public static let structure = dynamic(light: 0x1D5FC2, dark: 0x6EB2FF)
    /// Environment names inside `\begin{…}` / `\end{…}`.
    public static let environmentName = dynamic(light: 0x0B7A75, dark: 0x5FD3C4)
    /// Math content.
    public static let math = dynamic(light: 0x2E7D32, dark: 0x93D08A)
    /// Commands inside math.
    public static let mathCommand = dynamic(light: 0x1F6B2E, dark: 0x7CC98B)
    /// `$`, `\(`, `\[` …
    public static let mathDelimiter = dynamic(light: 0x3C8D40, dark: 0xA6DB9C)
    /// `\label`/`\ref`/`\cite`/`\input` arguments.
    public static let reference = dynamic(light: 0x4A4FC4, dark: 0xA7ABFF)
    /// `% comments`.
    public static let comment = NSColor.secondaryLabelColor
    /// `% !TEX` magic comments.
    public static let magicComment = dynamic(light: 0x5F6B7A, dark: 0x9AA7B8)
    /// `{ }`.
    public static let brace = NSColor.tertiaryLabelColor
    /// `[ ]` after commands.
    public static let bracket = NSColor.tertiaryLabelColor
    /// `& ~ ^ _ #`.
    public static let specialCharacter = dynamic(light: 0xA8445A, dark: 0xF0919F)
    /// Verbatim bodies.
    public static let verbatim = dynamic(light: 0xA85A00, dark: 0xF5B36B)
    /// Ordinary text.
    public static let text = NSColor.textColor

    /// The color used for a token class.
    public static func color(for kind: LaTeXTokenKind) -> NSColor {
        switch kind {
        case .command: command
        case .structureCommand: structure
        case .environmentName: environmentName
        case .mathDelimiter: mathDelimiter
        case .math: math
        case .mathCommand: mathCommand
        case .comment: comment
        case .magicComment: magicComment
        case .brace: brace
        case .bracket: bracket
        case .specialCharacter: specialCharacter
        case .verbatim: verbatim
        case .referenceArgument: reference
        }
    }

    // MARK: Diagnostics

    /// Underline / marker color for a severity: errors red, warnings orange, info & bad boxes subtle.
    public static func color(for severity: DiagnosticSeverity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemOrange
        case .badbox: dynamic(light: 0x8E8E93, dark: 0x98989D)
        case .info: dynamic(light: 0x8E8E93, dark: 0x98989D)
        }
    }

    /// SF Symbol name for a severity.
    public static func symbolName(for severity: DiagnosticSeverity) -> String {
        switch severity {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .badbox: "rectangle.compress.vertical"
        case .info: "info.circle.fill"
        }
    }

    // MARK: Chrome

    /// Current-line band behind the text and in the gutter.
    public static let currentLine = NSColor(name: "GabeTeX.currentLine") { appearance in
        if appearance.isDark {
            return NSColor(white: 1, alpha: appearance.isHighContrast ? 0.10 : 0.055)
        }
        return NSColor(white: 0, alpha: appearance.isHighContrast ? 0.08 : 0.04)
    }
    /// Line numbers.
    public static let lineNumber = NSColor.tertiaryLabelColor
    /// Line number of the line(s) holding the selection.
    public static let currentLineNumber = NSColor.secondaryLabelColor
    /// Hairline between gutter and text.
    public static let gutterSeparator = NSColor(name: "GabeTeX.gutterSeparator") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.06)
    }
    /// Background of inactive snippet tab stops.
    public static let snippetPlaceholder = NSColor(name: "GabeTeX.snippetPlaceholder") { appearance in
        NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.22 : 0.14)
    }
    /// The soft accent-colored highlight behind a range the editor just jumped to (SyncTeX, navigation,
    /// `EditorController.reveal`). `intensity` (0…1) scales the alpha while the highlight fades out; the
    /// result is a dynamic color, so Light/Dark and increased contrast resolve at draw time.
    public static func revealFlash(intensity: Double) -> NSColor {
        let level = CGFloat(max(0, min(1, intensity)))
        return NSColor(name: nil) { appearance in
            let peak: CGFloat = switch (appearance.isDark, appearance.isHighContrast) {
            case (false, false): 0.26
            case (true, false): 0.36
            case (false, true): 0.42
            case (true, true): 0.52
            }
            return NSColor.controlAccentColor.withAlphaComponent(peak * level)
        }
    }

    /// The block caret of Vim normal mode.
    public static let blockCaret = NSColor(name: "GabeTeX.blockCaret") { appearance in
        NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.55 : 0.40)
    }

    // MARK: Helpers

    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(rgb: dark) : NSColor(rgb: light)
        }
    }
}

extension NSAppearance {
    nonisolated var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                         .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                         .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                    .accessibilityHighContrastVibrantDark].contains($0) } ?? false
    }

    nonisolated var isHighContrast: Bool {
        bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .accessibilityHighContrastAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}

extension NSColor {
    nonisolated convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
