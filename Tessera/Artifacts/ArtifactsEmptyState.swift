import SwiftUI
import TesseraArtifactsCore

struct ArtifactsEmptyState: View {
    @Environment(\.designTokens) private var T
    var onQuickOpen: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(T.fgDim)
                Text("your work, open here")
                    .font(Typography.pageTitle)
                    .foregroundStyle(T.fg)
                Text("docs, pages, changes and files stay with their host, across sessions.")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                VStack(alignment: .leading, spacing: 16) {
                    source("folder", "open a file in Files")
                    source("text.cursor", "select a path in the terminal")
                    source("globe", "open a localhost link")
                    source("plus.forwardslash.minus", "open an agent edit")
                }
                if let onQuickOpen {
                    Button(action: onQuickOpen) {
                        Label("new tab", systemImage: "plus")
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.fg)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(T.inputBg, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("artifacts-new-tab")
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func source(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        Label(title, systemImage: symbol)
            .font(Typography.tesseraMono(size: 12))
            .foregroundStyle(T.fgMuted)
    }
}

struct ArtifactCacheBadge: View {
    @Environment(\.designTokens) private var T
    let presentation: ArtifactsCachePresentation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let badge = ArtifactsBrowserPresentation.badge(presentation, now: context.date) {
                Label {
                    Text(verbatim: badge.text)
                } icon: {
                    Image(systemName: badge.symbol)
                        .font(.system(size: badge.symbol == "circle.fill" ? 5 : 9))
                }
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgMuted)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: badge.accessibilityLabel))
            }
        }
    }
}
