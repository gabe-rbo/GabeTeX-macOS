import Foundation
import CheckKit
import VimKit

// Checks for VimKit — owned by the VimKit agent. Run: swift run VimKitChecks
//
// Keys use Vim notation ("d2w", "ci{", "<Esc>", "<C-r>", ":s/a/b/g<CR>"); texts mark the cursor with `|`
// (it sits before the character the block cursor covers). See Harness.swift.

await Check.suite("hjkl and line motions") {
    hjklChecks()
    lineMotionChecks()
}
await Check.suite("word, file and find motions") {
    wordMotionChecks()
    fileMotionChecks()
    findMotionChecks()
}
await Check.suite("screen motions and marks") {
    screenMotionChecks()
    markChecks()
}
await Check.suite("delete / change / yank operators") {
    deleteOperatorChecks()
    changeOperatorChecks()
    yankOperatorChecks()
}
await Check.suite("shift and case operators, counts") {
    shiftOperatorChecks()
    caseOperatorChecks()
    countChecks()
}
await Check.suite("x X s S D C Y r ~ J") {
    simpleEditChecks()
}
await Check.suite("put") {
    putChecks()
}
await Check.suite("undo and redo") {
    undoRedoChecks()
}
await Check.suite("dot repeat") {
    dotRepeatChecks()
}
await Check.suite("insert and replace mode") {
    insertModeChecks()
}
await Check.suite("word and paragraph text objects") {
    wordObjectChecks()
    paragraphObjectChecks()
}
await Check.suite("bracket and quote text objects") {
    bracketObjectChecks()
    quoteObjectChecks()
}
await Check.suite("LaTeX text objects") {
    mathObjectChecks()
    environmentObjectChecks()
}
await Check.suite("visual mode") {
    visualChecks()
}
await Check.suite("registers and clipboard") {
    registerChecks()
}
await Check.suite("ex commands") {
    exCommandChecks()
}
await Check.suite("search") {
    searchChecks()
}
await Check.suite("unicode") {
    unicodeChecks()
}
await Check.suite("state, modes and configuration") {
    stateChecks()
}
await Check.suite("fuzz: cursor invariants, no crashes") {
    fuzzChecks()
}

Check.finish()
