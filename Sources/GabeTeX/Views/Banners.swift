import SwiftUI
import TeXToolchain

/// Glass banners above the editor: no TeX found, missing package, file changed on disk.
struct BannerStack: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(ToolchainModel.self) private var toolchain

    var body: some View {
        let externalURLs = workspace.externalChanges.keys.sorted { $0.path < $1.path }
        let encodingURLs = workspace.encodingProblems.keys.sorted { $0.path < $1.path }
        VStack(spacing: 8) {
            if toolchain.hasLocated && toolchain.distribution == nil {
                NoTeXBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if workspace.packages.phase != .idle {
                PackageBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ForEach(externalURLs, id: \.self) { url in
                if let change = workspace.externalChanges[url] {
                    ExternalChangeBanner(url: url, change: change)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            ForEach(encodingURLs, id: \.self) { url in
                EncodingBanner(url: url)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, bannerPadding(externalURLs.count + encodingURLs.count))
        .animation(.smooth(duration: 0.25), value: workspace.packages.phase)
        .animation(.smooth(duration: 0.25), value: externalURLs)
        .animation(.smooth(duration: 0.25), value: encodingURLs)
        .animation(.smooth(duration: 0.25), value: toolchain.hasLocated)
    }

    private func bannerPadding(_ externalCount: Int) -> CGFloat {
        let visible = (toolchain.hasLocated && toolchain.distribution == nil) || workspace.packages.phase != .idle || externalCount > 0
        return visible ? 4 : 0
    }
}

/// Shared look of a banner: icon, text, trailing actions.
private struct BannerShell<Actions: View>: View {
    let symbol: String
    let tint: Color
    let message: Text
    let detail: Text?
    let showsProgress: Bool
    let actions: Actions

    init(
        symbol: String,
        tint: Color,
        message: Text,
        detail: Text? = nil,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.message = message
        self.detail = detail
        self.showsProgress = showsProgress
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                message.font(.system(size: 12, weight: .semibold))
                if let detail {
                    detail.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

private struct NoTeXBanner: View {
    var body: some View {
        BannerShell(
            symbol: "exclamationmark.triangle.fill",
            tint: .orange,
            message: Text("No TeX distribution was found"),
            detail: Text("Install MacTeX to compile documents, or choose a custom TeX folder in Settings.")
        ) {
            Button("Get MacTeX") {
                if let url = URL(string: "https://tug.org/mactex/") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.glassProminent)
            SettingsLink {
                Text("Open Settings")
            }
            .buttonStyle(.glass)
        }
    }
}

private struct PackageBanner: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(ToolchainModel.self) private var toolchain

    private var installer: PackageInstallCoordinator { workspace.packages }
    private var needsAdmin: Bool { toolchain.distribution.map { !$0.isUserWritable } ?? false }

    var body: some View {
        switch installer.phase {
        case .idle:
            EmptyView()
        case .offer(let files):
            BannerShell(
                symbol: "shippingbox.fill",
                tint: .blue,
                message: offerMessage(files),
                detail: needsAdmin ? Text("Installing needs your administrator password.") : nil
            ) {
                Button("Dismiss") { installer.dismiss() }
                    .buttonStyle(.glass)
                Button {
                    installer.install()
                } label: {
                    if needsAdmin { Text("Install…") } else { Text("Install") }
                }
                .buttonStyle(.glassProminent)
            }
        case .searching(let file):
            BannerShell(symbol: "magnifyingglass", tint: .blue, message: Text("Looking for a package that provides “\(file)”…"), showsProgress: true) {
                Button("Cancel") { installer.dismiss() }.buttonStyle(.glass)
            }
        case .choose(let file, let candidates):
            BannerShell(symbol: "shippingbox.fill", tint: .blue, message: Text("Several packages provide “\(file)”"), detail: Text("Choose the one to install.")) {
                Button("Cancel") { installer.dismiss() }
                    .buttonStyle(.glass)
                Menu("Choose Package") {
                    ForEach(candidates.prefix(12), id: \.self) { name in
                        Button(name) { installer.choose(name) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.glassProminent)
            }
        case .installing(let packages):
            BannerShell(
                symbol: "arrow.down.circle",
                tint: .blue,
                message: Text("Installing \(ListFormatter.localizedString(byJoining: packages))…"),
                detail: Text("This can take a minute."),
                showsProgress: true
            ) { EmptyView() }
        case .needsManagerUpdate:
            BannerShell(
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                tint: .orange,
                message: Text("The TeX Live manager needs to be updated first"),
                detail: Text("tlmgr must be updated before it can install packages.")
            ) {
                Button("Dismiss") { installer.dismiss() }.buttonStyle(.glass)
                Button("Update") { installer.updateManager() }.buttonStyle(.glassProminent)
            }
        case .updatingManager:
            BannerShell(symbol: "arrow.triangle.2.circlepath", tint: .blue, message: Text("Updating the TeX Live manager…"), showsProgress: true) { EmptyView() }
        }
    }

    private func offerMessage(_ files: [String]) -> Text {
        if files.count == 1, let file = files.first {
            return Text("“\(file)” is not installed")
        }
        let first = files.first ?? ""
        return Text("“\(first)” and \(files.count - 1) more files are not installed")
    }
}

private struct ExternalChangeBanner: View {
    @Environment(ProjectWorkspace.self) private var workspace
    let url: URL
    let change: ProjectWorkspace.ExternalChange

    var body: some View {
        switch change {
        case .modified:
            BannerShell(
                symbol: "arrow.triangle.2.circlepath",
                tint: .orange,
                message: Text("“\(url.lastPathComponent)” changed on disk"),
                detail: Text("You also have unsaved changes in the editor.")
            ) {
                Button("Keep Mine") { workspace.keepMine(url) }.buttonStyle(.glass)
                Button("Reload") { workspace.reloadFromDisk(url) }.buttonStyle(.glassProminent)
            }
        case .deleted:
            BannerShell(
                symbol: "trash",
                tint: .red,
                message: Text("“\(url.lastPathComponent)” was deleted from disk"),
                detail: Text("Saving will create the file again.")
            ) {
                Button("Close Tab") { workspace.closeTab(url, force: true) }.buttonStyle(.glass)
                Button("Keep Mine") { workspace.keepMine(url) }.buttonStyle(.glassProminent)
            }
        }
    }
}

/// The file was not valid UTF-8: it was repaired in memory. Offers the usual way out for legacy files.
private struct EncodingBanner: View {
    @Environment(ProjectWorkspace.self) private var workspace
    let url: URL

    var body: some View {
        BannerShell(
            symbol: "textformat.abc",
            tint: .orange,
            message: Text("“\(url.lastPathComponent)” is not valid UTF-8"),
            detail: Text("Some bytes could not be read as UTF-8 and were replaced. Saving writes the file as UTF-8; if this is an older file, reopen it as Latin-1.")
        ) {
            Button("Keep UTF-8") { workspace.keepUTF8(url) }.buttonStyle(.glass)
            Button("Reopen as Latin-1") { workspace.reopenAsLatin1(url) }.buttonStyle(.glassProminent)
        }
    }
}
