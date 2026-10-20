#pragma once
#include "JsonlReader.h"
#include "HistoryMetadataBudget.h"
#include <memory>
#include <map>
#include <set>
#include <optional>

namespace tessera {
// Metadata-only canonical selection for explicitly paginated Codex rollouts.
// Legacy mode is not inferred from the presence/absence of completed events.
class CodexHistoryIndex {
public:
    struct HistoryBase { std::string thread; uint64_t ordinal = 0, byteOffset = 0; };
    struct Entry {
        uint64_t start = 0, end = 0, ordinal = 0, updatedOrdinal = 0;
        std::string turn, id;
    };
    static NormalizedRecord metadata(simdjson::dom::element source, bool truncated);
    static NormalizedRecord completed(simdjson::dom::element source, bool truncated);
    static NormalizedRecord legacyMatch(simdjson::dom::element source, bool truncated);
    void refresh(JsonlReader& reader, const std::function<bool()>& cancelled = {}, size_t budget = HistoryMetadataBudget::indexLimit, bool physicalLineageSegment = false);
    bool paginated() const { return mode_ == "paginated"; }
    bool indexed() const { return paginated() || mode_ == "legacy"; }
    size_t mirroredRecords() const { return mirroredRecords_; }
    const std::string& generation() const { return generation_; }
    const std::string& sessionID() const { return session_; }
    const std::optional<HistoryBase>& historyBase() const { return base_; }
    const std::string& identityForLineage(const std::string& witness);
    uint64_t nextOrdinal() const {
        if (hasOrdinal_ && lastOrdinal_ == UINT64_MAX) throw std::runtime_error("codexInvalidOrdinal");
        return hasOrdinal_ ? lastOrdinal_ + 1 : 0;
    }
    size_t size() const { return count_; }
    Entry entry(JsonlReader& reader, size_t position);
    size_t bytes() const;
    bool lazy() const { return lazy_; }
    std::string sourceWitness() const {
        const auto fingerprint = validation_.fingerprint();
        static constexpr char hex[] = "0123456789abcdef";
        std::string result = identity_ + ":";
        for (auto byte : fingerprint) { result += hex[byte >> 4]; result += hex[byte & 15]; }
        return result;
    }
private:
    struct Compact {
        uint64_t start = 0, end = 0, ordinal = 0, updatedOrdinal = 0, hash = 0;
        std::array<uint8_t, 16> proof{};
    };
    struct Slot { uint64_t hash = 0; size_t index = 0; };
    struct Lookup { std::string turn, id; uint64_t before = 0, position = 0; bool active = false; };
    void refreshLegacy(JsonlReader& reader, const std::function<bool()>& cancelled, size_t budget);
    Entry decode(JsonlReader& reader, const Compact& compact) const;
    static Compact proved(Compact value, const std::string& metadata);
    std::optional<size_t> find(JsonlReader& reader, uint64_t hash, const std::string& turn, const std::string& id);
    bool seenBefore(JsonlReader& reader, const std::string& turn, const std::string& id, uint64_t before,
                    const std::function<bool()>& cancelled);
    int64_t legacyBalance(JsonlReader& reader, const std::pair<std::string, std::string>& key, uint64_t before,
                          const std::function<bool()>& cancelled);
    void insertSlot(uint64_t hash, size_t index);
    void rebuildSlots(size_t capacity = 0);
    void append(Compact value, size_t budget);
    void enterLazy(size_t budget);
    void updateWindow(JsonlReader& reader, uint64_t hash, const std::string& turn, const std::string& id,
                      const Compact& value);
    void windowAppend(const Compact& value, size_t ordinal);
    bool maybe(uint64_t hash) const;
    void remember(uint64_t hash);
    std::map<std::pair<std::string, std::string>, int64_t> legacyPending_;
    size_t pendingBytes_ = 0, mirroredRecords_ = 0;
    std::vector<Compact> entries_, window_;
    std::vector<Slot> slots_;
    std::vector<uint64_t> bloom_, revisionsBloom_;
    struct Checkpoint { size_t ordinal = 0; uint64_t position = 0, legacyBoundary = 0, physicalOrdinal = 0; };
    struct WindowScan {
        size_t requested = 0, ordinal = 0;
        uint64_t position = 0, sourceEnd = 0, legacyBoundary = 0, physicalOrdinal = 0;
        bool revisions = false;
        std::vector<Compact> records;
    };
    std::vector<Checkpoint> checkpoints_;
    size_t checkpointStride_ = 128;
    std::optional<WindowScan> windowScan_;
    bool maybeRevision(uint64_t hash) const;
    void rememberRevision(uint64_t hash);
    void checkpoint(const Compact& value, size_t budget);
    void fillWindow(JsonlReader& reader, size_t position);
    size_t count_ = 0, windowFirst_ = 0, windowStart_ = 0, windowLimit_ = 512;
    bool lazy_ = false, forceLazy_ = false, captureRange_ = false, skipValidation_ = false;
    size_t captureFirst_ = 0, metadataBudget_ = HistoryMetadataBudget::indexLimit;
    Lookup lookup_;
    int64_t lookupBalance_ = 0;
    uint64_t legacyBoundary_ = 0;
    std::string identity_, generation_, session_, mode_, mutationStamp_;
    uint64_t position_ = 0, witness_ = 0, seenSize_ = 0, historyStart_ = 0, lastOrdinal_ = 0;
    bool hasOrdinal_ = false;
    std::optional<HistoryBase> base_;
    std::string lineageWitness_, lineageGeneration_;
    SourceValidation validation_;
    uint64_t validationRevision_ = 0;
};

class CodexHistoryCache {
public:
    explicit CodexHistoryCache(HistoryMetadataBudget* budget = nullptr) : budget_(budget) {
        if (budget_) budget_->registerFamily(this, [this] { return usedBytes(); });
    }
    ~CodexHistoryCache() { if (budget_) budget_->unregisterFamily(this); }
    CodexHistoryIndex& get(const std::string& path);
    void pin(std::set<std::string> paths);
    void lineage(const std::string& path, std::vector<std::string> dependencies);
    void beginRead() { transientPins_.clear(); }
    const std::set<std::string>& readPaths() const { return transientPins_; }
    // Queued I/O continuations retain admitted index prefixes across other
    // jobs. Exhaustion reports capacity instead of repeatedly restarting them.
    void pending(std::set<std::string> paths) { pendingPins_ = std::move(paths); }
    void hold(const std::string& key) { transientPins_.insert(key); }
    size_t budgetFor(const std::string& path);
private:
    struct Cached { CodexHistoryIndex index; uint64_t touched = 0; std::vector<std::string> dependencies; };
    std::map<std::string, Cached> indexes_;
    std::set<std::string> pinned_;
    std::set<std::string> transientPins_;
    std::set<std::string> pendingPins_;
    uint64_t clock_ = 0;
    bool evict(const std::string& except);
    size_t usedBytes() const;
    HistoryMetadataBudget* budget_;
    static size_t overhead(const std::string& key, const Cached& cached);
};
}
