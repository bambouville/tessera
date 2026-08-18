// Tessera/Settings/ShortcutsEditorView.swift
// The keymap editor: one table for built-in actions and the user's own
// shortcuts, plus the chord recorder they share.
//
// Presented as a full-screen sheet rather than inline in Settings because the
// settings right pane caps at 560pt — too narrow for an action / binding /
// state table.
import SwiftUI
import SwiftData
import UIKit

// MARK: - Summary card (lives in keyboard & input)

/// Replaces the old read-only `ShortcutLegend`. States what's bound and opens
/// the editor; the full list now lives behind it.
struct ShortcutsSummaryCard: View {
    @Environment(\.designTokens) private var T
    @Environment(ShortcutStore.self) private var store
    @Environment(AppearancePreferences.self) private var appearance

    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("keyboard shortcuts")
                        .font(Typography.tesseraMono(size: 12.5))
                        .foregroundStyle(T.fg)
                    Text("remap any app shortcut · add your own")
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgDim)
                }
                Spacer(minLength: 8)
                Button { editing = true } label: {
                    Text("customize…")
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(T.accent)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(T.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7).stroke(T.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shortcuts-customize")
            }

            Divider().overlay(T.border)

            HStack(spacing: 22) {
                stat("\(ShortcutAction.allCases.count)", "bound", T.fg)
                stat("\(store.changedCount)", "changed", store.changedCount > 0 ? T.accent : T.fgMuted)
                stat("\(store.customShortcuts.count)", "custom",
                     store.customShortcuts.isEmpty ? T.fgMuted : T.green)
                Spacer(minLength: 0)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.border, lineWidth: 1))
        .sheet(isPresented: $editing) {
            ShortcutsEditorView()
                .environment(store)
                .environment(appearance)
                .environment(\.designTokens, T)
        }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(Typography.tesseraMono(size: 17))
                .foregroundStyle(color)
            Text(label)
                .font(Typography.tesseraMono(size: 9))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(T.fgDim)
        }
    }
}

// MARK: - Editor sheet

struct ShortcutsEditorView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(ShortcutStore.self) private var store
    @Environment(AppearancePreferences.self) private var appearance

    @State private var selectedGroup: ShortcutGroup?
    @State private var search = ""
    @State private var recording: RecordTarget?
    @State private var editingCustom: CustomShortcut?
    @State private var confirmRestore = false

    /// What the recorder is currently recording *for* — a built-in action or a
    /// custom shortcut being edited.
    enum RecordTarget: Identifiable {
        case action(ShortcutAction)
        case custom(UUID)
        var id: String {
            switch self {
            case .action(let a): return a.rawValue
            case .custom(let id): return id.uuidString
            }
        }
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(T.border)
            if isPhone {
                phoneBody
            } else {
                padBody
            }
            Divider().overlay(T.border)
            footer
        }
        .background(T.presentationBg.ignoresSafeArea())
        .sheet(item: $recording) { target in
            ChordRecorderSheet(target: target) { binding in
                apply(binding, to: target)
            }
            .environment(store)
            .environment(appearance)
            .environment(\.designTokens, T)
        }
        .sheet(item: $editingCustom) { shortcut in
            CustomShortcutEditorView(shortcut: shortcut)
                .environment(store)
                .environment(appearance)
                .environment(\.designTokens, T)
        }
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 14) {
            Text("shortcuts")
                .font(Typography.sheetTitle)
                .foregroundStyle(T.fg)

            if !isPhone {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(T.fgDim)
                    TextField("filter by name or key…", text: $search)
                        .font(Typography.tesseraMono(size: 12))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 11)
                .frame(maxWidth: 280)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
            }

            Spacer(minLength: 0)

            Button { confirmRestore = true } label: {
                Text("restore all defaults")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(store.changedCount > 0 ? T.fgMuted : T.fgFaint)
            }
            .buttonStyle(.plain)
            .disabled(store.changedCount == 0)

            Button { dismiss() } label: {
                Text("done")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.accent)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(T.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(T.panelBg)
        .confirmationDialog(
            "Restore every shortcut to its default?",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("restore \(store.changedCount) changed", role: .destructive) {
                store.restoreAllDefaults()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("Your custom shortcuts are not affected.")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                editingCustom = CustomShortcut(name: "", tokens: [])
            } label: {
                Text("+ custom shortcut")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.accent)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(T.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.accent, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("add-custom-shortcut")

            Spacer(minLength: 0)

            if !hardwareKeyboardAttached {
                Text("connect a hardware keyboard to record chords")
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.amber)
            } else if store.changedCount > 0 {
                Text("\(store.changedCount) changed from default")
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.fgDim)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(T.panelBg)
    }

    // MARK: bodies

    private var padBody: some View {
        HStack(spacing: 0) {
            rail.frame(width: 172)
            Divider().overlay(T.border)
            table
        }
    }

    private var phoneBody: some View {
        // The phone can't hold a three-column table; the rail becomes a
        // horizontal chip row above the same rows, matching how every other
        // settings section adapts.
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    railButton(nil, label: "all", count: ShortcutAction.allCases.count)
                    ForEach(ShortcutGroup.allCases) { group in
                        railButton(group, resolvedLabel: group.title, count: count(in: group))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Divider().overlay(T.border)
            table
        }
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: 2) {
                railButton(nil, label: "all", count: ShortcutAction.allCases.count)
                ForEach(ShortcutGroup.allCases.filter { $0 != .custom }) { group in
                    railButton(group, resolvedLabel: group.title, count: count(in: group))
                }
                Divider().overlay(T.border).padding(.vertical, 8)
                railButton(.custom, label: "custom", count: store.customShortcuts.count)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
    }

    private func railButton(_ group: ShortcutGroup?, label: LocalizedStringKey, count: Int) -> some View {
        railButton(group, label: Text(label), count: count)
    }

    private func railButton(_ group: ShortcutGroup?, resolvedLabel: String, count: Int) -> some View {
        railButton(group, label: Text(verbatim: resolvedLabel), count: count)
    }

    private func railButton(_ group: ShortcutGroup?, label: Text, count: Int) -> some View {
        let selected = selectedGroup == group
        return Button { selectedGroup = group } label: {
            HStack(spacing: 6) {
                label
                    .font(Typography.tesseraMono(size: 12))
                Spacer(minLength: 4)
                Text(verbatim: "\(count)")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(selected ? T.accent : T.fgFaint)
            }
            .foregroundStyle(selected ? T.accent : T.fgMuted)
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .background(selected ? T.accentSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func count(in group: ShortcutGroup) -> Int {
        group == .custom ? store.customShortcuts.count : ShortcutAction.actions(in: group).count
    }

    // MARK: table

    private var table: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleGroups) { group in
                    groupHeader(group)
                    if group == .custom {
                        ForEach(filteredCustoms) { shortcut in
                            customRow(shortcut)
                        }
                        if filteredCustoms.isEmpty {
                            emptyCustomHint
                        }
                    } else {
                        ForEach(filteredActions(in: group)) { action in
                            actionRow(action)
                        }
                    }
                }
                remoteSection
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleGroups: [ShortcutGroup] {
        if let selectedGroup { return [selectedGroup] }
        return ShortcutGroup.allCases
    }

    private func groupHeader(_ group: ShortcutGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.title.uppercased())
                .font(Typography.tesseraMono(size: 9.5))
                .tracking(0.8)
                .foregroundStyle(T.fgFaint)
            if let note = groupNote(group) {
                Text(note)
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(T.fgDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 7)
    }

    private func groupNote(_ group: ShortcutGroup) -> String? {
        switch group {
        case .tmux:  return String(localized: "— live only while a tmux session is attached")
        case .panes: return String(localized: "— live once a window holds more than one pane")
        case .custom: return String(localized: "— yours")
        default: return nil
        }
    }

    private func filteredActions(in group: ShortcutGroup) -> [ShortcutAction] {
        ShortcutAction.actions(in: group).filter(matchesSearch)
    }

    private var filteredCustoms: [CustomShortcut] {
        guard !search.isEmpty else { return store.customShortcuts }
        return store.customShortcuts.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    private func matchesSearch(_ action: ShortcutAction) -> Bool {
        guard !search.isEmpty else { return true }
        if action.title.localizedCaseInsensitiveContains(search) { return true }
        if let binding = store.binding(for: action) {
            let notation = appearance.modifierNotation
            if binding.rendered(notation).localizedCaseInsensitiveContains(search) { return true }
        }
        return false
    }

    // MARK: rows

    private func actionRow(_ action: ShortcutAction) -> some View {
        let binding = store.binding(for: action)
        let changed = store.isCustomized(action)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(Typography.tesseraMono(size: 12.5))
                    .foregroundStyle(T.fg)
                if let detail = action.detail {
                    Text(detail)
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)

            if let binding {
                if action.isDigitBlock {
                    KeycapView(text: binding.rendered(appearance.modifierNotation))
                    Text(verbatim: "–9")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                } else {
                    KeycapView(text: binding.rendered(appearance.modifierNotation))
                }
            } else {
                KeycapView(text: "unbound", ghost: true)
            }

            Text(changed ? "changed" : "default")
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(changed ? T.accent : T.fgDim)
                .padding(.vertical, 2)
                .padding(.horizontal, 7)
                .overlay(
                    Capsule().stroke(changed ? T.accent.opacity(0.5) : T.borderStrong, lineWidth: 1)
                )

            rowButton("pencil", label: "record \(action.title)") { recording = .action(action) }
            if changed {
                rowButton("arrow.uturn.backward", label: "reset \(action.title)") {
                    store.resetToDefault(action)
                }
            } else if binding != nil {
                rowButton("delete.left", label: "unbind \(action.title)") {
                    store.setBinding(nil, for: action)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
        .accessibilityIdentifier("shortcut-row-\(action.rawValue)")
    }

    private func customRow(_ shortcut: CustomShortcut) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.name.isEmpty ? "untitled" : shortcut.name)
                    .font(Typography.tesseraMono(size: 12.5))
                    .foregroundStyle(T.fg)
                Text(customDetail(shortcut))
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if let binding = shortcut.binding {
                KeycapView(text: binding.rendered(appearance.modifierNotation))
            }
            if shortcut.chipLabel != nil {
                ChipBadge(item: .custom(shortcut))
            }

            Text("custom")
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(T.green)
                .padding(.vertical, 2)
                .padding(.horizontal, 7)
                .overlay(Capsule().stroke(T.green.opacity(0.45), lineWidth: 1))

            rowButton("pencil", label: "edit \(shortcut.name)") { editingCustom = shortcut }
            // Take the chip off the bar with it. A stale `custom:<uuid>` is
            // invisible (the bar drops raw IDs it can't resolve) but it would
            // sit in the user's stored order forever.
            rowButton("trash", label: "delete \(shortcut.name)") {
                appearance.accessoryBarKeys = AccessoryBarPlacement.removing(
                    chipRawID: shortcut.chipRawID,
                    from: appearance.accessoryBarKeys
                )
                store.delete(shortcut)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
    }

    private func customDetail(_ shortcut: CustomShortcut) -> String {
        var parts: [String] = []
        let summary = shortcut.tokens.plainSummary
        if !summary.isEmpty { parts.append(String(localized: "sends \(summary)")) }
        if shortcut.tokens.endsWithReturn { parts.append(String(localized: "runs immediately")) }
        parts.append(shortcut.scope.summary)
        return parts.joined(separator: " · ")
    }

    private var emptyCustomHint: some View {
        Text("nothing yet — a custom shortcut sends text or keys to the remote, from a chord, a bar chip, or both.")
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgDim)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }

    /// Named explicitly rather than left out: these chords are real, users press
    /// them, and "why can't I rebind ⌥←" deserves an answer in the same table.
    @ViewBuilder
    private var remoteSection: some View {
        if selectedGroup == nil && search.isEmpty {
            HStack(spacing: 8) {
                Text("SENT TO THE SHELL")
                    .font(Typography.tesseraMono(size: 9.5))
                    .tracking(0.8)
                    .foregroundStyle(T.fgFaint)
                Text("— not app shortcuts")
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(T.fgDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 7)

            ForEach(Self.remoteRows, id: \.id) { row in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(Typography.tesseraMono(size: 12.5))
                            .foregroundStyle(T.fgMuted)
                        if let note = row.note {
                            Text(note)
                                .font(Typography.tesseraMono(size: 10.5))
                                .foregroundStyle(T.fgDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let display = row.keys {
                        Text(display.rendered(appearance.modifierNotation))
                            .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                            .foregroundStyle(T.fgMuted)
                    }
                    Text("sent to shell")
                        .font(Typography.tesseraMono(size: 9))
                        .foregroundStyle(T.amber)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 7)
                        .overlay(Capsule().stroke(T.amber.opacity(0.45), lineWidth: 1))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
            }
        }
    }

    private struct RemoteRow: Identifiable {
        let label: LocalizedStringResource
        let note: LocalizedStringResource?
        let keys: ChordDisplay?

        /// Keyed on the untranslated literal so row identity is stable
        /// across languages.
        var id: String { String(describing: label.key) }
    }

    private static let remoteRows: [RemoteRow] = [
        RemoteRow(
            label: "previous / next word",
            note: "natural text editing writes these to the remote — the app never sees them",
            keys: .pair(ChordPair(first: Chord([.option], .left), second: Chord([.option], .right)))
        ),
        RemoteRow(label: "start / end of line", note: nil,
                  keys: .pair(ChordPair(first: Chord([.command], .left), second: Chord([.command], .right)))),
        RemoteRow(label: "delete word left", note: nil, keys: .one(Chord([.option], .delete))),
        RemoteRow(
            label: "every bare and ⌃-prefixed key",
            note: "the terminal owns them — that's why app shortcuts must include ⌘",
            keys: nil
        ),
    ]

    private func rowButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(T.fgDim)
                .frame(width: 26, height: 26)
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var hardwareKeyboardAttached: Bool { HardwareKeyboard.isAttached }

    private func apply(_ binding: KeyBinding?, to target: RecordTarget) {
        switch target {
        case .action(let action):
            store.setBinding(binding, for: action)
        case .custom(let id):
            guard var shortcut = store.customShortcuts.first(where: { $0.id == id }) else { return }
            shortcut.binding = binding
            store.upsert(shortcut)
        }
    }
}

// MARK: - Small shared views

struct KeycapView: View {
    /// Key notation — `⌘`, `esc`, `F5`. Never translated.
    let text: String
    var ghost: Bool = false
    @Environment(\.designTokens) private var T

    var body: some View {
        Text(verbatim: text)
            .font(Typography.tesseraMono(size: 11.5, weight: .medium))
            .foregroundStyle(ghost ? T.fgFaint : T.fg)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(ghost ? Color.clear : T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        ghost ? T.border : T.borderStrong,
                        style: StrokeStyle(lineWidth: 1, dash: ghost ? [3, 2] : [])
                    )
            )
    }
}

/// A miniature of how a custom shortcut's chip looks on the bar.
struct ChipBadge: View {
    let item: AccessoryBarItem
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    var body: some View {
        Group {
            switch item.label(appearance.modifierNotation) {
            case .text(let text):
                Text(verbatim: text).font(Typography.tesseraMono(size: 11, weight: .medium))
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundStyle(T.green)
        .frame(minWidth: 30, minHeight: 26)
        .padding(.horizontal, 7)
        .background(T.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.green.opacity(0.45), lineWidth: 1))
    }
}

/// Whether a hardware keyboard is attached right now.
///
/// The gate for chord editing is deliberately this and not the device idiom:
/// an iPad in portrait with no Magic Keyboard has exactly the problem an iPhone
/// does, and an iPhone with one attached has none of it.
enum HardwareKeyboard {
    static var isAttached: Bool {
        GCKeyboardShim.isConnected
    }
}
