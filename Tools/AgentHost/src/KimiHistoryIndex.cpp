#include "KimiHistoryIndex.h"
#include "Catalog.h"
#include "Json.h"
#include <algorithm>
#include <stdexcept>

namespace tessera {
NormalizedRecord KimiHistoryIndex::metadata(simdjson::dom::element value, bool truncated) {
    NormalizedRecord result;
    const auto type = json::text(value, "type"); result.sourceType = type;
    json::Object out; out.string("type", type, 256);
    if (type == "metadata") out.string("version", json::text(value, "protocol_version"), 16);
    auto message = json::get(value, "message");
    auto loop = json::get(value, "event");
    auto origin = json::get(message, "origin");
    for (const auto object : {value, message, loop, origin}) if (object.is_object()) {
        std::set<std::string_view> fields;
        for (const auto field : simdjson::dom::object(object.get_object().value())) if (!fields.insert(field.key).second) result.chainUnproven = true;
    }
        if (type == "context.append_message") {
        const auto role = json::text(message, "role");
        if (!message.is_object() || (role != "user" && role != "assistant" && role != "system" && role != "tool")) result.chainUnproven = true;
        out.string("role", json::text(message, "role"), 32);
        out.string("origin", json::text(origin, "kind"), 64);
        out.string("trigger", json::text(origin, "trigger"), 64);
        if (json::text(origin, "kind") == "system_trigger") out.string("group", json::text(origin, "name"), 256);
        if (json::text(origin, "kind") == "injection") out.string("group", json::text(origin, "ownerPromptId"), 256);
        out.string("id", json::text(message, "id"), 256);
    } else if (type == "context.append_loop_event") {
        const auto kind = json::text(loop, "type");
        if (!loop.is_object() || kind.empty() || kind.size() > 64) result.chainUnproven = true;
        if ((kind == "step.begin" || kind == "step.end") && json::text(loop, "uuid").empty()) result.chainUnproven = true;
        if ((kind == "content.part" || kind == "tool.call") && json::text(loop, "stepUuid").empty()) result.chainUnproven = true;
        if ((kind == "tool.call" || kind == "tool.result") && json::text(loop, "toolCallId").empty()) result.chainUnproven = true;
        out.string("loop", kind, 64);
        out.string("group", json::text(loop, "stepUuid"), 256);
        out.string("id", json::text(loop, "type") == "step.begin" ? json::text(loop, "uuid") : json::text(loop, "toolCallId"), 256);
        const auto part = json::get(loop, "part"); const auto partType = json::text(part, "type");
        auto blank = [](const std::string& text) {
            // ECMAScript trim whitespace, matching upstream vacuousContent.
            for (size_t at = 0; at < text.size();) {
                const auto byte = static_cast<unsigned char>(text[at++]); uint32_t point = byte;
                if (byte >= 0xc0 && byte < 0xe0 && at < text.size()) point = ((byte & 31) << 6) | (text[at++] & 63);
                else if (byte >= 0xe0 && byte < 0xf0 && at + 1 < text.size()) {
                    point = ((byte & 15) << 12) | ((text[at] & 63) << 6) | (text[at + 1] & 63); at += 2;
                }
                if (!((point >= 9 && point <= 13) || point == 32 || point == 0xa0 || point == 0x1680 ||
                    (point >= 0x2000 && point <= 0x200a) || point == 0x2028 || point == 0x2029 || point == 0x202f ||
                    point == 0x205f || point == 0x3000 || point == 0xfeff)) return false;
            }
            return true;
        };
        out.boolean("vacuous", (partType == "text" && blank(json::text(part, "text"))) ||
            (partType == "think" && blank(json::text(part, "think")) && json::get(part, "encrypted").is_null()));
        const auto finish = json::text(loop, "finishReason"); out.boolean("settle", finish != "interrupted" && finish != "error");
    } else if (type == "context.undo") {
        uint64_t count = 0;
        if (json::get(value, "count").get_uint64().get(count) || !count) result.chainUnproven = true;
        out.number("count", count);
    } else if (type == "context.apply_compaction") out.boolean("settle", !json::get(value, "keptUserMessageCount").is_null());
    // A clipped identifier could change replay membership. Large prose and
    // tool output can be clipped safely; control fields may not be.
    for (const auto* name : {"type", "agentId"}) if (json::text(value, name).size() > 256) result.chainUnproven = true;
    for (const auto* name : {"stepUuid", "uuid", "toolCallId"}) if (json::text(loop, name).size() > 256) result.chainUnproven = true;
    if (json::text(message, "id").size() > 256 || json::text(message, "role").size() > 32 ||
        json::text(origin, "kind").size() > 64 || json::text(origin, "trigger").size() > 64 ||
        json::text(origin, "name").size() > 256 || json::text(origin, "ownerPromptId").size() > 256) result.chainUnproven = true;
    if (type.empty() || !value.is_object()) result.chainUnproven = true;
    (void)truncated;
    result.json = out.finish(); result.disposition = "metadata"; return result;
}

namespace {
using Entry = KimiHistoryIndex::Entry;
enum : uint32_t {
    Message = 1, Content = 2, Call = 3, Result = 4, Undo = 5, Boundary = 6,
    StepBegin = 7, StepEnd = 8, OtherLoop = 9, Other = 10,
    KindMask = 15, Anchor = 16, Injection = 32, Summary = 64, Interrupted = 128
};
struct Candidate {
    uint64_t emission = 0, start = 0, end = 0;
    uint32_t flags = 0;
    uint16_t phase = 2, rank = 2;
    std::array<uint8_t, 16> fingerprint{};
    bool operator<(const Candidate& other) const {
        return std::tie(emission, phase, rank, start) < std::tie(other.emission, other.phase, other.rank, other.start);
    }
    bool operator>(const Candidate& other) const { return other < *this; }
};
static_assert(sizeof(Candidate) == 48, "Kimi retained metadata must remain compact");
uint32_t flags(const Entry& e) {
    uint32_t result = e.type == "context.append_message" ? Message : e.type == "loop/content.part" ? Content :
        e.type == "loop/tool.call" ? Call : e.type == "loop/tool.result" ? Result :
        e.type == "context.undo" ? Undo : e.type == "context.clear" || e.type == "context.apply_compaction" ? Boundary :
        e.type == "loop/step.begin" ? StepBegin : e.type == "loop/step.end" ? StepEnd :
        e.type.rfind("loop/", 0) == 0 ? OtherLoop : Other;
    if (e.undoAnchor) result |= Anchor;
    if (e.origin == "injection") result |= Injection;
    if (e.origin == "compaction_summary") result |= Summary;
    return result;
}
Candidate candidate(const Entry& e) { return {e.start, e.start, e.end, flags(e), 2, 2, e.fingerprint}; }
Entry decode(const PositionedRecord& record) {
    if (record.value.chainUnproven || record.value.disposition == "malformed" || record.value.disposition == "unsupported")
        throw std::runtime_error("kimiIndexUnproven");
    simdjson::dom::parser parser;
    const auto value = parser.parse(record.value.json).value();
    Entry e; e.start = record.start; e.end = record.end; e.type = json::text(value, "type");
    SourceDigest metadataDigest; metadataDigest.append(record.value.json);
    const auto fingerprint = metadataDigest.finish();
    std::copy_n(fingerprint.begin(), e.fingerprint.size(), e.fingerprint.begin());
    if (e.type == "metadata" && e.start) throw std::runtime_error("kimiHeaderChanged");
    e.id = json::text(value, "id"); e.group = json::text(value, "group");
    e.role = json::text(value, "role"); e.origin = json::text(value, "origin"); e.trigger = json::text(value, "trigger");
    if (e.type == "context.undo" && json::get(value, "count").get_uint64().get(e.count))
        throw std::runtime_error("kimiIndexUnproven");
    e.vacuous = json::boolean(value, "vacuous"); e.settle = json::boolean(value, "settle");
    if (e.type == "context.append_loop_event") e.type = "loop/" + json::text(value, "loop");
    e.visible = e.role != "system" && e.origin != "injection" && e.origin != "retry" &&
        (e.origin != "system_trigger" || e.group == "goal_continuation" || e.group == "subagent");
    e.undoAnchor = e.role == "user" && (e.origin.empty() || e.origin == "user" ||
        ((e.origin == "skill_activation" || e.origin == "plugin_command") && e.trigger == "user-slash"));
    return e;
}
Entry next(JsonlReader& reader, uint64_t position, bool forward = true) {
    const auto page = reader.page(position, forward, 1);
    if (page.records.empty()) throw std::runtime_error("kimiIndexNoProgress");
    return decode(page.records.front());
}
size_t strings(const Entry& e) {
    return e.type.capacity() + e.id.capacity() + e.group.capacity() + e.role.capacity() + e.origin.capacity() + e.trigger.capacity();
}
struct UseMetadata {
    JsonlReader& reader; JsonlReader::Normalizer previous;
    explicit UseMetadata(JsonlReader& r) : reader(r), previous(r.normalizer()) { reader.setNormalizer(KimiHistoryIndex::metadata); }
    ~UseMetadata() { reader.setNormalizer(std::move(previous)); }
};
// A bounded decode batch amortizes source stat checks without retaining bodies
// beyond the reconstruction cursor. Tiny-budget fallback uses one record.
struct MetadataCursor {
    JsonlPage page;
    size_t at = 0;
    Entry read(JsonlReader& reader, uint64_t position, size_t limit) {
        if (at >= page.records.size() || page.records[at].start != position) {
            page = reader.page(position, true, limit); at = 0;
        }
        if (at == page.records.size()) throw std::runtime_error("kimiIndexNoProgress");
        auto result = decode(page.records[at]); ++at; return result;
    }
    size_t bytes() const {
        size_t result = page.records.capacity() * sizeof(PositionedRecord) + page.sourceIdentity.capacity();
        for (const auto& r : page.records) {
            const auto& v = r.value;
            result += r.receiptSourceIdentity.capacity() + v.json.capacity() + v.sourceType.capacity() + v.disposition.capacity() +
                v.providerID.capacity() + v.parentID.capacity() + v.chainID.capacity() + v.chainParentID.capacity() +
                v.legacyMatchText.capacity() + v.legacyMatchRole.capacity();
        }
        return result;
    }
};
// All source scans below retain their current event before a dependent read.
// readPending therefore resumes the current query, including a single enormous
// pending-tool interval; it does not repeat a 64 MiB prefix forever.
struct CanonicalScan {
    enum class Phase { Read, Process, InterruptedCalls, DeferredMessages, ContentParts, Finish };
    enum class Flush { Result, Settle, Discard, End };
    Phase phase = Phase::Read;
    Flush flush = Flush::End;
    uint64_t position = 0, end = 0, stepStart = 0, pendingStart = 0, pendingCount = 0;
    uint64_t scanPosition = 0, stop = 0;
    Entry current, scanning;
    MetadataCursor mainCursor, auxiliaryCursor;
    size_t pageLimit = 1;
    bool settleAtEnd = false;
    bool scanLoaded = false, vacuous = true, hasCall = false, dropContent = false;
    std::string step;
    std::optional<Candidate> firstBarrier, firstCall;
    struct Lookup {
        std::string id;
        uint64_t end = 0, position = 0;
        bool active = false, done = false;
        std::optional<uint64_t> call;
    } lookup;

    size_t bytes() const { return strings(current) + strings(scanning) + step.capacity() + lookup.id.capacity() + mainCursor.bytes() + auxiliaryCursor.bytes(); }
    std::optional<uint64_t> pending(JsonlReader& reader, const std::string& id, uint64_t until) {
        if (!lookup.active || lookup.id != id || lookup.end != until) {
            lookup = {}; lookup.id = id; lookup.end = until; lookup.position = until; lookup.active = true;
        }
        while (!lookup.done && lookup.position > stepStart) {
            const auto e = next(reader, lookup.position, false);
            if (e.type == "loop/tool.result" && e.id == id) lookup.done = true;
            else if (e.type == "loop/tool.call" && e.group == step && e.id == id) {
                lookup.call = e.start; lookup.done = true;
            }
            lookup.position = e.start;
        }
        if (lookup.position <= stepStart) lookup.done = true;
        return lookup.call;
    }
    void clearLookup() { lookup = {}; }
    void closeStep() {
        step.clear(); pendingCount = 0; pendingStart = 0; firstBarrier.reset(); firstCall.reset();
        vacuous = true; hasCall = false; clearLookup();
    }
    void beginFlush(Flush reason) {
        flush = reason; stop = current.start; scanPosition = stepStart; scanLoaded = false;
        dropContent = reason == Flush::Settle && vacuous && !hasCall;
        phase = reason == Flush::Settle && pendingCount ? Phase::InterruptedCalls :
            reason == Flush::Result ? Phase::DeferredMessages : Phase::ContentParts;
        if (phase == Phase::DeferredMessages) scanPosition = pendingStart;
        clearLookup();
    }
    template<class Emit> void run(JsonlReader& reader, const std::function<bool()>& cancelled, Emit emit) {
        for (;;) {
            if (cancelled && cancelled()) throw std::runtime_error("cancelled");
            if (phase == Phase::Read) {
                if (position == end) {
                    current = {}; current.start = end; current.end = end;
                    if (step.empty()) { phase = Phase::Finish; continue; }
                    beginFlush(settleAtEnd ? Flush::Settle : Flush::End); continue;
                }
                current = mainCursor.read(reader, position, pageLimit); phase = Phase::Process;
            }
            if (phase == Phase::Process) {
                const auto kind = flags(current) & KindMask;
                if (kind == Message) {
                    if (!pendingCount) { auto row = candidate(current); if (!firstBarrier && !step.empty()) firstBarrier = row; emit(row); }
                } else if (kind == StepBegin) { beginFlush(Flush::Settle); continue; }
                else if (kind == Content || kind == Call) {
                    if (!step.empty() && current.group == step) {
                        if (kind == Call) {
                            if (current.id.empty() || (pendingCount && pending(reader, current.id, current.start)))
                                throw std::runtime_error("kimiToolIdentityConflict");
                            clearLookup();
                            auto row = candidate(current);
                            if (firstBarrier && *firstBarrier < row) { row.emission = firstBarrier->emission; row.phase = firstBarrier->phase; }
                            row.rank = 1;
                            if (!firstCall) firstCall = row;
                            emit(row); hasCall = true;
                            if (!pendingCount) pendingStart = current.start;
                            ++pendingCount;
                        }
                        vacuous = vacuous && current.vacuous;
                    }
                } else if (kind == Result) {
                    if (pendingCount && pending(reader, current.id, current.start)) {
                        clearLookup(); auto row = candidate(current);
                        if (!firstBarrier) firstBarrier = row;
                        emit(row); --pendingCount;
                        if (!pendingCount) { beginFlush(Flush::Result); continue; }
                    }
                    clearLookup();
                } else if ((kind == StepEnd && current.settle) || kind == Boundary || kind == Undo) {
                    beginFlush(current.settle && kind != Undo ? Flush::Settle : Flush::Discard); continue;
                } else emit(candidate(current));
                position = current.end; phase = Phase::Read; continue;
            }
            if (phase == Phase::InterruptedCalls || phase == Phase::DeferredMessages || phase == Phase::ContentParts) {
                if (!step.empty() && scanPosition < stop && !(phase == Phase::ContentParts && dropContent)) {
                    if (!scanLoaded) { scanning = auxiliaryCursor.read(reader, scanPosition, pageLimit); scanLoaded = true; }
                    if (phase == Phase::InterruptedCalls && scanning.type == "loop/tool.call" && scanning.group == step) {
                        const auto call = pending(reader, scanning.id, stop);
                        if (call && *call == scanning.start) {
                            auto row = candidate(scanning); row.emission = stop; row.phase = 0; row.flags |= Interrupted;
                            if (!firstBarrier) firstBarrier = row;
                            emit(row);
                        }
                        clearLookup();
                    } else if (phase == Phase::DeferredMessages && scanning.type == "context.append_message") {
                        auto row = candidate(scanning); row.emission = stop; row.phase = flush == Flush::Result ? 3 : 1;
                        if (!firstBarrier) firstBarrier = row;
                        emit(row);
                    } else if (phase == Phase::ContentParts && scanning.type == "loop/content.part" && scanning.group == step) {
                        auto row = candidate(scanning);
                        for (const auto* boundary : {&firstBarrier, &firstCall}) if (*boundary && **boundary < row) {
                            row.emission = (**boundary).emission; row.phase = (**boundary).phase;
                        }
                        row.rank = 0; emit(row);
                    }
                    scanPosition = scanning.end; scanLoaded = false; continue;
                }
                if (phase == Phase::InterruptedCalls) {
                    phase = Phase::DeferredMessages; scanPosition = pendingStart; scanLoaded = false; continue;
                }
                if (phase == Phase::DeferredMessages) {
                    if (flush == Flush::Result) { position = current.end; phase = Phase::Read; continue; }
                    phase = Phase::ContentParts; scanPosition = stepStart; scanLoaded = false; continue;
                }
                closeStep();
                if (flush == Flush::End || (current.start == end && current.end == end && current.type.empty())) {
                    phase = Phase::Finish; continue;
                }
                emit(candidate(current));
                if (current.type == "loop/step.begin") { step = current.id; stepStart = current.end; }
                position = current.end; phase = Phase::Read; continue;
            }
            if (phase == Phase::Finish) return;
        }
    }
};
struct ReverseUndo {
    uint64_t debt = 0;
    std::string injectionOwner;
    bool keep(JsonlReader& reader, const Candidate& c) {
        const auto kind = c.flags & KindMask;
        if (kind == Undo) {
            const auto e = decode(reader.readRecord(c.start, c.end));
            debt = e.count > UINT64_MAX - debt ? UINT64_MAX : debt + e.count;
            return true;
        }
        if (kind == Boundary || (c.flags & Summary)) { debt = 0; injectionOwner.clear(); return true; }
        if (c.flags & Injection) {
            if (injectionOwner.empty()) return true;
            const auto e = decode(reader.readRecord(c.start, c.end));
            if (e.group == injectionOwner) return false;
            injectionOwner.clear(); return true;
        }
        if (kind == Message || kind == Content || kind == Call || kind == Result) {
            if (!debt) { injectionOwner.clear(); return true; }
            std::string owner;
            if (c.flags & Anchor) { owner = decode(reader.readRecord(c.start, c.end)).id; --debt; }
            injectionOwner = std::move(owner); return false;
        }
        if (kind == OtherLoop) injectionOwner.clear();
        return true;
    }
};
void digestCandidate(SourceDigest& digest, const Candidate& c) {
    const uint64_t words[] = {c.start, c.end, static_cast<uint64_t>((c.flags & Interrupted) != 0)};
    digest.append(std::string_view(reinterpret_cast<const char*>(words), sizeof(words)));
    digest.append(std::string_view(reinterpret_cast<const char*>(c.fingerprint.data()), c.fingerprint.size()));
}
struct LazyRequired {};
}

struct KimiHistoryIndex::Impl {
    SourceValidation validation;
    uint64_t validationRevision = 0, boundary = 0;
    std::string generation = "kimi-history:" + randomID(), version;
    CanonicalScan scan;
    ReverseUndo undo;
    std::vector<Candidate> rows;
    std::optional<Candidate> before;
    size_t budget = 0, count = 0, priorCount = 0, foldAt = 0, foldWrite = 0;
    std::array<uint8_t, 32> priorDigest{};
    bool building = false, lazy = false, sorting = false, complete = false;
    // A bounded canonical window remains useful for consecutive older-page
    // requests. Reconstructing dependencies never stores an unbounded map.
    std::vector<Candidate> window;
    size_t windowFirst = 0, requestedFirst = 0, requestedCount = 0, reverseOrdinal = 0;
    bool materializing = false;
    uint64_t sliceStart = 0, sliceEnd = 0, preparePosition = 0, candidateStart = 0;
    uint64_t linearFrom = 0, linearUntil = 0;
    size_t prepareCount = 0;
    bool prepared = false, endSettles = false, previousSettles = false;
    bool haveCandidate = false, simpleSuffix = true, more = false;

    size_t bytes() const {
        return sizeof(Impl) + generation.capacity() + version.capacity() + scan.bytes() +
            undo.injectionOwner.capacity() + rows.capacity() * sizeof(Candidate) + window.capacity() * sizeof(Candidate);
    }
    void resetScan() {
        scan = {}; scan.position = lazy ? sliceStart : 0; scan.end = lazy ? sliceEnd : boundary;
        scan.settleAtEnd = lazy && endSettles;
        scan.pageLimit = budget >= 1024 * 1024 ? 100 : 1;
        sorting = false; foldAt = 0; more = false;
    }
    void beginSlice(uint64_t end, bool settles = false) {
        sliceEnd = end; endSettles = settles; preparePosition = end; prepared = false;
        prepareCount = 0; haveCandidate = false; simpleSuffix = true; before.reset(); rows.clear();
        sorting = false; foldAt = 0; more = false;
    }
    // Reconstruct local provider epochs, not a fixed physical tail. A new step
    // settles the preceding step *before* its own record, so the left slice is
    // explicitly settled at that cut. Clear/compaction/undo and completed steps
    // reset pending state. Only a proven loop-free interval may be split at an
    // arbitrary message; undo debt still carries across every slice.
    void prepare(JsonlReader& reader, const std::function<bool()>& cancelled) {
        auto choose = [&](uint64_t start, bool settles) {
            sliceStart = start; previousSettles = settles; prepared = true; resetScan();
        };
        while (!prepared && preparePosition) {
            if (cancelled && cancelled()) throw std::runtime_error("cancelled");
            const auto e = next(reader, preparePosition, false); preparePosition = e.start; ++prepareCount;
            if (!haveCandidate && prepareCount >= batchCapacity()) { candidateStart = e.start; haveCandidate = true; }
            if (haveCandidate && sliceEnd <= linearUntil && candidateStart >= linearFrom) { choose(candidateStart, false); break; }
            const auto kind = flags(e) & KindMask;
            const bool closes = kind == Boundary || kind == Undo || (kind == StepEnd && e.settle);
            if (closes && e.end < sliceEnd && haveCandidate) {
                if (simpleSuffix) {
                    linearFrom = e.end; linearUntil = sliceEnd;
                    choose(std::max(candidateStart, e.end), false);
                } else choose(e.end, false);
                break;
            }
            if (kind == StepBegin && haveCandidate) { choose(e.start, true); break; }
            if (e.type.rfind("loop/", 0) == 0) simpleSuffix = false;
            if (!preparePosition) {
                if (simpleSuffix && haveCandidate) { linearFrom = 0; linearUntil = sliceEnd; choose(candidateStart, false); }
                else choose(0, false);
            }
        }
        if (!prepared) choose(0, false);
    }
    bool advanceLazy() {
        if (more && !rows.empty()) { before = rows.front(); rows.clear(); resetScan(); return true; }
        if (!sliceStart) return false;
        beginSlice(sliceStart, previousSettles); return true;
    }
    size_t batchCapacity() const {
        const auto fixed = bytes() - rows.capacity() * sizeof(Candidate) - window.capacity() * sizeof(Candidate);
        return std::max<size_t>(1, std::min<size_t>(8192, budget > fixed ? (budget - fixed) / (3 * sizeof(Candidate)) : 1));
    }
    void collect(const Candidate& row) {
        if (lazy) {
            if (before && !(row < *before)) return;
            const auto capacity = batchCapacity();
            if (rows.size() < capacity) {
                if (rows.capacity() < capacity) rows.reserve(capacity);
                rows.push_back(row); std::push_heap(rows.begin(), rows.end(), std::greater<Candidate>());
            } else {
                more = true;
                if (rows.front() < row) {
                    std::pop_heap(rows.begin(), rows.end(), std::greater<Candidate>()); rows.back() = row;
                    std::push_heap(rows.begin(), rows.end(), std::greater<Candidate>());
                }
            }
        } else {
            if (rows.size() == rows.capacity()) {
                const auto capacity = std::max<size_t>(256, rows.capacity() + rows.capacity() / 2);
                // reserve temporarily owns old and new allocations together.
                if (bytes() + capacity * sizeof(Candidate) + (scan.pageLimit > 1 ? 1024 * 1024 : 4096) > budget) throw LazyRequired{};
                rows.reserve(capacity);
            }
            rows.push_back(row);
        }
    }
    void batch(JsonlReader& reader, const std::function<bool()>& cancelled) {
        if (lazy && !prepared) prepare(reader, cancelled);
        if (!sorting) {
            scan.run(reader, cancelled, [&](const Candidate& c) { collect(c); });
            std::sort(rows.begin(), rows.end()); sorting = true; foldAt = rows.size(); foldWrite = rows.size();
        }
    }
};

KimiHistoryIndex::KimiHistoryIndex() : impl_(std::make_unique<Impl>()) {}
KimiHistoryIndex::~KimiHistoryIndex() = default;
KimiHistoryIndex::KimiHistoryIndex(KimiHistoryIndex&&) noexcept = default;
KimiHistoryIndex& KimiHistoryIndex::operator=(KimiHistoryIndex&&) noexcept = default;
size_t KimiHistoryIndex::size() const { return impl_->count; }
size_t KimiHistoryIndex::bytes() const { return impl_->bytes(); }
const std::string& KimiHistoryIndex::generation() const { return impl_->generation; }

void KimiHistoryIndex::refresh(JsonlReader& reader, const std::function<bool()>& cancelled, size_t budget) {
    UseMetadata metadataMode(reader);
    auto validation = reader.validatePrefix(impl_->validation, SourceValidation::defaultSlice,
        SourceValidation::Clock::now(), impl_->boundary);
    if (!validation.ready) throw std::runtime_error("readPending");
    const auto header = reader.firstRecord();
    if (!header || header->value.sourceType != "metadata") throw std::runtime_error("kimiHeaderMissing");
    if (header->value.chainUnproven || header->value.disposition == "malformed" || header->value.disposition == "unsupported")
        throw std::runtime_error("kimiIndexUnproven");
    simdjson::dom::parser parser;
    const auto version = json::text(parser.parse(header->value.json).value(), "version");
    if (version != "1.4" && version != "1.5") throw std::runtime_error("kimiFormatUnsupported");
    const auto boundary = reader.completeEnd();
    if (impl_->validationRevision != validation.revision || (!impl_->version.empty() && impl_->version != version)) {
        auto saved = std::move(impl_->validation); impl_ = std::make_unique<Impl>(); impl_->validation = std::move(saved);
        impl_->validationRevision = validation.revision;
    }
    auto& state = *impl_; state.budget = budget; state.version = version;
    if (state.complete && state.boundary == boundary) {
        if (state.bytes() > budget) {
            // Pinned pages retain their copied content, not a right to keep a
            // full metadata accelerator when another provider needs the RAM.
            state.lazy = true; std::vector<Candidate>().swap(state.rows); std::vector<Candidate>().swap(state.window);
            state.materializing = false; state.undo = {}; state.beginSlice(boundary);
        }
        return;
    }
    if (!state.building || state.boundary != boundary) {
        if (state.complete) {
            state.priorCount = state.count;
            SourceDigest prior;
            if (!state.lazy) for (const auto& row : state.rows) digestCandidate(prior, row);
            state.priorDigest = prior.finish();
        }
        // Older immutable page bodies remain owned by PageWindow while metadata
        // is reconstructed. Retaining a second full index would double memory.
        std::vector<Candidate>().swap(state.rows); std::vector<Candidate>().swap(state.window);
        state.boundary = boundary; state.building = true; state.complete = false; state.count = 0;
        state.lazy = false; state.before.reset(); state.undo = {}; state.resetScan(); state.materializing = false;
    }
    if (state.bytes() > budget) {
        state.lazy = true; std::vector<Candidate>().swap(state.rows); std::vector<Candidate>().swap(state.window);
        state.count = 0; state.undo = {}; state.beginSlice(boundary);
    }
    for (;;) {
        try { state.batch(reader, cancelled); }
        catch (const LazyRequired&) {
            state.lazy = true; std::vector<Candidate>().swap(state.rows); state.before.reset();
            state.undo = {}; state.count = 0; state.beginSlice(state.boundary); continue;
        }
        while (state.foldAt) {
            if (cancelled && cancelled()) throw std::runtime_error("cancelled");
            const auto row = state.rows[state.foldAt - 1];
            const bool keep = state.undo.keep(reader, row);
            --state.foldAt;
            if (keep) { ++state.count; if (!state.lazy) state.rows[--state.foldWrite] = row; }
        }
        if (!state.lazy) {
            state.rows.erase(state.rows.begin(), state.rows.begin() + static_cast<ptrdiff_t>(state.foldWrite));
            SourceDigest prefix;
            for (size_t i = 0; i < std::min(state.priorCount, state.rows.size()); ++i) digestCandidate(prefix, state.rows[i]);
            if (state.count < state.priorCount || (state.priorCount && prefix.finish() != state.priorDigest)) state.generation = "kimi-history:" + randomID();
            break;
        }
        if (!state.advanceLazy()) { if (state.priorCount) state.generation = "kimi-history:" + randomID(); break; }
    }
    reader.validateSnapshot(); state.building = false; state.complete = true;
    if (state.lazy) { state.undo = {}; state.beginSlice(state.boundary); }
}

std::vector<KimiHistoryIndex::Materialized> KimiHistoryIndex::materialize(
    JsonlReader& reader, size_t first, size_t count, const std::function<bool()>& cancelled) {
    UseMetadata metadataMode(reader); auto& state = *impl_;
    if (!state.complete || first > state.count || count > state.count - first) throw std::runtime_error("invalidCursor");
    if (count > 100) throw std::runtime_error("windowItemCapacity");
    const std::vector<Candidate>* source = &state.rows; size_t offset = first;
    if (state.lazy) {
        if (first < state.windowFirst || first + count > state.windowFirst + state.window.size()) {
            if (!state.materializing || state.requestedFirst != first || state.requestedCount != count) {
                // Continue an adjacent older request at the existing replay
                // checkpoint instead of reconstructing the newest prefix again.
                const bool adjacent = !state.materializing && first + count == state.reverseOrdinal &&
                    state.reverseOrdinal == state.windowFirst && !state.window.empty();
                state.materializing = true; state.requestedFirst = first; state.requestedCount = count;
                state.window.clear(); state.windowFirst = first;
                if (!adjacent) {
                    state.reverseOrdinal = state.count; state.undo = {}; state.beginSlice(state.boundary);
                }
            }
            while (state.reverseOrdinal > first) {
                state.batch(reader, cancelled);
                while (state.foldAt && state.reverseOrdinal > first) {
                    const auto row = state.rows[state.foldAt - 1];
                    const bool keep = state.undo.keep(reader, row); --state.foldAt;
                    if (keep) {
                        --state.reverseOrdinal;
                        if (state.reverseOrdinal < first + count) state.window.push_back(row);
                    }
                }
                if (state.reverseOrdinal <= first) break;
                if (!state.advanceLazy()) throw std::runtime_error("kimiIndexNoProgress");
            }
            std::reverse(state.window.begin(), state.window.end()); state.materializing = false;
        }
        source = &state.window; offset = first - state.windowFirst;
    }
    std::vector<Materialized> result; result.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        if (cancelled && cancelled()) throw std::runtime_error("cancelled");
        const auto& row = source->at(offset + i);
        auto entry = decode(reader.readRecord(row.start, row.end));
        if (entry.fingerprint != row.fingerprint) throw std::runtime_error("sourceChanged");
        result.push_back({std::move(entry), (row.flags & Interrupted) != 0});
    }
    reader.validateSnapshot(); return result;
}

KimiHistoryCache::KimiHistoryCache(HistoryMetadataBudget* budget) : sharedBudget_(budget) {
    if (sharedBudget_) sharedBudget_->registerFamily(this, [this] { return usedBytes(); });
}
KimiHistoryCache::~KimiHistoryCache() { if (sharedBudget_) sharedBudget_->unregisterFamily(this); }
size_t KimiHistoryCache::usedBytes() const {
    size_t total = sizeof(*this);
    for (const auto& item : indexes_) total += sizeof(item) + item.first.capacity() + 4 * sizeof(void*) + item.second.index.bytes();
    for (const auto* paths : {&pinned_, &transientPins_, &pendingPins_})
        for (const auto& path : *paths) total += sizeof(path) + path.capacity() + 4 * sizeof(void*);
    return total;
}
KimiHistoryIndex& KimiHistoryCache::get(const std::string& path) {
    if (!indexes_.count(path) && indexes_.size() >= 24) {
        auto victim = indexes_.end();
        for (auto at = indexes_.begin(); at != indexes_.end(); ++at)
            if (!retained(at->first) && (victim == indexes_.end() || at->second.touched < victim->second.touched)) victim = at;
        if (victim != indexes_.end()) indexes_.erase(victim);
    }
    auto& item = indexes_[path]; transientPins_.insert(path); item.touched = ++clock_; return item.index;
}
size_t KimiHistoryCache::budgetFor(const std::string& path) {
    const auto family = sharedBudget_ ? sharedBudget_->allowance(this, HistoryMetadataBudget::totalLimit) : HistoryMetadataBudget::totalLimit;
    auto others = [&] { const auto found = indexes_.find(path); return usedBytes() - (found == indexes_.end() ? 0 : found->second.index.bytes()); };
    while (others() + HistoryMetadataBudget::indexLimit > family) {
        auto victim = indexes_.end();
        for (auto at = indexes_.begin(); at != indexes_.end(); ++at)
            if (at->first != path && !retained(at->first) && (victim == indexes_.end() || at->second.touched < victim->second.touched)) victim = at;
        if (victim == indexes_.end()) break;
        indexes_.erase(victim);
    }
    const auto retainedBytes = others();
    return retainedBytes >= family ? 0 : std::min(HistoryMetadataBudget::indexLimit, family - retainedBytes);
}
}
