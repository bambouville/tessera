import Foundation
import SwiftUI

/// Rail sections navigate even while the compact shell's detail overlay is up.
/// A remembered session is only a destination while its live slot still exists.
enum RailNavigationPolicy {
    static func selection(
        previousTab: CompactRootTab,
        newTab: CompactRootTab,
        currentSelection: SidebarItem?,
        lastSessionID: UUID?,
        liveSessionIDs: Set<UUID>,
        agentCenterEnabled: Bool
    ) -> SidebarItem? {
        let tab = visibleTab(newTab, agentCenterEnabled: agentCenterEnabled)
        if previousTab == newTab, tab == newTab {
            switch currentSelection {
            case .session(let id) where !liveSessionIDs.contains(id):
                return nil
            case .agents where !agentCenterEnabled:
                return nil
            default:
                return currentSelection
            }
        }

        switch tab {
        case .hosts:
            return nil
        case .sessions:
            if case .session(let id) = currentSelection, liveSessionIDs.contains(id) {
                return .session(id)
            }
            if let lastSessionID, liveSessionIDs.contains(lastSessionID) {
                return .session(lastSessionID)
            }
            return nil
        case .agents:
            return .agents
        case .artifacts:
            return .artifacts
        case .settings:
            return .settings
        }
    }

    static func visibleTab(
        _ tab: CompactRootTab,
        agentCenterEnabled: Bool
    ) -> CompactRootTab {
        tab == .agents && !agentCenterEnabled ? .sessions : tab
    }
}

/// Decisions shared by the shell and toolbar, without mounting views or
/// invoking any published session action.
enum RailShellPolicy {
    static func isRailMode(isPhone: Bool, railEdge: HorizontalEdge?) -> Bool {
        isPhone && railEdge != nil
    }

    static func overlayIgnoredEdges(isPhone: Bool, railEdge: HorizontalEdge?) -> Edge.Set {
        guard isRailMode(isPhone: isPhone, railEdge: railEdge), let railEdge else { return .all }
        return railEdge == .leading ? [.top, .bottom, .trailing] : [.top, .bottom, .leading]
    }

    /// The outer display's rail insets the whole window. On the inner display
    /// it insets only the TabView's own content, so a layer beside the TabView
    /// reserves the difference itself or it covers the rail.
    /// A tab frame still being laid out (or left from another display) is
    /// ignored rather than sent to the terminal as a resize.
    static func overlayRailInset(railEdge: HorizontalEdge?, overlay: CGRect, tabContent: CGRect?) -> CGFloat {
        guard let railEdge, let tabContent, overlay.width > 0,
              tabContent.width >= overlay.width * 2 / 3 else { return 0 }
        switch railEdge {
        case .trailing:
            guard abs(tabContent.minX - overlay.minX) <= 1 else { return 0 }
            return max(0, overlay.maxX - tabContent.maxX)
        case .leading:
            guard abs(tabContent.maxX - overlay.maxX) <= 1 else { return 0 }
            return max(0, tabContent.minX - overlay.minX)
        }
    }

    static func workspaceStates(
        _ previous: [UUID: DuoWorkspaceState],
        liveSessionIDs: Set<UUID>
    ) -> [UUID: DuoWorkspaceState] {
        var states = previous.filter { liveSessionIDs.contains($0.key) }
        for id in liveSessionIDs where states[id] == nil {
            states[id] = DuoWorkspaceState()
        }
        return states
    }

    static func mainIdealWidth(cellWidth: CGFloat, isPhone: Bool, cornerInset: CGFloat) -> CGFloat {
        DuoPaneGeometry.mainIdealWidth(
            columns: 80,
            cellWidth: cellWidth,
            horizontalPadding: 2 * (isPhone ? 4 : cornerInset)
        )
    }

    /// A shown session keeps its actions on the rail and folds the tabs to
    /// make room, unless another tab carries a badge: the folded tabs show
    /// only the selected one's, so the badge wins and the tabs stay whole.
    static func prefersRailActions(sessionShown: Bool, otherTabBadged: Bool) -> Bool {
        sessionShown && !otherTabBadged
    }

    static func sessionActions(
        for sessionID: UUID?,
        published: SessionRailActions?
    ) -> SessionRailActions? {
        guard let sessionID, let published, published.sessionID == sessionID else { return nil }
        return published
    }

    static func harnessSizeClass(
        usesSystemSizeClass: Bool,
        usesCompactWidth: Bool,
        systemSizeClass: UserInterfaceSizeClass?
    ) -> UserInterfaceSizeClass? {
        usesSystemSizeClass ? systemSizeClass : (usesCompactWidth ? .compact : .regular)
    }
}
