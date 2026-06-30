import SwiftUI

struct SessionRestorePrompt: Identifiable {
    let id = UUID()
    let document: SessionRestoreDocument
    let hostNames: [String]
    let skippedCount: Int
    let preserveSnapshotLiveIDs: Bool

    init(
        document: SessionRestoreDocument,
        hostNames: [String],
        skippedCount: Int,
        preserveSnapshotLiveIDs: Bool = true
    ) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("reopen previous connections")
                .font(Typography.tesseraMono(size: 18, weight: .semibold))
                .foregroundStyle(T.fg)

            Text(summaryText)
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
            .padding(.vertical, 2)

            if prompt.skippedCount > 0 {
                Text(skippedText)
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

            HStack(spacing: 10) {
                Btn(style: .primary, action: onReopen) {
                    Text("reopen")
                        .font(Typography.tesseraMono(size: 13, weight: .semibold))
                }

                Btn("not now", style: .default, action: onNotNow)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.bg)
    }

    private var summaryText: String {
        let count = prompt.hostNames.count
        let noun = count == 1 ? "connection" : "connections"
        return "\(count) saved-host \(noun) can be reopened."
    }

    private var skippedText: String {
        let noun = prompt.skippedCount == 1 ? "connection was" : "connections were"
        return "\(prompt.skippedCount) previous \(noun) skipped because the saved host or credentials changed."
    }
}
