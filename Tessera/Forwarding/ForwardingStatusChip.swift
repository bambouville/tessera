import SwiftUI
import PortForwarding

/// Compact `⇄ N` chip that lives in the `SessionTopBar` between the
/// find/magnifying-glass button and the trailing home button. Reads
/// the active session's `PortForwarderManager` and:
///   - hides itself when the manager has zero rules (no chrome wasted
///     when forwarding isn't in use for this host)
///   - shows `⇄ N` with N listeners; the glyph is green while something
///     answers behind at least one of them, muted while nothing does
///   - fills accent-soft when at least one connection is in flight
///   - flips to amber `⇄ !` when any rule is in `.error`
///
/// Tap → bottom sheet popover with per-rule controls (open the tunnel in the
/// in-app browser, or hand it to Safari). Sheet is non-modal — the user can
/// dismiss and keep typing.
struct ForwardingStatusChip: View {
    let manager: PortForwarderManager
    let scale: CGFloat
    let T: DesignTokens
    /// Whether this chip looks at what answers behind its tunnels: only while
    /// its session is the one on screen and the app is in front, since each
    /// look is a real connection to the target.
    var monitorsServices = true

    @State private var sheetVisible = false

    var body: some View {
        if !manager.forwarders.isEmpty {
            chipButton
                .task(id: monitorsServices) {
                    guard monitorsServices else { return }
                    await manager.monitorServices()
                }
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
        let serving = manager.servingCount > 0

        Button { sheetVisible = true } label: {
            HStack(spacing: 5 * scale) {
                Text(verbatim: "\u{21C4}")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(isError ? T.amber : (serving ? T.green : T.fgMuted))
                Text(isError ? "!" : String(count))
                    .font(Typography.tesseraMono(size: 11 * scale, weight: .medium))
                    .foregroundStyle(T.fg)
            }
            // Label-level cap only: the status sheet presents from this
            // button and must keep unrestricted text scaling.
            .chromeBarTextCap()
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
            // Full-pitch hit frame: the scaled bar can't fit 44pt without
            // moving glyphs (iPadOS 26 expands sub-44pt targets itself and
            // mis-assigns taps between adjacent small controls), so absorb
            // the bar's 8pt-scaled gaps (4 each side) and fill the bar
            // height instead — capped at the bar, not the terminal below.
            .padding(.horizontal, 4 * scale)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(forwardingServiceSummary(manager))
    }
}

/// The glyph's colour as words, for VoiceOver and for the UI tests that
/// cannot read a colour.
@MainActor
private func forwardingServiceSummary(_ manager: PortForwarderManager) -> String {
    if manager.hasError { return String(localized: "error") }
    return manager.servingCount > 0
        ? String(localized: "serving")
        : String(localized: "nothing serving")
}

/// Phone toolbar action for sessions that actually have forwarding entries.
/// Like the iPad count chip, it stays out of the compact top bar when the
/// manager is empty. The sheet is read-only for *editing*: tunnel creation and
/// editing stay on iPad, while opening a tunnel in the in-app browser is full
/// parity — a phone is where a terminal has the least room to render a page.
struct CompactForwardingStatusButton: View {
    let manager: PortForwarderManager?
    let T: DesignTokens
    /// See `ForwardingStatusChip.monitorsServices`.
    var monitorsServices = true

    @State private var sheetVisible = false

    var body: some View {
        if let manager, !manager.forwarders.isEmpty {
            Button { sheetVisible = true } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(buttonTint)
                    // 38pt visual box inside the compact bar's full 40pt
                    // button pitch (44pt doesn't fit; iPadOS 26 expands
                    // sub-44pt targets itself and mis-assigns taps between
                    // adjacent small controls).
                    .frame(width: 38, height: 44)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Active tunnels")
            .accessibilityValue(forwardingServiceSummary(manager))
            .task(id: monitorsServices) {
                guard monitorsServices else { return }
                await manager.monitorServices()
            }
            .sheet(isPresented: $sheetVisible) {
                ForwardingStatusSheet(manager: manager, readOnly: true)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var buttonTint: Color {
        guard let manager else { return T.fgMuted }
        if manager.hasError { return T.amber }
        return manager.servingCount > 0 ? T.green : T.fgMuted
    }
}

/// Bottom sheet shown when the user taps the chip. Lists every rule in the
/// manager with its bytes / active-connection count. A live tunnel the shared
/// policy calls browsable also gets `↗ open in browser`, which presents the
/// page inside Tessera, and a `safari` escape hatch for anything the in-app
/// browser cannot do (a downloaded file, a password autofill).
private struct ForwardingStatusSheet: View {
    let manager: PortForwarderManager?
    /// Whether rules can be created or edited from here. Opening a tunnel is
    /// not editing, so the browse actions stay available either way — the
    /// phone's sheet is where a tunnel is most useful to open, since the
    /// terminal beside it has the least room to show a page.
    var readOnly = false
    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    // Optional: the tunnel-browser harness presents this sheet without one.
    @Environment(ProgramStatusCenter.self) private var programStatusCenter: ProgramStatusCenter?

    @State private var browsing: BrowsingTunnel?
    @State private var programStatusCoverSource = UUID()

    private var sortedForwarders: [PortForwarder] {
        (manager?.forwarders.values.map { $0 } ?? [])
            .sorted { $0.rule.bind.port < $1.rule.bind.port }
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

            if sortedForwarders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("no active tunnels")
                        .font(Typography.tesseraMono(size: 13, weight: .medium))
                        .foregroundStyle(T.fg)
                    Text(
                        readOnly
                            ? "create and edit forwarding rules from iPad."
                            : "create and edit forwarding rules on the host's tunnels page."
                    )
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgMuted)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
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
        }
        .background(T.presentationBg)
        // The rows below say per tunnel what the glyph summarised; bring
        // them up to date rather than showing the last cadence's answer.
        .onAppear { manager?.probeServicesNow() }
        // The sheet and its browser cover the session's terminal, so its
        // finished and failed results stay unread until the sheet closes.
        .onAppear { programStatusCenter?.setApplicationCovered(true, source: programStatusCoverSource) }
        .onDisappear { programStatusCenter?.setApplicationCovered(false, source: programStatusCoverSource) }
        .fullScreenCover(item: $browsing) { tunnel in
            TunnelWebBrowserView(target: tunnel.target, ruleLabel: tunnel.label)
        }
    }

    @ViewBuilder
    private func forwarderRow(_ forwarder: PortForwarder) -> some View {
        let rule = forwarder.rule

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusDot(for: forwarder)
                Text(String(rule.bind.port))
                    .font(Typography.tesseraMono(size: 13, weight: .semibold))
                    .foregroundStyle(T.accent)
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
                Spacer()
            }

            Text(statusText(for: forwarder))
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(statusColor(for: forwarder))

            HStack(spacing: 6) {
                // A tunnel is only browsable while something is listening on
                // it; the shared policy answers the address, this answers the
                // liveness it deliberately does not hold.
                if isLive(forwarder), let target = ForwardedWebPolicy.webTarget(for: rule) {
                    Btn("\u{2197} open in browser", style: .primary, compact: true) {
                        browsing = BrowsingTunnel(
                            id: rule.id,
                            target: target,
                            label: rule.label
                        )
                    }
                    Btn("safari", compact: true) {
                        if let url = URL(string: target.url) { openURL(url) }
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
            case .active: return T.green
            case .listening:
                switch forwarder.service {
                case .serving: return T.green
                case .notServing: return T.fgFaint
                case .unknown: return T.accent.opacity(0.7)
                }
            case .idle: return T.fgFaint
            case .error: return T.amber
            }
        }()
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private func statusText(for forwarder: PortForwarder) -> String {
        switch forwarder.state {
        case .idle: return String(localized: "idle")
        case .listening: return forwarder.listeningStatusText
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

    private func isLive(_ forwarder: PortForwarder) -> Bool {
        switch forwarder.state {
        case .listening, .active: return true
        case .idle, .error: return false
        }
    }
}

/// The tunnel the in-app browser is currently showing. Identified by its rule
/// so `fullScreenCover(item:)` rebuilds the browser when the user closes one
/// tunnel's page and opens another's.
private struct BrowsingTunnel: Identifiable {
    let id: UUID
    let target: ForwardedWebTarget
    let label: String
}
