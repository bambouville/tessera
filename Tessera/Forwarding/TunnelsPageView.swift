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
/// enabled, jumps to host editor via the chevron, opens HTTP-ish ports
/// in Safari while running. Hosts with zero rules don't render.
struct TunnelsPageView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.designTokens) private var T
    @Environment(\.openURL) private var openURL
    @Environment(TunnelsRegistry.self) private var registry

    @Query(sort: [SortDescriptor<PersistedHost>(\.sortOrder)])
    private var allHosts: [PersistedHost]

    /// Selected host id → flips the parent ContentView's `selectedItem`
    /// to the matching host editor when the user taps the chevron.
    let onEditHost: (PersistedHost) -> Void

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
                    .font(Typography.tesseraMono(size: 17, weight: .medium))
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

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(String(rule.localPort))
                        .font(Typography.tesseraMono(size: 13, weight: .semibold))
                        .foregroundStyle(group.isConnected && rule.enabled ? T.accent : T.fgMuted)
                    Text(" → ")
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fgDim)
                    Text(verbatim: "\(rule.remoteHost):\(rule.remotePort)")
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fg)
                    if !rule.label.isEmpty {
                        Text("  \"\(rule.label)\"")
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.fgMuted)
                    }
                }
                Text(subStatusText(rule: rule, runtime: runtimeState, group: group))
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(subStatusColor(runtime: runtimeState))
            }

            Spacer()

            if isRunning && isHTTPPort(rule.localPort) {
                Button {
                    if let url = URL(string: "http://localhost:\(rule.localPort)/") {
                        openURL(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(T.accent)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }

            Button {
                onEditHost(group.host)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(for: rule, in: group))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(T.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
            case .listening: return "listening · 0 active"
            case .idle: return "idle"
            case .error(let reason): return reason
            }
        }
        if !rule.enabled { return "disabled" }
        if !group.isConnected { return "host not connected" }
        return "idle"
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

    private func isHTTPPort(_ p: UInt16) -> Bool {
        let nonHTTP: Set<UInt16> = [22, 5432, 3306, 6379, 27017, 11211, 25, 110, 143]
        return !nonHTTP.contains(p)
    }
}
