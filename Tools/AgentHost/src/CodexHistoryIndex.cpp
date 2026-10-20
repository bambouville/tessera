#include "CodexHistoryIndex.h"
#include "Catalog.h"
#include "Json.h"
#include <algorithm>
#include <set>

namespace tessera {
namespace {
void unique(simdjson::dom::element value) {
    if (!value.is_object()) throw std::runtime_error("codexInvalidEnvelope");
    std::set<std::string_view> keys;
    for (const auto field : simdjson::dom::object(value.get_object().value()))
        if (!keys.insert(field.key).second) throw std::runtime_error("codexAmbiguousEnvelope");
}
std::string identifier(simdjson::dom::element value, const char* key) {
    if (!json::get(value, key).is_string()) throw std::runtime_error("codexInvalidIdentity");
    auto result = json::text(value, key);
    if (result.empty() || result.size() > 256) throw std::runtime_error("codexInvalidIdentity");
    return result;
}
uint64_t ordinal(simdjson::dom::element value, const char* key) {
    uint64_t result;
    if (json::get(value, key).get_uint64().get(result)) throw std::runtime_error("codexInvalidOrdinal");
    return result;
}
bool rejectedEnvelope(const std::runtime_error& error) {
    const std::string code = error.what();
    return code == "codexInvalidEnvelope" || code == "codexAmbiguousEnvelope" ||
        code == "codexInvalidIdentity" || code == "codexInvalidOrdinal";
}
NormalizedRecord rejectedRecord() {
    NormalizedRecord result;
    result.json = R"({"type":"unknown","provider":"codex","malformed":true,"sourceType":"invalid-codex-envelope"})";
    result.disposition = "malformed"; result.sourceType = "invalid-codex-envelope"; result.visible = true;
    return result;
}
}

NormalizedRecord CodexHistoryIndex::metadata(simdjson::dom::element source, bool truncated) try {
    unique(source);
    if (!json::get(source, "type").is_string()) throw std::runtime_error("codexInvalidEnvelope");
    const auto payload = json::get(source, "payload");
    const auto type = json::text(source, "type");
    if (type == "event_msg" || type == "response_item") {
        unique(payload);
        if (!json::get(payload, "type").is_string()) throw std::runtime_error("codexInvalidEnvelope");
    }
    json::Object out;
    if (type == "session_meta") {
        unique(payload);
        out.string("kind", "meta"); out.string("id", identifier(payload, "id"), 256);
        auto mode = json::text(payload, "history_mode");
        if (json::get(payload, "history_mode").is_null()) mode = "legacy";
        if (mode != "legacy" && mode != "paginated") throw std::runtime_error("codexUnknownHistoryMode");
        out.string("mode", mode);
        const auto base = json::get(payload, "history_base");
        if (!base.is_null()) {
            unique(base);
            if (mode != "paginated") throw std::runtime_error("codexInvalidEnvelope");
            out.string("baseThread", identifier(base, "thread_id"), 256);
            const auto baseOrdinal = ordinal(base, "end_ordinal_exclusive");
            if (!baseOrdinal || baseOrdinal == UINT64_MAX) throw std::runtime_error("codexInvalidOrdinal");
            out.number("baseOrdinal", baseOrdinal);
            out.number("baseBytes", ordinal(base, "end_byte_offset"));
        }
        if (!json::get(payload, "subagent_history_start_ordinal").is_null())
            out.number("historyStart", ordinal(payload, "subagent_history_start_ordinal"));
    } else if (type == "event_msg" && json::text(payload, "type") == "item_completed") {
        unique(payload); const auto item = json::get(payload, "item"); unique(item);
        out.string("kind", "completed"); out.string("id", identifier(item, "id"), 256);
        out.string("turn", identifier(payload, "turn_id"), 256);
        out.string("owner", identifier(payload, "thread_id"), 256);
    } else {
        // Canonical selection may omit understood model-context/status rows,
        // but it must not turn an unknown tag or content block into success.
        const auto normalized = normalize("codex", source, truncated);
        simdjson::dom::parser parser;
        const auto value = parser.parse(normalized.json).value();
        const bool diagnostic = normalized.disposition == "unclassified" ||
            json::integer(value, "unparsedContentCount") != 0;
        out.string("kind", diagnostic ? "diagnostic" : "other");
        if (diagnostic) out.string("id", "");
    }
    if (!json::get(source, "ordinal").is_null()) out.number("ordinal", ordinal(source, "ordinal"));
    NormalizedRecord result; result.json = out.finish(); result.disposition = "metadata";
    return result;
} catch (const std::runtime_error& error) {
    if (!rejectedEnvelope(error)) throw;
    return rejectedRecord();
}

NormalizedRecord CodexHistoryIndex::completed(simdjson::dom::element source, bool truncated) try {
    // This callback also reads selected rejected/unknown physical rows. Repeat
    // the index's envelope check so a rejected row cannot become authored text.
    const auto envelope = metadata(source, truncated);
    if (envelope.disposition == "malformed") return envelope;
    unique(source); const auto payload = json::get(source, "payload");
    if (json::text(source, "type") != "event_msg" || json::text(payload, "type") != "item_completed") {
        auto diagnostic = normalize("codex", source, truncated);
        simdjson::dom::parser parser;
        const auto value = parser.parse(diagnostic.json).value();
        if (diagnostic.disposition != "unclassified" && !json::integer(value, "unparsedContentCount"))
            throw std::runtime_error("codexCompletedSourceChanged");
        // A noncanonical row may be inherited model context, even if some
        // of its blocks look like prose. Surface the decoding failure without
        // promoting any of that context into a child thread's authored chat.
        json::Object warning;
        warning.string("type", "unknown"); warning.string("provider", "codex");
        warning.string("sourceType", diagnostic.sourceType, 256);
        const auto unparsed = json::integer(value, "unparsedContentCount");
        if (unparsed > 0) warning.number("unparsedContentCount", static_cast<uint64_t>(unparsed));
        NormalizedRecord result; result.json = warning.finish(); result.sourceType = diagnostic.sourceType;
        result.disposition = "unclassified"; result.visible = true;
        return result;
    }
    unique(payload);
    identifier(payload, "thread_id");
    return normalizeCodexCoreItem(json::get(payload, "item"), identifier(payload, "turn_id"), truncated);
} catch (const std::runtime_error& error) {
    if (!rejectedEnvelope(error)) throw;
    return rejectedRecord();
}

NormalizedRecord CodexHistoryIndex::legacyMatch(simdjson::dom::element source, bool truncated) {
    auto result = normalize("codex", source, truncated);
    const auto type = json::text(source, "type"); const auto payload = json::get(source, "payload");
    const auto kind = json::text(payload, "type");
    result.legacyBoundary = type == "event_msg" && (kind == "task_started" || kind == "turn_started" ||
        kind == "task_complete" || kind == "task_completed" || kind == "turn_aborted");
    if (truncated) return result; // equal clipped prefixes are NOT equal messages
    simdjson::dom::parser parser;
    const auto normalized = parser.parse(result.json).value();
    if (json::integer(normalized, "unparsedContentCount")) return result;
    const auto role = json::text(normalized, "role");
    if (role != "user" && role != "assistant") return result;
    if (type == "event_msg" && (kind == "user_message" || kind == "agent_message")) {
        // Local media paths and embedded media are not interchangeable proof.
        // Preserve both records when full authored-content identity is absent.
        for (const auto field : {"images", "local_images", "audio", "local_audio", "questions"}) {
            const auto value = json::get(payload, field);
            if (!value.is_null() && (!value.is_array() || value.get_array().value().size())) return result;
        }
        if (!json::get(payload, "message").is_string()) return result;
        result.legacyMatchText = json::text(payload, "message"); result.legacyEvent = true;
    } else if (type == "response_item" && kind == "message") {
        const auto content = json::get(payload, "content");
        if (!content.is_array()) return result;
        const auto annotation = json::get(payload, "internal_chat_message_metadata_passthrough");
        const auto kinds = json::get(annotation, "content_item_kinds");
        if (role == "user" && !annotation.is_null()) {
            if (!annotation.is_object()) return result;
            if (annotation.at_key("content_item_kinds").error() != simdjson::NO_SUCH_FIELD) {
                if (!kinds.is_array() || kinds.get_array().value().size() != content.get_array().value().size()) return result;
                for (const auto kind : simdjson::dom::array(kinds.get_array().value())) {
                    if (!kind.is_string() || kind.get_string().value().substr(0, 5) != "user.") return result;
                }
            }
        }
        for (const auto part : simdjson::dom::array(content.get_array().value())) {
            const auto tag = json::text(part, "type");
            if ((tag != "input_text" && tag != "output_text") || !json::get(part, "text").is_string()) {
                result.legacyMatchText.clear(); return result;
            }
            result.legacyMatchText += json::text(part, "text");
        }
    }
    if (!result.legacyMatchText.empty()) result.legacyMatchRole = role + ":" + json::text(payload, "phase");
    return result;
}

namespace {
uint64_t identityHash(const std::string& first, const std::string& second) {
    uint64_t hash = 14695981039346656037ULL;
    for (unsigned char byte : first) { hash ^= byte; hash *= 1099511628211ULL; }
    hash ^= 0xff; hash *= 1099511628211ULL;
    for (unsigned char byte : second) { hash ^= byte; hash *= 1099511628211ULL; }
    return hash;
}
struct RestoreNormalizer {
    JsonlReader& reader; JsonlReader::Normalizer previous;
    explicit RestoreNormalizer(JsonlReader& value) : reader(value), previous(value.normalizer()) {}
    ~RestoreNormalizer() { reader.setNormalizer(std::move(previous)); }
};
}

size_t CodexHistoryIndex::bytes() const {
    return sizeof(*this) + entries_.capacity() * sizeof(Compact) + slots_.capacity() * sizeof(Slot) +
        window_.capacity() * sizeof(Compact) + (bloom_.capacity() + revisionsBloom_.capacity()) * sizeof(uint64_t) + pendingBytes_ +
        checkpoints_.capacity() * sizeof(Checkpoint) + lookup_.turn.capacity() + lookup_.id.capacity() +
        (windowScan_ ? sizeof(WindowScan) + windowScan_->records.capacity() * sizeof(Compact) : 0);
}
CodexHistoryIndex::Compact CodexHistoryIndex::proved(Compact value, const std::string& metadata) {
    SourceDigest digest; digest.append(metadata); const auto bytes = digest.finish();
    std::copy_n(bytes.begin(), value.proof.size(), value.proof.begin()); return value;
}
CodexHistoryIndex::Entry CodexHistoryIndex::decode(JsonlReader& reader, const Compact& value) const {
    RestoreNormalizer restore(reader);
    reader.setNormalizer(mode_ == "legacy" ? JsonlReader::Normalizer(legacyMatch) : JsonlReader::Normalizer(metadata));
    const auto record = reader.readRecord(value.start, value.end);
    if (proved(value, record.value.json).proof != value.proof) throw std::runtime_error("sourceChanged");
    Entry result{value.start, value.end, value.ordinal, value.updatedOrdinal, "", ""};
    if (mode_ == "legacy") result.id = record.value.providerID;
    else if (record.value.disposition == "metadata") {
        simdjson::dom::parser parser; const auto object = parser.parse(record.value.json).value();
        result.turn = json::text(object, "turn"); result.id = json::text(object, "id");
    }
    return result;
}
void CodexHistoryIndex::insertSlot(uint64_t hash, size_t index) {
    size_t at = hash & (slots_.size() - 1);
    while (slots_[at].index) at = (at + 1) & (slots_.size() - 1);
    slots_[at] = {hash, index + 1};
}
void CodexHistoryIndex::rebuildSlots(size_t capacity) {
    if (capacity && capacity != slots_.size()) slots_.assign(capacity, {});
    else std::fill(slots_.begin(), slots_.end(), Slot{});
    if (slots_.empty()) return;
    for (size_t i = 0; i < entries_.size(); ++i) if (entries_[i].hash) insertSlot(entries_[i].hash, i);
}
std::optional<size_t> CodexHistoryIndex::find(JsonlReader& reader, uint64_t hash,
        const std::string& turn, const std::string& id) {
    if (slots_.empty()) return std::nullopt;
    size_t at = hash & (slots_.size() - 1);
    while (slots_[at].index) {
        if (slots_[at].hash == hash) {
            const auto index = slots_[at].index - 1; const auto candidate = decode(reader, entries_[index]);
            // Hashes narrow lookup only. A collision never establishes identity.
            if (candidate.turn == turn && candidate.id == id) return index;
        }
        at = (at + 1) & (slots_.size() - 1);
    }
    return std::nullopt;
}
bool CodexHistoryIndex::maybe(uint64_t hash) const {
    if (bloom_.empty()) return true;
    const uint64_t bits = bloom_.size() * 64;
    uint64_t step = (hash >> 29) | 1;
    for (unsigned i = 0; i < 7; ++i) {
        const auto at = hash % bits;
        if (!(bloom_[at / 64] & (uint64_t(1) << (at % 64)))) return false;
        hash += step;
    }
    return true;
}
void CodexHistoryIndex::remember(uint64_t hash) {
    if (bloom_.empty()) return;
    const uint64_t bits = bloom_.size() * 64;
    uint64_t step = (hash >> 29) | 1;
    for (unsigned i = 0; i < 7; ++i) {
        const auto at = hash % bits; bloom_[at / 64] |= uint64_t(1) << (at % 64); hash += step;
    }
}
void CodexHistoryIndex::windowAppend(const Compact& value, size_t ordinal) {
    if (captureRange_) {
        if (ordinal < captureFirst_ || ordinal - captureFirst_ >= windowLimit_) return;
        if (window_.empty()) windowFirst_ = ordinal;
        window_.push_back(value); return;
    }
    if (window_.size() < windowLimit_) {
        if (window_.empty()) windowFirst_ = ordinal;
        window_.push_back(value);
    } else {
        window_[windowStart_] = value; windowStart_ = (windowStart_ + 1) % windowLimit_; ++windowFirst_;
    }
}
void CodexHistoryIndex::enterLazy(size_t budget) {
    if (lazy_) return;
    lazy_ = true;
    windowLimit_ = std::max<size_t>(1, std::min<size_t>(512, budget / (sizeof(Compact) * 8)));
    // Bloom negatives are proof of absence; positives always perform an exact
    // source lookup. Saturation therefore changes work, never selection.
    const auto bloomBytes = std::max<size_t>(8, std::min<size_t>(4 * 1024 * 1024, budget / 16));
    bloom_.assign(bloomBytes / 8, 0);
    revisionsBloom_.assign(bloomBytes / 8, mode_ == "legacy" && count_ ? UINT64_MAX : 0);
    window_.reserve(windowLimit_);
    for (size_t i = 0; i < entries_.size(); ++i) {
        if (entries_[i].hash) {
            remember(entries_[i].hash);
            if (entries_[i].ordinal != entries_[i].updatedOrdinal) rememberRevision(entries_[i].hash);
        }
        windowAppend(entries_[i], i);
    }
    for (const auto& entry : legacyPending_) remember(identityHash(entry.first.first, entry.first.second));
    std::vector<Compact>().swap(entries_); std::vector<Slot>().swap(slots_);
    legacyPending_.clear(); pendingBytes_ = 0;
}
void CodexHistoryIndex::append(Compact value, size_t budget) {
    checkpoint(value, budget);
    if (!lazy_) {
        const auto entryCapacity = entries_.size() == entries_.capacity() ? std::max<size_t>(256, entries_.capacity() * 2) : entries_.capacity();
        auto slotCapacity = slots_.size();
        if (value.hash && (slots_.empty() || (count_ + 1) * 10 > slots_.size() * 7)) slotCapacity = std::max<size_t>(1024, slots_.size() * 2);
        const auto growthPeak = bytes() + (entryCapacity != entries_.capacity() ? entryCapacity * sizeof(Compact) : 0) +
            (slotCapacity != slots_.size() ? slotCapacity * sizeof(Slot) : 0) + std::min<size_t>(8 * 1024 * 1024, budget / 8) + 32 * 1024;
        if (growthPeak > budget) enterLazy(budget);
        else {
            if (entryCapacity > entries_.capacity()) entries_.reserve(entryCapacity);
            if (slotCapacity != slots_.size()) rebuildSlots(slotCapacity);
        }
    }
    if (lazy_) { windowAppend(value, count_); if (value.hash) remember(value.hash); }
    else { entries_.push_back(value); if (value.hash) insertSlot(value.hash, count_); }
    ++count_;
}
bool CodexHistoryIndex::seenBefore(JsonlReader& reader, const std::string& turn, const std::string& id,
        uint64_t before, const std::function<bool()>& cancelled) {
    if (!lookup_.active || lookup_.turn != turn || lookup_.id != id || lookup_.before != before)
        lookup_ = {turn, id, before, 0, true};
    RestoreNormalizer restore(reader); reader.setNormalizer(metadata);
    simdjson::dom::parser parser;
    while (lookup_.position < before) {
        if (cancelled && cancelled()) throw std::runtime_error("cancelled");
        const auto page = reader.page(lookup_.position, true, 100);
        if (page.records.empty()) throw std::runtime_error("codexIndexNoProgress");
        for (const auto& record : page.records) {
            if (record.start >= before) break;
            lookup_.position = record.end;
            if (record.value.disposition != "metadata") continue;
            const auto object = parser.parse(record.value.json).value();
            if (json::text(object, "kind") == "completed" && ordinal(object, "ordinal") >= historyStart_ &&
                json::text(object, "turn") == turn && json::text(object, "id") == id) {
                lookup_.active = false; return true;
            }
        }
    }
    lookup_.active = false; return false;
}
int64_t CodexHistoryIndex::legacyBalance(JsonlReader& reader, const std::pair<std::string, std::string>& key,
        uint64_t before, const std::function<bool()>& cancelled) {
    if (!lookup_.active || lookup_.turn != key.first || lookup_.id != key.second || lookup_.before != before) {
        lookup_ = {key.first, key.second, before, legacyBoundary_, true}; lookupBalance_ = 0;
    }
    RestoreNormalizer restore(reader); reader.setNormalizer(legacyMatch);
    while (lookup_.position < before) {
        if (cancelled && cancelled()) throw std::runtime_error("cancelled");
        const auto page = reader.page(lookup_.position, true, 100);
        if (page.records.empty()) throw std::runtime_error("codexIndexNoProgress");
        for (const auto& record : page.records) {
            if (record.start >= before) break;
            lookup_.position = record.end;
            if (record.value.legacyBoundary) lookupBalance_ = 0;
            else if (record.value.legacyMatchRole == key.first && record.value.legacyMatchText == key.second)
                lookupBalance_ += record.value.legacyEvent ? 1 : -1;
        }
    }
    lookup_.active = false; return lookupBalance_;
}
void CodexHistoryIndex::updateWindow(JsonlReader& reader, uint64_t hash, const std::string& turn,
        const std::string& id, const Compact& value) {
    for (auto& candidate : window_) if (candidate.hash == hash) {
        const auto decoded = decode(reader, candidate);
        if (decoded.turn == turn && decoded.id == id) {
            const auto ordinal = candidate.ordinal; candidate = value; candidate.ordinal = ordinal; return;
        }
    }
}
bool CodexHistoryIndex::maybeRevision(uint64_t hash) const {
    if (revisionsBloom_.empty()) return true;
    const uint64_t bits = revisionsBloom_.size() * 64; const auto step = (hash >> 29) | 1;
    for (unsigned i = 0; i < 7; ++i) {
        const auto at = hash % bits;
        if (!(revisionsBloom_[at / 64] & (uint64_t(1) << (at % 64)))) return false;
        hash += step;
    }
    return true;
}
void CodexHistoryIndex::rememberRevision(uint64_t hash) {
    if (revisionsBloom_.empty()) return;
    const uint64_t bits = revisionsBloom_.size() * 64; const auto step = (hash >> 29) | 1;
    for (unsigned i = 0; i < 7; ++i) {
        const auto at = hash % bits; revisionsBloom_[at / 64] |= uint64_t(1) << (at % 64); hash += step;
    }
}
void CodexHistoryIndex::checkpoint(const Compact& value, size_t budget) {
    if (count_ % checkpointStride_) return;
    const auto limit = std::max<size_t>(2, std::min<size_t>(2048, budget / (sizeof(Checkpoint) * 16)));
    if (checkpoints_.size() >= limit) {
        size_t kept = 0;
        for (size_t i = 0; i < checkpoints_.size(); i += 2) checkpoints_[kept++] = checkpoints_[i];
        checkpoints_.resize(kept);
        if (checkpointStride_ > SIZE_MAX / 2) return;
        checkpointStride_ *= 2;
        if (count_ % checkpointStride_) return;
    }
    checkpoints_.push_back({count_, value.start, legacyBoundary_, value.ordinal});
}
void CodexHistoryIndex::fillWindow(JsonlReader& reader, size_t position) {
    if (!windowScan_ || position < windowScan_->requested || position - windowScan_->requested >= windowLimit_) {
        WindowScan scan; scan.requested = position > windowLimit_ / 2 ? position - windowLimit_ / 2 : 0;
        scan.sourceEnd = position_;
        for (const auto& checkpoint : checkpoints_) if (checkpoint.ordinal <= scan.requested) {
            scan.ordinal = checkpoint.ordinal; scan.position = checkpoint.position; scan.legacyBoundary = checkpoint.legacyBoundary; scan.physicalOrdinal = checkpoint.physicalOrdinal;
        } else break;
        scan.records.reserve(windowLimit_); windowScan_ = std::move(scan);
    }
    RestoreNormalizer restore(reader); reader.setNormalizer(mode_ == "legacy" ? JsonlReader::Normalizer(legacyMatch) : JsonlReader::Normalizer(metadata));
    simdjson::dom::parser parser;
    auto& scan = *windowScan_;
    while (scan.position < scan.sourceEnd) {
        const auto page = reader.page(scan.position, true, 100);
        if (page.records.empty()) throw std::runtime_error("codexIndexNoProgress");
        for (const auto& record : page.records) {
            if (record.start >= scan.sourceEnd) break;
            auto value = proved({record.start, record.end, scan.physicalOrdinal, scan.physicalOrdinal, 0, {}}, record.value.json); bool selected = false;
            if (mode_ == "legacy") {
                const auto& normalized = record.value;
                if (normalized.legacyBoundary) scan.legacyBoundary = record.end;
                const auto hash = identityHash(normalized.legacyMatchRole, normalized.legacyMatchText);
                bool paired = false;
                if (!normalized.legacyBoundary && !normalized.legacyMatchRole.empty() && maybeRevision(hash)) {
                    const auto saved = legacyBoundary_; legacyBoundary_ = scan.legacyBoundary;
                    int64_t balance;
                    try { balance = legacyBalance(reader, {normalized.legacyMatchRole, normalized.legacyMatchText}, record.start, {}); }
                    catch (...) { legacyBoundary_ = saved; throw; }
                    legacyBoundary_ = saved;
                    paired = balance && ((balance > 0) != normalized.legacyEvent);
                }
                selected = !paired; ++scan.physicalOrdinal;
            } else if (record.value.disposition == "malformed") selected = true;
            else if (record.value.disposition == "metadata") {
                const auto object = parser.parse(record.value.json).value(); const auto kind = json::text(object, "kind");
                value.ordinal = value.updatedOrdinal = ordinal(object, "ordinal"); scan.physicalOrdinal = value.ordinal;
                if (kind == "diagnostic") selected = true;
                else if (kind == "completed" && value.ordinal >= historyStart_) {
                    const auto turn = identifier(object, "turn"), id = identifier(object, "id");
                    value.hash = identityHash(turn, id) | uint64_t(1);
                    if (maybeRevision(value.hash)) {
                        for (auto& candidate : scan.records) if (candidate.hash == value.hash) {
                            const auto prior = decode(reader, candidate);
                            if (prior.turn == turn && prior.id == id) {
                                const auto first = candidate.ordinal; candidate = value; candidate.ordinal = first;
                            }
                        }
                    }
                    if (!scan.revisions) selected = !maybeRevision(value.hash) || !seenBefore(reader, turn, id, record.start, {});
                }
            }
            scan.position = record.end;
            if (!scan.revisions && selected) {
                if (scan.ordinal >= scan.requested && scan.records.size() < windowLimit_) scan.records.push_back(value);
                ++scan.ordinal;
                if (scan.records.size() == windowLimit_) {
                    if (mode_ == "legacy" || std::none_of(scan.records.begin(), scan.records.end(), [&](const Compact& item) { return item.hash && maybeRevision(item.hash); })) {
                        scan.position = scan.sourceEnd; break;
                    }
                    scan.revisions = true;
                }
            }
        }
    }
    window_ = std::move(scan.records); windowFirst_ = scan.requested; windowStart_ = 0; windowScan_.reset();
}
CodexHistoryIndex::Entry CodexHistoryIndex::entry(JsonlReader& reader, size_t position) {
    if (position >= count_) throw std::runtime_error("invalidCursor");
    if (!lazy_) return decode(reader, entries_.at(position));
    if (position < windowFirst_ || position - windowFirst_ >= window_.size()) fillWindow(reader, position);
    if (position < windowFirst_ || position - windowFirst_ >= window_.size()) throw std::runtime_error("codexIndexNoProgress");
    return decode(reader, window_[(windowStart_ + position - windowFirst_) % window_.size()]);
}

void CodexHistoryIndex::refreshLegacy(JsonlReader& reader, const std::function<bool()>& cancelled, size_t budget) {
    RestoreNormalizer restore(reader); reader.setNormalizer(legacyMatch);
    const auto boundary = reader.completeEnd();
    while (position_ < boundary) {
        if (cancelled && cancelled()) throw std::runtime_error("cancelled");
        const auto page = reader.page(position_, true, 100);
        if (page.records.empty()) throw std::runtime_error("codexIndexNoProgress");
        for (const auto& record : page.records) {
            if (cancelled && cancelled()) throw std::runtime_error("cancelled");
            const auto& value = record.value;
            std::pair<std::string, std::string> key{value.legacyMatchRole, value.legacyMatchText};
            const auto hash = identityHash(key.first, key.second);
            const bool matching = !key.first.empty(); const int64_t side = value.legacyEvent ? 1 : -1;
            if (value.legacyBoundary) {
                legacyPending_.clear(); pendingBytes_ = 0; legacyBoundary_ = record.end;
                std::fill(bloom_.begin(), bloom_.end(), 0);
            }
            int64_t balance = 0;
            if (matching && !value.legacyBoundary) {
                if (lazy_) { if (maybe(hash)) balance = legacyBalance(reader, key, record.start, cancelled); }
                else { const auto found = legacyPending_.find(key); if (found != legacyPending_.end()) balance = found->second; }
            }
            const bool paired = balance && ((balance > 0) != (side > 0));
            if (matching && !value.legacyBoundary) {
                if (!lazy_) {
                    const auto cost = key.first.capacity() + key.second.capacity() + 192;
                    if (bytes() + cost + std::min<size_t>(8 * 1024 * 1024, budget / 8) + 32 * 1024 > budget) enterLazy(budget);
                    else {
                        auto found = legacyPending_.find(key);
                        if (found == legacyPending_.end()) { found = legacyPending_.emplace(key, 0).first; pendingBytes_ += cost; }
                        found->second += side;
                        if (!found->second) { pendingBytes_ -= found->first.first.capacity() + found->first.second.capacity() + 192; legacyPending_.erase(found); }
                    }
                }
                if (lazy_) remember(hash);
            }
            if (paired) { ++mirroredRecords_; if (lazy_) rememberRevision(hash); }
            else append(proved({record.start, record.end, lastOrdinal_, lastOrdinal_, 0, {}}, record.value.json), budget);
            ++lastOrdinal_; position_ = record.end;
        }
        witness_ = reader.anchor(position_);
    }
}

void CodexHistoryIndex::refresh(JsonlReader& reader, const std::function<bool()>& cancelled, size_t budget, bool physicalLineageSegment) {
    auto proof = validation_.progress();
    if (!skipValidation_) {
        proof = reader.validatePrefix(validation_, SourceValidation::defaultSlice, SourceValidation::Clock::now(), position_);
        if (!proof.ready) throw std::runtime_error("readPending");
    }
    if (identity_ != reader.identity() || position_ > reader.size() ||
        (!skipValidation_ && validationRevision_ != proof.revision)) {
        auto validation = std::move(validation_);
        const auto force = forceLazy_, capture = captureRange_, skip = skipValidation_;
        const auto first = captureFirst_, limit = windowLimit_;
        *this = CodexHistoryIndex(); validation_ = std::move(validation); validationRevision_ = proof.revision;
        forceLazy_ = force; captureRange_ = capture; skipValidation_ = skip; captureFirst_ = first; windowLimit_ = limit;
        identity_ = reader.identity(); generation_ = "codex-history:" + randomID();
    }
    metadataBudget_ = std::min(budget, HistoryMetadataBudget::indexLimit);
    if (forceLazy_ && !lazy_) enterLazy(metadataBudget_);
    if (!lazy_ && bytes() + 32 * 1024 > metadataBudget_) enterLazy(metadataBudget_);
    seenSize_ = reader.snapshotFileSize(); mutationStamp_ = reader.mutationStamp();
    if (base_ && !physicalLineageSegment) throw std::runtime_error("codexInheritedHistoryRequired");
    if (mode_.empty() && reader.completeEnd()) {
        RestoreNormalizer restore(reader); reader.setNormalizer(metadata);
        const auto first = reader.page(0, true, 1);
        if (!first.records.empty() && first.records.front().value.disposition == "metadata") {
            simdjson::dom::parser parser; const auto value = parser.parse(first.records.front().value.json).value();
            if (json::text(value, "kind") == "meta" && json::text(value, "mode") == "legacy") {
                mode_ = "legacy"; session_ = identifier(value, "id");
            }
        }
    }
    if (mode_ == "legacy") { refreshLegacy(reader, cancelled, metadataBudget_); return; }
    RestoreNormalizer restore(reader); reader.setNormalizer(metadata);
    const auto end = reader.completeEnd();
    while (position_ < end) {
        if (cancelled && cancelled()) throw std::runtime_error("cancelled");
        const auto page = reader.page(position_, true, 100);
        if (page.records.empty()) throw std::runtime_error("codexIndexNoProgress");
        const auto witness = reader.anchor(page.live);
        const auto oldCount = count_, oldSize = entries_.size(); const auto oldPosition = position_;
        const auto oldOrdinal = lastOrdinal_, oldHistory = historyStart_; const auto oldHas = hasOrdinal_;
        const auto oldMode = mode_, oldSession = session_; const auto oldBase = base_;
        const auto oldWindowFirst = windowFirst_, oldWindowStart = windowStart_;
        auto oldWindow = window_;
        const auto oldCheckpoints = checkpoints_; const auto oldCheckpointStride = checkpointStride_;
        std::vector<Compact> oldTail;
        if (!lazy_) {
            const auto retained = std::min(windowLimit_, entries_.size());
            oldTail.assign(entries_.end() - static_cast<ptrdiff_t>(retained), entries_.end());
        }
        std::vector<std::pair<size_t, Compact>> revisions;
        try {
            simdjson::dom::parser parser;
            for (const auto& record : page.records) {
                if (record.value.disposition == "malformed") {
                    if (mode_.empty() || !hasOrdinal_) throw std::runtime_error("codexMissingSessionMeta");
                    append(proved({record.start, record.end, lastOrdinal_, lastOrdinal_, 0, {}}, record.value.json), metadataBudget_); continue;
                }
                if (record.value.disposition != "metadata") throw std::runtime_error("codexIndexUnproven");
                const auto value = parser.parse(record.value.json).value(); const auto kind = json::text(value, "kind");
                if (kind == "meta") {
                    if (!mode_.empty()) {
                        if (ordinal(value, "ordinal") >= historyStart_) throw std::runtime_error("codexRepeatedSessionMeta");
                    } else {
                        if (record.start != 0) throw std::runtime_error("codexMissingSessionMeta");
                        mode_ = json::text(value, "mode"); session_ = identifier(value, "id");
                        if (!json::get(value, "baseThread").is_null()) {
                            if (!physicalLineageSegment) throw std::runtime_error("codexInheritedHistoryRequired");
                            base_ = HistoryBase{identifier(value, "baseThread"), ordinal(value, "baseOrdinal"), ordinal(value, "baseBytes")};
                        }
                        if (!json::get(value, "historyStart").is_null()) historyStart_ = ordinal(value, "historyStart");
                    }
                }
                if (mode_.empty()) throw std::runtime_error("codexMissingSessionMeta");
                const auto current = ordinal(value, "ordinal");
                // Codex rollouts can carry thread_settings_applied with the
                // preceding row's ordinal (observed in cli 0.153 rollouts, likely
                // two writers racing on a resume), and the counter continues from
                // that value, so accepting the repeat keeps nextOrdinal() aligned
                // with lineage cutoffs. Only rows that
                // carry no transcript content may repeat: a repeated item row would
                // defeat enterLazy's ordinal-based revision bookkeeping, and
                // session_meta stays unique. Gaps and decreases remain
                // discontinuities, so a repeat can only add metadata or diagnostic
                // rows, never history.
                const bool repeat = hasOrdinal_ && current == lastOrdinal_ && kind != "completed" && kind != "meta";
                if ((!hasOrdinal_ && current != (base_ ? base_->ordinal : 0)) ||
                    (hasOrdinal_ && (lastOrdinal_ == UINT64_MAX || (!repeat && current != lastOrdinal_ + 1))))
                    throw std::runtime_error("codexOrdinalDiscontinuity");
                lastOrdinal_ = current; hasOrdinal_ = true;
                if (kind == "diagnostic") { append(proved({record.start, record.end, current, current, 0, {}}, record.value.json), metadataBudget_); continue; }
                if (kind != "completed" || current < historyStart_) continue;
                const auto turn = identifier(value, "turn"), id = identifier(value, "id");
                const auto hash = identityHash(turn, id) | uint64_t(1);
                const auto fresh = proved({record.start, record.end, current, current, hash, {}}, record.value.json);
                if (lazy_) {
                    if (maybe(hash) && seenBefore(reader, turn, id, record.start, cancelled)) {
                        rememberRevision(hash); updateWindow(reader, hash, turn, id, fresh);
                    }
                    else append(fresh, metadataBudget_);
                } else if (const auto found = find(reader, hash, turn, id)) {
                    if (*found < oldSize) revisions.emplace_back(*found, entries_[*found]);
                    auto& existing = entries_[*found]; existing.start = record.start; existing.end = record.end; existing.updatedOrdinal = current; existing.proof = fresh.proof;
                } else append(fresh, metadataBudget_);
            }
            position_ = page.live; witness_ = witness;
        } catch (...) {
            count_ = oldCount; position_ = oldPosition; checkpoints_ = oldCheckpoints; checkpointStride_ = oldCheckpointStride;
            if (!lazy_) {
                entries_.resize(oldSize);
                for (auto at = revisions.rbegin(); at != revisions.rend(); ++at) entries_[at->first] = at->second;
                rebuildSlots();
            }
            if (lazy_ && oldWindow.empty() && !oldTail.empty()) {
                window_ = std::move(oldTail); windowFirst_ = oldCount - window_.size(); windowStart_ = 0;
            } else { window_ = std::move(oldWindow); windowFirst_ = oldWindowFirst; windowStart_ = oldWindowStart; }
            lastOrdinal_ = oldOrdinal; hasOrdinal_ = oldHas; historyStart_ = oldHistory;
            mode_ = oldMode; session_ = oldSession; base_ = oldBase;
            throw;
        }
    }
}

const std::string& CodexHistoryIndex::identityForLineage(const std::string& witness) {
    if (witness != lineageWitness_) { lineageWitness_ = witness; lineageGeneration_ = "codex-history:" + randomID(); }
    return lineageGeneration_;
}

bool CodexHistoryCache::evict(const std::string& except) {
    auto victim = indexes_.end();
    for (auto entry = indexes_.begin(); entry != indexes_.end(); ++entry)
        if (entry->first != except && !pinned_.count(entry->first) && !transientPins_.count(entry->first) && !pendingPins_.count(entry->first) &&
            (victim == indexes_.end() || entry->second.touched < victim->second.touched)) victim = entry;
    if (victim == indexes_.end()) return false;
    indexes_.erase(victim); return true;
}
size_t CodexHistoryCache::overhead(const std::string& key, const Cached& cached) {
    size_t bytes = 512 + key.capacity() + cached.dependencies.capacity() * sizeof(std::string);
    for (const auto& dependency : cached.dependencies) bytes += dependency.capacity();
    return bytes;
}
void CodexHistoryCache::pin(std::set<std::string> paths) {
    pinned_ = std::move(paths);
    for (const auto& entry : indexes_) if (pinned_.count(entry.first))
        for (const auto& dependency : entry.second.dependencies) pinned_.insert(dependency);
}
void CodexHistoryCache::lineage(const std::string& path, std::vector<std::string> dependencies) {
    auto found = indexes_.find(path);
    if (found == indexes_.end()) throw std::runtime_error("codexIndexCapacity");
    for (const auto& dependency : dependencies) if (dependency.size() > 2080) throw std::runtime_error("codexLineageCapacity");
    found->second.dependencies = std::move(dependencies);
    // Dependency metadata is included in the same shared allowance.
    (void)budgetFor(path);
}
CodexHistoryIndex& CodexHistoryCache::get(const std::string& path) {
    auto found = indexes_.find(path);
    if (found == indexes_.end()) {
        if (indexes_.size() >= 24) (void)evict(path);
        found = indexes_.try_emplace(path).first;
    }
    found->second.touched = ++clock_;
    return found->second.index;
}
size_t CodexHistoryCache::usedBytes() const {
    size_t result = 0;
    for (const auto& entry : indexes_) result += overhead(entry.first, entry.second) + entry.second.index.bytes();
    return result;
}
size_t CodexHistoryCache::budgetFor(const std::string& path) {
    for (;;) {
        const auto family = budget_ ? budget_->allowance(this, HistoryMetadataBudget::totalLimit) : HistoryMetadataBudget::totalLimit;
        size_t other = 0;
        for (const auto& entry : indexes_) {
            other += overhead(entry.first, entry.second);
            if (entry.first != path) other += entry.second.index.bytes();
        }
        const auto available = other >= family ? 0 : family - other;
        if (available >= HistoryMetadataBudget::indexLimit) return HistoryMetadataBudget::indexLimit;
        if (!evict(path)) return available;
    }
}
}
