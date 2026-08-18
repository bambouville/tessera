// Tessera/Settings/CustomShortcutEditorView.swift
// Define a shortcut of your own: what it's called, what fires it, what it
// sends, and where it applies.
//
// The token field is literal-first by design. The swipe pad's `MacroEncoder`
// spec language looks like the obvious fit and isn't — it strips every space
// and matches the bare words `tab`/`esc` anywhere, so "crontab -l" encodes as
// "cron"<TAB>"-l". Here text stays text and special keys are separate chips,
// so there is no grammar to get wrong. See CustomShortcut.swift.
import SwiftUI
import SwiftData

struct CustomShortcutEditorView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(ShortcutStore.self) private var store
    @Environment(AppearancePreferences.self) private var appearance

    @Query(sort: \PersistedHost.name) private var hosts: [PersistedHost]

    @State private var draft: CustomShortcut
    @State private var wantsChord: Bool
    @State private var wantsChip: Bool
    @State private var labelMode: LabelMode
    @State private var symbolName: String
    @State private var chipText: String
    @State private var bodyText: String
    @State private var trailingReturn: Bool
    @State private var scopeKind: ScopeKind
    @State private var processMatch: String
    @State private var selectedHosts: Set<UUID>
    @State private var recording = false

    private enum LabelMode: String, CaseIterable, Identifiable {
        case icon, text
        var id: String { rawValue }
    }

    private enum ScopeKind: String, CaseIterable, Identifiable {
        case everywhere, hosts, process
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everywhere: return String(localized: "everywhere")
            case .hosts:      return String(localized: "these hosts")
            case .process:    return String(localized: "this program")
            }
        }
        var caption: String {
            switch self {
            case .everywhere: return String(localized: "every session, every transport")
            case .hosts:      return String(localized: "pick the hosts it applies to")
            case .process:    return String(localized: "match the foreground process")
            }
        }
    }

    /// Stand-ins that read as terminal work. The picker is a curated strip
    /// rather than all 5,000 SF Symbols — a search field over the full set is
    /// a bigger surface than this feature needs, and any character can still be
    /// typed in text mode (including an emoji).
    private static let curatedSymbols = [
        "arrow.clockwise", "doc.text", "flag", "number", "doc.on.doc",
        "gearshape", "cylinder.split.1x2", "arrow.down.circle", "star",
        "checkmark", "xmark", "play.fill", "power", "bolt",
        "terminal", "hammer", "shippingbox", "leaf",
    ]

    init(shortcut: CustomShortcut) {
        _draft = State(initialValue: shortcut)
        _wantsChord = State(initialValue: shortcut.binding != nil)
        _wantsChip = State(initialValue: shortcut.chipLabel != nil || shortcut.binding == nil)

        switch shortcut.chipLabel {
        case .symbol(let name):
            _labelMode = State(initialValue: .icon)
            _symbolName = State(initialValue: name)
            _chipText = State(initialValue: "")
        case .text(let text), .character(let text):
            _labelMode = State(initialValue: .text)
            _symbolName = State(initialValue: "arrow.clockwise")
            _chipText = State(initialValue: text)
        case .none:
            _labelMode = State(initialValue: .icon)
            _symbolName = State(initialValue: "arrow.clockwise")
            _chipText = State(initialValue: "")
        }

        // Round-trip the token array back into an editable string. Anything
        // that isn't a trailing return is shown literally; richer sequences
        // keep their tokens and are edited as text.
        var tokens = shortcut.tokens
        var endsWithReturn = false
        if case .returnKey = tokens.last {
            endsWithReturn = true
            tokens.removeLast()
        }
        _trailingReturn = State(initialValue: endsWithReturn)
        _bodyText = State(initialValue: tokens.map(\.displayLabel).joined())

        switch shortcut.scope {
        case .everywhere:
            _scopeKind = State(initialValue: .everywhere)
            _processMatch = State(initialValue: "")
            _selectedHosts = State(initialValue: [])
        case .hosts(let ids):
            _scopeKind = State(initialValue: .hosts)
            _processMatch = State(initialValue: "")
            _selectedHosts = State(initialValue: Set(ids))
        case .process(let match):
            _scopeKind = State(initialValue: .process)
            _processMatch = State(initialValue: match)
            _selectedHosts = State(initialValue: [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(T.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    triggerSection
                    actionSection
                    scopeSection
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
            }
        }
        .background(T.presentationBg.ignoresSafeArea())
        .sheet(isPresented: $recording) {
            ChordRecorderSheet(target: .custom(draft.id)) { binding in
                draft.binding = binding
                wantsChord = binding != nil
            }
            .environment(store)
            .environment(appearance)
            .environment(\.designTokens, T)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            Text("custom shortcut")
                .font(Typography.sheetTitle)
                .foregroundStyle(T.fg)
            Spacer(minLength: 0)
            Button("cancel") { dismiss() }
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgDim)
                .buttonStyle(.plain)
            Button { save() } label: {
                Text("save")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(canSave ? T.accent : T.fgFaint)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(canSave ? T.accentSoft : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier("save-custom-shortcut")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(T.panelBg)
    }

    // MARK: name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("name")
            TextField("tail the deploy log", text: $draft.name)
                .font(Typography.tesseraMono(size: 12.5))
                .textFieldStyle(.plain)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
                .accessibilityIdentifier("custom-shortcut-name")
            // Not decoration: an icon chip carries no readable text, so this is
            // what VoiceOver announces for it.
            caption("also the VoiceOver label for its chip.")
        }
    }

    // MARK: trigger

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("trigger")

            Toggle(isOn: $wantsChord) {
                HStack(spacing: 10) {
                    Text("keyboard shortcut")
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(T.fg)
                    if let binding = draft.binding {
                        KeycapView(text: binding.rendered(appearance.modifierNotation))
                    }
                    if wantsChord {
                        Button(draft.binding == nil ? "record…" : "change…") { recording = true }
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.accent)
                            .buttonStyle(.plain)
                            .disabled(!HardwareKeyboard.isAttached)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(T.accent)

            if wantsChord && !HardwareKeyboard.isAttached {
                caption("connect a hardware keyboard to record a chord. the chip below works without one.")
            }

            Toggle(isOn: $wantsChip) {
                Text("accessory bar chip")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fg)
            }
            .toggleStyle(.switch)
            .tint(T.accent)

            if wantsChip { chipLabelEditor }

            if !wantsChord && !wantsChip {
                caption("at least one trigger is required — a shortcut with neither can never run.")
                    .foregroundStyle(T.amber)
            }
        }
    }

    private var chipLabelEditor: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 14) {
                Text("chip label")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)

                Picker("", selection: $labelMode) {
                    Text("icon").tag(LabelMode.icon)
                    Text("text").tag(LabelMode.text)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer(minLength: 0)

                Text("ON THE BAR")
                    .font(Typography.tesseraMono(size: 9))
                    .tracking(0.8)
                    .foregroundStyle(T.fgFaint)
                ChipBadge(item: .custom(previewShortcut))
            }

            if labelMode == .icon {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 9),
                    spacing: 6
                ) {
                    ForEach(Self.curatedSymbols, id: \.self) { name in
                        Button { symbolName = name } label: {
                            Image(systemName: name)
                                .font(.system(size: 14))
                                .foregroundStyle(symbolName == name ? T.accent : T.fg)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(symbolName == name ? T.accentSoft : T.inputBgSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(symbolName == name ? T.accent : T.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                    }
                }
                caption("monochrome SF Symbols — they tint with the theme, which is what keeps the bar reading as chrome. want an emoji instead? switch to text and type one.")
            } else {
                HStack(spacing: 11) {
                    TextField(chipSample, text: $chipText)
                        .font(Typography.tesseraMono(size: 12))
                        .textFieldStyle(.plain)
                        .frame(width: 130)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 11)
                        .background(T.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.border, lineWidth: 1))
                    Text("6 characters fit at 44pt · an emoji counts as one")
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgDim)
                }
                caption("falls back to the first 6 characters of the name if left empty.")
            }
        }
        .padding(12)
        .background(T.inputBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.border, lineWidth: 1))
    }

    // MARK: action

    // Sample values, not prose: a chip glyph, a shell command, a process
    // name. They must read the same in every language, so they go through
    // `TextField`'s StringProtocol overload instead of being extracted.
    private let chipSample = "deploy"
    private let bodySample = "tail -f /var/log/deploy.log"
    private let processSample = "claude"

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("sends")

            TextField(bodySample, text: $bodyText, axis: .vertical)
                .font(Typography.tesseraMono(size: 12.5))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
                .accessibilityIdentifier("custom-shortcut-body")

            caption("typed literally, spaces included.")

            Toggle(isOn: $trailingReturn) {
                Text("press return afterwards")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fg)
            }
            .toggleStyle(.switch)
            .tint(T.accent)

            if trailingReturn && !bodyText.isEmpty {
                caption("runs immediately when triggered.")
                    .foregroundStyle(T.amber)
            }

            byteReadout
        }
    }

    /// Shows exactly what goes on the wire. Cheap to render and it makes the
    /// literal-text promise checkable instead of a claim.
    private var byteReadout: some View {
        let bytes = currentTokens.encoded(applicationCursor: false)
        return VStack(alignment: .leading, spacing: 4) {
            Text(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.green)
                .lineLimit(3)
            Text("\(bytes.count) bytes")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.green.opacity(0.28), lineWidth: 1))
    }

    // MARK: scope

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("where it applies")

            Picker("", selection: $scopeKind) {
                ForEach(ScopeKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            caption(resolved: scopeKind.caption)

            switch scopeKind {
            case .everywhere:
                EmptyView()
            case .hosts:
                hostPicker
            case .process:
                VStack(alignment: .leading, spacing: 6) {
                    TextField(processSample, text: $processMatch)
                        .font(Typography.tesseraMono(size: 12.5))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(T.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
                    caption("literal process name, or a `regex:` prefix — the same matcher swipe-pad profiles use, so an \"approve\" shortcut exists only while an agent is in the foreground.")
                }
            }
        }
    }

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hosts, id: \.id) { host in
                Button {
                    if selectedHosts.contains(host.id) {
                        selectedHosts.remove(host.id)
                    } else {
                        selectedHosts.insert(host.id)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedHosts.contains(host.id) ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(selectedHosts.contains(host.id) ? T.accent : T.fgDim)
                        Text(host.name)
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.fg)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
            }
            if hosts.isEmpty {
                caption("no saved hosts yet.").padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
    }

    // MARK: derived state

    private var currentTokens: [ShortcutToken] {
        var tokens: [ShortcutToken] = []
        if !bodyText.isEmpty { tokens.append(.text(bodyText)) }
        if trailingReturn { tokens.append(.returnKey) }
        return tokens
    }

    private var resolvedChipLabel: ChipLabelKind? {
        guard wantsChip else { return nil }
        switch labelMode {
        case .icon:
            return .symbol(symbolName)
        case .text:
            let text = chipText.isEmpty ? String(draft.name.prefix(6)) : chipText
            // A single non-ASCII character is an emoji or symbol the user
            // typed; keep the distinction so the bar can size it right.
            return text.count == 1 ? .character(text) : .text(text)
        }
    }

    /// A live stand-in so the badge previews unsaved edits.
    private var previewShortcut: CustomShortcut {
        var copy = draft
        copy.chipLabel = resolvedChipLabel
        return copy
    }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !currentTokens.isEmpty else { return false }
        guard wantsChord || wantsChip else { return false }
        if wantsChord && draft.binding == nil { return false }
        if scopeKind == .process && processMatch.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if scopeKind == .hosts && selectedHosts.isEmpty { return false }
        return true
    }

    private func save() {
        var shortcut = draft
        shortcut.tokens = currentTokens
        shortcut.chipLabel = resolvedChipLabel
        shortcut.binding = wantsChord ? draft.binding : nil
        switch scopeKind {
        case .everywhere: shortcut.scope = .everywhere
        case .hosts:      shortcut.scope = .hosts(Array(selectedHosts))
        case .process:    shortcut.scope = .process(processMatch)
        }
        store.upsert(shortcut)
        syncBarPlacement(for: shortcut)
        dismiss()
    }

    /// "accessory bar chip" is a promise about the bar, so saving has to move
    /// `accessoryBarKeys` with it. Storing the label alone left a chip-only
    /// shortcut unreachable — no chord to press, and nothing ever placed it —
    /// while the editor showed an ON THE BAR preview of a chip that wasn't.
    ///
    /// Placement stays a separate fact from the label: removing a chip from
    /// the preview bar doesn't erase how it renders, and Settings → Keyboard
    /// lists every custom shortcut so it can be put back.
    private func syncBarPlacement(for shortcut: CustomShortcut) {
        appearance.accessoryBarKeys = AccessoryBarPlacement.apply(
            wantsChip: wantsChip,
            chipRawID: shortcut.chipRawID,
            to: appearance.accessoryBarKeys
        )
    }

    // MARK: bits

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgMuted)
    }

    /// Markdown-capable caption. `LocalizedStringKey` both extracts the
    /// literal and keeps the `**bold**` rendering the old `.init(text)` gave.
    private func caption(_ text: LocalizedStringKey) -> Text {
        captionText(Text(text))
    }

    /// The scope picker's caption arrives already resolved from its enum.
    private func caption(resolved text: String) -> Text {
        captionText(Text(verbatim: text))
    }

    private func captionText(_ text: Text) -> Text {
        text
            .font(Typography.tesseraMono(size: 10.5))
            .foregroundStyle(T.fgDim)
    }
}
