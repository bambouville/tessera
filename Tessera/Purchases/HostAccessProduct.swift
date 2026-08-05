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

    /// First `CFBundleVersion` that ships the free model. A verified App Store
    /// transaction whose original download build is below this cutoff belongs
    /// to a customer who paid for the app and is owed unlimited hosts.
    ///
    /// Paid releases used original build numbers through 3 (v0.1.2 shipped as
    /// build 3, and v0.2.0 reused build 1). The first free binary therefore
    /// uses build 4 and freezes 4 as this cutoff; neither value may be reset in
    /// later releases.
    static let freeModelFirstBuild = 4

    /// Whether a verified `AppTransaction.originalAppVersion` predates the
    /// free model and therefore represents a legacy paid customer.
    ///
    /// Numeric component-wise compare: `originalAppVersion < freeModelFirstBuild`.
    /// "9" < "10", "1.9" < "1.10", missing components = 0. Any unparseable
    /// component → false (never misgrant).
    static func isLegacyPaidBuild(originalAppVersion: String) -> Bool {
        let components = originalAppVersion.split(separator: ".", omittingEmptySubsequences: false)
        var numbers = [Int]()
        numbers.reserveCapacity(components.count)
        for component in components {
            // A negative component is nonsensical for a build string; treat it
            // as unparseable so it can never misgrant.
            guard let value = Int(component), value >= 0 else { return false }
            numbers.append(value)
        }

        let cutoff = [freeModelFirstBuild]
        let count = max(numbers.count, cutoff.count)
        for index in 0..<count {
            let original = index < numbers.count ? numbers[index] : 0
            let required = index < cutoff.count ? cutoff[index] : 0
            if original != required { return original < required }
        }
        return false
    }
}
