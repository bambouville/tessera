import SwiftUI
import PortForwarding

/// Compact `⇄ N` chip that lives in the `SessionTopBar` between the
/// find/magnifying-glass button and the trailing home button. Reads
/// the active session's `PortForwarderManager` and:
///   - hides itself when the manager has zero rules (no chrome wasted
///     when forwarding isn't in use for this host)
///   - shows `⇄ N` accent-soft when listening (no in-flight conns)
///   - shows `⇄ N` accent-fill when at least one connection is in flight
///   - flips to amber `⇄ !` when any rule is in `.error`
///
/// Tap → bottom sheet popover with per-rule controls (open in safari,
/// pause). Sheet is non-modal — the user can dismiss and keep typing.
struct ForwardingStatusChip: View {
    let manager: PortForwarderManager
    let scale: CGFloat
    let T: DesignTokens

    @State private var sheetVisible = false

    var body: some View {
        if !manager.forwarders.isEmpty {
            chipButton
                .sheet(isPresented: $sheetVisible) {
                    ForwardingStatusSheet(manager: manager)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
        }
    }

    @ViewBuilder
    private var chipButton: some View {
        let isError = manager.hasError
        let count = manager.runningCount
        let active = manager.activeConnectionCount > 0

        Button { sheetVisible = true } label: {
            HStack(spacing: 5 * scale) {
                Text("\u{21C4}")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(isError ? T.amber : T.accent)
                Text(isError ? "!" : String(count))
                    .font(Typography.tesseraMono(size: 11 * scale, weight: .medium))
                    .foregroundStyle(T.fg)
            }
            .padding(.horizontal, 9 * scale)
            .frame(height: 22 * scale)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isError ? T.amber.opacity(0.10) : (active ? T.accentSoft : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isError ? T.amber.opacity(0.35) : T.accent.opacity(active ? 0.30 : 0.20), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bottom sheet shown when the user taps the chip. Lists every rule
/// in the manager with its bytes / active-connection count and a
/// `pause` toggle. HTTP-ish ports also get an `↗ open in safari`
/// button that opens `http://localhost:<localPort>/`.
private struct ForwardingStatusSheet: View {
    let manager: PortForwarderManager
    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var sortedForwarders: [PortForwarder] {
        manager.forwarders.values.sorted { $0.rule.localPort < $1.rule.localPort }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("active tunnels")
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(T.fg)
                Spacer()
                Button("close") { dismiss() }
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.accent)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sortedForwarders) { forwarder in
                        forwarderRow(forwarder)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .background(T.bg)
    }

    @ViewBuilder
    private func forwarderRow(_ forwarder: PortForwarder) -> some View {
        let rule = forwarder.rule

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusDot(for: forwarder)
                Text(String(rule.localPort))
                    .font(Typography.tesseraMono(size: 13, weight: .semibold))
                    .foregroundStyle(T.accent)
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
                Spacer()
            }

            Text(statusText(for: forwarder))
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(statusColor(for: forwarder))

            HStack(spacing: 6) {
                if isHTTPPort(rule.localPort) {
                    Btn("\u{2197} open in safari", style: .primary, compact: true) {
                        if let url = URL(string: "http://localhost:\(rule.localPort)/") {
                            openURL(url)
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(12)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
    }

    @ViewBuilder
    private func statusDot(for forwarder: PortForwarder) -> some View {
        let color: Color = {
            switch forwarder.state {
            case .active: return T.accent
            case .listening: return T.accent.opacity(0.7)
            case .idle: return T.fgFaint
            case .error: return T.amber
            }
        }()
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private func statusText(for forwarder: PortForwarder) -> String {
        switch forwarder.state {
        case .idle: return "idle"
        case .listening: return "listening · 0 active"
        case .active(let n): return "\u{2191} \(byteString(forwarder.bytesUp))   \u{2193} \(byteString(forwarder.bytesDown))   ·   \(n) active"
        case .error(let reason): return reason
        }
    }

    private func statusColor(for forwarder: PortForwarder) -> Color {
        if case .error = forwarder.state { return T.amber }
        return T.fgMuted
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
        // Skip well-known non-HTTP ports — postgres, mysql, redis, mongo,
        // memcached, ssh — where http://localhost:<port>/ would just 404.
        let nonHTTP: Set<UInt16> = [22, 5432, 3306, 6379, 27017, 11211, 25, 110, 143]
        return !nonHTTP.contains(p)
    }
}
