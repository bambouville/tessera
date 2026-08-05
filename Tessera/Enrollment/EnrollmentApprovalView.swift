import SwiftUI

/// Explicit origin approval and requester progress surface for Handoff
/// credential enrollment. Device and host names are display-only; the Apple
/// continuation-stream binding is the peer identity.
struct EnrollmentApprovalView: View {
    @Bindable var coordinator: EnrollmentCoordinator
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                header
                content
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
        .background(T.presentationBg.ignoresSafeArea())
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        VStack(spacing: 11) {
            Image(systemName: headerIcon)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(headerColor)
            Text(headerTitle)
                .font(Typography.sheetTitle)
                .foregroundStyle(T.fg)
                .multilineTextAlignment(.center)
            Text(headerSubtitle)
                .tesseraSansScaled(size: 12)
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .awaitingApproval(let request), .authorizing(let request):
            approvalDetails(request)
        case .installing(let grant):
            approvalDetails(EnrollmentRequest(
                id: grant.enrollmentID,
                hostID: grant.hostID,
                hostName: grant.hostName,
                requestingDeviceName: grant.requestingDeviceName,
                publicKey: grant.publicKey
            ))
        case .openingStreams, .requesting:
            progressPanel("Waiting for your other device…")
        case .syncingRecords:
            progressPanel("Confirming both device records…")
        case .completed:
            statusPanel(
                icon: "checkmark.circle.fill",
                color: T.green,
                text: "The approved public key was installed and recorded on both devices. No private key crossed devices."
            )
        case .rejected:
            statusPanel(
                icon: "xmark.circle.fill",
                color: T.fgMuted,
                text: "The other device declined the request. No host access changed."
            )
        case .cancelled:
            statusPanel(
                icon: "xmark.circle",
                color: T.fgMuted,
                text: "Enrollment was cancelled and the continuation streams were closed."
            )
        case .failed(let message):
            statusPanel(
                icon: "exclamationmark.triangle.fill",
                color: T.red,
                text: message
            )
        case .idle:
            EmptyView()
        }
    }

    private func approvalDetails(_ request: EnrollmentRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            detailRow(
                label: "device (self-reported)",
                value: request.requestingDeviceName
            )
            detailRow(
                label: "host",
                value: coordinator.approvalHostName ?? "current authenticated session"
            )
            if let endpoint = coordinator.approvalEndpoint {
                detailRow(label: "endpoint", value: endpoint)
            }
            detailRow(label: "key", value: keyDescription(request.publicKey))
            detailRow(label: "fingerprint", value: request.publicKey.fingerprint)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(T.green)
                Text("Approve sends only this public key to the host. No password or private key crosses devices.")
                    .tesseraSansScaled(size: 11.5, weight: .medium)
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(T.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(T.green.opacity(0.28), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Typography.kicker)
                .tracking(0.6)
                .foregroundStyle(T.fgDim)
                .textCase(.uppercase)
            Text(value)
                .font(Typography.tesseraMono(size: 11.5))
                .foregroundStyle(T.fg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1)
        }
    }

    private func progressPanel(_ text: String) -> some View {
        HStack(spacing: 11) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusPanel(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text)
                .tesseraSansScaled(size: 12)
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            switch coordinator.phase {
            case .awaitingApproval:
                Btn("Authorize with Face ID / Passcode", style: .primary, full: true) {
                    coordinator.approve()
                }
                Btn("Deny", style: .danger, full: true) {
                    coordinator.reject()
                }
            case .openingStreams, .requesting, .authorizing, .installing, .syncingRecords:
                Btn("Cancel", full: true) { coordinator.cancel() }
            case .completed, .rejected, .cancelled, .failed:
                Btn("Done", style: .primary, full: true) {
                    coordinator.dismissTerminalState()
                }
            case .idle:
                EmptyView()
            }
        }
    }

    private var headerIcon: String {
        switch coordinator.phase {
        case .completed: return "checkmark.shield.fill"
        case .failed: return "exclamationmark.shield.fill"
        case .rejected, .cancelled: return "xmark.shield"
        default: return "person.badge.key.fill"
        }
    }

    private var headerColor: Color {
        switch coordinator.phase {
        case .completed: return T.green
        case .failed: return T.red
        case .rejected, .cancelled: return T.fgMuted
        default: return T.accent
        }
    }

    private var headerTitle: String {
        switch coordinator.phase {
        case .awaitingApproval: return "Authorize Device"
        case .authorizing: return "Confirm Your Identity"
        case .installing: return "Installing Public Key"
        case .syncingRecords: return "Recording Authorization"
        case .openingStreams, .requesting: return "Requesting Access"
        case .completed(let hostName): return "Access Granted to \(hostName)"
        case .rejected: return "Request Denied"
        case .cancelled: return "Enrollment Cancelled"
        case .failed: return "Enrollment Failed"
        case .idle: return "Enrollment"
        }
    }

    private var headerSubtitle: String {
        switch coordinator.phase {
        case .awaitingApproval:
            return "Review the exact host and public key before granting access."
        case .authorizing:
            return "A fresh device-owner check is required for every grant."
        case .installing:
            return "Tessera is adding the approved public key to authorized_keys."
        case .syncingRecords:
            return "Completion waits until both devices durably record the authorization."
        case .openingStreams, .requesting:
            return "Keep Tessera open on both devices."
        case .completed:
            return "Both devices recorded this authorization for later revocation."
        case .rejected, .cancelled, .failed:
            return "No private key or password was transferred."
        case .idle:
            return ""
        }
    }

    private func keyDescription(_ key: EnrollmentPublicKey) -> String {
        let algorithm: String
        switch key.algorithm {
        case .ed25519:
            algorithm = "Ed25519"
        case .secureEnclaveP256:
            algorithm = "ECDSA P-256"
        }
        let protection: String
        switch key.protection {
        case .secureEnclave:
            protection = "Secure Enclave (peer-reported)"
        case .software:
            protection = "software key (peer-reported)"
        }
        return "\(algorithm) · \(protection)"
    }
}
