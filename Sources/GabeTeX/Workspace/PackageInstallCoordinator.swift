import Foundation
import Observation
import TeXToolchain

/// Drives the “missing package” flow: banner → find providing packages → (choose) → install → recompile.
@Observable
final class PackageInstallCoordinator {
    enum Phase: Equatable {
        case idle
        /// Banner: “tikz-cd.sty” is not installed.  [Install] [Dismiss]
        case offer(files: [String])
        case searching(file: String)
        case choose(file: String, candidates: [String])
        case installing(packages: [String])
        /// tlmgr itself is outdated.  [Update] [Dismiss]
        case needsManagerUpdate
        case updatingManager
    }

    private(set) var phase: Phase = .idle

    /// Provides the package manager for the current distribution (nil when no TeX was found).
    @ObservationIgnored var managerProvider: () async -> TeXPackageManager? = { nil }
    /// Called after packages were installed (the workspace recompiles).
    @ObservationIgnored var onInstalled: () -> Void = {}
    /// Called with (title, message) for failures that need an alert.
    @ObservationIgnored var onFailure: (String, String) -> Void = { _, _ in }

    @ObservationIgnored private var dismissedFiles: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var choiceContinuation: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var lastOffered: [String] = []

    /// File extensions that TeX Live packages provide (anything else is a project problem).
    private static let packageExtensions: Set<String> = [
        "sty", "cls", "def", "fd", "cfg", "clo", "bst", "bbx", "cbx", "lbx", "ldf", "tfm", "enc", "map", "mf", "pfb"
    ]

    static func isPackageFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".code.tex") { return true }
        return packageExtensions.contains((lower as NSString).pathExtension)
    }

    var isBusy: Bool {
        switch phase {
        case .searching, .installing, .updatingManager: true
        default: false
        }
    }

    /// Called after every compile with `CompileResult.missingFiles`.
    func noteMissing(_ files: [String]) async {
        if isBusy { return }
        if case .choose = phase { return }
        let candidates = files.filter { Self.isPackageFile($0) && !dismissedFiles.contains($0) }
        guard !candidates.isEmpty else {
            if case .offer = phase { phase = .idle }
            return
        }
        var needed: [String] = []
        if let manager = await managerProvider() {
            for file in candidates {
                let installed = await manager.isInstalled(file: file)
                if !installed { needed.append(file) }
            }
        } else {
            needed = candidates
        }
        if isBusy { return }
        if needed.isEmpty {
            if case .offer = phase { phase = .idle }
        } else {
            lastOffered = needed
            phase = .offer(files: needed)
        }
    }

    func dismiss() {
        task?.cancel()
        choiceContinuation?.resume(returning: nil)
        choiceContinuation = nil
        switch phase {
        case .offer(let files): dismissedFiles.formUnion(files)
        default: dismissedFiles.formUnion(lastOffered)
        }
        phase = .idle
    }

    /// The user picked one of several candidate packages.
    func choose(_ package: String) {
        choiceContinuation?.resume(returning: package)
        choiceContinuation = nil
    }

    // MARK: Install

    func install() {
        guard case .offer(let files) = phase, task == nil else { return }
        task = Task { [weak self] in
            await self?.runInstall(files: files)
            self?.task = nil
        }
    }

    private func runInstall(files: [String]) async {
        guard let manager = await managerProvider() else {
            onFailure(String(localized: "TeX not found"), String(localized: "No TeX distribution was found, so packages cannot be installed."))
            phase = .offer(files: files)
            return
        }
        var packages: [String] = []
        for file in files {
            phase = .searching(file: file)
            let found: [String]
            do {
                found = try await manager.packages(providing: file)
            } catch {
                if Task.isCancelled { return }
                fail(error, files: files)
                return
            }
            if Task.isCancelled { return }
            guard let first = found.first else {
                onFailure(String(localized: "Package not found"), String(localized: "No TeX Live package provides “\(file)”."))
                phase = .offer(files: files)
                return
            }
            let stem = ((file as NSString).deletingPathExtension).lowercased()
            if found.count == 1 || first.lowercased() == stem {
                if !packages.contains(first) { packages.append(first) }
            } else {
                phase = .choose(file: file, candidates: found)
                let picked: String? = await withCheckedContinuation { continuation in
                    choiceContinuation = continuation
                }
                guard let picked else { return }   // dismissed
                if !packages.contains(picked) { packages.append(picked) }
            }
        }
        phase = .installing(packages: packages)
        do {
            _ = try await manager.install(packages)
            if Task.isCancelled { return }
            phase = .idle
            onInstalled()
        } catch {
            if Task.isCancelled { return }
            fail(error, files: files)
        }
    }

    private func fail(_ error: Error, files: [String]) {
        guard let managerError = error as? PackageManagerError else {
            onFailure(String(localized: "Installation failed"), error.localizedDescription)
            phase = .offer(files: files)
            return
        }
        switch managerError {
        case .userCancelledAuthorization:
            phase = .offer(files: files)
        case .tlmgrNeedsUpdate:
            phase = .needsManagerUpdate
        case .distributionFrozen(let message):
            onFailure(
                String(localized: "TeX Live is out of date"),
                String(localized: "\(message)\n\nThe package repository now belongs to a newer TeX Live release. Install the latest MacTeX to get new packages.")
            )
            phase = .offer(files: files)
        case .notFoundInRepository(let file):
            onFailure(String(localized: "Package not found"), String(localized: "No TeX Live package provides “\(file)”."))
            phase = .offer(files: files)
        case .tlmgrNotFound:
            onFailure(String(localized: "tlmgr not found"), managerError.localizedDescription)
            phase = .offer(files: files)
        case .failed(let message):
            onFailure(String(localized: "Installation failed"), message)
            phase = .offer(files: files)
        }
    }

    /// `tlmgr update --self`, then back to the offer so the user can retry.
    func updateManager() {
        guard case .needsManagerUpdate = phase, task == nil else { return }
        let files = lastOffered
        task = Task { [weak self] in
            guard let self else { return }
            self.phase = .updatingManager
            do {
                guard let manager = await self.managerProvider() else { self.phase = .offer(files: files); self.task = nil; return }
                _ = try await manager.updateManager()
                self.phase = .offer(files: files)
            } catch {
                if let e = error as? PackageManagerError, case .userCancelledAuthorization = e {
                    self.phase = .needsManagerUpdate
                } else {
                    self.onFailure(String(localized: "Update failed"), error.localizedDescription)
                    self.phase = .needsManagerUpdate
                }
            }
            self.task = nil
        }
    }
}
