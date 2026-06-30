import NIOSSH
import SwiftUI
import UIKit

struct KnownHostsPageView: View {
    @Environment(\.designTokens) private var T

    @State private var rows: [KnownHostsStore.DisplayRow] = []
    @State private var filter: Filter = .all
    @State private var expandedIDs: Set<String> = []

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
        .task { await reload() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("known hosts")
                .font(Typography.tesseraMono(size: 24, weight: .medium))
                .foregroundStyle(T.fg)
                .lineLimit(1)

            Spacer()

            Btn("export", compact: true) {
            }

            Btn("import", compact: true) {
            }
        }
        .padding(.top, 28)
        .padding(.horizontal, 40)
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
        .padding(.vertical, 20)
        .padding(.horizontal, 40)
    }

    private var filterChips: some View {
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
        .padding(.vertical, 20)
        .padding(.horizontal, 40)
    }

    private var table: some View {
        VStack(spacing: 0) {
            tableHeader

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
                    tableRow(row)
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
        .padding(.horizontal, 40)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 20)

            Text("host")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("algo")
                .frame(width: 90, alignment: .leading)

            Text("added")
                .frame(width: 140, alignment: .leading)

            Text("status")
                .frame(width: 110, alignment: .leading)

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

            Tag(text: row.algorithm)
                .frame(width: 90, alignment: .leading)

            Text(formatDate(row.firstSeen))
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgDim)
                .frame(width: 140, alignment: .leading)

            Text(statusLabel(row.status))
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(statusColor(row.status))
                .frame(width: 110, alignment: .leading)

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

            HStack(spacing: 8) {
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
            .padding(.top, 4)
        }
        .padding(.top, 16)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBgSoft)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
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
