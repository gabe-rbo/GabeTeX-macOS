import Foundation
import CheckKit
import VimKit

func registerChecks() {
    // Named registers.
    vim("\"ayw$\"ap", "|foo bar", "foo barfoo| ")
    vim("\"ayw\"byiw$\"bp", "|foo bar", "foo barfo|o")
    vim("\"ayww\"Ayw$\"ap", "|foo bar", "foo barfoo ba|r")
    vim("\"ayyj\"Ayy\"ap", "|a\nb", "a\nb\n|a\nb")
    vim("\"add\"ap", "|a\nb", "b\n|a")
    vim("\"ayiw\"aP", "|foo", "fo|ofoo")
    vim("\"qyy\"qp", "|x", "x\n|x")
    vim("\"Zyw", "|a b", "|a b")                           // upper-case register that was empty
    vim("\"1yw", "|a b", "|a b")

    // Unnamed, yank (0) and delete (1-9, -) registers.
    vim("dwP", "|foo bar", "foo| bar")
    vim("yiwwdiw\"0P", "|foo bar", "foofo|o ")
    vim("yiwwdiwP", "|foo bar", "fooba|r ")
    vim("dddd\"2p", "|a\nb\nc\nd", "c\n|a\nd")
    vim("dddd\"1p", "|a\nb\nc\nd", "c\n|b\nd")
    vim("x\"-p", "|abc", "b|ac")
    vim("dddw\"1P", "|a\nb c", "|a\nc")                   // small deletes do not shift the numbered registers
    vim("yyjdd\"0P", "|a\nb\nc", "a\n|a\nc")
    vim("dw\"_dwP", "|a b c", "a| c")
    vim("yy\"_ddp", "|a\nb", "b\n|a")
    vim("dd\"_ddp", "|a\nb\nc", "c\n|a")
    vim("\"_xp", "|ab", "|b")                             // nothing in the unnamed register after a black-hole delete
    vim("\"add\"bdd\"ap\"bp", "|a\nb\nc", "c\na\n|b")

    // Last inserted text, last ex command and last search pattern.
    vim("ixy<Esc>\".p", "|ab", "xyx|yab")
    vim(":s/a/b/<CR>\":p", "|a", "bs/a/b|/")
    vim("/b<CR>\"/P", "|abc", "a|bbc")

    // Clipboard integration.
    var s = VimSession("|foo bar")
    s.feed("yy")
    Check.equal(s.clipboardWrites.last, "foo bar\n", "yanks go to the clipboard")
    s = VimSession("|foo bar")
    s.feed("yiw")
    Check.equal(s.clipboard, "foo", "yiw writes the clipboard")
    s = VimSession("|foo bar")
    s.feed("\"ayiw")
    Check.expect(s.clipboardWrites.isEmpty, "a named register does not touch the clipboard")
    s = VimSession("|foo bar")
    s.feed("\"+yiw$\"+p")
    Check.equal(s.text, "foo barfoo", "\"+ yank and put")
    s = VimSession("|a")
    s.clipboard = "ext"
    s.feed("p")
    Check.equal(s.marked, "aex|t", "p pastes text copied elsewhere")
    s = VimSession("|a")
    s.clipboard = "line\n"
    s.feed("p")
    Check.equal(s.marked, "a\n|line", "clipboard text ending in a line break is linewise")
    s = VimSession("|a b")
    s.feed("yiw")
    s.clipboard = "other"
    s.feed("$p")
    Check.equal(s.text, "a bother", "text copied elsewhere wins over the last yank")
    s = VimSession("|a b")
    s.feed("yiw$p")
    Check.equal(s.text, "a ba", "an unchanged clipboard keeps the engine register (and its linewise flag)")
    s = VimSession("|foo\nbar")
    s.feed("yyjp")
    Check.equal(s.text, "foo\nbar\nfoo", "linewise yank survives the clipboard round trip")
    s = VimSession("|foo bar")
    s.engine.clipboardUnnamed = false
    s.feed("yiw")
    Check.expect(s.clipboardWrites.isEmpty, "clipboardUnnamed = false")
    s = VimSession("|foo bar")
    s.feed("dw")
    Check.expect(s.clipboardWrites.isEmpty, "deletes stay out of the clipboard by default")
    s = VimSession("|foo bar")
    s.engine.mirrorDeletesToClipboard = true
    s.feed("dw")
    Check.equal(s.clipboard, "foo ", "mirrorDeletesToClipboard")
    s = VimSession("|foo bar")
    s.clipboard = "zzz"
    s.feed("\"+P")
    Check.equal(s.text, "zzzfoo bar", "\"+P reads the clipboard")
}
