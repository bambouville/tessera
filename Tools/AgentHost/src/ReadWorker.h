#pragma once
#include "Catalog.h"
#include "CodexReader.h"
#include "FileWakeups.h"
#include "WindowSession.h"
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <vector>
#include <atomic>

namespace tessera {
struct ReadJob {
    uint64_t client = 0; std::string request; bool automatic = false, control = false, urgent = false;
    std::chrono::steady_clock::time_point continuationDeadline{};
    uint64_t resumedBytes = 0;
    std::set<std::string> historyPins{};
    uint64_t progressSequence = 0;
    std::chrono::steady_clock::time_point lastProgress{};
    uint64_t observationToken = 0;
};
struct ReadResult {
    uint64_t client = 0;
    std::string id, thread, kind, liveCursor;
    std::string provider, sessionID;
    std::vector<std::string> frames;
    bool failed = false;
    bool pending = false, progressRequested = false;
    bool empty = false;
    bool requiresWindowAck = false, hasNewer = false;
    uint64_t windowVersion = 0;
    std::string code;
    std::string acknowledgedTransaction;
};
// One bounded persistent I/O lane. The socket/lease loop never waits on disk
// reads. Queued jobs and results count against the same outstanding budget.
class ReadWorker {
public:
    explicit ReadWorker(std::string epoch);
    ~ReadWorker();
    bool submit(ReadJob job);
    std::vector<ReadResult> take();
    std::vector<std::string> takeChanges();
    int notificationFD() const { return notifications_[0]; }
    void drainNotifications();
    void cancel(uint64_t client);
    void shutdown();
private:
    struct Cursor {
        uint64_t client = 0, position = 0, anchor = 0;
        std::string thread, identity, direction, providerCursor;
    };
    void run();
    void notify();
    int notifications_[2] = {-1, -1};
    ReadResult execute(const ReadJob& job);
    std::string cursor(uint64_t client, const std::string& thread, const std::string& identity,
                       uint64_t position, uint64_t anchor, const std::string& direction,
                       const std::string& providerCursor = {});
    std::string epoch_;
    Catalog catalog_;
    FileWakeups wakeups_;
    std::vector<std::string> changes_;
    std::map<std::string, Cursor> cursors_;
    std::deque<std::string> cursorOrder_;
    struct Inventory { std::vector<Source> sources; std::string generation; };
    std::map<uint64_t, Inventory> inventories_;
    std::vector<Source> sharedInventory_;
    std::chrono::steady_clock::time_point inventoryRefresh_{};
    std::string inventoryFallback_;
    std::vector<Source> inventory();
    std::mutex mutex_;
    std::condition_variable changed_;
    std::deque<ReadJob> jobs_;
    std::vector<ReadResult> results_;
    std::deque<uint64_t> cancellations_;
    size_t outstanding_ = 0;
    bool stopped_ = false;
    uint64_t activeClient_ = 0;
    uint64_t nextObservationToken_ = 0;
    std::atomic_bool cancelled_{false};
    CodexServer codex_;
    struct NativeState { CodexReader reader; std::string identity; };
    std::map<std::pair<uint64_t, std::string>, NativeState> native_;
    std::map<std::pair<uint64_t, std::string>, WindowSession> windows_;
    HistoryMetadataBudget historyBudget_;
    ClaudeChainCache claudeChains_{&historyBudget_};
    KimiHistoryCache kimiHistories_{&historyBudget_};
    CodexHistoryCache codexHistories_{&historyBudget_};
    struct NativeReplay { uint64_t client; CodexPage page; size_t bytes; };
    std::map<std::string, NativeReplay> nativeReplay_;
    std::deque<std::string> nativeReplayOrder_;
    size_t nativeReplayBytes_ = 0;
    struct Summary { std::string witness, revision, records; uint64_t modified = 0;
        std::chrono::steady_clock::time_point expires{}; };
    std::map<std::string, Summary> summaries_;
    std::deque<std::string> summaryOrder_;
    struct CodexPageMetadata {
        OpenCodeStore::CodexMetadata value;
        std::string issue, reason;
        std::chrono::steady_clock::time_point refreshed{};
    };
    std::map<std::string, CodexPageMetadata> codexPageMetadata_;
    std::deque<std::string> codexPageMetadataOrder_;
    std::thread thread_;
};
}
