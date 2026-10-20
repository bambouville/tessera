#include "CodexReader.h"
#include "Json.h"
#include <algorithm>
#include <limits>
#include <set>
#include <stdexcept>

namespace tessera {
PositionedRecord CodexReader::retain(NormalizedRecord value, uint64_t order) {
    if (value.providerID.empty() || value.providerID.size() > 256) throw std::runtime_error("codexMalformedItem");
    auto found = items_.find(value.providerID);
    if (revisionClock_ == std::numeric_limits<uint64_t>::max()) throw std::runtime_error("revisionBudgetExceeded");
    uint64_t revision = ++revisionClock_;
    if (found != items_.end()) {
        if (found->second.order != order) throw std::runtime_error("codexItemOrderChanged");
        if (found->second.json == value.json) revision = found->second.revision;
        bytes_ -= found->second.json.size() + found->first.size() + 64;
    }
    items_[value.providerID] = {order, revision, value.json}; bytes_ += value.json.size() + value.providerID.size() + 64;
    while (items_.size() > 512 || bytes_ > 2 * 1024 * 1024) {
        auto victim = std::min_element(items_.begin(), items_.end(), [](const auto& a, const auto& b) { return a.second.order < b.second.order; });
        if (victim == items_.end()) break;
        bytes_ -= victim->second.json.size() + victim->first.size() + 64; items_.erase(victim);
    }
    PositionedRecord result; result.start = order; result.value = std::move(value); result.revision = revision;
    return result;
}

CodexPage CodexReader::read(CodexServer& server, const std::string& thread, const std::string& operation,
                          const std::string& cursor, uint64_t order, size_t limit) {
    // A failed page cannot advance revisions or discard the cache behind a
    // previously issued cursor. Publish state only with a complete page.
    auto staged = *this;
    auto page = staged.readStaged(server, thread, operation, cursor, order, limit);
    *this = std::move(staged);
    return page;
}
CodexPage CodexReader::readStaged(CodexServer& server, const std::string& thread, const std::string& operation,
                                 const std::string& cursor, uint64_t order, size_t limit) {
    if (!limit || limit > 100) throw std::runtime_error("invalidRequest");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
    const auto initialBytes = server.bytesRead();
    auto rpc = [&](const std::string& params) {
        const auto consumed = server.bytesRead() - initialBytes;
        if (consumed >= 64 * 1024 * 1024) throw std::runtime_error("codexResponseBudgetExceeded");
        return server.call("thread/items/list", params, deadline,
            static_cast<size_t>(std::min<uint64_t>(16 * 1024 * 1024, 64 * 1024 * 1024 - consumed)));
    };
    const bool bootstrap = operation == "bootstrap", forward = operation == "updates";
    // Leave ample headroom in both directions while remaining exactly
    // representable by platform JSON bridges using IEEE-754 numbers.
    if (bootstrap) { items_.clear(); bytes_ = 0; revisionClock_ = 0; order = uint64_t(1) << 52; }
    if (!bootstrap && !forward && operation != "history") throw std::runtime_error("invalidRequest");
    CodexPage result;
    result.page.sourceIdentity = "codex-appserver:" + thread;
    result.page.older = order; result.page.live = order;
    std::string continuation = cursor;
    std::set<std::string> seenCursors, seenIDs;
    size_t bytes = 2048;
    simdjson::dom::parser parser;
    for (size_t count = 0; count < limit; ++count) {
        json::Object params;
        params.string("threadId", thread, 256); params.number("limit", 1);
        params.string("sortDirection", forward ? "asc" : "desc"); params.optional("cursor", continuation, 2048);
        auto raw = rpc(params.finish());
        simdjson::dom::element response;
        if (parser.parse(raw).get(response)) throw std::runtime_error("codexMalformedResponse");
        const auto data = json::get(response, "data");
        if (!data.is_array() || data.get_array().value().size() > 1) throw std::runtime_error("codexMalformedResponse");
        auto next = json::text(response, "nextCursor");
        auto backwards = json::text(response, "backwardsCursor");
        if (next.size() > 2048 || backwards.size() > 2048) throw std::runtime_error("codexCursorBudgetExceeded");
        if (!data.get_array().value().size()) {
            if (bootstrap && result.page.records.empty()) throw std::runtime_error("codexEmptyHistory");
            result.page.hasNewer = false;
            break;
        }
        const auto entry = *data.get_array().value().begin();
        if (json::text(entry, "turnId").size() > 256) throw std::runtime_error("codexMalformedItem");
        auto value = normalizeCodexItem(json::get(entry, "item"), json::text(entry, "turnId"), server.responseTruncated());
        if (!seenIDs.insert(value.providerID).second) throw std::runtime_error("codexDuplicateItem");
        const auto existing = items_.find(value.providerID);
        // App Server's reverse cursor may include its boundary item (verified
        // against 0.154.0). Only the first, exactly matching anchor may overlap;
        // do not invent a new order or duplicate it as a newly appended item.
        const bool inclusiveBoundary = forward && count == 0 && existing != items_.end() && existing->second.order == order;
        if (inclusiveBoundary && existing->second.json == value.json) {
            if (next.empty()) { result.after = cursor; result.page.hasNewer = false; break; }
            if (next == continuation || !seenCursors.insert(next).second) throw std::runtime_error("codexCursorDidNotAdvance");
            continuation = next; result.after = next; result.page.hasNewer = true;
            continue;
        }
        const auto cost = value.json.size() + value.providerID.size() * 6 + 1536;
        if (bytes + cost > 262144) {
            result.page.hasNewer = forward; result.page.hasOlder = !forward; break;
        }
        bytes += cost;
        if (forward && !inclusiveBoundary) {
            if (order == std::numeric_limits<uint64_t>::max()) throw std::runtime_error("orderBudgetExceeded");
            ++order;
        } else if (!forward && (!bootstrap || count)) {
            if (!order) throw std::runtime_error("orderBudgetExceeded");
            --order;
        }
        auto record = retain(std::move(value), order);
        result.page.records.push_back(std::move(record));
        if (bootstrap && !count) { result.after = backwards; result.page.live = order; }
        // With limit=1, backwardsCursor identifies the same sole item as
        // nextCursor, but remains available at the tail. Its documented
        // reverse direction is DESC, so obtain an ASC anchor explicitly from
        // a DESC read below when the ascending continuation ends.
        if (forward) { result.after = next; result.page.live = order; }
        else { result.before = next; result.page.older = order; }
        if (next.empty()) { result.page.hasNewer = false; break; }
        if (!seenCursors.insert(next).second || next == continuation) throw std::runtime_error("codexCursorDidNotAdvance");
        continuation = next;
        result.page.hasNewer = forward; result.page.hasOlder = !forward;
    }
    if (!forward) {
        result.page.hasOlder = !result.before.empty();
        std::reverse(result.page.records.begin(), result.page.records.end());
    } else if (result.page.records.empty()) result.after = cursor;
    // Items such as a running command are revised in place. Reconcile every
    // retained item, including loaded history, with individually bounded RPCs.
    // Never aggregate hundreds of unbounded provider tool outputs in one RPC.
    if (forward && !result.page.hasNewer) {
        std::set<std::string> remaining;
        for (const auto& item : items_) remaining.insert(item.first);
        std::string scanCursor;
        bool first = true;
        for (size_t scanned = 0; !remaining.empty() && scanned < 4096; ++scanned) {
            json::Object params; params.string("threadId", thread, 256); params.number("limit", 1);
            params.string("sortDirection", "desc"); params.optional("cursor", scanCursor, 2048);
            auto raw = rpc(params.finish());
            simdjson::dom::element response;
            if (parser.parse(raw).get(response)) throw std::runtime_error("codexMalformedResponse");
            const auto data = json::get(response, "data");
            if (!data.is_array() || data.get_array().value().size() > 1) throw std::runtime_error("codexMalformedResponse");
            if (!data.get_array().value().size()) throw std::runtime_error("codexRevisionItemMissing");
            const auto next = json::text(response, "nextCursor"), backwards = json::text(response, "backwardsCursor");
            if (next.size() > 2048 || backwards.size() > 2048) throw std::runtime_error("codexCursorBudgetExceeded");
            if (!next.empty() && next == scanCursor) throw std::runtime_error("codexCursorDidNotAdvance");
            scanCursor = next;
            const auto entry = *data.get_array().value().begin();
            if (json::text(entry, "turnId").size() > 256) throw std::runtime_error("codexMalformedItem");
            auto value = normalizeCodexItem(json::get(entry, "item"), json::text(entry, "turnId"), server.responseTruncated());
            const auto found = items_.find(value.providerID);
            if (first && !result.page.records.empty() && found != items_.end() && found->second.order == result.page.live) {
                result.after = backwards;
            }
            first = false;
            remaining.erase(value.providerID);
            if (next.empty() && !remaining.empty()) throw std::runtime_error("codexRevisionItemMissing");
            // A newly appended item raced the tail read. Keep the old ASC
            // cursor so the next request catches it; never jump over it.
            if (found == items_.end()) {
                if (result.after.empty()) throw std::runtime_error("codexTailMoved");
                continue;
            }
            if (found->second.json == value.json) continue;
            if (seenIDs.count(value.providerID)) continue;
            const auto cost = value.json.size() + value.providerID.size() * 6 + 1536;
            if (bytes + cost > 262144 || result.page.records.size() >= 100) {
                // Keep the old cached value until this revision is emitted.
                // The next live request revisits it at the same item anchor.
                result.page.hasNewer = true; break;
            }
            bytes += cost; result.page.records.push_back(retain(std::move(value), found->second.order));
        }
        if (!remaining.empty() && !result.page.hasNewer) throw std::runtime_error("revisionCoverageExceeded");
        std::sort(result.page.records.begin(), result.page.records.end(), [](const auto& a, const auto& b) { return a.start < b.start; });
    }
    if ((bootstrap || forward) && result.after.empty()) throw std::runtime_error("codexMissingLiveAnchor");
    result.page.bytesRead = server.bytesRead() - initialBytes;
    return result;
}
}
