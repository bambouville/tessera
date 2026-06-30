import XCTest
@testable import Tessera

final class OSDetectorTests: XCTestCase {
    func test_darwinUname_mapsToMacOS() {
        let output = """
        Darwin
        ProductName:\t\tmacOS
        ProductVersion:\t\t14.6.1
        BuildVersion:\t\t23G93
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "macos")
    }

    func test_darwinWinsBeforeLinuxReleaseMarkers() {
        let output = """
        Darwin
        ID=ubuntu
        NAME="Ubuntu"
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "macos")
    }

    func test_darwinWithLeadingShellBanner_mapsToMacOS() {
        // A login/interactive probe shell can print banners before the
        // probe command runs, so "Darwin" is no longer the first line.
        let output = """
        Last login: Tue Jun 17 09:14:22 on ttys001

        Darwin
        ProductName:\t\tmacOS
        ProductVersion:\t\t14.6.1
        BuildVersion:\t\t23G93
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "macos")
    }

    func test_swVersWithoutUname_mapsToMacOS() {
        // If `uname` output never made it through (e.g. swallowed by a
        // dotfile that printed first), the sw_vers ProductName line is
        // enough to recognise macOS.
        let output = """
        some unrelated noise from .zprofile
        ProductName:\t\tmacOS
        ProductVersion:\t\t14.6.1
        BuildVersion:\t\t23G93
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "macos")
    }

    func test_macOSXProductLine_mapsToMacOS() {
        let output = """
        ProductName:\tMac OS X
        ProductVersion:\t10.15.7
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "macos")
    }

    func test_linuxWithLeadingBanner_mapsToLinux() {
        let output = """
        Welcome to my server (managed by darwin-team)
        Linux
        """

        // A banner mentioning "darwin" inline must not be mistaken for
        // macOS — only a bare "Darwin" uname line counts.
        XCTAssertEqual(OSDetector.parse(probeOutput: output), "linux")
    }

    func test_raspbianID_mapsToRaspbian() {
        let output = """
        Linux
        PRETTY_NAME="Raspbian GNU/Linux 12 (bookworm)"
        NAME="Raspbian GNU/Linux"
        VERSION_ID="12"
        VERSION="12 (bookworm)"
        ID=raspbian
        ID_LIKE=debian
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "raspbian")
    }

    func test_raspbianNameWinsBeforeUbuntuMarker() {
        let output = """
        Linux
        PRETTY_NAME="Raspbian GNU/Linux 12 (bookworm)"
        ID=ubuntu
        ID_LIKE=debian
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "raspbian")
    }

    func test_ubuntuID_mapsToUbuntu() {
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

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "ubuntu")
    }

    func test_ubuntuName_mapsToUbuntu() {
        let output = """
        Linux
        NAME="Ubuntu"
        VERSION_ID="22.04"
        ID_LIKE=debian
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "ubuntu")
    }

    func test_alpineID_mapsToAlpine() {
        let output = """
        Linux
        NAME="Alpine Linux"
        ID=alpine
        VERSION_ID=3.19.1
        PRETTY_NAME="Alpine Linux v3.19"
        HOME_URL="https://alpinelinux.org/"
        3.19.1
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "alpine")
    }

    func test_alpineReleaseFallback_mapsToAlpine() {
        let output = """
        Linux
        3.19.1
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "alpine")
    }

    func test_debianID_mapsToDebian() {
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

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "debian")
    }

    func test_debianVersionFallback_mapsToDebian() {
        let output = """
        Linux
        12.5
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "debian")
    }

    func test_debianSidFallback_mapsToDebian() {
        let output = """
        Linux
        bookworm/sid
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "debian")
    }

    func test_idLikeDebianDoesNotOverrideUbuntu() {
        let output = """
        Linux
        ID=ubuntu
        ID_LIKE=debian
        VERSION_ID="22.04"
        """

        XCTAssertEqual(OSDetector.parse(probeOutput: output), "ubuntu")
    }

    func test_genericLinux_mapsToLinux() {
        XCTAssertEqual(OSDetector.parse(probeOutput: "Linux\n"), "linux")
    }

    func test_unknownUname_returnsNil() {
        XCTAssertNil(OSDetector.parse(probeOutput: "FreeBSD\n12.5\n"))
    }

    func test_emptyOutput_returnsNil() {
        XCTAssertNil(OSDetector.parse(probeOutput: ""))
    }
}
