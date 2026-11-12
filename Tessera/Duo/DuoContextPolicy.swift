import Foundation
import Observation
import TesseraArtifactsCore

enum DuoArtifactOpenDestination: Equatable {
    case artifacts
    case context(sessionID: UUID)
}

/// What a session's files slot in the context shows.
enum DuoFilesSlot: Equatable {
    /// The session's Files panel.
    case panel
    /// The panel, opening in place: its bridge is up, or connecting it asks
    /// for nothing.
    case opensPanel
    /// The host's listing, or its offline prompt to open Files.
    case listing
}

/// The context slot owns its page's lifetime. A late disappearance cannot
/// end a replacement session's page.
@MainActor
@Observable
final class DuoContextPageOwner {
    let pageSession = ArtifactPageSession()
    private var ownerID: UUID?
    /// Held above a view that a pose rebuilds, a page outlives its pane
    /// while this holds, and the rebuilt pane adopts it.
    private let keepsPage: (@MainActor () -> Bool)?

    init(keepsPage: (@MainActor () -> Bool)? = nil) {
        self.keepsPage = keepsPage
    }

    func adopt(_ ownerID: UUID) {
        guard self.ownerID != ownerID else { return }
        if self.ownerID != nil, keepsPage == nil { pageSession.end() }
        self.ownerID = ownerID
    }

    func update(_ tab: ArtifactTab?, store: any ArtifactsBrowserStore, ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        pageSession.updatePageSession(for: tab, store: store)
    }

    func release(_ ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
        guard let keepsPage else { pageSession.end(); return }
        // The holder sees the rebuilt composition only once this update
        // finishes; a pane that adopts the page by then keeps it.
        Task { @MainActor [weak self] in
            guard let self, self.ownerID == nil, !keepsPage() else { return }
            self.pageSession.end()
        }
    }

    var isOwned: Bool { ownerID != nil }

    /// Ends a held page that no pane has adopted.
    func endIfUnowned() {
        if ownerID == nil { pageSession.end() }
    }
}

enum DuoContextPolicy {
    static func orderedTabs(hostID: UUID?, tabs: [ArtifactTab]) -> [ArtifactTab] {
        guard let hostID else { return [] }
        return tabs.filter { UUID(uuidString: $0.hostID) == hostID }.sorted {
            if $0.viewedAt != $1.viewedAt { return $0.viewedAt > $1.viewedAt }
            if $0.openedAt != $1.openedAt { return $0.openedAt > $1.openedAt }
            return $0.id < $1.id
        }
    }

    static func resolvedSelection(
        _ selection: DuoContextSelection, tabs: [ArtifactTab], extraIDs: [String], fallbackExtraID: String?
    ) -> DuoContextSelection {
        switch selection {
        case .tab(let id) where tabs.contains(where: { $0.id == id }): return .tab(id)
        case .extra(let id) where extraIDs.contains(id): return .extra(id)
        default:
            if let tab = tabs.first { return .tab(tab.id) }
            if let id = fallbackExtraID, extraIDs.contains(id) { return .extra(id) }
            return .automatic
        }
    }

    static func slotVisible(arrangement: DuoPaneArrangement?, isContextShown: Bool, isSwapped: Bool) -> Bool {
        guard let arrangement else { return true }
        return isSwapped || (arrangement != .single && isContextShown)
    }

    static func isVisible(
        surfaceVisible: Bool, slotVisible: Bool,
        isLocked: Bool, isObscured: Bool, hasSheet: Bool
    ) -> Bool {
        surfaceVisible && slotVisible && !isLocked && !isObscured && !hasSheet
    }

    /// `docksContext`: the shell lays a session out with its context, beside
    /// it on the rail or on the laptop's desk.
    static func openDestination(
        docksContext: Bool, selectedSessionID: UUID?, selectedHostID: UUID?,
        requestHostID: UUID, arrangement: DuoPaneArrangement
    ) -> DuoArtifactOpenDestination {
        // One pane has no room for the context, so an open there goes to the
        // artifacts section, as on every other phone.
        guard docksContext, arrangement != .single, let sessionID = selectedSessionID,
              selectedHostID == requestHostID else { return .artifacts }
        return .context(sessionID: sessionID)
    }

    /// A session's files slot holds its Files panel, so the folder button
    /// lights exactly while files show. Showing the slot opens it when the
    /// panel's own bridge is up, or when connecting it asks for nothing
    /// (`filesConnectUnprompted`). Otherwise the listing offers a tap.
    static func filesSlot(panelOpen: Bool, panelBridgeConnected: Bool, connectsUnprompted: Bool) -> DuoFilesSlot {
        if panelOpen { return .panel }
        return panelBridgeConnected || connectsUnprompted ? .opensPanel : .listing
    }

    /// Whether the files slot may dial the terminal's own host again with
    /// nothing to ask: the terminal is up, and no key on the route wants
    /// Face ID. With the global key setting off none can; with it on, only a
    /// direct route whose key the session ran without Face ID is known not to,
    /// as each bastion's key carries its own setting.
    static func filesConnectUnprompted(terminalConnected: Bool, keyFaceIDEnabled: Bool,
                                       sessionNeedsFaceID: Bool, hasJumpChain: Bool) -> Bool {
        guard terminalConnected else { return false }
        return !keyFaceIDEnabled || (!sessionNeedsFaceID && !hasJumpChain)
    }

    /// The folder button while the context shows files: back to the tab it
    /// showed last. With none, files stay.
    static func tabLeavingFiles(hostID: UUID?, tabs: [ArtifactTab]) -> String? {
        orderedTabs(hostID: hostID, tabs: tabs).first?.id
    }

    static func revealingContext(_ state: DuoWorkspaceState) -> DuoWorkspaceState {
        var next = state
        next.contextHidden = false
        next.fullScreen = false
        return next
    }

    static func retainedSelections(
        _ selections: [UUID: DuoContextSelection], liveSessionIDs: Set<UUID>
    ) -> [UUID: DuoContextSelection] {
        selections.filter { liveSessionIDs.contains($0.key) }
    }

    static func parentDirectory(_ directory: String) -> String? {
        guard directory.hasPrefix("/"), directory != "/" else { return nil }
        let parent = (directory as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func quickOpenRequest(for tab: ArtifactTab) -> ArtifactOpenRequest? {
        guard let hostID = UUID(uuidString: tab.hostID) else { return nil }
        let target: ArtifactOpenRequest.Target
        switch tab.target {
        case let .file(path): target = .file(path: path)
        case let .page(scheme, port, path): target = .page(scheme: scheme, port: Int(port), path: path)
        case let .change(path, diff, summary): target = .change(path: path, diff: diff, summary: summary)
        }
        return .init(hostID: hostID, target: target, origin: .quickOpen, tabID: tab.id)
    }

    static func fileBridgeKeys(
        hostID: UUID, sessionKeys: [FileBridgeKey], existingKeys: [FileBridgeKey]
    ) -> [FileBridgeKey] {
        let liveKeys = sessionKeys.filter { $0.hostID == hostID }
        if !liveKeys.isEmpty {
            var seen: Set<FileBridgeKey> = []
            return liveKeys.filter { existingKeys.contains($0) && seen.insert($0).inserted }
        }
        let matches = existingKeys.filter { $0.hostID == hostID }
        return matches.count == 1 ? matches : []
    }
}
