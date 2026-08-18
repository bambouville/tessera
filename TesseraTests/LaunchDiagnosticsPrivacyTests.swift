import XCTest
@testable import TmuxControl
@testable import Tessera

/// The tmux launch trace is written at `.ssh` level, which is on the
/// unconditional-emit list — it lands in `tessera-diagnostics.log` even with
/// verbose diagnostics off, in a file the user is invited to send to a
/// developer. Two of its fields leaked past the sanitizer; these pin the fixes
/// and the sanitizer behavior they depend on.
final class LaunchDiagnosticsPrivacyTests: XCTestCase {

    // MARK: - Failed-state descriptions

    /// `String(describing: SessionState.failed(_:))` renders the payload, which
    /// is `describeSSHError(_:)` falling through to `String(describing: error)`
    /// for anything that is neither a `LocalizedError` nor POSIX — NIO's
    /// connection errors among them.
    ///
    /// The sanitizer's only guard is `failed\([^)]*\)`, and `[^)]*` stops at the
    /// **first** `)`. NIO reports one `SingleConnectionFailure` per resolved
    /// address, so on any host with more than one A/AAAA record every address
    /// after the first sits outside the match and survives verbatim — into a
    /// file the user is invited to send to a developer.
    func testFailedStateDescriptionLeaksEveryAddressAfterTheFirst() throws {
        #if DEBUG
        let nioShaped = """
            NIOConnectionError(host: "prod-db.internal", port: 22, \
            dnsAError: nil, dnsAAAAError: nil, connectionErrors: \
            [SingleConnectionFailure(target: [IPv4]10.0.0.5/10.0.0.5:22, \
            error: connection reset), SingleConnectionFailure(target: \
            [IPv6]fd00::5/[fd00::5]:22, error: no route to host)])
            """
        let leaky = "launch state-change to=\(String(describing: SessionState.failed(nioShaped)))"
        let sanitized = DiagnosticLogStore.sanitizedMessageForTesting(leaky)

        XCTAssertTrue(
            sanitized.contains("fd00::5"),
            """
            This assertion documents WHY the log line may not use \
            String(describing:). If the sanitizer has since been taught to \
            redact the whole description, relax this test — do not relax the \
            call site.
            """
        )
        #else
        throw XCTSkip("the sanitizer test hook is DEBUG-only")
        #endif
    }

    /// The case name is the only form that may reach the log. Nothing
    /// diagnostic is lost: the reason is already logged, redacted, as
    /// `error='…'` by the transport.
    func testDiagnosticNameCarriesNoPayload() {
        XCTAssertEqual(SessionState.idle.diagnosticName, "idle")
        XCTAssertEqual(SessionState.connecting.diagnosticName, "connecting")
        XCTAssertEqual(SessionState.connected.diagnosticName, "connected")
        XCTAssertEqual(SessionState.disconnected.diagnosticName, "disconnected")

        let failed = SessionState.failed(
            #"NIOConnectionError(host: "prod-db.internal", target: [IPv4]10.0.0.5:22)"#
        )
        XCTAssertEqual(failed.diagnosticName, "failed")
        XCTAssertFalse(failed.diagnosticName.contains("prod-db.internal"))
        XCTAssertFalse(failed.diagnosticName.contains("10.0.0.5"))
    }

    // MARK: - Session-name correlation token

    /// The point of hashing rather than redacting: a redacted field collapses
    /// every session to one token and stops telling you which session was in
    /// use. `nameHash=` has to survive all three sanitizer rules or the
    /// correlation is lost anyway.
    func testNameHashSurvivesTheSanitizer() throws {
        #if DEBUG
        let digest = AutoTmuxScript.sessionNameDigest("acme-prod-payments")
        let line = "launch auto-tmux-send sid=1a2b3c4d bytes=412 nameHash=\(digest)"
        let sanitized = DiagnosticLogStore.sanitizedMessageForTesting(line)

        XCTAssertTrue(
            sanitized.contains("nameHash=\(digest)"),
            """
            nameHash must not collide with a sanitizer rule. It matches neither \
            the rule-1 field list nor rule-2's (which contains `names`, not \
            `nameHash`), and a bare 8-hex token has no dashes so the full-UUID \
            rule cannot match — the same reason `sid=` survives. Any rename of \
            this field has to re-check all three.
            """
        )
        #else
        throw XCTSkip("the sanitizer test hook is DEBUG-only")
        #endif
    }

    /// The fields this replaced. `name=` is absent from both allowlists, so a
    /// pinned-mode session name — the user's own label from
    /// `host.tmuxSessionName` — survived verbatim; renaming it to `session=`
    /// would have redacted it into uselessness instead.
    func testRawSessionNameFieldsAreTheOnesTheSanitizerCannotHelp() throws {
        #if DEBUG
        let raw = DiagnosticLogStore.sanitizedMessageForTesting(
            "launch auto-tmux-send name=acme-prod-payments bytes=412"
        )
        XCTAssertTrue(raw.contains("acme-prod-payments"), "name= is not on either allowlist")

        let redacted = DiagnosticLogStore.sanitizedMessageForTesting(
            "launch auto-tmux-send session=acme-prod-payments bytes=412"
        )
        XCTAssertTrue(redacted.contains("session=<redacted>"))
        XCTAssertFalse(
            redacted.contains("acme-prod"),
            "session= is redacted wholesale — every session collapses to one token"
        )
        #else
        throw XCTSkip("the sanitizer test hook is DEBUG-only")
        #endif
    }
}
