package com.bambouville.tessera.feature.agentcenter

/** Only fixed protocol codes may cross into exported device diagnostics.
 * Exception messages and server-controlled strings can contain private data. */
internal object AgentIngestionDiagnostics {
    private val codes = setOf(
        "sourceMissing", "sourceChanged", "sourceNotAuthorized", "sourceUnavailable", "sourceIdentityConflict",
        "contextIdentityConflict", "contextProcessUnavailable", "contextScopeUnavailable", "contextCapacity",
        "invalidRequest", "invalidCursor", "cursorExpired", "unsupported", "busy", "cancelled",
        "capacityExceeded", "catalogBudgetExceeded", "windowMissing", "windowCapacity", "windowWireCapacity",
        "windowSubscriptionRequired", "invalidWindowAck", "codexUnavailable", "codexSummaryMalformed",
        "controlBusy", "windowBusy", "windowStale", "invalidWindowVersion", "windowTransactionReused", "segmentExpired",
        "windowAnchorExpired", "windowAckExpired", "subscriptionAckExpired", "canonicalReadFailed", "hookOverflow",
        "invalidSegment", "invalidSegmentRecord", "segmentSourceChanged", "invalidRevisionTransaction",
        "sourceDoesNotSupportRevisions", "duplicateRevision", "revisionChangedOrder", "revisionOutsideCoverage",
        "revisionAnchorMissing", "windowItemCapacity", "invalidPartitionIdentity", "windowAckConflict",
        "windowAckStale", "windowAckHead", "windowAckDroppedIncoming", "windowAckRevisionRetention",
        "windowAckGap", "windowAckDuplicateSegment", "windowAckOrder",
        "codexInventoryBudgetExceeded", "codexInventoryMalformed", "codexTitleUnavailable",
        "opencodeDatabaseUnavailable", "opencodeReadBudgetExceeded", "opencodeInvalidSchema", "opencodeResourceLimit",
        "opencodeNestedRead", "opencodeSecureVFSUnavailable", "codexInvalidSessionID", "codexMetadataSchemaUnsupported",
        "codexMetadataCapacity", "malformedFrame", "staleEpoch",
        "incompletePage", "staleBinding", "ingestionRejected", "commitNotForwarded", "commitTimeout",
        "streamClosed", "helperStderr", "execUnavailable", "remoteRejected",
        "projectionInactive", "projectionRouteChanged", "projectionOwnerChanged",
        "applied", "sourceReset", "duplicate", "summaryApplied", "hookApplied", "hookIgnored", "resyncRequired",
        "ingestion_malformedFrame", "ingestion_capacityExceeded", "ingestion_staleEpoch", "ingestion_incompletePage",
        "ingestion_remoteRejected", "projection_staleBinding", "projection_transcriptUnavailable", "command_failed@projection",
    )
    fun code(raw: String?): String = raw?.takeIf { it in codes } ?: "unclassified"
    fun failure(error: Throwable): Map<String, String> = mapOf(
        "errorType" to error.javaClass.simpleName,
        "code" to if (error is AgentIngestionReadFailure) error.status.code else code(error.message),
    )
}
