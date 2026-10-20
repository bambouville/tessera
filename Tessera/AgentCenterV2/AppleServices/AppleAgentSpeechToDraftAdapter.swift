import Foundation
import TesseraCore

/// Owns the existing on-device speech controller only while an Agent Center
/// composer is explicitly dictating. Recognition output is copied to an
/// editable draft; it never dispatches a terminal action directly.
@MainActor
final class AppleAgentSpeechToDraftAdapter {
    enum BeginResult: Equatable {
        case listening
        case unavailable
        case busy
    }

    private let controller: SpeechDictationController
    private var ownerToken: UUID?
    private var previousCommit: ((String) -> Void)?

    init(controller: SpeechDictationController) {
        self.controller = controller
    }

    func begin(
        for threadID: AgentThreadID,
        applyDraft: @escaping (AgentThreadID, String) -> Void
    ) async -> BeginResult {
        guard controller.activeState == .idle else { return .busy }
        guard SpeechDictationController.isOnDeviceAvailable else { return .unavailable }

        let token = UUID()
        ownerToken = token
        previousCommit = controller.onCommit
        let priorCommit = previousCommit
        controller.onCommit = { [weak self] text in
            guard let self, self.ownerToken == token else { return }
            applyDraft(threadID, text)
            self.restore(previousCommit: priorCommit)
        }
        await controller.start()
        guard controller.activeState == .listening else {
            restore(previousCommit: priorCommit)
            return .unavailable
        }
        return .listening
    }

    func commit() {
        guard ownerToken != nil else { return }
        controller.stop(commit: true)
    }

    func cancel() {
        guard ownerToken != nil else { return }
        controller.stop(commit: false)
        restore(previousCommit: previousCommit)
    }

    private func restore(previousCommit: ((String) -> Void)?) {
        controller.onCommit = previousCommit
        self.previousCommit = nil
        ownerToken = nil
    }
}
