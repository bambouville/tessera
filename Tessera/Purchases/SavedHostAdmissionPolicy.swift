// Tessera/Purchases/SavedHostAdmissionPolicy.swift
import Foundation

/// Why a customer has unlimited hosts. The Settings detail names the source
/// honestly (`included with your original Tessera purchase` vs
/// `unlimited hosts purchased`).
enum HostUnlimitedSource: Equatable {
    case legacyPaid
    case purchasedIAP
}

/// The customer's resolved access level. `.checking` is the launch state while
/// StoreKit truth is still loading — never assume free while it is unknown.
enum HostAccessState: Equatable {
    case checking
    case free
    case unlimited(HostUnlimitedSource)
}

/// Verdict on a request to persist one or more new saved-host rows.
enum SavedHostAdmission: Equatable {
    case allow
    case requiresPurchase
    case checkingEntitlement
}

/// The one-host free quota, applied before persistence. Pure and shared by
/// every production host-creation path — New Host / Command-N, Handoff
/// prefill, and nearby-setup import — so keyboard shortcuts and cross-device
/// flows cannot bypass the limit. Multi-row requests are atomic: the whole
/// batch must fit or nothing is inserted.
enum SavedHostAdmissionPolicy {
    /// Number of `PersistedHost` rows a free customer may keep.
    static let freeHostLimit = 1

    static func decision(
        existingHostCount: Int,
        newRowCount: Int,
        access: HostAccessState
    ) -> SavedHostAdmission {
        // Admission below the free ceiling is entitlement-independent. This
        // lets a brand-new customer save the included first host even when
        // StoreKit is slow/offline. Zero-row edits and exact-match Handoffs
        // likewise remain allowed for an over-limit refunded customer.
        if newRowCount == 0
            || existingHostCount + newRowCount <= freeHostLimit {
            return .allow
        }
        switch access {
        case .unlimited:
            return .allow
        case .checking:
            return .checkingEntitlement
        case .free:
            return .requiresPurchase
        }
    }
}
