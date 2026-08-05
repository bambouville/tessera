import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

@Observable
final class KeysPagePresentationState {
    var showGenerateModal = false
    var showImportModal = false
    let generateDraft = GenerateKeyDraft()

    func presentGenerator(initialProtection: Bool) {
        generateDraft.reset(initialProtection: initialProtection)
        showGenerateModal = true
    }

    func closeGenerator() {
        showGenerateModal = false
        generateDraft.clear()
    }
}

struct PublicKeyCopyPayload: Equatable {
    let pasteboardValue: String
    let feedback: String

    init(publicKey: String) {
        pasteboardValue = publicKey
        feedback = "Public key copied"
    }
}

/// Keys page (M3). Two-pane: 340pt list + detail.
struct KeysPageView: View {
    @Bindable var presentation: KeysPagePresentationState
    @Environment(\.designTokens) private var T
    @Environment(\.modelContext) private var modelContext
    @Environment(AppearancePreferences.self) private var appearance
    @Query(sort: \StoredKey.createdAt, order: .reverse) private var keys: [StoredKey]
    @Query(sort: \PersistedHost.name) private var hosts: [PersistedHost]

    @State private var filterText = ""
    @State private var selectedID: UUID?
    @State private var didDefaultSelection = false
    @State private var showCopyToHostSheet = false
    @State private var toastText: String?
    @State private var recoveryPassphraseAction: RecoveryPassphraseAction?
    @State private var recoveryFilePurpose: RecoveryFilePurpose?
    @State private var showRecoveryFileImporter = false
    @State private var pendingExportDocument: EncryptedRecoveryDocument?
    @State private var pendingExportKeyID: UUID?
    @State private var pendingExportFilename = "tessera-recovery-key"
    @State private var showRecoveryFileExporter = false
    @State private var riskAcknowledgementKeyID: UUID?
    @State private var deleteCandidateID: UUID?
    @State private var deletionInProgress = false
    @State private var deletionTask: Task<Void, Never>?
    @State private var keyMaterialRevision = 0
    @State private var materialIntegrity: [UUID: KeyMaterialIntegrity] = [:]
    @State private var orphanedKeyIDs: Set<UUID> = []
    @State private var showOrphanCleanupConfirmation = false
    @State private var protectionUpdateKeyID: UUID?
    @State private var deviceAccessRevision = 0
    @State private var revokingDeviceAccessID: String?

    private let securityMetadata = KeySecurityMetadataStore()

    init(presentation: KeysPagePresentationState = KeysPagePresentationState()) {
        self.presentation = presentation
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private func presentGenerator() {
        presentation.presentGenerator(
            initialProtection: KeyOwnerPresencePolicy.initialKeyPreference(
                globalPreference: appearance.requireBiometricForKeyUse
            )
        )
    }

    private var filteredKeys: [StoredKey] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return keys }
        return keys.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var selectedKey: StoredKey? {
        guard let selectedID else { return nil }
        return keys.first { $0.id == selectedID }
    }

    private var trackedDeviceAccess: [KeySecurityMetadataStore.TrackedRemoteInstallation] {
        _ = deviceAccessRevision
        return securityMetadata.allRemoteInstallations().filter {
            $0.installation.flow != .manual
                || $0.installation.peerDeviceName != nil
                || $0.installation.verificationState == .uncertain
        }
    }

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()

            if isPhone {
                phoneContent
            } else {
                HStack(spacing: 0) {
                    leftPane

                    Rectangle()
                        .fill(T.border)
                        .frame(width: 1)

                    rightPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if presentation.showGenerateModal {
                GenerateKeyModal(
                    draft: presentation.generateDraft,
                    onClose: { presentation.closeGenerator() },
                    onCreated: { key in
                        selectedID = key.id
                        didDefaultSelection = true
                        beginInitialRecovery(for: key)
                    }
                )
                .zIndex(10)
            }

            if presentation.showImportModal {
                ImportKeyModal(
                    initialProtection: KeyOwnerPresencePolicy.initialKeyPreference(
                        globalPreference: appearance.requireBiometricForKeyUse
                    ),
                    onClose: { presentation.showImportModal = false },
                    onImported: { key in
                        selectedID = key.id
                        didDefaultSelection = true
                        beginInitialRecovery(for: key)
                    }
                )
                .zIndex(10)
            }

            if let action = recoveryPassphraseAction,
               let key = keys.first(where: { $0.id == action.keyID }) {
                RecoveryPassphraseModal(
                    keyName: displayName(for: key),
                    purpose: action.purpose,
                    onCancel: { clearRecoveryPassphraseAction() },
                    onSubmit: { passphrase in
                        Task { @MainActor in
                            await performRecoveryAction(
                                action,
                                passphrase: passphrase
                            )
                        }
                    }
                )
                .zIndex(30)
            }

            if let keyID = riskAcknowledgementKeyID,
               let key = keys.first(where: { $0.id == keyID }) {
                KeyRiskAcknowledgementModal(
                    key: key,
                    fingerprint: fingerprint(for: key),
                    onCancel: { riskAcknowledgementKeyID = nil },
                    onExport: (key.isSecureEnclave || key.algorithm != .ed25519) ? nil : {
                        riskAcknowledgementKeyID = nil
                        recoveryPassphraseAction = .export(keyID: key.id)
                    },
                    onAcknowledge: {
                        securityMetadata.acknowledgeDeviceBoundRisk(for: key.id)
                        riskAcknowledgementKeyID = nil
                        showCopyToHostSheet = true
                    }
                )
                .zIndex(30)
                .transaction { $0.animation = nil }
            }

            if let keyID = deleteCandidateID,
               let key = keys.first(where: { $0.id == keyID }) {
                KeyDeletionConfirmationModal(
                    key: key,
                    fingerprint: fingerprint(for: key),
                    hostNames: usedHostNames(for: key),
                    identityCount: usedIdentityCount(for: key),
                    securityRecord: securityMetadata.record(for: key.id),
                    eligibleRemoteRevocationCount: eligibleRemoteRevocationHosts(for: key).count,
                    isWorking: deletionInProgress,
                    onCancel: { deleteCandidateID = nil },
                    onConfirm: { deleteConfirmed(key) },
                    onRevokeAndConfirm: { revokeRemotelyThenDelete(key) }
                )
                .zIndex(30)
                .transaction { $0.animation = nil }
            }

            if showOrphanCleanupConfirmation {
                OrphanedKeyCleanupModal(
                    count: orphanedKeyIDs.count,
                    onCancel: { showOrphanCleanupConfirmation = false },
                    onConfirm: cleanupOrphanedPrivateMaterial
                )
                .zIndex(30)
                .transaction { $0.animation = nil }
            }
        }
        .onAppear {
            if !isPhone {
                applyInitialSelectionIfNeeded()
            }
            refreshIntegrityReport()
        }
        .onChange(of: keys.map(\.id)) { _, _ in
            reconcileSelectionAfterDataChange()
        }
        .sheet(isPresented: $showCopyToHostSheet) {
            if let selectedKey {
                InstallKeyToHostFlow(
                    key: selectedKey,
                    onClose: { showCopyToHostSheet = false }
                )
            }
        }
        .fileImporter(
            isPresented: $showRecoveryFileImporter,
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false,
            onCompletion: handleRecoveryFileSelection
        )
        .fileExporter(
            isPresented: $showRecoveryFileExporter,
            document: pendingExportDocument,
            contentType: .data,
            defaultFilename: pendingExportFilename,
            onCompletion: handleRecoveryExportCompletion
        )
        .onDisappear {
            deletionTask?.cancel()
        }
    }

    @ViewBuilder
    private var phoneContent: some View {
        if let selectedKey {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        selectedID = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(T.accent)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("back to keys")

                    Text(displayName(for: selectedKey))
                        .font(Typography.tesseraMono(size: 15, weight: .medium))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(T.border)
                        .frame(height: 1)
                }

                ScrollView {
                    keyDetail(selectedKey)
                        .padding(.horizontal, 18)
                        .padding(.top, 20)
                        .padding(.bottom, 32)
                }
            }
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    Text("keys")
                        .font(Typography.pageTitle)
                        .foregroundStyle(T.fg)

                    Spacer(minLength: 8)

                    Btn("+ generate", compact: true) {
                        presentGenerator()
                    }

                    Btn("import", compact: true) {
                        presentation.showImportModal = true
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

                Input(text: $filterText, placeholder: "search")
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                Rectangle()
                    .fill(T.border)
                    .frame(height: 1)

                ScrollView {
                    deviceAccessSection

                    if !orphanedKeyIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(orphanedKeyIDs.count) orphaned Keychain item\(orphanedKeyIDs.count == 1 ? "" : "s")")
                                .font(Typography.tesseraMono(size: 11, weight: .medium))
                                .foregroundStyle(T.red)
                            Text("Private material exists without matching key metadata.")
                                .font(Typography.tesseraMono(size: 10))
                                .foregroundStyle(T.fgDim)
                            Btn("review cleanup…", compact: true) {
                                showOrphanCleanupConfirmation = true
                            }
                        }
                        .padding(12)
                    }

                    if filteredKeys.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "key")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(T.fgDim)
                            Text(keys.isEmpty ? "no keys yet" : "no matching keys")
                                .font(Typography.tesseraMono(size: 13))
                                .foregroundStyle(T.fgMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 54)
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredKeys) { key in
                                keyListRow(key)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("keys")
                    .font(Typography.pageTitle)
                    .foregroundStyle(T.fg)

                Spacer()

                Btn("+ generate", compact: true) {
                    presentGenerator()
                }

                Btn("import", compact: true) {
                    presentation.showImportModal = true
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                Input(text: $filterText, placeholder: "search")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)

                Rectangle()
                    .fill(T.border)
                    .frame(height: 1)
            }

            ScrollView {
                deviceAccessSection

                if !orphanedKeyIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(orphanedKeyIDs.count) orphaned Keychain item\(orphanedKeyIDs.count == 1 ? "" : "s")")
                            .font(Typography.tesseraMono(size: 11, weight: .medium))
                            .foregroundStyle(T.red)
                        Text("Private material exists without matching key metadata.")
                            .font(Typography.tesseraMono(size: 10))
                            .foregroundStyle(T.fgDim)
                        Btn("review cleanup…", compact: true) {
                            showOrphanCleanupConfirmation = true
                        }
                    }
                    .padding(12)
                }

                LazyVStack(spacing: 2) {
                    ForEach(filteredKeys) { key in
                        keyListRow(key)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(T.panelBg)
    }

    private var rightPane: some View {
        ZStack {
            if let selectedKey {
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        keyDetail(selectedKey)
                            .frame(maxWidth: 680, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 28)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            } else {
                placeholder(text: keys.isEmpty ? "no keys yet · generate or import one" : "select a key")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func keyListRow(_ key: StoredKey) -> some View {
        let isSelected = key.id == selectedID

        return Button {
            selectedID = key.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName(for: key))
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(isSelected ? T.accent : T.fg)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if key.isSecureEnclave {
                        Tag(text: "secure enclave", color: T.accentSoft)
                    }
                }

                HStack(spacing: 6) {
                    Text("\(key.algorithm.displayName) · \(relativeDate(key.createdAt))")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if ownerPresenceIsEffectivelyRequired(for: key) {
                        Tag(text: "user presence")
                    }

                    switch recoveryState(for: key) {
                    case .missingPrivateMaterial:
                        Tag(text: "missing")
                    case .mismatchedPrivateMaterial, .invalidPrivateMaterial:
                        Tag(text: "rejected")
                    case .privateMaterialUnavailable:
                        Tag(text: "unavailable")
                    case .legacyAlgorithmDisabled:
                        Tag(text: "disabled")
                    case .notBackedUp, .backupExported, .deviceBoundUnrecoverable:
                        EmptyView()
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? T.inputBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var deviceAccessSection: some View {
        if !trackedDeviceAccess.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("device access")
                    .font(Typography.kicker)
                    .tracking(0.6)
                    .foregroundStyle(T.fgDim)
                    .textCase(.uppercase)

                ForEach(trackedDeviceAccess) { tracked in
                    let item = tracked.installation
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(T.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.peerDeviceName ?? "other device")
                                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                                    .foregroundStyle(T.fg)
                                Text("\(deviceAccessDirectionLabel(item.direction)) · \(item.hostLabel)")
                                    .font(Typography.tesseraMono(size: 9.5))
                                    .foregroundStyle(T.fgMuted)
                                Text("\(item.endpoint) · \(item.flow.rawValue)")
                                    .font(Typography.tesseraMono(size: 9))
                                    .foregroundStyle(T.fgDim)
                                    .lineLimit(2)
                                if item.verificationState == .uncertain {
                                    Text("remote state uncertain · retry revoke or verify manually")
                                        .font(Typography.tesseraMono(size: 9))
                                        .foregroundStyle(T.amber)
                                }
                            }
                            Spacer(minLength: 6)
                            Btn(
                                revokingDeviceAccessID == tracked.id ? "revoking…" : "revoke",
                                style: .danger,
                                compact: true
                            ) {
                                revokeTrackedDeviceAccess(tracked)
                            }
                            .disabled(revokingDeviceAccessID != nil)
                        }
                        if let fingerprint = item.publicKeyFingerprint {
                            Text(fingerprint)
                                .font(Typography.tesseraMono(size: 8.5))
                                .foregroundStyle(T.fgDim)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .background(T.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(T.border, lineWidth: 1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
    }

    private func deviceAccessDirectionLabel(
        _ direction: KeySecurityRecord.RemoteAccessDirection
    ) -> String {
        switch direction {
        case .localInstallation: return "installed here"
        case .grantedToPeer: return "granted from this device"
        case .receivedFromPeer: return "received for this device"
        }
    }

    private func revokeTrackedDeviceAccess(
        _ tracked: KeySecurityMetadataStore.TrackedRemoteInstallation
    ) {
        guard revokingDeviceAccessID == nil else { return }
        guard let host = hosts.first(where: { $0.id == tracked.installation.hostID }) else {
            showToast("The tracked host is no longer configured on this device")
            return
        }
        let line = tracked.installation.authorizedKeysLine
            ?? keys.first(where: { $0.id == tracked.keyID })?.authorizedKeysLine
        guard let line, !line.isEmpty else {
            showToast("This older ledger entry has no public key material; revoke it from the host manually")
            return
        }
        let hostSnapshot = Host(from: host)
        do {
            try RemoteAuthorizedKeysInstaller.validateRevocationRoute(
                tracked.installation.routeIdentity,
                on: hostSnapshot
            )
        } catch {
            showToast(error.localizedDescription)
            return
        }

        revokingDeviceAccessID = tracked.id
        Task { @MainActor in
            defer { revokingDeviceAccessID = nil }
            do {
                let targetKey = keys.first(where: { $0.id == tracked.keyID })
                let ledgerContext = RemoteAuthorizedKeysInstaller.LedgerContext(
                    keyID: tracked.keyID,
                    hostID: tracked.installation.hostID,
                    hostLabel: tracked.installation.hostLabel,
                    endpoint: tracked.installation.endpoint,
                    routeIdentity: tracked.installation.routeIdentity,
                    peerDeviceName: tracked.installation.peerDeviceName,
                    direction: tracked.installation.direction,
                    flow: tracked.installation.flow,
                    publicKeyFingerprint: tracked.installation.publicKeyFingerprint,
                    authorizedKeysLine: line
                )
                let shouldSelfRevoke = tracked.installation.direction == .receivedFromPeer
                    && RemoteAuthorizedKeysInstaller.shouldRevokeUsingTargetKey(
                        keyID: tracked.keyID,
                        on: hostSnapshot
                    )
                if shouldSelfRevoke {
                    guard let targetKey else {
                        throw KeyStore.KeyStoreError.privateMaterialMissing
                    }
                    try await RemoteAuthorizedKeysInstaller.revokeUsingTargetKey(
                        line: line,
                        keyID: tracked.keyID,
                        on: hostSnapshot,
                        requireBiometric: KeyOwnerPresencePolicy.isRequired(
                            globalPreference: appearance.requireBiometricForKeyUse,
                            key: targetKey,
                            metadata: securityMetadata
                        ),
                        isSecureEnclave: targetKey.isSecureEnclave,
                        ledgerContext: ledgerContext
                    )
                } else {
                    try await RemoteAuthorizedKeysInstaller.revoke(
                        line: line,
                        keyID: tracked.keyID,
                        on: hostSnapshot,
                        ledgerContext: ledgerContext
                    )
                }
                deviceAccessRevision += 1
                showToast("device access revoked on \(tracked.installation.hostLabel)")
            } catch {
                showToast("Revocation failed: \(error.localizedDescription)")
            }
        }
    }

    private func keyDetail(_ key: StoredKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displayName(for: key))
                .font(Typography.tesseraMono(size: 28, weight: .medium))
                .foregroundStyle(T.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            keyBadges(for: key)
                .padding(.bottom, 8)

            Text("created \(detailDate(key.createdAt))  ·  last used —")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fgDim)
                .padding(.bottom, 28)

            Field(label: "type") {
                staticValue(key.algorithm.displayName, size: 13, color: T.fg)
            }

            Field(label: "fingerprint (sha256)") {
                staticValue(fingerprint(for: key), size: 11, color: T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Field(label: "public key") {
                staticValue(key.authorizedKeysLine, size: 11, color: T.fgMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if key.isSecureEnclave {
                    enclaveNote(
                        "private key never leaves this device. sync, export, and copy-private-key are disabled."
                    )
                    .padding(.top, 10)
                }

                if key.algorithm == .rsa {
                    Text("Legacy RSA is disabled: Tessera cannot authenticate with or install this key. Generate an Ed25519 replacement, install it with a different working credential, then retire this RSA key.")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                } else {
                    HStack(spacing: 8) {
                        Btn("copy public key", compact: true) {
                            let payload = PublicKeyCopyPayload(
                                publicKey: key.authorizedKeysLine
                            )
                            UIPasteboard.general.setValue(
                                payload.pasteboardValue,
                                forPasteboardType: UTType.utf8PlainText.identifier
                            )
                            showToast(payload.feedback.lowercased())
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: payload.feedback
                            )
                        }
                        .accessibilityHint("Copies public material only")

                        Btn("share", compact: true) {
                            showToast("share ships later")
                        }

                        Btn("copy to host…", compact: true) {
                            requestCopyToHost(for: key)
                        }
                    }
                    .padding(.top, 10)
                }

                if let toastText {
                    Text(toastText)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .padding(.top, 8)
                }
            }

            recoverySection(for: key)
                .padding(.bottom, 22)

            Rectangle()
                .fill(T.border)
                .frame(height: 1)
                .padding(.top, 6)
                .padding(.bottom, 20)

            VStack(spacing: 14) {
                if key.isSecureEnclave {
                    let boundaryProtection = KeyOwnerPresencePolicy
                        .currentBoundaryProtection(
                            for: key,
                            metadata: securityMetadata
                        )
                    if boundaryProtection == .deviceUnlocked {
                        ToggleRow(
                            title: "require biometrics or passcode",
                            subtitle: "Tessera authenticates you before using this hardware-bound key",
                            isOn: Binding(
                                get: { key.requiresBiometric },
                                set: { newValue in
                                    updateProtection(for: key, enabled: newValue)
                                }
                            )
                        )
                        .disabled(protectionUpdateKeyID != nil)
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("biometrics or passcode")
                                    .font(Typography.tesseraMono(size: 13))
                                    .foregroundStyle(T.fg)
                                Text("Face ID/Touch ID or passcode is permanently enforced for this older Secure Enclave key")
                                    .font(Typography.tesseraMono(size: 11))
                                    .foregroundStyle(T.fgDim)
                            }
                            Spacer()
                            Tag(text: "enforced")
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    ToggleRow(
                        title: "require biometrics or passcode",
                        subtitle: "Face ID/Touch ID or passcode whenever Tessera accesses this key",
                        isOn: Binding(
                            get: { key.requiresBiometric },
                            set: { newValue in
                                updateProtection(for: key, enabled: newValue)
                            }
                        )
                    )
                    .disabled(protectionUpdateKeyID != nil)

                    if hasStaleUserPresenceBoundary(for: key) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This key is still protected by iOS. Confirm once to finish turning protection off, then Tessera can use it without authentication.")
                                .font(Typography.tesseraMono(size: 10))
                                .foregroundStyle(T.fgDim)
                                .fixedSize(horizontal: false, vertical: true)

                            Btn("finish turning protection off…", compact: true) {
                                updateProtection(for: key, enabled: false)
                            }
                            .disabled(protectionUpdateKeyID != nil)
                        }
                    }
                }
            }

            usedBySection(for: key)
                .padding(.top, 34)

            HStack(spacing: 10) {
                Btn("delete local private key…", style: .danger, compact: true) {
                    deleteCandidateID = key.id
                }

                if !key.isSecureEnclave && key.algorithm == .ed25519 {
                    Btn("export private key…", compact: true) {
                        recoveryPassphraseAction = .export(keyID: key.id)
                    }
                }
            }
            .padding(.top, 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func staticValue(_ text: String, size: CGFloat, color: Color) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: size))
            .foregroundStyle(color)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(T.border, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func keyBadges(for key: StoredKey) -> some View {
        HStack(spacing: 8) {
            keyBadge(
                text: badgeAlgorithmName(for: key.algorithm),
                background: T.inputBg,
                border: T.border,
                foreground: T.fg
            )

            if key.isSecureEnclave {
                keyBadge(
                    text: "secure enclave",
                    background: T.accentSoft,
                    border: T.accent,
                    foreground: T.accent
                )
            }

            if ownerPresenceIsEffectivelyRequired(for: key) {
                keyBadge(
                    text: "user presence",
                    background: T.panelBg,
                    border: T.border,
                    foreground: T.fgDim
                )
            }

            switch recoveryState(for: key) {
            case .missingPrivateMaterial:
                keyBadge(
                    text: "private material missing",
                    background: T.panelBg,
                    border: T.red,
                    foreground: T.red
                )
            case .mismatchedPrivateMaterial:
                keyBadge(
                    text: "private material mismatch",
                    background: T.panelBg,
                    border: T.red,
                    foreground: T.red
                )
            case .invalidPrivateMaterial:
                keyBadge(
                    text: "private material invalid",
                    background: T.panelBg,
                    border: T.red,
                    foreground: T.red
                )
            case .privateMaterialUnavailable:
                keyBadge(
                    text: "integrity unavailable",
                    background: T.panelBg,
                    border: T.border,
                    foreground: T.fgDim
                )
            case .legacyAlgorithmDisabled:
                keyBadge(
                    text: "legacy rsa disabled",
                    background: T.panelBg,
                    border: T.red,
                    foreground: T.red
                )
            case .notBackedUp:
                keyBadge(
                    text: "recovery not exported",
                    background: T.panelBg,
                    border: T.border,
                    foreground: T.fgDim
                )
            case .backupExported:
                keyBadge(
                    text: "recovery exported",
                    background: T.panelBg,
                    border: T.green,
                    foreground: T.green
                )
            case .deviceBoundUnrecoverable(let acknowledged):
                if acknowledged {
                    keyBadge(
                        text: "device-loss risk acknowledged",
                        background: T.panelBg,
                        border: T.border,
                        foreground: T.fgDim
                    )
                }
            }
        }
    }

    private func keyBadge(
        text: String,
        background: Color,
        border: Color,
        foreground: Color
    ) -> some View {
        Text(text.uppercased())
            .font(Typography.tesseraMono(size: 10))
            .tracking(0.6)
            .foregroundStyle(foreground)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(border, lineWidth: 1)
            )
    }

    private func enclaveNote(_ text: String) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(T.accent)
                    .frame(width: 2)
            }
    }

    private func badgeAlgorithmName(for algorithm: KeyAlgorithm) -> String {
        switch algorithm {
        case .ed25519:
            return "ed25519"
        case .ecdsaP256:
            return "ecdsa-p256"
        case .rsa:
            return "rsa"
        }
    }

    private func usedBySection(for key: StoredKey) -> some View {
        let hostNames = usedHostNames(for: key)

        return VStack(alignment: .leading, spacing: 10) {
            Text("used by")
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.fg)

            if hostNames.isEmpty {
                Text("no hosts use this key yet")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fgDim)
            } else {
                FlowTags(names: hostNames)
            }
        }
    }

    @ViewBuilder
    private func recoverySection(for key: StoredKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recovery")
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.fg)

            switch recoveryState(for: key) {
            case .missingPrivateMaterial:
                Text("The metadata for this key exists, but its private material is missing from Keychain. Tessera will not restore sessions or authenticate with it.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.red)
                    .fixedSize(horizontal: false, vertical: true)

                if !key.isSecureEnclave {
                    Btn("restore from recovery file…", compact: true) {
                        recoveryFilePurpose = .restore(keyID: key.id)
                        showRecoveryFileImporter = true
                    }
                }

            case .mismatchedPrivateMaterial:
                Text("The private material stored under this key ID derives a different public key. Tessera will not restore sessions, authenticate, copy, or install it.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.red)
                    .fixedSize(horizontal: false, vertical: true)

                if !key.isSecureEnclave && key.algorithm == .ed25519 {
                    Btn("repair from matching recovery file…", compact: true) {
                        recoveryFilePurpose = .restore(keyID: key.id)
                        showRecoveryFileImporter = true
                    }
                }

            case .invalidPrivateMaterial:
                Text("The private material is malformed for this key type. Tessera will not use it. Restore the matching Ed25519 recovery file or rotate the key.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.red)
                    .fixedSize(horizontal: false, vertical: true)

                if !key.isSecureEnclave && key.algorithm == .ed25519 {
                    Btn("repair from matching recovery file…", compact: true) {
                        recoveryFilePurpose = .restore(keyID: key.id)
                        showRecoveryFileImporter = true
                    }
                }

            case .privateMaterialUnavailable:
                Text("iOS could not complete a non-interactive integrity check. Tessera is failing closed for session restore and remote installation until the key becomes available.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.red)
                    .fixedSize(horizontal: false, vertical: true)

            case .legacyAlgorithmDisabled:
                Text("Legacy RSA authentication and installation are disabled because this SSH stack cannot prove RSA-SHA2 use. Generate an Ed25519 replacement and install it with a different credential before deleting this key.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.red)
                    .fixedSize(horizontal: false, vertical: true)

            case .notBackedUp:
                Text(key.algorithm == .ed25519
                    ? "No verified recovery export is recorded. Device loss or local deletion may permanently remove this credential."
                    : "This legacy software key type cannot be exported safely by this version. Generate a recoverable Ed25519 key, install it alongside this credential, then retire this key.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                if key.algorithm == .ed25519 {
                    Btn("protect recovery key…", compact: true) {
                        recoveryPassphraseAction = .export(keyID: key.id)
                    }
                } else {
                    Btn("acknowledge risk before remote use…", compact: true) {
                        riskAcknowledgementKeyID = key.id
                    }
                }

            case .backupExported(let date, let exportedFingerprint):
                Text("Encrypted OpenSSH recovery exported \(detailDate(date)). Fingerprint \(exportedFingerprint).")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Btn("verify recovery file…", compact: true) {
                        recoveryFilePurpose = .verify(keyID: key.id)
                        showRecoveryFileImporter = true
                    }
                    Btn("export a new copy…", compact: true) {
                        recoveryPassphraseAction = .export(keyID: key.id)
                    }
                }

            case .deviceBoundUnrecoverable(let acknowledged):
                Text("Secure Enclave private material cannot leave this device. Keep a second, recoverable credential authorized on every host that uses it.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                if !acknowledged {
                    Btn("acknowledge device-loss risk…", compact: true) {
                        riskAcknowledgementKeyID = key.id
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(Typography.tesseraMono(size: 14))
                .foregroundStyle(T.fgDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func usedHostNames(for key: StoredKey) -> [String] {
        let descriptor = FetchDescriptor<Identity>()
        let identities = (try? modelContext.fetch(descriptor)) ?? []
        let names = identities.flatMap { identity -> [String] in
            guard case .key(let keyID) = identity.credentialMode, keyID == key.id else {
                return []
            }
            return identity.hosts.map { host in
                host.name.isEmpty ? host.address : host.name
            }
        }
        return Array(Set(names)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func usedIdentityCount(for key: StoredKey) -> Int {
        let identities = (try? modelContext.fetch(FetchDescriptor<Identity>())) ?? []
        return identities.reduce(into: 0) { count, identity in
            if case .key(let keyID) = identity.credentialMode, keyID == key.id {
                count += 1
            }
        }
    }

    private func fingerprint(for key: StoredKey) -> String {
        let canonical = key.canonicalFingerprint
        return canonical.isEmpty ? "SHA256:—" : canonical
    }

    private func beginInitialRecovery(for key: StoredKey) {
        keyMaterialRevision += 1
        if key.isSecureEnclave {
            riskAcknowledgementKeyID = key.id
        } else {
            recoveryPassphraseAction = .export(keyID: key.id)
        }
    }

    private func recoveryState(for key: StoredKey) -> KeyRecoveryState {
        _ = keyMaterialRevision
        let integrity = materialIntegrity[key.id]
            ?? KeyStore.privateMaterialIntegrity(
                forKeyID: key.id,
                algorithm: key.algorithm,
                isSecureEnclave: key.isSecureEnclave,
                expectedAuthorizedKeysLine: key.authorizedKeysLine
            )
        return securityMetadata.recoveryState(
            for: key,
            integrity: integrity
        )
    }

    private func requestCopyToHost(for key: StoredKey) {
        guard key.algorithm != .rsa else {
            showToast("Legacy RSA installation is disabled; rotate to Ed25519")
            return
        }
        switch recoveryState(for: key) {
        case .missingPrivateMaterial:
            showToast("Restore the missing private key before installing it")
        case .mismatchedPrivateMaterial, .invalidPrivateMaterial:
            showToast("Repair the rejected private material before installing it")
        case .privateMaterialUnavailable:
            showToast("Key integrity is unavailable; installation is blocked")
        case .legacyAlgorithmDisabled:
            showToast("Legacy RSA installation is disabled; rotate to Ed25519")
        case .backupExported:
            showCopyToHostSheet = true
        case .notBackedUp:
            if securityMetadata.record(for: key.id).unrecoverableAcknowledgedAt != nil {
                showCopyToHostSheet = true
            } else {
                riskAcknowledgementKeyID = key.id
            }
        case .deviceBoundUnrecoverable(let acknowledged):
            if acknowledged {
                showCopyToHostSheet = true
            } else {
                riskAcknowledgementKeyID = key.id
            }
        }
    }

    private func clearRecoveryPassphraseAction() {
        recoveryPassphraseAction = nil
    }

    @MainActor
    private func performRecoveryAction(
        _ action: RecoveryPassphraseAction,
        passphrase: String
    ) async {
        guard let key = keys.first(where: { $0.id == action.keyID }) else {
            recoveryPassphraseAction = nil
            return
        }

        do {
            switch action {
            case .export:
                guard key.algorithm == .ed25519, !key.isSecureEnclave else {
                    throw KeyStore.RecoveryError.unsupportedAlgorithm
                }
                if hasStaleUserPresenceBoundary(for: key) {
                    throw AuthResolutionError
                        .ownerAuthenticationDisabledForProtectedKey
                }
                var authorization: BiometricAuthorization?
                if ownerPresenceIsEffectivelyRequired(for: key) {
                    switch await BiometricGate.evaluateForKeyUse(
                        reason: "export encrypted recovery for \(displayName(for: key))"
                    ) {
                    case .authenticated(let granted):
                        authorization = granted
                    case .userCancelled:
                        throw AuthResolutionError.biometricCancelled
                    case .unavailable:
                        throw AuthResolutionError.biometricFailed(
                            reason: "Device owner authentication is unavailable."
                        )
                    case .failed(let reason):
                        throw AuthResolutionError.biometricFailed(reason: reason)
                    }
                }
                let data = try KeyStore.exportEncryptedEd25519PrivateKey(
                    forKeyID: key.id,
                    passphrase: passphrase,
                    comment: key.name,
                    authorization: authorization
                )
                pendingExportDocument = EncryptedRecoveryDocument(data: data)
                pendingExportKeyID = key.id
                let safeName = key.name
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                pendingExportFilename = "\(safeName.isEmpty ? "tessera" : safeName)-recovery.key"
                recoveryPassphraseAction = nil
                showRecoveryFileExporter = true

            case .verify(_, let data):
                let expected = fingerprint(for: key)
                let actual = try KeyStore.recoveryFingerprint(
                    data: data,
                    passphrase: passphrase
                )
                guard actual == expected else {
                    throw KeyStore.RecoveryError.fingerprintMismatch(
                        expected: expected,
                        actual: actual
                    )
                }
                recoveryPassphraseAction = nil
                showToast("recovery file verified")

            case .restore(_, let data):
                let restoredProtection: KeyStore.KeyProtection =
                    ownerPresenceIsEffectivelyRequired(for: key)
                    ? .userPresence
                    : .deviceUnlocked
                let restoredFingerprint = try KeyStore.recoverEd25519Key(
                    data: data,
                    passphrase: passphrase,
                    forKeyID: key.id,
                    expectedFingerprint: fingerprint(for: key),
                    protection: restoredProtection
                )
                let integrity: KeyMaterialIntegrity = restoredProtection == .userPresence
                    ? .authenticationRequired
                    : .valid
                materialIntegrity[key.id] = integrity
                securityMetadata.markBoundaryProtection(
                    restoredProtection == .userPresence
                        ? .userPresence
                        : .deviceUnlocked,
                    for: key.id
                )
                securityMetadata.markMaterialIntegrity(integrity, for: key.id)
                securityMetadata.markBackupExported(
                    for: key.id,
                    fingerprint: restoredFingerprint
                )
                recoveryPassphraseAction = nil
                keyMaterialRevision += 1
                showToast("private key restored")
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func handleRecoveryFileSelection(_ result: Result<[URL], Error>) {
        guard let purpose = recoveryFilePurpose else { return }
        recoveryFilePurpose = nil

        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > 1_048_576 {
                throw KeyRecoverySurfaceError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= 1_048_576 else {
                throw KeyRecoverySurfaceError.fileTooLarge
            }
            switch purpose {
            case .verify(let keyID):
                recoveryPassphraseAction = .verify(keyID: keyID, data: data)
            case .restore(let keyID):
                recoveryPassphraseAction = .restore(keyID: keyID, data: data)
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func handleRecoveryExportCompletion(_ result: Result<URL, Error>) {
        defer {
            pendingExportDocument = nil
            pendingExportKeyID = nil
        }

        switch result {
        case .success:
            guard let keyID = pendingExportKeyID,
                  let key = keys.first(where: { $0.id == keyID }) else { return }
            securityMetadata.markBackupExported(
                for: keyID,
                fingerprint: fingerprint(for: key)
            )
            keyMaterialRevision += 1
            showToast("encrypted recovery file exported")
        case .failure(let error):
            showToast("Recovery export was not completed: \(error.localizedDescription)")
        }
    }

    private func deleteConfirmed(
        _ key: StoredKey,
        remotelyRevokedCount: Int = 0
    ) {
        deletionTask?.cancel()
        deletionInProgress = true
        deletionTask = Task { @MainActor in
            await performConfirmedDeletion(
                key,
                remotelyRevokedCount: remotelyRevokedCount
            )
        }
    }

    @MainActor
    private func performConfirmedDeletion(
        _ key: StoredKey,
        remotelyRevokedCount: Int
    ) async {
        guard !Task.isCancelled else {
            deletionInProgress = false
            return
        }
        let priorRemoteRevocation = securityMetadata.record(
            for: key.id
        ).lastRemoteRevocationAt != nil

        do {
            try StoredKeyLifecycle.delete(
                key,
                persistence: KeyLifecyclePersistence.live(modelContext),
                metadata: securityMetadata,
                deleteMaterial: { keyID in
                    _ = try KeyStore.deleteKey(forKeyID: keyID)
                }
            )
            deleteCandidateID = nil
            deletionInProgress = false
            selectedID = nil
            keyMaterialRevision += 1
            materialIntegrity.removeValue(forKey: key.id)
            if remotelyRevokedCount > 0 {
                showToast("local private key deleted after revoking \(remotelyRevokedCount) tracked remote authorization\(remotelyRevokedCount == 1 ? "" : "s")")
            } else if priorRemoteRevocation {
                showToast("local private key deleted; earlier tracked remote revocation was preserved")
            } else {
                showToast("local private key deleted; remote authorizations were not revoked")
            }
        } catch {
            deleteCandidateID = nil
            deletionInProgress = false
            keyMaterialRevision += 1
            if case .deletionPending = error as? KeyLifecycleError {
                selectedID = nil
                materialIntegrity.removeValue(forKey: key.id)
                showToast(error.localizedDescription)
            } else {
                showToast("Local key deletion failed; private material was not touched: \(error.localizedDescription)")
            }
        }
    }

    private func eligibleRemoteRevocationHosts(for key: StoredKey) -> [PersistedHost] {
        let tracked = securityMetadata.record(for: key.id).remoteInstallations
        return hosts.filter { host in
            let hostSnapshot = Host(from: host)
            guard let installation = tracked.first(where: { $0.hostID == host.id }),
                  installation.routeIdentity
                    == RemoteAccessRouteIdentity.value(for: hostSnapshot),
                  let identity = host.identity else {
                return false
            }
            switch identity.credentialMode {
            case .password:
                return !hostSnapshot.password.isEmpty
            case .key(let authKeyID):
                guard authKeyID != key.id,
                      let authKey = keys.first(where: { $0.id == authKeyID })
                else { return false }
                return integrity(for: authKey).permitsAuthenticationAttempt
            case .none, .legacyDevKey:
                return false
            }
        }
    }

    private func refreshIntegrityReport() {
        let pendingDeletionIDs = Set(
            KeyDeletionIntentStore().intents().map(\.keyID)
        )
        let report: KeyStore.IntegrityReport?
        do {
            report = try KeyStore.integrityReport(
                metadataKeyIDs: Set(keys.map(\.id))
            )
        } catch {
            // Protected items can gate the bulk attributes inventory on real
            // devices. Continue with exact per-key checks so one ACL never makes
            // every key look unavailable; orphan cleanup stays hidden because
            // it cannot be established safely from a partial inventory.
            report = nil
            orphanedKeyIDs = pendingDeletionIDs
            DiagnosticLogStore.appendKeys(
                "integrity-inventory-ui unavailable error='\(error.localizedDescription)'"
            )
        }

        if let report {
            orphanedKeyIDs = report.orphanedKeyIDs.union(pendingDeletionIDs)
        }
        var refreshed: [UUID: KeyMaterialIntegrity] = [:]
        for key in keys {
            let integrity: KeyMaterialIntegrity
            if report?.metadataOnlyKeyIDs.contains(key.id) == true {
                integrity = .missing
            } else {
                integrity = KeyStore.privateMaterialIntegrity(
                    forKeyID: key.id,
                    algorithm: key.algorithm,
                    isSecureEnclave: key.isSecureEnclave,
                    expectedAuthorizedKeysLine: key.authorizedKeysLine
                )
            }
            refreshed[key.id] = integrity
            securityMetadata.markMaterialIntegrity(integrity, for: key.id)
        }
        materialIntegrity = refreshed
        keyMaterialRevision += 1
    }

    private func cleanupOrphanedPrivateMaterial() {
        let keyIDs = orphanedKeyIDs
        showOrphanCleanupConfirmation = false
        Task { @MainActor in
            var failures = 0
            for keyID in keyIDs {
                do {
                    _ = try KeyStore.deleteKey(forKeyID: keyID)
                    securityMetadata.removeRecord(for: keyID)
                    try KeyDeletionIntentStore().clear(keyID: keyID)
                } catch {
                    failures += 1
                }
            }
            refreshIntegrityReport()
            if failures == 0 {
                showToast("orphaned private material deleted")
            } else {
                showToast("Some orphaned Keychain items could not be deleted")
            }
        }
    }

    private func revokeRemotelyThenDelete(_ key: StoredKey) {
        let eligibleHosts = eligibleRemoteRevocationHosts(for: key)
        guard !eligibleHosts.isEmpty else {
            showToast("No tracked remote host has a reachable alternate credential")
            return
        }

        deletionTask?.cancel()
        deletionInProgress = true
        let line = key.authorizedKeysLine
        let keyID = key.id
        deletionTask = Task { @MainActor in
            do {
                var revokedCount = 0
                for persistedHost in eligibleHosts {
                    try Task.checkCancellation()
                    guard let installation = securityMetadata.record(for: keyID)
                        .remoteInstallations.first(where: {
                            $0.hostID == persistedHost.id
                        }) else {
                        throw RemoteAuthorizedKeysInstaller.InstallError.routeChanged
                    }
                    let hostSnapshot = Host(from: persistedHost)
                    let authKey: StoredKey?
                    if case .key(let authKeyID) = persistedHost.identity?.credentialMode {
                        authKey = keys.first { $0.id == authKeyID }
                    } else {
                        authKey = nil
                    }
                    try await RemoteAuthorizedKeysInstaller.revoke(
                        line: line,
                        keyID: keyID,
                        on: hostSnapshot,
                        requireBiometric: KeyOwnerPresencePolicy.isRequired(
                            globalPreference: appearance.requireBiometricForKeyUse,
                            key: authKey,
                            metadata: securityMetadata
                        ),
                        isSecureEnclave: authKey?.isSecureEnclave ?? false,
                        ledgerContext: RemoteAuthorizedKeysInstaller.LedgerContext(
                            keyID: keyID,
                            hostID: installation.hostID,
                            hostLabel: installation.hostLabel,
                            endpoint: installation.endpoint,
                            routeIdentity: installation.routeIdentity,
                            peerDeviceName: installation.peerDeviceName,
                            direction: installation.direction,
                            flow: installation.flow,
                            publicKeyFingerprint: installation.publicKeyFingerprint,
                            authorizedKeysLine: line,
                            preserveExistingAuditFields: true
                        )
                    )
                    revokedCount += 1
                }
                try Task.checkCancellation()
                await performConfirmedDeletion(
                    key,
                    remotelyRevokedCount: revokedCount
                )
            } catch is CancellationError {
                deletionInProgress = false
            } catch {
                deletionInProgress = false
                showToast(
                    "Remote revocation failed; the local key was not deleted: \(error.localizedDescription)"
                )
            }
        }
    }

    private func updateProtection(for key: StoredKey, enabled: Bool) {
        guard protectionUpdateKeyID == nil else { return }
        if key.isSecureEnclave {
            guard KeyOwnerPresencePolicy.currentBoundaryProtection(
                for: key,
                metadata: securityMetadata
            ) == .deviceUnlocked else {
                showToast("This older Secure Enclave key requires rotation to change authentication")
                return
            }
            protectionUpdateKeyID = key.id
            Task { @MainActor in
                defer { protectionUpdateKeyID = nil }
                await performSecureEnclavePreferenceUpdate(
                    for: key,
                    enabled: enabled
                )
            }
            return
        }
        protectionUpdateKeyID = key.id
        Task { @MainActor in
            defer { protectionUpdateKeyID = nil }
            await performProtectionUpdate(for: key, enabled: enabled)
        }
    }

    @MainActor
    private func performSecureEnclavePreferenceUpdate(
        for key: StoredKey,
        enabled: Bool
    ) async {
        switch await BiometricGate.evaluateForKeyUse(
            reason: "change key authentication for \(displayName(for: key))"
        ) {
        case .authenticated:
            break
        case .userCancelled:
            showToast("Authentication cancelled - key setting unchanged")
            return
        case .unavailable(let reason), .failed(let reason):
            showToast("Could not change key authentication: \(reason)")
            return
        }

        do {
            try StoredKeyLifecycle.updateOwnerAuthenticationPreference(
                for: key,
                enabled: enabled,
                persistence: KeyLifecyclePersistence.live(modelContext)
            )
            DiagnosticLogStore.appendKeys(
                "secure-enclave app-auth changed enabled=\(enabled)"
            )
            showToast(
                enabled
                    ? "key authentication on"
                    : "key authentication off - future key use will not require authentication"
            )
        } catch {
            DiagnosticLogStore.appendKeys(
                "secure-enclave app-auth change failed error='\(error.localizedDescription)'"
            )
            showToast("Could not change key authentication: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func performProtectionUpdate(for key: StoredKey, enabled: Bool) async {
        // Rewriting a presence-protected item requires reading its bytes, and
        // on-device that read cannot reliably present the raw Keychain sheet.
        // Evaluate owner presence through the app gate and bind the rewrite to
        // that authorization. Turning protection off therefore has one final,
        // explicit confirmation before the same key becomes prompt-free.
        var authorization: BiometricAuthorization?
        let currentProtection: KeyStore.KeyMaterialProtection
        DiagnosticLogStore.appendKeys(
            "protection-change begin requested=\(enabled ? "on" : "off")"
        )
        do {
            currentProtection = try KeyStore.materialProtection(forKeyID: key.id)
        } catch {
            DiagnosticLogStore.appendKeys(
                "protection-change inspect-failed requested=\(enabled ? "on" : "off") error='\(error.localizedDescription)'"
            )
            showToast("Could not inspect current key protection; no change was made")
            return
        }
        if KeyOwnerPresencePolicy.requiresAuthorizationForProtectionChange(
            currentBoundary: currentProtection,
            enabling: enabled
        ) {
            // Enabling needs authorization too: if the SwiftData save fails,
            // compensation must be able to read/delete the presence-protected
            // item it just created without launching a second raw Keychain
            // prompt or leaving preference and boundary split.
            switch await BiometricGate.evaluateForKeyUse(
                reason: "change key protection for \(displayName(for: key))"
            ) {
            case .authenticated(let granted):
                authorization = granted
                DiagnosticLogStore.appendKeys(
                    "protection-change owner-auth=authenticated requested=\(enabled ? "on" : "off")"
                )
            case .userCancelled:
                DiagnosticLogStore.appendKeys(
                    "protection-change owner-auth=cancelled requested=\(enabled ? "on" : "off")"
                )
                showToast("Authentication cancelled - key protection unchanged")
                return
            case .unavailable(let reason):
                DiagnosticLogStore.appendKeys(
                    "protection-change owner-auth=unavailable requested=\(enabled ? "on" : "off") error='\(reason)'"
                )
                showToast("Could not change key protection: \(reason)")
                return
            case .failed(let reason):
                DiagnosticLogStore.appendKeys(
                    "protection-change owner-auth=failed requested=\(enabled ? "on" : "off") error='\(reason)'"
                )
                showToast("Could not change key protection: \(reason)")
                return
            }
        }

        do {
            try StoredKeyLifecycle.updateProtection(
                for: key,
                enabled: enabled,
                persistence: KeyLifecyclePersistence.live(modelContext),
                metadata: securityMetadata,
                applyBoundary: { protection in
                    try KeyStore.updateProtection(
                        forKeyID: key.id,
                        to: protection,
                        isSecureEnclave: false,
                        authorization: authorization
                    )
                },
                inspectBoundary: {
                    try KeyStore.materialProtection(forKeyID: key.id)
                }
            )
            let integrity: KeyMaterialIntegrity = enabled
                ? .authenticationRequired
                : KeyStore.privateMaterialIntegrity(
                    forKeyID: key.id,
                    algorithm: key.algorithm,
                    isSecureEnclave: false,
                    expectedAuthorizedKeysLine: key.authorizedKeysLine
                )
            materialIntegrity[key.id] = integrity
            securityMetadata.markMaterialIntegrity(integrity, for: key.id)
            keyMaterialRevision += 1
            DiagnosticLogStore.appendKeys(
                "protection-change complete protection=\(enabled ? "on" : "off")"
            )
            showToast(
                enabled
                    ? "key protection on"
                    : "key protection off - future key use will not require authentication"
            )
        } catch {
            DiagnosticLogStore.appendKeys(
                "protection-change failed requested=\(enabled ? "on" : "off") error='\(error.localizedDescription)'"
            )
            showToast("Could not change key protection: \(error.localizedDescription)")
        }
    }

    private func ownerPresenceIsEffectivelyRequired(for key: StoredKey) -> Bool {
        KeyOwnerPresencePolicy.isRequired(
            globalPreference: appearance.requireBiometricForKeyUse,
            key: key,
            metadata: securityMetadata
        )
    }

    private func hasStaleUserPresenceBoundary(for key: StoredKey) -> Bool {
        !ownerPresenceIsEffectivelyRequired(for: key)
            && securityMetadata.record(for: key.id).boundaryProtection == .userPresence
    }

    private func integrity(for key: StoredKey) -> KeyMaterialIntegrity {
        materialIntegrity[key.id] ?? KeyStore.privateMaterialIntegrity(
            forKeyID: key.id,
            algorithm: key.algorithm,
            isSecureEnclave: key.isSecureEnclave,
            expectedAuthorizedKeysLine: key.authorizedKeysLine
        )
    }

    private func displayName(for key: StoredKey) -> String {
        key.name.isEmpty ? "unnamed key" : key.name
    }

    private func relativeDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "today"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func detailDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func applyInitialSelectionIfNeeded() {
        guard !didDefaultSelection, selectedID == nil, let first = keys.first else { return }
        selectedID = first.id
        didDefaultSelection = true
    }

    private func reconcileSelectionAfterDataChange() {
        if let selectedID, !keys.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        applyInitialSelectionIfNeeded()
    }

    private func saveModelContext(_ action: String) {
        do {
            try modelContext.save()
        } catch {
            DiagnosticLogStore.appendKeys("model-save failed action='\(action)' error='\(error)'")
        }
    }

    private func showToast(_ text: String) {
        toastText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toastText == text {
                toastText = nil
            }
        }
    }
}

private struct FlowTags: View {
    let names: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tagContent
            }

            VStack(alignment: .leading, spacing: 8) {
                tagContent
            }
        }
    }

    @ViewBuilder
    private var tagContent: some View {
        ForEach(names, id: \.self) { name in
            Tag(text: name)
        }
    }
}

private enum RecoveryPassphraseAction {
    case export(keyID: UUID)
    case verify(keyID: UUID, data: Data)
    case restore(keyID: UUID, data: Data)

    var keyID: UUID {
        switch self {
        case .export(let keyID), .verify(let keyID, _), .restore(let keyID, _):
            return keyID
        }
    }

    var purpose: RecoveryPassphrasePurpose {
        switch self {
        case .export: return .export
        case .verify: return .verify
        case .restore: return .restore
        }
    }
}

private enum RecoveryPassphrasePurpose {
    case export
    case verify
    case restore

    var title: String {
        switch self {
        case .export: return "protect recovery key"
        case .verify: return "verify recovery file"
        case .restore: return "restore private key"
        }
    }

    var explanation: String {
        switch self {
        case .export:
            return "Tessera will create a standard passphrase-encrypted OpenSSH private-key file. Tessera cannot recover this passphrase. No plaintext key file is created."
        case .verify:
            return "The file will be decrypted in memory and its public fingerprint compared with this key. It will not replace the live key."
        case .restore:
            return "The file will be decrypted in memory, fingerprint-matched, and restored under the existing key identity so host references remain intact."
        }
    }
}

private enum RecoveryFilePurpose {
    case verify(keyID: UUID)
    case restore(keyID: UUID)
}

private struct EncryptedRecoveryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct RecoveryPassphraseModal: View {
    let keyName: String
    let purpose: RecoveryPassphrasePurpose
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.scenePhase) private var scenePhase
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var privacyShielded = false
    @State private var validationError: String?

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text(purpose.title)
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.fg)

                Text(keyName)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)

                Text(purpose.explanation)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                Field(label: "recovery-file passphrase") {
                    Input(text: $passphrase, placeholder: "", secure: true)
                }

                if purpose == .export {
                    Field(label: "confirm passphrase") {
                        Input(text: $confirmation, placeholder: "", secure: true)
                    }
                }

                if let validationError {
                    Text(validationError)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.red)
                }

                HStack(spacing: 10) {
                    Spacer()
                    Btn("cancel", compact: true, action: cancel)
                    Btn(submitTitle, style: .primary, compact: true, action: submit)
                }
            }
            .padding(isPhone ? 18 : 28)
            .frame(width: isPhone ? nil : 500)
            .frame(maxWidth: isPhone ? .infinity : nil)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.borderStrong, lineWidth: 1)
            )
            .padding(.horizontal, isPhone ? 18 : 0)

            if privacyShielded {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        Text("recovery operation hidden")
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .zIndex(100)
                    .transaction { $0.animation = nil }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                privacyShielded = UIScreen.main.isCaptured
            } else {
                privacyShielded = true
                clearSecrets()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIScreen.capturedDidChangeNotification
        )) { _ in
            let captured = UIScreen.main.isCaptured
            privacyShielded = captured
            if captured { clearSecrets() }
        }
        .onDisappear(perform: clearSecrets)
    }

    private var submitTitle: String {
        switch purpose {
        case .export: return "export encrypted file…"
        case .verify: return "verify"
        case .restore: return "restore"
        }
    }

    private func submit() {
        guard !passphrase.isEmpty else {
            validationError = "A passphrase is required."
            return
        }
        if purpose == .export {
            guard passphrase.count >= 8 else {
                validationError = "Use at least 8 characters."
                return
            }
            guard passphrase == confirmation else {
                validationError = "Passphrases do not match."
                return
            }
        }
        let submitted = passphrase
        clearSecrets()
        onSubmit(submitted)
    }

    private func cancel() {
        clearSecrets()
        onCancel()
    }

    private func clearSecrets() {
        passphrase = ""
        confirmation = ""
    }
}

private struct KeyRiskAcknowledgementModal: View {
    let key: StoredKey
    let fingerprint: String
    let onCancel: () -> Void
    let onExport: (() -> Void)?
    let onAcknowledge: () -> Void

    @Environment(\.designTokens) private var T

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text(key.isSecureEnclave ? "device-bound key" : "recovery not exported")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.fg)

                Text(fingerprint)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)

                Text(key.isSecureEnclave
                    ? "This Secure Enclave key can never be recovered after device loss. Before installing it remotely, keep a second recoverable credential on that host."
                    : "This software key has no recorded recovery export. Installing it as the only remote credential can permanently lock you out after device loss or accidental deletion.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                if isPhone {
                    VStack(spacing: 8) {
                        if let onExport {
                            Btn("export recovery first", style: .primary, full: true, action: onExport)
                        }
                        Btn("I understand · continue", style: .danger, full: true, action: onAcknowledge)
                        Btn("cancel", full: true, action: onCancel)
                    }
                } else {
                    HStack(spacing: 10) {
                        Btn("cancel", compact: true, action: onCancel)
                        Spacer()
                        if let onExport {
                            Btn("export recovery first", style: .primary, compact: true, action: onExport)
                        }
                        Btn("I understand · continue", style: .danger, compact: true, action: onAcknowledge)
                    }
                }
            }
            .padding(isPhone ? 18 : 28)
            .frame(width: isPhone ? nil : 560)
            .frame(maxWidth: isPhone ? .infinity : nil)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.borderStrong, lineWidth: 1)
            )
            .padding(.horizontal, isPhone ? 18 : 0)
        }
    }
}

private struct KeyDeletionConfirmationModal: View {
    let key: StoredKey
    let fingerprint: String
    let hostNames: [String]
    let identityCount: Int
    let securityRecord: KeySecurityRecord
    let eligibleRemoteRevocationCount: Int
    let isWorking: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onRevokeAndConfirm: () -> Void

    @Environment(\.designTokens) private var T

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("delete local private key")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.red)

                Text(fingerprint)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)

                Text(backupDescription)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Local references: \(identityCount) identit\(identityCount == 1 ? "y" : "ies") and \(hostNames.count) host\(hostNames.count == 1 ? "" : "s"). They will be detached before deletion.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)

                Text("Known remote installations: \(securityRecord.remoteInstallations.count). Deleting locally does not revoke any authorized_keys entry; remove this public key from every remote host separately.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                if !hostNames.isEmpty {
                    FlowTags(names: hostNames)
                }

                if isPhone {
                    VStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            if eligibleRemoteRevocationCount > 0 {
                                Btn(
                                    "revoke on \(eligibleRemoteRevocationCount) tracked host\(eligibleRemoteRevocationCount == 1 ? "" : "s") & delete",
                                    style: .primary,
                                    full: true,
                                    action: onRevokeAndConfirm
                                )
                            }
                            Btn("local delete only", style: .danger, full: true, action: onConfirm)
                        }
                        Btn("cancel", full: true, action: onCancel)
                            .disabled(isWorking)
                    }
                } else {
                    HStack(spacing: 10) {
                        Btn("cancel", compact: true, action: onCancel)
                            .disabled(isWorking)
                        Spacer()
                        if isWorking {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            if eligibleRemoteRevocationCount > 0 {
                                Btn(
                                    "revoke on \(eligibleRemoteRevocationCount) tracked host\(eligibleRemoteRevocationCount == 1 ? "" : "s") & delete",
                                    style: .primary,
                                    compact: true,
                                    action: onRevokeAndConfirm
                                )
                            }
                            Btn("local delete only", style: .danger, compact: true, action: onConfirm)
                        }
                    }
                }
            }
            .padding(isPhone ? 18 : 28)
            .frame(width: isPhone ? nil : 620)
            .frame(maxWidth: isPhone ? .infinity : nil)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.red, lineWidth: 1)
            )
            .padding(.horizontal, isPhone ? 18 : 0)
        }
    }

    private var backupDescription: String {
        if key.isSecureEnclave {
            return "This Secure Enclave key is permanently unrecoverable after deletion."
        }
        if let date = securityRecord.backupExportedAt {
            return "A recovery export was recorded \(date.formatted(.dateTime.year().month().day())). Confirm that you still possess its passphrase before deleting."
        }
        return "No recovery export is recorded. Deletion may be permanent."
    }
}

private struct OrphanedKeyCleanupModal: View {
    let count: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.designTokens) private var T

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("delete orphaned private material")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.red)

                Text("Tessera found \(count) Keychain item\(count == 1 ? "" : "s") with no matching key metadata. They cannot be selected, authenticated with, exported, or associated with a host. This removes only those inaccessible orphaned items.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)

                if isPhone {
                    VStack(spacing: 8) {
                        Btn("delete \(count) orphaned item\(count == 1 ? "" : "s")", style: .danger, full: true, action: onConfirm)
                        Btn("cancel", full: true, action: onCancel)
                    }
                } else {
                    HStack(spacing: 10) {
                        Btn("cancel", compact: true, action: onCancel)
                        Spacer()
                        Btn("delete \(count) orphaned item\(count == 1 ? "" : "s")", style: .danger, compact: true, action: onConfirm)
                    }
                }
            }
            .padding(isPhone ? 18 : 28)
            .frame(width: isPhone ? nil : 560)
            .frame(maxWidth: isPhone ? .infinity : nil)
            .background(T.panelBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.red, lineWidth: 1)
            )
            .padding(.horizontal, isPhone ? 18 : 0)
        }
    }
}

private enum KeyRecoverySurfaceError: LocalizedError {
    case fileTooLarge

    var errorDescription: String? {
        "The recovery file is empty or exceeds the 1 MB safety limit."
    }
}
