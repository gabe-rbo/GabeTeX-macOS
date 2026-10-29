import Foundation
import Observation
import TeXToolchain

/// App-wide view of the detected TeX distribution (shared by every project window and Settings).
@Observable
final class ToolchainModel {
    static let shared = ToolchainModel()

    private(set) var distribution: TeXDistribution?
    /// Every installation found (for the Settings pane).
    private(set) var candidates: [TeXDistribution] = []
    /// True once the first detection has finished.
    private(set) var hasLocated = false
    private(set) var isLocating = false
    /// Increments whenever the detection result is replaced, so owners can rebuild their tools.
    private(set) var generation = 0

    @ObservationIgnored private var sharedCompiler: LaTeXCompiler?
    @ObservationIgnored private var sharedCompilerGeneration = -1
    @ObservationIgnored private var locateTask: Task<Void, Never>?
    @ObservationIgnored private var serial = 0

    /// The one `LaTeXCompiler` of the current distribution, shared by all project windows (it serializes
    /// compiles per project itself). Nil when no TeX was found.
    func compiler() async -> LaTeXCompiler? {
        await ensureLocated()
        guard let distribution else { return nil }
        if sharedCompiler == nil || sharedCompilerGeneration != generation {
            sharedCompiler = LaTeXCompiler(distribution: distribution)
            sharedCompilerGeneration = generation
        }
        return sharedCompiler
    }

    /// Waits for the first detection (starting it if needed).
    func ensureLocated() async {
        if hasLocated { return }
        if let locateTask {
            await locateTask.value
            return
        }
        await relocate()
    }

    /// Runs detection again, honouring the custom bin directory from the settings.
    func relocate() async {
        serial += 1
        let mine = serial
        let custom = AppSettings.shared.customBinURL
        isLocating = true
        let task = Task { [weak self] in
            let found = await TeXDistributionLocator.locate(customBinDirectory: custom)
            let all = await TeXDistributionLocator.candidates()
            guard let self, self.serial == mine else { return }
            self.distribution = found
            self.candidates = all
            self.hasLocated = true
            self.isLocating = false
            self.generation += 1
            self.locateTask = nil
        }
        locateTask = task
        await task.value
    }
}
