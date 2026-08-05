import XCTest
@testable import Tessera

/// Pure matrix coverage of the saved-host admission quota shared by the manual
/// add-host paths, Handoff prefill, and nearby bootstrap import. No StoreKit,
/// no persistence, no defaults.
final class SavedHostAdmissionPolicyTests: XCTestCase {
    func test_freeHostLimit_isExactlyOneSavedHost() {
        XCTAssertEqual(SavedHostAdmissionPolicy.freeHostLimit, 1)
    }

    func test_freeCustomer_firstSavedHost_isAllowed() {
        // 0 existing + 1 requested lands exactly on freeHostLimit: the
        // boundary is inclusive, so the very first saved host always fits.
        XCTAssertEqual(
            SavedHostAdmissionPolicy.decision(
                existingHostCount: 0,
                newRowCount: 1,
                access: .free
            ),
            .allow
        )
    }

    func test_freeCustomer_multiRowRequest_isAtomicallyBlocked() {
        // A Handoff/bootstrap batch is all-or-nothing: 0 + 2 exceeds the free
        // limit, so the whole request requires purchase. The policy must never
        // save one row of a multi-row request and silently drop the rest.
        XCTAssertEqual(
            SavedHostAdmissionPolicy.decision(
                existingHostCount: 0,
                newRowCount: 2,
                access: .free
            ),
            .requiresPurchase
        )
    }

    func test_oneSavedHost_requiresPurchaseForSecondRow() {
        XCTAssertEqual(
            SavedHostAdmissionPolicy.decision(
                existingHostCount: 1,
                newRowCount: 1,
                access: .free
            ),
            .requiresPurchase
        )
    }

    func test_freeCustomer_overLimit_staysBlockedForNewRows() {
        // Post-refund state: every saved host stays visible and launchable,
        // but no additional row may be saved while the count is above the
        // free limit.
        XCTAssertEqual(
            SavedHostAdmissionPolicy.decision(
                existingHostCount: 5,
                newRowCount: 1,
                access: .free
            ),
            .requiresPurchase
        )
    }

    func test_freeCustomer_zeroRowRequests_areAllowedUpToTheLimit() {
        // Edits, exact-match Handoff continuations, and bootstrap re-imports
        // of already-saved hosts add zero rows — allowed at any existing
        // count, including over-limit (e.g. a refunded customer re-importing
        // existing hosts), because nothing new is persisted. The same holds
        // while entitlement truth is still loading: with no row to gate there
        // is nothing an unknown state could accidentally permit.
        for access in [HostAccessState.free, .checking, .unlimited(.legacyPaid)] {
            for existing in [0, 1, 5] {
                XCTAssertEqual(
                    SavedHostAdmissionPolicy.decision(
                        existingHostCount: existing,
                        newRowCount: 0,
                        access: access
                    ),
                    .allow,
                    "zero-row request with \(existing) existing hosts must be allowed in state \(access)"
                )
            }
        }
    }

    func test_unlimitedLegacyPaid_allowsAnyCombination() {
        assertAllowsAnyCombination(access: .unlimited(.legacyPaid))
    }

    func test_unlimitedPurchasedIAP_allowsAnyCombination() {
        assertAllowsAnyCombination(access: .unlimited(.purchasedIAP))
    }

    func test_checkingEntitlement_allowsIncludedFirstHostButDefersUnknownOverage() {
        // The first free slot is safe under every possible entitlement result;
        // only a request that needs unlimited access must wait for StoreKit.
        let cases: [(existing: Int, requested: Int)] = [
            (1, 1),
            (5, 5),
        ]
        XCTAssertEqual(
            SavedHostAdmissionPolicy.decision(
                existingHostCount: 0,
                newRowCount: 1,
                access: .checking
            ),
            .allow
        )
        for (existing, requested) in cases {
            XCTAssertEqual(
                SavedHostAdmissionPolicy.decision(
                    existingHostCount: existing,
                    newRowCount: requested,
                    access: .checking
                ),
                .checkingEntitlement,
                "checking state must defer \(existing) existing + \(requested) new"
            )
        }
    }

    private func assertAllowsAnyCombination(
        access: HostAccessState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for existing in [0, 1, 100] {
            for requested in [1, 10] {
                XCTAssertEqual(
                    SavedHostAdmissionPolicy.decision(
                        existingHostCount: existing,
                        newRowCount: requested,
                        access: access
                    ),
                    .allow,
                    "\(access) must allow \(existing) existing + \(requested) new",
                    file: file,
                    line: line
                )
            }
        }
    }
}
