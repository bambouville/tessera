import Foundation
import SwiftUI
import UIKit

/// Blocking sheet presented during SSH handshake when the host key
/// is unknown (first connect) or has changed (possible MITM).
struct HostKeyVerificationView: View {
    let request: HostKeyVerificationRequest
    let onTrust: () -> Void
    let onReject: () -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 20) {
                        header

                        if request.isChanged {
                            changedWarningPanel
                        }

                        keyDetails

                        if let peerMatchPanel {
                            peerMatchPanel
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(.top, 28)
                    .padding(.horizontal, 32)

                    Spacer(minLength: 24)

                    actions
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
            .background(T.presentationBg.ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // This blocking sheet has no text input. A terminal or host form
            // can still own first responder when the handshake asks for trust;
            // on a landscape iPhone that leaves the safe actions completely
            // behind the software keyboard. End editing before presenting the
            // decision so Trust/Cancel remain visible and tappable.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: request.isChanged ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(request.isChanged ? T.red : T.amber)

            Text(request.isChanged ? "host key changed" : "unknown host")
                .font(Typography.sheetTitle)
                .foregroundStyle(T.fg)

            Text(request.endpoint)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var changedWarningPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!")
                .font(Typography.tesseraMono(size: 12, weight: .medium))
                .foregroundStyle(T.red)

            Text("The host key for this server has changed since the last connection. This could indicate a man-in-the-middle attack, or the server was reinstalled.")
                .tesseraSansScaled(size: 13)
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(T.red.opacity(0.3), lineWidth: 1)
        )
    }

    private var keyDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if request.isChanged {
                fingerprintBlock(title: "Old fingerprint:", value: request.oldFingerprint ?? "")
            }

            fingerprintBlock(title: "Server fingerprint:", value: request.fingerprint)
            valueBlock(title: "Key type:", value: request.keyType)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if request.peerFingerprintMatches == false {
                Btn("Don't Connect", style: .primary, full: true, action: onReject)
                Btn("Trust Anyway", style: .danger, full: true, action: onTrust)
            } else {
                Btn(
                    request.isChanged ? "Trust" : "Trust & Connect",
                    style: .primary,
                    full: true,
                    action: onTrust
                )
                Btn("Cancel", full: true, action: onReject)
            }
        }
    }

    private var peerMatchPanel: AnyView? {
        guard let matches = request.peerFingerprintMatches else { return nil }
        let label = request.peerLabel ?? "your other device"
        let color = matches ? T.green : T.amber
        let icon = matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let text = matches
            ? "Matches the key \(label) trusts."
            : "Differs from the key \(label) trusts. Verify out of band before connecting."

        return AnyView(
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)

                Text(text)
                    .tesseraSansScaled(size: 12, weight: .medium)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.28), lineWidth: 1)
            }
        )
    }

    private func fingerprintBlock(title: String, value: String) -> some View {
        valueBlock(title: title, value: value)
            .textSelection(.enabled)
    }

    private func valueBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .tesseraSansScaled(size: 11, weight: .medium)
                .foregroundStyle(T.fgDim)

            Text(value)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(T.border, lineWidth: 1)
        )
    }
}

/// Data needed to present the host key verification sheet.
struct HostKeyVerificationRequest: Identifiable {
    let id: UUID
    let endpoint: String
    let fingerprint: String
    let keyType: String
    let isChanged: Bool
    let oldFingerprint: String?
    let peerFingerprint: String?
    let peerLabel: String?
    private let decision: HostKeyVerificationDecision

    init(
        id: UUID = UUID(),
        challenge: HostKeyVerificationChallenge,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.id = id
        endpoint = challenge.endpoint
        fingerprint = challenge.fingerprint
        keyType = challenge.keyType
        isChanged = challenge.isChanged
        oldFingerprint = challenge.oldFingerprint
        peerFingerprint = challenge.peerFingerprint
        peerLabel = challenge.peerLabel
        decision = HostKeyVerificationDecision(continuation: continuation)
    }

    @MainActor
    func accept() {
        decision.resolve(true)
    }

    @MainActor
    func reject() {
        decision.resolve(false)
    }

    var isResolved: Bool {
        decision.isResolved
    }

    var peerFingerprintMatches: Bool? {
        peerFingerprint.map { $0 == fingerprint }
    }

    func isSameChallenge(as other: HostKeyVerificationRequest) -> Bool {
        endpoint == other.endpoint
            && fingerprint == other.fingerprint
            && keyType == other.keyType
            && isChanged == other.isChanged
            && oldFingerprint == other.oldFingerprint
            && peerFingerprint == other.peerFingerprint
            && peerLabel == other.peerLabel
    }

    func coalesce(_ other: HostKeyVerificationRequest) {
        decision.coalesce(other.decision)
    }
}

private final class HostKeyVerificationDecision {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Bool, Never>]
    private var resolvedValue: Bool?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuations = [continuation]
    }

    var isResolved: Bool {
        lock.lock()
        let resolved = resolvedValue != nil || continuations.isEmpty
        lock.unlock()
        return resolved
    }

    func resolve(_ accepted: Bool) {
        let continuationsToResume: [CheckedContinuation<Bool, Never>]
        lock.lock()
        if resolvedValue != nil {
            continuationsToResume = []
        } else {
            resolvedValue = accepted
            continuationsToResume = continuations
            continuations = []
        }
        lock.unlock()

        guard !continuationsToResume.isEmpty else {
            DiagnosticLogStore.appendSSH(
                "hostkey prompt duplicate decision ignored accepted=\(accepted)"
            )
            return
        }

        for continuation in continuationsToResume {
            continuation.resume(returning: accepted)
        }
    }

    func coalesce(_ other: HostKeyVerificationDecision) {
        let detached = other.detach()
        switch detached {
        case .resolved(let accepted):
            resolve(accepted)
        case .continuations(let detachedContinuations):
            append(detachedContinuations)
        }
    }

    private func append(_ newContinuations: [CheckedContinuation<Bool, Never>]) {
        guard !newContinuations.isEmpty else { return }

        let alreadyResolvedValue: Bool?
        lock.lock()
        if let resolvedValue {
            alreadyResolvedValue = resolvedValue
        } else {
            alreadyResolvedValue = nil
            continuations.append(contentsOf: newContinuations)
        }
        lock.unlock()

        if let alreadyResolvedValue {
            for continuation in newContinuations {
                continuation.resume(returning: alreadyResolvedValue)
            }
        }
    }

    private func detach() -> DetachedDecision {
        lock.lock()
        if let resolvedValue {
            lock.unlock()
            return .resolved(resolvedValue)
        }

        let detached = continuations
        continuations = []
        lock.unlock()
        return .continuations(detached)
    }

    private enum DetachedDecision {
        case resolved(Bool)
        case continuations([CheckedContinuation<Bool, Never>])
    }
}
