import SwiftUI

struct SessionRestorePrompt: Identifiable {
    let id: UUID
    let document: SessionRestoreDocument
    let hostNames: [String]
    let skippedCount: Int
    let preserveSnapshotLiveIDs: Bool

    init(
        id: UUID = UUID(),
        document: SessionRestoreDocument,
        hostNames: [String],
        skippedCount: Int,
        preserveSnapshotLiveIDs: Bool = true
    ) {
        // Carrying the identity forward lets a presented sheet absorb a
        // larger snapshot set in place; `.sheet(item:)` would otherwise
        // dismiss and re-present it.
        self.id = id
        self.document = document
        self.hostNames = hostNames
        self.skippedCount = skippedCount
        self.preserveSnapshotLiveIDs = preserveSnapshotLiveIDs
    }
}

struct SessionRestoreSheet: View {
    let prompt: SessionRestorePrompt
    @Binding var alwaysReopen: Bool
    var onReopen: () -> Void
    var onNotNow: () -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                Text("reopen previous connections")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.fg)

                Text(verbatim: summaryText)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(prompt.hostNames.enumerated()), id: \.offset) { _, name in
                        HStack(spacing: 8) {
                            StatusDot(color: T.green, pulse: false, size: 6)
                            Text(name)
                                .font(Typography.tesseraMono(size: 13))
                                .foregroundStyle(T.fg)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if prompt.skippedCount > 0 {
                    Text(verbatim: skippedText)
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $alwaysReopen) {
                    Text("always reopen")
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fg)
                }
                .toggleStyle(.switch)
                .tint(T.accent)
                .padding(.top, 2)

                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)

            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)

            HStack(spacing: 10) {
                Btn(style: .primary, action: onReopen) {
                    Text("reopen")
                        .font(Typography.tesseraMono(size: 13, weight: .semibold))
                }

                Btn("not now", style: .default, action: onNotNow)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(T.presentationBg)
            .accessibilityElement(children: .contain)
        }
        .background(T.presentationBg)
        .modifier(
            SessionRestorePresentationModifier(
                fallbackHeight: fallbackPresentationHeight
            )
        )
    }

    // Whole sentences, pluralized by the String Catalog rather than by
    // swapping a noun in English. Picking "connection"/"connections" here
    // only works for languages with two forms and no agreement elsewhere in
    // the sentence; the catalog carries a variant per language's own rules.
    private var summaryText: String {
        String(
            localized: "\(prompt.hostNames.count) saved-host connections can be reopened.",
            comment: "Session restore sheet summary. Pluralized on the connection count."
        )
    }

    private var skippedText: String {
        String(
            localized: "\(prompt.skippedCount) previous connections were skipped because the saved host or credentials changed.",
            comment: "Session restore sheet note. Pluralized on the skipped count."
        )
    }

    private var maximumVisibleHostCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 4 : 7
    }

    private var hostListHeight: CGFloat {
        let visibleRows = max(1, min(prompt.hostNames.count, maximumVisibleHostCount))
        let rowHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 40 : 24
        return CGFloat(visibleRows) * rowHeight
    }

    private var fallbackPresentationHeight: CGFloat {
        let accessibilityAllowance: CGFloat = dynamicTypeSize.isAccessibilitySize ? 130 : 0
        let skippedAllowance: CGFloat = prompt.skippedCount > 0 ? 44 : 0
        return min(
            720,
            238 + hostListHeight + skippedAllowance + accessibilityAllowance
        )
    }
}

private struct SessionRestorePresentationModifier: ViewModifier {
    let fallbackHeight: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .presentationDetents([.height(fallbackHeight), .large])
            .presentationContentInteraction(.scrolls)
    }
}
