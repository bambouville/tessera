/// Shared timing decisions for integration observation. Platforms own their
/// tasks and clocks; cached installation facts never replace fresh process or
/// current-shell proof, and a failed check never extends a cache deadline.
public enum AgentIntegrationCheckPolicy {
    public static let currentInstallationFreshnessMilliseconds: UInt64 = 30_000
    public static let otherInstallationFreshnessMilliseconds: UInt64 = 5_000
    public static let activityThrottleMilliseconds: UInt64 = 2_000
    /// How long a warning decision must hold before chrome shows it. Probes,
    /// reconnects, and foreground changes pass through warning states on the
    /// way to `ready`; showing each one would flash chrome for no reason.
    /// Clearing is immediate.
    public static let warningPresentationDelayMilliseconds: UInt64 = 5_000

    public static func installationFreshnessMilliseconds(_ installation: AgentIntegrationInstallationKind) -> UInt64 {
        installation == .current ? currentInstallationFreshnessMilliseconds : otherInstallationFreshnessMilliseconds
    }

    /// Zero is the normal foreground check interval. Failures back off without
    /// turning a transient outage into a long-lived warning after recovery.
    public static func nextCheckDelayMilliseconds(consecutiveFailures: Int) -> UInt64 {
        switch consecutiveFailures {
        case ...1: return 2_000
        case 2: return 4_000
        case 3: return 8_000
        case 4: return 16_000
        default: return 30_000
        }
    }
}
