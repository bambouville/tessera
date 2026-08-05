import SwiftUI
import SwiftData
import TmuxControl
import PortForwarding
import UIKit

private enum Tab: String, CaseIterable {
    case connection
    case advanced
    case forwarding
    case snippets
}

struct HostEditorCredentialDraft: Equatable {
    private(set) var hostID: UUID?
    var password = ""
    var jumpPasswords: [UUID: String] = [:]

    mutating func beginEditing(hostID: UUID) {
        guard self.hostID != hostID else { return }
        self.hostID = hostID
        password = ""
        jumpPasswords = [:]
    }
}

/// Edit form for a single saved host. Replaces the old HostEntryView
/// with SwiftData binding and identity selection.
struct HostDetailView: View {
    @Bindable var host: PersistedHost
    @Environment(\.modelContext) private var modelContext
    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(HostTerminalBackgroundStore.self) private var hostBackgrounds
    @Environment(TunnelsRegistry.self) private var tunnelsRegistry
    @Query(sort: \StoredKey.createdAt, order: .reverse) private var storedKeys: [StoredKey]
    var onConnect: (PersistedHost, String, [UUID: String]) -> Void
    var onCancel: () -> Void
    var onSave: (() -> Void)? = nil
    var onDelete: () -> Void
    var continuationSourceLabel: String? = nil
    var continuationAction: ContinuationAction? = nil
    var continuationTmuxSessionName: String? = nil
    var compactPrimaryTitle: String = "save"
    var onAuthorizeFromPeer: (() -> Void)? = nil

    /// Transient password — entered here and never stored in SwiftData.
    /// Continuation drafts persist it only through the existing
    /// ThisDeviceOnly Keychain boundary before connecting.
    @State private var credentials = HostEditorCredentialDraft()
    @State private var selectedTab: Tab = .connection
    @State private var newTag: String = ""
    /// Mirrors `HostOSDetectionState.isManuallySet(hostID:)`, kept in
    /// `@State` so toggling between auto/manual triggers a SwiftUI
    /// re-render that hides or shows the OS picker.
    @State private var isOSManual: Bool = false
    /// Mirrors this host's `HostJumpLink.jumpHostID`, kept in `@State`
    /// so picking a bastion re-renders the path caption immediately.
    @State private var jumpHostID: UUID?
    /// Per-hop passwords are session-scoped like the destination password.
    /// They are never persisted; the resulting Host DTO retains them for
    /// reconnecting Mosh/tmux/File side channels during this live session.
    // Keep the cross-shell fields in one staged draft. A single state owner
    // survives compact/regular transitions, and Cancel has the same semantics
    // on both layouts instead of SwiftData autosaving only the regular form.
    @State private var compactName = ""
    @State private var compactAddress = ""
    @State private var compactPort = 22
    @State private var compactUser = ""
    @State private var compactIdentityKeyID: UUID?
    @State private var compactIdentityWasChanged = false
    @State private var compactTransport: HostTransport = .ssh
    @State private var compactPortForwardRules: [PortForwardRule] = []
    @State private var compactDraftLoaded = false
    @State private var credentialPersistenceError: String?

    private let osHintOptions = ["macos", "ubuntu", "debian", "alpine", "linux", "raspbian"]

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    /// A host counts as a draft (just-created via ⌘N / sidebar +) when
    /// both name and address are still empty. Drafts get the "new host"
    /// title and no delete button; cancel deletes the empty record so
    /// it doesn't litter the host list.
    private var isDraft: Bool {
        host.name.trimmingCharacters(in: .whitespaces).isEmpty
            && host.address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isContinuationDraft: Bool {
        continuationSourceLabel != nil
    }

    var body: some View {
        ZStack {
            T.presentationBg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                PageHeader(
                    title: isContinuationDraft
                        ? "add host & connect"
                        : (isDraft ? "new host" : (host.name.isEmpty ? "host" : host.name)),
                    onCancel: onCancel,
                    onDelete: (isDraft || isContinuationDraft) ? nil : onDelete
                )
                if let continuationSourceLabel {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                        Text("from \(continuationSourceLabel)")
                    }
                    .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                    .foregroundStyle(T.accent)
                    .padding(.horizontal, isPhone ? 18 : 40)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T.accentSoft)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(T.border).frame(height: 0.5)
                    }
                }
                if !isPhone {
                    SegmentedTabBar(selectedTab: $selectedTab)
                } else if !isContinuationDraft {
                    CompactHostSectionPicker(selectedTab: $selectedTab)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if continuationSourceLabel != nil {
                            Label(
                                "Sent as a secret-free descriptor. No password, private key, or trust pin was included; authentication happens on this device.",
                                systemImage: "lock.shield"
                            )
                            .font(Typography.tesseraMono(size: 10.5))
                            .foregroundStyle(T.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(T.inputBg)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(T.border, lineWidth: 1)
                            }
                        }

                        tabContent
                    }
                        .padding(.horizontal, isPhone ? 18 : 40)
                        .padding(.top, isPhone ? 20 : 28)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 560, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isPhone {
                compactEditorBar
            } else {
                connectBar
            }
        }
        .task(id: host.id) {
            // Secrets are scoped to one explicit host edit. Structural view
            // reuse must never make one host's password observable or usable
            // by the next host.
            credentials.beginEditing(hostID: host.id)
            credentialPersistenceError = nil
            compactDraftLoaded = false
            isOSManual = HostOSDetectionState.isManuallySet(hostID: host.id)
            jumpHostID = HostJumpChainResolver.link(for: host.id, in: modelContext)?.jumpHostID
            loadCompactDraftIfNeeded()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if isPhone {
            switch selectedTab {
            case .forwarding:
                forwardingTab
            default:
                connectionTab
            }
        } else {
            switch selectedTab {
            case .connection:
                connectionTab
            case .advanced:
                advancedTab
            case .forwarding:
                forwardingTab
            case .snippets:
                snippetsTab
            }
        }
    }

    private var connectBar: some View {
        Btn(style: .primary, full: true, action: {
            connectFromEditor()
        }) {
            HStack {
                Text("connect")
                    .font(Typography.tesseraMono(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.right")
            }
        }
        .disabled(!connectEnabled)
        .opacity(connectEnabled ? 1 : 0.5)
        .padding(.horizontal, isPhone ? 18 : 36)
        .padding(.vertical, 16)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(T.presentationBg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)
        }
    }

    private var compactEditorBar: some View {
        HStack(spacing: 10) {
            Btn("cancel", full: true, action: onCancel)
            Btn(compactPrimaryTitle, style: .primary, full: true, action: saveCompactDraft)
                .disabled(!compactSaveEnabled)
                .opacity(
                    compactSaveEnabled ? 1 : 0.5
                )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(T.presentationBg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)
        }
    }

    private var connectEnabled: Bool {
        !compactAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && (!destinationNeedsCredentialInput || !credentials.password.isEmpty)
            && passwordJumpHosts.allSatisfy { !jumpPasswordRequired(for: $0) }
    }

    private var compactSaveEnabled: Bool {
        !compactAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isContinuationDraft
                || !destinationNeedsCredentialInput
                || !credentials.password.isEmpty)
            && passwordJumpHosts.allSatisfy { !jumpPasswordRequired(for: $0) }
    }

    // MARK: - Tabs

    private var connectionTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Field(label: "name") {
                Input(text: hostNameBinding, placeholder: "my-server")
            }

            if isPhone {
                HStack(alignment: .top, spacing: 12) {
                    addressField
                    portField
                        .frame(width: 86)
                }
            } else {
                addressField

                HStack(spacing: 16) {
                    portField
                        .frame(width: 120)
                    Spacer()
                }
            }

            if isPhone {
                HStack(alignment: .top, spacing: 12) {
                    userField
                    identityField
                }
            } else {
                userField
                identityField
            }

            if !isPhone && !isContinuationDraft && !destinationNeedsCredentialInput {
                Field(label: "password") {
                    Input(text: $credentials.password, placeholder: "••••••••", secure: true)
                        .textContentType(.password)
                }
            }

            if destinationNeedsCredentialInput {
                CredentialCardView(
                    password: $credentials.password,
                    hostName: hostNameBinding.wrappedValue,
                    errorMessage: credentialPersistenceError,
                    onAuthorizeFromPeer: preparedPeerAuthorizationAction
                )
            }

            transportSection

            if !isPhone {
                jumpHostSection
                launchSection
            } else {
                compactContinuationRouteSummary
                if isCredentialSetupContext {
                    compactContinuationJumpCredentials
                }
                Text("jump chains, environment variables, startup snippets, and terminal backgrounds remain editable on iPad.")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var compactContinuationRouteSummary: some View {
        if let continuationAction {
            Field(label: "handoff action") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        continuationAction == .continueSession
                            ? "continue tmux session"
                            : "reconnect with a new shell"
                    )
                    .font(Typography.tesseraMono(size: 12.5, weight: .medium))
                    .foregroundStyle(T.fg)

                    if continuationAction == .continueSession,
                       let sessionName = continuationTmuxSessionName,
                       !sessionName.isEmpty {
                        Text(sessionName)
                            .font(Typography.tesseraMono(size: 11.5))
                            .foregroundStyle(T.accent)
                    }

                    Text(
                        continuationAction == .continueSession
                            ? "the same server-side screen remains attached on both devices."
                            : "plain SSH and mosh open a new remote shell on this device."
                    )
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(T.border, lineWidth: 1)
                }
            }
        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Field(label: "os logo") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        osModeButton(manual: false, label: "auto")
                        osModeButton(manual: true,  label: "manual")
                    }
                    .animation(.easeInOut(duration: 0.15), value: isOSManual)

                    if isOSManual {
                        // Manual override — pick any OS from the list.
                        // Setter is straight assignment; the manual flag
                        // is already on, so the next probe writeback will
                        // be ignored.
                        Menu {
                            ForEach(osHintOptions, id: \.self) { option in
                                Button(option) { host.osHint = option }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(host.osHint)
                                    .font(Typography.tesseraMono(size: 13))
                                    .foregroundStyle(T.fg)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(Typography.tesseraMono(size: 11))
                                    .foregroundStyle(T.fgDim)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(T.inputBg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(T.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("auto-detected on connect (currently: \(host.osHint))")
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgDim)
                    }
                }
            }

            terminalBackgroundField

            Field(label: "tags") {
                VStack(alignment: .leading, spacing: 10) {
                    if !host.tags.isEmpty {
                        tagPills
                    }

                    HStack(spacing: 8) {
                        Input(text: $newTag, placeholder: "tag")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addTag)

                        Btn("add", style: .default, compact: true, action: addTag)
                            .disabled(trimmedNewTag.isEmpty)
                            .opacity(trimmedNewTag.isEmpty ? 0.5 : 1)
                    }
                }
            }

            Field(label: "notes", sub: "free-form, shown in tooltips and host details") {
                multilineInput("notes", text: $host.notes)
            }

            Field(label: "environment variables", sub: "one KEY=value per line; an optional leading `export ` is stripped. values are passed to the remote shell verbatim — `$HOME`, `$(…)`, and quotes work as written.") {
                multilineInput("PATH=/opt/local/bin:$PATH\nEDITOR=nvim", text: $host.envVars)
            }

            Text("tmux gotcha: env vars and the startup snippet only run when tmux *starts*. if you re-attach to an existing tmux session on this host, the running panes keep their old env. run `tmux kill-server` on the remote (or kill the session) and reconnect to pick up changes.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -8)
        }
    }

    private var forwardingTab: some View {
        ForwardingTabView(
            host: host,
            stagedRules: $compactPortForwardRules,
            transportOverride: compactTransport
        )
    }

    // MARK: - Terminal background override

    private var backgroundOverride: HostTerminalBackgroundOverride {
        hostBackgrounds.override(for: host.id)
    }

    private var selectedTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var globalBackgroundCaption: String {
        if let bg = appearance.globalTerminalBackground {
            return "follows settings → themes (currently: custom image · dim \(Int((bg.dim * 100).rounded()))%)."
        }
        return "follows settings → themes (currently: theme color)."
    }

    private var terminalBackgroundField: some View {
        Field(label: "terminal background") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    backgroundModeButton(.inherit, label: "global")
                    backgroundModeButton(.color, label: "theme color")
                    backgroundModeButton(.image, label: "image")
                }
                .animation(.easeInOut(duration: 0.15), value: backgroundOverride.mode)

                switch backgroundOverride.mode {
                case .inherit:
                    Text(globalBackgroundCaption)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .color:
                    Text("always the theme's solid color on this host, even when a global picture is set.")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                case .image:
                    TerminalBackgroundImageControls(
                        imageID: backgroundOverride.imageID,
                        dim: backgroundOverride.dim,
                        blur: backgroundOverride.blur,
                        fillMode: backgroundOverride.fillMode,
                        theme: selectedTheme,
                        onImport: { data in
                            guard let imported = TerminalBackgroundImageStore.importImage(data: data) else {
                                NSLog("[TerminalBackground] host import failed host=%@", host.id.uuidString)
                                return
                            }
                            // set(_:for:) deletes the previously stored file
                            // when the id changes.
                            var override = backgroundOverride
                            override.imageID = imported.id
                            hostBackgrounds.set(override, for: host.id)
                        },
                        onRemove: {
                            var override = backgroundOverride
                            override.imageID = nil
                            hostBackgrounds.set(override, for: host.id)
                        },
                        onDimChanged: { dim in
                            var override = backgroundOverride
                            override.dim = dim
                            hostBackgrounds.set(override, for: host.id)
                        },
                        onBlurChanged: { blur in
                            var override = backgroundOverride
                            override.blur = blur
                            hostBackgrounds.set(override, for: host.id)
                        },
                        onFillModeChanged: { mode in
                            var override = backgroundOverride
                            override.fillMode = mode
                            hostBackgrounds.set(override, for: host.id)
                        }
                    )
                }
            }
        }
    }

    private func backgroundModeButton(
        _ mode: HostTerminalBackgroundMode,
        label: String
    ) -> some View {
        let isSelected = backgroundOverride.mode == mode
        return Btn(style: isSelected ? .primary : .default, full: true, action: {
            var override = backgroundOverride
            override.mode = mode
            hostBackgrounds.set(override, for: host.id)
        }) {
            Text(label)
                .font(Typography.tesseraMono(size: 13, weight: isSelected ? .semibold : .regular))
        }
    }

    private var snippetsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Field(label: "startup snippet", sub: "commands run immediately after connect") {
                multilineInput("startup snippet", text: $host.startupSnippet)
            }
        }
    }

    // MARK: - User + identity rows

    private var addressField: some View {
        Field(label: "address") {
            Input(text: hostAddressBinding, placeholder: "192.168.1.10")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
        }
    }

    private var userField: some View {
        Field(label: "user") {
            Input(text: hostUserBinding, placeholder: "username")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
        }
    }

    /// Inline native Picker (matches the os-hint Picker styling). Lists
    /// every `StoredKey` so the user can pick a key directly without
    /// having to manage `Identity` entities by hand. Selection writes
    /// through to `host.identity`, find-or-creating an Identity that
    /// wraps the chosen key.
    private var identityField: some View {
        Field(label: "identity") {
            Menu {
                Button("None") { identityKeyBinding.wrappedValue = nil }
                ForEach(storedKeys) { key in
                    Button(key.name) { identityKeyBinding.wrappedValue = key.id }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(identityDisplayLabel)
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fg)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(T.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var identityDisplayLabel: String {
        if !compactIdentityWasChanged,
           compactIdentityKeyID == nil,
           let identity = host.identity {
            if !identity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return identity.name
            }
            switch identity.credentialMode {
            case .password:
                return "Password"
            case .legacyDevKey:
                return "Legacy key"
            case .none:
                return "None"
            case .key:
                break
            }
        }
        guard let id = identityKeyBinding.wrappedValue else { return "None" }
        return storedKeys.first(where: { $0.id == id })?.name ?? "None"
    }

    private var identityKeyBinding: Binding<UUID?> {
        Binding(
            get: { compactIdentityKeyID },
            set: { newKeyID in
                compactIdentityKeyID = newKeyID
                compactIdentityWasChanged = true
            }
        )
    }

    /// Find an existing Identity whose credentialMode is `.key(id)`,
    /// or create a fresh one named after the key. Identities
    /// accumulate one-per-key so reuse across hosts works without
    /// the user opening any identity-management UI.
    private func identityForKey(_ keyID: UUID) -> Identity? {
        let descriptor = FetchDescriptor<Identity>()
        if let identities = try? modelContext.fetch(descriptor),
           let existing = identities.first(where: {
               if case .key(let id) = $0.credentialMode, id == keyID {
                   return true
               }
               return false
           })
        {
            return existing
        }

        let key = storedKeys.first(where: { $0.id == keyID })
        let identity = Identity(
            name: key?.name ?? "",
            user: "",
            credentialMode: .key(keyID)
        )
        modelContext.insert(identity)
        return identity
    }

    private var tagPills: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(host.tags.enumerated()), id: \.offset) { index, tag in
                Button {
                    removeTag(at: index)
                } label: {
                    HStack(spacing: 4) {
                        Text(tag)
                        Text("✕")
                    }
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgMuted)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 7)
                    .background(T.isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(T.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var trimmedNewTag: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTag() {
        let tag = trimmedNewTag
        guard !tag.isEmpty else { return }
        guard !host.tags.contains(tag) else {
            newTag = ""
            return
        }

        host.tags.append(tag)
        newTag = ""
    }

    private func removeTag(at index: Int) {
        guard host.tags.indices.contains(index) else { return }
        host.tags.remove(at: index)
    }

    private func multilineInput(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(4...10)
            .font(Typography.tesseraMono(size: 13))
            .foregroundStyle(T.fg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(T.border, lineWidth: 1)
            )
    }

    // MARK: - Launch mode section (R6.7 + R6.8)

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("transport")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)

            HStack(spacing: 8) {
                transportButton(.ssh, label: "ssh")
                transportButton(.mosh, label: "mosh")
            }
            .animation(.easeInOut(duration: 0.15), value: selectedTransport)

            Text(selectedTransport.editorDescription)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Jump host

    private var eligibleJumpHosts: [PersistedHost] {
        HostJumpChainResolver.eligibleJumpHosts(for: host.id, in: modelContext)
            .sorted {
                jumpHostDisplayName($0).localizedCaseInsensitiveCompare(
                    jumpHostDisplayName($1)
                ) == .orderedAscending
            }
    }

    private func jumpHostDisplayName(_ host: PersistedHost) -> String {
        host.name.isEmpty ? host.address : host.name
    }

    private var selectedJumpHostLabel: String {
        guard let jumpHostID else { return "none" }
        let descriptor = FetchDescriptor<PersistedHost>(
            predicate: #Predicate { $0.id == jumpHostID }
        )
        guard let bastion = (try? modelContext.fetch(descriptor))?.first else {
            return "missing host"
        }
        return jumpHostDisplayName(bastion)
    }

    /// Resolved multi-hop path (or the broken-chain warning) for the
    /// caption under the picker.
    private var jumpChainCaption: String? {
        guard jumpHostID != nil else { return nil }
        let resolution = HostJumpChainResolver.resolve(for: host, in: modelContext)
        if resolution.isBroken {
            return "⚠ \(resolution.brokenReason ?? "the jump chain could not be resolved.") connections fail until this is fixed."
        }
        let path = (resolution.hops.map(jumpHostDisplayName)
                    + [jumpHostDisplayName(host)]).joined(separator: " → ")
        var caption = "path: \(path)"
        if resolution.hops.count > 1 {
            caption += " (the jump host's own jump host extends the chain)"
        }
        if host.transport == .mosh {
            caption += "\nmosh UDP cannot traverse bastions — if the mosh server is unreachable the session falls back to SSH."
        }
        return caption
    }

    private func setJumpHost(_ id: UUID?) {
        HostJumpChainResolver.setJumpHost(id, for: host.id, in: modelContext)
        try? modelContext.save()
        jumpHostID = id
    }

    private var passwordJumpHosts: [PersistedHost] {
        let resolution = HostJumpChainResolver.resolve(for: host, in: modelContext)
        guard !resolution.isBroken else { return [] }
        return resolution.hops.filter {
            switch $0.identity?.credentialMode {
            case .some(.password):
                return true
            case nil, .some(.none):
                // A secret-free continuation cannot classify a fresh hop's
                // credential. Offer an explicit transient password field; a
                // configured key/legacy-key identity remains authoritative and
                // must never be weakened into a password fallback.
                return isCredentialSetupContext
            case .some(.key), .some(.legacyDevKey):
                return false
            }
        }
    }

    private func jumpPasswordRequired(for jumpHost: PersistedHost) -> Bool {
        if hasStoredJumpPassword(for: jumpHost) { return false }
        return (credentials.jumpPasswords[jumpHost.id] ?? "").isEmpty
    }

    private func hasStoredJumpPassword(for jumpHost: PersistedHost) -> Bool {
        guard let identity = jumpHost.identity,
              case .password = identity.credentialMode,
              let stored = try? KeychainHelper.password(forIdentityID: identity.id) else {
            return false
        }
        return !stored.isEmpty
    }

    private var jumpHostsNeedingPasswordInput: [PersistedHost] {
        passwordJumpHosts.filter { !hasStoredJumpPassword(for: $0) }
    }

    private func jumpPasswordBinding(for hostID: UUID) -> Binding<String> {
        Binding(
            get: { credentials.jumpPasswords[hostID] ?? "" },
            set: { credentials.jumpPasswords[hostID] = $0 }
        )
    }

    @ViewBuilder
    private var jumpPasswordInputs: some View {
        ForEach(jumpHostsNeedingPasswordInput, id: \.id) { jumpHost in
            Field(label: "password · \(jumpHostDisplayName(jumpHost))") {
                Input(
                    text: jumpPasswordBinding(for: jumpHost.id),
                    placeholder: "••••••••",
                    secure: true
                )
                .textContentType(.password)
            }
        }

        if !jumpHostsNeedingPasswordInput.isEmpty {
            Text(isContinuationDraft
                 ? "stored only in this device's keychain — never synced"
                 : "jump-host passwords are kept only for this live session.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
        }
    }

    private var compactContinuationJumpCredentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !jumpHostsNeedingPasswordInput.isEmpty {
                Text("jump-host authentication")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                jumpPasswordInputs
            }

            if let jumpChainCaption {
                Text(jumpChainCaption)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var jumpHostSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("jump host")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)

            Menu {
                Button("none") { setJumpHost(nil) }
                ForEach(eligibleJumpHosts, id: \.id) { candidate in
                    Button(jumpHostDisplayName(candidate)) {
                        setJumpHost(candidate.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedJumpHostLabel)
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fg)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(T.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            jumpPasswordInputs

            Text(jumpChainCaption
                 ?? "connect through another saved host (SSH bastion / ProxyJump).")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    /// Single segmented picker + one conditional field. The three modes
    /// are mutually exclusive by design — users pick exactly one of
    /// auto-tmux (default name), pinned-tmux (user-specified name), or
    /// custom command (replaces auto-tmux entirely).
    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("launch")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)

            // Custom 3-way segmented control. SwiftUI's .segmented
            // picker renders unselected labels as low-contrast gray
            // which is invisible on the black background — so we
            // roll our own using the same styling vocabulary as the
            // rest of the form (white opacity-0.08 field background
            // for unselected, solid white for selected).
            HStack(spacing: 8) {
                modeButton(.autoTmux, label: "auto-tmux")
                modeButton(.pinnedTmux, label: "named tmux")
                modeButton(.customCommand, label: "custom")
            }
            .animation(.easeInOut(duration: 0.15), value: host.launchMode)

            switch host.launchMode {
            case .autoTmux:
                Text(autoTmuxDescription)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            case .pinnedTmux:
                Field(label: "tmux session name") {
                    Input(
                        text: optionalStringBinding($host.tmuxSessionName),
                        placeholder: "dev"
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Text("letters, numbers, dash, underscore, dot only; anything else falls back to the auto-derived name.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            case .customCommand:
                Field(label: "launch command") {
                    Input(
                        text: optionalStringBinding($host.launchCommand),
                        placeholder: customLaunchPlaceholder
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Text(customLaunchDescription)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            }
        }
        .padding(.vertical, 4)
    }

    private func transportButton(_ transport: HostTransport, label: String) -> some View {
        let isSelected = selectedTransport == transport
        return Btn(style: isSelected ? .primary : .default, full: true, action: {
            compactTransport = transport
        }) {
            Text(label)
                .font(Typography.tesseraMono(size: 13, weight: isSelected ? .semibold : .regular))
        }
    }

    private func modeButton(_ mode: HostLaunchMode, label: String) -> some View {
        let isSelected = host.launchMode == mode
        return Btn(style: isSelected ? .primary : .default, full: true, action: { host.launchMode = mode }) {
            Text(label)
                .font(Typography.tesseraMono(size: 13, weight: isSelected ? .semibold : .regular))
        }
    }

    /// Two-state segmented button for the os-logo auto/manual selector.
    /// Mirrors the launch-mode and transport buttons stylistically.
    private func osModeButton(manual: Bool, label: String) -> some View {
        let isSelected = isOSManual == manual
        return Btn(style: isSelected ? .primary : .default, full: true, action: {
            isOSManual = manual
            if manual {
                HostOSDetectionState.markManuallySet(hostID: host.id)
            } else {
                HostOSDetectionState.clearManualFlag(hostID: host.id)
            }
        }) {
            Text(label)
                .font(Typography.tesseraMono(size: 13, weight: isSelected ? .semibold : .regular))
        }
    }

    private var derivedSessionName: String {
        let key = "\(compactUser)@\(compactAddress):\(compactPort)"
        return AutoTmuxScript.defaultSessionName(forHostKey: key)
    }

    private var autoTmuxDescription: String {
        switch selectedTransport {
        case .ssh:
            return "attach to per-host tmux session `\(derivedSessionName)`."
        case .mosh:
            return "start mosh inside per-host tmux session `\(derivedSessionName)`."
        }
    }

    private var customLaunchPlaceholder: String {
        switch selectedTransport {
        case .ssh:
            return "exec tmux -CC new -s dev"
        case .mosh:
            return "exec zsh -l"
        }
    }

    private var customLaunchDescription: String {
        switch selectedTransport {
        case .ssh:
            return "sent verbatim to the login shell on connect."
        case .mosh:
            return "run by `mosh-server new -- <command>` as the initial command."
        }
    }

    // MARK: - Port field

    private var portField: some View {
        Field(label: "port") {
            TextField(
                "22",
                value: hostPortBinding,
                formatter: NumberFormatter.port
            )
            .font(Typography.tesseraMono(size: 13))
            .foregroundStyle(T.fg)
            .keyboardType(.numberPad)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(T.border, lineWidth: 1)
            )
        }
    }

    private var selectedTransport: HostTransport {
        compactTransport
    }

    private var hostNameBinding: Binding<String> {
        $compactName
    }

    private var hostAddressBinding: Binding<String> {
        $compactAddress
    }

    private var hostUserBinding: Binding<String> {
        $compactUser
    }

    private var hostPortBinding: Binding<Int> {
        $compactPort
    }

    private func loadCompactDraftIfNeeded() {
        guard !compactDraftLoaded else { return }
        compactName = host.name
        compactAddress = host.address
        compactPort = host.port
        compactUser = host.user
        compactTransport = host.transport
        compactPortForwardRules = RuleCodec.decode(host.portForwardRulesData)
        if let identity = host.identity,
           case .key(let keyID) = identity.credentialMode {
            compactIdentityKeyID = keyID
        } else {
            compactIdentityKeyID = nil
        }
        compactIdentityWasChanged = false
        compactDraftLoaded = true
    }

    private func saveCompactDraft() {
        guard compactSaveEnabled else { return }

        commitStagedHostFields()
        guard persistCredentialPasswordIfNeeded(
            required: isContinuationDraft
        ) else { return }
        guard prepareContinuationJumpPasswordIdentitiesIfNeeded() else { return }
        try? modelContext.save()
        let hostID = host.id
        let savedRules = compactPortForwardRules
        Task {
            if let manager = tunnelsRegistry.manager(for: hostID) {
                await manager.reconcile(newRules: savedRules)
            }
        }
        if isContinuationDraft {
            onConnect(host, credentials.password, credentials.jumpPasswords)
        } else {
            onSave?()
        }
    }

    private func commitStagedHostFields() {
        host.name = compactName.trimmingCharacters(in: .whitespacesAndNewlines)
        host.address = compactAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        host.port = compactPort
        host.user = compactUser.trimmingCharacters(in: .whitespacesAndNewlines)
        host.transport = compactTransport
        host.setPortForwardRules(compactPortForwardRules)
        if compactIdentityWasChanged {
            host.identity = compactIdentityKeyID.flatMap(identityForKey(_:))
        }
    }

    private func connectFromEditor() {
        guard connectEnabled else { return }
        commitStagedHostFields()
        guard persistCredentialPasswordIfNeeded(required: true) else { return }
        guard prepareContinuationJumpPasswordIdentitiesIfNeeded() else { return }
        onConnect(host, credentials.password, credentials.jumpPasswords)
    }

    /// Enrollment replaces only the destination credential. A newly imported
    /// route may still contain password-backed bastions, so prepare those
    /// local-only credentials before opening the peer stream.
    private var preparedPeerAuthorizationAction: (() -> Void)? {
        guard let onAuthorizeFromPeer,
              peerAuthorizationRouteIsRepairable else { return nil }
        return {
            guard prepareContinuationJumpPasswordIdentitiesIfNeeded() else {
                return
            }
            onAuthorizeFromPeer()
        }
    }

    /// Enrollment changes only the destination identity. Every bastion must
    /// therefore already be usable, or be a password/unconfigured hop for
    /// which this editor provides a local repair field. Missing key material
    /// and broken routes cannot be repaired by peer authorization.
    private var peerAuthorizationRouteIsRepairable: Bool {
        let resolution = HostJumpChainResolver.resolve(for: host, in: modelContext)
        guard !resolution.isBroken else { return false }
        return resolution.hops.allSatisfy { hop in
            switch hop.identity?.credentialMode {
            case nil, .some(.none), .some(.password):
                return true
            case .some(.key), .some(.legacyDevKey):
                return SessionRestoreEligibility.isRestorable(
                    host: hop,
                    storedKey: { keyID in
                        storedKeys.first(where: { $0.id == keyID })
                    }
                )
            }
        }
    }

    private var destinationNeedsCredentialInput: Bool {
        if compactIdentityWasChanged {
            return compactIdentityKeyID == nil
        }
        guard let identity = host.identity else { return true }
        switch identity.credentialMode {
        case .none:
            return true
        case .password:
            guard let stored = try? KeychainHelper.password(
                forIdentityID: identity.id
            ) else { return true }
            return stored.isEmpty
        case .key(let keyID):
            return !storedKeys.contains(where: { $0.id == keyID })
        case .legacyDevKey:
            return false
        }
    }

    private var routeHasUnconfiguredCredential: Bool {
        let resolution = HostJumpChainResolver.resolve(for: host, in: modelContext)
        guard !resolution.isBroken else { return false }
        return resolution.hops.contains { hop in
            guard let identity = hop.identity else { return true }
            switch identity.credentialMode {
            case .none:
                return true
            case .password:
                guard let stored = try? KeychainHelper.password(
                    forIdentityID: identity.id
                ) else { return true }
                return stored.isEmpty
            case .key(let keyID):
                return !storedKeys.contains(where: { $0.id == keyID })
            case .legacyDevKey:
                return false
            }
        }
    }

    private var isCredentialSetupContext: Bool {
        isContinuationDraft
            || destinationNeedsCredentialInput
            || routeHasUnconfiguredCredential
    }

    /// A fresh continuation hop has public endpoint data but deliberately no
    /// credential classification. At the explicit Connect tap, classify only
    /// unconfigured hops as password-backed and retain the entered password in
    /// this device's existing ThisDeviceOnly Keychain boundary. That makes the
    /// one-time continuation setup honest for the complete route; no password
    /// enters SwiftData or either cross-device payload.
    private func prepareContinuationJumpPasswordIdentitiesIfNeeded() -> Bool {
        guard isCredentialSetupContext else { return true }

        for jumpHost in passwordJumpHosts {
            let identity: Identity
            switch jumpHost.identity?.credentialMode {
            case .some(.password):
                guard let existing = jumpHost.identity else { return false }
                identity = existing
            case nil, .some(.none):
                let created = Identity(
                    name: jumpHost.name.isEmpty
                        ? "\(jumpHost.address) password"
                        : "\(jumpHost.name) password",
                    user: jumpHost.user,
                    credentialMode: .password
                )
                modelContext.insert(created)
                jumpHost.identity = created
                ContinuationDraftRecoveryStore().registerCreatedIdentity(
                    created.id
                )
                identity = created
            case .some(.key), .some(.legacyDevKey):
                continue
            }

            let enteredPassword = credentials.jumpPasswords[jumpHost.id] ?? ""
            if enteredPassword.isEmpty, hasStoredJumpPassword(for: jumpHost) {
                continue
            }
            guard !enteredPassword.isEmpty else {
                credentialPersistenceError = "Enter a password for every unconfigured jump host."
                return false
            }
            do {
                try KeychainHelper.setPassword(
                    enteredPassword,
                    forIdentityID: identity.id
                )
            } catch {
                credentialPersistenceError = error.localizedDescription
                return false
            }
        }

        do {
            try modelContext.save()
            credentialPersistenceError = nil
            return true
        } catch {
            credentialPersistenceError = error.localizedDescription
            return false
        }
    }

    /// A password entered for a continuation is a one-time setup cost. Keep it
    /// available for later one-tap continuations on this device, using the
    /// existing ThisDeviceOnly Keychain boundary. Nothing here is encodable by
    /// either cross-device descriptor.
    private func persistCredentialPasswordIfNeeded(required: Bool) -> Bool {
        guard destinationNeedsCredentialInput else {
            credentialPersistenceError = nil
            return true
        }
        guard !credentials.password.isEmpty else {
            if required {
                credentialPersistenceError = onAuthorizeFromPeer == nil
                    ? "Enter a password or choose a key before connecting."
                    : "Enter a password or authorize this device from your other device."
                return false
            }
            credentialPersistenceError = nil
            return true
        }

        let identity: Identity
        if let existing = host.identity,
           case .password = existing.credentialMode {
            identity = existing
        } else {
            identity = Identity(
                name: host.name.isEmpty ? "password" : "\(host.name) password",
                user: host.user,
                credentialMode: .password
            )
            modelContext.insert(identity)
            host.identity = identity
            ContinuationDraftRecoveryStore().registerCreatedIdentity(
                identity.id
            )
        }

        do {
            try KeychainHelper.setPassword(credentials.password, forIdentityID: identity.id)
            try modelContext.save()
            credentialPersistenceError = nil
            return true
        } catch {
            credentialPersistenceError = error.localizedDescription
            return false
        }
    }
}

private struct PageHeader: View {
    var title: String
    var onCancel: () -> Void
    var onDelete: (() -> Void)?

    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(Typography.heroTitle)
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let onDelete, !isPhone {
                    Btn("delete", style: .danger, compact: true, action: onDelete)
                }
                if isPhone {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(T.fgMuted)
                            .frame(width: 44, height: 44)
                            .background(T.inputBg)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(T.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("cancel")
                } else {
                    Btn("cancel", style: .default, compact: true, action: onCancel)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 24)
            .padding(.horizontal, 40)

            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }
}

private struct SegmentedTabBar: View {
    @Binding var selectedTab: Tab

    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 0) {
                        Text(tab.rawValue)
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(selectedTab == tab ? T.fg : T.fgMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        Rectangle()
                            .fill(selectedTab == tab ? T.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 40)
        .overlay(alignment: .bottom) {
            Rectangle().fill(T.border).frame(height: 0.5)
        }
        .animation(.easeInOut(duration: 0.15), value: selectedTab)
    }
}

/// The compact editor intentionally exposes only the phone-supported host
/// sections. Forwarding uses the same rule editor as iPad; connection fields
/// and rules are both staged until the bottom Save action.
private struct CompactHostSectionPicker: View {
    @Binding var selectedTab: Tab
    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(spacing: 8) {
            sectionButton(.connection, title: "connection")
            sectionButton(.forwarding, title: "tunnels")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(T.presentationBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(T.border).frame(height: 0.5)
        }
    }

    private func sectionButton(_ tab: Tab, title: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(title)
                .font(Typography.tesseraMono(size: 12, weight: .medium))
                .foregroundStyle(selectedTab == tab ? T.fg : T.fgMuted)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selectedTab == tab ? T.accentSoft : T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(selectedTab == tab ? T.accent.opacity(0.6) : T.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return layout(sizes: sizes, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let positions = layout(sizes: sizes, width: bounds.width).positions

        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y),
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func layout(sizes: [CGSize], width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        guard !sizes.isEmpty else {
            return (.zero, [])
        }

        var positions: [CGPoint] = []
        var cursor = CGPoint.zero
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for size in sizes {
            if cursor.x > 0 && cursor.x + size.width > width {
                cursor.x = 0
                cursor.y += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(cursor)
            measuredWidth = max(measuredWidth, cursor.x + size.width)
            cursor.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (
            CGSize(width: min(measuredWidth, width), height: cursor.y + lineHeight),
            positions
        )
    }
}

/// Bridges a `Binding<String?>` to a `Binding<String>` for TextField use.
/// Empty string maps back to `nil` so the persistence layer stores the
/// "unset" state as absent rather than as an empty string.
private func optionalStringBinding(_ source: Binding<String?>) -> Binding<String> {
    Binding(
        get: { source.wrappedValue ?? "" },
        set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}

private extension NumberFormatter {
    static var port: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 65535
        f.allowsFloats = false
        return f
    }
}
