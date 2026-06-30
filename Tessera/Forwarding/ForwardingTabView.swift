import SwiftUI
import PortForwarding

/// Replaces the placeholder forwarding tab in `HostDetailView`. Lets the
/// user add / edit / delete / toggle local port-forward rules attached
/// to a single host. Rules persist as a Codable Data blob on
/// `PersistedHost.portForwardRulesData`; this view round-trips through
/// `RuleCodec` so the SwiftData model stays the source of truth.
///
/// Edits happen inline: tapping a rule expands its card into a form
/// (cancel/save at the bottom), and the trailing iOS toggle on each row
/// is the source of truth for `enabled`. On every persistence write we
/// also call `PortForwarderManager.reconcile(...)` against the host's
/// live manager (if connected) so changes apply immediately.
///
/// Mosh hosts can't carry forwards (the bootstrap SSH client is closed
/// immediately after extracting the UDP key), so when transport is mosh
/// the "+ add rule" button is disabled with a one-line caption. Existing
/// rules stay visible — toggling transport between ssh/mosh shouldn't
/// silently delete the user's work.
struct ForwardingTabView: View {
    @Bindable var host: PersistedHost
    @Environment(\.designTokens) private var T
    @Environment(TunnelsRegistry.self) private var tunnelsRegistry

    @State private var editing: EditState? = nil
    @State private var pendingDelete: PortForwardRule? = nil
    @State private var pendingSwitch: PendingSwitch? = nil
    @State private var newRuleID: UUID = UUID()

    @State private var localPortText: String = ""
    @State private var remoteHost: String = "localhost"
    @State private var remotePortText: String = ""
    @State private var ruleLabel: String = ""
    @State private var autoStart: Bool = true

    private enum EditState: Equatable {
        case existing(id: UUID)
        case new
    }

    private struct PendingSwitch: Identifiable {
        let id = UUID()
        let target: Target
        enum Target {
            case existingID(UUID)
            case new
            case dismiss
        }
    }

    private var rules: [PortForwardRule] {
        RuleCodec.decode(host.portForwardRulesData)
    }

    private var isForwardingDisabled: Bool {
        host.transport == .mosh && host.launchMode == .customCommand
    }

    private var originalForEditing: PortForwardRule? {
        guard case .existing(let id)? = editing else { return nil }
        return rules.first(where: { $0.id == id })
    }

    private var draft: PortForwardRule? {
        guard let editing else { return nil }
        guard let lp = UInt16(localPortText.trimmingCharacters(in: .whitespaces)),
              let rp = UInt16(remotePortText.trimmingCharacters(in: .whitespaces))
        else { return nil }

        let id: UUID
        let enabled: Bool
        switch editing {
        case .existing(let existingID):
            id = existingID
            enabled = originalForEditing?.enabled ?? true
        case .new:
            id = newRuleID
            enabled = true
        }

        return PortForwardRule(
            id: id,
            enabled: enabled,
            autoStart: autoStart,
            localPort: lp,
            remoteHost: remoteHost.trimmingCharacters(in: .whitespaces),
            remotePort: rp,
            label: ruleLabel.trimmingCharacters(in: .whitespaces)
        )
    }

    private var validationError: String? {
        guard let editing else { return nil }
        guard let draft else {
            if localPortText.isEmpty || remotePortText.isEmpty { return nil }
            return "ports must be numbers between 1 and 65535"
        }
        let siblings: [PortForwardRule]
        switch editing {
        case .existing(let id): siblings = rules.filter { $0.id != id }
        case .new:              siblings = rules
        }
        do {
            try RuleValidator.validate(rule: draft, against: siblings)
            return nil
        } catch let error as RuleValidationError {
            return describe(error)
        } catch {
            return error.localizedDescription
        }
    }

    private var canSave: Bool { draft != nil && validationError == nil }

    private var isDirty: Bool {
        guard let editing else { return false }
        switch editing {
        case .existing:
            guard let original = originalForEditing else { return true }
            if localPortText != String(original.localPort) { return true }
            if remoteHost != original.remoteHost { return true }
            if remotePortText != String(original.remotePort) { return true }
            if ruleLabel != original.label { return true }
            if autoStart != original.autoStart { return true }
            return false
        case .new:
            return !localPortText.isEmpty
                || !remotePortText.isEmpty
                || !ruleLabel.isEmpty
                || remoteHost != "localhost"
                || !autoStart
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("port forwarding rules applied when this host connects.")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)

            if rules.isEmpty {
                Text("no rules configured")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgDim)
            } else {
                VStack(spacing: 8) {
                    ForEach(rules) { rule in
                        if case .existing(let id)? = editing, id == rule.id {
                            editCard(isNew: false, originalRule: rule)
                        } else {
                            compactCard(rule)
                        }
                    }
                }
            }

            if case .new? = editing {
                editCard(isNew: true, originalRule: nil)
            } else {
                addButton
            }

            if isForwardingDisabled {
                Text("this launch mode has no ssh connection to carry forwards. switch the launch mode to auto-tmux or pinned-tmux on the connection tab — those modes keep an ssh side-channel for tmux that forwarding can ride on. (or change transport to ssh.)")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -8)
            }
        }
        .alert(
            "delete rule?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { rule in
            Button("delete", role: .destructive) {
                deleteRule(rule)
                pendingDelete = nil
            }
            Button("cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { rule in
            Text(ruleSummary(rule))
        }
        .alert(
            "discard changes?",
            isPresented: Binding(
                get: { pendingSwitch != nil },
                set: { if !$0 { pendingSwitch = nil } }
            ),
            presenting: pendingSwitch
        ) { _ in
            Button("discard", role: .destructive) {
                if let target = pendingSwitch?.target {
                    applySwitch(to: target)
                }
                pendingSwitch = nil
            }
            Button("keep editing", role: .cancel) {
                pendingSwitch = nil
            }
        } message: { _ in
            Text("the form has unsaved changes.")
        }
    }

    // MARK: - Compact card

    @ViewBuilder
    private func compactCard(_ rule: PortForwardRule) -> some View {
        HStack(spacing: 10) {
            Button(action: { requestEdit(rule) }) {
                VStack(alignment: .leading, spacing: 3) {
                    portsRow(rule)
                    Text(rule.enabled ? "idle" : "disabled")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { pendingDelete = rule }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(for: rule))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(T.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func portsRow(_ rule: PortForwardRule) -> some View {
        HStack(spacing: 0) {
            Text(String(rule.localPort))
                .font(Typography.tesseraMono(size: 13).weight(.semibold))
                .foregroundStyle(rule.enabled ? T.accent : T.fgMuted)
            Text(" → ")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fgDim)
            Text(verbatim: "\(rule.remoteHost):\(rule.remotePort)")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(rule.enabled ? T.fg : T.fgMuted)
            if !rule.label.isEmpty {
                Text("  \"\(rule.label)\"")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
            }
        }
    }

    // MARK: - Edit card

    @ViewBuilder
    private func editCard(isNew: Bool, originalRule: PortForwardRule?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if isNew {
                    Text("new rule")
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fgDim)
                } else if let originalRule {
                    portsRow(originalRule)
                }
                Spacer(minLength: 0)
                Text(isNew ? "adding" : "editing")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                if let originalRule {
                    Toggle("", isOn: enabledBinding(for: originalRule))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(T.accent)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Field(label: "local port") {
                    Input(text: $localPortText, placeholder: "8080")
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .frame(width: 130)

                Text("→")
                    .font(Typography.tesseraMono(size: 16))
                    .foregroundStyle(T.fgDim)
                    .padding(.bottom, 24)

                Field(label: "remote port") {
                    Input(text: $remotePortText, placeholder: "8080")
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .frame(width: 130)

                Spacer(minLength: 0)
            }

            Field(label: "remote host", sub: "the address as seen from the SSH server") {
                Input(text: $remoteHost, placeholder: "localhost")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Field(label: "label (optional)") {
                Input(text: $ruleLabel, placeholder: "web app")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Divider().background(T.border)

            ToggleRow(
                title: "auto-start when connecting",
                subtitle: "open the listener automatically once the SSH session is up",
                isOn: $autoStart
            )

            HStack(spacing: 8) {
                Rectangle().fill(T.border).frame(height: 1)
                Text("presets")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                Rectangle().fill(T.border).frame(height: 1)
            }
            .padding(.vertical, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(presets, id: \.label) { preset in
                    Btn(preset.label, style: .default, compact: true) {
                        applyPreset(preset)
                    }
                }
            }

            if let err = validationError {
                Text(err)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.amber)
            }

            HStack(spacing: 8) {
                Spacer()
                Btn("cancel", style: .default, compact: true) {
                    cancelEdit()
                }
                Btn(isNew ? "add rule" : "save", style: .primary, compact: true) {
                    saveEdit()
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(T.accent.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Add affordance

    private var addButton: some View {
        Button(action: { requestNew() }) {
            HStack {
                Spacer()
                Text("+ add forwarding rule")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(isForwardingDisabled ? T.fgFaint : T.fgMuted)
                Spacer()
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(T.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isForwardingDisabled)
        .opacity(isForwardingDisabled ? 0.5 : 1)
    }

    // MARK: - Edit transitions

    private func requestEdit(_ rule: PortForwardRule) {
        if editing != nil && isDirty {
            pendingSwitch = PendingSwitch(target: .existingID(rule.id))
        } else {
            applySwitch(to: .existingID(rule.id))
        }
    }

    private func requestNew() {
        if editing != nil && isDirty {
            pendingSwitch = PendingSwitch(target: .new)
        } else {
            applySwitch(to: .new)
        }
    }

    private func cancelEdit() {
        if isDirty {
            pendingSwitch = PendingSwitch(target: .dismiss)
        } else {
            applySwitch(to: .dismiss)
        }
    }

    private func applySwitch(to target: PendingSwitch.Target) {
        switch target {
        case .existingID(let id):
            guard let rule = rules.first(where: { $0.id == id }) else {
                editing = nil
                return
            }
            populateForm(from: rule)
            editing = .existing(id: id)
        case .new:
            populateFormForNew()
            editing = .new
        case .dismiss:
            editing = nil
        }
    }

    private func populateForm(from rule: PortForwardRule) {
        localPortText = String(rule.localPort)
        remoteHost = rule.remoteHost
        remotePortText = String(rule.remotePort)
        ruleLabel = rule.label
        autoStart = rule.autoStart
    }

    private func populateFormForNew() {
        newRuleID = UUID()
        localPortText = ""
        remoteHost = "localhost"
        remotePortText = ""
        ruleLabel = ""
        autoStart = true
    }

    // MARK: - Save / toggle / delete

    private func saveEdit() {
        guard let editing, let draft, canSave else { return }
        var next = rules
        switch editing {
        case .existing(let id):
            if let i = next.firstIndex(where: { $0.id == id }) {
                next[i] = draft
            }
        case .new:
            next.append(draft)
        }
        applyAndReconcile(next)
        self.editing = nil
    }

    private func enabledBinding(for rule: PortForwardRule) -> Binding<Bool> {
        Binding(
            get: { rules.first(where: { $0.id == rule.id })?.enabled ?? rule.enabled },
            set: { newValue in
                var next = rules
                if let i = next.firstIndex(where: { $0.id == rule.id }) {
                    next[i].enabled = newValue
                    applyAndReconcile(next)
                }
            }
        )
    }

    private func deleteRule(_ rule: PortForwardRule) {
        if case .existing(let id)? = editing, id == rule.id {
            editing = nil
        }
        applyAndReconcile(rules.filter { $0.id != rule.id })
    }

    private func applyAndReconcile(_ next: [PortForwardRule]) {
        host.setPortForwardRules(next)
        let hostID = host.id
        Task {
            if let manager = tunnelsRegistry.manager(for: hostID) {
                await manager.reconcile(newRules: next)
            }
        }
    }

    // MARK: - Helpers

    private func describe(_ error: RuleValidationError) -> String {
        switch error {
        case .localPortOutOfRange:
            return "local port must be at least 1024 (iOS sandbox can't bind below 1024)"
        case .remoteHostEmpty:
            return "remote host can't be empty"
        case .remotePortInvalid:
            return "remote port must be between 1 and 65535"
        case .localPortCollision:
            return "another rule on this host already uses that local port"
        }
    }

    private func ruleSummary(_ rule: PortForwardRule) -> String {
        if rule.label.isEmpty {
            return "\(rule.localPort) → \(rule.remoteHost):\(rule.remotePort)"
        }
        return "\(rule.localPort) → \(rule.remoteHost):\(rule.remotePort) — \(rule.label)"
    }

    private struct Preset {
        let label: String
        let local: UInt16
        let remote: UInt16
    }

    private let presets: [Preset] = [
        Preset(label: "jupyter 8888", local: 8888, remote: 8888),
        Preset(label: "postgres 5432", local: 5432, remote: 5432),
        Preset(label: "mysql 3306", local: 3306, remote: 3306),
        Preset(label: "redis 6379", local: 6379, remote: 6379),
        Preset(label: "web 3000", local: 3000, remote: 3000),
        Preset(label: "web 8080", local: 8080, remote: 8080),
    ]

    private func applyPreset(_ p: Preset) {
        localPortText = String(p.local)
        remotePortText = String(p.remote)
    }
}
