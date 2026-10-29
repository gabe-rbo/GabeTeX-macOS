import Foundation
import CheckKit
import TeXCore
import TeXToolchain

// Checks for TeXToolchain — owned by the TeXToolchain agent. Run: swift run TeXToolchainChecks
//   swift run TeXToolchainChecks            all suites (unit + fixtures + end-to-end on this Mac)
//   swift run TeXToolchainChecks --offline  skip the suites that need the network (tlmgr search)
//   swift run TeXToolchainChecks --unit     only pure / fixture-based suites (no TeX runs)

let arguments = Set(CommandLine.arguments.dropFirst())
await unitChecks()
await shadowSafetyChecks()
await parserChecks()
if !arguments.contains("--unit") {
    await integrationChecks(online: !arguments.contains("--offline"))
}
Check.finish()
