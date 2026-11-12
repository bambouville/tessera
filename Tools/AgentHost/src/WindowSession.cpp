#include "WindowSession.h"
#include <iterator>
#include <set>

namespace tessera {
namespace {
const char* const seekableSources[] = {"claude-chain:", "pi-chain:", "kimi-history:", "codex-history:"};
// A provider's own record ID, not one a reader made from its offset ("v1:",
// and "interrupted:" for a Kimi call that never got its result).
bool ownRecordID(const std::string& id) {
    return !id.empty() && id.size() <= 64 && id.rfind("v1:", 0) != 0 && id.rfind("interrupted:", 0) != 0 &&
        std::all_of(id.begin(), id.end(), [](unsigned char c) { return c > 0x20 && c < 0x7f && c != '"' && c != '\\'; });
}
void fold(uint64_t& hash, const std::string& bytes) {
    for (const unsigned char c : bytes) { hash ^= c; hash *= 1099511628211ull; }
}
}
std::string seekToken(const NormalizedRecord& record) {
    // A record with an ID of its own is proven by its name, which a revision
    // keeps: the digest covers its turn (Codex names an item by turn and ID)
    // and the ID follows it. Any other record is proven by its content.
    const bool named = ownRecordID(record.providerID);
    uint64_t hash = 14695981039346656037ull;
    if (named) { fold(hash, record.turnID); fold(hash, std::string(1, '\0')); fold(hash, record.providerID); }
    else fold(hash, record.json);
    static const char digits[] = "0123456789abcdef";
    std::string token(16, '0');
    for (size_t index = 16; index-- > 0; hash >>= 4) token[index] = digits[hash & 15];
    return named ? token + ":" + record.providerID : token;
}
bool validSeekToken(const std::string& token) {
    return token.size() >= 16 && std::all_of(token.begin(), token.begin() + 16,
        [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }) &&
        (token.size() == 16 || (token[16] == ':' && ownRecordID(token.substr(17))));
}
WindowReply WindowSession::read(WindowPageReader& reader, CodexServer& codex, const Source& suppliedSource,
        const std::string& transaction, const std::string& operation, const std::string& cursor,
        uint64_t version, size_t limit, bool automatic, size_t serviceBytes, const WindowSeek& target) {
    auto source = suppliedSource;
    const bool bootstrap = operation == "bootstrap", head = operation == "head", seek = operation == "seek";
    const bool forward = operation == "after" || head || seek;
    if (!bootstrap && !head && !seek && operation != "before" && operation != "after") throw std::runtime_error("invalidWindowOperation");
    if (bootstrap && !cursor.empty()) throw std::runtime_error("invalidWindowAnchor");
    expire();
    std::optional<WindowAnchor> anchor;
    if (!bootstrap) {
        // A seek names the live cursor: it is asked of the window the app
        // holds now, whose source the match's order must still belong to.
        auto found = anchors_.find(cursor);
        if (found == anchors_.end() || found->second.source != generation_ || found->second.forward != forward ||
            ((head || seek) && cursor != live_)) throw std::runtime_error("windowAnchorExpired");
        anchor = found->second;
    }
    bool counted = false;
    if (seek) {
        // Only an index position names one record wherever a page starts.
        // App Server and OpenCode orders count from wherever their read
        // began, and raw JSONL pages by byte.
        const bool indexed = std::any_of(std::begin(seekableSources), std::end(seekableSources),
            [&](const char* prefix) { return generation_.rfind(prefix, 0) == 0; });
        if (!indexed) throw std::runtime_error("seekUnsupported");
        // An order counts in the generation the search read. A later one
        // numbers the file anew: an index the cache evicted and rebuilt keeps
        // every record where it was, but a rewind or a branch can give the
        // order to another record, so the match then proves itself by offset.
        counted = target.recordID == generation_ + ":" + std::to_string(target.order);
        if (!counted && !target.sourceOffset && target.token.empty()) throw std::runtime_error("seekRecordMoved");
        // Some rows above the match, so it does not open as the first line.
        anchor = WindowAnchor{generation_, "", "", target.order - std::min<uint64_t>(target.order, limit / 4), 0, true, false};
    }
    auto kind = bootstrap ? PageWindow::Kind::Bootstrap : head ? PageWindow::Kind::Head : seek ? PageWindow::Kind::Seek :
        forward ? PageWindow::Kind::After : PageWindow::Kind::Before;
    window_.reserve(transaction, version, kind, serviceBytes);
    pendingTransaction_ = transaction;
    proposedRevisionAfter_.clear();
    WindowReply reply; reply.transaction = transaction; reply.lane = operation; reply.from = cursor;
    reply.version = bootstrap ? 1 : version + 1;
    uint64_t revision = bootstrap ? 0 : revision_;
    auto generation = bootstrap ? (source.provider == "codex" ? "codex-appserver:" + randomID() : "") : generation_;
    const auto initialBytes = codex.bytesRead();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
    try {
        if (!automatic) codex.invalidateCachedReads();
        uint64_t headerBytes = 0;
        const bool canonical = reader.canonicalCodexAvailable(source, headerBytes);
        reply.canonicalCodex = canonical;
        if (generation.rfind("codex-appserver:", 0) == 0 && canonical) {
            // Never splice byte/index anchors into an existing native window.
            // Resync must bootstrap a new canonical generation instead.
            if (!bootstrap) throw std::runtime_error("sourceChanged");
            generation.clear();
            reply.fallback = "codexCanonicalTranscriptAuthority";
        }
        sourcePath_ = source.provider == "pi" ? "pi:" + source.path :
            source.provider == "claude" || source.provider == "codex" || source.provider == "kimi" ? source.path : "";
        WindowRead page;
        try {
            page = reader.read(source, generation, anchor, forward, limit, revision, seek);
            if (bootstrap && generation.rfind("codex-appserver:", 0) == 0 && page.segment.records.empty())
                throw std::runtime_error("codexEmptyHistory");
        }
        catch (const std::exception& error) {
            if (!bootstrap || source.provider != "codex" || source.path.empty() || reader.cancelled()) throw;
            reply.fallback = error.what(); generation.clear(); revision = 0;
            page = reader.read(source, generation, std::nullopt, false, limit, revision);
        }
        if (seek) {
            auto landed = [&] {
                return std::find_if(page.segment.records.begin(), page.segment.records.end(),
                    [&](const PositionedRecord& record) { return record.start == target.order; });
            };
            // Large rows above the match can fill the page before it: start
            // at the match itself instead.
            if (landed() == page.segment.records.end() && anchor->position < target.order) {
                anchor->position = target.order;
                const auto skipped = page.bytesRead;
                page = reader.read(source, generation, anchor, forward, limit, revision, true);
                page.bytesRead += skipped;
            }
            // A Codex item's offset is its latest completed copy, which a
            // revision moves later; within the search's generation its order
            // names it. The token proves the record wherever the order was
            // counted: its provider's name for it, which a revision keeps,
            // else the same JSON at the search's offset (a file rewritten in
            // place can put another record there, which a Kimi index whose
            // records keep their shape still counts as its generation). A
            // search without a token proves it by offset.
            const bool revisable = counted && generation_.rfind("codex-history:", 0) == 0;
            const auto match = landed();
            bool moved = match == page.segment.records.end();
            const bool named = target.token.size() > 16;
            if (!moved && (named || (!target.token.empty() && !revisable))) {
                moved = seekToken(match->value) != target.token ||
                    (!named && target.sourceOffset && match->sourceByteOffset != *target.sourceOffset);
            } else if (!moved && target.sourceOffset) {
                moved = revisable ? match->sourceByteOffset < *target.sourceOffset : match->sourceByteOffset != *target.sourceOffset;
            }
            if (moved) throw std::runtime_error("seekRecordMoved");
        }
        generation = page.segment.source; reply.source = generation;
        reply.native = generation.rfind("codex-appserver:", 0) == 0 || source.provider == "opencode";
        reply.bytesRead = page.bytesRead + headerBytes; reply.sourceEnd = page.sourceEnd; reply.hasNewer = head && page.segment.hasNewer;
        if (head && page.segment.records.empty()) {
            std::vector<PositionedRecord> patches;
            // The sweep position before each patch, for deferring it.
            std::vector<std::string> resume;
            size_t bytes = 2048;
            if (reply.native || generation.rfind("codex-history:", 0) == 0) {
                std::map<std::string, std::pair<PageWindow::Segment, size_t>> latest;
                for (const auto& segment : window_.coverage()) {
                    if (segment->anchors.size() != segment->records.size()) throw std::runtime_error("revisionAnchorMissing");
                    for (size_t index = 0; index < segment->records.size(); ++index) {
                        const auto& record = segment->records[index];
                        const auto key = std::to_string(record.start);
                        const auto found = latest.find(key);
                        if (found == latest.end() || record.revision > found->second.first->records[found->second.second].revision)
                            latest[key] = {segment, index};
                    }
                }
                bool full = false;
                size_t checked = 0;
                std::set<const WindowSegment*> revisedSegments;
                const auto sliceDeadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
                auto next = revisionAfter_.empty() ? latest.begin() : latest.upper_bound(revisionAfter_);
                proposedRevisionAfter_ = revisionAfter_;
                for (; next != latest.end(); ++next) {
                        // Bound unchanged work too, not just changed output.
                        // Never run hundreds of sequential provider RPCs under
                        // one request deadline. The next ACK resumes precisely
                        // after the last checked item, including empty slices.
                        if (checked && (checked >= 64 || std::chrono::steady_clock::now() >= sliceDeadline)) {
                            full = true; break;
                        }
                        const auto& [identifier, location] = *next;
                        const auto& segment = location.first; const auto index = location.second;
                        const auto& old = segment->records[index];
                        auto fresh = source.provider == "opencode" ? reader.reviseOpenCode(old, segment->anchors[index], source, revision, reply.bytesRead) :
                            reply.native ? reader.reviseNative(old, segment->anchors[index], source, revision, deadline, initialBytes) :
                            reader.reviseHistory(old, segment->anchors[index], source, revision, reply.bytesRead);
                        if (fresh.revision != old.revision) {
                            const auto cost = fresh.value.json.size() + fresh.value.providerID.size() * 6 + 1536;
                            // A large window must not turn one slice into more
                            // partitions than a revisions lane may carry.
                            const bool another = !revisedSegments.count(segment.get());
                            if (patches.size() >= limit || bytes + cost > 245760 ||
                                (another && revisedSegments.size() >= PageWindow::maximumRevisedSegments)) { full = true; break; }
                            resume.push_back(proposedRevisionAfter_);
                            bytes += cost; patches.push_back(std::move(fresh)); revisedSegments.insert(segment.get());
                        }
                        proposedRevisionAfter_ = identifier; ++checked;
                }
                if (!full) proposedRevisionAfter_.clear();
                reply.hasNewer = full;
                if (reply.native && source.provider != "opencode") reply.bytesRead = codex.bytesRead() - initialBytes;
            }
            if (patches.empty() && automatic && !reply.hasNewer && revisionAfter_.empty()) {
                cancel(transaction); reply.unchanged = true; reply.liveCursor = live_; return reply;
            }
            // The reservation changes lane without publishing any retained
            // data. Empty manual reads still provide a fresh receipt witness.
            window_.cancel(); window_.reserve(transaction, version, PageWindow::Kind::Revisions, serviceBytes);
            // Near the service ceiling, deferred patches resume in the next
            // slice. The admitted room is at least one page, so each slice
            // normally stages one patch or more; a lone patch that still cannot
            // fit refuses this refresh with windowCapacity.
            const auto staged = window_.stageRevisionPrefix(patches, randomID);
            if (staged < patches.size()) {
                proposedRevisionAfter_ = resume[staged]; reply.hasNewer = true;
                patches.erase(patches.begin() + staged, patches.end());
            }
            reply.partitions = window_.partitions();
            for (const auto& part : reply.partitions) {
                const auto original = window_.find(part.original);
                proposedAnchors_[part.before] = original->anchors[part.offset].before;
                proposedAnchors_[part.after] = original->anchors[part.offset + part.count - 1].after;
            }
            reply.lane = "revisions"; reply.records = std::move(patches); reply.liveCursor = live_;
            proposedGeneration_ = generation; proposedLive_ = live_; proposedRevision_ = revision;
            return reply;
        }
        if (head) {
            const auto previous = window_.find(window_.head());
            auto records = previous->records; auto anchors = previous->anchors;
            if (records.size() != anchors.size()) throw std::runtime_error("headAnchorMissing");
            for (size_t index = 0; index < page.segment.records.size(); ++index) {
                const auto& item = page.segment.records[index];
                if (!records.empty() && item.start <= records.back().start) throw std::runtime_error("headOrderChanged");
                records.push_back(item); anchors.push_back(page.segment.anchors[index]);
            }
            page.segment.records = std::move(records); page.segment.anchors = std::move(anchors);
            while (page.segment.records.size() > limit || page.segment.bytes() + 8192 > PageWindow::pageLimit) {
                if (page.segment.records.size() <= 1) throw std::runtime_error("windowItemCapacity");
                page.segment.records.erase(page.segment.records.begin()); page.segment.anchors.erase(page.segment.anchors.begin());
            }
            page.before = page.segment.anchors.front().before; page.after = page.segment.anchors.back().after;
            page.segment.hasOlder = !page.before.terminal;
        }
        page.segment.id = randomID(); page.segment.before = randomID(); page.segment.after = randomID();
        proposedAnchors_[page.segment.before] = page.before; proposedAnchors_[page.segment.after] = page.after;
        auto segment = std::make_shared<const WindowSegment>(std::move(page.segment));
        window_.stage(segment); reply.segment = segment; reply.records = segment->records;
        proposedGeneration_ = generation; proposedLive_ = bootstrap || head ? segment->after : live_;
        if (bootstrap || head) reply.liveCursor = proposedLive_;
        proposedRevision_ = revision;
        return reply;
    } catch (...) { cancel(transaction); throw; }
}

void WindowSession::acknowledge(const std::string& transaction, uint64_t version,
        const std::vector<std::string>& viewport, const std::string& head) {
    // PageWindow validates bounded replay before this method mutates cursors.
    window_.acknowledge(transaction, version, viewport, head);
    if (pendingTransaction_ != transaction) return;
    anchors_.insert(proposedAnchors_.begin(), proposedAnchors_.end());
    generation_ = proposedGeneration_; live_ = proposedLive_;
    revision_ = proposedRevision_;
    revisionAfter_ = proposedRevisionAfter_;
    std::set<std::string> retained{live_};
    for (const auto& segment : window_.coverage()) { retained.insert(segment->before); retained.insert(segment->after); }
    for (auto iterator = anchors_.begin(); iterator != anchors_.end();) {
        if (!retained.count(iterator->first)) iterator = anchors_.erase(iterator); else ++iterator;
    }
    proposedAnchors_.clear(); pendingTransaction_.clear(); proposedGeneration_.clear(); proposedLive_.clear();
}
void WindowSession::cancel(const std::string& transaction) {
    if (pendingTransaction_ != transaction) return;
    window_.cancel(); proposedAnchors_.clear(); pendingTransaction_.clear(); proposedGeneration_.clear(); proposedLive_.clear();
}
bool WindowSession::expire() {
    if (!window_.expire()) return false;
    proposedAnchors_.clear(); pendingTransaction_.clear(); proposedGeneration_.clear(); proposedLive_.clear();
    return true;
}
}
