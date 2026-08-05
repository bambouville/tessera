import SwiftUI
import UIKit

/// Full-screen presentation surface for first-open receive, existing-device
/// offer, SAS comparison, origin approval, and the credential checklist.
/// Integration owns presentation by injecting one `BootstrapCoordinator` and
/// placing this view above the normal app content while `isPresented` is true.
struct BootstrapFlowView: View {
    @Bindable var coordinator: BootstrapCoordinator
    var onConfigureHost: (BootstrapCredentialChecklistItem) -> Void = { _ in }

    @Environment(\.designTokens) private var T

    var body: some View {
        ZStack {
            T.presentationBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(T.fg)
            Text("TESSERA · NEARBY SETUP")
                .font(Typography.tesseraMono(size: 12, weight: .semibold))
                .foregroundStyle(T.fgMuted)
            Spacer()
            if canCancel {
                Button("cancel") { coordinator.cancel() }
                    .buttonStyle(.plain)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                    .accessibilityIdentifier("bootstrap.cancel")
            }
        }
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
            progress(
                title: "Waiting for your other device",
                detail: "Keep this screen open. Tessera is visible only while this setup flow is in the foreground."
            )
        case .negotiating(_, let peerName):
            progress(
                title: "Opening an encrypted channel",
                detail: "Connecting to \(peerName). Device names are labels only; the code on the next screen verifies the channel."
            )
        case .compareCode(_, let peerName, let code):
            codeComparison(peerName: peerName, code: code)
        case .waitingForPeerCode(_, let peerName, let code):
            progress(
                title: "Waiting for the other device",
                detail: "You confirmed code \(code). \(peerName) must confirm the same code before setup can continue."
            )
        case .notifyingCodeRejection(let peerName):
            progress(
                title: "Stopping nearby setup",
                detail: "Telling \(peerName) that this pairing attempt was rejected."
            )
        case .awaitingRecipientPublicKey(let peerName, let code):
            progress(
                title: "Waiting for the device key",
                detail: "Code \(code) matched. Waiting for \(peerName) to create or reuse its device public key."
            )
        case .authorizingRecipientKey:
            progress(
                title: "Prepare this device key",
                detail: "Tessera is creating or loading this device’s Secure Enclave key. If your key-use setting requires authentication, confirm Face ID or device passcode. You can change it later in Keys."
            )
        case .selectingGrants(let selection):
            originApproval(selection: selection)
        case .waitingForOriginApproval(let peerName, let code):
            progress(
                title: "Approve on the other device",
                detail: "Code \(code) matched. \(peerName) must approve before any setup data can be sent."
            )
        case .authorizingOrigin(let selection):
            progress(
                title: "Confirm on this device",
                detail: "Authorizing \(selection.peerDisplayName) with code \(selection.code)."
            )
        case .transferring(let role, let peerName):
            progress(
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
            title(
                "Bring your setup with you",
                detail: "Copy hosts, jump routes, port forwards, and portable appearance settings from a nearby iPhone or iPad. The sending device separately chooses whether sensitive host text and trusted host keys move. Passwords and private keys never move."
            )

            card {
                VStack(alignment: .leading, spacing: 14) {
                    label("INHERIT FROM NEARBY")
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
            title(
                "Choose your other device",
                detail: "On that device, open Settings → Continuity and tap “send setup to nearby device.”"
            )

            if coordinator.discoveredPeers.isEmpty {
                progress(
                    title: "Looking nearby",
                    detail: "No devices found yet. Both devices must keep Tessera open on the setup screen."
                )
            } else {
                ForEach(coordinator.discoveredPeers) { peer in
                    // The badge is advisory: TXT data is unauthenticated, so
                    // the row always stays tappable and the handshake's
                    // version check produces the authoritative refusal.
                    let flagged = peer.compatibility.indicatesVersionMismatch
                    let subtitle = peerSubtitle(for: peer.compatibility)
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
                                Text(subtitle)
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

    private func peerSubtitle(for compatibility: NearbyPeerCompatibility) -> String {
        switch compatibility {
        case .unknown, .compatible:
            return "tap to connect · name is not trusted"
        case .localRequiresUpdate:
            return "may need newer Tessera on this device · tap to try"
        case .peerRequiresUpdate:
            return "may need newer Tessera on that device · tap to try"
        }
    }

    private func codeComparison(peerName: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            title(
                "Compare this code",
                detail: "Confirm only if the same code is visible on \(peerName). If either device rejects the code, both devices stop this attempt; retrying creates fresh encryption keys."
            )
            codeCard(code)
            Btn("codes match", style: .primary, full: true) {
                coordinator.confirmCodeMatches()
            }
            .accessibilityIdentifier("bootstrap.code.match")
            Btn("codes don’t match", style: .danger, full: true) {
                coordinator.rejectCode()
            }
            .accessibilityIdentifier("bootstrap.code.reject")
        }
    }

    private func originApproval(selection: BootstrapGrantSelectionState) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            title(
                "Choose what to copy",
                detail: "Code \(selection.code) matched. Optional host text and trust start off. Review this exact setup transfer and where to install \(selection.publicKeyName)."
            )
            card {
                VStack(alignment: .leading, spacing: 12) {
                    label("RECIPIENT PUBLIC KEY")
                    Text(selection.publicKeyFingerprint)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgMuted)
                        .textSelection(.enabled)
                    if selection.publicKeyProtection == .software {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(T.amber)
                            Text("Software-backed simulator key. It is not protected by Secure Enclave; grant access only to test hosts you intend this simulator to use.")
                                .tesseraSansScaled(size: 13)
                                .foregroundStyle(T.fgMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("bootstrap.software-key-warning")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                label("OPTIONAL HOST DATA · OFF BY DEFAULT")
                Text("These fields may contain secrets or change first-connect trust. Select only what you intend to copy to \(selection.peerDisplayName).")
                    .tesseraSansScaled(size: 13)
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(BootstrapOptionalTransfer.allCases) { transfer in
                    Button {
                        coordinator.setOptionalTransfer(
                            transfer,
                            selected: !selection.selectedOptionalTransfers.contains(transfer)
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selection.selectedOptionalTransfers.contains(transfer)
                                ? "checkmark.square.fill" : "square")
                                .frame(width: 18)
                                .foregroundStyle(T.fg)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(optionalTransferTitle(transfer))
                                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                                    .foregroundStyle(T.fg)
                                Text(optionalTransferDetail(transfer))
                                    .tesseraSansScaled(size: 13)
                                    .foregroundStyle(T.fgMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(T.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(T.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bootstrap.optional.\(transfer.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                label("HOST GRANTS")
                ForEach(selection.checklist) { item in
                    Button {
                        guard item.isGrantEligible else { return }
                        coordinator.setGrantSelected(
                            hostID: item.id,
                            selected: !selection.selectedHostIDs.contains(item.id)
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: grantSelectionSymbol(item, selection: selection))
                                .frame(width: 18)
                                .foregroundStyle(item.isGrantEligible ? T.fg : T.fgFaint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.hostName)
                                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                                    .foregroundStyle(T.fg)
                                Text(item.detail)
                                    .tesseraSansScaled(size: 13)
                                    .foregroundStyle(T.fgMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(T.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(T.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isGrantEligible)
                    .accessibilityIdentifier("bootstrap.grant.\(item.id.uuidString)")
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    receiptLine("hosts, jump routes, port forwards, and portable appearance", symbol: "server.rack")
                    receiptLine(
                        "\(selection.selectedOptionalTransfers.count) optional data categor\(selection.selectedOptionalTransfers.count == 1 ? "y" : "ies") selected",
                        symbol: "checklist"
                    )
                    receiptLine("no passwords or private keys move", symbol: "lock.fill", color: T.green)
                    receiptLine("\(selection.selectedCount) public-key grant\(selection.selectedCount == 1 ? "" : "s") selected", symbol: "key", color: T.green)
                }
            }
            Btn("approve selected batch", style: .primary, full: true) {
                coordinator.approveOriginTransfer()
            }
            .accessibilityIdentifier("bootstrap.approve")
            Text("Sending to \(selection.peerDisplayName). Its displayed name is never used as a security decision.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
        }
    }

    private func progress(title: String, detail: String) -> some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                ProgressView().tint(T.fg)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(Typography.tesseraMono(size: 15, weight: .medium))
                        .foregroundStyle(T.fg)
                    Text(detail)
                        .tesseraSansScaled(size: 14)
                        .foregroundStyle(T.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func receiptView(_ receipt: BootstrapFlowReceipt) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            switch receipt.direction {
            case .sent(let hostCount):
                title(
                    "Setup sent",
                    detail: "\(hostCount) host\(hostCount == 1 ? "" : "s") sent securely. Credentials remain local to each device."
                )
            case .received(let imported):
                title(
                    "Setup inherited",
                    detail: "Imported \(imported.insertedHosts) host\(imported.insertedHosts == 1 ? "" : "s"), \(imported.insertedJumpLinks) jump route\(imported.insertedJumpLinks == 1 ? "" : "s"), and \(imported.insertedKnownHosts) trusted host key\(imported.insertedKnownHosts == 1 ? "" : "s")."
                )
                if imported.skippedKnownHosts > 0 {
                    Text("\(imported.skippedKnownHosts) identical trusted host key\(imported.skippedKnownHosts == 1 ? " was" : "s were") already present.")
                        .tesseraSansScaled(size: 13)
                        .foregroundStyle(T.fgMuted)
                }
                if imported.conflictingKnownHosts > 0 {
                    Text("\(imported.conflictingKnownHosts) local trusted host key conflict\(imported.conflictingKnownHosts == 1 ? " was" : "s were") preserved for review in Known Hosts.")
                        .tesseraSansScaled(size: 13, weight: .semibold)
                        .foregroundStyle(T.amber)
                }
            }

            if !receipt.grantReceipt.results.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    label("HOST ACCESS RECEIPT")
                    Text("This is the acknowledged result for every host. Failed, skipped, and credential-ineligible hosts are never reported as authorized.")
                        .tesseraSansScaled(size: 14)
                        .foregroundStyle(T.fgMuted)

                    ForEach(receipt.grantReceipt.results) { result in
                        card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: grantResultSymbol(result.status))
                                        .foregroundStyle(grantResultColor(result.status))
                                    Text(result.hostName)
                                        .font(Typography.tesseraMono(size: 13, weight: .medium))
                                        .foregroundStyle(T.fg)
                                    Spacer()
                                    Text(grantResultLabel(result.status))
                                        .font(Typography.tesseraMono(size: 10, weight: .semibold))
                                        .foregroundStyle(grantResultColor(result.status))
                                }
                                Text(result.detail ?? grantResultDetail(result.status))
                                    .tesseraSansScaled(size: 13)
                                    .foregroundStyle(T.fgMuted)
                                if result.status.offersConfigureLater,
                                   let item = receipt.credentialChecklist.first(where: { $0.id == result.hostID }) {
                                    Btn("configure later", compact: true) {
                                        onConfigureHost(item)
                                    }
                                    .accessibilityIdentifier("bootstrap.configure.\(result.id.uuidString)")
                                }
                            }
                        }
                    }
                }
            }

            Btn("done", style: .primary, full: true) {
                coordinator.finish()
            }
            .accessibilityIdentifier("bootstrap.done")
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            title(
                "Nearby setup stopped",
                detail: message
            )
            card {
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
                Text(message)
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

    private func title(_ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(Typography.pageTitle)
                .foregroundStyle(T.fg)
            Text(detail)
                .tesseraSansScaled(size: 15)
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeCard(_ code: String) -> some View {
        Text(code)
            .font(Typography.tesseraMono(size: 38, weight: .semibold))
            .tracking(4)
            .foregroundStyle(T.fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(T.borderStrong, lineWidth: 1)
            )
            .accessibilityIdentifier("bootstrap.code")
    }

    private func card<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(T.border, lineWidth: 1)
            )
    }

    private func label(_ value: String) -> some View {
        Text(value)
            .font(Typography.kicker)
            .tracking(0.6)
            .foregroundStyle(T.fgDim)
    }

    private func receiptLine(
        _ value: String,
        symbol: String,
        color: Color? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(color ?? T.fgMuted)
            Text(value)
                .tesseraSansScaled(size: 14)
                .foregroundStyle(T.fgMuted)
        }
    }

    private func grantSelectionSymbol(
        _ item: BootstrapCredentialChecklistItem,
        selection: BootstrapGrantSelectionState
    ) -> String {
        guard item.isGrantEligible else { return "minus.square" }
        return selection.selectedHostIDs.contains(item.id)
            ? "checkmark.square.fill" : "square"
    }

    private func optionalTransferTitle(_ transfer: BootstrapOptionalTransfer) -> String {
        switch transfer {
        case .launchCommands: "launch commands"
        case .notes: "notes"
        case .environmentVariables: "environment variables"
        case .startupSnippets: "startup snippets"
        case .trustedHostKeys: "trusted host keys"
        }
    }

    private func optionalTransferDetail(_ transfer: BootstrapOptionalTransfer) -> String {
        switch transfer {
        case .launchCommands:
            "Custom shell commands. These may contain secrets."
        case .notes:
            "Free-form host notes. These may contain sensitive text."
        case .environmentVariables:
            "Environment variables. These commonly contain tokens or credentials."
        case .startupSnippets:
            "Shell text run at startup. This may contain secrets."
        case .trustedHostKeys:
            "The receiving device will trust the same server keys without prompting again. Existing conflicts are preserved for review."
        }
    }

    private func grantResultSymbol(_ status: BootstrapHostGrantStatus) -> String {
        switch status {
        case .installed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .notSelected: return "minus.circle"
        case .rejectedImport: return "exclamationmark.triangle"
        case .excludedAuthentication: return "lock.circle"
        }
    }

    private func grantResultLabel(_ status: BootstrapHostGrantStatus) -> String {
        switch status {
        case .installed: return "AUTHORIZED"
        case .failed: return "FAILED"
        case .notSelected: return "NOT SELECTED"
        case .rejectedImport: return "NOT IMPORTED"
        case .excludedAuthentication: return "EXCLUDED"
        }
    }

    private func grantResultDetail(_ status: BootstrapHostGrantStatus) -> String {
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

    private func grantResultColor(_ status: BootstrapHostGrantStatus) -> Color {
        switch status {
        case .installed: return T.green
        case .failed: return T.red
        case .notSelected, .rejectedImport, .excludedAuthentication: return T.fgDim
        }
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
