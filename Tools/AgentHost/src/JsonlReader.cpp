#include "JsonlReader.h"
#include "BoundedJson.h"
#include "Json.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace tessera {
namespace {
constexpr uint64_t maximumReadWork = 64 * 1024 * 1024;
constexpr size_t maximumPage = 262144;
}

JsonlReader::JsonlReader(const std::string& path, const std::string& provider, int descriptor, std::function<bool()> cancelled, Normalizer normalizer, uint64_t prefixEnd)
    : path_(path), provider_(provider), cancelled_(std::move(cancelled)), normalizer_(std::move(normalizer)) {
    descriptor_ = descriptor >= 0 ? descriptor : ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat info{};
    if (descriptor_ < 0 || ::fstat(descriptor_, &info) || !S_ISREG(info.st_mode) || info.st_size < 0) {
        if (descriptor_ >= 0) ::close(descriptor_);
        descriptor_ = -1;
        throw std::runtime_error("sourceMissing");
    }
    snapshotFileSize_ = static_cast<uint64_t>(info.st_size);
    if (prefixEnd != UINT64_MAX && prefixEnd > snapshotFileSize_) {
        ::close(descriptor_); descriptor_ = -1; throw std::runtime_error("sourceChanged");
    }
    size_ = prefixEnd == UINT64_MAX ? snapshotFileSize_ : prefixEnd;
    sourceLimit_ = size_;
    device_ = info.st_dev; inode_ = info.st_ino;
    identity_ = "jsonl:" + std::to_string(device_) + ":" + std::to_string(inode_);
#ifdef __APPLE__
    const auto modified = info.st_mtimespec;
    const auto changed = info.st_ctimespec;
#else
    const auto modified = info.st_mtim;
    const auto changed = info.st_ctim;
#endif
    mutationStamp_ = std::to_string(modified.tv_sec) + ":" + std::to_string(modified.tv_nsec) + ":" +
        std::to_string(changed.tv_sec) + ":" + std::to_string(changed.tv_nsec);
    mtimeNanoseconds_ = static_cast<int64_t>(modified.tv_sec) * 1000000000 + modified.tv_nsec;
    ctimeNanoseconds_ = static_cast<int64_t>(changed.tv_sec) * 1000000000 + changed.tv_nsec;
    continuationSource_ = {path_, identity_, mutationStamp_, provider_, snapshotFileSize_};
}
JsonlReader::~JsonlReader() { if (descriptor_ >= 0) ::close(descriptor_); }

SourceValidation::Result JsonlReader::validatePrefix(SourceValidation& state, size_t byteSlice,
        SourceValidation::Clock::time_point now, uint64_t minimumEnd,
        SourceValidation::WallClock::time_point wallNow) {
    unchanged();
    const SourceValidation::Source source{identity_, mutationStamp_, sourceLimit_, mtimeNanoseconds_, ctimeNanoseconds_};
    const auto result = state.advance(source, [&](uint64_t offset, char* bytes, size_t count) {
        if (cancelled_ && cancelled_()) throw std::runtime_error("cancelled");
        if (auto* context = JsonlContinuation::active()) context->check(count, false);
        ssize_t received;
        do { received = ::pread(descriptor_, bytes, count, static_cast<off_t>(offset)); }
        while (received < 0 && errno == EINTR);
        if (received < 0 || static_cast<size_t>(received) != count) throw std::runtime_error("sourceChanged");
        readBytes_ += count;
        if (auto* context = JsonlContinuation::active()) context->charge(count);
    }, byteSlice, now, JsonlContinuation::active() ? JsonlContinuation::active()->observationToken() : 0,
       minimumEnd, validationRefresh_, wallNow);
    unchanged();
    if (result.ready) {
        size_ = result.validatedEnd;
        cacheSize_ = previousSize_ = 0;
        continuationSource_.stamp = mutationStamp_ + ":observed:" + std::to_string(result.revision);
        continuationSource_.size = size_;
        continuationSource_.observedRevision = result.revision;
    }
    return result;
}

void JsonlReader::unchanged() {
    struct stat info{};
    if (::lstat(path_.c_str(), &info) || !S_ISREG(info.st_mode) ||
        static_cast<uint64_t>(info.st_dev) != device_ || static_cast<uint64_t>(info.st_ino) != inode_ ||
        info.st_size < 0 || static_cast<uint64_t>(info.st_size) < snapshotFileSize_) throw std::runtime_error("sourceChanged");
#ifdef __APPLE__
    const auto modified = info.st_mtimespec;
    const auto changed = info.st_ctimespec;
#else
    const auto modified = info.st_mtim;
    const auto changed = info.st_ctim;
#endif
    if (static_cast<uint64_t>(info.st_size) == snapshotFileSize_ &&
        std::to_string(modified.tv_sec) + ":" + std::to_string(modified.tv_nsec) + ":" +
        std::to_string(changed.tv_sec) + ":" + std::to_string(changed.tv_nsec) != mutationStamp_)
        throw std::runtime_error("sourceChanged");
}

void JsonlReader::block(uint64_t position) {
    if (cancelled_ && cancelled_()) throw std::runtime_error("cancelled");
    if (position >= size_) throw std::runtime_error("invalidCursor");
    if (cacheSize_ && position >= cacheStart_ && position < cacheStart_ + cacheSize_) return;
    if (previousSize_ && position >= previousStart_ && position < previousStart_ + previousSize_) {
        std::swap(cacheStart_, previousStart_); std::swap(cacheSize_, previousSize_); cacheIndex_ ^= 1;
        return;
    }
    previousStart_ = cacheStart_; previousSize_ = cacheSize_; cacheIndex_ ^= 1;
    cacheStart_ = position - position % cache().size();
    cacheSize_ = 0;
    const auto requested = static_cast<size_t>(std::min<uint64_t>(cache().size(), size_ - cacheStart_));
    auto* continuation = JsonlContinuation::active();
    if (continuation) continuation->check(requested, readingWitness_);
    else if (readBytes_ - operationStart_ + requested > maximumReadWork) throw std::runtime_error("readBudgetExceeded");
    ssize_t count;
    do { count = ::pread(descriptor_, cache().data(), requested, static_cast<off_t>(cacheStart_)); } while (count < 0 && errno == EINTR);
    if (count < 0 || static_cast<size_t>(count) != requested) throw std::runtime_error("sourceChanged");
    cacheSize_ = static_cast<size_t>(count); readBytes_ += cacheSize_;
    if (continuation) continuation->charge(cacheSize_);
}

uint64_t JsonlReader::completeEnd() {
    auto* context = JsonlContinuation::active();
    auto* scan = context ? &context->scan(continuationSource(), size_, false) : nullptr;
    if (scan && scan->complete) return scan->result;
    uint64_t position = scan ? scan->position : size_;
    while (position) {
        block(position - 1);
        const auto begin = cacheStart_;
        for (auto i = position; i > begin; --i) if (cache()[i - begin - 1] == '\n') {
            if (scan) { scan->complete = true; scan->result = i; }
            return i;
        }
        position = begin;
        if (scan) scan->position = position;
    }
    if (scan) scan->complete = true;
    return 0;
}
uint64_t JsonlReader::previousStart(uint64_t end) {
    if (!end) return 0;
    block(end - 1);
    if (cache()[end - 1 - cacheStart_] != '\n') throw std::runtime_error("invalidCursor");
    auto* context = JsonlContinuation::active();
    auto* scan = context ? &context->scan(continuationSource(), end, true) : nullptr;
    if (scan && scan->complete) return scan->result;
    uint64_t position = scan ? scan->position : end - 1;
    while (position) {
        block(position - 1);
        const auto begin = cacheStart_;
        for (auto i = position; i > begin; --i) if (cache()[i - begin - 1] == '\n') {
            if (scan) { scan->complete = true; scan->result = i; }
            return i;
        }
        position = begin;
        if (scan) scan->position = position;
    }
    if (scan) scan->complete = true;
    return 0;
}
PositionedRecord JsonlReader::record(uint64_t start, uint64_t end, bool locateEnd) {
    auto* context = JsonlContinuation::active();
    PositionedRecord result;
    result.start = start; result.end = end; result.sourceByteOffset = start;
    result.receiptSourceIdentity = identity_; result.receiptSourceOffset = start;
    // Only the default normalizer's output is a function of the bytes alone.
    const bool remembered = context && !locateEnd && !normalizer_;
    if (remembered) if (const auto* value = context->result(continuationSource(), start, end)) {
        result.value = *value; return result;
    }
    JsonlContinuation::Record local(provider_ == "codex");
    local.start = start; local.position = start;
    local.end = end; local.locateEnd = locateEnd;
    local.oversized = !locateEnd && end - start > BoundedJson::maximumDocument;
    auto* state = context ? context->find(continuationSource(), start, end, locateEnd) : nullptr;
    if (!state && context && local.oversized) local.source = continuationSource();
    if (!state) state = context && local.oversized ? &context->retain(std::move(local)) : &local;
    if (state->complete) end = state->end;
    bool foundEnd = !locateEnd || state->complete;
    while (!state->complete && state->position < (locateEnd ? end : end - 1)) {
        auto position = state->position;
        block(position);
        auto length = static_cast<size_t>(std::min<uint64_t>(cacheStart_ + cacheSize_, locateEnd ? end : end - 1) - position);
        if (locateEnd) {
            const auto* begin = cache().data() + (position - cacheStart_);
            if (const auto* newline = static_cast<const char*>(std::memchr(begin, '\n', length))) {
                length = static_cast<size_t>(newline - begin); end = position + length + 1; foundEnd = true;
            }
            // Promote the bounded prefix only once. Forward index construction
            // can locate and decode each line in one physical pass instead of
            // scanning it, evicting it, then rereading its entire body.
            if (!state->oversized && state->raw.size() + length + 1 > BoundedJson::maximumDocument) {
                state->oversized = true; state->bounded.feed(state->raw); std::string().swap(state->raw);
                if (context) { local.source = continuationSource(); state = &context->retain(std::move(local)); }
            }
        }
        const auto piece = std::string_view(cache().data() + (position - cacheStart_), length);
        if (state->oversized) state->bounded.feed(piece); else state->raw.append(piece);
        state->position += length;
        if (context && state->oversized) context->validateBudget();
        if (locateEnd && foundEnd) break;
    }
    if (!foundEnd) throw std::runtime_error("invalidCursor");
    state->complete = true; state->end = end;
    const auto& bounded = state->bounded;
    const auto oversized = state->oversized;
    const auto& document = oversized ? bounded.json() : state->raw;
    simdjson::dom::element value;
    auto error = oversized && (bounded.malformed() || bounded.unsupported()) ? simdjson::TAPE_ERROR : parser_.parse(document).get(value);
    result.end = end;
    if (error || !value.is_object()) {
        const bool unsupported = (oversized && bounded.unsupported() && !bounded.malformed()) || error == simdjson::DEPTH_ERROR;
        json::Object unknown;
        unknown.string("type", "unknown"); unknown.string("provider", provider_);
        unknown.boolean("malformed", !unsupported); unknown.boolean("truncated", unsupported);
        unknown.string("sourceType", unsupported ? "record-budget-exceeded" : "malformed-json");
        result.value.json = unknown.finish(); result.value.visible = true;
        result.value.sourceType = unsupported ? "record-budget-exceeded" : "malformed-json";
        result.value.disposition = unsupported ? "unsupported" : "malformed";
    } else result.value = normalizer_ ? normalizer_(value, oversized && bounded.truncated()) :
        normalize(provider_, value, oversized && bounded.truncated(), provider_ == "pi" || provider_ == "kimi" ? "v1:" + std::to_string(start) : "");
    if (remembered) context->remember(continuationSource(), start, end, result.value);
    return result;
}

std::optional<PositionedRecord> JsonlReader::firstRecord() {
    operationStart_ = readBytes_;
    unchanged();
    if (!size_) return std::nullopt;
    constexpr uint64_t maximumHeader = 8 * 1024 * 1024;
    try {
        auto result = record(0, std::min(size_, maximumHeader), true);
        unchanged();
        return result;
    } catch (const std::runtime_error& error) {
        if (std::strcmp(error.what(), "invalidCursor") != 0) throw;
        unchanged();
        throw std::runtime_error(size_ > maximumHeader ? "headerBudgetExceeded" : "headerIncomplete");
    }
}

JsonlPage JsonlReader::page(uint64_t position, bool forward, size_t limit) {
    if (!limit || limit > 100) throw std::runtime_error("invalidRequest");
    operationStart_ = readBytes_;
    unchanged();
    const auto boundary = completeEnd();
    if (position == std::numeric_limits<uint64_t>::max()) position = forward ? 0 : boundary;
    if (position > boundary) throw std::runtime_error("invalidCursor");
    if (position) { block(position - 1); if (cache()[position - 1 - cacheStart_] != '\n') throw std::runtime_error("invalidCursor"); }
    JsonlPage result;
    result.sourceIdentity = identity_; result.live = forward ? position : boundary;
    result.older = position;
    size_t bytes = 0;
    while ((forward ? position < boundary : position > 0) && result.records.size() < limit) {
        try {
            const auto start = forward ? position : previousStart(position);
            auto value = record(start, forward ? boundary : position, forward);
            const auto end = value.end;
            const auto encoded = value.json(identity_).size();
            // Exact JSONL envelope plus room for the native transaction envelope.
            // Provider IDs may themselves expand when escaped; a flat allowance
            // for unescaped field lengths is not a safe page budget.
            if (bytes + encoded + 1024 > maximumPage - 2048) break;
            bytes += encoded + 1024;
            result.records.push_back(std::move(value));
            position = forward ? end : start;
        } catch (const std::runtime_error& error) {
            // A page's I/O slice can end between records even though its
            // encoded preview budget has room. Publish the admitted prefix
            // with an exclusive continuation; never discard it or claim EOF.
            // A single record that cannot fit still reports capacity rather
            // than looping without progress or skipping that record.
            if (result.records.empty() || (std::strcmp(error.what(), "readBudgetExceeded") != 0 &&
                std::strcmp(error.what(), "readPending") != 0)) throw;
            break;
        }
    }
    if (forward) { result.live = position; result.hasNewer = position < boundary; }
    else { result.older = position; result.hasOlder = position > 0; std::reverse(result.records.begin(), result.records.end()); }
    unchanged();
    result.bytesRead = readBytes_ - operationStart_;
    return result;
}

uint64_t JsonlReader::anchor(uint64_t position) {
    if (position > size_) throw std::runtime_error("invalidCursor");
    // A witness is its own bounded operation (64 bytes, at most two blocks),
    // not part of the preceding page's exhausted scan slice. Keep all physical
    // I/O in readBytes_, including a boundary evicted by a partial next record.
    operationStart_ = readBytes_;
    struct WitnessScope { bool& active; explicit WitnessScope(bool& value) : active(value) { active = true; }
        ~WitnessScope() { active = false; } } witnessScope(readingWitness_);
    uint64_t hash = 14695981039346656037ULL;
    for (uint64_t i = position > 64 ? position - 64 : 0; i < position; ++i) {
        block(i); hash ^= static_cast<unsigned char>(cache()[i - cacheStart_]); hash *= 1099511628211ULL;
    }
    // Integrity witness within the append-only contract, never authorization.
    return hash;
}

std::string PositionedRecord::json(const std::string& identity) const {
    json::Object result;
    result.string("recordID", identity + ":" + std::to_string(start), 256);
    result.number("sourceOffset", start); result.number("sourceEnd", end);
    if (!receiptSourceIdentity.empty() && receiptSourceOffset != UINT64_MAX) {
        result.string("receiptSourceIdentity", receiptSourceIdentity, 256);
        result.number("receiptSourceOffset", receiptSourceOffset);
    }
    result.optional("providerRecordID", value.providerID, 256);
    result.optional("parentID", value.parentID, 256);
    result.string("sourceType", value.sourceType, 256);
    result.string("disposition", value.disposition, 32);
    result.boolean("visible", value.visible); result.raw("record", value.json);
    return result.finish();
}

std::string JsonlPage::json() const {
    json::Object result;
    result.string("sourceIdentity", sourceIdentity);
    result.number("olderPosition", older); result.number("livePosition", live);
    result.boolean("hasOlder", hasOlder); result.boolean("hasNewer", hasNewer);
    result.number("bytesRead", bytesRead);
    std::vector<std::string> values;
    for (const auto& record : records) {
        values.push_back(record.json(sourceIdentity));
    }
    result.raw("records", json::array(values));
    return result.finish();
}
}
