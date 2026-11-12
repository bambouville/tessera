import SwiftUI

/// A passive drawing of both entry points; these rows never open a real file
/// or send a path to a session while the walkthrough is on screen.
struct OpenInArtifactsIllustration: View {
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                caption("terminal selection")
                HStack(spacing: 0) {
                    selectionItem("Copy", highlighted: false)
                    selectionItem("Open in Artifacts", highlighted: true)
                    selectionItem("Reveal in Files", highlighted: false)
                }
                .padding(4)
                .background(menuBackground)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(T.fgMuted)
                    Text(verbatim: "README.md")
                        .foregroundStyle(T.fg)
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis")
                        .foregroundStyle(T.fgMuted)
                }
                .font(Typography.tesseraMono(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                VStack(spacing: 0) {
                    fileMenuItem("Open in Artifacts", glyph: "archivebox", highlighted: true)
                    fileMenuItem("Download", glyph: "arrow.down", highlighted: false)
                    fileMenuItem("Share…", glyph: "square.and.arrow.up", highlighted: false)
                    fileMenuItem("Send Path to Terminal", glyph: "terminal", highlighted: false)
                }
                .padding(4)
                .background(menuBackground)
            }
        }
        .padding(12)
        .background(T.inputBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(T.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Typography.tesseraMono(size: 10))
            .foregroundStyle(T.fgDim)
    }

    private func selectionItem(_ title: LocalizedStringKey, highlighted: Bool) -> some View {
        Text(title)
            .font(Typography.tesseraSans(size: 10, weight: highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? T.fg : T.fgMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(highlighted ? T.inputBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func fileMenuItem(_ title: LocalizedStringKey, glyph: String, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            Image(systemName: glyph)
        }
        .font(Typography.tesseraSans(size: 12, weight: highlighted ? .semibold : .regular))
        .foregroundStyle(highlighted ? T.fg : T.fgMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(highlighted ? T.inputBg : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var menuBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(T.panelBg)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(T.borderStrong, lineWidth: 0.5)
            }
    }
}
