// Tessera/Purchases/StoreKitClient.swift
import StoreKit

/// The one product as the App Store describes it. `displayName`,
/// `productDescription`, and `displayPrice` come straight from StoreKit's
/// localized `Product` — the UI must never ship a hard-coded price, so a
/// missing product is an unavailable state, never a fabricated one.
struct AccessProduct: Equatable {
    let id: String
    let displayName: String
    let productDescription: String
    let displayPrice: String
}

/// Terminal result of a purchase attempt. Cancellation is a normal quiet
/// outcome; pending resolves later through `Transaction.updates`.
enum PurchaseOutcome: Equatable {
    case success
    case cancelled
    case pending
}

/// A change to the unlimited-hosts entitlement observed on
/// `Transaction.updates` — purchases completed on another device, Ask to Buy
/// approvals, and refunds/revocations.
enum EntitlementUpdate: Equatable {
    case granted
    case revoked
}

/// Boundary between the app and the live App Store. Policy and state tests
/// inject a fake; production uses `LiveStoreKitClient`. StoreKit's signed
/// transaction is the authority — there is no server and no Tessera account.
protocol StoreKitClient {
    /// Loads the single product. Throws when the App Store cannot return it;
    /// callers surface an unavailable state rather than a substitute price.
    func loadProduct() async throws -> AccessProduct

    /// Whether the verified app transaction says this Apple Account originally
    /// downloaded the paid app. Only the two non-throwing outcomes are
    /// authoritative: `.verified` is compared against the cutoff build and
    /// sandbox/Xcode app transactions are deliberately not grandfathered, so
    /// TestFlight/App Review can exercise the free-to-IAP path. An unverified
    /// result throws: it never grants, but it is also not authoritative proof
    /// that this customer is new.
    func isLegacyPaidCustomer() async throws -> Bool

    /// Whether a verified, unrevoked transaction for the unlimited-hosts
    /// product sits in `Transaction.currentEntitlements`.
    /// An unverified transaction for this product throws. Skipping it as a
    /// definitive `false` could expose a real owner to a duplicate offer.
    func hasUnlimitedHostsEntitlement() async throws -> Bool

    /// Verified unlimited-hosts transactions delivered after launch. Yields
    /// `.revoked` for refunded/revoked transactions, `.granted` otherwise.
    /// Unverified updates are skipped entirely.
    func entitlementUpdates() -> AsyncStream<EntitlementUpdate>

    /// Buys the product. Verified success finishes the transaction; an
    /// unverified result throws instead of granting.
    func purchase() async throws -> PurchaseOutcome

    /// `AppStore.sync()`. Explicit user taps only — it can prompt for App
    /// Store authentication.
    func sync() async throws
}

/// Failures raised by the live client. Messages stay lowercase per the app's
/// voice; the store replaces them with user-facing copy anyway.
enum StoreKitClientError: LocalizedError {
    /// `Product.products(for:)` returned nothing for the known product ID.
    case productUnavailable
    /// A purchase or update failed StoreKit verification.
    case purchaseUnverified
    /// Existing app/IAP ownership could not be verified.
    case entitlementUnverified

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "the App Store did not return the unlimited saved hosts product"
        case .purchaseUnverified:
            return "the App Store returned a purchase that failed verification"
        case .entitlementUnverified:
            return "the App Store could not verify existing purchase status"
        }
    }
}

/// StoreKit 2 implementation. All entitlement decisions pass through
/// `VerificationResult`; anything unverified is skipped or treated as absent.
struct LiveStoreKitClient: StoreKitClient {
    init() {}

    func loadProduct() async throws -> AccessProduct {
        let products = try await Product.products(for: [HostAccessProduct.productID])
        guard let product = products.first else {
            throw StoreKitClientError.productUnavailable
        }
        return AccessProduct(
            id: product.id,
            displayName: product.displayName,
            productDescription: product.description,
            displayPrice: product.displayPrice
        )
    }

    func isLegacyPaidCustomer() async throws -> Bool {
        // `.verified` and `.unverified` are the only authoritative outcomes;
        // a thrown lookup error propagates so the caller can hold `.checking`
        // instead of misclassifying an offline legacy customer as free.
        let result = try await AppTransaction.shared
        switch result {
        case .verified(let transaction):
            return Self.isLegacyPaidCustomer(
                originalAppVersion: transaction.originalAppVersion,
                environment: transaction.environment
            )
        case .unverified:
            throw StoreKitClientError.entitlementUnverified
        }
    }

    /// Pure environment gate kept internal for deterministic coverage. Sandbox
    /// and local StoreKit testing report synthetic original versions (notably
    /// 1.0); applying the production cutoff there would hide the IAP from
    /// TestFlight/App Review.
    static func isLegacyPaidCustomer(
        originalAppVersion: String,
        environment: AppStore.Environment
    ) -> Bool {
        environment == .production
            && HostAccessProduct.isLegacyPaidBuild(
                originalAppVersion: originalAppVersion
            )
    }

    func hasUnlimitedHostsEntitlement() async throws -> Bool {
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                if transaction.productID == HostAccessProduct.productID,
                   transaction.revocationDate == nil {
                    return true
                }
            case .unverified(let transaction, _):
                if transaction.productID == HostAccessProduct.productID {
                    throw StoreKitClientError.entitlementUnverified
                }
            }
        }
        return false
    }

    func entitlementUpdates() -> AsyncStream<EntitlementUpdate> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let transaction) = result else { continue }
                    guard transaction.productID == HostAccessProduct.productID else { continue }
                    await transaction.finish()
                    if transaction.revocationDate != nil {
                        continuation.yield(.revoked)
                    } else {
                        continuation.yield(.granted)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func purchase() async throws -> PurchaseOutcome {
        let products = try await Product.products(for: [HostAccessProduct.productID])
        guard let product = products.first else {
            throw StoreKitClientError.productUnavailable
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch StoreKitError.userCancelled {
            // StoreKit Test simulates cancellation as a thrown error rather
            // than the `.userCancelled` result; both mean a quiet cancel.
            return .cancelled
        }
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                return .success
            case .unverified:
                throw StoreKitClientError.purchaseUnverified
            }
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            throw StoreKitClientError.purchaseUnverified
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }
}
