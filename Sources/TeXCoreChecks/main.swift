import Foundation
import CheckKit
import TeXCore

// Checks for TeXCore — owned by the TeXCore agent. Run: swift run TeXCoreChecks
// (use `swift run -c release TeXCoreChecks` to also enforce the tokenizer's 10 ms / 100 KB budget).

await runModelChecks()
await runTokenizerChecks()
await runScannerChecks()
await runProjectIndexChecks()
await runBibChecks()
await runLinterChecks()
await runReferenceChecks()
await runSnippetChecks()
await runCompletionChecks()
await runStatisticsChecks()
await runPerformanceChecks()

Check.finish()
