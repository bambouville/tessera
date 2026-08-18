// Tessera/Settings/KeyboardSettingsView.swift
// §14.8 — accessory bar editor + modifier behavior + input preferences.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct KeyboardSettingsView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("keyboard & input")

            ToggleRow(
                title: "natural text editing",
                subtitle: "mac-style word, line, and delete shortcuts in shells and terminal apps",
                isOn: $appearance.naturalTextEditingEnabled
            )
            .padding(.bottom, 22)

            ToggleRow(
                title: "show accessory bar",
                subtitle: "row of special keys above the on-screen keyboard",
                isOn: $appearance.showAccessoryBar
            )
            .padding(.bottom, 22)

            ToggleRow(
                title: "resize terminal with keyboard",
                subtitle: "reflow terminal rows when the software keyboard appears or hides",
                isOn: $appearance.resizeTerminalWithKeyboard
            )
            .padding(.bottom, 22)

            Field(label: "accessory bar layout") {
                AccessoryBarEditor()
            }

            Field(
                label: "modifier behavior",
                sub: "one-shot: tap \(KeyToken.control.rendered(appearance.modifierNotation)), then a key — modifier auto-clears after one press · sticky: tap to lock the modifier, tap again to release"
            ) {
                ModifierBehaviorSegmented()
            }

            Field(
                label: "modifier notation",
                sub: "how modifier keys are written everywhere in the app — the accessory bar, the shortcut list, window tabs, and hints"
            ) {
                ModifierNotationSegmented()
            }

            // Was an iPad-only read-only legend. Gated on nothing now: the
            // list is worth reading on iPhone too, and chord *editing* gates on
            // a hardware keyboard being attached rather than on the idiom.
            Field(label: "shortcuts") {
                ShortcutsSummaryCard()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shortcut legend (read-only)

private struct ShortcutLegend: View {
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    private struct Row: Identifiable {
        let keys: ChordDisplay
        let label: LocalizedStringResource
        /// Stable across notation changes, so `ForEach` identity doesn't churn
        /// when the user flips the preference. Keyed on the untranslated
        /// literal so identity is the same in every language.
        var id: String { String(describing: label.key) }
    }

    private struct Group: Identifiable {
        let title: LocalizedStringResource
        let rows: [Row]
        var id: String { String(describing: title.key) }
    }

    // Reference for the primary chords the app registers:
    //   · global ⌘N / ⌘K / ⌘, live on hidden buttons in ContentView
    //   · session ⌘⇧K / ⌘⇧J + the find / settings chords ride
    //     TesseraTerminalContainer's UIKeyCommands (see
    //     SessionSwitcher.swift for why letters, not ⌃Tab or ⌘⌥[ — both
    //     are dropped by iPadOS before the keyCommand can match).
    //     The bare ⌘[ / ⌘] brackets were reassigned to in-window pane
    //     cycling, so session switching moved to the ⌘⇧K / ⌘⇧J letters.
    //   · ⌘↩ connect lives on HostDetailView's regular-width connect button
    //   · the tmux block is only active while a tmux session is attached;
    //     the pane chords (⌘D / ⌘[ / ⌘] / ⇧⌘↩) only do anything once a
    //     window holds more than one pane
    private var groups: [Group] {
        [
            Group(title: "global", rows: [
                Row(keys: .one(.cmd("n")), label: "new host"),
                Row(keys: .one(.cmd("k")), label: "quick-switch palette"),
                Row(keys: .one(Chord([.command], .character(","))), label: "settings"),
                Row(keys: .one(.cmdShift("a")), label: "toggle agent center"),
            ]),
            Group(title: "sessions", rows: [
                Row(keys: .pair(ChordPair(first: .cmdShift("k"), second: .cmdShift("j"))),
                    label: "previous / next session"),
                Row(keys: .one(.cmdShift("e")), label: "toggle files panel"),
                Row(keys: .one(.cmd("r")), label: "refresh terminal"),
                Row(keys: .one(Chord([.command], .return)), label: "connect (host editor)"),
            ]),
            Group(title: "find in scrollback", rows: [
                Row(keys: .one(.cmd("f")), label: "open find bar"),
                Row(keys: .pair(ChordPair(first: .cmd("g"), second: .cmdShift("g"))),
                    label: "next / previous match"),
                Row(keys: .pair(ChordPair(first: Chord([], .return),
                                          second: Chord([.shift], .return))),
                    label: "next / previous match (while searching)"),
                Row(keys: .one(Chord([], .escape)), label: "close find bar"),
            ]),
            Group(title: "text editing", rows: [
                Row(keys: .pair(ChordPair(first: Chord([.option], .left),
                                          second: Chord([.option], .right))),
                    label: "previous / next word"),
                Row(keys: .pair(ChordPair(first: Chord([.command], .left),
                                          second: Chord([.command], .right))),
                    label: "start / end of line"),
                Row(keys: .one(Chord([.option], .delete)), label: "delete word left"),
                Row(keys: .one(Chord([.command], .delete)), label: "delete to start of line"),
            ]),
            Group(title: "tmux", rows: [
                Row(keys: .one(.cmd("t")), label: "new window"),
                Row(keys: .one(.cmdShift("w")), label: "close pane / window"),
                Row(keys: .pair(ChordPair(first: .cmdShift("["), second: .cmdShift("]"))),
                    label: "previous / next window"),
                Row(keys: .range(ChordRange(modifiers: [.command], from: "1", to: "9")),
                    label: "jump to window 1–9"),
            ]),
            Group(title: "panes", rows: [
                Row(keys: .pair(ChordPair(first: .cmd("d"), second: .cmdShift("d"))),
                    label: "split side-by-side / stacked"),
                Row(keys: .pair(ChordPair(first: .cmd("["), second: .cmd("]"))),
                    label: "previous / next pane"),
                Row(keys: .one(Chord([.command, .shift], .return)), label: "zoom pane"),
            ]),
        ]
    }

    /// The key column has to fit the widest row. Words mode needs half again as
    /// much room ("cmd-shift-k / cmd-shift-j"), so derive it rather than adding
    /// a second magic number.
    private var keyColumnWidth: CGFloat {
        appearance.modifierNotation == .words ? 168 : 116
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(Typography.kicker)
                        .foregroundStyle(T.fgDim)
                        .tracking(0.6)
                        // Locale-aware uppercasing, unlike `.uppercased()`.
                        .textCase(.uppercase)
                        .padding(.bottom, 6)

                    ForEach(group.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: row.keys.rendered(appearance.modifierNotation))
                                .font(Typography.tesseraMono(size: 12, weight: .medium))
                                .foregroundStyle(T.fg)
                                .frame(minWidth: keyColumnWidth, alignment: .leading)
                            Text(row.label)
                                .font(Typography.tesseraMono(size: 12))
                                .foregroundStyle(T.fgMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            if row.id != group.rows.last?.id {
                                Rectangle().fill(T.border).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        )
    }
}

// MARK: - Accessory bar editor (preview + palette + restore-defaults)

private struct AccessoryBarEditor: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(ShortcutStore.self) private var shortcutStore
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewCard
            paletteCard
            HStack(spacing: 10) {
                Button {
                    appearance.accessoryBarKeys = AccessoryChip.defaultBarOrder.map(\.rawValue)
                } label: {
                    Text("restore defaults")
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(T.fgMuted)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(T.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(T.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text("tap a palette chip to add · tap a preview chip to remove · long-press a preview chip to drag-reorder · dimmed palette entries are already on the bar\nshortcuts you write appear under YOUR SHORTCUTS — add one from keyboard shortcuts above\n⌘ is different from the other modifiers: it runs a Tessera shortcut instead of sending anything to the remote, so app shortcuts work without a hardware keyboard")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: preview

    private var previewCard: some View {
        @Bindable var appearance = appearance
        return VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW")
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(T.fgFaint)
                .tracking(1)
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                DraggableChipBar(
                    keys: $appearance.accessoryBarKeys,
                    trashEnabled: false,
                    trashColor: T.red,
                    onTap: { item in
                        appearance.accessoryBarKeys.removeAll { $0 == item.rawID }
                    },
                    resolve: { raw in
                        AccessoryBarItem.resolve(raw) { shortcutStore.customShortcut(withChipRawID: $0) }
                    }
                ) { item, lifted in
                    ChipLabel(item: item, style: lifted ? .lifted : .preview, accent: T.accent, dim: false)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("accessory-bar-preview")
            .overlay(alignment: .trailing) {
                AccessoryBarOverflowFade(background: T.panelBg)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        )
    }

    // MARK: palette

    private var paletteCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Yours first: it's the section a user goes looking for, and the
            // only one whose contents they authored.
            if !customItems.isEmpty {
                paletteSection("your shortcuts", items: customItems)
            }
            paletteSection("navigation", chips: navChips)
            paletteSection("modifiers", chips: modifierChips)
            paletteSection("control shortcuts", chips: controlChips)
            paletteSection("function keys", chips: fkeyChips)
            paletteSection("symbols", chips: symbolChips)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func paletteSection(_ title: LocalizedStringKey, chips: [AccessoryChip]) -> some View {
        paletteSection(title, items: chips.map(AccessoryBarItem.chip))
    }

    private func paletteSection(_ title: LocalizedStringKey, items: [AccessoryBarItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(T.fgFaint)
                .tracking(1)
                .textCase(.uppercase)

            FlowChipRow(items: items, current: Set(appearance.accessoryBarKeys), accent: T.accent) { item in
                add(item)
            }
        }
    }

    private func add(_ item: AccessoryBarItem) {
        let raw = item.rawID
        if !appearance.accessoryBarKeys.contains(raw) {
            appearance.accessoryBarKeys.append(raw)
        }
    }

    /// Every custom shortcut is offered, not only the ones saved with a chip
    /// label. One without a label still renders — `AccessoryBarItem` falls back
    /// to the shortcut's name — and refusing to list it would leave a user who
    /// built a chord-only shortcut with no way to also put it on the bar.
    private var customItems: [AccessoryBarItem] {
        shortcutStore.customShortcuts.map(AccessoryBarItem.custom)
    }

    // Chip catalogs by category. Single source of truth lives in
    // AccessoryChip; here we just group for the palette UI.
    private let navChips: [AccessoryChip] = [.esc, .tab, .left, .down, .up, .right, .home, .end, .pgup, .pgdn]
    private let modifierChips: [AccessoryChip] = [.ctrl, .alt, .shift, .cmd]
    private let controlChips: [AccessoryChip] = [.ctrlC, .ctrlJ]
    private let fkeyChips: [AccessoryChip] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
    private let symbolChips: [AccessoryChip] = [.pipe, .tilde, .slash, .backslash, .dollar, .lbrace, .rbrace, .lbracket, .rbracket, .lt, .gt]
}

// MARK: - Chip label (used by preview, palette, and drag preview)

private enum ChipStyle {
    case preview    // chip in the live preview bar
    case palette    // chip in the palette (tap to add)
    case lifted     // chip in flight during drag
}

private struct ChipLabel: View {
    let item: AccessoryBarItem
    let style: ChipStyle
    let accent: Color
    let dim: Bool

    init(chip: AccessoryChip, style: ChipStyle, accent: Color, dim: Bool) {
        self.init(item: .chip(chip), style: style, accent: accent, dim: dim)
    }

    init(item: AccessoryBarItem, style: ChipStyle, accent: Color, dim: Bool) {
        self.item = item
        self.style = style
        self.accent = accent
        self.dim = dim
    }

    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    private var resolvedLabel: AccessoryBarItemLabel { item.label(appearance.modifierNotation) }

    var body: some View {
        labelView
            .font(Typography.tesseraMono(size: chipFontSize, weight: .medium))
            .foregroundStyle(foreground)
            .frame(minWidth: 36, minHeight: 30)
            .padding(.horizontal, 10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(border, lineWidth: 1)
            )
            .opacity(dim ? 0.35 : 1)
            .shadow(color: style == .lifted ? Color.black.opacity(0.4) : .clear, radius: 8, x: 0, y: 4)
            .scaleEffect(style == .lifted ? 1.06 : 1)
    }

    @ViewBuilder
    private var labelView: some View {
        switch resolvedLabel {
        case .text(let text):
            Text(text)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
        }
    }

    private var chipFontSize: CGFloat {
        resolvedLabel.isLong ? 11 : 13
    }

    private var foreground: Color {
        switch style {
        case .preview, .palette:
            return T.fg
        case .lifted:
            return accent
        }
    }

    private var background: Color {
        switch style {
        case .preview:
            return T.inputBg
        case .palette:
            return T.inputBgSoft
        case .lifted:
            return accent.opacity(0.20)
        }
    }

    private var border: Color {
        switch style {
        case .preview, .palette:
            return T.border
        case .lifted:
            return accent
        }
    }
}

// MARK: - Palette flow row (taps add chip)

private struct FlowChipRow: View {
    let items: [AccessoryBarItem]
    let current: Set<String>
    let accent: Color
    let onTap: (AccessoryBarItem) -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        HFlow(spacing: 6, runSpacing: 6) {
            ForEach(items) { item in
                let isCurrent = current.contains(item.rawID)
                Button {
                    if !isCurrent { onTap(item) }
                } label: {
                    ChipLabel(item: item, style: .palette, accent: accent, dim: isCurrent)
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
                .accessibilityLabel(item.accessibilityLabel)
            }
        }
    }
}

/// Minimal flow layout: lays children left-to-right, wraps to a new line
/// when content runs out of width. Avoids pulling in iOS 16's `Layout`
/// machinery for a 30-line need.
private struct HFlow: Layout {
    var spacing: CGFloat = 6
    var runSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: width)
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + (acc == 0 ? 0 : runSpacing) + row.height
        }
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(usedWidth, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        let rows = computeRows(subviews: subviews, maxWidth: width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + runSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let lastIdx = rows.count - 1
            let projected = rows[lastIdx].width + (rows[lastIdx].indices.isEmpty ? 0 : spacing) + size.width
            if projected > maxWidth, !rows[lastIdx].indices.isEmpty {
                rows.append(Row())
            }
            let i = rows.count - 1
            rows[i].indices.append(index)
            rows[i].width += (rows[i].indices.count == 1 ? 0 : spacing) + size.width
            rows[i].height = max(rows[i].height, size.height)
        }
        return rows
    }
}

// MARK: - Modifier behavior segmented control

private struct ModifierBehaviorSegmented: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T

    var body: some View {
        @Bindable var appearance = appearance

        HStack(spacing: 2) {
            segment("one-shot", value: "oneShot", binding: $appearance.modifierBehavior)
            segment("sticky", value: "sticky", binding: $appearance.modifierBehavior)
        }
        .padding(3)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(T.border, lineWidth: 1)
        )
        .fixedSize()
    }

    private func segment(_ label: LocalizedStringKey, value: String, binding: Binding<String>) -> some View {
        let active = binding.wrappedValue == value
        return Button {
            binding.wrappedValue = value
        } label: {
            Text(label)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(active ? T.accent : T.fgMuted)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(active ? T.accentSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Modifier notation segmented control

/// Glyphs (⌘⇧E) vs words (cmd-shift-e). Sits directly under modifier behavior —
/// the two are the pair of "how modifiers work / how they're written" controls.
private struct ModifierNotationSegmented: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(ModifierNotation.allCases) { notation in
                    segment(notation, binding: $appearance.modifierNotation)
                }
            }
            .padding(3)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(T.border, lineWidth: 1)
            )
            .fixedSize()

            // A live sample beats describing the difference in prose.
            HStack(spacing: 8) {
                ForEach(sampleChords, id: \.self) { rendered in
                    Text(rendered)
                        .font(Typography.tesseraMono(size: 11, weight: .medium))
                        .foregroundStyle(T.fg)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(T.inputBgSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(T.border, lineWidth: 1)
                        )
                }
            }
            .accessibilityIdentifier("modifier-notation-preview")
        }
    }

    private var sampleChords: [String] {
        let n = appearance.modifierNotation
        return [
            Chord.cmd("n").rendered(n),
            Chord.cmdShift("e").rendered(n),
            Chord([.option], .left).rendered(n),
            Chord([.command], .return).rendered(n),
        ]
    }

    private func segment(
        _ notation: ModifierNotation,
        binding: Binding<ModifierNotation>
    ) -> some View {
        let active = binding.wrappedValue == notation
        return Button {
            binding.wrappedValue = notation
        } label: {
            Text(notation.label)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(active ? T.accent : T.fgMuted)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(active ? T.accentSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("modifier-notation-\(notation.rawValue)")
    }
}
