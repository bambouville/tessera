import SwiftData
import SwiftUI
import UIKit

struct HostsLandingView: View {
    @Query(sort: \PersistedHost.sortOrder) private var hosts: [PersistedHost]

    let onConnect: (PersistedHost) -> Void
    let onEdit: (PersistedHost) -> Void
    let onDelete: (PersistedHost) -> Void
    let onNewHost: () -> Void
    let onQuickConnect: (String) -> Void
    let onOpenKeys: () -> Void
    let activeHostKeys: Set<String>
    let activeHostTmuxUsage: [UUID: Bool]

    @Environment(\.designTokens) private var T
    @State private var search: String = ""
    @State private var pendingRemovalHost: PersistedHost?

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The full quick-connect instruction truncates inside the ~300 pt field a
    /// phone offers; the empty state's bottom hint already teaches `user@host`,
    /// so the compact placeholder stays short.
    private var searchPlaceholder: String {
        guard isPhone else {
            return "search hosts, or type user@host to quick-connect"
        }
        return hosts.isEmpty
            ? "search hosts or add new ones below"
            : "search hosts or user@host"
    }

    var body: some View {
        Group {
            if hosts.isEmpty {
                // Empty state replaces the scrolling sections: header + quick-
                // connect bar stay, then a centered call-to-action fills the rest.
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    quickConnectRow
                    emptyState
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pageHeader
                        quickConnectRow
                        recentSection
                        allHostsSection
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.bg.ignoresSafeArea())
        .confirmationDialog(
            pendingRemovalHost.map { "remove \($0.name.isEmpty ? $0.address : $0.name)?" }
                ?? "remove host?",
            isPresented: Binding(
                get: { pendingRemovalHost != nil },
                set: { if !$0 { pendingRemovalHost = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("remove host", role: .destructive) {
                guard let host = pendingRemovalHost else { return }
                onDelete(host)
                pendingRemovalHost = nil
            }
            Button("cancel", role: .cancel) {
                pendingRemovalHost = nil
            }
        } message: {
            Text("This removes the saved host. Existing live sessions are not disconnected.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            TesseraLogo(size: 60)
                .padding(.bottom, 22)

            Text("no hosts yet")
                .font(Typography.tesseraMono(size: 19, weight: .medium))
                .foregroundStyle(T.fg)
                .padding(.bottom, 10)

            Text("Add a server to open a session over SSH or Mosh — with tmux, "
                + "truecolor, and trackpad scrolling built in.")
                .tesseraSansScaled(size: 14)
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .padding(.bottom, 24)

            HStack(spacing: 10) {
                Btn(style: .primary, action: onNewHost) {
                    HStack(spacing: 8) {
                        Text("add your first host")
                        if !isPhone {
                            Text("⌘N")
                                .font(Typography.tesseraMono(size: 11))
                                .foregroundStyle((T.isLight ? Color.white : Color.black).opacity(0.55))
                        }
                    }
                }
                .onboardingAnchor(.addHost)

                Btn(style: .default, action: onOpenKeys) {
                    Text("generate a key")
                }
            }

            Group {
                Text("or type ")
                    + Text("user@host").foregroundColor(T.fgMuted)
                    + Text(" in the search bar above to connect right away")
            }
            .font(Typography.tesseraMono(size: 12))
            .foregroundStyle(T.fgDim)
            .multilineTextAlignment(.center)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, isPhone ? 20 : 40)
        .padding(.bottom, isPhone ? 20 : 60)
    }

    private var filteredHosts: [PersistedHost] {
        guard !search.isEmpty else { return hosts }

        let q = search.lowercased()
        return hosts.filter { host in
            let user = host.effectiveUser
            let addr = (user.isEmpty ? "" : user + "@") + host.address
            return host.name.lowercased().contains(q) || addr.lowercased().contains(q)
        }
    }

    private var pageHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("hosts")
                    .font(Typography.heroTitle)
                    .foregroundStyle(T.fg)

                Spacer()

                Btn(style: .default, compact: true, action: onNewHost) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("new host")
                        if !isPhone {
                            Text("⌘N")
                                .font(Typography.tesseraMono(size: 11))
                                .foregroundStyle(T.fgDim)
                        }
                    }
                }
                // Spotlight target for the replay walkthrough's step ①, where the
                // host list is populated so the empty-state CTA isn't rendered.
                .onboardingAnchor(.addHost, if: !hosts.isEmpty)
            }
            .padding(.top, isPhone ? 14 : 28)
            .padding(.bottom, isPhone ? 14 : 24)
            .padding(.horizontal, isPhone ? 18 : 40)

            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private var quickConnectRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(T.fgMuted)

            TextField(searchPlaceholder, text: $search)
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fg)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    let value = search.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.contains("@") else { return }

                    onQuickConnect(value)
                    search = ""
                }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        }
        .padding(.top, isPhone ? 14 : 20)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("recent")

            LazyVGrid(columns: recentColumns, spacing: 12) {
                ForEach(Array(hosts.prefix(3))) { host in
                    HostCard(
                        host: host,
                        isActive: activeHostKeys.contains(host.connectionKey),
                        activeSessionUsesTmux: activeHostTmuxUsage[host.id],
                        onOpen: {
                            onConnect(host)
                        },
                        onEdit: isPhone ? {
                            onEdit(host)
                        } : nil,
                        onDelete: isPhone ? {
                            pendingRemovalHost = host
                        } : nil
                    )
                }
            }
            .padding(.top, 12)
        }
        .padding(.top, isPhone ? 22 : 28)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var allHostsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("all hosts · \(filteredHosts.count)")
                .padding(.bottom, 12)

            if isPhone {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredHosts) { host in
                        CompactHostRow(
                            host: host,
                            isActive: activeHostKeys.contains(host.connectionKey),
                            onConnect: onConnect,
                            onEdit: onEdit,
                            onDelete: { pendingRemovalHost = $0 }
                        )
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    hostTableHeader

                    ForEach(filteredHosts) { host in
                        HostRow(host: host, onConnect: onConnect, onEdit: onEdit)
                    }
                }
            }
        }
        .accessibilityIdentifier("hosts-landing-page")
        .padding(.top, isPhone ? 26 : 32)
        .padding(.horizontal, isPhone ? 18 : 40)
        .padding(.bottom, isPhone ? 24 : 40)
    }

    private var recentColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 10),
            count: isPhone ? 2 : 3
        )
    }

    private var hostTableHeader: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: 24, alignment: .leading)
            headerCell("name")
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("address")
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("port")
                .frame(width: 80, alignment: .leading)
            headerCell("identity")
                .frame(width: 120, alignment: .leading)
            headerCell("last seen")
                .frame(width: 100, alignment: .leading)
            Text("")
                .frame(width: 28, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        // One case treatment for every header on this page — "RECENT" was
        // uppercased at its call site while "all hosts · N" stayed lowercase.
        Text(text)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgMuted)
            .kerning(0.4)
            .textCase(.uppercase)
    }

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 10))
            .foregroundStyle(T.fgMuted)
            .kerning(0.4)
            .lineLimit(1)
    }
}

private struct CompactHostRow: View {
    let host: PersistedHost
    let isActive: Bool
    let onConnect: (PersistedHost) -> Void
    let onEdit: (PersistedHost) -> Void
    let onDelete: (PersistedHost) -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(spacing: 11) {
            Button {
                onConnect(host)
            } label: {
                HStack(spacing: 11) {
                    ZStack(alignment: .topTrailing) {
                        OSBadge(osHint: host.osHint, size: 18)

                        if isActive {
                            StatusDot(color: T.green, pulse: true, size: 6)
                                .offset(x: 4, y: -4)
                        }
                    }
                    .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.name)
                            .font(Typography.tesseraMono(size: 13, weight: .medium))
                            .foregroundStyle(T.fg)
                            .lineLimit(1)

                        Text(endpoint)
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(host.port))
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgDim)
                        Text(host.transport == .mosh ? "mosh" : "ssh")
                            .font(Typography.tesseraMono(size: 10))
                            .foregroundStyle(T.fgDim)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onEdit(host)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("edit \(host.name)")
        }
        .frame(minHeight: 58)
        .contextMenu {
            Button("connect", systemImage: "terminal") {
                onConnect(host)
            }
            Button("edit…", systemImage: "pencil") {
                onEdit(host)
            }
            Button("remove…", systemImage: "trash", role: .destructive) {
                onDelete(host)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private var endpoint: String {
        let user = host.effectiveUser
        return user.isEmpty ? host.address : "\(user)@\(host.address)"
    }
}

private struct HostRow: View {
    let host: PersistedHost
    let onConnect: (PersistedHost) -> Void
    let onEdit: (PersistedHost) -> Void

    @Environment(\.designTokens) private var T
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                OSBadge(osHint: host.osHint, size: 16)
                    .frame(width: 24, alignment: .leading)

                Text(host.name)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                rowText(host.address, color: T.fgMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                rowText(String(host.port), color: T.fgDim)
                    .frame(width: 80, alignment: .leading)

                rowText(host.identity?.name ?? "—", color: T.fgDim)
                    .frame(width: 120, alignment: .leading)

                rowText("—", color: T.fgDim)
                    .frame(width: 100, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onConnect(host)
            }

            Button {
                onEdit(host)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(hover ? hoverTint : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private var hoverTint: Color {
        T.isLight ? Color.black.opacity(0.03) : Color.white.opacity(0.03)
    }

    private func rowText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 12))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
