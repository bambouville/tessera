import TesseraAgentCore

@_cdecl("tessera_agent_process_proof_timeout_milliseconds")
public func tesseraAgentProcessProofTimeoutMilliseconds() -> UInt64 {
    AgentReadRecoveryPolicy.processProofTimeoutMilliseconds
}

@_cdecl("tessera_agent_initial_load_page_count")
public func tesseraAgentInitialLoadPageCount() -> Int32 { Int32(AgentInitialLoadPolicy.initialPageCount) }

@_cdecl("tessera_agent_read_retry_delay_milliseconds")
public func tesseraAgentReadRetryDelayMilliseconds(consecutiveFailures: Int32) -> UInt64 {
    AgentIngestionReadRetryPolicy.delayMilliseconds(consecutiveFailures: Int(consecutiveFailures))
}

/// Flags: 1 older history exists, 2 current foreground selection, 4 priority
/// work pending. Unknown bits fail closed, as does an uncommitted first page.
@_cdecl("tessera_agent_initial_load_should_prefetch")
public func tesseraAgentInitialLoadShouldPrefetch(completedPages: Int32, flags: UInt32) -> Int32 {
    guard flags & ~7 == 0 else { return 0 }
    return AgentInitialLoadPolicy.shouldPrefetch(completedPages: Int(completedPages),
        hasOlder: flags & 1 != 0, isCurrent: flags & 2 != 0, hasPriorityDemand: flags & 4 != 0) ? 1 : 0
}
