import SwiftUI

/// Blocking sheet presented during SSH handshake when the host key
/// is unknown (first connect) or has changed (possible MITM).
struct HostKeyVerificationView: View {
    let request: HostKeyVerificationRequest
    let onTrust: () -> Void
    let onReject: () -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                header

                if request.isChanged {
                    changedWarningPanel
                }

                keyDetails
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: request.isChanged ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(request.isChanged ? T.red : T.amber)

            Text(request.isChanged ? "HOST KEY CHANGED" : "Unknown Host")
                .font(Typography.tesseraMono(size: 20, weight: .medium))
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
                .font(Typography.tesseraSans(size: 13))
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
            Btn(request.isChanged ? "Trust" : "Accept New Key", style: .primary, full: true, action: onTrust)
            Btn("Reject", style: .danger, full: true, action: onReject)
        }
    }

    private func fingerprintBlock(title: String, value: String) -> some View {
        valueBlock(title: title, value: value)
            .textSelection(.enabled)
    }

    private func valueBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typography.tesseraSans(size: 11, weight: .medium))
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
    let id = UUID()
    let endpoint: String
    let fingerprint: String
    let keyType: String
    let isChanged: Bool
    let oldFingerprint: String?
    /// Continuation that the presenter resumes with the user's decision.
    let continuation: CheckedContinuation<Bool, Never>

    init(
        challenge: HostKeyVerificationChallenge,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        endpoint = challenge.endpoint
        fingerprint = challenge.fingerprint
        keyType = challenge.keyType
        isChanged = challenge.isChanged
        oldFingerprint = challenge.oldFingerprint
        self.continuation = continuation
    }
}
