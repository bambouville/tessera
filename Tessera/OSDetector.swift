import Foundation
import TesseraDomainCore

/// iOS-facing name for the shared OS-family classifier.
///
/// The rules themselves — Darwin-anywhere, `sw_vers` fallback, `ID=` from
/// `/etc/os-release`, the Raspbian-before-Ubuntu ordering and the
/// alpine/debian release-file fallbacks — live in
/// `TesseraDomainCore.RemoteOSDetection` so Android classifies a host
/// identically. This file exists only to keep the call sites and their tests
/// spelled the way they always were.
enum OSDetector {
    static func parse(probeOutput: String) -> String? {
        RemoteOSDetection.parseOSFamily(probeOutput: probeOutput)
    }
}
