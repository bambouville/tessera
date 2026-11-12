import SwiftUI

/// The release card uses the phone's tab bar or the iPad's sidebar vocabulary.
/// Its actions stay visible when a short window makes the explanation scroll.
struct WhatsNewCard: View {
    let isPhone: Bool
    let onShowMe: () -> Void
    let onDone: () -> Void

    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    var body: some View {
        VStack(spacing: 18) {
            ViewThatFits(in: .vertical) {
                explanation.fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) {
                    explanation
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Btn(style: .primary, full: true, action: onShowMe) {
                        Text("show me").frame(minHeight: 24)
                    }
                    .accessibilityIdentifier("whats-new-show-me")

                    Btn(style: .default, full: true, action: onDone) {
                        Text("done").frame(minHeight: 24)
                    }
                    .accessibilityIdentifier("whats-new-done")
                }

                Text("again any time in Settings → About")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(isPhone ? 20 : 26)
        .floatingGlass(
            appearance.chromeMaterial, tint: T.sidebarBg, solidFill: T.panelBg,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(T.borderStrong, lineWidth: 0.5)
        }
        .accessibilityIdentifier("whats-new-card")
    }

    private var explanation: some View {
        VStack(spacing: 16) {
            TesseraLogo(size: 44, color: T.fg)

            Text("what's new in 0.4.1")
                .font(Typography.tesseraMono(size: isPhone ? 19 : 22, weight: .semibold))
                .foregroundStyle(T.fg)
                .multilineTextAlignment(.center)

            Text(isPhone
                ? "The tab bar has new places. Here is what moved, and where it went."
                : "The sidebar has new places. Here is what moved, and where it went.")
                .tesseraSansScaled(size: 13)
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                navigationBar("before", places: before)
                navigationBar("now", places: now)
            }

            VStack(alignment: .leading, spacing: 13) {
                move("archivebox", title: "artifacts", detail: "Docs, pages, an agent's changes and files from every session, as tabs that stay with their host.")
                move("archivebox", title: "Open in Artifacts", detail: "Where Quick Look was — in a file's menu and on a path you select in the terminal.")
                if isPhone {
                    move("sparkles", title: "agents", detail: "Its own tab while Agent Center is on, instead of a segment in sessions.")
                } else {
                    move("arrow.left.arrow.right", title: "tunnels", detail: "Its pages open as artifacts tabs; the rules stay in each host's editor.")
                }
                move("key", title: "keys and known hosts", detail: "In Settings now, beside security.")
            }
        }
    }

    private struct Place {
        let glyph: String
        let title: LocalizedStringResource
    }

    private var before: [Place] {
        if isPhone {
            return [Place(glyph: "server.rack", title: "hosts"),
                    Place(glyph: "square.stack", title: "sessions"),
                    Place(glyph: "key", title: "keys"),
                    Place(glyph: "gearshape", title: "settings")]
        }
        return [Place(glyph: "square.stack", title: "sessions/hosts"),
                Place(glyph: "sparkles", title: "agents"),
                Place(glyph: "key", title: "keys"),
                Place(glyph: "lock.shield", title: "known hosts"),
                Place(glyph: "arrow.left.arrow.right", title: "tunnels"),
                Place(glyph: "gearshape", title: "settings")]
    }

    private var now: [Place] {
        let navigation = [Place(glyph: "sparkles", title: "agents"),
                          Place(glyph: "archivebox", title: "artifacts"),
                          Place(glyph: "gearshape", title: "settings")]
        return isPhone
            ? [Place(glyph: "server.rack", title: "hosts"), Place(glyph: "square.stack", title: "sessions")] + navigation
            : navigation
    }

    private func navigationBar(_ label: LocalizedStringKey, places: [Place]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
            HStack(alignment: .top, spacing: 4) {
                ForEach(places.indices, id: \.self) { index in
                    VStack(spacing: 5) {
                        Image(systemName: places[index].glyph)
                            .font(.system(size: 13))
                        Text(places[index].title)
                            .font(Typography.tesseraSans(size: 10))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(T.fgMuted)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .background(T.inputBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(T.border, lineWidth: 0.5)
        }
    }

    private func move(_ glyph: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 15))
                .foregroundStyle(T.fgMuted)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(T.fg)
                Text(detail)
                    .tesseraSansScaled(size: 12)
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
