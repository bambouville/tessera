import SwiftUI

/// Where an artifact open came from. Sources only describe what they want
/// opened; the artifacts store decides whether that focuses an existing tab.
enum ArtifactOpenOrigin: String, Equatable, Sendable {
    case files
    case terminalSelection
    case terminalLink
    case forwarding
    case agentEdit
    case quickOpen
    case documentLink
    case palette
}

/// A request to open something as a tab in the artifacts browser.
///
/// A tab belongs to the saved host, not to the session that asked, so the
/// host is the identity and the session is only a hint: the connection a
/// page's forward tries first.
struct ArtifactOpenRequest: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// An absolute remote path.
        case file(path: String)
        /// A port on the host's own loopback, as a terminal or the forwarding
        /// chip names it; the store plans the local forward.
        case page(scheme: String, port: Int, path: String)
        /// An agent edit snapshot.
        case change(path: String, diff: String, summary: String)
    }

    var hostID: UUID
    var target: Target
    var origin: ArtifactOpenOrigin
    var sessionID: UUID?
    /// A copy the caller already downloaded, such as Files' staged preview.
    /// The store adopts it as the tab's first cached copy instead of
    /// fetching the file again.
    var stagedLocalURL: URL?
    /// A tab that already exists, such as one Quick Open just made: the
    /// open reveals it instead of matching its target, which an older tab
    /// on the same target would otherwise win.
    var tabID: String?

    init(
        hostID: UUID,
        target: Target,
        origin: ArtifactOpenOrigin,
        sessionID: UUID? = nil,
        stagedLocalURL: URL? = nil,
        tabID: String? = nil
    ) {
        self.hostID = hostID
        self.target = target
        self.origin = origin
        self.sessionID = sessionID
        self.stagedLocalURL = stagedLocalURL
        self.tabID = tabID
    }
}

/// Opens an artifact tab and shows the browser. Installed once at the app
/// root; nil where no browser exists (previews, extensions, tests).
struct OpenArtifactAction {
    let handler: @MainActor (ArtifactOpenRequest) -> Void

    @MainActor
    func callAsFunction(_ request: ArtifactOpenRequest) {
        handler(request)
    }
}

private struct OpenArtifactActionKey: EnvironmentKey {
    static let defaultValue: OpenArtifactAction? = nil
}

extension EnvironmentValues {
    var openArtifact: OpenArtifactAction? {
        get { self[OpenArtifactActionKey.self] }
        set { self[OpenArtifactActionKey.self] = newValue }
    }
}
