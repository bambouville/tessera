import SwiftUI
import TesseraCore

/// A foreground-only presentation for the local Pairing-v1 adapter. The
/// protocol coordinator owns all state transitions; this view only makes the
/// user-visible consent, comparison, retry, and cancellation boundaries
/// explicit. Phone uses the available screen, while iPad keeps the pairing
/// surface deliberately bounded beside the terminal workspace.
struct CrossDevicePairingView: View {
    @Environment(\.designTokens) private var T
    @Bindable var coordinator: CrossDevicePairingCoordinator
    var onReceivedSetupFinished: () -> Void = {}
    @StateObject private var scanner = PairingQRCodeScannerModel()
    @State private var manualText = ""
    @State private var showsManualEntry = false

    var body: some View {
        ZStack {
            T.presentationBg
                .ignoresSafeArea()

            Group {
                if case .scanning = coordinator.phase {
                    scannerSurface
                } else {
                    SetupFlowShell(title: flowTitle, presentation: coordinator.presentation, identifier: "pairing", cancel: coordinator.cancel) { cardSurface }
                }
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("pairing.flow")
        .onChange(of: coordinator.phase) { _, phase in
            if case .scanning = phase {
                scanner.onCanonicalText = { text in coordinator.beginRecipient(qrText: text) }
                scanner.restart()
            } else {
                scanner.cancel()
            }
        }
        .onAppear {
            scanner.onCanonicalText = { text in coordinator.beginRecipient(qrText: text) }
        }
        .onDisappear { scanner.cancel() }
    }

    private var flowTitle: LocalizedStringKey {
        switch coordinator.presentationPurpose {
        case .continueSession: "continue on another device"
        case .setUpAndContinue: "set up & continue"
        default: "bring your setup with you"
        }
    }

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch coordinator.phase {
            case .showingOffer:
                SetupFlowHeading("Scan with your other device", detail: "Open Tessera → Settings → sync & continuity on the other device. On Apple, tap “scan pairing code.” On Android, tap “pair another device,” then “scan pairing code.” Keep both devices on the same network.", symbol: "qrcode.viewfinder")
                if let text = coordinator.qrText,
                   let image = try? PairingQRCodeRenderer.image(forCanonicalText: text, side: 360) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(20)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Pairing QR code")
                }
                Label("Next, compare a six-digit code on both screens.", systemImage: "lock.shield")
                    .font(.subheadline).foregroundStyle(T.fgMuted)
            case .connecting:
                SetupFlowHeading("Connecting your devices", detail: "Keep Tessera open on both devices. A security code will appear when the encrypted channel is ready.", symbol: "ipad.and.iphone")
                SetupFlowProgress(title: "preparing a local pairing channel")
            case .transferring:
                SetupFlowHeading("Keep both devices open", detail: "Follow the current instruction below. Both devices must stay open until the transfer finishes.", symbol: "arrow.triangle.2.circlepath")
                SetupFlowProgress(title: operationTitle)
            case .waitingForSetupChoice:
                SetupFlowHeading("Choose on the sending device", detail: "Your devices are verified. Choose the hosts and data to copy on the device sending setup; the receiving device will review them next.", symbol: "checklist")
                SetupFlowProgress(title: "waiting for setup selection")
            case .compareSAS(let sas):
                verification(sas, waiting: false)
            case .waitingForPeerSAS(let sas):
                verification(sas, waiting: true)
            case .bootstrapOriginApproval(let selection):
                originApproval(selection)
            case .bootstrapRecipientImport(let checklist):
                recipientImport(checklist)
            case .completed(let receipt):
                if receipt?.hasUnverifiedAccess == true {
                    SetupFlowHeading("Setup copied", detail: "Some hosts still need access setup. Review the results below before connecting.", symbol: "checklist")
                } else {
                    SetupFlowHeading("You’re ready", detail: receipt == nil
                            ? "Your devices have finished this transfer."
                            : "Your devices have finished this transfer. Review the results below.", symbol: "checkmark.circle")
                }
                if let receipt { self.receiptView(receipt) }
                Button("done") {
                    let showsHosts = coordinator.finishedReceivingSetup
                    coordinator.dismiss()
                    if showsHosts { onReceivedSetupFinished() }
                }.buttonStyle(.borderedProminent).controlSize(.large)
            case .failed(let message):
                SetupFlowHeading("pairing stopped", resolvedDetail: message, symbol: "exclamationmark.triangle")
                Button("done") { coordinator.dismiss() }.buttonStyle(.bordered).controlSize(.large)
            case .idle, .scanning:
                EmptyView()
            }
        }
    }

    private func verification(_ code: String, waiting: Bool) -> some View {
        SetupCodeVerification(code: code, waiting: waiting, codeIdentifier: "pairing.security-code",
            matchIdentifier: "pairing.codes-match", rejectIdentifier: "pairing.codes-reject",
            confirm: { coordinator.decideSAS(matches: true) }, reject: { coordinator.decideSAS(matches: false) })
    }

    private func originApproval(_ selection: BootstrapGrantSelectionState) -> some View {
        SetupSelectionReview(selection: selection, mode: .copy, identifier: "pairing",
            softwareKeyWarning: "This device did not prove its key is hardware protected. Grant access only to hosts you intend the paired device to reach.",
            onHost: { coordinator.setGrantSelected(hostID: $0, selected: $1) },
            onOptional: { coordinator.setOptionalTransfer($0, selected: $1) },
            approve: coordinator.approveBootstrapOrigin)
            .id(coordinator.presentationAttempt)
    }

    /// What the transfer actually did, per host. A bare "complete" left the
    /// sender no record of whether each host's key access was installed.
    @ViewBuilder
    private func receiptView(_ receipt: CrossDevicePairingReceipt) -> some View {
        BootstrapConsentCard {
            VStack(alignment: .leading, spacing: 10) {
                BootstrapConsentLabel(
                    receipt.direction == .sent ? "COPIED TO THE PAIRED DEVICE" : "IMPORTED FROM THE PAIRED DEVICE"
                )
                ForEach(receipt.hosts) { host in
                    SetupHostAccessRow(name: host.name, outcome: host.presentationOutcome)
                }
                if receipt.direction == .sent {
                    // Reuses the nearby receipt's wording so the count
                    // pluralizes correctly and inherits its translations.
                    Text(verbatim: String(
                        localized: "\(receipt.optionalCategoryCount) optional data categories selected",
                        comment: "Pairing receipt line. Pluralized on the category count."
                    ))
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.fgDim)
                }
                Text("No passwords or private keys were transferred.")
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.green)
            }
        }
    }

    @ViewBuilder
    private func recipientImport(_ checklist: [BootstrapCredentialChecklistItem]) -> some View {
        Text("import paired setup")
            .font(Typography.tesseraMono(size: 16, weight: .medium))
            .foregroundStyle(T.fg)
        Text("These hosts were approved by the other device. You will use this device's own key; passwords and private keys are not imported.")
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgMuted)
            .fixedSize(horizontal: false, vertical: true)

        BootstrapConsentCard {
            VStack(alignment: .leading, spacing: 10) {
                BootstrapConsentLabel("HOSTS BEING IMPORTED")
                ForEach(checklist) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "server.rack")
                            .frame(width: 18)
                            .foregroundStyle(T.fgMuted)
                        Text(verbatim: item.hostName)
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(T.fg)
                        Spacer()
                    }
                }
            }
        }

        Button("import setup") { coordinator.approveBootstrapRecipientImport() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("pairing.import")
    }

    private var operationTitle: LocalizedStringKey {
        switch coordinator.operationStatus {
        case .authorizing: "Confirm authentication on this device"
        case .importing: "Importing approved setup"
        case .waitingForGrant: "Setup copied. Waiting for the sender to authorize access."
        case .granting: "Installing and verifying the recipient key"
        case .recordingAccess: "Recording verified access on both devices"
        case .awaitingConnection: "Waiting for the other device to connect"
        default: "finishing the approved transfer"
        }
    }

    private var scannerSurface: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                PairingQRCodeScannerView(model: scanner)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("scan pairing code")
                                .font(.headline)
                            Spacer()
                            Button("cancel") { coordinator.cancel() }
                        }
                        .foregroundStyle(T.fg)
                        Text("Point the camera at the QR code in Tessera on your other device.")
                            .font(.subheadline).foregroundStyle(T.fgMuted)
                        DisclosureGroup("Enter a pairing code instead", isExpanded: $showsManualEntry) {
                            HStack(alignment: .center, spacing: 12) {
                                TextField("paste pairing text", text: $manualText, axis: .vertical)
                                    .accessibilityIdentifier("pairing.manual-text")
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(2...4)
                                Button("use code") { _ = scanner.submitManualText(manualText) }
                                    .buttonStyle(.bordered)
                                    .fixedSize()
                                    .frame(minHeight: 44)
                                    .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            Text("Camera unavailable? Paste the code instead.")
                                .font(.caption).foregroundStyle(T.fgMuted)
                            if scanner.status == .invalidManualText {
                                Text("This code is invalid or expired. Ask the other device to show a new pairing code.")
                                    .font(.subheadline).foregroundStyle(T.red)
                            }
                        }
                    }
                    .padding(18)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: geometry.size.height * (showsManualEntry ? 0.75 : 0.35))
                .background(T.bg.opacity(0.96))
            }
        }
        .onAppear {
            showsManualEntry = scanner.status == .unavailable || scanner.status == .denied
        }
        .onChange(of: scanner.status) { _, status in
            if status == .unavailable || status == .denied { showsManualEntry = true }
        }
    }

}
