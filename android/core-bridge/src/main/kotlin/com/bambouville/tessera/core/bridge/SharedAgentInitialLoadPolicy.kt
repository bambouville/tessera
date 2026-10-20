package com.bambouville.tessera.core.bridge

/** Only platform resource cancellation lives outside this shared policy. */
object SharedAgentReadRecoveryPolicy {
    val processProofTimeoutMilliseconds: Long get() {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.agentProcessProofTimeoutMilliseconds()
    }
}

/** Shared protocol-page budget; native adapters only own task lifetimes. */
object SharedAgentInitialLoadPolicy {
    fun readRetryDelayMilliseconds(consecutiveFailures: Int): Long {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.agentReadRetryDelayMilliseconds(consecutiveFailures)
    }

    val initialPageCount: Int get() {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.agentInitialLoadPageCount()
    }

    fun shouldPrefetch(completedPages: Int, hasOlder: Boolean, isCurrent: Boolean = true,
                       hasPriorityDemand: Boolean = false): Boolean {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.agentInitialLoadShouldPrefetch(completedPages,
            (if (hasOlder) 1 else 0) or (if (isCurrent) 2 else 0) or (if (hasPriorityDemand) 4 else 0))
    }
}
