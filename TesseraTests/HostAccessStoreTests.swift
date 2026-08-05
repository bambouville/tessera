import StoreKit
import XCTest
@testable import Tessera

/// Deterministic, StoreKit-free coverage of `HostAccessStore`: legacy paid
/// grandfathering, entitlement composition, product-load failure, legacy
/// lookup failure, purchase lifecycle, deferred post-purchase actions,
/// revocation, restore/sync discipline, and the presentation-only offer flag.
/// Unverified-transaction rejection is enforced by construction in
/// `LiveStoreKitClient` — all four transaction-handling methods guard
/// `VerificationResult` — and cannot be exercised end-to-end here: under
/// local StoreKit Testing and the sandbox the app transaction is always
/// verified. Every fact the fake reports models already-verified StoreKit
/// truth.
@MainActor
final class HostAccessStoreTests: XCTestCase {
    private enum InjectedFailure: Error {
        case productLoad
        case purchase
        case legacyLookup
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let name = "HostAccessStoreTests.\(UUID().uuidString)"
        suiteName = name
        defaults = UserDefaults(suiteName: name)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Product contract and legacy build compare

    func test_productContract_matchesCheckedInConstants() {
        XCTAssertEqual(
            HostAccessProduct.productID,
            "com.bambouville.TesseraApp.unlimited_hosts"
        )
        XCTAssertEqual(HostAccessProduct.freeModelFirstBuild, 4)
    }

    func test_originalBuildBelowCutoff_isLegacyPaidCustomer() {
        // Paid App Store releases used builds 1 through 3. All must remain
        // grandfathered after the free-model build 4 ships.
        let legacyBuilds = [
            "1",
            "2",
            "3",
            "3.0",
            "01",
            "1.9",
            "1.10",
        ]

        for build in legacyBuilds {
            XCTAssertTrue(
                HostAccessProduct.isLegacyPaidBuild(originalAppVersion: build),
                "originalAppVersion \(build.debugDescription) must be a legacy paid customer"
            )
        }
    }

    func test_originalBuildEqualToCutoff_isNewFreeCustomer() {
        // originalBuild == freeModelFirstBuild means the customer first
        // downloaded the free build: no grandfathering.
        for build in ["4", "4.0"] {
            XCTAssertFalse(
                HostAccessProduct.isLegacyPaidBuild(originalAppVersion: build),
                "originalAppVersion \(build.debugDescription) equals the cutoff and must be free"
            )
        }
    }

    func test_originalBuildAboveCutoff_isNewFreeCustomer() {
        // "10" is the lexicographic trap: as raw strings "10" < "4", but
        // numerically it is a later free build.
        for build in ["5", "9", "10"] {
            XCTAssertFalse(
                HostAccessProduct.isLegacyPaidBuild(originalAppVersion: build),
                "originalAppVersion \(build.debugDescription) is above the cutoff and must be free"
            )
        }
    }

    func test_malformedOriginalBuild_failsClosedAsNewFreeCustomer() {
        // Garbage must never misclassify a new user as a paid customer, the
        // same fail-closed rule as an unverified app transaction. " 1" is not
        // the canonical build string AppTransaction would vend, so it is
        // treated as malformed rather than trimmed.
        for build in ["", "abc", "1.x", " 1"] {
            XCTAssertFalse(
                HostAccessProduct.isLegacyPaidBuild(originalAppVersion: build),
                "malformed originalAppVersion \(build.debugDescription) must fail closed (free)"
            )
        }
    }

    func test_grandfatheringAppliesOnlyToProductionAppTransactions() {
        XCTAssertTrue(
            LiveStoreKitClient.isLegacyPaidCustomer(
                originalAppVersion: "3",
                environment: .production
            )
        )
        XCTAssertFalse(
            LiveStoreKitClient.isLegacyPaidCustomer(
                originalAppVersion: "1",
                environment: .sandbox
            )
        )
        XCTAssertFalse(
            LiveStoreKitClient.isLegacyPaidCustomer(
                originalAppVersion: "1",
                environment: .xcode
            )
        )
    }

    // MARK: - Entitlement composition

    func test_legacyPaidOnly_resolvesUnlimitedFromLegacySource() async {
        let (_, store) = makeStore(legacyPaid: true, entitled: false)

        await store.awaitReady()

        XCTAssertEqual(store.accessState, .unlimited(.legacyPaid))
    }

    func test_purchasedIAPOnly_resolvesUnlimitedFromPurchasedSource() async {
        let (_, store) = makeStore(legacyPaid: false, entitled: true)

        await store.awaitReady()

        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
    }

    func test_legacyPaidAndPurchasedIAP_togetherResolveUnlimited() async {
        let (_, store) = makeStore(legacyPaid: true, entitled: true)

        await store.awaitReady()

        // Union rule: either source alone suffices, so with both present the
        // store may report either — what matters is unlimited access.
        if case .unlimited = store.accessState {} else {
            XCTFail("expected .unlimited, got \(store.accessState)")
        }
    }

    func test_neitherSource_resolvesFreeEvenWhenProductLoads() async {
        // Unverified transactions never reach the store (the live client
        // drops them), so this pins the store's half of the rule: access is
        // composed from exactly the two verified booleans, and a loaded
        // product with a price never leaks into the access decision.
        let (_, store) = makeStore(legacyPaid: false, entitled: false)

        await store.awaitReady()

        XCTAssertEqual(store.accessState, .free)
        XCTAssertEqual(store.product, fixtureProduct)
        XCTAssertFalse(store.isProductUnavailable)
        XCTAssertNil(store.lastErrorMessage)
    }

    // MARK: - Product loading

    func test_productLoadFailure_neverFabricatesAPriceAndStillResolvesAccess() async {
        let (_, store) = makeStore(
            productResult: .failure(InjectedFailure.productLoad),
            legacyPaid: false,
            entitled: false
        )

        await store.awaitReady()

        XCTAssertNil(store.product, "no substitute product or mock price may appear")
        XCTAssertTrue(store.isProductUnavailable)
        XCTAssertNotNil(store.lastErrorMessage)
        // Entitlement truth does not depend on the storefront being reachable.
        XCTAssertEqual(store.accessState, .free)
    }

    func test_retryLoad_afterFailure_recoversProductAndClearsError() async {
        let (client, store) = makeStore(
            productResult: .failure(InjectedFailure.productLoad)
        )
        await store.awaitReady()
        XCTAssertTrue(store.isProductUnavailable)

        client.productResult = .success(fixtureProduct)
        await store.retryLoad()

        XCTAssertEqual(store.product, fixtureProduct)
        XCTAssertFalse(store.isProductUnavailable)
        XCTAssertNil(store.lastErrorMessage)
    }

    // MARK: - Legacy lookup failure

    func test_legacyLookupFailure_holdsCheckingUntilRetryResolves() async {
        // No start(): drive the rescans directly so each step is synchronous.
        let (client, store) = makeStore(start: false)
        client.legacyError = InjectedFailure.legacyLookup

        await store.refresh()

        XCTAssertEqual(
            store.accessState,
            .checking,
            "a failed lookup is unknown access, never an assumed .free"
        )
        XCTAssertNotNil(store.lastErrorMessage)

        client.legacyError = nil
        client.legacyPaid = true
        await store.retryLoad()

        XCTAssertEqual(store.accessState, .unlimited(.legacyPaid))
        XCTAssertNil(store.lastErrorMessage)
    }

    func test_legacyLookupFailure_keepsPurchasePendingForTheNextCompletedScan() async {
        let (client, store) = makeStore(purchaseOutcome: .pending)
        await store.awaitReady()
        await store.purchase()
        XCTAssertTrue(store.purchasePending)

        client.legacyError = InjectedFailure.legacyLookup
        await store.refresh()

        XCTAssertEqual(store.accessState, .checking)
        XCTAssertTrue(
            store.purchasePending,
            "a failed scan is not the Ask-to-Buy reset point"
        )
    }

    func test_verifiedIAP_grantsWhenLegacyLookupFails() async {
        let (client, store) = makeStore(start: false)
        client.entitled = true
        client.legacyError = InjectedFailure.legacyLookup

        await store.refresh()

        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
        XCTAssertEqual(client.hasUnlimitedHostsEntitlementCallCount, 1)
        XCTAssertNil(store.lastErrorMessage)
    }

    func test_verifiedLegacy_grantsWhenIAPLookupFails() async {
        let (client, store) = makeStore(start: false)
        client.legacyPaid = true
        client.entitlementError = InjectedFailure.legacyLookup

        await store.refresh()

        XCTAssertEqual(store.accessState, .unlimited(.legacyPaid))
        XCTAssertNil(store.lastErrorMessage)
    }

    func test_unverifiedIAPWithNoLegacyProof_holdsCheckingAndCannotPurchase() async {
        let (client, store) = makeStore(start: false)
        client.entitlementError = InjectedFailure.legacyLookup

        await store.refresh()
        await store.purchase()

        XCTAssertEqual(store.accessState, .checking)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(client.purchaseCallCount, 0)
    }

    // MARK: - Purchase lifecycle

    func test_successfulPurchase_grantsUnlimitedAndClearsInFlight() async {
        let (client, store) = makeStore()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, .free)
        XCTAssertFalse(store.purchaseInFlight)

        await store.purchase()

        XCTAssertEqual(client.purchaseCallCount, 1)
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
        XCTAssertFalse(store.purchaseInFlight)
        XCTAssertNil(store.lastErrorMessage)
    }

    func test_cancelledPurchase_isQuietAndLeavesAccessUnchanged() async {
        let (_, store) = makeStore(purchaseOutcome: .cancelled)
        await store.awaitReady()

        await store.purchase()

        XCTAssertEqual(store.accessState, .free)
        XCTAssertNil(store.lastErrorMessage, "cancellation dismisses without an error toast")
        XCTAssertFalse(store.purchaseInFlight)
        XCTAssertFalse(store.purchasePending)
    }

    func test_failedPurchase_surfacesErrorAndKeepsFreeAccess() async {
        let (_, store) = makeStore(purchaseError: InjectedFailure.purchase)
        await store.awaitReady()

        await store.purchase()

        XCTAssertEqual(store.accessState, .free)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertFalse(store.purchaseInFlight)
    }

    func test_purchaseWhileAccessIsChecking_neverCallsStoreKit() async {
        let (client, store) = makeStore(start: false)

        await store.purchase()

        XCTAssertEqual(store.accessState, .checking)
        XCTAssertEqual(client.purchaseCallCount, 0)
    }

    func test_pendingPurchase_staysFreeUntilApprovedUpdateArrives() async {
        let (client, store) = makeStore(purchaseOutcome: .pending)
        await store.awaitReady()

        await store.purchase()

        XCTAssertTrue(store.purchasePending)
        XCTAssertFalse(store.purchaseInFlight)
        XCTAssertEqual(store.accessState, .free, "Ask-to-Buy approval has not happened yet")
        XCTAssertNil(store.lastErrorMessage)

        client.yield(.granted)

        let pendingResolved = await waitUntil {
            store.accessState == .unlimited(.purchasedIAP) && !store.purchasePending
        }
        XCTAssertTrue(
            pendingResolved,
            "the approved update must resolve the pending purchase"
        )
    }

    func test_pendingPurchase_isClearedByNextCompletedRescan() async {
        // StoreKit delivers no Transaction.updates event when an approver
        // declines Ask to Buy, so the next completed entitlement scan is the
        // reset point that re-enables the purchase button.
        let (_, store) = makeStore(purchaseOutcome: .pending)
        await store.awaitReady()

        await store.purchase()
        XCTAssertTrue(store.purchasePending)

        await store.refresh()

        XCTAssertFalse(store.purchasePending)
        XCTAssertEqual(store.accessState, .free)
    }

    func test_pendingPurchase_isClearedOnNextForegroundRescan() async {
        let (_, store) = makeStore(purchaseOutcome: .pending)
        await store.awaitReady()
        await store.purchase()
        XCTAssertTrue(store.purchasePending)

        store.applicationDidBecomeActive()

        let reset = await waitUntil { !store.purchasePending }
        XCTAssertTrue(reset)
        XCTAssertEqual(store.accessState, .free)
    }

    func test_freshForegroundActivationDoesNotReloadProductOrAccess() async {
        let (client, store) = makeStore()
        await store.awaitReady()
        let productCalls = client.loadProductCallCount
        let accessCalls = client.hasUnlimitedHostsEntitlementCallCount

        store.applicationDidBecomeActive()
        store.applicationDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(client.loadProductCallCount, productCalls)
        XCTAssertEqual(client.hasUnlimitedHostsEntitlementCallCount, accessCalls)
    }

    func test_staleForegroundActivationRefreshesAccessWithoutReloadingProduct() async {
        var currentTime = Date(timeIntervalSince1970: 10_000)
        let (client, store) = makeStore(now: { currentTime })
        await store.awaitReady()
        let productCalls = client.loadProductCallCount
        let accessCalls = client.hasUnlimitedHostsEntitlementCallCount
        currentTime.addTimeInterval(HostAccessStore.foregroundAccessFreshnessInterval + 1)

        store.applicationDidBecomeActive()

        let refreshed = await waitUntil {
            client.hasUnlimitedHostsEntitlementCallCount == accessCalls + 1
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(client.loadProductCallCount, productCalls)
    }

    func test_successfulPurchase_clearsStaleErrorFromEarlierFailure() async {
        let (client, store) = makeStore(purchaseError: InjectedFailure.purchase)
        await store.awaitReady()

        await store.purchase()
        XCTAssertNotNil(store.lastErrorMessage)

        client.purchaseError = nil
        await store.purchase()

        XCTAssertNil(
            store.lastErrorMessage,
            "a fresh purchase attempt clears the stale error note so the retry treatment resets"
        )
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
    }

    // MARK: - Deferred post-purchase action

    func test_deferredPostPurchaseAction_runsExactlyOnceAcrossLaterGrants() async {
        let (client, store) = makeStore()
        await store.awaitReady()
        var runCount = 0
        store.setDeferredPostPurchaseAction { runCount += 1 }

        await store.purchase()

        let resumed = await waitUntil { runCount == 1 }
        XCTAssertTrue(
            resumed,
            "purchase success resumes the deferred add-host action"
        )

        // A later unrelated grant must not re-run the consumed token. Follow
        // it with a revocation and wait for the free state; stream ordering
        // proves both updates were consumed before the assertion.
        client.yield(.granted)
        client.yield(.revoked)

        let grantConsumed = await waitUntil { store.accessState == .free }
        XCTAssertTrue(
            grantConsumed,
            "the store must process the streamed grant"
        )
        XCTAssertEqual(runCount, 1, "the deferred action token is single-shot")
    }

    func test_deferredPostPurchaseAction_runsOnApprovedPendingPurchase() async {
        let (client, store) = makeStore(purchaseOutcome: .pending)
        await store.awaitReady()
        var runCount = 0
        store.setDeferredPostPurchaseAction { runCount += 1 }

        await store.purchase()

        XCTAssertEqual(runCount, 0, "pending approval must not run the deferred action")

        client.yield(.granted)

        let approvedResumed = await waitUntil { runCount == 1 }
        XCTAssertTrue(
            approvedResumed,
            "the approved update resumes the deferred add-host action"
        )
    }

    func test_foregroundEntitlementRescan_runsDeferredActionExactlyOnce() async {
        var currentTime = Date(timeIntervalSince1970: 10_000)
        let (client, store) = makeStore(now: { currentTime })
        await store.awaitReady()
        var runCount = 0
        store.setDeferredPostPurchaseAction { runCount += 1 }

        // Models an approval or other-device purchase whose live update was
        // missed while Tessera was inactive. Foreground current-entitlements
        // truth must resume the blocked save, not merely dismiss its sheet.
        client.entitled = true
        currentTime.addTimeInterval(HostAccessStore.foregroundAccessFreshnessInterval + 1)
        store.applicationDidBecomeActive()

        let resumed = await waitUntil { runCount == 1 }
        XCTAssertTrue(resumed)
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))

        await store.refresh()
        XCTAssertEqual(runCount, 1, "later scans cannot replay the consumed token")
    }

    func test_clearedDeferredPostPurchaseAction_neverRuns() async {
        let (_, store) = makeStore()
        await store.awaitReady()
        var runCount = 0
        store.setDeferredPostPurchaseAction { runCount += 1 }
        store.clearDeferredPostPurchaseAction()

        await store.purchase()

        // The purchase path consumes the token before purchase() returns, so
        // a cleared token can never fire from here.
        XCTAssertEqual(runCount, 0, "a cleared token must not survive into the purchase")
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
    }

    // MARK: - Revocation

    func test_revokedEntitlement_dropsToFreeWithoutCallingSync() async {
        let (client, store) = makeStore(entitled: true)
        await store.awaitReady()
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))

        client.yield(.revoked)

        let refundApplied = await waitUntil { store.accessState == .free }
        XCTAssertTrue(
            refundApplied,
            "a refund removes only the IAP source"
        )
        XCTAssertEqual(
            client.syncCallCount,
            0,
            "Transaction.updates delivery must not trigger AppStore.sync()"
        )
    }

    func test_revokedEntitlement_withLegacyPaid_fallsBackToLegacyUnlimited() async {
        let (client, store) = makeStore(legacyPaid: true, entitled: true)
        await store.awaitReady()
        if case .unlimited = store.accessState {} else {
            XCTFail("expected .unlimited, got \(store.accessState)")
        }

        // The resolved state is .unlimited(.legacyPaid) both before and after
        // the refund, so gate on the re-scan the update triggers — proof the
        // revocation was consumed — before asserting the fallback.
        let rescans = client.hasUnlimitedHostsEntitlementCallCount
        client.yield(.revoked)

        let revocationConsumed = await waitUntil { client.hasUnlimitedHostsEntitlementCallCount > rescans }
        XCTAssertTrue(
            revocationConsumed,
            "the store must process the streamed revocation"
        )
        XCTAssertEqual(
            store.accessState,
            .unlimited(.legacyPaid),
            "a refunded IAP customer keeps their legacy paid entitlement"
        )
        XCTAssertEqual(client.syncCallCount, 0)
    }

    // MARK: - Restore and sync discipline

    func test_restore_callsSyncExactlyOncePerExplicitCallAndRescans() async {
        let (client, store) = makeStore()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, .free)

        // Purchase completed on another device after the last entitlement scan.
        client.entitled = true
        await store.restore()

        XCTAssertEqual(client.syncCallCount, 1)
        let restoreApplied = await waitUntil { store.accessState == .unlimited(.purchasedIAP) }
        XCTAssertTrue(
            restoreApplied,
            "restore re-scans entitlements after syncing"
        )

        await store.restore()

        XCTAssertEqual(client.syncCallCount, 2, "each explicit restore syncs exactly once")
    }

    func test_restoreToUnlimited_runsDeferredActionExactlyOnceAcrossLaterGrants() async {
        let (client, store) = makeStore()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, .free)
        var runCount = 0
        store.setDeferredPostPurchaseAction { runCount += 1 }

        // The purchase completed on another device since the last scan, so
        // the sync + rescan resolves unlimited — the add the customer started
        // before tapping restore must resume from here, not dangle.
        client.entitled = true
        await store.restore()

        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
        XCTAssertEqual(
            runCount,
            1,
            "restore to unlimited resumes the deferred add-host action"
        )

        // Consume a later grant and a following revocation in stream order;
        // neither may re-run the already consumed action.
        client.yield(.granted)
        client.yield(.revoked)

        let grantConsumed = await waitUntil { store.accessState == .free }
        XCTAssertTrue(
            grantConsumed,
            "the store must process the streamed grant"
        )
        XCTAssertEqual(runCount, 1, "the deferred action token is single-shot")
    }

    func test_restoreToFree_preservesDeferredActionForLaterGrant() async {
        let (_, store) = makeStore()
        await store.awaitReady()
        var runCount = 0
        store.setDeferredPostPurchaseAction { runCount += 1 }

        await store.restore()

        XCTAssertEqual(store.accessState, .free)
        XCTAssertEqual(
            runCount,
            0,
            "a restore that stays free must not consume the token — it belongs to the sheet-dismissal path"
        )

        await store.purchase()

        XCTAssertEqual(runCount, 1, "the preserved token still fires on the next grant")
    }

    func test_refreshAndPurchasePaths_neverCallSync() async {
        // AppStore.sync() can prompt for App Store credentials, so only the
        // explicit restore button may call it — never startup, refresh, or
        // purchase.
        let (client, store) = makeStore()
        await store.awaitReady()
        XCTAssertEqual(client.syncCallCount, 0)

        await store.refresh()
        XCTAssertEqual(client.syncCallCount, 0)

        await store.purchase()
        XCTAssertEqual(client.syncCallCount, 0)
    }

    func test_persistenceAdmissionAutomaticallyReconstructsExistingIAPWithoutSync() async {
        let (client, store) = makeStore(start: false)

        // Model a new device whose first local state has no entitlement yet,
        // followed by StoreKit making the Apple Account's prior non-consumable
        // available before a nearby bootstrap reaches its persistence gate.
        await store.refresh()
        XCTAssertEqual(store.accessState, .free)
        client.entitled = true

        let access = await store.accessStateForPersistenceAdmission()

        XCTAssertEqual(access, .unlimited(.purchasedIAP))
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
        XCTAssertEqual(
            client.syncCallCount,
            0,
            "automatic new-device admission must never require Restore or AppStore.sync()"
        )
    }

    // MARK: - Offer presentation preference

    func test_hasSeenUnlimitedHostsOffer_defaultsFalseAndPersistsAcrossStoreInstances() {
        let (_, first) = makeStore(start: false)
        XCTAssertFalse(first.hasSeenUnlimitedHostsOffer)

        first.hasSeenUnlimitedHostsOffer = true

        // A fresh store over the same suite (i.e. after relaunch) reads it back.
        let second = HostAccessStore(client: FakeStoreKitClient(), defaults: defaults)
        XCTAssertTrue(
            second.hasSeenUnlimitedHostsOffer,
            "the presentation preference is local and durable, not entitlement state"
        )
    }

    func test_hasSeenUnlimitedHostsOffer_neverAffectsAdmissionDecisions() async {
        let (_, store) = makeStore()
        await store.awaitReady()
        store.hasSeenUnlimitedHostsOffer = true

        // The flag suppresses the full explainer only; it must never leak
        // into the quota decision.
        XCTAssertEqual(
            SavedHostAdmissionPolicy.decision(
                existingHostCount: 1,
                newRowCount: 1,
                access: store.accessState
            ),
            .requiresPurchase
        )
    }

    // MARK: - Readiness

    func test_awaitReady_returnsOnceAccessStateResolves() async {
        let (_, store) = makeStore()
        XCTAssertEqual(store.accessState, .checking)

        await store.awaitReady()

        XCTAssertEqual(store.accessState, .free)
    }

    func test_slowProductLoad_doesNotBlockLegacyAccessResolution() async {
        let client = ControlledStoreKitClient(
            legacyPaid: true,
            entitled: false,
            suspendsProductLoad: true
        )
        let store = HostAccessStore(client: client, defaults: defaults)

        let refresh = Task { await store.refresh() }
        let resolved = await waitUntil {
            store.accessState == .unlimited(.legacyPaid)
                && client.productContinuationCount == 1
        }

        XCTAssertTrue(resolved)
        XCTAssertNil(store.product)
        client.resumeProductLoad()
        await refresh.value
    }

    func test_concurrentRefreshesJoinOneAccessAndProductScan() async {
        let client = ControlledStoreKitClient()
        client.suspendsProductLoad = true
        client.suspendsEntitlementScan = true
        let store = HostAccessStore(client: client, defaults: defaults)

        let first = Task { await store.refresh() }
        let firstStarted = await waitUntil {
            client.entitlementContinuationCount == 1
                && client.productContinuationCount == 1
        }
        XCTAssertTrue(firstStarted)
        let second = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(client.entitlementContinuationCount, 1)
        XCTAssertEqual(client.productContinuationCount, 1)

        client.resumeEntitlementScan(at: 0, with: false)
        client.resumeProductLoad()
        await first.value
        await second.value
        XCTAssertEqual(store.accessState, .free)
    }

    func test_verifiedPurchase_invalidatesOlderFreeScan() async {
        let client = ControlledStoreKitClient()
        let store = HostAccessStore(client: client, defaults: defaults)
        await store.refresh()
        XCTAssertEqual(store.accessState, .free)

        client.suspendsEntitlementScan = true
        let staleRefresh = Task { await store.refresh() }
        let staleScanStarted = await waitUntil { client.entitlementContinuationCount == 1 }
        XCTAssertTrue(staleScanStarted)

        await store.purchase()
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))

        client.resumeEntitlementScan(at: 0, with: false)
        await staleRefresh.value
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
    }

    func test_restoreRunsAccessScanNewerThanPreSyncFlight() async {
        let client = ControlledStoreKitClient()
        client.suspendsEntitlementScan = true
        client.syncEntitledValue = true
        let store = HostAccessStore(client: client, defaults: defaults)

        let staleRefresh = Task { await store.refresh() }
        let staleStarted = await waitUntil { client.entitlementContinuationCount == 1 }
        XCTAssertTrue(staleStarted)
        let restore = Task { await store.restore() }
        let syncCompleted = await waitUntil { client.syncCallCount == 1 }
        XCTAssertTrue(syncCompleted)

        client.resumeEntitlementScan(at: 0, with: false)
        let postSyncStarted = await waitUntil { client.entitlementContinuationCount == 2 }
        XCTAssertTrue(postSyncStarted)
        client.resumeEntitlementScan(at: 1, with: true)

        await staleRefresh.value
        await restore.value
        XCTAssertEqual(store.accessState, .unlimited(.purchasedIAP))
    }

    // MARK: - Fixtures

    private func makeStore(
        productResult: Result<AccessProduct, Error> = .success(fixtureProduct),
        legacyPaid: Bool = false,
        entitled: Bool = false,
        purchaseOutcome: PurchaseOutcome = .success,
        purchaseError: Error? = nil,
        start: Bool = true,
        now: @escaping @MainActor () -> Date = { .now }
    ) -> (client: FakeStoreKitClient, store: HostAccessStore) {
        let client = FakeStoreKitClient(
            productResult: productResult,
            legacyPaid: legacyPaid,
            entitled: entitled,
            purchaseOutcome: purchaseOutcome,
            purchaseError: purchaseError
        )
        let store = HostAccessStore(client: client, defaults: defaults, now: now)
        if start {
            store.start()
        }
        return (client, store)
    }
}

/// Localized product fixture. The price is deliberately NOT the product's
/// real $9.99 so any hard-coded price in production code fails the
/// pass-through assertions.
private let fixtureProduct = AccessProduct(
    id: HostAccessProduct.productID,
    displayName: "Unlimited Saved Hosts",
    productDescription: "Save and manage as many hosts as you need.",
    displayPrice: "¥1,800"
)

/// Scriptable `StoreKitClient` double with call recording and a mid-test
/// yieldable entitlement stream.
private final class FakeStoreKitClient: StoreKitClient {
    var productResult: Result<AccessProduct, Error>
    var legacyPaid: Bool
    var entitled: Bool
    var purchaseOutcome: PurchaseOutcome
    var purchaseError: Error?
    var entitlementError: Error?
    /// When set, models the app-transaction lookup itself failing (e.g.
    /// offline) — distinct from a verified non-legacy answer, which is
    /// `legacyPaid = false`.
    var legacyError: Error?

    private(set) var loadProductCallCount = 0
    private(set) var isLegacyPaidCustomerCallCount = 0
    private(set) var hasUnlimitedHostsEntitlementCallCount = 0
    private(set) var entitlementUpdatesCallCount = 0
    private(set) var purchaseCallCount = 0
    private(set) var syncCallCount = 0

    let entitlementContinuation: AsyncStream<EntitlementUpdate>.Continuation
    private let stream: AsyncStream<EntitlementUpdate>

    init(
        productResult: Result<AccessProduct, Error> = .success(fixtureProduct),
        legacyPaid: Bool = false,
        entitled: Bool = false,
        purchaseOutcome: PurchaseOutcome = .success,
        purchaseError: Error? = nil
    ) {
        self.productResult = productResult
        self.legacyPaid = legacyPaid
        self.entitled = entitled
        self.purchaseOutcome = purchaseOutcome
        self.purchaseError = purchaseError
        var captured: AsyncStream<EntitlementUpdate>.Continuation!
        stream = AsyncStream(EntitlementUpdate.self) { captured = $0 }
        entitlementContinuation = captured
    }

    func loadProduct() async throws -> AccessProduct {
        loadProductCallCount += 1
        return try productResult.get()
    }

    func isLegacyPaidCustomer() async throws -> Bool {
        isLegacyPaidCustomerCallCount += 1
        if let legacyError {
            throw legacyError
        }
        return legacyPaid
    }

    func hasUnlimitedHostsEntitlement() async throws -> Bool {
        hasUnlimitedHostsEntitlementCallCount += 1
        if let entitlementError { throw entitlementError }
        return entitled
    }

    func entitlementUpdates() -> AsyncStream<EntitlementUpdate> {
        entitlementUpdatesCallCount += 1
        return stream
    }

    func purchase() async throws -> PurchaseOutcome {
        purchaseCallCount += 1
        if let purchaseError {
            throw purchaseError
        }
        // A completed purchase becomes StoreKit truth: any later entitlement
        // scan would now report it.
        if purchaseOutcome == .success {
            entitled = true
        }
        return purchaseOutcome
    }

    func sync() async throws {
        syncCallCount += 1
    }

    /// Models StoreKit delivering a transaction update: the underlying truth
    /// changes first (a later entitlement scan would agree), then the app
    /// hears about it, so a store that re-scans on updates sees a consistent
    /// world either way.
    func yield(_ update: EntitlementUpdate) {
        switch update {
        case .granted:
            entitled = true
        case .revoked:
            entitled = false
        }
        entitlementContinuation.yield(update)
    }
}

/// Continuation-controlled client for proving ordering and independent product
/// versus access resolution. Tests resume specific calls in adversarial order.
private final class ControlledStoreKitClient: StoreKitClient {
    var legacyPaid: Bool
    var entitled: Bool
    var suspendsProductLoad: Bool
    var suspendsEntitlementScan = false
    var syncEntitledValue: Bool?

    private(set) var syncCallCount = 0
    private var productContinuations: [CheckedContinuation<AccessProduct, Error>] = []
    private var entitlementContinuations: [CheckedContinuation<Bool, Error>] = []

    init(
        legacyPaid: Bool = false,
        entitled: Bool = false,
        suspendsProductLoad: Bool = false
    ) {
        self.legacyPaid = legacyPaid
        self.entitled = entitled
        self.suspendsProductLoad = suspendsProductLoad
    }

    var productContinuationCount: Int { productContinuations.count }
    var entitlementContinuationCount: Int { entitlementContinuations.count }

    func loadProduct() async throws -> AccessProduct {
        guard suspendsProductLoad else { return fixtureProduct }
        return try await withCheckedThrowingContinuation { continuation in
            productContinuations.append(continuation)
        }
    }

    func isLegacyPaidCustomer() async throws -> Bool {
        legacyPaid
    }

    func hasUnlimitedHostsEntitlement() async throws -> Bool {
        guard suspendsEntitlementScan else { return entitled }
        return try await withCheckedThrowingContinuation { continuation in
            entitlementContinuations.append(continuation)
        }
    }

    func entitlementUpdates() -> AsyncStream<EntitlementUpdate> {
        AsyncStream { _ in }
    }

    func purchase() async throws -> PurchaseOutcome {
        entitled = true
        return .success
    }

    func sync() async throws {
        syncCallCount += 1
        if let syncEntitledValue {
            entitled = syncEntitledValue
        }
    }

    func resumeProductLoad() {
        let continuation = productContinuations.removeFirst()
        suspendsProductLoad = false
        continuation.resume(returning: fixtureProduct)
    }

    func resumeEntitlementScan(at index: Int, with value: Bool) {
        entitlementContinuations[index].resume(returning: value)
    }
}

/// Polls a main-actor condition until it holds or the timeout elapses.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
