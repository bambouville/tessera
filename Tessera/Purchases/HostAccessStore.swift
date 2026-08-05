// Tessera/Purchases/HostAccessStore.swift
import Foundation

/// App-lifetime owner of everything the UI needs to know about the
/// "Unlimited Saved Hosts" purchase: the loaded product, the resolved
/// `HostAccessState`, purchase/restore progress, user-facing errors, and the
/// single deferred post-purchase action token. Constructed in
/// `TesseraApp.init` and injected like the other controllers; `start()` is the
/// production entry point.
///
/// The store does not own host data and never persists entitlement truth —
/// StoreKit's signed transactions are re-queried on every rescan. Saved hosts
/// are never hidden, deleted, or made unlaunchable from here; the worst an
/// error can do is hold access in `.checking` — never an assumed `.free` —
/// with every row intact.
@MainActor @Observable
final class HostAccessStore {
    static let foregroundAccessFreshnessInterval: TimeInterval = 60

    private struct AccessRefreshFlight {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    /// Resolved access level. Stays `.checking` until the first rescan lands;
    /// callers must not treat `.checking` as `.free`.
    private(set) var accessState: HostAccessState = .checking

    /// The localized product, or nil while it has not loaded.
    private(set) var product: AccessProduct?

    /// True when the last product load failed. The UI shows a compact retry
    /// and keeps `restore purchases` available — never a fabricated price.
    private(set) var isProductUnavailable = false

    /// One purchase or restore at a time; controls disable while set.
    private(set) var purchaseInFlight = false

    /// Ask to Buy / pending approval. The app stays usable; approval arrives
    /// through the entitlement-updates listener, while a decline arrives
    /// silently — the next completed entitlement rescan is the reset point.
    private(set) var purchasePending = false

    /// Last user-facing failure. Product metadata, entitlement verification,
    /// and an explicit purchase/restore are independent operations; keeping
    /// their errors separate prevents a late product success from erasing an
    /// ownership-verification failure (or vice versa).
    var lastErrorMessage: String? {
        operationErrorMessage ?? accessErrorMessage ?? productErrorMessage
    }

    /// Whether the full explainer sheet has already auto-presented once on
    /// this device. A presentation preference only — NEVER entitlement truth
    /// and never consulted for access decisions.
    var hasSeenUnlimitedHostsOffer: Bool {
        get { defaults.bool(forKey: Self.hasSeenOfferKey) }
        set { defaults.set(newValue, forKey: Self.hasSeenOfferKey) }
    }
    private static let hasSeenOfferKey = "hasSeenUnlimitedHostsOffer"

    private let client: StoreKitClient
    private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    /// Written once by `start()` on the main actor and cancelled from
    /// `deinit`, which is nonisolated — `nonisolated(unsafe)` is the escape
    /// hatch for exactly that single-writer pattern, and the token is not UI
    /// state so it stays out of observation tracking. The store is
    /// app-lifetime, so in practice neither side races anything.
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var accessRefreshFlight: AccessRefreshFlight?
    @ObservationIgnored private var productRefreshTask: Task<Void, Never>?
    private var deferredAction: (() -> Void)?
    private var didStart = false
    private var accessRefreshGeneration: UInt64 = 0
    private var productRefreshGeneration: UInt64 = 0
    private var lastAuthoritativeAccessRefreshAt: Date?
    private var productRevision: UInt64 = 0
    private var accessRevision: UInt64 = 0
    private var productErrorMessage: String?
    private var accessErrorMessage: String?
    private var operationErrorMessage: String?

    init(
        client: StoreKitClient,
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.client = client
        self.defaults = defaults
        self.now = now
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Production entry point, called once at app start: kicks a full rescan
    /// in the background and spawns the entitlement-updates listener so
    /// purchases completed elsewhere, Ask to Buy approvals, and refunds reach
    /// the UI without a relaunch.
    func start() {
        guard !didStart else { return }
        didStart = true
        Task { await refresh() }
        updatesTask = Task { [weak self, client] in
            for await update in client.entitlementUpdates() {
                guard let self else { break }
                await self.apply(update)
            }
        }
    }

    /// Full refresh. Product metadata and access truth run independently: a
    /// slow storefront must not keep a verified legacy/IAP owner in
    /// `.checking`, and a product-load failure must not block entitlement
    /// reconstruction.
    func refresh() async {
        async let productRefresh: Void = refreshProduct()
        async let accessRefresh: Void = refreshAccess()
        await accessRefresh
        await productRefresh
    }

    /// Backs the compact retry button in the unavailable/error state.
    func retryLoad() async {
        operationErrorMessage = nil
        productErrorMessage = nil
        accessErrorMessage = nil
        await refresh()
    }

    /// Foreground is the production reset point for a declined Ask to Buy
    /// request (StoreKit sends no transaction update for a decline), and a
    /// fallback rescan for purchases/refunds completed elsewhere. Never calls
    /// `AppStore.sync()` and never presents UI by itself.
    func applicationDidBecomeActive() {
        guard didStart else { return }
        let accessIsFresh: Bool
        if let refreshedAt = lastAuthoritativeAccessRefreshAt {
            let age = now().timeIntervalSince(refreshedAt)
            accessIsFresh = age >= 0 && age < Self.foregroundAccessFreshnessInterval
        } else {
            accessIsFresh = false
        }
        guard purchasePending || accessState == .checking || !accessIsFresh else {
            return
        }
        Task { await refreshAccess() }
    }

    /// Re-checks signed ownership at a persistence admission boundary without
    /// presenting UI. StoreKit automatically makes non-consumable transactions
    /// available on a new device, so this reconstructs an existing purchase
    /// from `Transaction.currentEntitlements`; it deliberately does not call
    /// `AppStore.sync()`, which Apple reserves for an explicit user action
    /// because it can present an authentication prompt.
    ///
    /// Bootstrap uses this fresh scan instead of relying only on the app-start
    /// task having completed within a fixed polling window. A customer setting
    /// up a new device therefore crosses the multi-host gate automatically as
    /// soon as StoreKit verifies the prior purchase, with no Restore tap.
    func accessStateForPersistenceAdmission() async -> HostAccessState {
        if case .unlimited = accessState { return accessState }
        await refreshAccess()
        return accessState
    }

    /// Suspends until the first entitlement rescan has resolved
    /// `accessState` out of `.checking`. Polls briefly and gives up after ~10s
    /// so a wedged StoreKit cannot hang a caller; on timeout the state is
    /// still `.checking` and the caller decides what to show.
    func awaitReady() async {
        var waitedMilliseconds = 0
        while accessState == .checking, waitedMilliseconds < 10_000, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            waitedMilliseconds += 50
        }
    }

    /// Runs the purchase flow. Quiet on cancellation, surfaces thrown errors,
    /// and on verified success grants access and continues the deferred
    /// add-host action exactly once (no success banner).
    func purchase() async {
        // Both the UI and the StoreKit boundary defend this rule. When access
        // is unknown the customer may already own the paid app or IAP; never
        // expose them to a duplicate charge merely because product metadata
        // happened to load first.
        guard accessState == .free, !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        operationErrorMessage = nil
        purchasePending = false
        do {
            switch try await client.purchase() {
            case .success:
                invalidateAccessScans()
                accessState = .unlimited(.purchasedIAP)
                accessErrorMessage = nil
                lastAuthoritativeAccessRefreshAt = now()
                runDeferredOnce()
            case .cancelled:
                break
            case .pending:
                purchasePending = true
            }
        } catch {
            operationErrorMessage = "the App Store could not complete the request. your saved host is unchanged."
        }
    }

    /// `restore purchases` — explicit user taps only, because `AppStore.sync()`
    /// can prompt for App Store authentication. Re-runs a full rescan after
    /// the sync so the UI reflects whatever the App Store returns; a restore
    /// that lands on unlimited resumes the deferred add-host action exactly
    /// like a fresh grant, while one that stays free keeps the token for the
    /// sheet-dismissal path.
    func restore() async {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        operationErrorMessage = nil
        do {
            try await client.sync()
            // Ownership truth is sufficient to finish Restore. Product
            // metadata refreshes independently and must not hold the restore
            // spinner forever when the storefront is unavailable.
            Task { await refreshProduct() }
            invalidateAccessScans()
            await refreshAccess(forceAfterInFlight: true)
            if case .unlimited = accessState {
                runDeferredOnce()
            }
        } catch {
            operationErrorMessage = "the App Store could not complete the request. your saved host is unchanged."
        }
    }

    /// Registers the action to continue after a purchase-triggered flow
    /// succeeds (e.g. open a fresh host editor). Replaces any existing token;
    /// the token fires exactly once via `runDeferredOnce`.
    func setDeferredPostPurchaseAction(_ action: @escaping () -> Void) {
        deferredAction = action
    }

    /// Drops any pending deferred action without running it.
    func clearDeferredPostPurchaseAction() {
        deferredAction = nil
    }

    // MARK: - Internals

    /// Re-resolves access from StoreKit truth: legacy paid app OR verified
    /// IAP is unlimited, otherwise free. The two sources are independent: a
    /// verified IAP grants immediately even when the app-transaction lookup
    /// fails. Only `IAP absent + legacy unknown` remains `.checking`.
    /// A completed scan is also the one reset point for `purchasePending`:
    /// StoreKit delivers no update when an approver declines Ask to Buy, so
    /// without this the purchase button would stay disabled all session.
    /// Ordinary callers join the current scan. StoreKit mutation callers wait
    /// for it, then force a newer scan so pre-sync/revocation truth cannot win.
    private func refreshAccess(forceAfterInFlight: Bool = false) async {
        if let flight = accessRefreshFlight {
            await flight.task.value
            if accessRefreshFlight?.generation == flight.generation {
                accessRefreshFlight = nil
            }
            if !forceAfterInFlight { return }
        }

        accessRefreshGeneration &+= 1
        let generation = accessRefreshGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performAccessRefresh()
        }
        accessRefreshFlight = AccessRefreshFlight(generation: generation, task: task)
        await task.value
        if accessRefreshFlight?.generation == generation {
            accessRefreshFlight = nil
        }
    }

    private func performAccessRefresh() async {
        accessRevision &+= 1
        let revision = accessRevision

        var encounteredVerificationFailure = false
        do {
            if try await client.hasUnlimitedHostsEntitlement() {
                applyAccessResolution(
                    .unlimited(.purchasedIAP),
                    revision: revision
                )
                return
            }
        } catch {
            encounteredVerificationFailure = true
        }

        do {
            if try await client.isLegacyPaidCustomer() {
                applyAccessResolution(.unlimited(.legacyPaid), revision: revision)
                return
            }
        } catch {
            encounteredVerificationFailure = true
        }

        guard revision == accessRevision else { return }
        if encounteredVerificationFailure {
            accessState = .checking
            accessErrorMessage = "the App Store could not confirm your existing purchases. your saved hosts remain available."
            // A failed scan is not an Ask-to-Buy decline signal.
            return
        }
        accessState = .free
        accessErrorMessage = nil
        purchasePending = false
        lastAuthoritativeAccessRefreshAt = now()
    }

    private func applyAccessResolution(
        _ state: HostAccessState,
        revision: UInt64
    ) {
        guard revision == accessRevision else { return }
        accessState = state
        accessErrorMessage = nil
        purchasePending = false
        lastAuthoritativeAccessRefreshAt = now()
        if case .unlimited = state {
            // A foreground/current-entitlements scan can be the first place
            // an Ask-to-Buy approval or purchase from another device becomes
            // visible. Resume the exact blocked save just as a live update or
            // explicit restore would; the token is single-shot.
            runDeferredOnce()
        }
    }

    private func refreshProduct() async {
        if let task = productRefreshTask {
            await task.value
            return
        }

        productRefreshGeneration &+= 1
        let generation = productRefreshGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performProductRefresh()
        }
        productRefreshTask = task
        await task.value
        if generation == productRefreshGeneration {
            productRefreshTask = nil
        }
    }

    private func performProductRefresh() async {
        productRevision &+= 1
        let revision = productRevision
        do {
            let loaded = try await client.loadProduct()
            guard revision == productRevision else { return }
            product = loaded
            isProductUnavailable = false
            productErrorMessage = nil
        } catch {
            guard revision == productRevision else { return }
            product = nil
            isProductUnavailable = true
            productErrorMessage = "the App Store could not load this purchase. existing hosts remain available."
        }
    }

    private func invalidateAccessScans() {
        accessRevision &+= 1
    }

    /// Handles one verified entitlement update from the listener. `.granted`
    /// covers purchases completed on another device and Ask to Buy approvals
    /// and resumes the deferred add-host action; `.revoked` covers refunds —
    /// saved-host rows are never touched, the customer simply drops to
    /// `.free` (or keeps `.unlimited(.legacyPaid)`). The rescan owns the
    /// pending-reset and `.checking`-on-failure policy for both.
    private func apply(_ update: EntitlementUpdate) async {
        switch update {
        case .granted:
            // The update itself is a verified target transaction. Apply it
            // directly so eventual consistency in currentEntitlements cannot
            // turn a real approval/external purchase into a false negative.
            invalidateAccessScans()
            accessState = .unlimited(.purchasedIAP)
            accessErrorMessage = nil
            purchasePending = false
            lastAuthoritativeAccessRefreshAt = now()
            runDeferredOnce()
        case .revoked:
            // Revocation removes the IAP source, but a paid-app grandfather may
            // still keep access. Re-resolve the union.
            invalidateAccessScans()
            await refreshAccess(forceAfterInFlight: true)
        }
    }

    /// Fires the deferred post-purchase action exactly once.
    private func runDeferredOnce() {
        let action = deferredAction
        deferredAction = nil
        action?()
    }
}
