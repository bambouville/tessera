import SwiftUI

enum HostCardRuntimeBadges {
    static func activeTmuxUsage(in sessions: [LiveSession]) -> [UUID: Bool] {
        sessions.reduce(into: [:]) { usage, session in
            guard let hostID = session.persistedHostID else { return }
            usage[hostID] = (usage[hostID] ?? false) || session.autoTmux
        }
    }

    static func showsTmux(
        savedPreference: Bool,
        activeSessionUsesTmux: Bool?,
        tmuxKnownUnavailable: Bool
    ) -> Bool {
        if let activeSessionUsesTmux {
            return activeSessionUsesTmux
        }
        return savedPreference && !tmuxKnownUnavailable
    }
}

struct HostCard: View {
    let host: PersistedHost
    let isActive: Bool
    let activeSessionUsesTmux: Bool?
    let onOpen: () -> Void
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

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
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
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
        .contextMenu {
            Button("connect", systemImage: "terminal", action: onOpen)
            if let onEdit {
                Button("edit…", systemImage: "pencil", action: onEdit)
            }
            if let onDelete {
                Button("remove…", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.14), value: hover)
    }

    private var endpointText: String {
        let user = host.effectiveUser
        let endpoint = user.isEmpty ? host.address : "\(user)@\(host.address)"
        return "\(endpoint):\(host.port)"
    }

    private var tagTexts: [String] {
        var values: [String] = []

        if host.transport == .mosh {
            values.append("mosh")
        }

        if HostCardRuntimeBadges.showsTmux(
            savedPreference: host.autoTmux,
            activeSessionUsesTmux: activeSessionUsesTmux,
            tmuxKnownUnavailable: HostRuntimeStateStore.isTmuxKnownUnavailable(
                for: Host(
                    id: host.id,
                    address: host.address,
                    port: host.port,
                    user: host.effectiveUser
                )
            )
        ) {
            values.append("tmux")
        }

        values.append(contentsOf: host.tags)
        return values
    }
}
