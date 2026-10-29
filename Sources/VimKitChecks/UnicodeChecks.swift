import Foundation
import CheckKit
import VimKit

func unicodeChecks() {
    let combining = "e\u{301}"                          // e + COMBINING ACUTE ACCENT: one character, two UTF-16 units
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"   // ZWJ sequence: one character, eight UTF-16 units
    let flag = "\u{1F1E7}\u{1F1F7}"                    // regional indicators: one character

    // Precomposed text.
    vim("lx", "|ação", "a|ão")
    vim("$", "|ação", "açã|o")
    vim("x", "aç|ão", "aç|o")
    vim("dw", "|ação você", "|você")
    vim("ciwX<Esc>", "|ação você", "|X você")
    vim("yiwP", "|ação", "açã|oação")
    vim("~", "|ação", "A|ção")
    vim("4~", "|ação", "AÇÃ|O")
    vim("gUU", "|ação", "|AÇÃO")
    vim("~", "|ß", "S|S")                                // the case mapping changes the length
    vim("fç", "|ação", "a|ção")
    vim("tã", "|ação", "a|ção")
    vim("rá", "|ação", "|áção")
    vim("ge", "ação voc|ê", "açã|o você")
    vim("b", "ação voc|ê", "ação |você")
    vim("*", "|você x você", "você x |você")

    // Surrogate pairs.
    vim("l", "|a😀b", "a|😀b")
    vim("ll", "|a😀b", "a😀|b")
    vim("lx", "|a😀b", "a|b")
    vim("h", "a😀|b", "a|😀b")
    vim("X", "a😀|b", "a|b")
    vim("x", "|😀b", "|b")
    vim("$", "a|b😀", "ab|😀")
    vim("yl$p", "|😀", "😀|😀")
    vim("ylP", "|😀", "|😀😀")
    vim("dw", "|😀 b", "|b")                              // emoji are their own character class
    vim("diw", "|a😀b", "|😀b")
    vim("daw", "|😀 b", "|b")
    vim("r😀", "|abc", "|😀bc")
    vim("3r😀", "|abc", "😀😀|😀")
    vim("f😀", "|ab😀c", "ab|😀c")
    vim("t😀", "|ab😀c", "a|b😀c")
    vim("F😀", "😀ab|c", "|😀abc")
    vim("v", "a|😀b", "a|😀b", mode: .visual)
    vim("di\"", "\"😀|\"", "\"|\"")
    vim("ci\"X<Esc>", "\"a😀|b\"", "\"|X\"")
    vim("ia😀<Esc>", "|b", "a|😀b")
    vim("A😀<Esc>", "|a", "a|😀")
    vim("R😀<Esc>", "|abc", "|😀bc")
    vim("Rab<Esc>", "|😀x", "a|b")                        // replace mode overwrites whole characters
    vim("J", "|😀\n😀", "😀| 😀")
    vim("~", "|😀", "|😀")
    vim("x", "|😀😀", "|😀")
    vim("2x", "|😀😀😀", "|😀")
    vim("dd", "|😀\nb", "|b")
    vim("/😀<CR>", "|a😀b😀", "a|😀b😀")
    vim("/😀<CR>n", "|a😀b😀", "a😀b|😀")

    // Composed characters.
    vim("l", "|\(combining)x", "\(combining)|x")
    vim("x", "|\(combining)x", "|x")
    vim("$", "|x\(combining)", "x|\(combining)")
    vim("h", "x\(combining)|y", "x|\(combining)y")
    vim("X", "x\(combining)|y", "x|y")
    vim("r.", "|\(combining)x", "|.x")
    vim("dl", "|\(combining)x", "|x")
    vim("yl$p", "|\(combining)", "\(combining)|\(combining)")
    vim("w", "|\(combining)b c", "\(combining)b |c")
    vim("~", "|\(combining)x", "\(combining.uppercased())|x")
    vim("f\(combining)", "|a\(combining)b", "a|\(combining)b")
    vim("diw", "|\(combining)b c", "| c")

    // ZWJ sequences and flags.
    vim("x", "|\(family)b", "|b")
    vim("l", "|\(family)b", "\(family)|b")
    vim("$", "a|\(family)", "a|\(family)")
    vim("x", "|\(flag)b", "|b")
    vim("l", "|\(flag)b", "\(flag)|b")
    vim("dl", "|\(flag)\(flag)", "|\(flag)")
    vim("ylp", "|\(family)", "\(family)|\(family)")
    vim("dw", "|\(family) b", "|b")

    // The cursor never rests inside a character, whatever the host selects.
    var s = VimSession("a😀b")
    s.buffer.vimSelection = NSRange(location: 2, length: 0)    // in the middle of the surrogate pair
    s.feed("x")
    Check.equal(s.text, "ab", "a click inside a surrogate pair snaps to the character")
    s = VimSession("x\(combining)y")
    s.buffer.vimSelection = NSRange(location: 2, length: 0)    // between e and the accent
    s.feed("x")
    Check.equal(s.text, "xy", "a click inside a composed character snaps to the character")
    s = VimSession("ab\r\ncd")
    s.buffer.vimSelection = NSRange(location: 3, length: 0)    // between the CR and the LF
    s.feed("x")
    Check.equal(s.text, "a\r\ncd", "a click inside a CRLF snaps back to the last character of the line")
    s = VimSession("ab\r\n\r\ncd")
    s.buffer.vimSelection = NSRange(location: 5, length: 0)    // inside the CRLF of the empty line
    s.feed("ix<Esc>")
    Check.equal(s.text, "ab\r\nx\r\ncd", "and on an empty line it snaps to the line start")
}
