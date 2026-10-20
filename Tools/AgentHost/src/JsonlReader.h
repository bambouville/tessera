#pragma once
#include "Normalize.h"
#include "JsonlContinuation.h"
#include "SourceValidation.h"
#include <array>
#include <cstdint>
#include <string>
#include <vector>
#include <functional>
#include <stdexcept>
#include <optional>

namespace tessera {
struct PositionedRecord {
    uint64_t start = 0, end = 0;
    uint64_t sourceByteOffset = UINT64_MAX;
    uint64_t revision = 1;
    NormalizedRecord value;
    // Physical provenance is independent of canonical/lineage sequence numbers.
    // It supports advisory post-frontier matching, never proof of causality.
    std::string receiptSourceIdentity;
    uint64_t receiptSourceOffset = UINT64_MAX;
    std::string json(const std::string& identity) const;
};
struct JsonlPage {
    std::vector<PositionedRecord> records;
    std::string sourceIdentity;
    uint64_t older = 0, live = 0, bytesRead = 0;
    bool hasOlder = false, hasNewer = false;
    std::string json() const;
};
class JsonlReader {
public:
    using Normalizer = std::function<NormalizedRecord(simdjson::dom::element, bool)>;
    // Takes ownership of an already-authorized descriptor when supplied.
    JsonlReader(const std::string& path, const std::string& provider, int descriptor = -1,
                std::function<bool()> cancelled = {}, Normalizer normalizer = {}, uint64_t prefixEnd = UINT64_MAX);
    ~JsonlReader();
    JsonlReader(const JsonlReader&) = delete;
    JsonlReader& operator=(const JsonlReader&) = delete;
    JsonlPage page(uint64_t position, bool forward, size_t limit = 100);
    // Prefix-only authority probe: never locate EOF or scan an unfinished tail.
    // Empty files have no record; incomplete/oversized headers fail explicitly.
    std::optional<PositionedRecord> firstRecord();
    uint64_t completeEnd();
    uint64_t size() const { return size_; }
    uint64_t snapshotFileSize() const { return snapshotFileSize_; }
    uint64_t bytesRead() const { return readBytes_; }
    std::string identity() const { return identity_; }
    const std::string& mutationStamp() const { return mutationStamp_; }
    void setNormalizer(Normalizer normalizer) { normalizer_ = std::move(normalizer); }
    Normalizer normalizer() const { return normalizer_; }
    // Full coverage is sliced and retained by the source's index owner. Once
    // ready, this reader is pinned to the observed cut, never a moving EOF.
    SourceValidation::Result validatePrefix(SourceValidation& state,
        size_t byteSlice = SourceValidation::defaultSlice,
        SourceValidation::Clock::time_point now = SourceValidation::Clock::now(), uint64_t minimumEnd = 0,
        SourceValidation::WallClock::time_point wallNow = SourceValidation::WallClock::now());
    void setValidationRefresh(bool refresh) { validationRefresh_ = refresh; }
    void validateSnapshot() { unchanged(); }
    uint64_t anchor(uint64_t position);
    PositionedRecord readRecord(uint64_t start, uint64_t end) {
        operationStart_ = readBytes_;
        if (start >= end || end > size_) throw std::runtime_error("invalidCursor");
        unchanged(); auto result = record(start, end); unchanged(); return result;
    }
private:
    void block(uint64_t position);
    uint64_t previousStart(uint64_t end);
    PositionedRecord record(uint64_t start, uint64_t end, bool locateEnd = false);
    void unchanged();
    const JsonlContinuation::Source& continuationSource() const { return continuationSource_; }
    int descriptor_ = -1;
    std::string path_, provider_, identity_;
    std::string mutationStamp_;
    int64_t mtimeNanoseconds_ = 0, ctimeNanoseconds_ = 0;
    uint64_t size_ = 0, sourceLimit_ = 0, snapshotFileSize_ = 0, device_ = 0, inode_ = 0, readBytes_ = 0, operationStart_ = 0;
    uint64_t cacheStart_ = 0;
    size_t cacheSize_ = 0;
    // Keep the prior block: locating a newline and then decoding a record
    // straddling that boundary must not reread both blocks on every crossing.
    std::array<std::array<char, 65536>, 2> buffers_{};
    size_t cacheIndex_ = 0, previousSize_ = 0;
    uint64_t previousStart_ = 0;
    std::array<char, 65536>& cache() { return buffers_[cacheIndex_]; }
    simdjson::dom::parser parser_;
    std::function<bool()> cancelled_;
    Normalizer normalizer_;
    bool readingWitness_ = false;
    bool validationRefresh_ = true;
    JsonlContinuation::Source continuationSource_;
};
}
