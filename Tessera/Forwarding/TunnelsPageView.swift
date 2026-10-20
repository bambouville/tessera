import SwiftUI
import SwiftData
import PortForwarding

/// Global Tunnels view, mounted at `SidebarItem.tunnels` in ContentView.
/// Projects every host's defined `[PortForwardRule]` (from SwiftData)
/// crossed with the currently-live `PortForwarderManager` instances
/// (from `TunnelsRegistry`), so the user can see and control all
/// forwarding rules without bouncing through individual host editors.
///
/// Layout: rules grouped by host, connected hosts on top with a green
/// dot, disconnected hosts below with a muted dot. Each row toggles
/// enabled, jumps to host editor via the chevron, and — while the rule is
/// running and the shared policy says a page can be there — opens the
/// forwarded port in the in-app browser. Hosts with zero rules don't render.
struct TunnelsPageView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.designTokens) private var T
    @Environment(TunnelsRegistry.self) private var registry
    @Environment(AppPhase.self) private var appPhase

    @Query(sort: [SortDescriptor<PersistedHost>(\.sortOrder)])
    private var allHosts: [PersistedHost]

    /// Selected host id → flips the parent ContentView's `selectedItem`
    /// to the matching host editor when the user taps the chevron.
    let onEditHost: (PersistedHost) -> Void

    /// The tunnel the in-app browser is showing, if any.
    @State private var browsing: BrowsedTunnel?

    /// Identified by its rule so `fullScreenCover(item:)` rebuilds the browser
    /// when the user closes one tunnel's page and opens another's.
    private struct BrowsedTunnel: Identifiable {
        let id: UUID
        let target: ForwardedWebTarget
        let label: String
    }

    private struct ServiceMonitorKey: Equatable {
        let managers: Set<ObjectIdentifier>
        let appActive: Bool
    }

    private struct HostGroup: Identifiable {
        let host: PersistedHost
        let rules: [PortForwardRule]
        let manager: PortForwarderManager?
        var isConnected: Bool { manager != nil }
        var id: UUID { host.id }
    }

    private var groups: [HostGroup] {
        let raw = allHosts.compactMap { host -> HostGroup? in
            let rules = RuleCodec.decode(host.portForwardRulesData)
            guard !rules.isEmpty else { return nil }
            return HostGroup(
                host: host,
                rules: rules,
                manager: registry.manager(for: host.id)
            )
        }
        return raw.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.host.name.localizedCaseInsensitiveCompare(rhs.host.name) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("tunnels")
                    .font(Typography.pageTitle)
                    .foregroundStyle(T.fg)
                Text("all forwarding rules across your hosts.")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                    .padding(.bottom, 12)

                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        groupSection(group)
                            .padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.bg)
        // Every connected host's rows say whether anything answers behind
        // them, so this page looks for as long as it is showing and the app
        // is in front — tunnels keep running in the background, looks don't.
        .task(id: ServiceMonitorKey(
            managers: Set(registry.managers.values.map(ObjectIdentifier.init)),
            appActive: appPhase.isActive
        )) {
            guard appPhase.isActive else { return }
            await withTaskGroup(of: Void.self) { group in
                for manager in registry.managers.values {
                    group.addTask { await manager.monitorServices() }
                }
            }
        }
        .fullScreenCover(item: $browsing) { tunnel in
            TunnelWebBrowserView(target: tunnel.target, ruleLabel: tunnel.label)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("no tunnels yet")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fg)
            Text("open a host's editor → forwarding tab to add a rule. tunnels start automatically when you connect.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
    }

    @ViewBuilder
    private func groupSection(_ group: HostGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Rectangle().fill(T.border).frame(height: 1)
                Text(group.host.name)
                    .font(Typography.tesseraMono(size: 11, weight: .medium))
                    .foregroundStyle(group.isConnected ? T.fg : T.fgMuted)
                Circle()
                    .fill(group.isConnected ? T.green : T.fgFaint)
                    .frame(width: 6, height: 6)
                Text(group.isConnected ? "connected" : "disconnected")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                Rectangle().fill(T.border).frame(height: 1)
            }
            .padding(.top, 4)

            ForEach(group.rules) { rule in
                ruleRow(rule, in: group)
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: PortForwardRule, in group: HostGroup) -> some View {
        let runtimeState = group.manager?.forwarders[rule.id]?.state
        let isRunning: Bool = {
            guard let s = runtimeState else { return false }
            switch s {
            case .listening, .active: return true
            default: return false
            }
        }()

        // spacing 0 — the trailing buttons carry 44pt hit frames that
        // absorb the old 12pt gaps (glyph centers drift <= 2pt).
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(String(rule.bind.port))
                        .font(Typography.tesseraMono(size: 13, weight: .semibold))
                        .foregroundStyle(group.isConnected && rule.enabled ? T.accent : T.fgMuted)
                    Text(verbatim: " → ")
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fgDim)
                    Text(verbatim: rule.targetDisplayText)
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fg)
                    if !rule.label.isEmpty {
                        Text(verbatim: "  \"\(rule.label)\"")
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.fgMuted)
                    }
                }
                Text(subStatusText(rule: rule, runtime: runtimeState, group: group))
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(subStatusColor(runtime: runtimeState))
            }

            Spacer(minLength: 12)

            // One heuristic for "is there a page here", shared with Android
            // and with the session bar's tunnel sheet; this view used to keep
            // a second copy of the port list.
            if isRunning, let target = ForwardedWebPolicy.webTarget(for: rule) {
                Button {
                    browsing = BrowsedTunnel(id: rule.id, target: target, label: rule.label)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(T.accent)
                        // 28pt visual box inside a 44pt hit frame. Must not
                        // shrink below 44pt: iPadOS 26 expands sub-44pt
                        // targets itself and mis-assigns taps between
                        // adjacent small controls.
                        .frame(width: 28, height: 28)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                onEditHost(group.host)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T.fgMuted)
                    // 28pt visual box inside a 44pt hit frame (see above).
                    .frame(width: 28, height: 28)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(for: rule, in: group))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(T.accent)
                // 2pt + the chevron frame's 8pt overhang ≈ the old 12pt gap.
                .padding(.leading, 2)
        }
        .padding(.horizontal, 14)
        // 6pt + the 44pt hit frames keeps the old ~56pt card height.
        .padding(.vertical, 6)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
    }

    private func subStatusText(rule: PortForwardRule, runtime: PortForwarder.State?, group: HostGroup) -> String {
        if let runtime {
            switch runtime {
            case .active(let n):
                let f = group.manager?.forwarders[rule.id]
                return "\u{2191} \(byteString(f?.bytesUp ?? 0))   \u{2193} \(byteString(f?.bytesDown ?? 0))   ·   \(n) active"
            case .listening:
                return group.manager?.forwarders[rule.id]?.listeningStatusText
                    ?? String(localized: "listening · 0 active")
            case .idle: return String(localized: "idle")
            case .error(let reason): return reason
            }
        }
        if !rule.enabled { return String(localized: "disabled") }
        if !group.isConnected { return String(localized: "host not connected") }
        return String(localized: "idle")
    }

    private func subStatusColor(runtime: PortForwarder.State?) -> Color {
        if case .error = runtime { return T.amber }
        return T.fgDim
    }

    private func enabledBinding(for rule: PortForwardRule, in group: HostGroup) -> Binding<Bool> {
        Binding(
            get: { group.rules.first(where: { $0.id == rule.id })?.enabled ?? rule.enabled },
            set: { newValue in
                var next = group.rules
                guard let i = next.firstIndex(where: { $0.id == rule.id }) else { return }
                next[i].enabled = newValue
                group.host.setPortForwardRules(next)
                try? modelContext.save()
                let hostID = group.host.id
                Task {
                    if let manager = registry.manager(for: hostID) {
                        await manager.reconcile(newRules: next)
                    }
                }
            }
        )
    }

    private func byteString(_ n: UInt64) -> String {
        let units: [(UInt64, String)] = [
            (1024 * 1024 * 1024, "GB"),
            (1024 * 1024, "MB"),
            (1024, "KB"),
        ]
        for (threshold, suffix) in units where n >= threshold {
            let scaled = Double(n) / Double(threshold)
            return String(format: "%.1f %@", scaled, suffix)
        }
        return "\(n) B"
    }
}
