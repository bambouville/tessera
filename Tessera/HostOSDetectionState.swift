import Foundation

enum HostOSDetectionState {
    private static let defaults = UserDefaults.standard
    private static let keyPrefix = "tessera.host.osManual."

    static func isManuallySet(hostID: UUID) -> Bool {
        defaults.bool(forKey: key(for: hostID))
    }

    static func markManuallySet(hostID: UUID) {
        defaults.set(true, forKey: key(for: hostID))
    }

    static func clearManualFlag(hostID: UUID) {
        defaults.removeObject(forKey: key(for: hostID))
    }

    private static func key(for hostID: UUID) -> String {
        keyPrefix + hostID.uuidString
    }
}
