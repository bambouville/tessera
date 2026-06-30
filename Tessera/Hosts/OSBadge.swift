import SwiftUI

struct OSBadge: View {
    let osHint: String
    var size: CGFloat = 18

    @Environment(\.designTokens) private var T

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(T.accent)
            .frame(width: size, height: size)
            .overlay {
                glyph
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            }
    }

    private var normalizedOS: String {
        osHint.lowercased()
    }

    @ViewBuilder
    private var glyph: some View {
        if normalizedOS == "macos" {
            // Apple's official mark already ships as an SF Symbol — use it.
            Image(systemName: "apple.logo")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.70, height: size * 0.70)
                .foregroundStyle(.white)
        } else if let logo = DistroLogo.glyph(for: normalizedOS, size: size * 0.78) {
            // Each Linux distro renders as its own monochrome shape so the
            // accent color shows through as the badge background.
            logo.foregroundStyle(.white)
        } else {
            Text("?")
                .font(Typography.tesseraMono(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
