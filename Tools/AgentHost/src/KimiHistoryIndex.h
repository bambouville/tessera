#pragma once
#include "JsonlReader.h"
#include "HistoryMetadataBudget.h"
#include <map>
#include <memory>
#include <set>

namespace tessera {
// Provider replay keeps compact source coordinates when they fit. The same
// canonical iterator can instead reconstruct bounded order windows, so a RAM
// budget limits retained acceleration, never the length of a conversation.
class KimiHistoryIndex {
public:
    struct Entry {
        uint64_t start = 0, end = 0, count = 0;
        std::string type, id, group, role, origin, trigger;
        bool visible = false, undoAnchor = false, vacuous = false, settle = false;
        std::array<uint8_t, 16> fingerprint{};
    };
    struct Materialized { Entry entry; bool interrupted = false; };
    KimiHistoryIndex();
    ~KimiHistoryIndex();
    KimiHistoryIndex(KimiHistoryIndex&&) noexcept;
    KimiHistoryIndex& operator=(KimiHistoryIndex&&) noexcept;
    static NormalizedRecord metadata(simdjson::dom::element value, bool truncated);
    void refresh(JsonlReader& reader, const std::function<bool()>& cancelled, size_t budget);
    std::vector<Materialized> materialize(JsonlReader& reader, size_t first, size_t count,
                                         const std::function<bool()>& cancelled = {});
    size_t size() const;
    size_t bytes() const;
    const std::string& generation() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class KimiHistoryCache {
public:
    explicit KimiHistoryCache(HistoryMetadataBudget* budget = nullptr);
    ~KimiHistoryCache();
    KimiHistoryIndex& get(const std::string& path);
    void pin(std::set<std::string> paths) { pinned_ = std::move(paths); }
    void beginRead() { transientPins_.clear(); }
    const std::set<std::string>& readPaths() const { return transientPins_; }
    void pending(std::set<std::string> paths) { pendingPins_ = std::move(paths); }
    size_t budgetFor(const std::string& path);
    size_t usedBytes() const;
private:
    struct Cached { KimiHistoryIndex index; uint64_t touched = 0; };
    std::map<std::string, Cached> indexes_;
    std::set<std::string> pinned_;
    std::set<std::string> transientPins_, pendingPins_;
    bool retained(const std::string& path) const {
        return pinned_.count(path) || transientPins_.count(path) || pendingPins_.count(path);
    }
    HistoryMetadataBudget* sharedBudget_ = nullptr;
    uint64_t clock_ = 0;
};
}
