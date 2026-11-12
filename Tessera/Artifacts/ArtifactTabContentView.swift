import SwiftUI
import TesseraArtifactsCore

@MainActor
struct ArtifactTabContentView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.openArtifact) private var openArtifact
    let store: any ArtifactsBrowserStore
    let tab: ArtifactTab
    let webModel: ArtifactWebViewModel?
    let onRefresh: () -> Void
    @State private var linkFailure: LinkFailure?

    /// Each failure restarts its banner's timer, even with the same text.
    private struct LinkFailure: Equatable {
        let text: String
        let id = UUID()
    }

    var body: some View {
        VStack(spacing: 0) {
            cacheBanner
            if let linkFailure {
                banner(symbol: "link", text: linkFailure.text)
                    .task(id: linkFailure) {
                        try? await Task.sleep(for: .seconds(4))
                        if !Task.isCancelled { self.linkFailure = nil }
                    }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(T.presentationBg)
        .accessibilityIdentifier("artifacts-content")
        .onChange(of: tab.id) { linkFailure = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch store.content(for: tab.id) {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().tint(T.fgMuted)
                Text("loading artifact")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            }
        case let .document(localURL, title, reloadToken, prepareImages):
            ArtifactDocumentView(localURL: localURL, title: title, prepareImages: prepareImages, reloadToken: reloadToken)
                .environment(\.openURL, OpenURLAction(handler: openDocumentLink))
        case .servedPage:
            page
        case let .forwardedPage(_, ruleLabel, isEphemeral):
            VStack(spacing: 0) {
                forwardBanner(ruleLabel: ruleLabel, isEphemeral: isEphemeral)
                page
            }
        case let .change(path, diff):
            ArtifactDiffView(path: path, diff: diff)
        case let .unavailable(reason):
            unavailable(reason)
        }
    }

    /// A document's links are its host's, as a browser reads a link in a
    /// file it shows: its paths and localhost pages open as tabs, and only
    /// the internet or a mail address leaves for the device. Markdown
    /// resolves a relative link against the cached copy, so the link is
    /// read as written.
    private func openDocumentLink(_ url: URL) -> OpenURLAction.Result {
        guard case let .file(documentPath) = tab.target else { return .discarded }
        let home = store.quickOpenHosts.first { $0.id == tab.hostID }?.home
        let target: ArtifactOpenRequest.Target
        switch ArtifactsDocumentLinks.resolve(url.relativeString, documentPath: documentPath, home: home) {
        case let .file(path): target = .file(path: path)
        case let .page(scheme, port, path): target = .page(scheme: scheme, port: Int(port), path: path)
        case .external: return .systemAction
        case .ignored: return .discarded
        case .refused: return failedLink()
        }
        guard let openArtifact, let hostID = UUID(uuidString: tab.hostID) else { return failedLink() }
        linkFailure = nil
        openArtifact(ArtifactOpenRequest(
            hostID: hostID, target: target, origin: .documentLink,
            sessionID: tab.sessionHint.flatMap { UUID(uuidString: $0) }
        ))
        return .handled
    }

    private func failedLink() -> OpenURLAction.Result {
        linkFailure = LinkFailure(text: String(localized: "this link could not be opened"))
        return .discarded
    }

    @ViewBuilder
    private var page: some View {
        if let webModel {
            ArtifactWebView(model: webModel, showsControls: false) { title in
                store.titleLearned(tab.id, title)
            }
        } else {
            ProgressView().tint(T.fgMuted)
        }
    }

    @ViewBuilder
    private var cacheBanner: some View {
        let presentation = store.presentation(for: tab.id)
        if case .document = store.content(for: tab.id) {
            if presentation.state == .cached, let reconnect = store.filesReconnect(for: tab.id) {
                // The host's terminal is connected; only Files is not.
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "clock").accessibilityHidden(true)
                    Text(verbatim: reconnectBannerText(reconnect))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    reconnectControl(reconnect, label: "refresh")
                }
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgMuted)
                .padding(.horizontal, 12)
                .artifactsChromeSurface()
            } else if presentation.state == .cached {
                banner(symbol: "clock", text: String(localized: "\(tab.hostLabel) is offline; viewing the cached copy"))
            } else if presentation.state == .stale {
                let reconnect = store.filesReconnect(for: tab.id)
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark").accessibilityHidden(true)
                    if case let .failed(message)? = reconnect {
                        Text(verbatim: message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("this copy is stale; the host has a newer version")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if presentation.canRefresh {
                        bannerButton("refresh", minWidth: 60, action: onRefresh)
                    } else if let reconnect {
                        reconnectControl(reconnect, label: "refresh")
                    }
                }
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgMuted)
                .padding(.horizontal, 12)
                .artifactsChromeSurface()
            }
        }
    }

    private func reconnectBannerText(_ reconnect: ArtifactFilesReconnect) -> String {
        if case let .failed(message) = reconnect { return message }
        return String(localized: "viewing the cached copy")
    }

    @ViewBuilder
    private func reconnectControl(_ reconnect: ArtifactFilesReconnect, label: LocalizedStringKey) -> some View {
        if reconnect == .connecting {
            ProgressView()
                .controlSize(.small)
                .tint(T.fgMuted)
                .frame(minWidth: 60, minHeight: 44)
                .accessibilityLabel("connecting")
        } else {
            bannerButton(label, minWidth: 60, action: onRefresh)
        }
    }

    /// Two lines at most, so a short pane (the laptop's upper half) keeps
    /// its page: the address bar already shows the tab title and ⇄.
    private func forwardBanner(ruleLabel: String, isEphemeral: Bool) -> some View {
        let isPlainHTTP = if case let .page(scheme, _, _) = tab.target { scheme == "http" } else { false }
        let detail = Self.forwardDetail(ruleLabel: ruleLabel, tabTitle: tab.title, isPlainHTTP: isPlainHTTP)
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.left.arrow.right").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if isEphemeral { Text("forwarded for this tab until it closes") }
                else { Text("forwarded by a saved rule") }
                if !detail.isEmpty { Text(verbatim: detail).foregroundStyle(T.fgDim) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            if store.canKeepAsRule(tab.id) {
                bannerButton("keep as a rule") { store.keepAsRule(tab.id) }
            }
        }
        .font(Typography.tesseraMono(size: 10))
        .foregroundStyle(T.fgMuted)
        .padding(.horizontal, 12)
        .artifactsChromeSurface()
    }

    /// The banner's dim line: the rule's own name, unless it only repeats the
    /// tab title, then the tunnel's note for a plain http page.
    nonisolated static func forwardDetail(ruleLabel: String, tabTitle: String, isPlainHTTP: Bool) -> String {
        var parts: [String] = []
        if !ruleLabel.isEmpty, ruleLabel != tabTitle { parts.append(ruleLabel) }
        if isPlainHTTP { parts.append(String(localized: "the SSH tunnel encrypts this connection")) }
        return parts.joined(separator: " · ")
    }

    /// A text button whose whole 44 pt frame takes the tap; a frame outside
    /// the button would grow the layout but not the hit area.
    private func bannerButton(_ label: LocalizedStringKey, minWidth: CGFloat = 44, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .frame(minWidth: minWidth, minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private func banner(symbol: String, text: String) -> some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: symbol) }
            .font(Typography.tesseraMono(size: 10))
            .foregroundStyle(T.fgMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .artifactsChromeSurface()
    }

    private func unavailable(_ reason: ArtifactUnavailable) -> some View {
        let message = unavailableMessage(reason)
        return ScrollView {
            VStack(spacing: 14) {
                Image(systemName: message.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(T.fgDim)
                Text(verbatim: message.title)
                    .font(Typography.tesseraMono(size: 16, weight: .medium))
                    .foregroundStyle(T.fg)
                Text(verbatim: message.detail)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if reason == .offline || reason == .noForwarding, let reconnect = store.filesReconnect(for: tab.id) {
                    reconnectControl(reconnect, label: "load")
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                } else if store.canRetry(tab.id) {
                    bannerButton("retry", minWidth: 60, action: onRefresh)
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                }
            }
            .padding(28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func unavailableMessage(_ reason: ArtifactUnavailable) -> (symbol: String, title: String, detail: String) {
        switch reason {
        case .offline:
            if let reconnect = store.filesReconnect(for: tab.id) {
                if case let .failed(message) = reconnect {
                    return ("exclamationmark.circle", String(localized: "could not load this artifact"), message)
                }
                return ("arrow.down.circle", String(localized: "not loaded"),
                        String(localized: "\(tab.hostLabel) is connected; load opens its Files connection"))
            }
            return ("bolt.slash", String(localized: "offline"),
                    String(localized: "connect a session to \(tab.hostLabel) to load it"))
        case .noForwarding:
            if let reconnect = store.filesReconnect(for: tab.id) {
                if case let .failed(message) = reconnect {
                    return ("exclamationmark.circle", String(localized: "could not load this artifact"), message)
                }
                return ("arrow.left.arrow.right", String(localized: "no page connection"),
                        String(localized: "\(tab.hostLabel) is connected; load opens its Files connection"))
            }
            return ("arrow.left.arrow.right", String(localized: "no page connection"),
                    String(localized: "pages on mosh hosts open while Files or an ssh session is connected"))
        case let .tooLarge(bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return ("doc", String(localized: "too large to preview"),
                    String(localized: "this file is \(size); open a smaller file to preview it here"))
        case .missing:
            return ("doc.badge.ellipsis", String(localized: "file not found"),
                    String(localized: "this file is no longer at \(tab.target.path)"))
        case let .failed(message):
            return ("exclamationmark.circle", String(localized: "could not load this artifact"), message)
        }
    }
}
