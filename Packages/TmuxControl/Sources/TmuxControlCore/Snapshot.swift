import Foundation

public struct TmuxPaneSnapshot: Codable, Equatable, Sendable {
    public let id: PaneId
    public let title: String?
    /// True when `title` is tmux's host-derived default rather than an
    /// application supplied pane title. Presentation adapters use this to
    /// preserve the released window-name fallback without re-owning policy.
    public let titleIsDefault: Bool
    public let currentCommand: String?
    /// Server-reported `#{pane_current_path}`. Optional for old snapshots and
    /// for tmux builds that do not expose it.
    public let currentPath: String?
    public let isActive: Bool
    public let isAlternateScreen: Bool?
    public let isMouseReporting: Bool?
    public let isSgrMouse: Bool?
    public let contentRect: CellRect?

    public init(
        id: PaneId,
        title: String? = nil,
        titleIsDefault: Bool = false,
        currentCommand: String? = nil,
        currentPath: String? = nil,
        isActive: Bool = false,
        isAlternateScreen: Bool? = nil,
        isMouseReporting: Bool? = nil,
        isSgrMouse: Bool? = nil,
        contentRect: CellRect? = nil
    ) {
        self.id = id
        self.title = title
        self.titleIsDefault = titleIsDefault && title != nil
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.isActive = isActive
        self.isAlternateScreen = isAlternateScreen
        self.isMouseReporting = isMouseReporting
        self.isSgrMouse = isSgrMouse
        self.contentRect = contentRect
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleIsDefault, currentCommand, currentPath, isActive
        case isAlternateScreen, isMouseReporting, isSgrMouse, contentRect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PaneId.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titleIsDefault = (try container.decodeIfPresent(
            Bool.self,
            forKey: .titleIsDefault
        ) ?? false) && title != nil
        currentCommand = try container.decodeIfPresent(String.self, forKey: .currentCommand)
        currentPath = try container.decodeIfPresent(String.self, forKey: .currentPath)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        isAlternateScreen = try container.decodeIfPresent(Bool.self, forKey: .isAlternateScreen)
        isMouseReporting = try container.decodeIfPresent(Bool.self, forKey: .isMouseReporting)
        isSgrMouse = try container.decodeIfPresent(Bool.self, forKey: .isSgrMouse)
        contentRect = try container.decodeIfPresent(CellRect.self, forKey: .contentRect)
    }
}

public struct TmuxWindowSnapshot: Codable, Equatable, Sendable {
    public let id: WindowId
    public let index: Int?
    public let name: String?
    public let activePaneID: PaneId?
    public let activePaneTitle: String?
    public let activePaneTitleIsDefault: Bool
    public let panes: [TmuxPaneSnapshot]
    public let layout: WindowLayout?
    public let visibleLayout: WindowLayout?
    public let isZoomed: Bool

    public init(
        id: WindowId,
        index: Int? = nil,
        name: String? = nil,
        activePaneID: PaneId? = nil,
        activePaneTitle: String? = nil,
        activePaneTitleIsDefault: Bool = false,
        panes: [TmuxPaneSnapshot] = [],
        layout: WindowLayout? = nil,
        visibleLayout: WindowLayout? = nil,
        isZoomed: Bool = false
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.activePaneID = activePaneID
        self.activePaneTitle = activePaneTitle
        self.activePaneTitleIsDefault = activePaneTitleIsDefault && activePaneTitle != nil
        self.panes = panes
        self.layout = layout
        self.visibleLayout = visibleLayout
        self.isZoomed = isZoomed
    }

    /// Visible label for this window, and the single owner of that policy.
    ///
    /// A non-default active pane title wins because OSC titles update
    /// `pane_title` without emitting `%window-renamed`, so `#{window_name}`
    /// alone goes stale the moment a shell or editor sets its own title.
    /// tmux's default pane title is just `#{host}`, which names the machine
    /// rather than the window, so it is tracked but never shown. The window id
    /// is the last resort for a window seen before any metadata answered.
    ///
    /// Presentation adapters on every platform read this instead of
    /// re-deriving from the parts: doing that privately is what left Android
    /// rendering raw `#{window_name}` while iOS rendered the pane title.
    public var displayName: String {
        Self.displayName(
            windowID: id,
            name: name,
            activePaneTitle: activePaneTitle,
            activePaneTitleIsDefault: activePaneTitleIsDefault
        )
    }

    /// The same rule over loose parts, for adapters holding their own window
    /// model. Static so a tab strip re-rendering on every byte of output does
    /// not build a snapshot just to read a label.
    public static func displayName(
        windowID: WindowId,
        name: String?,
        activePaneTitle: String?,
        activePaneTitleIsDefault: Bool
    ) -> String {
        (activePaneTitleIsDefault ? nil : nonEmpty(activePaneTitle))
            ?? nonEmpty(name)
            ?? windowID.description
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, name, activePaneID, activePaneTitle
        case activePaneTitleIsDefault, panes, layout, visibleLayout, isZoomed
        /// Encode-only: a derived label, carried on the wire so non-Swift
        /// clients read the identical string rather than recomputing it.
        case displayName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(index, forKey: .index)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(activePaneID, forKey: .activePaneID)
        try container.encodeIfPresent(activePaneTitle, forKey: .activePaneTitle)
        try container.encode(activePaneTitleIsDefault, forKey: .activePaneTitleIsDefault)
        try container.encode(panes, forKey: .panes)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(visibleLayout, forKey: .visibleLayout)
        try container.encode(isZoomed, forKey: .isZoomed)
        try container.encode(displayName, forKey: .displayName)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WindowId.self, forKey: .id)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        activePaneID = try container.decodeIfPresent(PaneId.self, forKey: .activePaneID)
        activePaneTitle = try container.decodeIfPresent(String.self, forKey: .activePaneTitle)
        activePaneTitleIsDefault = (try container.decodeIfPresent(
            Bool.self,
            forKey: .activePaneTitleIsDefault
        ) ?? false) && activePaneTitle != nil
        panes = try container.decode([TmuxPaneSnapshot].self, forKey: .panes)
        layout = try container.decodeIfPresent(WindowLayout.self, forKey: .layout)
        visibleLayout = try container.decodeIfPresent(WindowLayout.self, forKey: .visibleLayout)
        isZoomed = try container.decode(Bool.self, forKey: .isZoomed)
    }
}

public struct TmuxSnapshot: Codable, Equatable, Sendable {
    public let sessionID: SessionId?
    public let sessionName: String?
    public let activeWindowID: WindowId?
    /// True only when tmux itself named `activeWindowID` for this client's
    /// session: a `%session-window-changed` for a session `%session-changed`
    /// proved ours (a selection, or the first announcement of a new window),
    /// or the correlated active-window query reply. False for the fail-open
    /// first-`%window-add` fallback and the window picked after the active
    /// one closed, which are provisional guesses; a reader judging geometry
    /// or authority against "the active window" must not take those for
    /// tmux's answer. Absent in payloads that predate it, which decode as
    /// false.
    public let isActiveWindowAuthoritative: Bool
    public let windows: [TmuxWindowSnapshot]
    public let authority: TmuxGridAuthoritySnapshot
    public let capabilities: TmuxWindowCapabilities?
    public let authoritativeWindowOrder: [WindowId]
    public let isWindowListHydrated: Bool
    public let isReorderPending: Bool
    /// Monotonic core-owned revision. Pure trace replay starts at zero.
    public let revision: UInt64

    public init(
        sessionID: SessionId?,
        sessionName: String?,
        activeWindowID: WindowId?,
        isActiveWindowAuthoritative: Bool = false,
        windows: [TmuxWindowSnapshot],
        authority: TmuxGridAuthoritySnapshot,
        capabilities: TmuxWindowCapabilities? = nil,
        isReorderPending: Bool = false,
        authoritativeWindowOrder: [WindowId]? = nil,
        isWindowListHydrated: Bool = false,
        revision: UInt64 = 0
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.activeWindowID = activeWindowID
        self.isActiveWindowAuthoritative = isActiveWindowAuthoritative
        self.windows = windows
        self.authority = authority
        self.capabilities = capabilities
        self.authoritativeWindowOrder = authoritativeWindowOrder ?? windows.map(\.id)
        self.isWindowListHydrated = isWindowListHydrated
        self.isReorderPending = isReorderPending
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, sessionName, activeWindowID, isActiveWindowAuthoritative, windows, authority
        case isWindowListHydrated, capabilities, isReorderPending, authoritativeWindowOrder, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(SessionId.self, forKey: .sessionID)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
        activeWindowID = try container.decodeIfPresent(WindowId.self, forKey: .activeWindowID)
        isActiveWindowAuthoritative = try container.decodeIfPresent(
            Bool.self,
            forKey: .isActiveWindowAuthoritative
        ) ?? false
        windows = try container.decode([TmuxWindowSnapshot].self, forKey: .windows)
        authority = try container.decode(TmuxGridAuthoritySnapshot.self, forKey: .authority)
        capabilities = try container.decodeIfPresent(
            TmuxWindowCapabilities.self,
            forKey: .capabilities
        )
        authoritativeWindowOrder = try container.decodeIfPresent([WindowId].self, forKey: .authoritativeWindowOrder) ?? windows.map(\.id)
        isWindowListHydrated = try container.decodeIfPresent(Bool.self, forKey: .isWindowListHydrated) ?? false
        isReorderPending = try container.decodeIfPresent(
            Bool.self,
            forKey: .isReorderPending
        ) ?? false
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    }
}

public extension TmuxGridAuthoritySnapshot {
    var deviceID: String? {
        if case .peer(let deviceID, _, _) = self { return deviceID }
        return nil
    }

    var displayName: String? { peerDisplayName }

    var epoch: UInt64? {
        switch self {
        case .mine(let generation), .peer(_, _, let generation): return generation
        case .unknown: return nil
        }
    }

    var isLocal: Bool {
        if case .mine = self { return true }
        return false
    }
}
