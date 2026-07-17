import Foundation

public enum PaneSplitAxis: Sendable {
    case horizontal // tmux `split-window -h` -> side-by-side {} ; iTerm2 Cmd-D
    case vertical   // tmux `split-window -v` -> stacked []       ; iTerm2 Cmd-Shift-D
}

/// Semantic keys must stay semantic when tmux's pane application negotiated
/// an extended keyboard protocol. Sending a literal CR/ESC byte with `-H`
/// can be interpreted as composer text by modern TUIs instead of Enter/Escape.
public enum PaneInputKey: Sendable {
    case enter
    case escape

    fileprivate var tmuxName: String {
        switch self {
        case .enter: "Enter"
        case .escape: "Escape"
        }
    }
}

@MainActor
public extension TmuxController {
    func splitActivePane(_ axis: PaneSplitAxis) {
        guard mode == .tmuxControl, let activePaneId else { return }
        preemptMoshPaneBorderSplit(forTargeting: activePaneId)

        let flag: String
        switch axis {
        case .horizontal:
            flag = "-h"
        case .vertical:
            flag = "-v"
        }

        sendPaneOperationCommand(
            "split-window \(flag) -t \(activePaneId.description) -e COLORTERM=truecolor"
        )
    }

    func selectPane(_ paneId: PaneId) {
        guard mode == .tmuxControl else { return }
        sendPaneOperationCommand("select-pane -t \(paneId.description)")
    }

    func killActivePane() {
        guard mode == .tmuxControl, let activePaneId else { return }
        sendPaneOperationCommand("kill-pane -t \(activePaneId.description)")
    }

    func killPane(_ paneId: PaneId) {
        guard mode == .tmuxControl else { return }
        sendPaneOperationCommand("kill-pane -t \(paneId.description)")
    }

    func togglePaneZoom() {
        guard mode == .tmuxControl, let activePaneId else { return }
        sendPaneOperationCommand("resize-pane -Z -t \(activePaneId.description)")
    }

    func cyclePane(forward: Bool) {
        guard mode == .tmuxControl,
              let activeWindowId,
              let activePaneId,
              let activeWindow = windows.first(where: { $0.id == activeWindowId }),
              let paneIds = activeWindow.layout?.paneIds,
              paneIds.count >= 2,
              let currentIndex = paneIds.firstIndex(of: activePaneId)
        else { return }

        let nextIndex: Int
        if forward {
            nextIndex = paneIds.index(after: currentIndex) == paneIds.endIndex
                ? paneIds.startIndex
                : paneIds.index(after: currentIndex)
        } else {
            nextIndex = currentIndex == paneIds.startIndex
                ? paneIds.index(before: paneIds.endIndex)
                : paneIds.index(before: currentIndex)
        }

        selectPane(paneIds[nextIndex])
    }

    func sendInput(_ bytes: [UInt8], toPane paneId: PaneId) {
        guard mode == .tmuxControl, !bytes.isEmpty else { return }

        inputObserver?(paneId, bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendControlCommand("send-keys -t \(paneId.description) -H \(hex)")
    }

    /// Agent Center needs to distinguish local enqueue from tmux accepting
    /// the pane-targeted input. Agent Center deliberately does not publish the
    /// ordinary user-input observer here: tmux accepting Return is not proof
    /// that an agent composer submitted it.
    func sendInputAcknowledged(_ bytes: [UInt8], toPane paneId: PaneId) async -> Bool {
        guard mode == .tmuxControl, !bytes.isEmpty else { return false }

        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let result = await withCheckedContinuation { continuation in
            sendControlCommand("send-keys -t \(paneId.description) -H \(hex)") { result in
                continuation.resume(returning: result)
            }
        }
        guard case .success = result else { return false }
        return true
    }

    func sendKeyAcknowledged(_ key: PaneInputKey, toPane paneId: PaneId) async -> Bool {
        guard mode == .tmuxControl else { return false }

        let result = await withCheckedContinuation { continuation in
            sendControlCommand("send-keys -t \(paneId.description) \(key.tmuxName)") { result in
                continuation.resume(returning: result)
            }
        }
        guard case .success = result else { return false }
        return true
    }

    private func sendPaneOperationCommand(_ command: String) {
        sendControlCommand(command) { [weak self] result in
            guard case .failure(.tmuxError(let lines)) = result else { return }
            let message = lines
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.onCommandError?(message)
        }
    }
}
