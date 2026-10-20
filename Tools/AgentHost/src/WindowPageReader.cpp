#include "WindowPageReader.h"
#include "Json.h"
#include "OpenCodeStore.h"
#include <algorithm>
#include <limits>
#include <set>
#include <stdexcept>

namespace tessera {
bool WindowPageReader::canonicalCodexAvailable(Source& source, uint64_t& bytesRead) {
    if (source.provider != "codex" || source.path.empty()) return false;
    // A missing cached pathname may have moved into archived_sessions. Only
    // genuine absence permits store fallback; substituted/denied paths fail.
    const auto resolved = catalog_.resolveCodexFile(source.sessionID, true);
    if (resolved.path.empty()) return false;
    source.path = resolved.path;
    JsonlReader reader(source.path, "codex", catalog_.open(source), cancelled_, CodexHistoryIndex::metadata);
    const auto first = reader.firstRecord();
    bytesRead += reader.bytesRead();
    reader.validateSnapshot();
    if (!first) return false;
    const auto& record = first->value;
    if (record.disposition == "malformed" || record.disposition == "unsupported")
        throw std::runtime_error("codexInvalidCanonicalHeader");
    simdjson::dom::parser parser;
    const auto header = parser.parse(record.json).value();
    if (json::text(header, "kind") != "meta") return false;
    if (json::text(header, "id") != source.sessionID) throw std::runtime_error("codexIdentityConflict");
    const auto mode = json::text(header, "mode");
    return mode == "legacy" || mode == "paginated";
}

WindowPageReader::Item WindowPageReader::nativeItem(const Source& source, const std::string& cursor, bool forward,
        std::chrono::steady_clock::time_point deadline, uint64_t initialBytes) {
    if (cancelled_ && cancelled_()) throw std::runtime_error("cancelled");
    const auto consumed = codex_.bytesRead() - initialBytes;
    if (consumed >= 64 * 1024 * 1024) throw std::runtime_error("codexResponseBudgetExceeded");
    json::Object params; params.string("threadId", source.sessionID, 256); params.number("limit", 1);
    params.string("sortDirection", forward ? "asc" : "desc"); params.optional("cursor", cursor, 2048);
    auto raw = codex_.call("thread/items/list", params.finish(), deadline,
        static_cast<size_t>(std::min<uint64_t>(16 * 1024 * 1024, 64 * 1024 * 1024 - consumed)), automatic_);
    simdjson::dom::parser parser; simdjson::dom::element response;
    if (parser.parse(raw).get(response)) throw std::runtime_error("codexMalformedResponse");
    auto data = json::get(response, "data");
    if (!data.is_array() || data.get_array().value().size() > 1) throw std::runtime_error("codexMalformedResponse");
    Item result; result.empty = !data.get_array().value().size();
    result.next = json::text(response, "nextCursor"); result.backwards = json::text(response, "backwardsCursor");
    if (result.next.size() > 2048 || result.backwards.size() > 2048 || (result.empty && !result.next.empty()))
        throw std::runtime_error("codexMalformedCursor");
    if (!result.empty) {
        const auto entry = *data.get_array().value().begin();
        const auto turn = json::text(entry, "turnId");
        if (turn.size() > 256) throw std::runtime_error("codexMalformedItem");
        result.record = normalizeCodexItem(json::get(entry, "item"), turn, codex_.responseTruncated());
        if (result.record.providerID.empty() || result.record.providerID.size() > 256 || result.backwards.empty())
            throw std::runtime_error("codexMissingItemAnchor");
    }
    return result;
}

namespace {
std::string digestText(const SourceDigest& digest) {
    static constexpr char hex[] = "0123456789abcdef"; std::string result;
    for (auto byte : digest.finish()) { result += hex[byte >> 4]; result += hex[byte & 15]; }
    return result;
}
void lineagePart(SourceDigest& digest, const std::string& value) {
    digest.append(std::to_string(value.size())); digest.append(":"); digest.append(value);
}
struct LineageCycle {
    std::string checkpoint;
    uint64_t power = 1, distance = 0;
    explicit LineageCycle(std::string first) : checkpoint(std::move(first)) {}
    void advance(const std::string& next) {
        if (next == checkpoint) throw std::runtime_error("codexLineageCycle");
        ++distance;
        if (distance == power) {
            checkpoint = next; distance = 0;
            if (power <= UINT64_MAX / 2) power *= 2;
        }
    }
};
}
WindowPageReader::HistorySegment WindowPageReader::describeHistory(const Source& source, uint64_t cutoff, uint64_t expectedOrdinal) {
    HistorySegment result; result.source = source; result.cutoff = cutoff;
    result.key = cutoff == UINT64_MAX ? source.path : source.path + "#prefix:" + std::to_string(cutoff);
    // The child and current scan retain useful progress. Arbitrarily deep
    // ancestry never pins every whole index or an open descriptor per ancestor.
    histories_->beginRead(); histories_->hold(historyPath_); histories_->hold(result.key);
    auto& index = histories_->get(result.key);
    JsonlReader reader(source.path, "codex", catalog_.open(source), cancelled_, CodexHistoryIndex::metadata, cutoff);
    reader.setValidationRefresh(refreshValidation_);
    index.refresh(reader, cancelled_, histories_->budgetFor(result.key), true);
    if (index.sessionID() != source.sessionID) throw std::runtime_error("sourceChanged");
    if (cutoff != UINT64_MAX && (!index.paginated() || reader.completeEnd() != cutoff || index.nextOrdinal() != expectedOrdinal))
        throw std::runtime_error("codexLineageCutoffMismatch");
    result.index = &index; result.count = index.size(); result.bytes = reader.size();
    result.witness = cutoff == UINT64_MAX ? index.generation() : index.sourceWitness();
    reader.validateSnapshot(); historyPreparationBytes_ += reader.bytesRead();
    return result;
}
void WindowPageReader::prepareHistory(const Source& source) {
    historySegments_.clear(); activeHistory_.reset(); histories_->beginRead();
    historyCount_ = 0; historySourceEnd_ = 0; historyPreparationBytes_ = 0;
    historyPath_ = source.path; historyRoot_ = source; historyGeneration_.clear(); lazyLineage_ = false;
    auto current = source; uint64_t cutoff = UINT64_MAX, expectedOrdinal = UINT64_MAX;
    LineageCycle cycle(current.sessionID); SourceDigest closure;
    size_t metadataBytes = 0;
    for (;;) {
        if (cancelled()) throw std::runtime_error("cancelled");
        auto segment = describeHistory(current, cutoff, expectedOrdinal);
        if (historyCount_ == 0 && cutoff == UINT64_MAX) historyIndexed_ = segment.index->indexed();
        if (segment.count > SIZE_MAX - historyCount_ || segment.bytes > UINT64_MAX - historySourceEnd_)
            throw std::runtime_error("codexInvalidOrdinal");
        historyCount_ += segment.count; historySourceEnd_ += segment.bytes;
        lineagePart(closure, segment.witness); lineagePart(closure, std::to_string(cutoff));
        const auto base = segment.index->historyBase();
        const auto cost = sizeof(HistorySegment) + segment.key.capacity() + segment.witness.capacity() +
            segment.source.path.capacity() + segment.source.handle.capacity() + segment.source.sessionID.capacity() + 512;
        if (!lazyLineage_ && cost <= 128 * 1024 - metadataBytes) {
            metadataBytes += cost; segment.index = nullptr; historySegments_.push_back(std::move(segment));
        } else if (!lazyLineage_) {
            lazyLineage_ = true; std::vector<HistorySegment>().swap(historySegments_);
        }
        if (!base) break;
        cycle.advance(base->thread); current = catalog_.resolveCodexFile(base->thread);
        cutoff = base->byteOffset; expectedOrdinal = base->ordinal;
    }
    auto& root = histories_->get(source.path);
    historyGeneration_ = root.identityForLineage(digestText(closure));
    if (!lazyLineage_) {
        std::reverse(historySegments_.begin(), historySegments_.end());
        size_t offset = 0; uint64_t bytes = 0;
        for (auto& segment : historySegments_) {
            segment.offset = offset; offset += segment.count; segment.byteOffset = bytes; bytes += segment.bytes;
        }
    }
}
void WindowPageReader::loadHistory(HistorySegment segment) {
    if (activeHistory_) historyPreparationBytes_ += activeHistory_->reader->bytesRead();
    activeHistory_.reset();
    histories_->beginRead(); histories_->hold(historyPath_); histories_->hold(segment.key);
    auto& index = histories_->get(segment.key);
    auto reader = std::make_unique<JsonlReader>(segment.source.path, "codex", catalog_.open(segment.source), cancelled_,
        CodexHistoryIndex::metadata, segment.cutoff);
    reader->setValidationRefresh(refreshValidation_);
    index.refresh(*reader, cancelled_, histories_->budgetFor(segment.key), true);
    const auto witness = segment.cutoff == UINT64_MAX ? index.generation() : index.sourceWitness();
    if (index.size() != segment.count || witness != segment.witness) throw std::runtime_error("sourceChanged");
    reader->setNormalizer(index.paginated() ? JsonlReader::Normalizer(CodexHistoryIndex::completed) : JsonlReader::Normalizer());
    segment.index = &index; segment.reader = std::move(reader); activeHistory_ = std::move(segment);
}
std::pair<WindowPageReader::HistorySegment&, CodexHistoryIndex::Entry> WindowPageReader::historyEntry(size_t position) {
    if (position >= historyCount_) throw std::runtime_error("sourceChanged");
    auto contains = [&](const HistorySegment& segment) {
        return position >= segment.offset && position - segment.offset < segment.count;
    };
    if (!activeHistory_ || !contains(*activeHistory_)) {
        if (!lazyLineage_) {
            const auto found = std::find_if(historySegments_.begin(), historySegments_.end(), contains);
            if (found == historySegments_.end()) throw std::runtime_error("sourceChanged");
            HistorySegment descriptor;
            descriptor.source = found->source; descriptor.key = found->key; descriptor.witness = found->witness;
            descriptor.cutoff = found->cutoff; descriptor.bytes = found->bytes; descriptor.count = found->count;
            descriptor.offset = found->offset; descriptor.byteOffset = found->byteOffset;
            loadHistory(std::move(descriptor));
        } else {
            // A deep lineage uses the same bounded reader and a constant-size
            // cycle detector. Reconstruct only the requested segment descriptor.
            auto current = historyRoot_; uint64_t cutoff = UINT64_MAX, expectedOrdinal = UINT64_MAX;
            size_t remaining = historyCount_; uint64_t remainingBytes = historySourceEnd_;
            LineageCycle cycle(current.sessionID); SourceDigest closure; std::optional<HistorySegment> selected;
            for (;;) {
                if (cancelled()) throw std::runtime_error("cancelled");
                auto segment = describeHistory(current, cutoff, expectedOrdinal);
                if (segment.count > remaining || segment.bytes > remainingBytes) throw std::runtime_error("sourceChanged");
                remaining -= segment.count; remainingBytes -= segment.bytes;
                segment.offset = remaining; segment.byteOffset = remainingBytes;
                lineagePart(closure, segment.witness); lineagePart(closure, std::to_string(cutoff));
                const auto base = segment.index->historyBase(); segment.index = nullptr;
                if (contains(segment)) selected = std::move(segment);
                if (!base) break;
                cycle.advance(base->thread); current = catalog_.resolveCodexFile(base->thread);
                cutoff = base->byteOffset; expectedOrdinal = base->ordinal;
            }
            if (remaining || remainingBytes || !selected || histories_->get(historyPath_).identityForLineage(digestText(closure)) != historyGeneration_)
                throw std::runtime_error("sourceChanged");
            loadHistory(std::move(*selected));
        }
    }
    auto& segment = *activeHistory_;
    return {segment, segment.index->entry(*segment.reader, position - segment.offset)};
}
uint64_t WindowPageReader::historyBytesRead() const {
    return historyPreparationBytes_ + (activeHistory_ ? activeHistory_->reader->bytesRead() : 0);
}

WindowRead WindowPageReader::read(const Source& source, const std::string& generation,
        const std::optional<WindowAnchor>& anchor, bool forward, size_t limit, uint64_t& revision) {
    if (!limit || limit > 100 || (anchor && (anchor->source != generation || anchor->forward != forward || anchor->terminal)))
        throw std::runtime_error("invalidWindowAnchor");
    WindowRead result;
    if (source.provider == "opencode") {
        OpenCodeStore database(source.path, cancelled_);
        const auto identity = database.identity(source.sessionID);
        if (anchor && generation != identity) throw std::runtime_error("sourceChanged");
        OpenCodeStore::Key key;
        if (anchor && !anchor->providerCursor.empty()) {
            simdjson::dom::parser parser; const auto value = parser.parse(anchor->providerCursor).value();
            key = {json::integer(value, "created"), json::text(value, "id"), json::text(value, "message")};
            database.exact(source.sessionID, key); // A deleted/moved anchor cannot silently select a different range.
            if (!json::get(value, "previous").is_string() || database.predecessor(source.sessionID, key) != json::text(value, "previous"))
                throw std::runtime_error("sourceChanged");
        }
        auto rows = database.page(source.sessionID, key.id.empty() ? nullptr : &key, forward, limit + 1);
        result.segment.source = identity;
        uint64_t order = anchor ? anchor->position : uint64_t(1) << 52;
        auto boundary = [&](const OpenCodeStore::Row& row, bool direction, bool terminal = false) {
            json::Object cursor; cursor.number("created", static_cast<uint64_t>(row.key.created)); cursor.string("id", row.key.id, 256);
            cursor.optional("message", row.key.message, 256);
            cursor.string("previous", database.predecessor(source.sessionID, row.key), 256);
            return WindowAnchor{identity, cursor.finish(), row.value.providerID, order, 0, direction, terminal};
        };
        if (anchor) { result.before = *anchor; result.after = *anchor; }
        else { result.before.source = identity; result.before.terminal = true; result.after.source = identity; result.after.forward = true; }
        for (size_t index = 0; index < rows.size() && index < limit; ++index) {
            if (anchor || index) {
                if ((!forward && !order) || (forward && order == UINT64_MAX)) throw std::runtime_error("orderBudgetExceeded");
                order = forward ? order + 1 : order - 1;
            }
            if (revision == UINT64_MAX) throw std::runtime_error("revisionBudgetExceeded");
            PositionedRecord record; record.start = order; record.revision = revision + 1; record.value = rows[index].value;
            WindowRecordAnchors bounds{boundary(rows[index], false, !forward && index + 1 == rows.size()),
                boundary(rows[index], true), boundary(rows[index], true)};
            WindowSegment candidate; candidate.records.push_back(record); candidate.anchors.push_back(bounds);
            if (result.segment.bytes() + candidate.bytes() - 1024 + 8192 > PageWindow::pageLimit) break;
            ++revision; result.segment.records.push_back(std::move(record)); result.segment.anchors.push_back(std::move(bounds));
        }
        if (!rows.empty() && result.segment.records.empty()) throw std::runtime_error("windowItemCapacity");
        const bool more = rows.size() > result.segment.records.size();
        if (!forward) { std::reverse(result.segment.records.begin(), result.segment.records.end()); std::reverse(result.segment.anchors.begin(), result.segment.anchors.end()); }
        if (!result.segment.anchors.empty()) { result.before = result.segment.anchors.front().before; result.after = result.segment.anchors.back().after; }
        result.segment.hasOlder = forward ? anchor.has_value() : more;
        result.segment.hasNewer = forward ? more : anchor.has_value();
        result.bytesRead = database.bytesRead(); return result;
    }
    if (generation.rfind("codex-appserver:", 0) != 0) {
        if (source.provider == "codex") {
            prepareHistory(source);
            if (historyIndexed_) {
                const auto& identity = historyGeneration_; const auto count = historyCount_;
                if (anchor && (generation != identity || anchor->position > count)) throw std::runtime_error("sourceChanged");
                // Reuse the authorized descriptor and finite snapshot for
                // index selection, page bodies, and the ensuing revision
                // sweep. A path replacement cannot switch their provenance.
                size_t position = anchor ? anchor->position : forward ? 0 : count;
                result.segment.source = identity; result.sourceEnd = historySourceEnd_;
                auto boundary = [&](size_t value, bool direction) -> WindowAnchor { return {identity, "", "", value, 0, direction, !direction && value == 0}; };
                result.before = boundary(position, false); result.after = boundary(position, true);
                while ((forward ? position < count : position > 0) && result.segment.records.size() < limit) {
                    const auto order = forward ? position : position - 1;
                    auto [segment, entry] = historyEntry(order);
                    auto record = segment.reader->readRecord(entry.start, entry.end);
                    if (record.value.providerID != entry.id) throw std::runtime_error("sourceChanged");
                    // A lineage is one virtual concatenation of immutable
                    // ancestor prefixes plus the mutable child. Receipt offsets
                    // and sourceEnd must use this SAME provenance domain.
                    record.sourceByteOffset = segment.byteOffset + entry.start;
                    record.start = order; record.end = order + 1;
                    if (revision == UINT64_MAX) throw std::runtime_error("revisionBudgetExceeded");
                    record.revision = revision + 1;
                    WindowRecordAnchors bounds; bounds.before = boundary(order, false); bounds.after = boundary(order + 1, true); bounds.reread = boundary(order, true);
                    WindowSegment candidate; candidate.records.push_back(record); candidate.anchors.push_back(bounds);
                    if (result.segment.bytes() + candidate.bytes() - 1024 + 8192 > PageWindow::pageLimit) {
                        if (result.segment.records.empty()) throw std::runtime_error("windowItemCapacity");
                        break;
                    }
                    ++revision; result.segment.records.push_back(std::move(record)); result.segment.anchors.push_back(std::move(bounds));
                    position = forward ? order + 1 : order;
                }
                if (!forward) { std::reverse(result.segment.records.begin(), result.segment.records.end()); std::reverse(result.segment.anchors.begin(), result.segment.anchors.end()); }
                if (!result.segment.anchors.empty()) { result.before = result.segment.anchors.front().before; result.after = result.segment.anchors.back().after; }
                result.segment.hasOlder = result.before.position > 0; result.segment.hasNewer = result.after.position < count;
                if (activeHistory_) activeHistory_->reader->validateSnapshot();
                result.bytesRead = historyBytesRead();
                return result;
            }
        }
        JsonlReader reader(source.path, source.provider, catalog_.open(source), cancelled_);
        reader.setValidationRefresh(refreshValidation_);
        if (source.provider == "kimi") {
            auto& index = kimi_->get(source.path);
            reader.setNormalizer(KimiHistoryIndex::metadata);
            index.refresh(reader, cancelled_, kimi_->budgetFor(source.path));
            reader.setNormalizer({});
            const auto& identity = index.generation(); const auto count = index.size();
            if (anchor && (generation != identity || anchor->position > count)) throw std::runtime_error("sourceChanged");
            size_t position = anchor ? anchor->position : forward ? 0 : count;
            result.segment.source = identity; result.sourceEnd = reader.size();
            auto boundary = [&](size_t ordinal, bool direction) -> WindowAnchor {
                return {identity, "", "", ordinal, 0, direction, !direction && ordinal == 0};
            };
            result.before = boundary(position, false); result.after = boundary(position, true);
            const size_t firstOrdinal = forward ? position : position > limit ? position - limit : 0;
            const size_t requested = forward ? std::min(limit, count - position) : position - firstOrdinal;
            const auto selected = requested ? index.materialize(reader, firstOrdinal, requested, cancelled_) : std::vector<KimiHistoryIndex::Materialized>();
            if (selected.size() != requested) throw std::runtime_error("kimiIndexNoProgress");
            while ((forward ? position < count : position > 0) && result.segment.records.size() < limit) {
                const auto ordinal = forward ? position : position - 1;
                const auto& selection = selected.at(ordinal - firstOrdinal);
                const auto& entry = selection.entry;
                auto record = reader.readRecord(entry.start, entry.end);
                if (selection.interrupted) {
                    json::Object body, event, envelope;
                    body.string("output", "Tool execution was interrupted before its result was recorded. Do not assume the tool completed successfully.");
                    body.boolean("isError", true); event.string("type", "tool.result"); event.string("toolCallId", entry.id, 256); event.raw("result", body.finish());
                    envelope.string("type", "context.append_loop_event"); envelope.raw("event", event.finish());
                    simdjson::dom::parser parser;
                    record.value = normalizeKimi(parser.parse(envelope.finish()).value(), false, "interrupted:" + std::to_string(entry.start));
                }
                record.start = ordinal; record.end = ordinal + 1;
                WindowRecordAnchors bounds; bounds.before = boundary(ordinal, false); bounds.after = boundary(ordinal + 1, true);
                WindowSegment candidate; candidate.records.push_back(record); candidate.anchors.push_back(bounds);
                if (result.segment.bytes() + candidate.bytes() - 1024 + 8192 > PageWindow::pageLimit) {
                    if (result.segment.records.empty()) throw std::runtime_error("windowItemCapacity");
                    break;
                }
                result.segment.records.push_back(std::move(record)); result.segment.anchors.push_back(std::move(bounds));
                position = forward ? ordinal + 1 : ordinal;
            }
            if (!forward) { std::reverse(result.segment.records.begin(), result.segment.records.end()); std::reverse(result.segment.anchors.begin(), result.segment.anchors.end()); }
            if (!result.segment.anchors.empty()) { result.before = result.segment.anchors.front().before; result.after = result.segment.anchors.back().after; }
            result.segment.hasOlder = result.before.position > 0; result.segment.hasNewer = result.after.position < count;
            reader.validateSnapshot(); result.bytesRead = reader.bytesRead(); return result;
        }
        if (source.provider == "claude" || source.provider == "pi") {
            const auto key = source.provider == "pi" ? "pi:" + source.path : source.path;
            auto& index = chains_->get(key);
            try { index.refresh(reader, cancelled_, chains_->budgetFor(key), source.provider == "pi", source.sessionID); }
            catch (...) { chains_->enforce(key); throw; }
            chains_->enforce(key);
            if (source.provider == "pi" && (!index.size() || index.entry(reader, 0, cancelled_).id != source.sessionID))
                throw std::runtime_error("piIdentityConflict");
            const auto& identity = index.generation();
            const auto count = index.size();
            if (anchor && (generation != identity || anchor->position > count)) throw std::runtime_error("sourceChanged");
            size_t position = anchor ? anchor->position : forward ? 0 : count;
            result.segment.source = identity; result.sourceEnd = reader.size();
            auto boundary = [&](size_t ordinal, bool direction) -> WindowAnchor {
                return {identity, "", "", ordinal, 0, direction, !direction && ordinal == 0};
            };
            result.before = boundary(position, false); result.after = boundary(position, true);
            while ((forward ? position < count : position > 0) && result.segment.records.size() < limit) {
                const auto ordinal = forward ? position : position - 1;
                const auto entry = index.entry(reader, ordinal, cancelled_);
                auto record = reader.readRecord(entry.start, entry.end);
                // Canonical ordinals stay stable across a proven append. A
                // branch rewrite changes generation before exposing records.
                record.start = ordinal; record.end = ordinal + 1;
                WindowRecordAnchors bounds; bounds.before = boundary(ordinal, false); bounds.after = boundary(ordinal + 1, true);
                WindowSegment candidate; candidate.records.push_back(record); candidate.anchors.push_back(bounds);
                if (result.segment.bytes() + candidate.bytes() - 1024 + 8192 > PageWindow::pageLimit) {
                    if (result.segment.records.empty()) throw std::runtime_error("windowItemCapacity");
                    break;
                }
                result.segment.records.push_back(std::move(record)); result.segment.anchors.push_back(std::move(bounds));
                position = forward ? ordinal + 1 : ordinal;
            }
            if (!forward) {
                std::reverse(result.segment.records.begin(), result.segment.records.end());
                std::reverse(result.segment.anchors.begin(), result.segment.anchors.end());
            }
            if (!result.segment.anchors.empty()) {
                result.before = result.segment.anchors.front().before; result.after = result.segment.anchors.back().after;
            }
            result.segment.hasOlder = result.before.position > 0;
            result.segment.hasNewer = result.after.position < count;
            result.bytesRead = reader.bytesRead();
            return result;
        }
        if (anchor && (reader.identity() != generation || anchor->position > reader.size() || reader.anchor(anchor->position) != anchor->fileWitness))
            throw std::runtime_error("sourceChanged");
        auto page = reader.page(anchor ? anchor->position : std::numeric_limits<uint64_t>::max(), forward, limit);
        result.segment.source = page.sourceIdentity;
        result.segment.records = std::move(page.records); result.segment.hasOlder = page.hasOlder;
        result.segment.hasNewer = forward ? page.hasNewer : anchor.has_value();
        result.before = {page.sourceIdentity, "", "", page.older, reader.anchor(page.older), false, !page.hasOlder};
        result.after = {page.sourceIdentity, "", "", page.live, reader.anchor(page.live), true, false};
        result.sourceEnd = reader.size();
        for (const auto& record : result.segment.records) {
            WindowRecordAnchors bounds;
            bounds.before = {page.sourceIdentity, "", "", record.start, reader.anchor(record.start), false, record.start == 0};
            bounds.after = {page.sourceIdentity, "", "", record.end, reader.anchor(record.end), true, false};
            result.segment.anchors.push_back(std::move(bounds));
        }
        if (!result.segment.anchors.empty()) {
            result.before = result.segment.anchors.front().before;
            result.after = result.segment.anchors.back().after;
            result.segment.hasOlder = !result.before.terminal;
            if (!forward) result.segment.hasNewer = result.after.position < page.live;
        }
        result.bytesRead = reader.bytesRead();
        return result;
    }
    result.segment.source = generation;
    const auto initialBytes = codex_.bytesRead();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
    auto cursor = anchor ? anchor->providerCursor : "";
    uint64_t order = anchor ? anchor->position : uint64_t(1) << 52;
    std::set<std::string> seenIDs, seenCursors;
    if (anchor) { result.before = *anchor; result.after = *anchor; }
    // One extra lookup may normalize an inclusive reverse boundary. It does
    // not consume the normalized-record budget or invent a duplicate order.
    for (size_t calls = 0; result.segment.records.size() < limit && calls <= limit; ++calls) {
        auto item = nativeItem(source, cursor, forward, deadline, initialBytes);
        if (item.empty) break;
        if (!seenIDs.insert(item.record.providerID).second) throw std::runtime_error("codexDuplicateItem");
        if (anchor && calls == 0 && item.record.providerID == anchor->recordID) {
            if (item.next.empty()) break;
            if (item.next == cursor || !seenCursors.insert(item.next).second) throw std::runtime_error("codexCursorDidNotAdvance");
            cursor = item.next; continue;
        }
        if (anchor || !result.segment.records.empty()) {
            if ((!forward && !order) || (forward && order >= (uint64_t(1) << 53) - 1)) throw std::runtime_error("orderBudgetExceeded");
            order = forward ? order + 1 : order - 1;
        }
        if (revision == UINT64_MAX) throw std::runtime_error("revisionBudgetExceeded");
        PositionedRecord record; record.start = order; record.revision = revision + 1; record.value = std::move(item.record);
        WindowRecordAnchors bounds;
        bounds.reread = {generation, item.backwards, record.value.providerID, order, 0, !forward, false};
        bounds.before = {generation, forward ? item.backwards : item.next, record.value.providerID, order, 0, false, !forward && item.next.empty()};
        bounds.after = {generation, forward ? item.next : item.backwards, record.value.providerID, order, 0, true, false};
        if (forward && item.next.empty()) {
            // The ASC tail lacks nextCursor. Reverse-read its exact boundary
            // and use the returned ASC cursor; never reinterpret opaque bytes.
            auto boundary = nativeItem(source, item.backwards, false, deadline, initialBytes);
            if (boundary.empty || boundary.record.providerID != record.value.providerID) throw std::runtime_error("codexBoundaryChanged");
            bounds.after.providerCursor = boundary.backwards;
        }
        WindowSegment candidate;
        candidate.records.push_back(record); candidate.anchors.push_back(bounds);
        // Reserve wire/descriptor space and bound anchor memory independently
        // of raw provider responses. Do not advance beyond an unadmitted item.
        if (result.segment.bytes() + candidate.bytes() - 1024 + 8192 > PageWindow::pageLimit) {
            if (result.segment.records.empty()) throw std::runtime_error("windowItemCapacity");
            result.segment.hasNewer = forward; result.segment.hasOlder = !forward; break;
        }
        ++revision;
        result.segment.records.push_back(std::move(record)); result.segment.anchors.push_back(std::move(bounds));
        if (item.next.empty()) { result.segment.hasNewer = false; break; }
        if (item.next == cursor || !seenCursors.insert(item.next).second) throw std::runtime_error("codexCursorDidNotAdvance");
        cursor = item.next;
        result.segment.hasNewer = forward; result.segment.hasOlder = !forward;
    }
    if (!forward) {
        std::reverse(result.segment.records.begin(), result.segment.records.end());
        std::reverse(result.segment.anchors.begin(), result.segment.anchors.end());
    }
    if (!result.segment.records.empty()) {
        result.before = result.segment.anchors.front().before; result.after = result.segment.anchors.back().after;
        result.segment.hasOlder = !result.before.terminal;
        // DESC reads below an existing boundary necessarily omit newer data.
        if (!forward) result.segment.hasNewer = anchor.has_value();
    }
    result.bytesRead = codex_.bytesRead() - initialBytes;
    return result;
}

PositionedRecord WindowPageReader::reviseNative(const PositionedRecord& record, const WindowRecordAnchors& anchors,
        const Source& source, uint64_t& revision, std::chrono::steady_clock::time_point deadline, uint64_t initialBytes) {
    auto fresh = nativeItem(source, anchors.reread.providerCursor, anchors.reread.forward, deadline, initialBytes);
    if (fresh.empty || fresh.record.providerID != record.value.providerID) throw std::runtime_error("codexRevisionItemMissing");
    auto result = record;
    if (fresh.record.json != record.value.json) {
        if (revision == UINT64_MAX) throw std::runtime_error("revisionBudgetExceeded");
        result.value = std::move(fresh.record); result.revision = ++revision;
    }
    return result;
}
PositionedRecord WindowPageReader::reviseOpenCode(const PositionedRecord& record, const WindowRecordAnchors& anchors,
        const Source& source, uint64_t& revision, uint64_t& bytesRead) {
    OpenCodeStore database(source.path, cancelled_);
    if (database.identity(source.sessionID) != anchors.reread.source) throw std::runtime_error("sourceChanged");
    simdjson::dom::parser parser; const auto cursor = parser.parse(anchors.reread.providerCursor).value();
    auto fresh = database.exact(source.sessionID, {json::integer(cursor, "created"), json::text(cursor, "id"), json::text(cursor, "message")});
    if (!json::get(cursor, "previous").is_string() || database.predecessor(source.sessionID, fresh.key) != json::text(cursor, "previous"))
        throw std::runtime_error("sourceChanged");
    bytesRead += database.bytesRead();
    if (fresh.value.providerID != record.value.providerID) throw std::runtime_error("sourceChanged");
    auto result = record;
    if (fresh.value.json != record.value.json) {
        if (revision == UINT64_MAX) throw std::runtime_error("revisionBudgetExceeded");
        result.value = std::move(fresh.value); result.revision = ++revision;
    }
    return result;
}

PositionedRecord WindowPageReader::reviseHistory(const PositionedRecord& record, const WindowRecordAnchors& anchors,
        const Source& source, uint64_t& revision, uint64_t& bytesRead) {
    if (historyPath_ != source.path || !historyIndexed_ || anchors.reread.source != historyGeneration_ ||
        anchors.reread.position >= historyCount_) throw std::runtime_error("sourceChanged");
    if (activeHistory_) activeHistory_->reader->validateSnapshot();
    auto [segment, entry] = historyEntry(anchors.reread.position);
    if (entry.id != record.value.providerID) throw std::runtime_error("sourceChanged");
    auto result = record;
    // Source offset is the latest completed snapshot, independent of its
    // stable first-occurrence position. Unchanged items require no file read.
    const auto sourceOffset = segment.byteOffset + entry.start;
    if (sourceOffset == record.sourceByteOffset) return result;
    auto& reader = *segment.reader; const auto before = reader.bytesRead();
    auto fresh = reader.readRecord(entry.start, entry.end); bytesRead += reader.bytesRead() - before;
    if (fresh.value.providerID != record.value.providerID) throw std::runtime_error("sourceChanged");
    simdjson::dom::parser parser;
    if (json::text(parser.parse(fresh.value.json).value(), "turnID") != entry.turn) throw std::runtime_error("sourceChanged");
    if (revision == UINT64_MAX) throw std::runtime_error("revisionBudgetExceeded");
    result.value = std::move(fresh.value); result.sourceByteOffset = sourceOffset; result.revision = ++revision;
    return result;
}
}
