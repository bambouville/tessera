// Tessera/Keyboard/ShortcutCheatSheetView.swift
// A passive, entirely visible keymap. Measure whole-section column layouts
// before choosing a scale, so short windows never depend on scrolling.
import SwiftUI

struct ShortcutCheatSheetView: View {
    let sections: [ShortcutCheatSheetSection]
    let material: ChromeMaterial
    let notation: ModifierNotation
    var isPresented = true

    @Environment(\.designTokens) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measurements: [Int: CGSize] = [:]

    private let margin: CGFloat = 16
    private let cardPadding: CGFloat = 18
    private let columnGap: CGFloat = 24
    private let minimumColumnWidth: CGFloat = 248
    private let maximumCardWidth: CGFloat = 920

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(
                width: max(1, geometry.size.width - margin * 2),
                height: max(1, geometry.size.height - margin * 2)
            )
            let selection = bestLayout(available: available)
            ZStack {
                ForEach(1...min(3, max(1, sections.count)), id: \.self) { count in
                    let selected = count == selection.count
                    card(columnCount: count)
                        .frame(width: naturalWidth(columns: count, available: available.width))
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { cardGeometry in
                                Color.clear.preference(
                                    key: CheatSheetMeasurements.self,
                                    value: [count: cardGeometry.size]
                                )
                            }
                        }
                        .floatingGlass(
                            material, tint: T.sidebarBg, solidFill: T.panelBg,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(T.borderStrong, lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                        .scaleEffect(selection.scale)
                        .opacity(selected && measurements[count] != nil ? 1 : 0)
                        .accessibilityHidden(!selected)
                        .accessibilityIdentifier(
                            selected ? "shortcut-cheat-sheet" : "shortcut-cheat-sheet-measure-\(count)"
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(reduceMotion || isPresented ? 1 : 0.97)
            .animation(.easeOut(duration: 0.15), value: isPresented)
        }
        .onPreferenceChange(CheatSheetMeasurements.self) { measurements = $0 }
        .allowsHitTesting(false)
    }

    private func card(columnCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    heading
                    Spacer(minLength: 0)
                    closeHint
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    closeHint
                }
            }
            HStack(alignment: .top, spacing: columnGap) {
                let columns = ShortcutCheatSheetColumns.balanced(sections, count: columnCount)
                ForEach(columns.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(columns[index]) { section in
                            sectionView(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(cardPadding)
    }

    private var heading: some View {
        Text("keyboard shortcuts")
            .font(Typography.tesseraMono(size: 13))
            .foregroundStyle(T.fg)
            .fixedSize()
    }

    private var closeHint: some View {
        Text("release \(KeyToken.command.rendered(notation)) to close")
            .font(Typography.tesseraMono(size: 10))
            .foregroundStyle(T.fgDim)
            .fixedSize()
    }

    private func sectionView(_ section: ShortcutCheatSheetSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: section.title)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(T.fgFaint)
                if let note = section.note {
                    Text(verbatim: note)
                        .foregroundStyle(T.fgDim)
                }
            }
            .font(Typography.tesseraMono(size: 9.5))
            .fixedSize(horizontal: false, vertical: true)

            ForEach(section.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: row.title)
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(T.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(verbatim: row.chord)
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .foregroundStyle(T.fg)
                        .fixedSize()
                        .layoutPriority(1)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func naturalWidth(columns: Int, available: CGFloat) -> CGFloat {
        min(maximumCardWidth, max(
            available,
            minimumColumnWidth * CGFloat(columns) + columnGap * CGFloat(columns - 1) + cardPadding * 2
        ))
    }

    /// Try wider natural layouts as well: three columns scaled slightly down
    /// are more readable than one very tall column on a landscape iPhone.
    /// Normal phone/tablet sizes stay around 0.6 or above; unusually small
    /// windows still fit every row instead of clipping at an arbitrary floor.
    private func bestLayout(available: CGSize) -> (count: Int, scale: CGFloat) {
        let preferred = min(3, max(1, Int(
            (available.width - cardPadding * 2 + columnGap) / (minimumColumnWidth + columnGap)
        )))
        var best = (count: 1, scale: CGFloat.zero)
        for count in 1...min(3, max(1, sections.count)) {
            guard let size = measurements[count], size.height > 0 else { continue }
            let width = naturalWidth(columns: count, available: available.width)
            let scale = min(1, available.width / width, available.height / size.height)
            if scale > best.scale + 0.001
                || (abs(scale - best.scale) <= 0.001 && abs(count - preferred) < abs(best.count - preferred)) {
                best = (count, scale)
            }
        }
        return best
    }
}

private struct CheatSheetMeasurements: PreferenceKey {
    static let defaultValue: [Int: CGSize] = [:]
    static func reduce(value: inout [Int: CGSize], nextValue: () -> [Int: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Contiguous partitions preserve registry reading order. Minimize the
/// heaviest column rather than round-robin interleaving unrelated groups.
enum ShortcutCheatSheetColumns {
    static func balanced(_ sections: [ShortcutCheatSheetSection], count: Int) -> [[ShortcutCheatSheetSection]] {
        guard !sections.isEmpty else { return [] }
        let count = min(max(1, count), sections.count)
        let weights = sections.map { $0.rows.count + ($0.note == nil ? 2 : 4) }
        var prefix = [0]
        for weight in weights { prefix.append((prefix.last ?? 0) + weight) }
        var costs = Array(repeating: Array(repeating: Int.max, count: sections.count + 1), count: count + 1)
        var cuts = Array(repeating: Array(repeating: 0, count: sections.count + 1), count: count + 1)
        costs[0][0] = 0
        for column in 1...count {
            for end in column...sections.count {
                for start in (column - 1)..<end where costs[column - 1][start] != Int.max {
                    let cost = max(costs[column - 1][start], prefix[end] - prefix[start])
                    if cost < costs[column][end] {
                        costs[column][end] = cost
                        cuts[column][end] = start
                    }
                }
            }
        }
        var columns: [[ShortcutCheatSheetSection]] = []
        var end = sections.count
        for column in stride(from: count, through: 1, by: -1) {
            let start = cuts[column][end]
            columns.insert(Array(sections[start..<end]), at: 0)
            end = start
        }
        return columns
    }
}

#Preview {
    ShortcutCheatSheetView(
        sections: ShortcutCheatSheet.sections(store: nil, notation: .glyph),
        material: .frosted, notation: .glyph
    )
    .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))
}
