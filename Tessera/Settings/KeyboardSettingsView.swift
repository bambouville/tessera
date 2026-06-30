// Tessera/Settings/KeyboardSettingsView.swift
// §14.8 — accessory bar editor + modifier behavior + caps-lock-as-ctrl.
import SwiftUI
import UniformTypeIdentifiers

struct KeyboardSettingsView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.designTokens) private var T

    var body: some View {
        @Bindable var appearance = appearance

        VStack(alignment: .leading, spacing: 0) {
            SettingsH("keyboard")

            ToggleRow(
                title: "show accessory bar",
                subtitle: "row of special keys above the on-screen keyboard",
                isOn: $appearance.showAccessoryBar
            )
            .padding(.bottom, 22)

            Field(label: "accessory bar layout") {
                AccessoryBarEditor()
            }

            Field(
                label: "modifier behavior",
                sub: "one-shot: tap ⌃, then a key — modifier auto-clears after one press · sticky: tap to lock the modifier, tap again to release"
            ) {
                ModifierBehaviorSegmented()
            }

            Field(
                label: "shortcuts",
                sub: "read-only for now; per-user remapping is on the roadmap"
            ) {
                ShortcutLegend()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shortcut legend (read-only)

private struct ShortcutLegend: View {
    @Environment(\.designTokens) private var T

    private struct Group: Identifiable {
        let title: String
        let rows: [(keys: String, label: String)]
        var id: String { title }
    }

    // Mirrors every chord the app actually registers:
    //   · global ⌘N / ⌘K / ⌘, live on hidden buttons in ContentView
    //   · session ⌘⇧K / ⌘⇧J + the find / settings chords ride
    //     TesseraTerminalContainer's UIKeyCommands (see
    //     SessionSwitcher.swift for why letters, not ⌃Tab or ⌘⌥[ — both
    //     are dropped by iPadOS before the keyCommand can match).
    //     The bare ⌘[ / ⌘] brackets were reassigned to in-window pane
    //     cycling, so session switching moved to the ⌘⇧K / ⌘⇧J letters.
    //   · ⌘↩ connect lives on HostEntryView's connect button
    //   · the tmux block is only active while a tmux session is attached;
    //     the pane chords (⌘D / ⌘[ / ⌘] / ⇧⌘↩) only do anything once a
    //     window holds more than one pane
    private let groups: [Group] = [
        Group(title: "global", rows: [
            ("⌘N",        "new host"),
            ("⌘K",        "quick-switch palette"),
            ("⌘,",        "settings"),
        ]),
        Group(title: "sessions", rows: [
            ("⌘⇧K / ⌘⇧J", "previous / next session"),
            ("⌘↩",        "connect (host editor)"),
        ]),
        Group(title: "find in scrollback", rows: [
            ("⌘F",        "open find bar"),
            ("⌘G / ⇧⌘G",  "next / previous match"),
            ("↩ / ⇧↩",    "next / previous match (while searching)"),
            ("esc",       "close find bar"),
        ]),
        Group(title: "tmux", rows: [
            ("⌘T",        "new window"),
            ("⇧⌘W",       "close pane / window"),
            ("⇧⌘[ / ⇧⌘]", "previous / next window"),
            ("⌘1 – ⌘9",   "jump to window 1–9"),
        ]),
        Group(title: "panes", rows: [
            ("⌘D / ⇧⌘D",  "split side-by-side / stacked"),
            ("⌘[ / ⌘]",   "previous / next pane"),
            ("⇧⌘↩",       "zoom pane"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title.uppercased())
                        .font(Typography.tesseraMono(size: 9))
                        .foregroundStyle(T.fgFaint)
                        .tracking(1)
                        .padding(.bottom, 6)

                    ForEach(group.rows, id: \.keys) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.keys)
                                .font(Typography.tesseraMono(size: 12, weight: .medium))
                                .foregroundStyle(T.fg)
                                .frame(minWidth: 116, alignment: .leading)
                            Text(row.label)
                                .font(Typography.tesseraMono(size: 12))
                                .foregroundStyle(T.fgMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            if row.keys != group.rows.last?.keys {
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
            Text("tap a palette chip to add · tap a preview chip to remove · long-press a preview chip to drag-reorder · dimmed palette entries are already on the bar")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .lineSpacing(2)
        }
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
                    onTap: { chip in
                        appearance.accessoryBarKeys.removeAll { $0 == chip.rawValue }
                    }
                ) { chip, lifted in
                    ChipLabel(chip: chip, style: lifted ? .lifted : .preview, accent: T.accent, dim: false)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
        .padding(10)
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
            paletteSection("navigation", chips: navChips)
            paletteSection("modifiers", chips: modifierChips)
            paletteSection("function keys", chips: fkeyChips)
            paletteSection("symbols", chips: symbolChips)
        }
        .padding(14)
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private func paletteSection(_ title: String, chips: [AccessoryChip]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(T.fgFaint)
                .tracking(1)

            FlowChipRow(chips: chips, current: Set(appearance.accessoryBarKeys), accent: T.accent) { chip in
                add(chip)
            }
        }
    }

    private func add(_ chip: AccessoryChip) {
        let raw = chip.rawValue
        if !appearance.accessoryBarKeys.contains(raw) {
            appearance.accessoryBarKeys.append(raw)
        }
    }

    private var currentChips: [AccessoryChip] {
        AccessoryChip.from(rawIDs: appearance.accessoryBarKeys)
    }

    // Chip catalogs by category. Single source of truth lives in
    // AccessoryChip; here we just group for the palette UI.
    private let navChips: [AccessoryChip] = [.esc, .tab, .left, .down, .up, .right, .home, .end, .pgup, .pgdn]
    private let modifierChips: [AccessoryChip] = [.ctrl, .alt, .shift]
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
    let chip: AccessoryChip
    let style: ChipStyle
    let accent: Color
    let dim: Bool

    @Environment(\.designTokens) private var T

    var body: some View {
        Text(chip.displayLabel)
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

    private var chipFontSize: CGFloat {
        chip.displayLabel.count > 2 ? 11 : 13
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
    let chips: [AccessoryChip]
    let current: Set<String>
    let accent: Color
    let onTap: (AccessoryChip) -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        HFlow(spacing: 6, runSpacing: 6) {
            ForEach(chips, id: \.rawValue) { chip in
                let isCurrent = current.contains(chip.rawValue)
                Button {
                    if !isCurrent { onTap(chip) }
                } label: {
                    ChipLabel(chip: chip, style: .palette, accent: accent, dim: isCurrent)
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
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

    private func segment(_ label: String, value: String, binding: Binding<String>) -> some View {
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
