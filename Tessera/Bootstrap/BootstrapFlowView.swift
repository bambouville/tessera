import SwiftUI
import UIKit
import TesseraCore

/// Full-screen presentation surface for first-open receive, existing-device
/// offer, SAS comparison, origin approval, and the credential checklist.
/// Integration owns presentation by injecting one `BootstrapCoordinator` and
/// placing this view above the normal app content while `isPresented` is true.
struct BootstrapFlowView: View {
    @Bindable var coordinator: BootstrapCoordinator
    var onConfigureHost: (BootstrapCredentialChecklistItem) -> Void = { _ in }
    var onReceivedSetupFinished: () -> Void = {}

    @Environment(\.designTokens) private var T

    var body: some View {
        ZStack {
            T.presentationBg.ignoresSafeArea()

            SetupFlowShell(title: "TESSERA · NEARBY SETUP", presentation: presentation,
                           identifier: "bootstrap", canCancel: canCancel, cancel: coordinator.cancel) {
                content
            }
            .allowsHitTesting(coordinator.peerRejectionNotice == nil)
            .accessibilityHidden(coordinator.peerRejectionNotice != nil)

            if let notice = coordinator.peerRejectionNotice {
                peerRejectionOverlay(notice)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("bootstrap.flow")
    }

    private var presentation: SetupFlowPresentationV1.Output {
        let phase: SetupFlowPresentationV1.Phase
        switch coordinator.phase {
        case .inactive, .welcome, .browsing, .offering: phase = .entry
        case .negotiating: phase = .connecting
        case .compareCode: phase = .compareCode
        case .waitingForPeerCode: phase = .waitingForPeerCode
        case .notifyingCodeRejection: phase = .rejecting
        case .awaitingRecipientPublicKey, .authorizingRecipientKey: phase = .preparingKey
        case .selectingGrants: phase = .choosing
        case .waitingForOriginApproval: phase = .waitingForSelection
        case .authorizingOrigin: phase = .authorizing
        case .transferring: phase = .transferring
        case .completed: phase = .completed
        case .failed: phase = .failed
        }
        return SetupFlowPresentationV1.project(.init(entry: .nearby, phase: phase))
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .inactive:
            EmptyView()
        case .welcome:
            welcome
        case .browsing:
            browser
        case .offering:
            SetupFlowProgress(
                title: "Waiting for your other device",
                detail: "Keep this screen open. Tessera is visible only while this setup flow is in the foreground."
            )
        case .negotiating(_, let peerName):
            SetupFlowProgress(
                title: "Opening an encrypted channel",
                detail: "Connecting to \(peerName). Device names are labels only; the code on the next screen verifies the channel."
            )
        case .compareCode(_, _, let code):
            verification(code: code, waiting: false)
        case .waitingForPeerCode(_, _, let code):
            verification(code: code, waiting: true)
        case .notifyingCodeRejection(let peerName):
            SetupFlowProgress(
                title: "Stopping nearby setup",
                detail: "Telling \(peerName) that this pairing attempt was rejected."
            )
        case .awaitingRecipientPublicKey(let peerName, let code):
            SetupFlowProgress(
                title: "Waiting for the device key",
                detail: "Code \(code) matched. Waiting for \(peerName) to create or reuse its device public key."
            )
        case .authorizingRecipientKey:
            SetupFlowProgress(
                title: "Prepare this device key",
                detail: "Tessera is creating or loading this device’s Secure Enclave key. If your key-use setting requires authentication, confirm Face ID or device passcode. You can change it later in Keys."
            )
        case .selectingGrants(let selection):
            originApproval(selection: selection)
        case .waitingForOriginApproval(let peerName, let code):
            SetupFlowProgress(
                title: "Approve on the other device",
                detail: "Code \(code) matched. \(peerName) must approve before any setup data can be sent."
            )
        case .authorizingOrigin(let selection):
            SetupFlowProgress(
                title: "Confirm on this device",
                detail: "Authorizing \(selection.peerDisplayName) with code \(selection.code)."
            )
        case .transferring(let role, let peerName):
            SetupFlowProgress(
                title: role == .origin ? "Sending setup" : "Importing setup",
                detail: role == .origin
                    ? "Sending the approved, encrypted manifest to \(peerName)."
                    : "Verifying and importing the approved manifest from \(peerName)."
            )
        case .completed(let receipt):
            receiptView(receipt)
        case .failed(let message):
            failure(message)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupFlowHeading(
                "Bring your setup with you",
                detail: "Copy hosts, jump routes, port forwards, and portable appearance settings from a nearby iPhone or iPad. The sending device separately chooses whether sensitive host text and trusted host keys move. Passwords and private keys never move."
            )

            BootstrapConsentCard {
                VStack(alignment: .leading, spacing: 14) {
                    BootstrapConsentLabel("INHERIT FROM NEARBY")
                    Text("You’ll compare a six-digit code on both devices before the origin can approve the transfer.")
                        .tesseraSansScaled(size: 14)
                        .foregroundStyle(T.fgMuted)
                    Btn("find nearby devices", style: .primary, full: true) {
                        coordinator.startRecipientDiscovery(
                            displayName: UIDevice.current.name
                        )
                    }
                    .accessibilityIdentifier("bootstrap.inherit")
                }
            }

            Btn("set up as new", full: true) {
                coordinator.setUpAsNew()
            }
            .accessibilityIdentifier("bootstrap.new")
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupFlowHeading(
                "Choose your other device",
                detail: "On that device, open Settings → Continuity and tap “send setup to nearby device.”"
            )

            if coordinator.discoveredPeers.isEmpty {
                SetupFlowProgress(
                    title: "Looking nearby",
                    detail: "No devices found yet. Both devices must keep Tessera open on the setup screen."
                )
            } else {
                ForEach(coordinator.discoveredPeers) { peer in
                    // The badge is advisory: TXT data is unauthenticated, so
                    // the row always stays tappable and the handshake's
                    // version check produces the authoritative refusal.
                    let flagged = peer.compatibility.indicatesVersionMismatch
                    let subtitle = String(localized: peerSubtitle(for: peer.compatibility))
                    Button {
                        coordinator.selectPeer(peer)
                    } label: {
                        HStack(spacing: 12) {
                            StatusDot(
                                color: flagged ? T.amber : T.green,
                                pulse: !flagged
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(peer.displayName)
                                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                                    .foregroundStyle(T.fg)
                                Text(verbatim: subtitle)
                                    .font(Typography.tesseraMono(size: 11))
                                    .foregroundStyle(T.fgDim)
                            }
                            Spacer()
                            Image(systemName: flagged ? "exclamationmark.triangle" : "chevron.right")
                                .foregroundStyle(T.fgDim)
                        }
                        .padding(16)
                        .background(T.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(T.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bootstrap.peer.\(peer.id)")
                    .accessibilityHint(subtitle)
                }
            }
        }
    }

    private func peerSubtitle(for compatibility: NearbyPeerCompatibility) -> LocalizedStringResource {
        switch compatibility {
        case .unknown, .compatible:
            return "tap to connect · name is not trusted"
        case .localRequiresUpdate:
            return "may need newer Tessera on this device · tap to try"
        case .peerRequiresUpdate:
            return "may need newer Tessera on that device · tap to try"
        }
    }

    private func verification(code: String, waiting: Bool) -> some View {
        SetupCodeVerification(code: code, waiting: waiting, codeIdentifier: "bootstrap.code",
            matchIdentifier: "bootstrap.code.match", rejectIdentifier: "bootstrap.code.reject",
            confirm: coordinator.confirmCodeMatches, reject: coordinator.rejectCode)
    }

    private func originApproval(selection: BootstrapGrantSelectionState) -> some View {
        SetupSelectionReview(selection: selection, mode: .grants, identifier: "bootstrap",
            softwareKeyWarning: "Software-backed simulator key. It is not protected by Secure Enclave; grant access only to test hosts you intend this simulator to use.",
            onHost: { coordinator.setGrantSelected(hostID: $0, selected: $1) },
            onOptional: { coordinator.setOptionalTransfer($0, selected: $1) },
            approve: coordinator.approveOriginTransfer)
    }

    private func receiptView(_ receipt: BootstrapFlowReceipt) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            switch receipt.direction {
            case .sent(let hostCount):
                // Receipt heading on the sending device.
                SetupFlowHeading(
                    "Setup sent",
                    resolvedDetail: String(
                        localized: "\(hostCount) hosts sent securely. Credentials remain local to each device.",
                        comment: "Bootstrap receipt detail. Pluralized on the host count."
                    )
                )
            case .received(let imported):
                // Receipt heading on the receiving device. Three
                // independently pluralized counts share one sentence — the
                // catalog carries a substitution for each.
                SetupFlowHeading(
                    "Setup inherited",
                    resolvedDetail: String(
                        localized: "Imported \(imported.insertedHosts) hosts, \(imported.insertedJumpLinks) jump routes, and \(imported.insertedKnownHosts) trusted host keys.",
                        comment: "Bootstrap import summary. Each count pluralizes independently."
                    )
                )
                if imported.skippedKnownHosts > 0 {
                    Text("\(imported.skippedKnownHosts) identical trusted host keys were already present.")
                        .tesseraSansScaled(size: 13)
                        .foregroundStyle(T.fgMuted)
                }
                if imported.conflictingKnownHosts > 0 {
                    Text("\(imported.conflictingKnownHosts) local trusted host key conflicts were preserved for review in Known Hosts.")
                        .tesseraSansScaled(size: 13, weight: .semibold)
                        .foregroundStyle(T.amber)
                }
            }

            if !receipt.grantReceipt.results.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    BootstrapConsentLabel("HOST ACCESS RECEIPT")
                    Text("This is the acknowledged result for every host. Failed, skipped, and credential-ineligible hosts are never reported as authorized.")
                        .tesseraSansScaled(size: 14)
                        .foregroundStyle(T.fgMuted)

                    ForEach(receipt.grantReceipt.results) { result in
                        BootstrapConsentCard {
                            SetupHostAccessRow(name: result.hostName, outcome: grantOutcome(result),
                                detail: grantResultDetailText(result),
                                configureIdentifier: "bootstrap.configure.\(result.id.uuidString)",
                                configure: configureAction(result, receipt: receipt))
                        }
                    }
                }
            }

            Btn("done", style: .primary, full: true) {
                coordinator.finish()
                if case .received = receipt.direction {
                    onReceivedSetupFinished()
                }
            }
            .accessibilityIdentifier("bootstrap.done")
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupFlowHeading(
                "Nearby setup stopped",
                resolvedDetail: message
            )
            BootstrapConsentCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(T.amber)
                    Text("Setup was not marked complete. Any encrypted channel is closed, and any host grant is recorded only after its remote installation succeeds; retrying nearby transfer creates fresh ephemeral keys and a new comparison code.")
                        .tesseraSansScaled(size: 14)
                        .foregroundStyle(T.fgMuted)
                }
            }
            Btn("start again", style: .primary, full: true) {
                coordinator.retry()
            }
            .accessibilityIdentifier("bootstrap.retry")
            Btn("close", full: true) { coordinator.cancel() }
        }
    }

    private func peerRejectionOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(T.red)
                    Text("Pairing rejected")
                        .font(Typography.tesseraMono(size: 20, weight: .medium))
                        .foregroundStyle(T.fg)
                }
                Text(verbatim: message)
                    .tesseraSansScaled(size: 15)
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Btn("OK", style: .primary, full: true) {
                    coordinator.acknowledgePeerRejection()
                }
                .accessibilityIdentifier("bootstrap.peer-rejection.ok")
            }
            .padding(24)
            .frame(maxWidth: 440, alignment: .leading)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.borderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bootstrap.peer-rejection")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
        .zIndex(10)
    }

    private func configureAction(_ result: BootstrapHostGrantResult, receipt: BootstrapFlowReceipt) -> (() -> Void)? {
        guard result.status.offersConfigureLater,
              let item = receipt.credentialChecklist.first(where: { $0.id == result.hostID }) else { return nil }
        return { onConfigureHost(item) }
    }

    private func grantOutcome(_ result: BootstrapHostGrantResult) -> SetupFlowPresentationV1.Outcome {
        let status = result.status
        let access: SetupFlowPresentationV1.Access
        switch status {
        case .installed: access = .installed
        case .failed: access = .failed
        case .notSelected: access = .notSelected
        case .excludedAuthentication: access = .excluded
        case .rejectedImport: access = .unknown
        }
        return SetupFlowPresentationV1.outcome(.init(id: result.hostID, access: access,
            wasAccepted: status == .rejectedImport ? false : nil))
    }

    private func grantResultDetail(_ status: BootstrapHostGrantStatus) -> LocalizedStringResource {
        switch status {
        case .installed:
            return "The recipient device key was installed and recorded on both devices."
        case .failed:
            return "The public-key installation failed."
        case .notSelected:
            return "This eligible host was not included in the approved batch."
        case .rejectedImport:
            return "The other device did not import this host, so no key was installed."
        case .excludedAuthentication:
            return "Passwords and unavailable credentials cannot be reused for a bootstrap grant."
        }
    }

    /// The installer's own message when it produced one — already resolved
    /// by the error that threw it — otherwise the localized status copy.
    private func grantResultDetailText(_ result: BootstrapHostGrantResult) -> Text {
        if let detail = result.detail {
            return Text(verbatim: detail)
        }
        return Text(grantResultDetail(result.status))
    }

    private var canCancel: Bool {
        switch coordinator.phase {
        case .inactive, .authorizingOrigin, .transferring, .notifyingCodeRejection:
            return false
        default:
            return true
        }
    }
}
