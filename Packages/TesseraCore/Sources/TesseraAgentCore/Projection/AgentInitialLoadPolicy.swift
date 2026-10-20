/// Initial detail loading uses the ordinary bounded protocol pages. Platforms
/// publish/acknowledge the newest page first, then run these optional reads at
/// lower priority than Send, explicit navigation, and recovery.
public enum AgentInitialLoadPolicy {
    public static let initialPageCount = 3

    public static func shouldPrefetch(completedPages: Int, hasOlder: Bool,
                                      isCurrent: Bool = true, hasPriorityDemand: Bool = false) -> Bool {
        completedPages > 0 && completedPages < initialPageCount && hasOlder && isCurrent && !hasPriorityDemand
    }
}

public enum AgentIngestionReadRetryPolicy {
    public static func delayMilliseconds(consecutiveFailures: Int) -> UInt64 {
        switch consecutiveFailures {
        case ...1: return 1_000
        case 2: return 2_000
        case 3: return 4_000
        case 4: return 8_000
        default: return 15_000
        }
    }
}

/// Remote evidence must settle without retaining a conversation reader or a
/// sibling pane's admission gate. Platforms cancel only the child operation;
/// their established terminal carrier remains alive.
public enum AgentReadRecoveryPolicy {
    public static let processProofTimeoutMilliseconds: UInt64 = 6_000

    public static func retainsStatusAfterReaderClosure(_ status: AgentIngestionReadStatus) -> Bool {
        !status.isProgress
    }
}
