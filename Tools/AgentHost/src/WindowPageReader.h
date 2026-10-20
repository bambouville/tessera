#pragma once
#include "Catalog.h"
#include "CodexServer.h"
#include "PageWindow.h"
#include "ClaudeChainIndex.h"
#include "CodexHistoryIndex.h"
#include "KimiHistoryIndex.h"
#include <optional>

namespace tessera {
struct WindowRead {
    WindowSegment segment;
    WindowAnchor before, after;
    uint64_t bytesRead = 0, sourceEnd = 0;
};

// Stateless bounded provider page reads. Revision/order state belongs to the
// acknowledged PageWindow, not a separately evicted transcript-wide map.
class WindowPageReader {
public:
    WindowPageReader(Catalog& catalog, CodexServer& codex, std::function<bool()> cancelled, ClaudeChainCache* chains = nullptr, bool automatic = false, CodexHistoryCache* histories = nullptr, KimiHistoryCache* kimi = nullptr)
        : catalog_(catalog), codex_(codex), cancelled_(std::move(cancelled)), chains_(chains ? chains : &localChains_), histories_(histories ? histories : &localHistories_), kimi_(kimi ? kimi : &localKimi_), automatic_(automatic) {}
    bool cancelled() const { return cancelled_ && cancelled_(); }
    void setValidationRefresh(bool value) { refreshValidation_ = value; }
    // App Server pagination has no rollout-materialization freshness witness.
    // A verified supported rollout header makes its canonical history the
    // authority; absent/unmarked files retain the structured-store capability.
    bool canonicalCodexAvailable(Source& source, uint64_t& bytesRead);
    WindowRead read(const Source& source, const std::string& generation,
                    const std::optional<WindowAnchor>& anchor, bool forward, size_t limit, uint64_t& revision);
    PositionedRecord reviseNative(const PositionedRecord& record, const WindowRecordAnchors& anchors,
                                  const Source& source, uint64_t& revision,
                                  std::chrono::steady_clock::time_point deadline, uint64_t initialBytes);
    PositionedRecord reviseHistory(const PositionedRecord& record, const WindowRecordAnchors& anchors,
                                   const Source& source, uint64_t& revision, uint64_t& bytesRead);
    PositionedRecord reviseOpenCode(const PositionedRecord& record, const WindowRecordAnchors& anchors,
                                   const Source& source, uint64_t& revision, uint64_t& bytesRead);
private:
    struct HistorySegment {
        Source source;
        std::string key, witness;
        uint64_t cutoff = UINT64_MAX, bytes = 0;
        size_t count = 0;
        CodexHistoryIndex* index = nullptr;
        std::unique_ptr<JsonlReader> reader;
        size_t offset = 0;
        uint64_t byteOffset = 0;
    };
    void prepareHistory(const Source& source);
    HistorySegment describeHistory(const Source& source, uint64_t cutoff, uint64_t expectedOrdinal);
    void loadHistory(HistorySegment segment);
    std::pair<HistorySegment&, CodexHistoryIndex::Entry> historyEntry(size_t position);
    uint64_t historyBytesRead() const;
    struct Item { bool empty = false; NormalizedRecord record; std::string next, backwards; };
    Item nativeItem(const Source& source, const std::string& cursor, bool forward,
                    std::chrono::steady_clock::time_point deadline, uint64_t initialBytes);
    Catalog& catalog_;
    CodexServer& codex_;
    std::function<bool()> cancelled_;
    HistoryMetadataBudget localBudget_;
    ClaudeChainCache localChains_{&localBudget_};
    ClaudeChainCache* chains_;
    CodexHistoryCache localHistories_{&localBudget_};
    CodexHistoryCache* histories_;
    KimiHistoryCache localKimi_{&localBudget_};
    KimiHistoryCache* kimi_;
    std::vector<HistorySegment> historySegments_;
    std::optional<HistorySegment> activeHistory_;
    Source historyRoot_;
    bool lazyLineage_ = false, historyIndexed_ = false;
    uint64_t historyPreparationBytes_ = 0;
    std::string historyPath_, historyGeneration_;
    size_t historyCount_ = 0;
    uint64_t historySourceEnd_ = 0;
    bool automatic_;
    bool refreshValidation_ = true;
};
}
