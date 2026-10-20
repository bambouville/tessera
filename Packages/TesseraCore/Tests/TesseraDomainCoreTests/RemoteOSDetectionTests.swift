import Foundation
import XCTest
@testable import TesseraDomainCore

/// Ported from the iOS `OSDetectorTests`, which pin both classifiers against
/// real host transcripts. The iOS copies stay where they are and now also
/// assert that `OSDetector` / `OSDetectionProbe` still delegate here.
final class RemoteOSDetectionTests: XCTestCase {

    // MARK: - Network path

    func testDetectsDocumentedWSLTailscaleMTURisk() {
        let output = """
        Linux
        ID=ubuntu
        __TESSERA_NETWORK__ kernel=5.15.153.1-microsoft-standard-WSL2
        __TESSERA_NETWORK__ tailscale_path=1
        __TESSERA_NETWORK__ default_mtu=1280
        __TESSERA_NETWORK__ tailscale_mtu=1280
        """

        let result = RemoteOSDetection.parse(probeOutput: output)

        XCTAssertEqual(result.osHint, "ubuntu")
        XCTAssertEqual(
            result.networkPathAssessment,
            .warning(
                WSLTailscaleMTUWarning(
                    defaultInterfaceMTU: 1_280,
                    tailscaleInterfaceMTU: 1_280
                )
            )
        )
    }

    func testClearsRiskWhenOuterMTUIsRemediated() {
        let output = """
        Linux
        __TESSERA_NETWORK__ kernel=5.15.153.1-microsoft-standard-WSL2
        __TESSERA_NETWORK__ tailscale_path=1
        __TESSERA_NETWORK__ default_mtu=1340
        __TESSERA_NETWORK__ tailscale_mtu=1280
        """

        XCTAssertEqual(
            RemoteOSDetection.parse(probeOutput: output).networkPathAssessment,
            .notAtRisk
        )
    }

    func testDoesNotWarnWhenSSHDidNotLandOnTailscale() {
        let output = """
        Linux
        __TESSERA_NETWORK__ kernel=5.15.153.1-microsoft-standard-WSL2
        __TESSERA_NETWORK__ tailscale_path=0
        __TESSERA_NETWORK__ default_mtu=1280
        __TESSERA_NETWORK__ tailscale_mtu=1280
        """

        XCTAssertEqual(
            RemoteOSDetection.parse(probeOutput: output).networkPathAssessment,
            .notAtRisk
        )
    }

    func testRetainsCachedKnowledgeWhenWSLFieldsAreIncomplete() {
        let output = """
        Linux
        __TESSERA_NETWORK__ kernel=5.15.153.1-microsoft-standard-WSL2
        __TESSERA_NETWORK__ tailscale_path=unknown
        __TESSERA_NETWORK__ default_mtu=
        __TESSERA_NETWORK__ tailscale_mtu=
        """

        XCTAssertEqual(
            RemoteOSDetection.parse(probeOutput: output).networkPathAssessment,
            .unavailable
        )
    }

    /// A non-WSL kernel is a completed probe, not a missing one: callers may
    /// clear a warning cached by an earlier connection.
    func testNonWSLKernelIsNotAtRiskAndAMissingKernelIsUnavailable() {
        XCTAssertEqual(
            RemoteOSDetection.parse(
                probeOutput: "Linux\n__TESSERA_NETWORK__ kernel=6.1.0-18-amd64\n"
            ).networkPathAssessment,
            .notAtRisk
        )
        XCTAssertEqual(
            RemoteOSDetection.parse(
                probeOutput: "Linux\n__TESSERA_NETWORK__ kernel=\n"
            ).networkPathAssessment,
            .unavailable
        )
        XCTAssertEqual(
            RemoteOSDetection.parse(probeOutput: "Linux\n").networkPathAssessment,
            .unavailable
        )
    }

    /// The probe script's trailing `exit 0` is load-bearing — a missing
    /// release file makes the last `cat` exit non-zero, and the SSH client
    /// then discards every byte the probe already produced.
    func testProbeCommandEndsWithTheLoadBearingExitZero() {
        XCTAssertTrue(RemoteOSDetection.probeCommand.hasSuffix("exit 0"))
        XCTAssertTrue(RemoteOSDetection.probeCommand.hasPrefix("uname -s 2>/dev/null"))
        for field in ["kernel=", "tailscale_path=", "default_mtu=", "tailscale_mtu="] {
            XCTAssertTrue(
                RemoteOSDetection.probeCommand.contains(
                    "\(RemoteOSDetection.networkMarker) \(field)"
                ),
                field
            )
        }
    }

    // MARK: - OS family

    func testDarwinUnameMapsToMacOS() {
        let output = """
        Darwin
        ProductName:\t\tmacOS
        ProductVersion:\t\t14.6.1
        BuildVersion:\t\t23G93
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "macos")
    }

    func testDarwinWinsBeforeLinuxReleaseMarkers() {
        let output = """
        Darwin
        ID=ubuntu
        NAME="Ubuntu"
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "macos")
    }

    /// A login/interactive probe shell can print banners before the probe
    /// command runs, so "Darwin" is no longer the first line.
    func testDarwinWithLeadingShellBannerMapsToMacOS() {
        let output = """
        Last login: Tue Jun 17 09:14:22 on ttys001

        Darwin
        ProductName:\t\tmacOS
        ProductVersion:\t\t14.6.1
        BuildVersion:\t\t23G93
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "macos")
    }

    /// If `uname` output never made it through (e.g. swallowed by a dotfile
    /// that printed first), the sw_vers ProductName line is enough.
    func testSwVersWithoutUnameMapsToMacOS() {
        let output = """
        some unrelated noise from .zprofile
        ProductName:\t\tmacOS
        ProductVersion:\t\t14.6.1
        BuildVersion:\t\t23G93
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "macos")
    }

    func testMacOSXProductLineMapsToMacOS() {
        let output = """
        ProductName:\tMac OS X
        ProductVersion:\t10.15.7
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "macos")
    }

    /// A banner mentioning "darwin" inline must not be mistaken for macOS —
    /// only a bare "Darwin" uname line counts.
    func testLinuxWithLeadingBannerMapsToLinux() {
        let output = """
        Welcome to my server (managed by darwin-team)
        Linux
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "linux")
    }

    func testRaspbianIDMapsToRaspbian() {
        let output = """
        Linux
        PRETTY_NAME="Raspbian GNU/Linux 12 (bookworm)"
        NAME="Raspbian GNU/Linux"
        VERSION_ID="12"
        VERSION="12 (bookworm)"
        ID=raspbian
        ID_LIKE=debian
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "raspbian")
    }

    func testRaspbianNameWinsBeforeUbuntuMarker() {
        let output = """
        Linux
        PRETTY_NAME="Raspbian GNU/Linux 12 (bookworm)"
        ID=ubuntu
        ID_LIKE=debian
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "raspbian")
    }

    func testUbuntuIDMapsToUbuntu() {
        let output = """
        Linux
        PRETTY_NAME="Ubuntu 22.04.4 LTS"
        NAME="Ubuntu"
        VERSION_ID="22.04"
        VERSION="22.04.4 LTS (Jammy Jellyfish)"
        VERSION_CODENAME=jammy
        ID=ubuntu
        ID_LIKE=debian
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "ubuntu")
    }

    func testUbuntuNameMapsToUbuntu() {
        let output = """
        Linux
        NAME="Ubuntu"
        VERSION_ID="22.04"
        ID_LIKE=debian
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "ubuntu")
    }

    func testAlpineIDMapsToAlpine() {
        let output = """
        Linux
        NAME="Alpine Linux"
        ID=alpine
        VERSION_ID=3.19.1
        PRETTY_NAME="Alpine Linux v3.19"
        HOME_URL="https://alpinelinux.org/"
        3.19.1
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "alpine")
    }

    func testAlpineReleaseFallbackMapsToAlpine() {
        XCTAssertEqual(
            RemoteOSDetection.parseOSFamily(probeOutput: "Linux\n3.19.1"),
            "alpine"
        )
        XCTAssertEqual(
            RemoteOSDetection.parseOSFamily(probeOutput: "Linux\nedge"),
            "alpine"
        )
    }

    func testDebianIDMapsToDebian() {
        let output = """
        Linux
        PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
        NAME="Debian GNU/Linux"
        VERSION_ID="12"
        VERSION="12 (bookworm)"
        VERSION_CODENAME=bookworm
        ID=debian
        HOME_URL="https://www.debian.org/"
        12.5
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "debian")
    }

    func testDebianVersionFallbackMapsToDebian() {
        XCTAssertEqual(
            RemoteOSDetection.parseOSFamily(probeOutput: "Linux\n12.5"),
            "debian"
        )
    }

    func testDebianSidFallbackMapsToDebian() {
        XCTAssertEqual(
            RemoteOSDetection.parseOSFamily(probeOutput: "Linux\nbookworm/sid"),
            "debian"
        )
    }

    func testIDLikeDebianDoesNotOverrideUbuntu() {
        let output = """
        Linux
        ID=ubuntu
        ID_LIKE=debian
        VERSION_ID="22.04"
        """

        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: output), "ubuntu")
    }

    func testGenericLinuxMapsToLinux() {
        XCTAssertEqual(RemoteOSDetection.parseOSFamily(probeOutput: "Linux\n"), "linux")
    }

    func testUnknownUnameReturnsNil() {
        XCTAssertNil(RemoteOSDetection.parseOSFamily(probeOutput: "FreeBSD\n12.5\n"))
    }

    func testEmptyOutputReturnsNil() {
        XCTAssertNil(RemoteOSDetection.parseOSFamily(probeOutput: ""))
    }

    /// The warning is persisted per host, so its coding keys are a
    /// compatibility surface, not an implementation detail.
    func testWarningCodingKeysAreStable() throws {
        let encoded = try JSONEncoder().encode(
            WSLTailscaleMTUWarning(defaultInterfaceMTU: 1_280, tailscaleInterfaceMTU: 1_280)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["defaultInterfaceMTU", "tailscaleInterfaceMTU"])
        XCTAssertEqual(
            try JSONDecoder().decode(WSLTailscaleMTUWarning.self, from: encoded),
            WSLTailscaleMTUWarning(defaultInterfaceMTU: 1_280, tailscaleInterfaceMTU: 1_280)
        )
    }
}
