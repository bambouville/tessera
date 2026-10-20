import Foundation

public enum PaneSplitAxis: Sendable, Equatable {
    case horizontal // tmux `split-window -h` -> side-by-side {} ; iTerm2 Cmd-D
    case vertical   // tmux `split-window -v` -> stacked []       ; iTerm2 Cmd-Shift-D
}

/// Semantic keys must stay semantic when tmux's pane application negotiated
/// an extended keyboard protocol. Sending a literal CR/ESC byte with `-H`
/// can be interpreted as composer text by modern TUIs instead of Enter/Escape.
public enum PaneInputKey: String, Sendable {
    case enter = "Enter", escape = "Escape", tab = "Tab", backTab = "BTab"
    case up = "Up", down = "Down", left = "Left", right = "Right"
    case shiftLeft = "S-Left", controlRightBracket = "C-]"
}

@MainActor
private final class AgentPaneWriteCompletion {
    var deadlineTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func complete(_ acknowledged: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.resume(returning: acknowledged)
    }
}

@MainActor
public extension TmuxController {
    func splitActivePane(_ axis: PaneSplitAxis) {
        guard !userMutationsSuppressedWhileYielded else { return }
        guard mode == .tmuxControl, let activePaneId else { return }
        splitPane(activePaneId, axis: axis)
    }

    /// Split an explicitly selected pane from a touch switcher. Stable pane
    /// ids let compact UI target an inactive window without first selecting it
    /// and racing the asynchronous `%session-window-changed` notification.
    ///
    /// `before` places the new pane ahead of the target on the split axis —
    /// left of a `-h` split, above a `-v` one — which is tmux's `-b`. Without
    /// it tmux always appends, the only placement `⌘D` / `⌘⇧D` can express.
    func splitPane(_ paneId: PaneId, axis: PaneSplitAxis, before: Bool = false) {
        guard !userMutationsSuppressedWhileYielded else { return }
        // `isWindowListHydrated` for the same reason `killWindow`,
        // `renameWindow` and `selectWindow` require it: a session change
        // keeps the previous window list on screen while marking it stale,
        // and a bare `%id` resolves against whatever session now owns it.
        guard mode == .tmuxControl,
              isWindowListHydrated,
              windows.contains(where: { window in
                  window.panes.contains(where: { $0.id == paneId })
              })
        else { return }
        preemptMoshPaneBorderSplit(forTargeting: paneId)

        sendPaneOperationCommand(TmuxWindowCommands.splitPane(paneId, horizontal: axis == .horizontal, before: before))
    }

    func selectPane(_ paneId: PaneId) {
        guard !userMutationsSuppressedWhileYielded,
              mode == .tmuxControl else { return }
        selectPaneAcrossTmuxClients(paneId, preservingWindowZoom: false)
    }

    /// Select a compact full-screen pane without losing a server-side zoom.
    ///
    /// tmux unzooms a window when `select-pane` targets a different pane.
    /// Compact presentation must not silently change that geometry. tmux's
    /// `select-pane -Z` performs the selection while retaining an existing
    /// zoom atomically, so other attached clients never observe an unzoomed
    /// intermediate layout. `-Z` is also a no-op for an unzoomed window, so
    /// use it unconditionally instead of trusting potentially stale layout
    /// metadata from another attached client.
    public func selectPanePreservingWindowZoom(_ paneId: PaneId) {
        guard !userMutationsSuppressedWhileYielded,
              mode == .tmuxControl else { return }
        selectPaneAcrossTmuxClients(paneId, preservingWindowZoom: true)
    }

    func killActivePane() {
        guard !userMutationsSuppressedWhileYielded,
              mode == .tmuxControl,
              let activePaneId else { return }
        sendPaneOperationCommand("kill-pane -t \(activePaneId.description)")
    }

    func killPane(_ paneId: PaneId) {
        guard !userMutationsSuppressedWhileYielded,
              mode == .tmuxControl else { return }
        sendPaneOperationCommand("kill-pane -t \(paneId.description)")
    }

    func togglePaneZoom() {
        guard !userMutationsSuppressedWhileYielded,
              mode == .tmuxControl,
              let activePaneId else { return }
        sendPaneOperationCommand("resize-pane -Z -t \(activePaneId.description)")
    }

    /// Set, rather than toggle, pane zoom so a delayed presentation command
    /// cannot invert state that changed while it crossed the shared session
    /// boundary.
    public func setPaneZoomed(_ paneId: PaneId, zoomed: Bool) {
        guard !userMutationsSuppressedWhileYielded,
              mode == .tmuxControl,
              let window = windows.first(where: { window in
                  window.panes.contains(where: { $0.id == paneId })
              }),
              window.isZoomed != zoomed
        else { return }
        sendPaneOperationCommand("resize-pane -Z -t \(paneId.description)")
    }

    func cyclePane(forward: Bool) {
        guard !userMutationsSuppressedWhileYielded else { return }
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
        guard !userMutationsSuppressedWhileYielded,
              mode == .tmuxControl,
              !bytes.isEmpty else { return }

        inputObserver?(paneId, bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendControlCommand("send-keys -t \(paneId.description) -H \(hex)")
    }

    /// Agent Center needs to distinguish local enqueue from tmux accepting
    /// the pane-targeted input. Agent Center deliberately does not publish the
    /// ordinary user-input observer here: tmux accepting Return is not proof
    /// that an agent composer submitted it. The proved pane's `send-keys`
    /// leaves grid authority unchanged, so it also runs while yielded.
    func sendInputAcknowledged(_ bytes: [UInt8], toPane paneId: PaneId,
                               completionTimeout: Duration = .seconds(10)) async -> Bool {
        guard mode == .tmuxControl,
              !bytes.isEmpty else { return false }

        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return await sendAgentPaneCommandAcknowledged("send-keys -t \(paneId.description) -H \(hex)",
                                                     completionTimeout: completionTimeout)
    }

    /// Agent Center's named key to a proved pane leaves grid authority
    /// unchanged; success reports tmux's acknowledgement, even while yielded.
    func sendKeyAcknowledged(_ key: PaneInputKey, toPane paneId: PaneId,
                             completionTimeout: Duration = .seconds(10)) async -> Bool {
        guard mode == .tmuxControl else { return false }

        return await sendAgentPaneCommandAcknowledged("send-keys -t \(paneId.description) \(key.rawValue)",
                                                     completionTimeout: completionTimeout)
    }

    /// Only the caller expires. The command's FIFO slot stays reserved until
    /// its reply or reset; a late ACK cannot resume the caller or send a key.
    private func sendAgentPaneCommandAcknowledged(_ command: String, completionTimeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = AgentPaneWriteCompletion(continuation)
            completion.deadlineTask = Task { @MainActor in
                do { try await Task.sleep(for: completionTimeout) } catch { return }
                completion.complete(false)
            }
            sendControlCommand(command) { result in
                if case .success = result { completion.complete(true) }
                else { completion.complete(false) }
            }
        }
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
