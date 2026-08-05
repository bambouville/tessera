import NIOSSH
import SwiftUI
import UIKit

struct KnownHostsPageView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var rows: [KnownHostsStore.DisplayRow] = []
    @State private var filter: Filter = .all
    @State private var expandedIDs: Set<String> = []

    // The table cells render Dynamic-Type-scaling mono text; scale the fixed
    // column widths with it so larger text sizes don't wrap or collide.
    @ScaledMetric(relativeTo: .body) private var algoColumnWidth: CGFloat = 90
    @ScaledMetric(relativeTo: .body) private var addedColumnWidth: CGFloat = 140
    @ScaledMetric(relativeTo: .body) private var statusColumnWidth: CGFloat = 110

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The desktop table's fixed columns total 340pt at default text size and
    /// scale with Dynamic Type (@ScaledMetric below) — at accessibility sizes
    /// they would consume the whole viewport on iPad portrait / Split View,
    /// collapsing the flexible host column. Fall back to the stacked compact
    /// row there; it has no fixed columns.
    private var usesCompactRows: Bool {
        isPhone || dynamicTypeSize.isAccessibilitySize
    }

    private enum Filter {
        case all
        case ok
        case stale
        case changed
    }

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if changedCount > 0 {
                        mismatchBanner
                    }

                    filterChips
                    table
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 40)
            }
        }
        .accessibilityIdentifier("known-hosts-page")
        .task { await reload() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("known hosts")
                .font(Typography.pageTitle)
                .foregroundStyle(T.fg)
                .lineLimit(1)

            Spacer()

            if !isPhone {
                Btn("export", compact: true) {
                }

                Btn("import", compact: true) {
                }
            }
        }
        .padding(.top, isPhone ? 14 : 28)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var mismatchBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusDot(color: T.red)

            Text(mismatchMessage)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(T.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(T.red.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, isPhone ? 14 : 20)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Chip(text: "all · \(rows.count)", selected: filter == .all) {
                    filter = .all
                }
                Chip(text: "verified", selected: filter == .ok) {
                    filter = .ok
                }
                Chip(text: "stale", selected: filter == .stale) {
                    filter = .stale
                }
                Chip(text: "changed", selected: filter == .changed) {
                    filter = .changed
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, isPhone ? 14 : 20)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var table: some View {
        VStack(spacing: 0) {
            if !usesCompactRows {
                tableHeader
            }

            ForEach(filteredRows) { row in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        if expandedIDs.contains(row.id) {
                            expandedIDs.remove(row.id)
                        } else {
                            expandedIDs.insert(row.id)
                        }
                    }
                } label: {
                    if usesCompactRows {
                        compactTableRow(row)
                    } else {
                        tableRow(row)
                    }
                }
                .buttonStyle(.plain)

                if expandedIDs.contains(row.id) {
                    expandedDetail(row)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }
            }
        }
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 20)

            Text("host")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("algo")
                .frame(width: algoColumnWidth, alignment: .leading)

            Text("added")
                .frame(width: addedColumnWidth, alignment: .leading)

            Text("status")
                .frame(width: statusColumnWidth, alignment: .leading)

            Color.clear
                .frame(width: 28)
        }
        .font(Typography.tesseraMono(size: 10))
        .foregroundStyle(T.fgMuted)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private func tableRow(_ row: KnownHostsStore.DisplayRow) -> some View {
        HStack(spacing: 0) {
            StatusDot(color: statusColor(row.status))
                .frame(width: 20, alignment: .leading)

            Text(row.host)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fg)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if row.matchedPeerLabel != nil {
                Tag(text: "matched peer", color: T.green.opacity(0.12))
                    .padding(.trailing, 8)
            }

            Tag(text: row.algorithm)
                .frame(width: algoColumnWidth, alignment: .leading)

            Text(formatDate(row.firstSeen))
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgDim)
                .frame(width: addedColumnWidth, alignment: .leading)

            Text(statusLabel(row.status))
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(statusColor(row.status))
                .frame(width: statusColumnWidth, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(T.fgMuted)
                .rotationEffect(.degrees(expandedIDs.contains(row.id) ? 90 : 0))
                .frame(width: 28, alignment: .center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(row.status == .changed ? T.red.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private func compactTableRow(_ row: KnownHostsStore.DisplayRow) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor(row.status))

            VStack(alignment: .leading, spacing: 4) {
                Text(row.host)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    Tag(text: row.algorithm)

                    if row.matchedPeerLabel != nil {
                        Tag(text: "matched peer", color: T.green.opacity(0.12))
                    }

                    Text("added \(formatDate(row.firstSeen))")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(statusLabel(row.status))
                .font(Typography.tesseraMono(size: 10, weight: .medium))
                .foregroundStyle(statusColor(row.status))

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(T.fgMuted)
                .rotationEffect(.degrees(expandedIDs.contains(row.id) ? 90 : 0))
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .background(row.status == .changed ? T.red.opacity(0.04) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private func expandedDetail(_ row: KnownHostsStore.DisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.status == .changed {
                Text("⚠ remote host identification has changed. man-in-the-middle attack, or server key was rotated.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(T.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 4)
            }

            fingerprintLine(
                label: "current fingerprint: ",
                value: row.fingerprint,
                valueColor: T.fg
            )

            if let peer = row.matchedPeerLabel {
                Text("matched \(peer) at trust time")
                    .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                    .foregroundStyle(T.green)
            }

            if let previousFingerprint = row.previousFingerprint {
                fingerprintLine(
                    label: "previous fingerprint: ",
                    value: previousFingerprint,
                    valueColor: T.fgDim
                )
            }

            if let pendingFingerprint = row.pendingFingerprint, row.status == .changed {
                fingerprintLine(
                    label: "new fingerprint: ",
                    value: pendingFingerprint,
                    valueColor: T.fg
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    expandedActions(row)
                }

                VStack(alignment: .leading, spacing: 8) {
                    expandedActions(row)
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 16)
        .padding(.trailing, isPhone ? 12 : 20)
        .padding(.bottom, 20)
        .padding(.leading, isPhone ? 12 : 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBgSoft)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func expandedActions(_ row: KnownHostsStore.DisplayRow) -> some View {
        Btn("copy fingerprint", compact: true) {
            UIPasteboard.general.string = row.fingerprint
        }

        if row.status == .changed {
            Btn("accept new key", style: .primary, compact: true) {
                Task { await acceptNewKey(row) }
            }
        }

        Btn("remove", style: .danger, compact: true) {
            Task { await remove(row) }
        }
    }

    private func fingerprintLine(label: String, value: String, valueColor: Color) -> some View {
        (Text(label)
            .foregroundColor(T.fgMuted)
        + Text(value)
            .foregroundColor(valueColor))
            .font(Typography.tesseraMono(size: 11))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var filteredRows: [KnownHostsStore.DisplayRow] {
        switch filter {
        case .all:
            rows
        case .ok:
            rows.filter { $0.status == .ok }
        case .stale:
            rows.filter { $0.status == .stale }
        case .changed:
            rows.filter { $0.status == .changed }
        }
    }

    private var changedCount: Int {
        rows.filter { $0.status == .changed }.count
    }

    private var mismatchMessage: String {
        let verb = changedCount == 1 ? "has" : "have"
        let keyLabel = changedCount == 1 ? "host key" : "host keys"
        return "\(changedCount) \(keyLabel) \(verb) changed since last connect — review before reconnecting"
    }

    private func statusColor(_ status: KnownHostsStore.HostStatus) -> Color {
        switch status {
        case .ok:
            return T.green
        case .stale:
            return T.amber
        case .changed:
            return T.red
        }
    }

    private func statusLabel(_ status: KnownHostsStore.HostStatus) -> String {
        switch status {
        case .ok:
            return "verified"
        case .stale:
            return "stale"
        case .changed:
            return "MISMATCH"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @MainActor
    private func reload() async {
        rows = await KnownHostsStore.shared.list()
        let liveIDs = Set(rows.map(\.id))
        expandedIDs.formIntersection(liveIDs)
    }

    @MainActor
    private func acceptNewKey(_ row: KnownHostsStore.DisplayRow) async {
        guard let keyString = row.pendingKeyString else { return }

        do {
            let key = try NIOSSHPublicKey(openSSHPublicKey: keyString)
            await KnownHostsStore.shared.trust(key, for: row.id)
            await reload()
        } catch {
            DiagnosticLogStore.appendKnownHosts("accept-new-key failed error='\(error)'")
        }
    }

    @MainActor
    private func remove(_ row: KnownHostsStore.DisplayRow) async {
        await KnownHostsStore.shared.remove(endpoint: row.id)
        await reload()
    }
}
