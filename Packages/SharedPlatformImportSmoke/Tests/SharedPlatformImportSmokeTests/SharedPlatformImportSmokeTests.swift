import XCTest
import SharedPlatformImportSmoke

final class SharedPlatformImportSmokeTests: XCTestCase {
    func test_publicSharedModulesImportAndComposeOnMacOS() throws {
        let result = try SharedPlatformImportProbe.run()

        XCTAssertTrue(result.appleHandoffAccepted)
        XCTAssertTrue(result.appleEnrollmentAccepted)
        XCTAssertEqual(
            result.publicKeyFingerprint,
            "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA"
        )
        XCTAssertEqual(
            result.tmuxIdentityQuery,
            "display-message -p -t shared-smoke '#{session_id}\\t#{session_name}\\t#{socket_path}'"
        )
        XCTAssertEqual(result.parsedTmuxMessageCount, 1)
        XCTAssertEqual(result.abiInputByteCount, 16 * 1024)
        XCTAssertEqual(result.terminalKeyBytes, [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41])
        XCTAssertEqual(result.terminalMouseBytes, Array("\u{1B}[<64;42;7M".utf8))
    }
}
