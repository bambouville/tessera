import SwiftUI

struct HostCard: View {
    let host: PersistedHost
    let isActive: Bool
    let onOpen: () -> Void

    @Environment(\.designTokens) private var T
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    OSBadge(osHint: host.osHint, size: 18)

                    Spacer(minLength: 8)

                    if isActive {
                        StatusDot(color: T.green, pulse: true, size: 7)
                    }
                }
                .padding(.bottom, 8)

                Text(host.name)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)

                Text(endpointText)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
                    .padding(.top, 4)

                // Always reserve the chip-row height so cards stay
                // size-matched whether or not the host has tags.
                HStack(spacing: 6) {
                    if tagTexts.isEmpty {
                        Tag(text: "—")
                            .opacity(0)
                            .accessibilityHidden(true)
                    } else {
                        ForEach(Array(tagTexts.enumerated()), id: \.offset) { _, text in
                            Tag(text: text)
                        }
                    }
                }
                .padding(.top, 10)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? T.panelBg : T.sidebarBg)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hover ? T.borderStrong : T.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.14), value: hover)
    }

    private var endpointText: String {
        let user = host.effectiveUser
        let prefix = user.isEmpty ? host.address : user
        return "\(prefix)@\(host.address):\(host.port)"
    }

    private var tagTexts: [String] {
        var values: [String] = []

        if host.transport == .mosh {
            values.append("mosh")
        }

        if host.autoTmux {
            values.append("tmux")
        }

        values.append(contentsOf: host.tags)
        return values
    }
}
