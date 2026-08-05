import StoreKit
import StoreKitTest
import XCTest

@testable import Tessera

/// Exercises the real StoreKit stack end to end through `SKTestSession` plus the
/// app's own purchase types (`LiveStoreKitClient`, `HostAccessStore`).
///
/// The session is backed by `Tessera.storekit`, which must be registered in the
/// TesseraTests bundle's Resources phase (`SKTestSession(configurationFileNamed:)`
/// resolves configuration files from the test bundle). No network is involved.
///
/// Sandbox/TestFlight report synthetic original app versions, so production
/// grandfathering is intentionally disabled outside AppStore.Environment.production.
/// That keeps the actual free/paywall path reachable to App Review and local
/// StoreKit tests. Paid-to-free cutoff math stays deterministic in
/// HostAccessStoreTests with injected production facts.
@MainActor
final class StoreKitPurchaseTests: XCTestCase {
    private static let productID = "com.bambouville.TesseraApp.unlimited_hosts"
    private static let enUSDisplayName = "Unlimited Saved Hosts"
    private static let enUSDescription = "Save and manage as many hosts as you need."
    private static let deDEDisplayName = "Unbegrenzt gespeicherte Hosts"
    private static let deDEDescription = "Speichere und verwalte beliebig viele Hosts."

    private var session: SKTestSession!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        session = try SKTestSession(configurationFileNamed: "Tessera")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")
        suiteName = "StoreKitPurchaseTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        session.clearTransactions()
        session = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Product loading

    func test_loadProduct_returnsConfiguredNonConsumableWithLocalizedPrice() async throws {
        let client = LiveStoreKitClient()

        let product = try await client.loadProduct()

        XCTAssertEqual(product.id, Self.productID)
        XCTAssertEqual(product.displayName, Self.enUSDisplayName)
        XCTAssertEqual(product.productDescription, Self.enUSDescription)
        XCTAssertTrue(
            product.displayPrice.contains("9.99"),
            "displayPrice should render the configured 9.99 price for the USA storefront, got \(product.displayPrice)"
        )
    }

    func test_checkedInMetadata_fitsAppStoreConnectLimits() {
        XCTAssertLessThanOrEqual(Self.enUSDisplayName.count, 30)
        XCTAssertLessThanOrEqual(Self.deDEDisplayName.count, 30)
        XCTAssertLessThanOrEqual(Self.enUSDescription.count, 45)
        XCTAssertLessThanOrEqual(Self.deDEDescription.count, 45)
    }

    func test_loadProduct_germanStorefront_returnsDistinctLocalizedCopyAndPrice() async throws {
        session.storefront = "DEU"
        session.locale = Locale(identifier: "de_DE")
        let client = LiveStoreKitClient()

        let product = try await client.loadProduct()

        XCTAssertEqual(product.id, Self.productID)
        XCTAssertEqual(product.displayName, Self.deDEDisplayName)
        XCTAssertEqual(product.productDescription, Self.deDEDescription)
        XCTAssertNotEqual(product.displayName, Self.enUSDisplayName)
        XCTAssertNotEqual(product.productDescription, Self.enUSDescription)
        // Same configured price, German formatting — proves the UI copy comes
        // from StoreKit localization rather than hard-coded strings.
        XCTAssertTrue(
            product.displayPrice.contains("9,99"),
            "displayPrice should be localized for de_DE, got \(product.displayPrice)"
        )
    }

    // MARK: - Purchase flows

    func test_purchaseGrantsUnlimitedAccess() async throws {
        let expected = try await expectedStates()
        let client = LiveStoreKitClient()
        let store = HostAccessStore(client: client, defaults: defaults)
        store.start()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, expected.baseline)

        await store.purchase()

        // The store applies an in-app purchase result directly; unlike
        // update-driven grants the source is always reported as .purchasedIAP.
        await waitUntil("purchase grants unlimited access") {
            store.accessState == .unlimited(.purchasedIAP)
        }
        XCTAssertFalse(store.purchaseInFlight)
        XCTAssertNil(store.lastErrorMessage)
        let entitled = try await client.hasUnlimitedHostsEntitlement()
        XCTAssertTrue(entitled)
    }

    func test_cancelledPurchase_staysBaselineAndQuiet() async throws {
        let expected = try await expectedStates()
        // SKTestSession has no "cancel the sheet" API: with dialogs disabled
        // every purchase auto-approves, and `failureError`/`failTransactionsEnabled`
        // are deprecated. The supported equivalent is a simulated StoreKit error;
        // `StoreKitError.userCancelled` is the canonical cancellation error, and
        // `LiveStoreKitClient.purchase()` is expected to map it to
        // `PurchaseOutcome.cancelled` exactly like a real sheet dismissal.
        try await session.setSimulatedError(
            SKTestFailures.Purchase.generic(.userCancelled),
            forAPI: StoreKitPurchaseAPI()
        )
        let store = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        store.start()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, expected.baseline)

        await store.purchase()
        // Simulated StoreKit errors survive SKTestSession replacement inside
        // the same test-runner process on iOS 26. Clear the API explicitly so
        // later purchase/refund/restore cases remain independent.
        try await session.setSimulatedError(nil, forAPI: StoreKitPurchaseAPI())

        XCTAssertEqual(store.accessState, expected.baseline)
        XCTAssertFalse(store.purchaseInFlight)
        XCTAssertFalse(store.purchasePending)
        XCTAssertNil(
            store.lastErrorMessage,
            "Cancellation must be quiet, got error: \(store.lastErrorMessage ?? "nil")"
        )
    }

    func test_failedPurchase_surfacesErrorAndKeepsBaselineAccess() async throws {
        let expected = try await expectedStates()
        // A non-cancellation StoreKit failure (a network interruption mid
        // purchase): purchase() throws, the store surfaces the error, and
        // access does not change. StoreKitTest clears a simulated error by
        // setting nil for the same API — there is no separate clear API.
        try await session.setSimulatedError(
            SKTestFailures.Purchase.generic(.networkError(URLError(.networkConnectionLost))),
            forAPI: StoreKitPurchaseAPI()
        )
        let store = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        store.start()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, expected.baseline)

        await store.purchase()
        try await session.setSimulatedError(nil, forAPI: StoreKitPurchaseAPI())

        XCTAssertEqual(store.accessState, expected.baseline)
        XCTAssertFalse(store.purchaseInFlight)
        XCTAssertFalse(store.purchasePending)
        XCTAssertNotNil(
            store.lastErrorMessage,
            "a failed purchase must surface a user-facing error"
        )

        // StoreKit Test can leave this particular session's purchase path
        // wedged after a simulated failure, so same-session retry semantics
        // stay covered by HostAccessStoreTests with the deterministic client.
        // Clearing the simulated API above is still required because that
        // injected error otherwise leaks into later SKTestSession instances.
    }

    func test_askToBuy_pendsUntilApprovedThenGrants() async throws {
        let expected = try await expectedStates()
        session.askToBuyEnabled = true
        let store = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        store.start()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, expected.baseline)

        await store.purchase()

        await waitUntil("ask-to-buy purchase enters pending state") {
            store.purchasePending
        }
        XCTAssertEqual(store.accessState, expected.baseline)
        let pendingTransactions = session.allTransactions().filter(\.pendingAskToBuyConfirmation)
        XCTAssertEqual(pendingTransactions.count, 1)
        let pendingTransaction = try XCTUnwrap(pendingTransactions.first)

        try session.approveAskToBuyTransaction(identifier: pendingTransaction.identifier)

        // The approved transaction arrives through Transaction.updates, which
        // the store observes because start() was called before purchasing.
        await waitUntil("approved ask-to-buy transaction grants unlimited access") {
            store.accessState == expected.grantViaUpdates && !store.purchasePending
        }
        XCTAssertNil(store.lastErrorMessage)
    }

    func test_externalPurchase_grantsViaTransactionUpdates() async throws {
        let expected = try await expectedStates()
        // The local environment classifies every install as legacy paid, so
        // baseline and post-grant states are identical and the access state
        // alone cannot prove Transaction.updates delivered. The spy counts
        // the elements pulled through entitlementUpdates() — only the store's
        // live listener can produce one.
        let spy = EntitlementUpdateSpyClient()
        let store = HostAccessStore(client: spy, defaults: defaults)
        store.start()
        await store.awaitReady()
        XCTAssertEqual(store.accessState, expected.baseline)

        // Creates a transaction outside the app's purchase flow (e.g. a purchase
        // made on another device or via the App Store app); it must reach the
        // store only through Transaction.updates.
        _ = try await session.buyProduct(identifier: Self.productID)

        await waitUntil("the live listener delivers the external purchase") {
            spy.deliveredCount > 0
        }
        await waitUntil("external purchase grants unlimited access") {
            store.accessState == expected.grantViaUpdates
        }
        XCTAssertFalse(store.purchaseInFlight)
    }

    func test_restore_reconstructsEntitlementViaSync() async throws {
        let expected = try await expectedStates()
        let purchasingStore = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        purchasingStore.start()
        await purchasingStore.awaitReady()
        await purchasingStore.purchase()
        await waitUntil("initial purchase grants unlimited access") {
            purchasingStore.accessState == .unlimited(.purchasedIAP)
        }

        // A store that never observed the purchase reconstructs it through the
        // explicit restore path (AppStore.sync does not prompt in SKTestSession).
        let restoringStore = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        await restoringStore.restore()

        await waitUntil("restore reconstructs unlimited access") {
            restoringStore.accessState == expected.grantViaUpdates
        }

        // Source-independent: the IAP transaction itself must exist in
        // StoreKit — this environment's legacy classification resolves to the
        // same access state whether or not it does.
        let entitled = try await LiveStoreKitClient().hasUnlimitedHostsEntitlement()
        XCTAssertTrue(
            entitled,
            "restore must reconstruct from a real IAP transaction, not legacy classification"
        )
    }

    func test_refundWhileRunning_revokesEntitlement() async throws {
        let expected = try await expectedStates()
        let store = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        store.start()
        await store.awaitReady()
        await store.purchase()
        await waitUntil("purchase grants unlimited access") {
            store.accessState == .unlimited(.purchasedIAP)
        }
        let transaction = try XCTUnwrap(
            session.allTransactions().first,
            "Expected a test transaction to refund"
        )

        try session.refundTransaction(identifier: transaction.identifier)

        // The revocation arrives through Transaction.updates while the app runs
        // and drops the IAP source — back to this environment's baseline.
        await waitUntil("refund returns access to the no-IAP baseline") {
            store.accessState == expected.baseline
        }
    }

    func test_relaunch_reconstructsEntitlementFromStoreKit() async throws {
        let expected = try await expectedStates()
        let firstStore = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        firstStore.start()
        await firstStore.awaitReady()
        await firstStore.purchase()
        await waitUntil("purchase grants unlimited access") {
            firstStore.accessState == .unlimited(.purchasedIAP)
        }

        // New client + new store: nothing survives in memory, so the entitlement
        // can only come from StoreKit transaction state.
        let relaunchedStore = HostAccessStore(client: LiveStoreKitClient(), defaults: defaults)
        relaunchedStore.start()
        await relaunchedStore.awaitReady()

        await waitUntil("relaunch reconstructs unlimited access") {
            relaunchedStore.accessState == expected.grantViaUpdates
        }

        // Source-independent: StoreKit must still hold the IAP transaction —
        // this environment's legacy classification would resolve to the same
        // access state even if the transaction were lost.
        let entitled = try await LiveStoreKitClient().hasUnlimitedHostsEntitlement()
        XCTAssertTrue(
            entitled,
            "relaunch must reconstruct from a real IAP transaction, not legacy classification"
        )
    }

    // MARK: - Legacy classification

    func test_legacyClassification_matchesAppTransactionAndCutoff() async throws {
        // This environment must remain free so the product under review is
        // reachable; only verified production app transactions apply the
        // paid-build cutoff.
        let client = LiveStoreKitClient()

        let reported = try await client.isLegacyPaidCustomer()
        let reportedAgain = try await client.isLegacyPaidCustomer()
        XCTAssertEqual(reported, reportedAgain, "legacy classification must be stable")

        do {
            let result = try await AppTransaction.shared
            switch result {
            case .verified(let appTransaction):
                let expected = appTransaction.environment == .production
                    && HostAccessProduct.isLegacyPaidBuild(
                        originalAppVersion: appTransaction.originalAppVersion
                    )
                XCTAssertEqual(
                    reported,
                    expected,
                    "only production app transactions may apply the legacy cutoff"
                )
                if appTransaction.environment != .production {
                    XCTAssertFalse(reported, "sandbox/Xcode must expose the free IAP path")
                }
            case .unverified:
                XCTAssertFalse(reported, "unverified app transaction must never classify as legacy paid")
            }
        } catch {
            XCTAssertFalse(reported, "failed app transaction lookup must never classify as legacy paid")
        }
    }

    // MARK: - Helpers

    /// Expected access states for this environment's legacy classification.
    /// `baseline` is where the store settles with no IAP entitlement (`.free`
    /// for a new customer, `.unlimited(.legacyPaid)` when the app transaction
    /// predates the cutoff); `grantViaUpdates` is the state after an entitlement
    /// arrives through `Transaction.updates` (a rescan prefers the legacy
    /// source when both apply). The mechanics under test are identical either
    /// way; only the source label differs.
    private func expectedStates() async throws
        -> (baseline: HostAccessState, grantViaUpdates: HostAccessState)
    {
        let isLegacy = try await LiveStoreKitClient().isLegacyPaidCustomer()
        if isLegacy {
            return (.unlimited(.legacyPaid), .unlimited(.legacyPaid))
        }
        return (.free, .unlimited(.purchasedIAP))
    }

    /// Polls `condition` until it holds or the timeout elapses, then fails with
    /// `description`. StoreKit delivers test transactions asynchronously, so
    /// entitlement assertions must wait for Transaction.updates to land.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTAssertTrue(condition(), "Timed out waiting for: \(description)", file: file, line: line)
    }
}

/// Thread-safe count of elements pulled through a wrapped
/// `AsyncStream<EntitlementUpdate>`. The forwarding task runs off the main
/// actor while the test polls from it, hence the lock.
private final class EntitlementUpdateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func increment() {
        lock.lock()
        delivered += 1
        lock.unlock()
    }
}

/// Delegates every `StoreKitClient` call to a real `LiveStoreKitClient`,
/// counting the elements yielded through `entitlementUpdates()`. Local
/// StoreKit Testing classifies this install as legacy paid, so the resolved
/// access state alone cannot prove a transaction update arrived — only the
/// store's live listener pulling an element through this wrapper can.
private struct EntitlementUpdateSpyClient: StoreKitClient {
    private let live: LiveStoreKitClient
    private let counter: EntitlementUpdateCounter

    init(live: LiveStoreKitClient = LiveStoreKitClient()) {
        self.live = live
        counter = EntitlementUpdateCounter()
    }

    var deliveredCount: Int { counter.value }

    func loadProduct() async throws -> AccessProduct {
        try await live.loadProduct()
    }

    func isLegacyPaidCustomer() async throws -> Bool {
        try await live.isLegacyPaidCustomer()
    }

    func hasUnlimitedHostsEntitlement() async throws -> Bool {
        try await live.hasUnlimitedHostsEntitlement()
    }

    func entitlementUpdates() -> AsyncStream<EntitlementUpdate> {
        let upstream = live.entitlementUpdates()
        let counter = counter
        return AsyncStream { continuation in
            let task = Task {
                for await update in upstream {
                    counter.increment()
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func purchase() async throws -> PurchaseOutcome {
        try await live.purchase()
    }

    func sync() async throws {
        try await live.sync()
    }
}
