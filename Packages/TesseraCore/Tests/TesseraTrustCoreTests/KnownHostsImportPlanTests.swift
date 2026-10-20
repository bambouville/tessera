import Foundation
import XCTest
@testable import TesseraTrustCore

final class KnownHostsImportPlanTests: XCTestCase {

    // MARK: - Helpers

    private func keyString(_ seed: UInt8) -> String {
        TrustFixtures.ed25519KeyString(seed: seed)
    }

    private func fingerprint(_ seed: UInt8) -> String {
        TrustFixtures.ed25519Fingerprint(seed: seed)
    }

    private func plan(
        _ text: String,
        existing: [String: String] = [:]
    ) -> KnownHostsImportPlan {
        OpenSSHKnownHostsCodec.importPlan(text: text, existingFingerprints: existing)
    }

    private func normalizedPlan(
        _ text: String,
        existing: [String: String] = [:]
    ) -> KnownHostsImportPlan {
        OpenSSHKnownHostsCodec.importPlan(
            text: text,
            existingFingerprints: existing,
            endpointNormalization: .normalized
        )
    }

    private func reasons(_ plan: KnownHostsImportPlan) -> [KnownHostsImportRejectionReason] {
        plan.rejections.map(\.reason)
    }

    // MARK: - Classification

    func testClassifiesAddReplaceAndUnchanged() {
        let result = plan(
            """
            # exported by OpenSSH

            same.example \(keyString(1))
            [rotate.example]:2222 \(keyString(2))
            new.example \(keyString(3)) trailing comment ignored
            """,
            existing: [
                "same.example:22": fingerprint(1),
                "rotate.example:2222": fingerprint(9),
            ]
        )

        XCTAssertEqual(result.addCount, 1)
        XCTAssertEqual(result.replaceCount, 1)
        XCTAssertEqual(result.unchangedCount, 1)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertEqual(
            result.candidates.first { $0.action == .replace }?.endpointKey,
            "rotate.example:2222"
        )
        XCTAssertEqual(
            result.candidates.first { $0.action == .replace }?.expectedPriorFingerprint,
            fingerprint(9)
        )
        XCTAssertNil(result.candidates.first { $0.action == .add }?.expectedPriorFingerprint)
        XCTAssertFalse(result.isNoOp)
    }

    func testCandidatesAreOrderedByLineThenEndpoint() {
        let result = plan(
            """
            zeta.example,alpha.example \(keyString(1))
            middle.example \(keyString(2))
            """
        )

        XCTAssertEqual(
            result.candidates.map(\.endpointKey),
            ["alpha.example:22", "zeta.example:22", "middle.example:22"]
        )
        XCTAssertEqual(result.candidates.map(\.lineNumber), [1, 1, 2])
    }

    // MARK: - Comma-separated host lists

    func testEveryTokenOfACommaListBecomesItsOwnCandidate() {
        let result = plan("a.example,b.example,[c.example]:2200 \(keyString(1))")

        XCTAssertEqual(
            Set(result.candidates.map(\.endpointKey)),
            ["a.example:22", "b.example:22", "c.example:2200"]
        )
        XCTAssertTrue(result.candidates.allSatisfy { $0.fingerprint == self.fingerprint(1) })
        XCTAssertTrue(result.rejections.isEmpty)
    }

    func testABadTokenRejectsOnlyItselfAndTheRestOfTheListSurvives() {
        let result = plan("good.example,*.bad \(keyString(1))")

        XCTAssertEqual(result.candidates.map(\.endpointKey), ["good.example:22"])
        XCTAssertEqual(reasons(result), [.wildcardOrNegatedHost])
        XCTAssertEqual(result.rejections.first?.source, "*.bad")
    }

    func testAnInvalidKeyRejectsTheLineOnceNotOncePerHostToken() {
        let result = plan("a.example,b.example,c.example ssh-ed25519 not!base64")

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(reasons(result), [.invalidPublicKey])
    }

    // MARK: - Rejection reasons

    func testMissingFieldsIsReportedBeforeTheMarkerCheck() {
        // "@cert-authority host" is incomplete first and a marker second; the
        // user is told the line is short, matching the shipped iOS ordering.
        let result = plan("@cert-authority host.example")

        XCTAssertEqual(reasons(result), [.missingFields])
    }

    func testCertAuthorityAndRevokedMarkersAreRejectedPerLine() {
        let result = plan(
            """
            @cert-authority ca.example \(keyString(1))
            @revoked bad.example \(keyString(2))
            """
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(
            reasons(result),
            [.unsupportedMarker("@cert-authority"), .unsupportedMarker("@revoked")]
        )
        XCTAssertEqual(result.rejections.map(\.lineNumber), [1, 2])
    }

    func testHashedHostsAreRejectedWithTheirOwnReason() {
        let result = plan("|1|F1E1MjA=|Qk9HVVM= \(keyString(1))")

        XCTAssertEqual(reasons(result), [.hashedHost])
    }

    func testWildcardQuestionMarkAndNegatedHostsAreRejected() {
        let result = plan(
            """
            *.example \(keyString(1))
            ho?st.example \(keyString(1))
            !nope.example \(keyString(1))
            """
        )

        XCTAssertEqual(
            reasons(result),
            [.wildcardOrNegatedHost, .wildcardOrNegatedHost, .wildcardOrNegatedHost]
        )
    }

    func testEmptyHostTokenIsRejected() {
        let result = plan("a.example,,b.example \(keyString(1))")

        XCTAssertEqual(reasons(result), [.emptyHostField])
        XCTAssertEqual(
            Set(result.candidates.map(\.endpointKey)),
            ["a.example:22", "b.example:22"]
        )
    }

    func testMalformedBracketedHostsAreRejected() {
        let result = plan(
            """
            [host.example:2222 \(keyString(1))
            [host.example]2222 \(keyString(1))
            [host.example] \(keyString(1))
            """
        )

        XCTAssertEqual(
            reasons(result),
            [
                .invalidBracketedHostPort,
                .invalidBracketedHostPort,
                .invalidBracketedHostPort,
            ]
        )
    }

    func testBracketedHostsWithBadPortsOrEmptyHostsAreRejected() {
        let result = plan(
            """
            []:22 \(keyString(1))
            [host.example]:0 \(keyString(1))
            [host.example]:65536 \(keyString(1))
            [host.example]:ssh \(keyString(1))
            """
        )

        XCTAssertEqual(
            reasons(result),
            [.invalidHostOrPort, .invalidHostOrPort, .invalidHostOrPort, .invalidHostOrPort]
        )
    }

    func testShortLinesAreRejectedAndCommentsAndBlanksAreSkipped() {
        let result = plan(
            """
            # a comment

            missing-fields
            host.example ssh-ed25519
            """
        )

        XCTAssertEqual(reasons(result), [.missingFields, .missingFields])
        XCTAssertEqual(result.rejections.map(\.lineNumber), [3, 4])
    }

    func testStructuralValidationRejectsAKeyThatLiesAboutItsAlgorithm() {
        let result = plan("host.example \(TrustFixtures.algorithmLyingKeyString())")

        XCTAssertEqual(reasons(result), [.invalidPublicKey])
    }

    // MARK: - Ambiguity and duplicates

    func testDifferentKeysForOneEndpointRejectEveryContributingLine() {
        let result = plan(
            """
            same.example \(keyString(1))
            same.example \(keyString(2))
            """
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(reasons(result), [.ambiguousEndpoint, .ambiguousEndpoint])
        XCTAssertEqual(result.rejections.map(\.lineNumber), [1, 2])
        XCTAssertTrue(result.rejections.allSatisfy { $0.source == "same.example:22" })
    }

    func testAmbiguityInOneEndpointDoesNotPoisonTheOthers() {
        let result = plan(
            """
            ambiguous.example \(keyString(1))
            fine.example \(keyString(3))
            ambiguous.example \(keyString(2))
            """
        )

        XCTAssertEqual(result.candidates.map(\.endpointKey), ["fine.example:22"])
        XCTAssertEqual(reasons(result), [.ambiguousEndpoint, .ambiguousEndpoint])
    }

    func testRepeatedIdenticalPinsWarnAndKeepOnlyTheFirst() {
        let result = plan(
            """
            dupe.example \(keyString(1))
            dupe.example \(keyString(1))
            dupe.example \(keyString(1))
            """
        )

        XCTAssertEqual(result.candidates.map(\.lineNumber), [1])
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertEqual(
            result.warnings,
            [
                .duplicatePinIgnored(lineNumber: 2, endpointKey: "dupe.example:22"),
                .duplicatePinIgnored(lineNumber: 3, endpointKey: "dupe.example:22"),
            ]
        )
    }

    func testPlansAreReproducibleForTheSameInput() {
        let text = """
        a.example \(keyString(1))
        a.example \(keyString(2))
        b.example \(keyString(3))
        b.example \(keyString(4))
        c.example \(keyString(5))
        c.example \(keyString(5))
        """

        let first = plan(text)
        for _ in 0..<20 {
            XCTAssertEqual(plan(text), first)
        }
    }

    // MARK: - Plan-then-apply

    func testMalformedLineThreeOfFiveLeavesTwoCandidatesOneRejectionAndNoMutation() {
        let store = RecordingPinStore(pins: ["existing.example:22": fingerprint(7)])

        let result = OpenSSHKnownHostsCodec.importPlan(
            text: """
            # exported by OpenSSH
            good-one.example \(keyString(1))
            broken.example ssh-ed25519 not!base64
            good-two.example \(keyString(2))

            """,
            existingFingerprints: store.pins
        )

        XCTAssertEqual(
            result.candidates.map(\.endpointKey),
            ["good-one.example:22", "good-two.example:22"]
        )
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections.first?.lineNumber, 3)
        XCTAssertEqual(result.rejections.first?.reason, .invalidPublicKey)
        // Building a plan is pure: the store is untouched until the user
        // confirms, so one bad line cannot leave a half-imported pin set.
        XCTAssertEqual(store.mutationCount, 0)
        XCTAssertEqual(store.pins, ["existing.example:22": fingerprint(7)])
    }

    // MARK: - Endpoint key space

    // A plan is only honest if it is computed in the SAME key space as the
    // store it will be applied to. These pin both modes, and the four ways the
    // mismatch used to show up.

    func testVerbatimIsTheDefaultAndKeysCandidatesExactlyAsTheFileSpellsThem() {
        // iOS keys its records by the address as the user typed it, so it must
        // keep getting the file's own spelling — including the shadow key that
        // a differently spelled file produces. This is the contract, not a bug:
        // rewriting it would land an import on a second key for the same host.
        let result = plan(
            "Rotate.Example. \(keyString(2))",
            existing: ["rotate.example:22": fingerprint(9)]
        )

        XCTAssertEqual(result.candidates.map(\.endpointKey), ["Rotate.Example.:22"])
        XCTAssertEqual(result.candidates.first?.action, .add)
        XCTAssertNil(result.candidates.first?.expectedPriorFingerprint)
    }

    func testNormalizedFindsAStoredPinTheFileSpellsDifferently() {
        // Case, a trailing root dot, and IPv6 brackets are all spellings of one
        // name. Under `.normalized` each collapses onto the stored key, so the
        // sheet says "replace" and carries the fingerprint apply-time will
        // compare-and-swap against — instead of promising an `add` that the
        // store's guard then refuses, leaving the summary a lie.
        let result = normalizedPlan(
            """
            Rotate.Example. \(keyString(2))
            [2001:DB8::1]:2222 \(keyString(3))
            Same.Example \(keyString(1))
            """,
            existing: [
                "rotate.example:22": fingerprint(9),
                "2001:db8::1:2222": fingerprint(3),
                "same.example:22": fingerprint(1),
            ]
        )

        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertEqual(
            result.candidates.map(\.endpointKey),
            ["rotate.example:22", "2001:db8::1:2222", "same.example:22"]
        )
        XCTAssertEqual(result.candidates.map(\.action), [.replace, .unchanged, .unchanged])
        XCTAssertEqual(result.candidates[0].expectedPriorFingerprint, fingerprint(9))
        XCTAssertEqual(result.candidates[1].expectedPriorFingerprint, fingerprint(3))
        XCTAssertEqual(result.replaceCount, 1)
        XCTAssertEqual(result.unchangedCount, 2)
        XCTAssertEqual(result.addCount, 0)
    }

    func testVerbatimWouldHaveCalledEveryOneOfThoseAnAdd() {
        // The same file under the shipped default: three adds, no prior
        // fingerprints, and a store that refuses all three at apply time.
        let existing = [
            "rotate.example:22": fingerprint(9),
            "2001:db8::1:2222": fingerprint(3),
            "same.example:22": fingerprint(1),
        ]
        let result = plan(
            """
            Rotate.Example. \(keyString(2))
            [2001:DB8::1]:2222 \(keyString(3))
            Same.Example \(keyString(1))
            """,
            existing: existing
        )

        XCTAssertEqual(result.addCount, 3)
        XCTAssertTrue(result.candidates.allSatisfy { $0.expectedPriorFingerprint == nil })
        XCTAssertTrue(result.candidates.allSatisfy { existing[$0.endpointKey] == nil })
    }

    func testNormalizedRejectsTwoCaseVariantLinesWithDifferentKeysAsOneAmbiguousEndpoint() {
        // Two spellings of one host are one endpoint. Keyed verbatim they were
        // two, so no ambiguity fired, both were planned as adds, and whichever
        // applied last silently won — a pin store quietly accepting the second
        // key it was shown.
        let result = normalizedPlan(
            """
            Same.Example \(keyString(1))
            same.example. \(keyString(2))
            """
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(reasons(result), [.ambiguousEndpoint, .ambiguousEndpoint])
        XCTAssertEqual(result.rejections.map(\.lineNumber), [1, 2])
        XCTAssertTrue(result.rejections.allSatisfy { $0.source == "same.example:22" })

        // Same input, same-spelling: the rejection is identical, which is the
        // point — spelling must not change the classification.
        let sameSpelling = normalizedPlan(
            """
            same.example \(keyString(1))
            same.example \(keyString(2))
            """
        )
        XCTAssertEqual(reasons(sameSpelling), reasons(result))
        XCTAssertEqual(sameSpelling.rejections, result.rejections)
    }

    func testVerbatimLetsThoseTwoCaseVariantLinesBothThroughUnnoticed() {
        let result = plan(
            """
            Same.Example \(keyString(1))
            same.example. \(keyString(2))
            """
        )

        // Two candidates, two different keys, no rejection and no warning:
        // exactly the silent last-writer-wins the normalized mode closes.
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(Set(result.candidates.map(\.fingerprint)).count, 2)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testNormalizedWarnsWhenCaseVariantLinesCarryTheSameKey() {
        let result = normalizedPlan(
            """
            Dupe.Example \(keyString(1))
            dupe.example \(keyString(1))
            DUPE.EXAMPLE. \(keyString(1))
            """
        )

        XCTAssertEqual(result.candidates.map(\.endpointKey), ["dupe.example:22"])
        XCTAssertEqual(result.candidates.map(\.lineNumber), [1])
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertEqual(
            result.warnings,
            [
                .duplicatePinIgnored(lineNumber: 2, endpointKey: "dupe.example:22"),
                .duplicatePinIgnored(lineNumber: 3, endpointKey: "dupe.example:22"),
            ]
        )
    }

    func testNormalizedRejectsOnlyTheTokenThatHasNoNormalizedForm() {
        // `.` survives token parsing — non-empty, unhashed, unpatterned — and
        // then normalizes to nothing. It is named rather than silently kept in
        // the other key space.
        let result = normalizedPlan("good.example,. \(keyString(1))")

        XCTAssertEqual(result.candidates.map(\.endpointKey), ["good.example:22"])
        XCTAssertEqual(reasons(result), [.unnormalizableHost])
        XCTAssertEqual(result.rejections.first?.source, ".")
    }

    func testVerbatimStaysByteIdenticalToTheShippedDefault() {
        // Every existing expectation in this file exercises the default; this
        // pins that asking for `.verbatim` explicitly is the same call.
        let text = """
        # exported by OpenSSH
        Same.Example \(keyString(1))
        [Rotate.Example]:2222 \(keyString(2))
        good.example,*.bad,|1|c2FsdA==|aGFzaA== \(keyString(3))
        @cert-authority ca.example \(keyString(4))
        dupe.example \(keyString(5))
        dupe.example \(keyString(5))
        ambiguous.example \(keyString(6))
        ambiguous.example \(keyString(7))
        broken.example ssh-ed25519 not!base64
        missing-fields
        """
        let existing = ["same.example:22": fingerprint(1)]

        XCTAssertEqual(
            OpenSSHKnownHostsCodec.importPlan(
                text: text,
                existingFingerprints: existing,
                endpointNormalization: .verbatim
            ),
            plan(text, existing: existing)
        )
    }

    // MARK: - Export

    func testExportUsesBareHostAtPort22AndBracketsOtherwise() {
        XCTAssertEqual(
            OpenSSHKnownHostsCodec.exportLine(
                endpointKey: "host.example:22",
                keyString: keyString(1)
            ),
            "host.example \(keyString(1))"
        )
        XCTAssertEqual(
            OpenSSHKnownHostsCodec.exportLine(
                endpointKey: "host.example:2222",
                keyString: keyString(1)
            ),
            "[host.example]:2222 \(keyString(1))"
        )
    }

    func testExportPassesThroughKeysThatAreNotHostColonPort() {
        XCTAssertEqual(
            OpenSSHKnownHostsCodec.knownHostsHostField(fromEndpointKey: "host.example"),
            "host.example"
        )
        XCTAssertEqual(
            OpenSSHKnownHostsCodec.knownHostsHostField(fromEndpointKey: "host.example:ssh"),
            "host.example:ssh"
        )
    }

    func testExportTextIsSortedAndNewlineTerminated() {
        let text = OpenSSHKnownHostsCodec.exportText(records: [
            KnownHostsExportRecord(endpointKey: "zeta.example:22", keyString: keyString(1)),
            KnownHostsExportRecord(endpointKey: "alpha.example:22", keyString: keyString(2)),
        ])

        XCTAssertTrue(text.hasPrefix("alpha.example "))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertEqual(OpenSSHKnownHostsCodec.exportText(records: []), "")
    }

    func testExportRoundTripsBackThroughImportAsEntirelyUnchanged() {
        let records = [
            KnownHostsExportRecord(endpointKey: "default.example:22", keyString: keyString(1)),
            KnownHostsExportRecord(endpointKey: "custom.example:2200", keyString: keyString(2)),
        ]
        let existing = [
            "default.example:22": fingerprint(1),
            "custom.example:2200": fingerprint(2),
        ]

        let text = OpenSSHKnownHostsCodec.exportText(records: records)
        let result = plan(text, existing: existing)

        // ssh(1) shape on the way out, same endpoints on the way back in.
        XCTAssertTrue(text.contains("default.example ssh-ed25519 "))
        XCTAssertTrue(text.contains("[custom.example]:2200 ssh-ed25519 "))
        XCTAssertEqual(result.unchangedCount, 2)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertTrue(result.isNoOp)
    }
}

/// Stands in for a pin store so a test can prove that building a plan never
/// writes. Any mutation goes through `apply`, which the planning path must
/// never call.
private final class RecordingPinStore {
    private(set) var pins: [String: String]
    private(set) var mutationCount = 0

    init(pins: [String: String]) {
        self.pins = pins
    }

    func apply(_ candidate: KnownHostsImportCandidate) {
        pins[candidate.endpointKey] = candidate.fingerprint
        mutationCount += 1
    }
}
