// Tessera/Purchases/UnlimitedHostsSheet.swift
import SwiftUI
import UIKit

// Purchase UI for the "Unlimited Saved Hosts" non-consumable in the app's
// lowercase mono voice. All three surfaces read HostAccessStore
// from the environment; presentation, dismissal-after-purchase, and
// hasSeenUnlimitedHostsOffer bookkeeping are owned by the presenting
// coordinator, not these views.

// MARK: - Shared components (also used by UnlimitedHostsSettingsView)

/// Decorative 3×3 tile mosaic that heads the purchase sheet. Tiles 2, 4, and 8
/// (1-indexed) carry the accent.
struct UnlimitedHostsMosaic: View {
    @Environment(\.designTokens) private var T

    private let accentTiles: Set<Int> = [1, 3, 7]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accentTiles.contains(row * 3 + column) ? T.accent : T.fgFaint)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(10)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(T.border, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

/// Tinted status note driven by HostAccessStore state: muted while the product
/// loads, amber while a purchase awaits approval, red on error. The error note
/// is itself the retry target only when the product failed to LOAD — after a
/// failed purchase/restore attempt (product still loaded) the purchase button
/// becomes the retry ("try again · price") and this note stays
/// informational so the two controls never race different operations.
struct UnlimitedHostsStateNote: View {
    enum Kind {
        case loading, pending, error
    }

    let kind: Kind
    var onRetry: (() -> Void)?

    @Environment(HostAccessStore.self) private var store
    @Environment(\.designTokens) private var T

    /// Maps the store onto the at-most-one visible note. Pending wins over
    /// error, which wins over loading, so the most actionable state shows.
    @MainActor
    static func kind(for store: HostAccessStore) -> Kind? {
        if store.purchasePending { return .pending }
        if store.isProductUnavailable || store.lastErrorMessage != nil { return .error }
        if store.product == nil { return .loading }
        return nil
    }

    private var text: String {
        switch kind {
        case .loading:
            return "checking the app store for the localized product and price…"
        case .pending:
            return "waiting for approval. you can close this and keep using tessera."
        case .error:
            return "the app store could not complete the request. your saved host is unchanged."
        }
    }

    private var color: Color {
        switch kind {
        case .loading: return T.fgMuted
        case .pending: return T.amber
        case .error: return T.red
        }
    }

    private var fill: Color {
        switch kind {
        case .loading: return T.inputBg
        case .pending: return T.amber.opacity(0.12)
        case .error: return T.red.opacity(0.10)
        }
    }

    var body: some View {
        // Load failure (no product): the note is the retry, wired to
        // retryLoad(). Purchase/restore failure (product loaded): the note is
        // non-interactive — the purchase button carries "try again · price".
        if kind == .error,
           let onRetry,
           store.product == nil || store.accessState == .checking {
            Button(action: onRetry) {
                noteContent(showRetry: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(text))
            .accessibilityHint("double-tap to try again")
        } else {
            noteContent(showRetry: false)
        }
    }

    private func noteContent(showRetry: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showRetry {
                Text("try again")
                    .font(Typography.tesseraMono(size: 11, weight: .semibold))
                    .foregroundStyle(T.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Primary purchase button. Never renders a hard-coded price: the label takes
/// StoreKit's localized `displayPrice` and degrades to a price-less label while
/// the product is missing (which also disables the button). After a failed
/// purchase/restore attempt the button itself becomes the retry — "try again ·
/// price" — because tapping it re-runs purchase() and the store
/// clears the error at the start of the new attempt.
struct UnlimitedHostsPurchaseButton: View {
    @Environment(HostAccessStore.self) private var store
    @Environment(\.designTokens) private var T

    private var label: String {
        if store.accessState == .checking {
            return "checking purchase status"
        }
        if let product = store.product {
            if store.lastErrorMessage != nil {
                return "try again · \(product.displayPrice)"
            }
            return "unlock unlimited hosts · \(product.displayPrice)"
        }
        return "unlock unlimited hosts"
    }

    private var isDisabled: Bool {
        store.accessState != .free
            || store.purchaseInFlight
            || store.purchasePending
            || store.product == nil
    }

    var body: some View {
        Btn(style: .primary, full: true, action: { Task { await store.purchase() } }) {
            HStack(spacing: 8) {
                if store.purchaseInFlight {
                    ProgressView()
                        .controlSize(.small)
                        // Match Btn's primary foreground (white on light, black
                        // on dark) so the spinner reads against the filled button.
                        .tint(T.isLight ? .white : .black)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 24pt label + Btn's 2×10pt vertical padding = 44pt minimum target.
            .frame(maxWidth: .infinity, minHeight: 24)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(label)
    }
}

/// Accent link that runs an explicit restore (the only path allowed to call
/// AppStore.sync(), since it can prompt for App Store authentication).
struct UnlimitedHostsRestoreLink: View {
    @Environment(HostAccessStore.self) private var store
    @Environment(\.designTokens) private var T

    var body: some View {
        Button {
            Task { await store.restore() }
        } label: {
            Text("restore purchases")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.purchaseInFlight)
        .opacity(store.purchaseInFlight ? 0.45 : 1)
    }
}

// MARK: - Full explainer / purchase sheet

/// The one full purchase sheet. Shown at most once automatically (first
/// over-limit save attempt) and thereafter only on explicit request from the
/// limit notice or Settings. "not now" only dismisses; the parent observes the
/// store for the post-purchase transition and owns `hasSeenUnlimitedHostsOffer`.
struct UnlimitedHostsSheet: View {
    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(HostAccessStore.self) private var store

    init() {}

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 0) {
                        explainerContent
                        separator
                        purchaseFooter
                    }
                }
                .scrollIndicators(.visible)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        explainerContent
                    }
                    .scrollIndicators(.visible)

                    separator
                    purchaseFooter
                }
            }
        }
        .background(T.presentationBg)
        .presentationDetents(presentationDetents)
        .presentationContentInteraction(.scrolls)
    }

    private var explainerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 15) {
                    UnlimitedHostsMosaic()
                    heroContent
                }

                VStack(alignment: .leading, spacing: 12) {
                    UnlimitedHostsMosaic()
                    heroContent
                }
            }

            if store.accessState == .free {
                includedRows
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var heroContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.accessState == .checking ? "checking host access" : "save every host")
                .font(Typography.sheetTitle)
                .foregroundStyle(T.fg)

            Text(heroCopy)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            // StoreKit's localized product description, when loaded — no
            // placeholder while it is missing.
            if store.accessState == .free,
               let description = store.product?.productDescription,
               !description.isEmpty {
                Text(description)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var purchaseFooter: some View {
        VStack(spacing: 12) {
            if let noteKind = UnlimitedHostsStateNote.kind(for: store) {
                UnlimitedHostsStateNote(
                    kind: noteKind,
                    onRetry: noteKind == .error ? retryStoreLoad : nil
                )
            }

            if store.accessState == .free {
                UnlimitedHostsPurchaseButton()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    UnlimitedHostsRestoreLink()
                    notNowButton
                }

                VStack(spacing: 4) {
                    UnlimitedHostsRestoreLink()
                    notNowButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text(store.accessState == .checking
                 ? "tessera will not offer a purchase until existing access is confirmed. your saved hosts remain available."
                 : "payment is handled by the app store. your saved hosts remain unchanged if you cancel.")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(T.presentationBg)
    }

    private var notNowButton: some View {
        Button {
            dismiss()
        } label: {
            Text("not now")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var separator: some View {
        Rectangle()
            .fill(T.border)
            .frame(height: 0.5)
    }

    private var heroCopy: String {
        if store.accessState == .checking {
            return "tessera could not confirm your existing purchase status yet. retry or restore purchases before saving another host."
        }
        return "your free host is already saved. unlock unlimited saved hosts with one purchase — every tessera feature stays included either way."
    }

    private var presentationDetents: Set<PresentationDetent> {
        if UIDevice.current.userInterfaceIdiom == .phone
            || dynamicTypeSize.isAccessibilitySize {
            return [.large]
        }
        return [.height(560), .large]
    }

    private var includedRows: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 7) {
                checkRow {
                    // StoreKit's localized product name when loaded; the
                    // static lowercase copy stays as the pre-load fallback.
                    Text(store.product?.displayName ?? "unlimited saved hosts").foregroundStyle(T.fg)
                        + Text(" — the only paid upgrade").foregroundStyle(T.fgMuted)
                }
                checkRow {
                    Text("one purchase on your ").foregroundStyle(T.fgMuted)
                        + Text("iphone and ipad").foregroundStyle(T.fg)
                }
                checkRow {
                    Text("no subscription").foregroundStyle(T.fg)
                        + Text(" and no tessera account").foregroundStyle(T.fgMuted)
                }
            }
            .padding(.vertical, 13)

            Rectangle()
                .fill(T.border)
                .frame(height: 0.5)
        }
    }

    private func checkRow(_ text: () -> Text) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(T.green)

            text()
                .font(Typography.tesseraMono(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func retryStoreLoad() {
        Task { await store.retryLoad() }
    }
}

// MARK: - Compact repeat-visit limit notice

/// Small factual notice shown when a free customer who already dismissed the
/// full explainer tries to save another host. It never starts a purchase;
/// `view unlimited hosts` asks the parent to open the full sheet.
struct HostLimitNoticeSheet: View {
    let onViewOffer: () -> Void
    let onCancel: () -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 0) {
                        noticeContent
                        separator
                        noticeFooter
                    }
                }
                .scrollIndicators(.visible)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        noticeContent
                    }

                    separator
                    noticeFooter
                }
            }
        }
        .background(T.presentationBg)
        .presentationDetents(presentationDetents)
        .presentationContentInteraction(.scrolls)
    }

    private var noticeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("free tessera remembers one host")
                .font(Typography.tesseraMono(size: 14, weight: .medium))
                .foregroundStyle(T.fg)

            Text("your saved hosts are unchanged. edit an existing host, remove saved hosts until a slot is free, or view the one-time unlimited-hosts option.")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var noticeFooter: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    noticeButton("view unlimited hosts", isPrimary: true, action: onViewOffer)
                    noticeButton("cancel", isPrimary: false, action: onCancel)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        noticeButton("view unlimited hosts", isPrimary: true, action: onViewOffer)
                        noticeButton("cancel", isPrimary: false, action: onCancel)
                    }
                    VStack(spacing: 8) {
                        noticeButton("view unlimited hosts", isPrimary: true, action: onViewOffer)
                        noticeButton("cancel", isPrimary: false, action: onCancel)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(T.presentationBg)
    }

    private var separator: some View {
        Rectangle()
            .fill(T.border)
            .frame(height: 0.5)
    }

    private func noticeButton(_ title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.tesseraMono(size: 12, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(isPrimary ? T.accent : T.fg)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    minHeight: 44
                )
                .background(T.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isPrimary ? T.accent.opacity(0.38) : T.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private var presentationDetents: Set<PresentationDetent> {
        if UIDevice.current.userInterfaceIdiom == .phone
            || dynamicTypeSize.isAccessibilitySize {
            return [.large]
        }
        return [.height(280), .large]
    }
}

// MARK: - Nearby-setup quota decision

/// Shown while a nearby-setup import waits: the offered batch exceeds the free
/// one-host limit, so the recipient either keeps one route that fits, unlocks
/// unlimited hosts (which resumes the full import), or cancels the transfer.
struct BootstrapQuotaDecisionSheet: View {
    let plan: BootstrapImportPlan
    let remainingFreeSlots: Int
    let showsOfferInitially: Bool
    let onDecision: (BootstrapAdmissionResponse) -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(HostAccessStore.self) private var store
    @State private var showsOffer: Bool

    init(
        plan: BootstrapImportPlan,
        remainingFreeSlots: Int,
        showsOfferInitially: Bool = true,
        onDecision: @escaping (BootstrapAdmissionResponse) -> Void
    ) {
        self.plan = plan
        self.remainingFreeSlots = remainingFreeSlots
        self.showsOfferInitially = showsOfferInitially
        self.onDecision = onDecision
        _showsOffer = State(initialValue: showsOfferInitially)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 0) {
                        decisionContent
                        separator
                        decisionFooter
                    }
                }
                .scrollIndicators(.visible)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        decisionContent
                    }
                    .scrollIndicators(.visible)

                    separator
                    decisionFooter
                }
            }
        }
        .background(T.presentationBg)
        .presentationDetents(presentationDetents)
        .presentationContentInteraction(.scrolls)
        .onAppear {
            if showsOfferInitially {
                store.hasSeenUnlimitedHostsOffer = true
            }
            if case .unlimited = store.accessState {
                onDecision(.proceedFull)
            }
        }
        .onChange(of: store.accessState) { _, newState in
            if case .unlimited = newState {
                onDecision(.proceedFull)
            }
        }
    }

    private var decisionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("choose what to keep")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(T.fg)

                Text(explanationText)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.routes) { route in
                    routeRow(route)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var decisionFooter: some View {
        VStack(spacing: 12) {
            if showsOffer {
                if let noteKind = UnlimitedHostsStateNote.kind(for: store) {
                    UnlimitedHostsStateNote(
                        kind: noteKind,
                        onRetry: noteKind == .error ? retryStoreLoad : nil
                    )
                }

                UnlimitedHostsPurchaseButton()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        // A customer who already owns the IAP on another device
                        // resolves the quota here via restore; a successful
                        // restore flips accessState to .unlimited and the
                        // onChange above auto-decides .proceedFull.
                        UnlimitedHostsRestoreLink()
                        cancelTransferButton
                    }

                    VStack(spacing: 4) {
                        UnlimitedHostsRestoreLink()
                        cancelTransferButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Btn(style: .primary, full: true, action: {
                    store.hasSeenUnlimitedHostsOffer = true
                    showsOffer = true
                }) {
                    Text("view unlimited hosts")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                cancelTransferButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(T.presentationBg)
    }

    private var separator: some View {
        Rectangle()
            .fill(T.border)
            .frame(height: 0.5)
    }

    private var explanationText: String {
        let count = plan.newHostIDs.count
        let noun = count == 1 ? "host" : "hosts"
        return "free tessera remembers one host. this nearby setup offered \(count) \(noun) — choose one route to keep within the free limit, or unlock unlimited hosts to keep everything."
    }

    private func retryStoreLoad() {
        Task { await store.retryLoad() }
    }

    private var cancelTransferButton: some View {
        Button {
            onDecision(.cancel)
        } label: {
            Text("cancel transfer")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var presentationDetents: Set<PresentationDetent> {
        if UIDevice.current.userInterfaceIdiom == .phone
            || dynamicTypeSize.isAccessibilitySize {
            return [.large]
        }
        return [.height(520), .large]
    }

    private func routeRow(_ route: BootstrapImportPlan.Route) -> some View {
        let closureCount = route.closureHostIDs.count
        let isSelectable = closureCount <= remainingFreeSlots

        return Button {
            onDecision(.restrictTo(route.closureHostIDs))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(route.name)
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fg)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    Spacer(minLength: 8)

                    if closureCount > 1 {
                        Text("\(closureCount) hosts")
                            .font(Typography.tesseraMono(size: 10))
                            .foregroundStyle(T.fgDim)
                    }
                }

                Text(route.address)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                if !isSelectable {
                    Text(closureCount > 1 ? "needs a jump host too" : "no free host slot")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(T.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .opacity(isSelectable ? 1 : 0.55)
        .accessibilityHint(isSelectable ? "double-tap to keep only this route" : "not selectable within the free limit")
    }
}
