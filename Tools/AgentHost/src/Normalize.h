#pragma once
#include <simdjson.h>
#include <string>

namespace tessera {
struct NormalizedRecord {
    std::string json;
    std::string sourceType;
    std::string disposition;
    std::string providerID;
    std::string parentID;
    bool visible = false;
    // Metadata-only Claude branch index; never serialized as message content.
    bool chainEntry = false, chainMessage = false, chainMain = false, parentField = false;
    std::string chainID, chainParentID;
    bool chainUnproven = false;
    // Claude only. A root compact_boundary (parentUuid null/absent) resumes
    // display ancestry at an effective parent chosen by the index; its
    // advisory logicalParentUuid is empty when absent, ill-typed or ambiguous.
    // chainSidechain marks isSidechain/teamName records of any node type.
    bool chainCompactBoundary = false, chainSidechain = false;
    std::string chainLogicalParentID;
    // Used only by the legacy-index readRecord callback, never by a page
    // normalizer or wire payload. Exact bodies are bounded by the input DOM
    // and released when the opposite copy arrives or the turn boundary ends.
    std::string legacyMatchText, legacyMatchRole;
    bool legacyEvent = false, legacyBoundary = false;
};
NormalizedRecord normalize(const std::string& provider, simdjson::dom::element source, bool truncated,
                           const std::string& fallbackID = {});
NormalizedRecord normalizeKimi(simdjson::dom::element source, bool truncated, const std::string& fallbackID = {});
NormalizedRecord normalizeCodexItem(simdjson::dom::element item, const std::string& turnID, bool truncated = false);
// Core TurnItem (rollout item_completed) uses a different tagged vocabulary
// from public ThreadItem. Selection/ownership/revision merging is the caller's
// responsibility; this function only converts a single item's display fields.
NormalizedRecord normalizeCodexCoreItem(simdjson::dom::element item, const std::string& turnID, bool truncated = false);
}
