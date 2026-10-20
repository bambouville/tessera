import SwiftUI
import TesseraCore

/// The consent surface shared by both setup transports.
///
/// Nearby (Bonjour) bootstrap and QR pairing move the same manifest under the
/// same rules, so they must ask the same questions: which recipient key is being
/// trusted, which optional host text is copied, and which hosts get a key grant
/// installed. These views are that single implementation — QR pairing used to
/// approve a bare host count, which gave the sender no way to see or narrow what
/// was leaving the device.
enum BootstrapConsent {
    static func optionalTransferTitle(_ transfer: BootstrapOptionalTransfer) -> LocalizedStringResource {
        switch transfer {
        case .launchCommands: "launch commands"
        case .notes: "notes"
        case .environmentVariables: "environment variables"
        case .startupSnippets: "startup snippets"
        case .trustedHostKeys: "trusted host keys"
        }
    }

    static func optionalTransferDetail(_ transfer: BootstrapOptionalTransfer) -> LocalizedStringResource {
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
}

/// Panel surface used by every consent section.
struct BootstrapConsentCard<Content: View>: View {
    @Environment(\.designTokens) private var T
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(T.border, lineWidth: 1)
            )
    }
}

struct BootstrapConsentLabel: View {
    @Environment(\.designTokens) private var T
    let value: LocalizedStringKey

    init(_ value: LocalizedStringKey) { self.value = value }

    var body: some View {
        Text(value)
            .font(Typography.kicker)
            .tracking(0.6)
            .foregroundStyle(T.fgDim)
    }
}

/// Selectable row shared by the optional-data and host-grant lists.
private struct BootstrapConsentRow: View {
    @Environment(\.designTokens) private var T
    let symbol: String
    let symbolColor: Color
    let title: Text
    let detail: Text
    let isEnabled: Bool
    let isSelected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(symbolColor)
                VStack(alignment: .leading, spacing: 4) {
                    title
                        .font(Typography.tesseraMono(size: 13, weight: .medium))
                        .foregroundStyle(T.fg)
                    detail
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
        .disabled(!isEnabled)
        .accessibilityValue(isSelected ? Text("selected") : Text("not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The recipient's public key, with the software-key warning it must carry.
struct BootstrapRecipientKeyCard: View {
    @Environment(\.designTokens) private var T
    let fingerprint: String
    /// The two transports carry different protection enums, so the caller
    /// decides whether to warn.
    let showsSoftwareKeyWarning: Bool
    /// Nearby pairs with another Apple device, so it can name the simulator case.
    /// QR pairs with anything, so it states the property rather than the device.
    var softwareKeyWarning: LocalizedStringKey =
        "Software-backed simulator key. It is not protected by Secure Enclave; grant access only to test hosts you intend this simulator to use."
    var identifierPrefix: String = "bootstrap"

    var body: some View {
        BootstrapConsentCard {
            VStack(alignment: .leading, spacing: 12) {
                BootstrapConsentLabel("RECIPIENT PUBLIC KEY")
                Text(fingerprint)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .textSelection(.enabled)
                if showsSoftwareKeyWarning {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(T.amber)
                        Text(softwareKeyWarning)
                            .tesseraSansScaled(size: 13)
                            .foregroundStyle(T.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("\(identifierPrefix).software-key-warning")
                }
            }
        }
    }
}

/// Optional host text, off by default because it can carry secrets.
struct BootstrapOptionalTransfersSection: View {
    @Environment(\.designTokens) private var T
    let peerDisplayName: String
    let selected: Set<BootstrapOptionalTransfer>
    var identifierPrefix: String = "bootstrap"
    let onToggle: (BootstrapOptionalTransfer, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BootstrapConsentLabel("OPTIONAL HOST DATA · OFF BY DEFAULT")
            Text("These fields may contain secrets or change first-connect trust. Select only what you intend to copy to \(peerDisplayName).")
                .tesseraSansScaled(size: 13)
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(BootstrapOptionalTransfer.allCases) { transfer in
                BootstrapConsentRow(
                    symbol: selected.contains(transfer) ? "checkmark.square.fill" : "square",
                    symbolColor: T.fg,
                    title: Text(BootstrapConsent.optionalTransferTitle(transfer)),
                    detail: Text(BootstrapConsent.optionalTransferDetail(transfer)),
                    isEnabled: true,
                    isSelected: selected.contains(transfer),
                    identifier: "\(identifierPrefix).optional.\(transfer.rawValue)",
                    action: { onToggle(transfer, !selected.contains(transfer)) }
                )
            }
        }
    }
}

/// What the checkbox means differs by transport, so the caller says which.
enum BootstrapHostSelectionMode {
    /// Nearby: every host is copied regardless; the box picks which hosts get
    /// the recipient's key installed, so hosts that cannot take a grant are
    /// visible but unselectable.
    case grants
    /// QR: the box picks which hosts are copied at all, because the pairing
    /// transaction binds the authorization set to the filtered manifest. Every
    /// host is selectable — a password host is still worth copying.
    case copy
}

/// Which hosts are involved, and to what extent.
struct BootstrapHostGrantsSection: View {
    @Environment(\.designTokens) private var T
    let checklist: [BootstrapCredentialChecklistItem]
    let selectedHostIDs: Set<UUID>
    var mode: BootstrapHostSelectionMode = .grants
    var identifierPrefix: String = "bootstrap"
    let onToggle: (UUID, Bool) -> Void

    private var sectionLabel: LocalizedStringKey {
        switch mode {
        case .grants: "HOST GRANTS"
        case .copy: "HOSTS TO COPY"
        }
    }

    private func isSelectable(_ item: BootstrapCredentialChecklistItem) -> Bool {
        switch mode {
        case .grants: item.isGrantEligible
        case .copy: true
        }
    }

    private func symbol(_ item: BootstrapCredentialChecklistItem) -> String {
        guard isSelectable(item) else { return "minus.square" }
        return selectedHostIDs.contains(item.id) ? "checkmark.square.fill" : "square"
    }

    private func detail(_ item: BootstrapCredentialChecklistItem) -> LocalizedStringResource {
        switch mode {
        case .grants: item.detail
        case .copy: item.copyDetail
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BootstrapConsentLabel(sectionLabel)
            ForEach(checklist) { item in
                BootstrapConsentRow(
                    symbol: symbol(item),
                    symbolColor: isSelectable(item) ? T.fg : T.fgFaint,
                    title: Text(verbatim: item.hostName),
                    detail: Text(detail(item)),
                    isEnabled: isSelectable(item),
                    isSelected: selectedHostIDs.contains(item.id),
                    identifier: "\(identifierPrefix).grant.\(item.id.uuidString)",
                    action: {
                        guard isSelectable(item) else { return }
                        onToggle(item.id, !selectedHostIDs.contains(item.id))
                    }
                )
            }
        }
    }
}

// MARK: - Native setup screens (nearby and QR)

struct SetupFlowShell<Content: View>: View {
    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: LocalizedStringKey
    let presentation: SetupFlowPresentationV1.Output
    let identifier: String
    var canCancel = true
    let cancel: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(T.fg)
                    Spacer()
                    if canCancel {
                        Button("cancel", action: cancel)
                            .font(.subheadline).foregroundStyle(T.fgMuted)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("\(identifier).cancel")
                    }
                }
                if presentation.status != .failed {
                    SetupFlowSteps(presentation: presentation)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: presentation.currentStage)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .background(sizeClass == .compact ? Color.clear : T.bg, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if sizeClass != .compact { RoundedRectangle(cornerRadius: 18).stroke(T.border, lineWidth: 1) }
            }
            .padding(sizeClass == .compact ? 0 : 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(T.presentationBg.ignoresSafeArea())
    }
}

struct SetupFlowSteps: View {
    @Environment(\.designTokens) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: SetupFlowPresentationV1.Output
    private func title(_ stage: SetupFlowPresentationV1.Stage) -> LocalizedStringKey {
        switch stage {
        case .scan: "Scan"
        case .discover: "Discover"
        case .verify: "Verify"
        case .choose: "Choose"
        case .transfer: "Transfer"
        case .connect: "Connect"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(presentation.stages.enumerated()), id: \.offset) { index, stage in
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(index <= presentation.currentStageIndex ? T.fg : T.border).frame(height: 3)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(title(stage)).font(.caption).foregroundStyle(stage == presentation.currentStage ? T.fg : T.fgDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(title(stage)))
                    .accessibilityAddTraits(stage == presentation.currentStage ? .isSelected : [])
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                (Text(title(presentation.currentStage)) + Text(verbatim: " · \(presentation.currentStageIndex + 1)/\(presentation.stages.count)"))
                    .font(.caption).foregroundStyle(T.fg)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct SetupFlowHeading: View {
    @Environment(\.designTokens) private var T
    let title: Text
    let detail: Text
    var symbol: String = "ipad.and.iphone"
    init(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String = "ipad.and.iphone") {
        self.title = Text(title); self.detail = Text(detail); self.symbol = symbol
    }
    init(_ title: LocalizedStringKey, resolvedDetail: String, symbol: String = "ipad.and.iphone") {
        self.title = Text(title); self.detail = Text(verbatim: resolvedDetail); self.symbol = symbol
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(T.fg).accessibilityHidden(true)
            title.font(.title2.weight(.semibold)).foregroundStyle(T.fg)
            detail.font(.subheadline).foregroundStyle(T.fgMuted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SetupFlowProgress: View {
    @Environment(\.designTokens) private var T
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    var body: some View {
        BootstrapConsentCard {
            HStack(alignment: .top, spacing: 14) {
                ProgressView().tint(T.fgMuted)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(T.fg)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(T.fgMuted).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
}

struct SetupCodeVerification: View {
    @Environment(\.designTokens) private var T
    let code: String
    let waiting: Bool
    let codeIdentifier: String
    let matchIdentifier: String
    let rejectIdentifier: String
    let confirm: () -> Void
    let reject: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupFlowHeading(waiting ? "Confirm on your other device" : "Do the codes match?",
                             detail: waiting ? "This device confirmed the code. Confirm the same code on the other screen to continue." : "Compare all six digits on both screens before continuing. No setup has been sent yet.",
                             symbol: waiting ? "checkmark.shield" : "lock.shield")
            Text(verbatim: code)
                .font(.system(size: 42, weight: .medium, design: .monospaced)).tracking(6)
                .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(T.fg)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
                .background(T.panelBg, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier(codeIdentifier)
                .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
            if waiting {
                SetupFlowProgress(title: "waiting for the other device")
            } else {
                Button("codes match", action: confirm).buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier(matchIdentifier)
                Button("does not match", role: .destructive, action: reject).buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier(rejectIdentifier)
            }
        }
    }
}

struct SetupSelectionReview: View {
    @Environment(\.designTokens) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    let selection: BootstrapGrantSelectionState
    let mode: BootstrapHostSelectionMode
    let identifier: String
    let softwareKeyWarning: LocalizedStringKey
    let onHost: (UUID, Bool) -> Void
    let onOptional: (BootstrapOptionalTransfer, Bool) -> Void
    let approve: () -> Void
    private var projection: SetupFlowPresentationV1.Output {
        SetupFlowPresentationV1.project(.init(phase: .choosing, supportedActions: [.approve], selection: .init(
            mode: mode == .copy ? .copy : .grants, allHostIDs: selection.checklist.map(\.id),
            selectedHostIDs: Array(selection.selectedHostIDs), grantEligibleHostIDs: selection.checklist.filter(\.isGrantEligible).map(\.id)
        )))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Review setup", selection: $step) {
                Text("Hosts").tag(0); Text("Include").tag(1); Text("Review").tag(2)
            }.pickerStyle(.segmented)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: step)
            if step == 0 {
                SetupFlowHeading("Choose your hosts", detail: mode == .copy
                    ? "Choose which hosts to copy. Required jump hosts are included with their routes."
                    : "All hosts are copied. Choose which hosts also receive this device’s public key for access.", symbol: "server.rack")
                BootstrapHostGrantsSection(checklist: selection.checklist, selectedHostIDs: selection.selectedHostIDs,
                                          mode: mode, identifierPrefix: identifier, onToggle: onHost)
                Button("next: choose data") { step = 1 }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!projection.allows(.approve))
            } else if step == 1 {
                SetupFlowHeading("Make it feel familiar", detail: "Host addresses, jump routes, port forwards, and portable appearance settings are included. Choose any additional data below.", symbol: "slider.horizontal.3")
                BootstrapOptionalTransfersSection(peerDisplayName: selection.peerDisplayName,
                    selected: selection.selectedOptionalTransfers, identifierPrefix: identifier, onToggle: onOptional)
                Button("next: review transfer") { step = 2 }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                SetupFlowHeading("Ready to copy", detail: "Review this transfer to \(selection.peerDisplayName). Passwords and private keys never leave this device.", symbol: "checklist")
                BootstrapConsentCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(selection.checklist.filter { projection.copiedHostIDs.contains($0.id) }) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(item.hostName, systemImage: "server.rack").font(.subheadline).foregroundStyle(T.fg)
                                if mode == .grants {
                                    Text(projection.grantedHostIDs.contains(item.id) ? "Public-key access selected" : "Configuration only")
                                        .font(.caption).foregroundStyle(T.fgMuted)
                                }
                            }
                        }
                        ForEach(BootstrapOptionalTransfer.allCases.filter { selection.selectedOptionalTransfers.contains($0) }) { transfer in
                            Text(BootstrapConsent.optionalTransferTitle(transfer)).font(.subheadline).foregroundStyle(T.fgMuted)
                        }
                        Text(verbatim: String(localized: "\(selection.selectedOptionalTransfers.count) optional data categories selected"))
                            .font(.caption).foregroundStyle(T.fgMuted)
                        Text(verbatim: String(localized: "\(projection.grantedHostIDs.count) public-key grants selected"))
                            .font(.caption).foregroundStyle(T.fgMuted)
                    }
                }
                BootstrapRecipientKeyCard(fingerprint: selection.publicKeyFingerprint,
                    showsSoftwareKeyWarning: selection.publicKeyProtection == .software,
                    softwareKeyWarning: softwareKeyWarning, identifierPrefix: identifier)
                Button("approve transfer", action: approve).buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!projection.allows(.approve)).accessibilityIdentifier("\(identifier).approve")
            }
        }
        .onChange(of: selection.code) { _, _ in step = 0 }
        .onChange(of: selection.publicKeyFingerprint) { _, _ in step = 0 }
    }
}

enum SetupAccessCopy {
    static func failure(_ reason: SetupFlowPresentationV1.FailureReason) -> LocalizedStringResource {
        switch reason {
        case .expired: "This pairing code expired. Show a new code on the sending device and scan it again."
        case .codeMismatch: "The security codes were rejected. Start again and compare the new code on both devices."
        case .disconnected: "The other device disconnected. Keep both devices open on the same network and start again."
        case .locked: "Pairing stopped because a device locked. Unlock both devices and start again."
        case .policyChanged: "Security settings changed during pairing. Review the settings and start again."
        case .protocolError: "The transfer could not be verified. Start a fresh pairing attempt."
        case .other: "Pairing did not finish. Review any copied hosts before starting again."
        }
    }
    static func label(_ outcome: SetupFlowPresentationV1.Outcome) -> LocalizedStringResource {
        switch outcome {
        case .authorized: "AUTHORIZED"
        case .alreadyAuthorized: "ALREADY AUTHORIZED"
        case .configurationCopied: "CONFIGURATION COPIED"
        case .passwordNeeded: "PASSWORD ON FIRST CONNECT"
        case .failed: "FAILED"
        case .skipped: "SKIPPED"
        case .notSelected: "NOT SELECTED"
        case .notImported: "NOT IMPORTED"
        case .excluded: "EXCLUDED"
        case .uncertain: "ACCESS NOT VERIFIED"
        }
    }
}

struct SetupHostAccessRow: View {
    @Environment(\.designTokens) private var T
    let name: String
    let outcome: SetupFlowPresentationV1.Outcome
    var detail: Text? = nil
    var configureIdentifier: String = ""
    var configure: (() -> Void)? = nil
    private var color: Color {
        switch outcome {
        case .authorized, .alreadyAuthorized: T.green
        case .failed: T.red
        case .uncertain: T.amber
        default: T.fgMuted
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Vertical status survives narrow screens and accessibility sizes.
            Text(verbatim: name).font(.subheadline.weight(.medium)).foregroundStyle(T.fg)
            Text(SetupAccessCopy.label(outcome)).font(.caption.weight(.semibold)).foregroundStyle(color)
            if let detail { detail.font(.subheadline).foregroundStyle(T.fgMuted).fixedSize(horizontal: false, vertical: true) }
            if let configure {
                Button("configure later", action: configure).buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier(configureIdentifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
/// Host-free native surface oracle. Uses the exact components composed by
/// Bonjour and QR; never creates a key, runtime, or network connection.
struct SetupFlowPresentationHarness: View {
    @State private var phase: SetupFlowPresentationV1.Phase = .compareCode
    @State private var configured = false
    @State private var selection = BootstrapGrantSelectionState(
        peerDisplayName: "Review iPhone", code: "123456", publicKeyName: "Device key",
        publicKeyFingerprint: "SHA256:fixture-public-key-only", publicKeyProtection: .software,
        checklist: [.init(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                          hostName: "Build server", authenticationHint: .publicKey),
                    .init(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                          hostName: "Password server", authenticationHint: .password)],
        selectedHostIDs: [], selectedOptionalTransfers: [])
    private var nearby: Bool { ProcessInfo.processInfo.environment["TESSERA_SETUP_FLOW_MODE"] == "nearby" }
    var body: some View {
        SetupFlowShell(title: "Bring your setup with you", presentation: SetupFlowPresentationV1.project(
            .init(entry: nearby ? .nearby : .qr, phase: phase)), identifier: "setup-harness", cancel: {}) {
            if phase == .compareCode {
                SetupCodeVerification(code: "123456", waiting: false, codeIdentifier: "harness.code",
                    matchIdentifier: "harness.match", rejectIdentifier: "harness.reject",
                    confirm: { phase = .choosing }, reject: { phase = .failed })
            } else if phase == .choosing {
                SetupSelectionReview(selection: selection, mode: nearby ? .grants : .copy, identifier: "harness",
                    softwareKeyWarning: "Software-backed key. It is not hardware protected.",
                    onHost: { id, selected in
                        if selected { selection.selectedHostIDs.insert(id) } else { selection.selectedHostIDs.remove(id) }
                    }, onOptional: { item, selected in
                        if selected { selection.selectedOptionalTransfers.insert(item) } else { selection.selectedOptionalTransfers.remove(item) }
                    }, approve: { phase = .completed })
            } else if phase == .failed {
                SetupFlowHeading("Pairing stopped", resolvedDetail: String(localized: SetupAccessCopy.failure(.codeMismatch)), symbol: "exclamationmark.shield")
                Button("start again") { phase = .compareCode }
            } else {
                SetupFlowHeading("Setup copied", detail: "Some hosts still need attention.", symbol: "checkmark.circle")
                SetupHostAccessRow(name: "Build server", outcome: nearby ? .notSelected : .authorized,
                    detail: Text(nearby ? "Configuration was copied. No public-key access was selected." : "The recipient public key was installed and verified."))
                SetupHostAccessRow(name: "Password server", outcome: .passwordNeeded,
                    detail: Text("The password stays on this device. Configure it when you connect."),
                    configureIdentifier: "harness.configure", configure: { configured = true })
                if configured { Text("Host configuration requested").accessibilityIdentifier("harness.configured") }
            }
        }
        .dynamicTypeSize(ProcessInfo.processInfo.environment["TESSERA_SETUP_FLOW_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
    }
}
#endif
