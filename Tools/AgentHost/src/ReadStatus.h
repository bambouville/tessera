#pragma once
#include "Json.h"
#include <algorithm>
#include <string>
#include <string_view>

namespace tessera {
// One native classifier for both clients. Unknown exception strings never
// cross the status/diagnostic boundary as paths or provider transcript text.
struct ReadStatus {
    std::string code, state, domain, recovery;
    static std::string safeCode(const std::string& raw) {
        static constexpr std::string_view known[] = {
            "busy",
            "cancelled",
            "canonicalReadFailed",
            "capacityExceeded",
            "catalogBudgetExceeded",
            "catalogSourceChanged",
            "catalogSourceUnavailable",
            "claudeIndexCapacity",
            "claudeIndexNoProgress",
            "claudeIndexUnproven",
            "codexAmbiguousEnvelope",
            "codexBoundaryChanged",
            "codexCompletedSourceChanged",
            "codexCursorBudgetExceeded",
            "codexCursorDidNotAdvance",
            "codexDisconnected",
            "codexDuplicateItem",
            "codexEmptyHistory",
            "codexIdentityConflict",
            "codexIndexCapacity",
            "codexIndexNoProgress",
            "codexIndexUnproven",
            "codexInheritedHistoryRequired",
            "codexInvalidCanonicalHeader",
            "codexInvalidEnvelope",
            "codexInvalidIdentity",
            "codexInvalidOrdinal",
            "codexInvalidSessionID",
            "codexInventoryBudgetExceeded",
            "codexInventoryMalformed",
            "codexItemOrderChanged",
            "codexLineageCapacity",
            "codexLineageCutoffMismatch",
            "codexLineageCycle",
            "codexMalformedCursor",
            "codexMalformedItem",
            "codexMalformedResponse",
            "codexMemoryBudgetExceeded",
            "codexMetadataCapacity",
            "codexMetadataMalformed",
            "codexMetadataSchemaUnsupported",
            "codexMissingItemAnchor",
            "codexMissingLiveAnchor",
            "codexMissingSessionMeta",
            "codexNoThreads",
            "codexOrdinalDiscontinuity",
            "codexPaginationUnavailable",
            "codexProcessBudgetExceeded",
            "codexReadDeadlineExceeded",
            "codexReadFailed",
            "codexRepeatedSessionMeta",
            "codexResourceMonitorUnavailable",
            "codexResponseBudgetExceeded",
            "codexRevisionItemMissing",
            "codexSummaryMalformed",
            "codexTailMoved",
            "codexUnavailable",
            "codexUnexpectedResponse",
            "codexUnexpectedServerRequest",
            "codexUnknownHistoryMode",
            "codexUnsafeExecutable",
            "codexVersionUnsupported",
            "contextEnvironmentCapacity",
            "contextEnvironmentInvalid",
            "contextEnvironmentUnavailable",
            "contextHelloCapacity",
            "contextHelloInvalid",
            "contextHelloTimeout",
            "contextHelloUnavailable",
            "contextNamespaceMismatch",
            "contextProcessChanged",
            "contextProcessUnavailable",
            "contextScopeUnavailable",
            "contextUnsupported",
            "cursorDidNotAdvance",
            "cursorExpired",
            "duplicateHistoryBudgetOwner",
            "duplicateRevision",
            "headAnchorMissing",
            "headOrderChanged",
            "homeUnavailable",
            "hookOverflow",
            "invalidCodexThreadID",
            "invalidContextPID",
            "invalidCursor",
            "invalidPartitionIdentity",
            "invalidProviderRoot",
            "invalidRequest",
            "invalidRevisionTransaction",
            "invalidSegment",
            "invalidSegmentRecord",
            "invalidWindowAck",
            "invalidWindowAnchor",
            "invalidWindowOperation",
            "invalidWindowVersion",
            "jsonlContinuationCapacity",
            "kimiFormatUnsupported",
            "kimiHeaderChanged",
            "kimiHeaderMissing",
            "kimiIdentityConflict",
            "kimiIndexCapacity",
            "kimiIndexNoProgress",
            "kimiIndexUnavailable",
            "kimiIndexUnproven",
            "kimiToolIdentityConflict",
            "namespaceUnavailable",
            "opencodeDatabaseUnavailable",
            "opencodeInvalidRecord",
            "opencodeInvalidSchema",
            "opencodeNestedRead",
            "opencodeReadBudgetExceeded",
            "opencodeResourceLimit",
            "opencodeSecureVFSUnavailable",
            "orderBudgetExceeded",
            "piChainUnproven",
            "piDuplicateEntryID",
            "piFormatUnsupported",
            "piHeaderChanged",
            "piHeaderMissing",
            "piIdentityConflict",
            "providerEnvironmentUnavailable",
            "readBudgetExceeded",
            "readContinuationTimeout",
            "readNoProgress",
            "readPending",
            "revisionAnchorMissing",
            "revisionBudgetExceeded",
            "revisionChangedOrder",
            "revisionCoverageExceeded",
            "revisionOutsideCoverage",
            "scopeMismatch",
            "scopeUnavailable",
            "segmentExpired",
            "segmentSourceChanged",
            "sourceChanged",
            "sourceDoesNotSupportRevisions",
            "sourceHandleExpired",
            "sourceMissing",
            "sourceNotAuthorized",
            "sourceUnavailable",
            "subscriptionAckExpired",
            "unknown",
            "unsupported",
            "versionIdentity",
            "versionMissing",
            "versionUnavailable",
            "windowAckConflict",
            "windowAckDroppedIncoming",
            "windowAckDuplicateSegment",
            "windowAckExpired",
            "windowAckGap",
            "windowAckHead",
            "windowAckOrder",
            "windowAckRevisionRetention",
            "windowAckStale",
            "windowAnchorExpired",
            "windowBusy",
            "windowCapacity",
            "windowItemCapacity",
            "windowMissing",
            "windowStale",
            "windowSubscriptionRequired",
            "windowTransactionReused",
            "windowWireCapacity",
            "workerNotificationUnavailable",
        };
        return std::binary_search(std::begin(known), std::end(known), std::string_view(raw)) ? raw : "unknown";
    }
    static ReadStatus from(const std::string& raw) {
        ReadStatus value{safeCode(raw), "failed", "source", "manual"};
        const auto& code = value.code;
        if (code == "readPending") return {code, "preparing", "source", "continue"};
        if (code == "sourceChanged" || code == "catalogSourceChanged" || code == "segmentSourceChanged" ||
            code == "cursorExpired" || code == "sourceHandleExpired" || code == "windowMissing" ||
            code == "windowStale" || code == "windowAnchorExpired" || code == "segmentExpired" ||
            code == "codexBoundaryChanged" || code == "codexCompletedSourceChanged" || code == "codexTailMoved" ||
            code == "windowAckExpired" || code == "subscriptionAckExpired")
            return {code, "sourceChanged", "source", "rebootstrap"};
        if (code == "contextProcessChanged" || code == "contextProcessUnavailable" || code == "contextScopeUnavailable")
            return {code, "retryable", "transport", "renewConnection"};
        if (code == "busy" || code == "windowBusy" || code == "readContinuationTimeout" || code == "readNoProgress" ||
            code == "codexDisconnected" || code == "codexReadDeadlineExceeded" || code == "codexUnavailable")
            return {code, "retryable", code.rfind("codex", 0) == 0 ? "provider" : "host", "retryRead"};
        if (code.find("Capacity") != std::string::npos || code.find("BudgetExceeded") != std::string::npos ||
            code == "capacityExceeded" || code == "opencodeResourceLimit")
            return {code, "resourceLimited", "host", "retryRead"};
        if (code.find("Unsupported") != std::string::npos || code == "unsupported" ||
            code == "codexUnknownHistoryMode" || code == "sourceDoesNotSupportRevisions")
            return {code, "unsupported", "provider", "manual"};
        return value;
    }
    std::string json() const {
        json::Object value; value.number("v", 1); value.string("state", state);
        value.string("domain", domain); value.string("recovery", recovery); value.string("code", code);
        return value.finish();
    }
};
}
