import SwiftUI
import SwiftData

/// Sidebar root for the NavigationSplitView. Hosts and active sessions
/// share one custom M2 sidebar surface. Fixed 240pt wide; `ContentView`
/// shows or hides it (no rail/wide collapse variant).
struct SessionSidebar: View {
    /// Fixed width of the sidebar column. Shared with `ContentView` so the
    /// push-aside inset on non-terminal pages matches exactly.
    static let width: CGFloat = 240

    @Query(sort: \PersistedHost.sortOrder) private var hosts: [PersistedHost]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance

    @Binding var activeSessions: [LiveSession]
    @Binding var selectedItem: SidebarItem?
    var onDisconnectSession: (LiveSession) -> Void
    var onNewHost: () -> Void = {}
    /// Hides the sidebar — backs the in-panel `‹` button (Apple's in-sidebar
    /// toggle). Reopen via the terminal top-bar `line.3.horizontal` button, or
    /// the floating reveal button on browse pages.
    var onCollapse: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if !activeSessions.isEmpty {
                        activeSessionsSection
                    }

                    hostsSection
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            bottomNavigation
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Floating glass: the sidebar sits ABOVE the detail content in a
        // ZStack, so this material refracts/blurs the terminal (or page)
        // behind it. `T.sidebarBg` is the translucent tint wash; `.solid`
        // / Reduce Transparency fall back to an opaque panel fill.
        .floatingGlass(
            appearance.chromeMaterial,
            tint: T.sidebarBg,
            solidFill: T.isLight ? Color(rgbInt: 0xF2F2F7) : Color(rgbInt: 0x1C1C1E),
            in: Rectangle()
        )
        // No opaque floor: it would sit behind the glass and get refracted
        // instead of the terminal, collapsing Liquid Glass to a flat blur. The
        // context-menu lift that previously needed a floor is gone (disconnect /
        // delete are explicit buttons now), so the glass can read the canvas.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(T.sidebarBorder)
                .frame(width: 0.5)
        }
        // Lift the bottom safe-area inset off the entire sidebar (not
        // just the background) so the bottom-nav buttons and the
        // sidebar surface both reach the screen edge in landscape
        // Magic Keyboard layouts, where the home-indicator gutter
        // sits under the center detail pane, not the sidebar column.
        .ignoresSafeArea(edges: .bottom)
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                TesseraLogo(size: 18)

                Text("Tessera")
                    .font(Typography.tesseraMono(size: 17, weight: .medium))
                    .foregroundStyle(T.fg)
            }

            Spacer(minLength: 0)

            SidebarIconButton(systemName: "plus", accessibilityLabel: "new host") {
                onNewHost()
            }

            // In-panel hide (Apple's in-sidebar toggle). Over the terminal the
            // sidebar floats, so this maximizes the canvas; on browse pages it
            // collapses the nav column to full-width content.
            SidebarIconButton(systemName: "chevron.left", accessibilityLabel: "hide sidebar") {
                onCollapse()
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 48)
    }

    private var activeSessionsSection: some View {
        SidebarSection(label: "active") {
            ForEach(activeSessions) { live in
                ActiveSessionRow(
                    live: live,
                    isSelected: selectedItem == .session(live.id),
                    action: { toggleSelection(.session(live.id)) },
                    onDisconnect: { onDisconnectSession(live) }
                )
            }
        }
    }

    private var hostsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("hosts")
                    .font(Typography.tesseraMono(size: 11))
                    .tracking(0.4)
                    .foregroundStyle(T.fgMuted)

                Spacer(minLength: 0)

                Button {
                    selectedItem = nil
                } label: {
                    Text("view all")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgMuted)
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("view all hosts")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)

            ForEach(hosts) { host in
                // Inline red trash button (no long-press menu — its system lift
                // made the floating glass sidebar render transparent).
                HostRow(
                    host: host,
                    isSelected: selectedItem == .host(host.id),
                    action: { selectedItem = .host(host.id) },
                    onDelete: {
                        if selectedItem == .host(host.id) { selectedItem = nil }
                        modelContext.delete(host)
                        try? modelContext.save()
                    }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var bottomNavigation: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(T.sidebarBorder)
                .frame(height: 1)

            VStack(spacing: 2) {
                BottomNavigationRow(
                    item: .keys,
                    systemName: "key.fill",
                    label: "keys",
                    isSelected: selectedItem == .keys
                ) {
                    selectedItem = .keys
                }
                .onboardingAnchor(.keysNav)

                BottomNavigationRow(
                    item: .knownHosts,
                    systemName: "lock.shield.fill",
                    label: "known hosts",
                    isSelected: selectedItem == .knownHosts
                ) {
                    selectedItem = .knownHosts
                }

                BottomNavigationRow(
                    item: .tunnels,
                    systemName: "arrow.left.arrow.right",
                    label: "tunnels",
                    isSelected: selectedItem == .tunnels
                ) {
                    selectedItem = .tunnels
                }

                BottomNavigationRow(
                    item: .settings,
                    systemName: "gearshape.fill",
                    label: "settings",
                    isSelected: selectedItem == .settings
                ) {
                    selectedItem = .settings
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 14)
            .padding(.horizontal, 8)
        }
    }

    private func toggleSelection(_ item: SidebarItem) {
        selectedItem = selectedItem == item ? nil : item
    }
}

private struct SidebarSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(Typography.tesseraMono(size: 11))
                .tracking(0.4)
                .foregroundStyle(T.fgMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)

            content
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// Thin enum-branching wrapper. SwiftUI's `@ObservedObject` can't bind
/// `any TerminalSession` (an existential doesn't itself satisfy
/// `ObservableObject` — see `LiveSession` docs), so we branch on the
/// transport here and hand the concrete `SSHSession` / `MoshSession`
/// to a generic body that observes its `@Published state`.
private struct ActiveSessionRow: View {
    let live: LiveSession
    let isSelected: Bool
    let action: () -> Void
    var onDisconnect: () -> Void = {}

    var body: some View {
        switch live.session {
        case .ssh(let session):
            ActiveSessionRowBody(
                session: session,
                live: live,
                isSelected: isSelected,
                action: action,
                onDisconnect: onDisconnect
            )
        case .mosh(let session):
            ActiveSessionRowBody(
                session: session,
                live: live,
                isSelected: isSelected,
                action: action,
                onDisconnect: onDisconnect
            )
        }
    }
}

private struct ActiveSessionRowBody<S: ObservableObject & TerminalSession>: View {
    @ObservedObject var session: S
    let live: LiveSession
    let isSelected: Bool
    let action: () -> Void
    var onDisconnect: () -> Void = {}

    @State private var confirmingDisconnect = false
    @Environment(\.designTokens) private var T
    @Environment(SessionRegistry.self) private var registry

    // Dot color mirrors `SessionTopBar.dotColor(for:)` so the sidebar
    // and the top-bar chrome agree on what each state looks like.
    private func dotColor(for state: SessionState) -> Color {
        switch state {
        case .idle:                 return T.fgDim
        case .connecting:           return T.amber
        case .connected:            return T.green
        case .disconnected, .failed: return T.red
        }
    }

    // Pulse only while there's live motion to convey (connecting /
    // connected); terminal states are static.
    private func pulses(for state: SessionState) -> Bool {
        switch state {
        case .connecting, .connected: return true
        default:                      return false
        }
    }

    private func label(for state: SessionState) -> String {
        switch state {
        case .idle:         return "idle"
        case .connecting:   return "connecting…"
        case .connected:    return "connected"
        case .disconnected: return "disconnected"
        case .failed:       return "failed"
        }
    }

    var body: some View {
        // Read once inside the @MainActor body; the helpers take the
        // (Sendable) SessionState rather than touching the isolated
        // `session.state` from non-isolated computed properties.
        //
        // A tmux session reports `.connected` the moment the SSH/mosh
        // handshake lands, but the user is still watching the "attaching
        // tmux" launch shield until the first pane paints. Hold the row in
        // its connecting appearance (amber dot, pulsing, "connecting…")
        // until `SessionView` marks the launch complete in the registry —
        // otherwise the sidebar reads "connected" over the loading screen.
        let rawState = session.state
        let state: SessionState = (rawState == .connected && !registry.isRenderReady(live.id))
            ? .connecting
            : rawState

        HStack(spacing: 6) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(color: dotColor(for: state), pulse: pulses(for: state), size: 6)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            Text(live.hostName)
                                .font(Typography.tesseraMono(size: 13))
                                .foregroundStyle(T.fg)
                                .lineLimit(1)

                            if live.autoTmux {
                                Text(" · tmux")
                                    .font(Typography.tesseraMono(size: 13))
                                    .foregroundStyle(T.fgDim)
                                    .lineLimit(1)
                            }
                        }

                        Text(label(for: state))
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Explicit disconnect. Replaces the long-press context menu, whose
            // system "lift" made the floating glass sidebar render transparent
            // over the live terminal (Liquid Glass doesn't composite into the
            // context-menu backdrop). A tap confirms, so it's hard to fat-finger.
            RowActionButton(
                systemName: "xmark",
                tint: T.red,
                accessibilityLabel: "disconnect \(live.hostName)"
            ) {
                confirmingDisconnect = true
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? T.inputBgSoft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 2)
        .confirmationDialog(
            "Disconnect \(live.hostName)?",
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { onDisconnect() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct HostRow: View {
    let host: PersistedHost
    let isSelected: Bool
    let action: () -> Void
    var onDelete: () -> Void = {}

    @State private var confirmingDelete = false
    @Environment(\.designTokens) private var T

    private var title: String {
        host.name.isEmpty ? host.address : host.name
    }

    private var subtitle: String {
        let user = host.effectiveUser
        return "\(user.isEmpty ? "—" : user)@\(host.address):\(host.port)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 0) {
                    OSBadge(osHint: host.osHint, size: 16)
                        .padding(.top, 1)
                        .padding(.trailing, 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(T.fg)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            RowActionButton(
                systemName: "trash",
                tint: T.red,
                accessibilityLabel: "delete \(title)"
            ) {
                confirmingDelete = true
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? T.inputBgSoft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 2)
        .confirmationDialog(
            "Delete \(title)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Small circular tinted icon button for in-row destructive actions
/// (disconnect, delete). Clearly reads as a button: tinted fill + hairline
/// ring around the glyph.
private struct RowActionButton: View {
    let systemName: String
    let tint: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().stroke(tint.opacity(0.35), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct BottomNavigationRow: View {
    let item: SidebarItem
    let systemName: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                navIcon

                Text(label)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(isSelected ? T.accent : T.fgMuted)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? T.inputBgSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var navIcon: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 15, height: 15)
            .foregroundStyle(isSelected ? T.accent : T.fgMuted)
    }
}

private struct SidebarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(T.fgMuted)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressableIconButtonStyle(cornerRadius: 6))
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Press feedback for the small chrome icon buttons (the title-bar `+` and
/// `‹`). `.plain` buttons give no on-press response on iPad, so a tap felt
/// dead. This fills the glyph's bounds with a faint wash and nudges it down
/// in scale while the finger is held, then springs back on release.
private struct PressableIconButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    @Environment(\.designTokens) private var T

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? T.fgFaint : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Discriminated union for sidebar selection.
enum SidebarItem: Hashable, Equatable {
    case session(UUID)
    case host(UUID)
    case keys
    case knownHosts
    case tunnels
    case settings
}
