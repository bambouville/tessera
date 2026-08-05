// Tessera/Settings/ExperimentalSettingsView.swift
// Experimental swipe-pad settings: gesture guide, profiles, and voice input.
import SwiftUI
import UserNotifications
import UIKit

struct ExperimentalSettingsView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(BellController.self) private var bellController
    @Environment(\.designTokens) private var T

    @Bindable var store: SwipePadProfileStore

    @State private var expandedProfileIDs: Set<UUID> = [SwipePadProfile.builtInClaudeCodeID]
    @State private var editor: MacroEditorDraft?
    @State private var showNotificationDenialSheet = false

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("experimental")

            warningRow
                .padding(.bottom, 22)

            ToggleRow(
                title: "agent center",
                subtitle: "discover Claude and Codex sessions · precise status requires an optional host hook · off by default · disabling does not uninstall host hooks",
                isOn: $appearance.agentCenterEnabled
            )
            .onChange(of: appearance.agentCenterEnabled) { _, enabled in
                guard enabled, appearance.agentCenterNotificationsEnabled else { return }
                requestAgentNotificationPermission()
            }
            .padding(.bottom, 22)

            ToggleRow(
                title: "agent attention notifications",
                subtitle: "iOS notification when an off-screen agent finishes or needs input while Tessera is running in the background · iPadOS may suspend longer sessions",
                isOn: $appearance.agentCenterNotificationsEnabled
            )
            .disabled(!appearance.agentCenterEnabled)
            .onChange(of: appearance.agentCenterNotificationsEnabled) { _, enabled in
                if enabled {
                    requestAgentNotificationPermission()
                } else {
                    bellController.cancelAgentNotifications()
                }
            }

            Text(agentNotificationCoordinationText)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(
                    appearance.bellNotificationEnabled ? T.amber : T.fgDim
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, 22)

            ToggleRow(
                title: "swipe pad",
                subtitle: "floating thumb-zone puck · 3 discrete gestures · radial macros + on-device dictation",
                isOn: $appearance.swipePadEnabled
            )
            .padding(.bottom, 22)

            Field(label: "gestures") {
                GestureVocabularyCard()
            }

            Field(
                label: "default corner",
                sub: "the puck remembers its last position per-orientation. this is just the cold-launch fallback."
            ) {
                SegmentedStringPicker(
                    options: [
                        ("topLeft", "topLeft"),
                        ("topRight", "topRight"),
                        ("bottomLeft", "bottomLeft"),
                        ("bottomRight", "bottomRight")
                    ],
                    selection: $appearance.swipePadCorner,
                    columns: UIDevice.current.userInterfaceIdiom == .phone ? 2 : nil
                )
            }

            Field(label: "puck size") {
                SegmentedStringPicker(
                    options: UIDevice.current.userInterfaceIdiom == .phone
                        ? [
                            ("compact", "compact · 44pt"),
                            ("standard", "standard · 52pt")
                        ]
                        : [
                            ("compact", "compact · 44pt"),
                            ("standard", "standard · 52pt"),
                            ("large", "large · 64pt")
                        ],
                    selection: $appearance.swipePadSize
                )
            }

            Field(label: "active profile · auto-detected") {
                ActiveProfileCard(profile: store.profiles.first)
            }

            Field(label: "profiles · evaluated top-to-bottom · first match wins") {
                ProfileListCard(
                    profiles: store.profiles,
                    expandedProfileIDs: $expandedProfileIDs,
                    editor: $editor,
                    onUpdateProfile: store.upsert
                )

                addProfileButton
                    .padding(.top, 14)
            }

            SettingsH("voice input")
                .padding(.top, 10)

            Text("triggered by double tap on the puck. independent of the radial — no swipe required.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .lineSpacing(2)
                .padding(.bottom, 14)

            ToggleRow(
                title: "on-device dictation",
                subtitle: dictationSubtitle,
                isOn: dictationBinding
            )
            .disabled(!isOnDeviceDictationAvailable)
            .padding(.bottom, 12)

            ToggleRow(
                title: "commit on silence",
                subtitle: "auto-send after 1.2s of silence · otherwise double-tap again to send",
                isOn: $appearance.voiceCommitOnSilence
            )
            .padding(.bottom, 12)

            ToggleRow(
                title: "append return",
                subtitle: "send a ↵ after the transcript hits the terminal",
                isOn: $appearance.voiceAppendReturn
            )
            .padding(.bottom, 12)

            ToggleRow(
                title: "live waveform on the puck",
                subtitle: "the puck morphs into a mic+waveform glyph while listening",
                isOn: $appearance.voiceWaveformOnPuck
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editor) { draft in
            MacroEditorSheet(
                draft: draft,
                onCancel: { editor = nil },
                onSave: { macro in
                    save(macro: macro, for: draft)
                    editor = nil
                }
            )
        }
        .sheet(isPresented: $showNotificationDenialSheet) {
            NotificationPermissionDenialSheet(
                detail: "Tessera can't notify you when an off-screen agent finishes or needs input while the app is backgrounded. Turn notifications on in Settings, then come back."
            )
        }
        .task {
            guard appearance.agentCenterEnabled,
                  appearance.agentCenterNotificationsEnabled else { return }
            let status = await bellController.requestPermissionIfNeeded()
            if status == .denied { showNotificationDenialSheet = true }
        }
    }

    private var agentNotificationCoordinationText: String {
        if appearance.bellNotificationEnabled {
            return "Terminal-bell background notifications are also enabled by your override. They can duplicate alerts and are less precise because any program can ring BEL. Without a notification server, completions after iPadOS suspends Tessera are recovered when you return."
        }
        return "Enabling precise agent alerts automatically turns off terminal-bell background notifications once. You can override that later under Terminal. Without a notification server, completions after iPadOS suspends Tessera are recovered when you return."
    }

    private func requestAgentNotificationPermission() {
        Task {
            let status = await bellController.requestPermissionIfNeeded()
            if status == .denied { showNotificationDenialSheet = true }
        }
    }

    private var warningRow: some View {
        let amber = Color(red: 1.0, green: 0.62, blue: 0.04)

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("HEADS UP")
                .font(Typography.tesseraMono(size: 9, weight: .semibold))
                .foregroundStyle(amber)
                .tracking(0.6)
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(amber.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text("features in this section are under active design — keybindings, defaults, and storage layouts may change between releases.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addProfileButton: some View {
        Button {
            let profile = SwipePadProfile(
                id: UUID(),
                name: "new profile",
                matchProcess: "",
                bindings: [:],
                isBuiltIn: false
            )
            store.upsert(profile)
            expandedProfileIDs.insert(profile.id)
        } label: {
            Text("+ add profile")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(T.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
        }
        .buttonStyle(.plain)
    }

    private var isOnDeviceDictationAvailable: Bool {
        SpeechDictationController.isOnDeviceAvailable
    }

    private var dictationSubtitle: String {
        if isOnDeviceDictationAvailable {
            return "SFSpeechRecognizer · no audio leaves the device · english"
        }
        return "not available for your language on this device"
    }

    private var dictationBinding: Binding<Bool> {
        // Persisted in AppearancePreferences and consulted by SwipePadView's
        // double-tap handler. Availability only gates the displayed value, so
        // a transient recognizer outage doesn't overwrite the stored choice.
        Binding(
            get: { isOnDeviceDictationAvailable && appearance.voiceDictationEnabled },
            set: { appearance.voiceDictationEnabled = $0 }
        )
    }

    private func save(macro: String, for draft: MacroEditorDraft) {
        guard let idx = store.profiles.firstIndex(where: { $0.id == draft.profileID }) else { return }
        var profile = store.profiles[idx]
        if macro.isEmpty {
            profile.bindings.removeValue(forKey: draft.direction)
        } else {
            profile.bindings[draft.direction] = SwipePadBinding(macro: macro)
        }
        store.upsert(profile)
    }
}

// MARK: - Gesture vocabulary

private struct GestureVocabularyCard: View {
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(spacing: 0) {
            GestureVocabularyRow(
                glyph: "↗",
                title: "tap, hold & drag",
                subtitle: "opens the radial · drag to a direction and release to fire that macro · release in the dead-zone to cancel",
                tag: "MACRO"
            )
            Divider().background(T.border)
            GestureVocabularyRow(
                glyph: "··",
                title: "double tap",
                subtitle: "starts on-device dictation · puck morphs into a live waveform · tap again or pause to commit",
                tag: "DICTATION"
            )
            Divider().background(T.border)
            GestureVocabularyRow(
                glyph: "⊕",
                title: "long press",
                subtitle: "picks up the puck for relocation · drag to any spot and release · snaps to nearest edge",
                tag: "MOVE"
            )
        }
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        )
    }
}

private struct GestureVocabularyRow: View {
    let glyph: String
    let title: String
    let subtitle: String
    let tag: String

    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(glyph)
                .font(Typography.tesseraMono(size: glyph == "··" ? 11 : 13, weight: .semibold))
                .foregroundStyle(T.accent)
                .frame(width: 28, height: 28)
                .background(T.accentSoft)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(T.fg)
                Text(subtitle)
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(tag)
                .font(Typography.tesseraMono(size: 10, weight: .medium))
                .foregroundStyle(T.accent)
                .tracking(0.5)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }
}

// MARK: - Segmented string picker

private struct SegmentedStringPicker: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var columns: Int? = nil

    @Environment(\.designTokens) private var T

    var body: some View {
        segments
            .padding(3)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(T.border, lineWidth: 1)
            )
    }

    /// With `columns`, options lay out row-major — pass corner options in
    /// reading order and the grid becomes a spatial map of the corners.
    @ViewBuilder private var segments: some View {
        if let columns, options.count > columns {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(options[start..<min(start + columns, options.count)], id: \.value) { option in
                            segment(option.label, value: option.value)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    segment(option.label, value: option.value)
                }
            }
        }
    }

    private func segment(_ label: String, value: String) -> some View {
        let active = selection == value
        return Button {
            selection = value
        } label: {
            Text(label)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(active ? T.accent : T.fgMuted)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(active ? T.accentSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Active profile

private struct ActiveProfileCard: View {
    let profile: SwipePadProfile?

    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("detected from foreground process · resolved at puck-touch time")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                Text(profileText)
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(T.fg)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Circle()
                    .fill(T.green)
                    .frame(width: 6, height: 6)
                Text("matching")
                    .font(Typography.tesseraMono(size: 11, weight: .medium))
            }
            .foregroundStyle(T.green)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(T.green.opacity(0.16))
            .clipShape(Capsule())
        }
        .padding(14)
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private var profileText: String {
        guard let profile = profile else { return "no profiles configured" }
        if profile.matchProcess.isEmpty { return "\(profile.name) · fallback" }
        return "\(profile.name) · process == \(profile.matchProcess)"
    }
}

// MARK: - Profiles

private struct ProfileListCard: View {
    let profiles: [SwipePadProfile]
    @Binding var expandedProfileIDs: Set<UUID>
    @Binding var editor: MacroEditorDraft?
    let onUpdateProfile: (SwipePadProfile) -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(spacing: 0) {
            ForEach(profiles) { profile in
                ProfileRow(
                    profile: profile,
                    isExpanded: expandedProfileIDs.contains(profile.id),
                    onToggle: { toggle(profile.id) },
                    onEdit: { direction in
                        editor = MacroEditorDraft(profile: profile, direction: direction)
                    },
                    onUpdate: onUpdateProfile
                )

                if profile.id != profiles.last?.id {
                    Divider().background(T.border)
                }
            }
        }
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func toggle(_ id: UUID) {
        if expandedProfileIDs.contains(id) {
            expandedProfileIDs.remove(id)
        } else {
            expandedProfileIDs.insert(id)
        }
    }
}

private struct ProfileRow: View {
    let profile: SwipePadProfile
    let isExpanded: Bool
    let onToggle: () -> Void
    let onEdit: (SwipeDirection) -> Void
    let onUpdate: (SwipePadProfile) -> Void

    @Environment(\.designTokens) private var T

    /// Phone cells (~176pt in two columns) can't hold icon + role name +
    /// key badge without mid-word breaks — and role/macro names are
    /// user-defined, so no copy fix holds. Full-width rows on phone.
    private let columns = UIDevice.current.userInterfaceIdiom == .phone
        ? [GridItem(.flexible(), spacing: 1)]
        : [
            GridItem(.flexible(), spacing: 1),
            GridItem(.flexible(), spacing: 1)
        ]

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(Typography.tesseraMono(size: 10, weight: .semibold))
                        .foregroundStyle(isExpanded ? T.accent : T.fgFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(profile.name)
                                .font(Typography.tesseraMono(size: 13, weight: .medium))
                                .foregroundStyle(T.fg)

                            if profile.matchProcess.isEmpty && profile.isBuiltIn {
                                Text("always on")
                                    .font(Typography.tesseraMono(size: 9, weight: .semibold))
                                    .foregroundStyle(T.amber)
                                    .tracking(0.4)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 6)
                                    .background(T.amber.opacity(0.16))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            } else if profile.isBuiltIn {
                                Text("smart default")
                                    .font(Typography.tesseraMono(size: 9, weight: .semibold))
                                    .foregroundStyle(T.accent)
                                    .tracking(0.4)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 6)
                                    .background(T.accentSoft)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }

                        Text(matchText)
                            .font(Typography.tesseraMono(size: 10.5))
                            .foregroundStyle(T.fgDim)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if !profile.isBuiltIn {
                    CustomAgentRuleEditor(profile: profile, onUpdate: onUpdate)
                    Divider().background(T.border)
                }
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(SwipeDirection.allCases, id: \.self) { direction in
                        BindingCell(
                            direction: direction,
                            binding: profile.binding(for: direction),
                            onTap: { onEdit(direction) }
                        )
                    }
                }
                .background(T.border)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(T.border)
                        .frame(height: 1)
                }
            }
        }
        .background(isExpanded ? T.accentSoft.opacity(0.22) : Color.clear)
    }

    private var matchText: String {
        if profile.matchProcess.isEmpty {
            return "catch-all · used whenever no profile above matches the foreground process. all directions unbound by default — bind any to use the puck outside an agent prompt."
        }
        if profile.matchProcess.hasPrefix("regex:") {
            let pattern = String(profile.matchProcess.dropFirst(6))
            return "match: process matches regex /\(pattern)/"
        }
        return "match: process \(profile.matchProcess)"
    }
}

private struct CustomAgentRuleEditor: View {
    let profile: SwipePadProfile
    let onUpdate: (SwipePadProfile) -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("profile + agent detection")
                .font(Typography.tesseraMono(size: 10, weight: .semibold))
                .foregroundStyle(T.fgMuted)

            profileField("name", keyPath: \.name)
            profileField("process or regex:…", keyPath: \.matchProcess)

            Toggle(
                "detect as an agent",
                isOn: Binding(
                    get: { profile.agentDetection != nil },
                    set: setAgentDetectionEnabled
                )
            )
            .font(Typography.tesseraMono(size: 11))
            .tint(T.accent)

            if let rules = profile.agentDetection {
                ruleField(
                    "blocking prompt regexes · one per line",
                    value: rules.blockingPromptPatterns.joined(separator: "\n"),
                    update: { text in
                        updateRules { $0.blockingPromptPatterns = splitPatterns(text) }
                    }
                )
                ruleField(
                    "idle prompt regexes · one per line",
                    value: rules.idlePromptPatterns.joined(separator: "\n"),
                    update: { text in
                        updateRules { $0.idlePromptPatterns = splitPatterns(text) }
                    }
                )
                ruleField(
                    "menu option regex · captures marker, number, label, shortcut",
                    value: rules.menuOptionPattern,
                    update: { text in updateRules { $0.menuOptionPattern = text } }
                )
                HStack(spacing: 8) {
                    compactRuleField(
                        "response · {index}/{shortcut}",
                        value: rules.responseTemplate,
                        update: { text in updateRules { $0.responseTemplate = text } }
                    )
                    compactRuleField(
                        "fallback response",
                        value: rules.fallbackResponseTemplate,
                        update: { text in updateRules { $0.fallbackResponseTemplate = text } }
                    )
                }
                Text("invalid or incomplete rules degrade to “status unavailable”; Agent Center never guesses controls.")
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(T.fgFaint)
            }
        }
        .padding(14)
        .background(T.inputBgSoft)
    }

    private func profileField(
        _ placeholder: String,
        keyPath: WritableKeyPath<SwipePadProfile, String>
    ) -> some View {
        TextField(
            placeholder,
            text: Binding(
                get: { profile[keyPath: keyPath] },
                set: { value in
                    var updated = profile
                    updated[keyPath: keyPath] = value
                    onUpdate(updated)
                }
            )
        )
        .agentRuleFieldStyle(tokens: T)
    }

    private func ruleField(
        _ placeholder: String,
        value: String,
        update: @escaping (String) -> Void
    ) -> some View {
        TextField(placeholder, text: Binding(get: { value }, set: update), axis: .vertical)
            .lineLimit(2...4)
            .agentRuleFieldStyle(tokens: T)
    }

    private func compactRuleField(
        _ placeholder: String,
        value: String,
        update: @escaping (String) -> Void
    ) -> some View {
        TextField(placeholder, text: Binding(get: { value }, set: update))
            .agentRuleFieldStyle(tokens: T)
    }

    private func setAgentDetectionEnabled(_ enabled: Bool) {
        var updated = profile
        updated.agentDetection = enabled ? AgentDetectionRules(
            blockingPromptPatterns: [],
            idlePromptPatterns: [],
            responseTemplate: "{index}↵"
        ) : nil
        onUpdate(updated)
    }

    private func updateRules(_ mutate: (inout AgentDetectionRules) -> Void) {
        guard var rules = profile.agentDetection else { return }
        mutate(&rules)
        var updated = profile
        updated.agentDetection = rules
        onUpdate(updated)
    }

    private func splitPatterns(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private extension View {
    func agentRuleFieldStyle(tokens: DesignTokens) -> some View {
        self
            .font(Typography.tesseraMono(size: 10.5))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tokens.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tokens.border, lineWidth: 1))
    }
}

private struct BindingCell: View {
    let direction: SwipeDirection
    let binding: SwipePadBinding
    let onTap: () -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                Text(direction.arrow)
                    .font(Typography.tesseraMono(size: 14, weight: .medium))
                    .foregroundStyle(binding.isBound ? directionColor : directionColor.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(binding.isBound ? directionColor.opacity(0.16) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                binding.isBound ? directionColor.opacity(0.45) : directionColor.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1, dash: binding.isBound ? [] : [4, 3])
                            )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(binding.isBound ? direction.roleName : "not bound")
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .foregroundStyle(binding.isBound ? T.fg : T.fgMuted)
                    Text(binding.isBound ? "drag \(direction.rawValue)" : "drag \(direction.rawValue) · petal hidden until set")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgFaint)
                        .tracking(0.5)
                }

                Spacer(minLength: 8)

                Text(binding.isBound ? binding.macro : "+ add")
                    .font(Typography.tesseraMono(size: 11, weight: .medium))
                    .foregroundStyle(binding.isBound ? T.fgMuted : T.fgFaint)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(binding.isBound ? T.inputBg : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                binding.isBound ? T.border : T.borderStrong,
                                style: StrokeStyle(lineWidth: 1, dash: binding.isBound ? [] : [4, 3])
                            )
                    )
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.panelBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var directionColor: Color {
        switch direction {
        case .left:  return T.red
        case .right: return T.green
        case .up:    return T.amber
        case .down:  return T.accent
        }
    }
}

private extension SwipeDirection {
    var arrow: String {
        switch self {
        case .left:  return "←"
        case .right: return "→"
        case .up:    return "↑"
        case .down:  return "↓"
        }
    }

    var roleName: String {
        switch self {
        case .left:  return "deny"
        case .right: return "approve"
        case .up:    return "always allow"
        case .down:  return "custom macro"
        }
    }
}

// MARK: - Macro editor

private struct MacroEditorDraft: Identifiable {
    let profileID: UUID
    let profileName: String
    let direction: SwipeDirection
    let macro: String

    init(profile: SwipePadProfile, direction: SwipeDirection) {
        self.profileID = profile.id
        self.profileName = profile.name
        self.direction = direction
        self.macro = profile.binding(for: direction).macro
    }

    var id: String { "\(profileID.uuidString)-\(direction.rawValue)" }
}

private struct MacroEditorSheet: View {
    let draft: MacroEditorDraft
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @Environment(\.designTokens) private var T
    @State private var macro: String

    init(
        draft: MacroEditorDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        self._macro = State(initialValue: draft.macro)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("edit macro")
                .font(Typography.sheetTitle)
                .foregroundStyle(T.fg)

            Text("\(draft.profileName) · drag \(draft.direction.rawValue)")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)

            TextField("macro spec", text: $macro)
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(T.border, lineWidth: 1)
                )

            Text("macro spec: literal chars, ↵ for Enter, esc/\\e/\\x1b for Escape, \\t/tab, \\r, \\n.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    onSave(macro)
                } label: {
                    Text("save")
                        .font(Typography.tesseraMono(size: 13, weight: .medium))
                        .foregroundStyle(T.accent)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(T.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(T.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button("cancel") { onCancel() }
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fgMuted)
                    .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.presentationBg)
    }
}
