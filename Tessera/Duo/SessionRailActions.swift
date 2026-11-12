import Foundation
import Observation

@MainActor @Observable
final class SessionRailActionCenter {
    private(set) var actions: SessionRailActions?

    func publish(_ actions: SessionRailActions, for sessionID: UUID) {
        guard actions.sessionID == sessionID else { return }
        self.actions = actions
    }

    func withdraw(sessionID: UUID) {
        guard actions?.sessionID == sessionID else { return }
        actions = nil
    }
}

struct SessionRailActions {
    var sessionID: UUID
    var canCreateTmuxWindow: Bool
    var findOpen: Bool
    var filesOpen: Bool
    var hasForwarding: Bool
    var hasContinuity: Bool
    /// Docked in the context pane when two panes fit.
    var filesPanel: FilesPanelController?
    /// The terminal is connected and its route needs no Face ID, so the
    /// context's files slot may open the panel, and connect, by itself.
    var filesConnectUnprompted: Bool
    /// Opens the panel where the context already shows files: unlike the
    /// button, it leaves the context and the keyboard. False when the panel
    /// cannot dock there.
    var openFilesInPlace: (() -> Bool)?
    var openSwitcher: () -> Void
    var createTmuxWindow: () -> Void
    var toggleFind: () -> Void
    var toggleFiles: () -> Void
    var showForwarding: () -> Void
    var showContinuity: () -> Void
    var disconnect: () -> Void
}

/// The mounted chrome owns the integration notice and its repair presentation.
/// Rail actions keep this stable reference while the chrome refreshes its opener.
@MainActor
final class SessionRailSwitcher {
    var open: () -> Void = {}
}

enum SessionRailPolicy {
    static let paneHeaderHeight: CGFloat = 28

    static func reservedHeight(railMode: Bool, regularHeight: CGFloat) -> CGFloat {
        railMode ? paneHeaderHeight : regularHeight
    }

    static func openSwitcher(
        sessionID: UUID?, actions: SessionRailActions?, fallback: () -> Void
    ) {
        if let sessionID, let actions, actions.sessionID == sessionID {
            actions.openSwitcher()
        } else {
            fallback()
        }
    }

    static func canCreateTmuxWindow(
        controlActive: Bool,
        degraded: Bool,
        hasWindows: Bool,
        controlledElsewhere: Bool
    ) -> Bool {
        controlActive && !degraded && hasWindows && !controlledElsewhere
    }
}

/// Observes the fields rendered by the rail without comparing its closures.
struct SessionRailActionState: Equatable {
    var sessionID: UUID
    var isActive: Bool
    var canCreateTmuxWindow: Bool
    var findOpen: Bool
    var filesOpen: Bool
    var filesConnectUnprompted: Bool
    /// Docking changes what the files closures do, so it republishes them.
    var filesDocked: Bool
    var hasForwarding: Bool
    var hasContinuity: Bool
    var sourceIdentity: ObjectIdentifier
    var forwarderIdentity: ObjectIdentifier?

    @MainActor
    func synchronize(
        _ actions: SessionRailActions,
        previousSessionID: UUID?,
        with center: SessionRailActionCenter
    ) {
        if let previousSessionID, previousSessionID != sessionID {
            center.withdraw(sessionID: previousSessionID)
        }
        if isActive {
            center.publish(actions, for: sessionID)
        } else {
            center.withdraw(sessionID: sessionID)
        }
    }
}
