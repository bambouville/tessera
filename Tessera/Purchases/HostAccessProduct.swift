// Tessera/Purchases/HostAccessProduct.swift
import Foundation

/// Constants and pure rules behind the "Unlimited Saved Hosts" non-consumable
/// and the paid-to-free grandfather cutoff. Every Tessera feature is free; the
/// purchase changes only how many hosts the app remembers, and customers of
/// the original paid app are grandfathered into unlimited hosts without buying
/// the IAP.
enum HostAccessProduct {
    /// The single non-consumable product ID. Must match App Store Connect and
    /// the local `Tessera.storekit` test configuration exactly.
    static let productID = "com.bambouville.TesseraApp.unlimited_hosts"

    /// Customer-protective grandfather cutoff: August 14, 2026 at noon in New
    /// York (`2026-08-14T16:00:00Z`). v0.3.1 became free on August 12, but its
    /// production grandfathering was incorrect. Everyone whose verified
    /// original download predates this grace cutoff keeps unlimited hosts.
    ///
    /// `originalAppVersion` cannot represent this boundary because v0.2.0 and
    /// the shipped v0.3.1 both used `CFBundleVersion = 1`. Keep this date frozen
    /// even as later releases increment their build number.
    static let legacyPaidCutoffDate = Date(timeIntervalSince1970: 1_786_723_200)

    /// Whether the verified production app purchase predates the free model.
    /// The boundary is strict: a download at or after the cutoff is a free-model
    /// customer and needs the non-consumable for unlimited saved hosts.
    static func isLegacyPaidPurchase(originalPurchaseDate: Date) -> Bool {
        originalPurchaseDate < legacyPaidCutoffDate
    }
}
