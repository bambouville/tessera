import Foundation

public enum PaneSplitAxis: Sendable {
    case horizontal // tmux `split-window -h` -> side-by-side {} ; iTerm2 Cmd-D
    case vertical   // tmux `split-window -v` -> stacked []       ; iTerm2 Cmd-Shift-D
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

        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendControlCommand("send-keys -t \(paneId.description) -H \(hex)")
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
