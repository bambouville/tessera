#pragma once
#include "BoundedJson.h"
#include "Normalize.h"
#include <chrono>
#include <iterator>
#include <list>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace tessera {
// Owned by one worker lane, never process-global. Holds no file descriptors or
// DOMs. A resumed read must first reopen the source under Catalog authority.
// At most four oversized projections (each <=1 MiB encoded) can be pending;
// completed entries are evictable, pending entries are not silently restarted.
// Finished default-normalized records also keep their normalized result, so a
// page that spans more bytes than one slice resumes after its last finished
// record instead of rereading every earlier one; that never finished at all
// once a page's records outgrew a slice or the four retained projections.
class JsonlContinuation {
public:
    using Clock = std::chrono::steady_clock;
    JsonlContinuation() = default;
    // The result index holds iterators into this continuation's own list.
    JsonlContinuation(const JsonlContinuation&) = delete;
    JsonlContinuation& operator=(const JsonlContinuation&) = delete;
    static constexpr uint64_t sliceLimit = 64 * 1024 * 1024;
    struct Source {
        std::string path, identity, stamp, provider;
        uint64_t size = 0;
        uint64_t observedRevision = 0;
        bool same(const Source& other) const {
            if (path != other.path || identity != other.identity || provider != other.provider) return false;
            // Validation keeps a revision across appends, which leave a giant
            // record's already-consumed prefix as it was.
            if (observedRevision || other.observedRevision)
                return observedRevision && observedRevision == other.observedRevision;
            return size == other.size && stamp == other.stamp;
        }
        // Whether an entry retained under this source is stale for a reader
        // observing `current`. A pre-validation observation (no revision,
        // such as a bounded header check) and a validated observation
        // describe the same bytes differently; neither can retire the
        // other's progress, or a giant record never finishes while the two
        // alternate within one job. Aging and capacity still bound both.
        bool retiredBy(const Source& current) const {
            if (path != current.path) return false;
            if (identity != current.identity || provider != current.provider) return true;
            if (bool(observedRevision) != bool(current.observedRevision)) return false;
            return !same(current);
        }
    };
    struct Record {
        explicit Record(bool codex) : bounded(codex) {}
        Source source;
        uint64_t start = 0, position = 0, end = 0;
        bool locateEnd = false, complete = false, oversized = false;
        std::string raw;
        BoundedJson bounded;
        Clock::time_point touched = Clock::now();
    };
    struct Scan {
        Source source;
        uint64_t end = 0, position = 0, result = 0;
        bool previous = false, complete = false;
    };
    class Scope {
    public:
        explicit Scope(JsonlContinuation& value) : previous_(active_) { active_ = &value; }
        ~Scope() { active_ = previous_; }
    private:
        JsonlContinuation* previous_;
    };
    // A job that cannot resume must not yield mid-way: readPending would
    // rerun it from scratch, and each rerun gets only one more read through.
    class Suspend {
    public:
        Suspend() : previous_(active_) { active_ = nullptr; }
        ~Suspend() { active_ = previous_; }
    private:
        JsonlContinuation* previous_;
    };
    static JsonlContinuation* active() { return active_; }
    void beginSlice(uint64_t observationToken = 0) {
        consumed_ = 0; sliceStarted_ = Clock::now(); observationToken_ = observationToken;
    }
    uint64_t observationToken() const { return observationToken_; }
    void check(size_t bytes, bool witness) const {
        // Witnesses are <=64 bytes, crossing at most two 64 KiB blocks. They
        // must be allowed to commit the last admitted metadata page at yield.
        if (!witness && (consumed_ + bytes > sliceLimit ||
            (consumed_ && Clock::now() - sliceStarted_ >= std::chrono::milliseconds(250))))
            throw std::runtime_error("readPending");
    }
    void charge(size_t bytes) { consumed_ += bytes; }
    uint64_t consumed() const { return consumed_; }
    Record* find(const Source& source, uint64_t start, uint64_t end, bool locateEnd) {
        const auto now = Clock::now();
        for (auto it = records_.begin(); it != records_.end();) {
            if (now - it->touched > std::chrono::seconds(30) || it->source.retiredBy(source)) { it = records_.erase(it); continue; }
            if (it->source.same(source) && it->start == start &&
                (it->complete ? (locateEnd ? it->end <= end : it->end == end) :
                    it->locateEnd == locateEnd && (locateEnd ? it->position <= end : it->end == end))) {
                it->source = source; it->touched = now; return &*it;
            }
            ++it;
        }
        return nullptr;
    }
    Record& retain(Record record) {
        if (records_.size() >= 4) {
            auto oldest = records_.end();
            for (auto it = records_.begin(); it != records_.end(); ++it)
                if (it->complete && (oldest == records_.end() || it->touched < oldest->touched)) oldest = it;
            if (oldest == records_.end()) throw std::runtime_error("jsonlContinuationCapacity");
            records_.erase(oldest);
        }
        records_.push_back(std::move(record)); return records_.back();
    }
    void validateBudget() {
        size_t bytes = 128 * 1024; // source keys, scan list and allocator overhead
        for (const auto& record : records_) bytes += record.bounded.retainedBytes() + record.raw.capacity();
        if (bytes > 8 * 1024 * 1024) {
            // No staged DOM or partially validated projection is publishable.
            // Release this bounded lane cache on failure, never retain an
            // over-budget entry that permanently blocks subsequent requests.
            records_.clear(); throw std::runtime_error("jsonlContinuationCapacity");
        }
    }
    // Results are evictable; a lost entry only costs its reread. A job
    // replays at most one page (<=100 records plus the one that did not fit,
    // normalized far below their raw bytes), and ReadWorker admits at most 12
    // ordinary jobs, so interleaved pages never evict each other's progress.
    static constexpr size_t resultLimit = 2048;
    static constexpr size_t resultBudget = 8 * 1024 * 1024;
    // A kind names the normalizer that produced a result; "" is the default.
    // Every record read looks here, so a lookup visits only results with the
    // same bounds: walking all of them per record cost a warm page 14 ms once
    // index walks filled the list.
    const NormalizedRecord* result(const Source& source, uint64_t start, uint64_t end, const std::string& kind = {}) {
        const auto now = Clock::now();
        // A hit moves to the back, so the front is always the least recent.
        while (!results_.empty() && now - results_.front().touched > std::chrono::seconds(30)) forget(results_.begin());
        const NormalizedRecord* found = nullptr;
        bool retired = false;
        const auto range = resultIndex_.equal_range({start, end});
        for (auto entry = range.first; entry != range.second; ++entry) {
            const auto it = entry->second;
            if (it->source.retiredBy(source)) retired = true;
            else if (!found && it->kind == kind && it->source.same(source)) {
                it->source = source; it->touched = now;
                results_.splice(results_.end(), results_, it);
                found = &it->value;
            }
        }
        // The source changed under these results: drop all it retired, as a
        // stale result left elsewhere would outlive live ones under pressure.
        // A hit is never retired.
        if (retired) for (auto it = results_.begin(); it != results_.end();) {
            const auto next = std::next(it);
            if (it->source.retiredBy(source)) forget(it);
            it = next;
        }
        return found;
    }
    void remember(const Source& source, uint64_t start, uint64_t end, const NormalizedRecord& value, const std::string& kind = {}) {
        const auto bytes = 256 + value.json.size() + value.sourceType.size() + value.disposition.size() +
            value.providerID.size() + value.parentID.size() + value.turnID.size() + value.chainID.size() + value.chainParentID.size() +
            value.chainLogicalParentID.size() + value.legacyMatchText.size() + value.legacyMatchRole.size();
        if (bytes > resultBudget / 16) return;
        while (!results_.empty() && (results_.size() >= resultLimit || resultBytes_ + bytes > resultBudget))
            forget(results_.begin());
        results_.push_back({source, kind, start, end, bytes, value, Clock::now()});
        // An unindexed result would later be forgotten without ever having
        // been counted, wrapping the byte total so every remember flushed all.
        try { resultIndex_.emplace(Bounds{start, end}, std::prev(results_.end())); }
        catch (...) { results_.pop_back(); throw; }
        resultBytes_ += bytes;
    }
    Scan& scan(const Source& source, uint64_t end, bool previous) {
        for (auto it = scans_.begin(); it != scans_.end();) {
            if (it->source.retiredBy(source)) { it = scans_.erase(it); continue; }
            if (it->source.same(source) && it->end == end && it->previous == previous) {
                it->source = source; return *it;
            }
            ++it;
        }
        if (scans_.size() >= 16) scans_.pop_front();
        scans_.push_back({source, end, previous && end ? end - 1 : end, 0, previous, false});
        return scans_.back();
    }
private:
    inline static thread_local JsonlContinuation* active_ = nullptr;
    uint64_t consumed_ = 0;
    uint64_t observationToken_ = 0;
    Clock::time_point sliceStarted_ = Clock::now();
    struct Result {
        Source source;
        std::string kind;
        uint64_t start = 0, end = 0;
        size_t bytes = 0;
        NormalizedRecord value;
        Clock::time_point touched;
    };
    std::list<Record> records_;
    struct Bounds {
        uint64_t start = 0, end = 0;
        bool operator==(const Bounds& other) const { return start == other.start && end == other.end; }
    };
    struct BoundsHash {
        size_t operator()(const Bounds& value) const {
            return std::hash<uint64_t>()(value.start * 0x9e3779b97f4a7c15ULL ^ value.end);
        }
    };
    void forget(std::list<Result>::iterator it) {
        const auto range = resultIndex_.equal_range({it->start, it->end});
        for (auto entry = range.first; entry != range.second; ++entry)
            if (entry->second == it) { resultIndex_.erase(entry); break; }
        resultBytes_ -= it->bytes; results_.erase(it);
    }
    std::list<Result> results_;
    std::unordered_multimap<Bounds, std::list<Result>::iterator, BoundsHash> resultIndex_;
    size_t resultBytes_ = 0;
    std::list<Scan> scans_;
};
}
