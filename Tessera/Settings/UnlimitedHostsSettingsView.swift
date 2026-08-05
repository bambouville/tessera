// Tessera/Settings/UnlimitedHostsSettingsView.swift
import SwiftData
import SwiftUI

/// Settings → unlimited hosts. The one place purchase, status, retry, and
/// restore UI always lives, reachable without first hitting the free limit.
/// Purchase surfaces reuse the sheet's shared components from
/// UnlimitedHostsSheet.swift.
struct UnlimitedHostsSettingsView: View {
    @Environment(\.designTokens) private var T
    @Environment(HostAccessStore.self) private var store
    @Query(sort: \PersistedHost.name) private var hosts: [PersistedHost]

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsH("unlimited hosts")

            planCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // store.start() runs app-side; this only recovers a page opened
            // while the product is in the unavailable state.
            if store.isProductUnavailable {
                Task { await store.retryLoad() }
            }
        }
    }

    // MARK: - Plan card

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("your access")
                .font(Typography.kicker)
                .tracking(0.6)
                .foregroundStyle(T.fgDim)
                .textCase(.uppercase)

            planTitleRow
                .padding(.top, 10)

            if let copy = planCopy {
                Text(copy)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            featureList
                .padding(.top, 17)

            switch store.accessState {
            case .checking:
                recoveryBlock
                    .padding(.top, 17)
            case .free:
                purchaseBlock
                    .padding(.top, 17)
            case .unlimited(let source):
                statusBox(copy: statusCopy(for: source))
                    .padding(.top, 14)
            }
        }
        .padding(18)
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(T.border, lineWidth: 1)
        )
    }

    private var planTitleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                planTitleText
                Spacer(minLength: 8)
                planStatusText
            }

            VStack(alignment: .leading, spacing: 4) {
                planTitleText
                planStatusText
            }
        }
    }

    private var planTitleText: some View {
        Text(planTitle)
            .font(Typography.tesseraMono(size: 16, weight: .medium))
            .foregroundStyle(T.fg)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var planStatusText: some View {
        if let status = planStatus {
            Text(status)
                .font(Typography.tesseraMono(size: 11, weight: .semibold))
                .foregroundStyle(T.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planTitle: String {
        switch store.accessState {
        case .checking:
            return "checking…"
        case .free:
            return "free · 1 saved host"
        case .unlimited:
            return "unlimited hosts"
        }
    }

    private var planStatus: String? {
        switch store.accessState {
        case .checking:
            return nil
        case .free:
            return "\(hosts.count) of 1 saved"
        case .unlimited(let source):
            switch source {
            case .legacyPaid: return "included"
            case .purchasedIAP: return "active"
            }
        }
    }

    /// Plain muted copy shown under the title for the free and checking
    /// states. Legacy/purchased copy lives in the accent status box instead.
    private var planCopy: String? {
        switch store.accessState {
        case .checking:
            return "checking the app store for product and purchase status…"
        case .free:
            return "ssh, mosh, tmux, files, forwarding, and every other tessera feature are included. the one-time purchase changes only how many hosts tessera remembers."
        case .unlimited:
            return nil
        }
    }

    private func statusCopy(for source: HostUnlimitedSource) -> String {
        switch source {
        case .legacyPaid:
            return "unlimited hosts are included with your original paid tessera purchase. thank you for supporting the app early."
        case .purchasedIAP:
            return "unlimited saved hosts are active on this apple account and available on your iphone and ipad."
        }
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 8) {
                featureRow("features on every allowed host", value: "included")
                featureRow("iphone + ipad", value: "included")
                featureRow("subscription or tessera account", value: "never")
            }
            .padding(.vertical, 14)

            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)
        }
    }

    private func featureRow(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                featureTitle(title)
                Spacer(minLength: 8)
                featureValue(value)
            }

            VStack(alignment: .leading, spacing: 3) {
                featureTitle(title)
                featureValue(value)
            }
        }
    }

    private func featureTitle(_ title: String) -> some View {
        Text(title)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fg)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func featureValue(_ value: String) -> some View {
        Text(value)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.green)
    }

    private func statusBox(copy: String) -> some View {
        Text(copy)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Purchase block (free state only)

    private var recoveryBlock: some View {
        VStack(spacing: 12) {
            if let noteKind = UnlimitedHostsStateNote.kind(for: store) {
                UnlimitedHostsStateNote(
                    kind: noteKind,
                    onRetry: retryStoreLoad
                )
            }

            UnlimitedHostsRestoreLink()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var purchaseBlock: some View {
        VStack(spacing: 12) {
            if let noteKind = UnlimitedHostsStateNote.kind(for: store) {
                UnlimitedHostsStateNote(
                    kind: noteKind,
                    onRetry: noteKind == .error ? retryStoreLoad : nil
                )
            }

            UnlimitedHostsPurchaseButton()

            UnlimitedHostsRestoreLink()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func retryStoreLoad() {
        Task { await store.retryLoad() }
    }
}
